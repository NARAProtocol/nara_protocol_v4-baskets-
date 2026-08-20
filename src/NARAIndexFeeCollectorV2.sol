// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface INARAEngineRewardsV2 {
    function NARA() external view returns (address);
    function notifyEthRewards() external payable;
    function depositRewards(uint256 amount) external;
}

interface IWETH9V2 {
    function withdraw(uint256 amount) external;
}

interface IAggregatorV3V2 {
    function decimals() external view returns (uint8);

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

interface ISwapRouter02V2 {
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

/// @notice Converts launch-basket USDC fees into oracle-bounded WETH and atomically
///         forwards the resulting ETH, or directly held NARA, to the NARA engine.
/// @dev V2 deliberately has no arbitrary executor, selector, calldata, token sweep,
///      or caller-supplied minimum output. Basket launch configuration must keep
///      holding and raw-withdraw fees at zero, so normal manager flows send only
///      USDC buy/sell fees or NARA-denominated sell fees here.
///
///      The typed USDC -> WETH route can be replaced after a two-day delay to
///      survive router or oracle migration. Every execution remains constrained by
///      fresh USDC/USD and ETH/USD feeds plus an immutable slippage ceiling.
contract NARAIndexFeeCollectorV2 is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant BPS = 10_000;
    uint16 public constant MAX_SLIPPAGE_BPS = 500;
    uint48 public constant MIN_ORACLE_AGE = 5 minutes;
    uint48 public constant MAX_ORACLE_AGE = 2 days;
    uint48 public constant ROUTE_UPDATE_DELAY = 2 days;

    uint256 public constant USDC_MIN_PRICE_WAD = 0.9e18;
    uint256 public constant USDC_MAX_PRICE_WAD = 1.1e18;
    uint256 public constant ETH_MIN_PRICE_WAD = 100e18;
    uint256 public constant ETH_MAX_PRICE_WAD = 100_000e18;
    address internal constant BASE_SEQUENCER_UPTIME_FEED = 0xBCF85224fc0756B9Fa45aA7892530B47e10b6433;
    uint256 internal constant SEQUENCER_GRACE_PERIOD = 1 hours;

    bytes32 public constant SWAPPER_ROLE = keccak256("SWAPPER_ROLE");
    bytes32 public constant ROUTE_MANAGER_ROLE = keccak256("ROUTE_MANAGER_ROLE");

    error ZeroAddress();
    error ZeroAmount();
    error NotAContract(address account);
    error RolesMustDiffer();
    error InvalidConfig();
    error BalanceInsufficient();
    error OracleInvalid(address feed);
    error OracleStale(address feed, uint256 updatedAt);
    error OraclePriceOutOfBounds(address feed, uint256 priceWad);
    error SequencerDown();
    error SequencerGracePeriodNotElapsed(uint256 startedAt);
    error NoPendingRoute();
    error RouteUpdateNotReady(uint48 eta);
    error PendingRouteProposerRevoked(address proposer);
    error RouteOutputTooLow(uint256 minimum, uint256 actual);
    error RouteInputMismatch(uint256 expected, uint256 actual);
    error EngineInputMismatch(uint256 expected, uint256 actual);

    struct RouteConfig {
        address router;
        address usdcUsdFeed;
        address ethUsdFeed;
        uint24 poolFee;
    }

    struct PendingRouteConfig {
        RouteConfig route;
        address proposer;
        uint48 eta;
        bool exists;
    }

    INARAEngineRewardsV2 public immutable engine;
    IERC20 public immutable nara;
    IERC20 public immutable usdc;
    IERC20 public immutable weth;
    uint8 public immutable usdcDecimals;
    uint48 public immutable maxUsdcOracleAge;
    uint48 public immutable maxEthOracleAge;
    uint16 public immutable maxSlippageBps;

    RouteConfig public routeConfig;
    PendingRouteConfig public pendingRouteConfig;

