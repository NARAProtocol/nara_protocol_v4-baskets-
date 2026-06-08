// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface INARAEngineRewardsV2 {
    function notifyEthRewards() external payable;
    function depositRewards(uint256 amount) external;
}

interface IWETH9V2 {
    function withdraw(uint256 amount) external;
}

/// @notice Routes basket fees into NARA rewards. Sweep-resistant against fee tokens.
/// @dev V2 hardens V1 by removing the arbitrary `sweepToken` admin escape. Any ERC-20 that
///      arrives in this contract can leave only through the swap pipeline, which is
///      constrained to output NARA or WETH. This eliminates the F-08 USDC honeypot risk
///      where a compromised admin could drain pre-swap USDC fees.
///
///      No `sweepToken`. No `sweepETH`. Stuck native ETH is forwarded to the engine via
///      `notifyNativeEth` (admin can choose to drain idle ETH only into engine rewards).
///
///      Admin still controls executor + selector allowlist (operational governance over
///      DEX routes), but cannot redirect token outflow away from the engine.
contract NARAIndexFeeCollectorV2 is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant SWAPPER_ROLE = keccak256("SWAPPER_ROLE");
    bytes32 public constant EXECUTOR_MANAGER_ROLE = keccak256("EXECUTOR_MANAGER_ROLE");

    error ZeroAddress();
    error ZeroAmount();
    error ExecutorNotAllowed();
    error InvalidRewardOutput();
    error BalanceInsufficient();
    error CallFailed();
    error SelectorTooShort();
    error EthOutflowDisabled();
    error AllowlistFrozen();

    struct SwapCall {
        address executor;
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint256 minAmountOut;
        bytes data;
    }

    INARAEngineRewardsV2 public immutable engine;
    IERC20 public immutable nara;
    IERC20 public immutable weth;

    mapping(address => bool) public allowedExecutor;
    mapping(address => mapping(bytes4 => bool)) public allowedSelector;
    bool public allowlistFrozen;

    event AllowedExecutorSet(address indexed executor, bool allowed);
    event AllowedSelectorSet(address indexed executor, bytes4 indexed selector, bool allowed);
    event AllowlistFrozenSet();
    event SwapExecuted(
        address indexed executor,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountInMax,
        uint256 amountInActual,
        uint256 amountOutActual
    );
    event NaraRewardsDeposited(uint256 amount);
    event EthRewardsNotified(uint256 amount);

    constructor(address engine_, address nara_, address weth_, address admin_, address[] memory allowedExecutors_) {
        if (engine_ == address(0) || nara_ == address(0) || weth_ == address(0) || admin_ == address(0)) {
            revert ZeroAddress();
        }
        engine = INARAEngineRewardsV2(engine_);
        nara = IERC20(nara_);
        weth = IERC20(weth_);

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(SWAPPER_ROLE, admin_);
        _grantRole(EXECUTOR_MANAGER_ROLE, admin_);

        for (uint256 i = 0; i < allowedExecutors_.length; i++) {
            if (allowedExecutors_[i] == address(0)) revert ZeroAddress();
            allowedExecutor[allowedExecutors_[i]] = true;
            emit AllowedExecutorSet(allowedExecutors_[i], true);
        }
    }

    receive() external payable {}

    function setAllowedExecutor(address executor, bool allowed) external onlyRole(EXECUTOR_MANAGER_ROLE) {
        if (allowlistFrozen) revert AllowlistFrozen();
        if (executor == address(0)) revert ZeroAddress();
        allowedExecutor[executor] = allowed;
        emit AllowedExecutorSet(executor, allowed);
    }

    function setAllowedSelector(address executor, bytes4 selector, bool allowed)
        external
        onlyRole(EXECUTOR_MANAGER_ROLE)
    {
        if (allowlistFrozen) revert AllowlistFrozen();
        if (executor == address(0)) revert ZeroAddress();
        if (selector == bytes4(0)) revert ExecutorNotAllowed();
        allowedSelector[executor][selector] = allowed;
        emit AllowedSelectorSet(executor, selector, allowed);
    }

    function freezeAllowlist() external onlyRole(EXECUTOR_MANAGER_ROLE) {
        allowlistFrozen = true;
        emit AllowlistFrozenSet();
    }

    function executeFeeSwap(SwapCall calldata swapCall) external onlyRole(SWAPPER_ROLE) nonReentrant {
        _executeSwap(swapCall);
    }

    function depositNaraRewards(uint256 amount) external onlyRole(SWAPPER_ROLE) nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (nara.balanceOf(address(this)) < amount) revert BalanceInsufficient();
        nara.forceApprove(address(engine), amount);
        engine.depositRewards(amount);
        nara.forceApprove(address(engine), 0);
        emit NaraRewardsDeposited(amount);
    }

    function unwrapWethAndNotifyEth(uint256 amount) external onlyRole(SWAPPER_ROLE) nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (weth.balanceOf(address(this)) < amount) revert BalanceInsufficient();
        IWETH9V2(address(weth)).withdraw(amount);
        engine.notifyEthRewards{value: amount}();
        emit EthRewardsNotified(amount);
    }

    function notifyNativeEth(uint256 amount) external onlyRole(SWAPPER_ROLE) nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (address(this).balance < amount) revert BalanceInsufficient();
        engine.notifyEthRewards{value: amount}();
        emit EthRewardsNotified(amount);
    }

    function _executeSwap(SwapCall calldata swapCall) internal {
        if (!allowedExecutor[swapCall.executor]) revert ExecutorNotAllowed();
        if (!allowedSelector[swapCall.executor][_selector(swapCall.data)]) revert ExecutorNotAllowed();
        if (swapCall.tokenIn == address(0) || swapCall.tokenOut == address(0)) revert ZeroAddress();
        if (swapCall.amountIn == 0 || swapCall.minAmountOut == 0) revert ZeroAmount();
        if (swapCall.tokenOut != address(nara) && swapCall.tokenOut != address(weth)) {
            revert InvalidRewardOutput();
        }

        uint256 inBefore = IERC20(swapCall.tokenIn).balanceOf(address(this));
        uint256 outBefore = IERC20(swapCall.tokenOut).balanceOf(address(this));
        if (inBefore < swapCall.amountIn) revert BalanceInsufficient();

        IERC20(swapCall.tokenIn).forceApprove(swapCall.executor, swapCall.amountIn);
        (bool ok,) = swapCall.executor.call(swapCall.data);
        IERC20(swapCall.tokenIn).forceApprove(swapCall.executor, 0);
        if (!ok) revert CallFailed();

        uint256 inAfter = IERC20(swapCall.tokenIn).balanceOf(address(this));
        uint256 outAfter = IERC20(swapCall.tokenOut).balanceOf(address(this));
        uint256 actualIn = inAfter < inBefore ? inBefore - inAfter : 0;
        uint256 actualOut = outAfter > outBefore ? outAfter - outBefore : 0;
        if (actualIn == 0) revert ZeroAmount();
        if (actualIn > swapCall.amountIn) revert BalanceInsufficient();
        if (actualOut < swapCall.minAmountOut) revert BalanceInsufficient();
        emit SwapExecuted(
            swapCall.executor, swapCall.tokenIn, swapCall.tokenOut, swapCall.amountIn, actualIn, actualOut
        );
    }

    function _selector(bytes calldata data) internal pure returns (bytes4 selector) {
        if (data.length < 4) revert SelectorTooShort();
        assembly {
            selector := calldataload(data.offset)
        }
    }
}
