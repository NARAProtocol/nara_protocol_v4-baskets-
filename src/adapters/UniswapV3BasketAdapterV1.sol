// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {INARABasketSwapAdapterV1} from "../NARAImmutableBasketPositionManagerV1.sol";

interface IUniswapV3SwapRouter02 {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

/// @notice Single-hop Uniswap V3 swap adapter for NARA Basket position managers.
/// @dev Immutable. No admin. No upgrade. Constructor pins SwapRouter02. Implements
///      INARABasketSwapAdapterV1 exactly so it can be approved as an immutable adapter
///      on any NARAImmutableBasketPositionManagerV1.
///
///      `data` is decoded as `(uint24 fee, uint160 sqrtPriceLimitX96)`. Callers select
///      the V3 pool fee tier (e.g., 100, 500, 3000, 10000) and optional sqrtPriceLimit.
///      Pass 0 for no price-limit cap.
///
///      Exact-input semantics: pulls `amountIn` from msg.sender, swaps via SwapRouter02
///      with manager as recipient, returns the actual delta. The manager
///      independently verifies these against balance deltas, so this adapter cannot
///      lie about consumed/produced amounts.
contract UniswapV3BasketAdapterV1 is INARABasketSwapAdapterV1, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IUniswapV3SwapRouter02 public immutable router;

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
        uint24 fee,
        uint256 amountIn,
        uint256 amountOut
    );

    constructor(address router_) {
        if (router_ == address(0)) revert ZeroAddress();
        router = IUniswapV3SwapRouter02(router_);
    }

    /// @inheritdoc INARABasketSwapAdapterV1
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

        (uint24 fee, uint160 sqrtPriceLimitX96) = abi.decode(data, (uint24, uint160));

        IERC20 tokenInErc = IERC20(tokenIn);
        IERC20 tokenOutErc = IERC20(tokenOut);

        uint256 selfInBefore = tokenInErc.balanceOf(address(this));
        uint256 selfOutBefore = tokenOutErc.balanceOf(address(this));
        tokenInErc.safeTransferFrom(msg.sender, address(this), amountIn);
        uint256 received = tokenInErc.balanceOf(address(this)) - selfInBefore;
        if (received != amountIn) revert UnexpectedRemainder();

        tokenInErc.forceApprove(address(router), amountIn);
        amountOut = router.exactInputSingle(
            IUniswapV3SwapRouter02.ExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                fee: fee,
                recipient: msg.sender,
                amountIn: amountIn,
                amountOutMinimum: minAmountOut,
                sqrtPriceLimitX96: sqrtPriceLimitX96
            })
        );
        tokenInErc.forceApprove(address(router), 0);

        if (amountOut < minAmountOut) revert InsufficientOutput();

        uint256 selfInAfter = tokenInErc.balanceOf(address(this));
        if (selfInAfter != selfInBefore) revert UnexpectedRemainder();

        if (tokenOutErc.balanceOf(address(this)) != selfOutBefore) revert UnexpectedRemainder();

        amountInUsed = amountIn;
        emit AdapterSwap(msg.sender, tokenIn, tokenOut, fee, amountInUsed, amountOut);
    }
}