    event RouteProposed(
        address indexed router, address indexed usdcUsdFeed, address indexed ethUsdFeed, uint24 poolFee, uint48 eta
    );
    event RouteExecuted(
        address indexed router, address indexed usdcUsdFeed, address indexed ethUsdFeed, uint24 poolFee
    );
    event RouteCancelled();
    event UsdcConvertedAndNotified(
        address indexed router, uint256 usdcAmountIn, uint256 minimumWethOut, uint256 actualWethOut
    );
    event NaraRewardsDeposited(uint256 amount);
    event EthRewardsNotified(uint256 amount);

    constructor(
        address engine_,
        address nara_,
        address usdc_,
        address weth_,
        address admin_,
        address swapper_,
        address routeManager_,
        RouteConfig memory initialRoute_,
        uint48 maxUsdcOracleAge_,
        uint48 maxEthOracleAge_,
        uint16 maxSlippageBps_
    ) {
        if (
            engine_ == address(0) || nara_ == address(0) || usdc_ == address(0) || weth_ == address(0)
                || admin_ == address(0) || swapper_ == address(0) || routeManager_ == address(0)
        ) {
            revert ZeroAddress();
        }
        if (admin_ == swapper_ || admin_ == routeManager_ || swapper_ == routeManager_) {
            revert RolesMustDiffer();
        }
        _requireContract(admin_);
        _requireContract(routeManager_);
        _requireContract(engine_);
        _requireContract(nara_);
        _requireContract(usdc_);
        _requireContract(weth_);
        if (INARAEngineRewardsV2(engine_).NARA() != nara_) revert InvalidConfig();
        _validateRoute(initialRoute_);
        if (
            maxUsdcOracleAge_ < MIN_ORACLE_AGE || maxUsdcOracleAge_ > MAX_ORACLE_AGE
                || maxEthOracleAge_ < MIN_ORACLE_AGE || maxEthOracleAge_ > MAX_ORACLE_AGE
                || maxSlippageBps_ > MAX_SLIPPAGE_BPS
        ) {
            revert InvalidConfig();
        }

        uint8 usdcDecimals_ = IERC20Metadata(usdc_).decimals();
        if (usdcDecimals_ > 18 || IERC20Metadata(weth_).decimals() != 18) revert InvalidConfig();

        engine = INARAEngineRewardsV2(engine_);
        nara = IERC20(nara_);
        usdc = IERC20(usdc_);
        weth = IERC20(weth_);
        usdcDecimals = usdcDecimals_;
        maxUsdcOracleAge = maxUsdcOracleAge_;
        maxEthOracleAge = maxEthOracleAge_;
        maxSlippageBps = maxSlippageBps_;
        routeConfig = initialRoute_;

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(SWAPPER_ROLE, swapper_);
        _grantRole(ROUTE_MANAGER_ROLE, routeManager_);

        emit RouteExecuted(
            initialRoute_.router, initialRoute_.usdcUsdFeed, initialRoute_.ethUsdFeed, initialRoute_.poolFee
        );
    }

    receive() external payable {}

    /// @notice Queues a typed USDC/WETH route replacement.
    /// @dev Worst case for a compromised route manager is a publicly visible bad
    ///      proposal. It cannot execute for two days and oracle bounds still apply.
    function proposeRoute(RouteConfig calldata nextRoute) external onlyRole(ROUTE_MANAGER_ROLE) {
        _validateRoute(nextRoute);
        uint48 eta = uint48(block.timestamp + ROUTE_UPDATE_DELAY);
        pendingRouteConfig = PendingRouteConfig({route: nextRoute, proposer: msg.sender, eta: eta, exists: true});
        emit RouteProposed(nextRoute.router, nextRoute.usdcUsdFeed, nextRoute.ethUsdFeed, nextRoute.poolFee, eta);
    }

    /// @notice Cancels a queued route. The role admin is an independent guardian
    ///         so a compromised route manager cannot make its own proposal
    ///         unstoppable.
    function cancelRoute() external {
        if (!hasRole(ROUTE_MANAGER_ROLE, msg.sender)) {
            _checkRole(DEFAULT_ADMIN_ROLE, msg.sender);
        }
        if (!pendingRouteConfig.exists) revert NoPendingRoute();
        delete pendingRouteConfig;
        emit RouteCancelled();
    }

