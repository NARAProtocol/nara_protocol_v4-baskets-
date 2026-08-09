// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {INARABasketSwapAdapterV1} from "../NARAImmutableBasketPositionManagerV1.sol";

/// @dev Minimal Permit2 AllowanceTransfer surface. Canonical Permit2 is deployed at the
///      same address on every chain: 0x000000000022D473030F116dDEE9F6B43aC78BA3.
interface IPermit2 {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

/// @dev Minimal Uniswap Universal Router surface used for v4 swaps.
interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

/// @dev Immutable identity exposed by the canonical NARA liquidity-growth hook.
interface INARALiquidityGrowthHookBinding {
    function token() external view returns (address);
    function base() external view returns (address);
    function poolRegistered() external view returns (bool);
    function registeredPoolId() external view returns (bytes32);
}

/// @title Uniswap v4 single-hop swap adapter for NARA basket position managers.
/// @notice Routes a basket's swaps through a Uniswap v4 pool via the Universal Router and
///         Permit2, implementing INARABasketSwapAdapterV1. This enables baskets to trade the
///         required NARA slice on a hooked v4 pool. Hook fees remain banked in their input
///         currency; only balanced NARA/base inventory can later be compounded by a keeper.
/// @dev Immutable: no admin, no upgrade path. The Universal Router integration keeps the
///      dependency surface to the minimal interfaces declared above (no v4-core import).
///
///      Canonical PoolKey parameters are immutable constructor inputs. Dynamic
///      route data is rejected so required-NARA flow cannot select another pool.
///
///      Exact-input semantics: pulls `amountIn` from the caller (the manager), executes the
///      swap, and forwards the output to the manager. The manager independently verifies the
///      consumed and produced amounts against its own balance deltas, so the adapter cannot
///      misreport. `minAmountOut` is enforced by the v4 swap, re-checked here, and re-checked
///      by the manager.
contract UniswapV4BasketAdapterV1 is INARABasketSwapAdapterV1, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    // Universal Router command and v4 action selectors, per the canonical Uniswap deployment.
    bytes1 private constant V4_SWAP = 0x10;
    uint8 private constant SWAP_EXACT_IN_SINGLE = 0x06;
    uint8 private constant SETTLE_ALL = 0x0c;
    uint8 private constant TAKE_ALL = 0x0f;
    uint160 private constant ALL_HOOK_PERMISSION_FLAGS = (1 << 14) - 1;
    uint160 public constant REQUIRED_HOOK_PERMISSION_FLAGS = 0x2088;

    /// @dev v4 PoolKey. Currency/IHooks are address-wrapped types; encoding as `address`
    ///      produces byte-identical calldata to the periphery's decode.
    struct PoolKey {
        address currency0;
        address currency1;
        uint24 fee;
        int24 tickSpacing;
        address hooks;
    }

    /// @dev Matches IV4Router.ExactInputSingleParams field-for-field.
    struct ExactInputSingleParams {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 amountIn;
        uint128 amountOutMinimum;
        bytes hookData;
    }

    IUniversalRouter public immutable router;
    IPermit2 public immutable permit2;
    uint24 public immutable canonicalFee;
    int24 public immutable canonicalTickSpacing;
    address public immutable canonicalHooks;
    address public immutable canonicalToken;
    address public immutable canonicalBase;
    bytes32 public immutable canonicalPoolId;

    error ZeroAddress();
    error ZeroAmount();
    error InvalidTokens();
    error DataLengthInvalid();
    error AmountTooLarge();
    error OutputTooLow(uint256 received, uint256 minimum);
    error InputNotFullyConsumed(uint256 residual);
    error InvalidHookPermissions(address hook, uint160 expected, uint160 actual);
    error HookTokenMismatch(address expected, address actual);
    error HookBaseMismatch(address expected, address actual);
    error HookPoolNotRegistered();
    error RegisteredPoolIdMismatch(bytes32 expected, bytes32 actual);

    constructor(
        address router_,
        address permit2_,
        address canonicalToken_,
        address canonicalBase_,
        uint24 canonicalFee_,
        int24 canonicalTickSpacing_,
        address canonicalHooks_
    ) {
        if (
            router_ == address(0) || permit2_ == address(0) || canonicalToken_ == address(0)
                || canonicalBase_ == address(0) || canonicalHooks_ == address(0)
        ) revert ZeroAddress();
        if (canonicalToken_ == canonicalBase_) revert InvalidTokens();

        uint160 actualHookFlags = uint160(canonicalHooks_) & ALL_HOOK_PERMISSION_FLAGS;
        if (actualHookFlags != REQUIRED_HOOK_PERMISSION_FLAGS) {
            revert InvalidHookPermissions(canonicalHooks_, REQUIRED_HOOK_PERMISSION_FLAGS, actualHookFlags);
        }

        INARALiquidityGrowthHookBinding hook = INARALiquidityGrowthHookBinding(canonicalHooks_);
        address hookToken = hook.token();
        if (hookToken != canonicalToken_) revert HookTokenMismatch(canonicalToken_, hookToken);
        address hookBase = hook.base();
        if (hookBase != canonicalBase_) revert HookBaseMismatch(canonicalBase_, hookBase);
        if (!hook.poolRegistered()) revert HookPoolNotRegistered();

        bytes32 recomputedPoolId =
            _poolId(canonicalToken_, canonicalBase_, canonicalFee_, canonicalTickSpacing_, canonicalHooks_);
        bytes32 registeredPoolId = hook.registeredPoolId();
        if (registeredPoolId != recomputedPoolId) {
            revert RegisteredPoolIdMismatch(recomputedPoolId, registeredPoolId);
        }

        router = IUniversalRouter(router_);
        permit2 = IPermit2(permit2_);
        canonicalToken = canonicalToken_;
        canonicalBase = canonicalBase_;
        canonicalFee = canonicalFee_;
        canonicalTickSpacing = canonicalTickSpacing_;
        canonicalHooks = canonicalHooks_;
        canonicalPoolId = recomputedPoolId;
    }

