// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {ICategoryIndexVaultV1} from "./CategoryIndexSuiteV1.sol";

interface INARAEngineRewardsV1 {
    function notifyEthRewards() external payable;
    function depositRewards(uint256 amount) external;
}

interface IWETH9 {
    function withdraw(uint256 amount) external;
}

/// @notice Receives index fee shares, redeems them, swaps fee assets, and routes value into NARA rewards.
/// @dev No user funds should ever enter this contract. It only handles protocol-earned fees.
/// Swap execution is restricted to trusted keepers and explicitly allowed executor selectors.
contract NARAIndexFeeCollectorV1 is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant SWAPPER_ROLE = keccak256("SWAPPER_ROLE");
    bytes32 public constant EXECUTOR_MANAGER_ROLE = keccak256("EXECUTOR_MANAGER_ROLE");
    bytes32 public constant REDEEMER_ROLE = keccak256("REDEEMER_ROLE");
    bytes32 public constant VAULT_MANAGER_ROLE = keccak256("VAULT_MANAGER_ROLE");

    error ZeroAddress();
    error ZeroAmount();
    error ExecutorNotAllowed();
    error InvalidVault();
    error InvalidRewardOutput();
    error BalanceInsufficient();
    error CallFailed();
    error ETHTransferFailed();

    struct SwapCall {
        address executor;
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint256 minAmountOut;
        bytes data;
    }

    INARAEngineRewardsV1 public immutable engine;
    IERC20 public immutable nara;
    IERC20 public immutable weth;

    mapping(address => bool) public allowedExecutor;
    mapping(address => mapping(bytes4 => bool)) public allowedSelector;
    mapping(address => bool) public allowedVault;

    event IndexFeesRedeemed(address indexed vault, uint256 sharesRedeemed);
    event AllowedVaultSet(address indexed vault, bool allowed);
    event AllowedExecutorSet(address indexed executor, bool allowed);
    event AllowedSelectorSet(address indexed executor, bytes4 indexed selector, bool allowed);
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
    event TokenSwept(address indexed token, address indexed to, uint256 amount);
    event EthSwept(address indexed to, uint256 amount);

    constructor(address engine_, address nara_, address weth_, address admin_, address[] memory allowedExecutors_) {
        if (engine_ == address(0) || nara_ == address(0) || weth_ == address(0) || admin_ == address(0)) {
            revert ZeroAddress();
        }
        engine = INARAEngineRewardsV1(engine_);
        nara = IERC20(nara_);
        weth = IERC20(weth_);

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(SWAPPER_ROLE, admin_);
        _grantRole(EXECUTOR_MANAGER_ROLE, admin_);
        _grantRole(REDEEMER_ROLE, admin_);
        _grantRole(VAULT_MANAGER_ROLE, admin_);

        for (uint256 i = 0; i < allowedExecutors_.length; i++) {
            if (allowedExecutors_[i] == address(0)) revert ZeroAddress();
            allowedExecutor[allowedExecutors_[i]] = true;
            emit AllowedExecutorSet(allowedExecutors_[i], true);
        }
    }

    receive() external payable {}

    function setAllowedVault(address vault, bool allowed) external onlyRole(VAULT_MANAGER_ROLE) {
        if (vault == address(0)) revert ZeroAddress();
        allowedVault[vault] = allowed;
        emit AllowedVaultSet(vault, allowed);
    }

    function setAllowedExecutor(address executor, bool allowed) external onlyRole(EXECUTOR_MANAGER_ROLE) {
        if (executor == address(0)) revert ZeroAddress();
        allowedExecutor[executor] = allowed;
        emit AllowedExecutorSet(executor, allowed);
    }

    function setAllowedSelector(address executor, bytes4 selector, bool allowed)
        external
        onlyRole(EXECUTOR_MANAGER_ROLE)
    {
        if (executor == address(0)) revert ZeroAddress();
        if (selector == bytes4(0)) revert ExecutorNotAllowed();
        allowedSelector[executor][selector] = allowed;
        emit AllowedSelectorSet(executor, selector, allowed);
    }

    function redeemIndexFeeShares(address vault, uint256 shares, uint256[] calldata minAmountsOut)
        external
        onlyRole(REDEEMER_ROLE)
        nonReentrant
    {
        if (vault == address(0)) revert ZeroAddress();
        if (!allowedVault[vault]) revert InvalidVault();
        if (shares == 0) revert ZeroAmount();
        if (IERC20(vault).balanceOf(address(this)) < shares) revert BalanceInsufficient();
        ICategoryIndexVaultV1(vault).redeemInKind(shares, minAmountsOut, address(this));
        emit IndexFeesRedeemed(vault, shares);
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
        IWETH9(address(weth)).withdraw(amount);
        engine.notifyEthRewards{value: amount}();
        emit EthRewardsNotified(amount);
    }

    function notifyNativeEth(uint256 amount) external onlyRole(SWAPPER_ROLE) nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (address(this).balance < amount) revert BalanceInsufficient();
        engine.notifyEthRewards{value: amount}();
        emit EthRewardsNotified(amount);
    }

    function sweepToken(address token, address to, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        if (token == address(0) || to == address(0)) revert ZeroAddress();
        if (token == address(nara) || token == address(weth)) revert InvalidRewardOutput();
        if (amount == 0) revert ZeroAmount();
        IERC20(token).safeTransfer(to, amount);
        emit TokenSwept(token, to, amount);
    }

    function sweepETH(address to, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (address(this).balance < amount) revert BalanceInsufficient();

        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert ETHTransferFailed();

        emit EthSwept(to, amount);
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
        if (actualIn > swapCall.amountIn) revert BalanceInsufficient();
        if (actualOut < swapCall.minAmountOut) revert BalanceInsufficient();
        emit SwapExecuted(
            swapCall.executor, swapCall.tokenIn, swapCall.tokenOut, swapCall.amountIn, actualIn, actualOut
        );
    }

    function _selector(bytes calldata data) internal pure returns (bytes4 selector) {
        if (data.length < 4) revert ExecutorNotAllowed();
        assembly {
            selector := calldataload(data.offset)
        }
    }
}