    /// @notice Activates a matured route only after independent admin approval.
    function executeRoute() external onlyRole(DEFAULT_ADMIN_ROLE) {
        PendingRouteConfig memory pending = pendingRouteConfig;
        if (!pending.exists) revert NoPendingRoute();
        if (block.timestamp < pending.eta) revert RouteUpdateNotReady(pending.eta);
        if (!hasRole(ROUTE_MANAGER_ROLE, pending.proposer)) {
            revert PendingRouteProposerRevoked(pending.proposer);
        }
        delete pendingRouteConfig;
        routeConfig = pending.route;
        emit RouteExecuted(
            pending.route.router, pending.route.usdcUsdFeed, pending.route.ethUsdFeed, pending.route.poolFee
        );
    }

    /// @notice Converts collector-held USDC through the typed route and forwards
    ///         the received ETH to the engine in the same transaction.
    function convertUsdcAndNotifyEth(uint256 amountIn)
        external
        onlyRole(SWAPPER_ROLE)
        nonReentrant
        returns (uint256 actualOut)
    {
        if (amountIn == 0) revert ZeroAmount();
        if (usdc.balanceOf(address(this)) < amountIn) revert BalanceInsufficient();

        RouteConfig memory route = routeConfig;
        uint256 minimumOut = minimumWethOut(amountIn);
        uint256 usdcBefore = usdc.balanceOf(address(this));
        uint256 wethBefore = weth.balanceOf(address(this));

        usdc.forceApprove(route.router, amountIn);
        ISwapRouter02V2(route.router)
            .exactInputSingle(
                ISwapRouter02V2.ExactInputSingleParams({
                    tokenIn: address(usdc),
                    tokenOut: address(weth),
                    fee: route.poolFee,
                    recipient: address(this),
                    amountIn: amountIn,
                    amountOutMinimum: minimumOut,
                    sqrtPriceLimitX96: 0
                })
            );
        usdc.forceApprove(route.router, 0);

        uint256 usdcAfter = usdc.balanceOf(address(this));
        uint256 wethAfter = weth.balanceOf(address(this));
        uint256 actualIn = usdcBefore > usdcAfter ? usdcBefore - usdcAfter : 0;
        actualOut = wethAfter > wethBefore ? wethAfter - wethBefore : 0;
        if (actualIn != amountIn) revert RouteInputMismatch(amountIn, actualIn);
        if (actualOut < minimumOut) revert RouteOutputTooLow(minimumOut, actualOut);

        IWETH9V2(address(weth)).withdraw(actualOut);
        engine.notifyEthRewards{value: actualOut}();
        emit UsdcConvertedAndNotified(route.router, amountIn, minimumOut, actualOut);
        emit EthRewardsNotified(actualOut);
    }

    function minimumWethOut(uint256 amountIn) public view returns (uint256) {
        if (amountIn == 0) revert ZeroAmount();
        _requireSequencerHealthy();
        RouteConfig memory route = routeConfig;
        uint256 usdcPriceWad = _readPriceWad(route.usdcUsdFeed, maxUsdcOracleAge);
        uint256 ethPriceWad = _readPriceWad(route.ethUsdFeed, maxEthOracleAge);
        if (usdcPriceWad < USDC_MIN_PRICE_WAD || usdcPriceWad > USDC_MAX_PRICE_WAD) {
            revert OraclePriceOutOfBounds(route.usdcUsdFeed, usdcPriceWad);
        }
        if (ethPriceWad < ETH_MIN_PRICE_WAD || ethPriceWad > ETH_MAX_PRICE_WAD) {
            revert OraclePriceOutOfBounds(route.ethUsdFeed, ethPriceWad);
        }

        uint256 usdValueWad = Math.mulDiv(amountIn, usdcPriceWad, 10 ** uint256(usdcDecimals));
        uint256 expectedWeth = Math.mulDiv(usdValueWad, 1e18, ethPriceWad);
        return Math.mulDiv(expectedWeth, BPS - maxSlippageBps, BPS);
    }

