// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {INARABasketSwapAdapterV1} from "../NARAImmutableBasketPositionManagerV1.sol";

/// @dev Aerodrome Slipstream (concentrated-liquidity) SwapRouter. Verified on Base at
///      0xBE6D8f0d05cC4be24d5167a3eF062215bE6D18a5 ("Aerodrome: SlipStream Swap Router").
///      Slipstream is a Uniswap-V3 fork but identifies pools by `tickSpacing` (int24), not a
///      fee tier. This is the dominant Base venue by volume — the classic AMM Router used by
///      AerodromeBasketAdapterV1 cannot reach these CL pools.
interface ISlipstreamSwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        int24 tickSpacing;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

/// @notice Single-hop Aerodrome Slipstream (CL) swap adapter for NARA Basket position managers.
/// @dev Immutable. No admin. No upgrade. Constructor pins the Slipstream SwapRouter.
///      Implements INARABasketSwapAdapterV1 exactly so it can be approved as an immutable
///      adapter on any NARAImmutableBasketPositionManagerV1.
///
///      `data` is decoded as `(int24 tickSpacing, uint160 sqrtPriceLimitX96)`. Common Slipstream
///      tick spacings on Base are 1 and 50 (stable/correlated), 100 and 200 (volatile), and 2000
///      (exotic). Pass 0 for sqrtPriceLimitX96 to apply no price-limit cap.
///
///      Exact-input semantics: pulls `amountIn` from msg.sender, swaps via the router with the
///      manager (msg.sender) as recipient, returns the actual delta. The position manager
///      independently verifies these against token balance deltas, so this adapter cannot lie
///      about consumed/produced amounts.
contract AerodromeSlipstreamBasketAdapterV1 is INARABasketSwapAdapterV1, ReentrancyGuard {
    using SafeERC20 for IERC20;

    ISlipstreamSwapRouter public immutable router;

    error ZeroAddress();
    error ZeroAmount();
    error InvalidTokens();
    error DataLengthInvalid();
    error InsufficientOutput();
    error UnexpectedRemainder();

    event AdapterSwap(
        address indexed caller,
        address indexed tokenIn,
        address indexed tokenOut,
        int24 tickSpacing,
        uint256 amountIn,
        uint256 amountOut
    );

    constructor(address router_) {
        if (router_ == address(0)) revert ZeroAddress();
        router = ISlipstreamSwapRouter(router_);
    }

    /// @inheritdoc INARABasketSwapAdapterV1
    /// @param data ABI-encoded `(int24 tickSpacing, uint160 sqrtPriceLimitX96)`.
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
        if (data.length != 64) revert DataLengthInvalid();

        (int24 tickSpacing, uint160 sqrtPriceLimitX96) = abi.decode(data, (int24, uint160));

        IERC20 tokenInErc = IERC20(tokenIn);
        IERC20 tokenOutErc = IERC20(tokenOut);

        uint256 selfInBefore = tokenInErc.balanceOf(address(this));
        uint256 selfOutBefore = tokenOutErc.balanceOf(address(this));
        tokenInErc.safeTransferFrom(msg.sender, address(this), amountIn);
        uint256 received = tokenInErc.balanceOf(address(this)) - selfInBefore;
        if (received != amountIn) revert UnexpectedRemainder();

        tokenInErc.forceApprove(address(router), amountIn);
        amountOut = router.exactInputSingle(
            ISlipstreamSwapRouter.ExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                tickSpacing: tickSpacing,
                recipient: msg.sender,
                deadline: block.timestamp,
                amountIn: amountIn,
                amountOutMinimum: minAmountOut,
                sqrtPriceLimitX96: sqrtPriceLimitX96
            })
        );
        tokenInErc.forceApprove(address(router), 0);

        if (amountOut < minAmountOut) revert InsufficientOutput();

        // Adapter must consume exactly amountIn and retain nothing.
        uint256 selfInAfter = tokenInErc.balanceOf(address(this));
        if (selfInAfter != selfInBefore) revert UnexpectedRemainder();
        if (tokenOutErc.balanceOf(address(this)) != selfOutBefore) revert UnexpectedRemainder();

        amountInUsed = amountIn;
        emit AdapterSwap(msg.sender, tokenIn, tokenOut, tickSpacing, amountInUsed, amountOut);
    }
}
