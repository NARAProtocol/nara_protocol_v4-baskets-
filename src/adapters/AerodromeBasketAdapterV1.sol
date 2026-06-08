// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {INARABasketSwapAdapterV1} from "../NARAImmutableBasketPositionManagerV1.sol";

interface IAerodromeRouter {
    struct Route {
        address from;
        address to;
        bool stable;
        address factory;
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        Route[] calldata routes,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
}

/// @notice Aerodrome (Velodrome V2 fork) swap adapter for NARA Basket position managers.
/// @dev Supports single-hop and multi-hop routes through Aerodrome stable and volatile pools.
///      Immutable. No admin. No upgrade. Constructor pins the Aerodrome Router and factory.
///
///      `data` is ABI-encoded as `IAerodromeRouter.Route[]`.
///
///        Route = (address from, address to, bool stable, address factory)
///
///      Rules:
///        routes[0].from must equal tokenIn.
///        routes[last].to must equal tokenOut.
///        Each routes[i].from must equal routes[i-1].to (no broken chains).
///        All addresses in each Route must be non-zero.
///        Max 4 hops. 1–2 hops cover every realistic basket use case.
///
///      Typical encodings (from baskets.ts):
///
///        Single-hop  USDC → TOSHI (Aerodrome volatile):
///          routes = [{ from: USDC, to: TOSHI, stable: false, factory: AERO_FACTORY }]
///
///        Two-hop  USDC → WETH → BRETT (no direct USDC pool for BRETT):
///          routes = [
///            { from: USDC,  to: WETH,  stable: false, factory: AERO_FACTORY },
///            { from: WETH,  to: BRETT, stable: false, factory: AERO_FACTORY }
///          ]
///
///        Stable swap  USDC → DAI:
///          routes = [{ from: USDC, to: DAI, stable: true, factory: AERO_FACTORY }]
///
///      The position manager verifies return values against token balance deltas, so this
///      adapter cannot misreport consumed/produced amounts.
contract AerodromeBasketAdapterV1 is INARABasketSwapAdapterV1, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IAerodromeRouter public immutable router;
    address public immutable allowedFactory;

    uint256 public constant MAX_HOPS = 4;

    error ZeroAddress();
    error ZeroAmount();
    error InvalidTokens();
    error EmptyRoutes();
    error TooManyHops();
    error RouteTokenInMismatch(address expected, address actual);
    error RouteTokenOutMismatch(address expected, address actual);
    error RouteChainBroken(uint256 index, address prevTo, address currFrom);
    error RouteZeroAddress(uint256 index);
    error RouteFactoryNotAllowed(uint256 index, address expected, address actual);
    error InsufficientOutput();
    error UnexpectedRemainder();

    event AdapterSwap(
        address indexed caller,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 hopCount,
        uint256 amountIn,
        uint256 amountOut
    );

    constructor(address router_, address factory_) {
        if (router_ == address(0) || factory_ == address(0)) revert ZeroAddress();
        router = IAerodromeRouter(router_);
        allowedFactory = factory_;
    }

    /// @inheritdoc INARABasketSwapAdapterV1
    /// @param data ABI-encoded Route[] — see contract-level docs for encoding examples.
    function swapExactInput(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        bytes calldata data
    ) external nonReentrant returns (uint256 amountInUsed, uint256 amountOut) {
        if (tokenIn == address(0) || tokenOut == address(0)) revert ZeroAddress();
        if (tokenIn == tokenOut) revert InvalidTokens();
        if (amountIn == 0 || minAmountOut == 0) revert ZeroAmount();

        IAerodromeRouter.Route[] memory routes = abi.decode(data, (IAerodromeRouter.Route[]));

        if (routes.length == 0) revert EmptyRoutes();
        if (routes.length > MAX_HOPS) revert TooManyHops();

        // Validate first and last hops match tokenIn / tokenOut.
        if (routes[0].from != tokenIn) revert RouteTokenInMismatch(tokenIn, routes[0].from);
        uint256 last = routes.length - 1;
        if (routes[last].to != tokenOut) revert RouteTokenOutMismatch(tokenOut, routes[last].to);

        // Validate no zero addresses and continuous chain through intermediate hops.
        for (uint256 i = 0; i < routes.length; ++i) {
            if (routes[i].from == address(0) || routes[i].to == address(0) || routes[i].factory == address(0)) {
                revert RouteZeroAddress(i);
            }
            if (routes[i].factory != allowedFactory) {
                revert RouteFactoryNotAllowed(i, allowedFactory, routes[i].factory);
            }
            if (i > 0 && routes[i].from != routes[i - 1].to) {
                revert RouteChainBroken(i, routes[i - 1].to, routes[i].from);
            }
        }

        IERC20 tokenInErc = IERC20(tokenIn);
        IERC20 tokenOutErc = IERC20(tokenOut);

        // Pull tokenIn from caller (position manager) and track balance delta to catch
        // any fee-on-transfer token that slips through the basket guard.
        uint256 selfInBefore = tokenInErc.balanceOf(address(this));
        uint256 selfOutBefore = tokenOutErc.balanceOf(address(this));
        tokenInErc.safeTransferFrom(msg.sender, address(this), amountIn);
        uint256 received = tokenInErc.balanceOf(address(this)) - selfInBefore;
        if (received != amountIn) revert UnexpectedRemainder();

        tokenInErc.forceApprove(address(router), amountIn);

        // Router sends final tokenOut directly to msg.sender (position manager).
        uint256[] memory amounts = router.swapExactTokensForTokens(
            amountIn,
            minAmountOut,
            routes,
            msg.sender,
            block.timestamp
        );

        tokenInErc.forceApprove(address(router), 0);

        amountOut = amounts[amounts.length - 1];
        if (amountOut < minAmountOut) revert InsufficientOutput();

        // This adapter must hold zero tokenIn after the swap (all consumed by router).
        if (tokenInErc.balanceOf(address(this)) != selfInBefore) revert UnexpectedRemainder();
        // Router sends tokenOut directly to msg.sender; unrelated dust must not brick the route.
        if (tokenOutErc.balanceOf(address(this)) != selfOutBefore) revert UnexpectedRemainder();

        amountInUsed = amountIn;
        emit AdapterSwap(msg.sender, tokenIn, tokenOut, routes.length, amountInUsed, amountOut);
    }
}