    function _requireSequencerHealthy() internal view {
        (, int256 answer, uint256 startedAt,,) = IAggregatorV3V2(BASE_SEQUENCER_UPTIME_FEED).latestRoundData();
        if (answer != 0) revert SequencerDown();
        if (startedAt == 0 || startedAt > block.timestamp) {
            revert OracleInvalid(BASE_SEQUENCER_UPTIME_FEED);
        }
        if (block.timestamp - startedAt <= SEQUENCER_GRACE_PERIOD) {
            revert SequencerGracePeriodNotElapsed(startedAt);
        }
    }

    function depositNaraRewards(uint256 amount) external onlyRole(SWAPPER_ROLE) nonReentrant {
        if (amount == 0) revert ZeroAmount();
        uint256 balanceBefore = nara.balanceOf(address(this));
        if (balanceBefore < amount) revert BalanceInsufficient();
        nara.forceApprove(address(engine), amount);
        engine.depositRewards(amount);
        nara.forceApprove(address(engine), 0);
        uint256 balanceAfter = nara.balanceOf(address(this));
        uint256 actualInput = balanceBefore > balanceAfter ? balanceBefore - balanceAfter : 0;
        if (actualInput != amount) revert EngineInputMismatch(amount, actualInput);
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

    function _readPriceWad(address feed, uint48 maxAge) internal view returns (uint256 priceWad) {
        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) =
            IAggregatorV3V2(feed).latestRoundData();
        if (answer <= 0 || updatedAt == 0 || updatedAt > block.timestamp || answeredInRound < roundId) {
            revert OracleInvalid(feed);
        }
        if (block.timestamp - updatedAt > maxAge) revert OracleStale(feed, updatedAt);

        uint8 decimals = IAggregatorV3V2(feed).decimals();
        if (decimals > 18) revert OracleInvalid(feed);
        priceWad = uint256(answer) * (10 ** uint256(18 - decimals));
    }

    function _validateRoute(RouteConfig memory route) internal view {
        if (route.router == address(0) || route.usdcUsdFeed == address(0) || route.ethUsdFeed == address(0)) {
            revert ZeroAddress();
        }
        if (route.poolFee == 0 || route.poolFee >= 1_000_000) revert InvalidConfig();
        _requireContract(route.router);
        _requireContract(route.usdcUsdFeed);
        _requireContract(route.ethUsdFeed);
        if (IAggregatorV3V2(route.usdcUsdFeed).decimals() > 18 || IAggregatorV3V2(route.ethUsdFeed).decimals() > 18) {
            revert InvalidConfig();
        }
    }

    /// @dev Role rotation must preserve the same separation enforced by the
    ///      constructor. Admin and route-manager roles also remain contract-held
    ///      after deployment; the low-trust swapper may be an EOA or automation key.
    function _grantRole(bytes32 role, address account) internal override returns (bool) {
        if (
            (role == DEFAULT_ADMIN_ROLE && (hasRole(SWAPPER_ROLE, account) || hasRole(ROUTE_MANAGER_ROLE, account)))
                || (role == SWAPPER_ROLE
                    && (hasRole(DEFAULT_ADMIN_ROLE, account) || hasRole(ROUTE_MANAGER_ROLE, account)))
                || (role == ROUTE_MANAGER_ROLE
                    && (hasRole(DEFAULT_ADMIN_ROLE, account) || hasRole(SWAPPER_ROLE, account)))
        ) {
            revert RolesMustDiffer();
        }
        if (role == DEFAULT_ADMIN_ROLE || role == ROUTE_MANAGER_ROLE) _requireContract(account);
        return super._grantRole(role, account);
    }

    function _requireContract(address account) internal view {
        if (account.code.length == 0) revert NotAContract(account);
    }
}