    /// @inheritdoc INARABasketSwapAdapterV1
    function swapExactInput(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        bytes calldata data
    ) external nonReentrant returns (uint256 amountInUsed, uint256 amountOut) {
        if (tokenIn == address(0) || tokenOut == address(0) || tokenIn == tokenOut) {
            revert InvalidTokens();
        }
        if (!((tokenIn == canonicalToken && tokenOut == canonicalBase)
                    || (tokenIn == canonicalBase && tokenOut == canonicalToken))) revert InvalidTokens();
        if (amountIn == 0 || minAmountOut == 0) revert ZeroAmount();
        // v4 swap amounts are uint128.
        if (amountIn > type(uint128).max || minAmountOut > type(uint128).max) revert AmountTooLarge();
        uint128 amountIn128 = amountIn.toUint128();
        uint128 minAmountOut128 = minAmountOut.toUint128();

        // Canonical fee, tick spacing, and hook are constructor immutables. Reject all
        // caller-supplied route data so this adapter cannot be redirected to another pool.
        if (data.length != 0) revert DataLengthInvalid();

        // Pull the exact input the manager approved.
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);

        // Permit2 path: ERC20-approve Permit2, then Permit2-approve the Universal Router.
        // The router pulls `amountIn` within this same tx; the allowance self-decrements to 0.
        IERC20(tokenIn).forceApprove(address(permit2), amountIn);
        permit2.approve(tokenIn, address(router), amountIn128, uint48(block.timestamp + 60));

        uint256 inBeforeSwap = IERC20(tokenIn).balanceOf(address(this));
        uint256 received = _executeV4Swap(
            tokenIn, tokenOut, amountIn128, minAmountOut128, canonicalFee, canonicalTickSpacing, canonicalHooks
        );
        if (received < minAmountOut) revert OutputTooLow(received, minAmountOut);
        uint256 inAfterSwap = IERC20(tokenIn).balanceOf(address(this));
        if (inBeforeSwap - inAfterSwap != amountIn) revert InputNotFullyConsumed(inAfterSwap);

        // Clear the ERC20 approval to Permit2 (defensive; it's consumed already).
        IERC20(tokenIn).forceApprove(address(permit2), 0);

        // Forward output to the manager; it verifies its own balance delta.
        IERC20(tokenOut).safeTransfer(msg.sender, received);

        amountInUsed = amountIn;
        amountOut = received;
    }

    /// @dev Encodes and dispatches the single-hop v4 exact-input swap through the Universal
    ///      Router, then returns the tokenOut actually received by this adapter.
    function _executeV4Swap(
        address tokenIn,
        address tokenOut,
        uint128 amountIn,
        uint128 minAmountOut,
        uint24 fee,
        int24 tickSpacing,
        address hooks
    ) internal returns (uint256 received) {
        // PoolKey currencies are sorted by address.
        (address currency0, address currency1) = tokenIn < tokenOut ? (tokenIn, tokenOut) : (tokenOut, tokenIn);
        bool zeroForOne = tokenIn == currency0;

        bytes memory actions = abi.encodePacked(SWAP_EXACT_IN_SINGLE, SETTLE_ALL, TAKE_ALL);

        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            ExactInputSingleParams({
                poolKey: PoolKey({
                    currency0: currency0, currency1: currency1, fee: fee, tickSpacing: tickSpacing, hooks: hooks
                }),
                zeroForOne: zeroForOne,
                amountIn: amountIn,
                amountOutMinimum: minAmountOut,
                hookData: bytes("")
            })
        );
        params[1] = abi.encode(tokenIn, amountIn); // SETTLE_ALL(currency, maxAmount)
        params[2] = abi.encode(tokenOut, minAmountOut); // TAKE_ALL(currency, minAmount)

        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);

        uint256 outBefore = IERC20(tokenOut).balanceOf(address(this));
        router.execute(abi.encodePacked(V4_SWAP), inputs, block.timestamp);
        received = IERC20(tokenOut).balanceOf(address(this)) - outBefore;
    }

    function _poolId(address token, address base, uint24 fee, int24 tickSpacing, address hooks)
        internal
        pure
        returns (bytes32)
    {
        (address currency0, address currency1) = token < base ? (token, base) : (base, token);
        return keccak256(
            abi.encode(
                PoolKey({currency0: currency0, currency1: currency1, fee: fee, tickSpacing: tickSpacing, hooks: hooks})
            )
        );
    }
}
