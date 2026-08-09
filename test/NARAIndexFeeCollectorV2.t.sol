// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {NARAIndexFeeCollectorV2, ISwapRouter02V2} from "../src/NARAIndexFeeCollectorV2.sol";

contract MockTokenCollectorV2 is ERC20 {
    uint8 private immutable _tokenDecimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _tokenDecimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _tokenDecimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockWethCollectorV2 is ERC20 {
    constructor() ERC20("Wrapped Ether", "WETH") {}

    receive() external payable {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        (bool ok,) = payable(msg.sender).call{value: amount}("");
        require(ok, "ETH_SEND");
    }
}

contract MockEngineCollectorV2 {
    IERC20 public immutable nara;
    uint256 public naraReceived;
    uint256 public ethReceived;
    bool public spendLess;

    constructor(IERC20 nara_) {
        nara = nara_;
    }

    function NARA() external view returns (address) {
        return address(nara);
    }

    function setSpendLess(bool spendLess_) external {
        spendLess = spendLess_;
    }

    function depositRewards(uint256 amount) external {
        uint256 amountToSpend = spendLess ? amount - 1 : amount;
        nara.transferFrom(msg.sender, address(this), amountToSpend);
        naraReceived += amountToSpend;
    }

    function notifyEthRewards() external payable {
        ethReceived += msg.value;
    }
}

contract MockAggregatorCollectorV2 {
    uint8 public immutable decimals;
    int256 public answer;
    uint256 public updatedAt;
    uint80 public roundId = 1;
    uint80 public answeredInRound = 1;

    constructor(uint8 decimals_, int256 answer_) {
        decimals = decimals_;
        answer = answer_;
        updatedAt = block.timestamp;
    }

    function setAnswer(int256 answer_) external {
        answer = answer_;
        updatedAt = block.timestamp;
        roundId++;
        answeredInRound = roundId;
    }

    function setRound(int256 answer_, uint256 updatedAt_, uint80 roundId_, uint80 answeredInRound_) external {
        answer = answer_;
        updatedAt = updatedAt_;
        roundId = roundId_;
        answeredInRound = answeredInRound_;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (roundId, answer, updatedAt, updatedAt, answeredInRound);
    }
}

contract MockRouterCollectorV2 {
    MockWethCollectorV2 public immutable weth;
    uint256 public outputAmount;
    uint256 public returnedAmount;
    bool public lieAboutReturn;
    bool public spendLess;

    constructor(MockWethCollectorV2 weth_) {
        weth = weth_;
    }

    function setOutputAmount(uint256 outputAmount_) external {
        outputAmount = outputAmount_;
    }

    function setSpendLess(bool spendLess_) external {
        spendLess = spendLess_;
    }

    function setReturnedAmount(uint256 returnedAmount_) external {
        returnedAmount = returnedAmount_;
        lieAboutReturn = true;
    }

    function exactInputSingle(ISwapRouter02V2.ExactInputSingleParams calldata params)
        external
        payable
        returns (uint256 amountOut)
    {
        uint256 amountToSpend = spendLess ? params.amountIn - 1 : params.amountIn;
        IERC20(params.tokenIn).transferFrom(msg.sender, address(this), amountToSpend);
        weth.mint(params.recipient, outputAmount);
        return lieAboutReturn ? returnedAmount : outputAmount;
    }
}

contract NARAIndexFeeCollectorV2Test is Test {
    address internal constant ADMIN = address(0xA11);
    address internal constant SWAPPER = address(0xB22);
    address internal constant ROUTE_MANAGER = address(0xC33);
    address internal constant ATTACKER = address(0xD44);
    address internal constant BASE_SEQUENCER_UPTIME_FEED = 0xBCF85224fc0756B9Fa45aA7892530B47e10b6433;
    uint48 internal constant USDC_MAX_ORACLE_AGE = 26 hours;
    uint48 internal constant ETH_MAX_ORACLE_AGE = 1 hours;

    MockTokenCollectorV2 internal nara;
    MockTokenCollectorV2 internal usdc;
    MockWethCollectorV2 internal weth;
    MockEngineCollectorV2 internal engine;
    MockAggregatorCollectorV2 internal usdcFeed;
    MockAggregatorCollectorV2 internal ethFeed;
    MockRouterCollectorV2 internal router;
    NARAIndexFeeCollectorV2 internal collector;

    function setUp() public {
        vm.warp(2 hours + 1);
        vm.etch(ADMIN, hex"00");
        vm.etch(ROUTE_MANAGER, hex"00");
        _mockSequencer(0, 1);
        nara = new MockTokenCollectorV2("NARA", "NARA", 18);
        usdc = new MockTokenCollectorV2("USD Coin", "USDC", 6);
        weth = new MockWethCollectorV2();
        engine = new MockEngineCollectorV2(IERC20(address(nara)));
        usdcFeed = new MockAggregatorCollectorV2(8, 1e8);
        ethFeed = new MockAggregatorCollectorV2(8, 2_000e8);
        router = new MockRouterCollectorV2(weth);
        vm.deal(address(weth), 100 ether);

        collector = _deploy(address(router), address(usdcFeed), address(ethFeed));
    }

    function _mockSequencer(int256 answer, uint256 startedAt) internal {
        vm.mockCall(
            BASE_SEQUENCER_UPTIME_FEED,
            abi.encodeWithSelector(bytes4(keccak256("latestRoundData()"))),
            abi.encode(uint80(1), answer, startedAt, block.timestamp, uint80(1))
        );
    }

    function _route(address router_, address usdcFeed_, address ethFeed_)
        internal
        pure
        returns (NARAIndexFeeCollectorV2.RouteConfig memory)
    {
        return NARAIndexFeeCollectorV2.RouteConfig({
            router: router_, usdcUsdFeed: usdcFeed_, ethUsdFeed: ethFeed_, poolFee: 500
        });
    }

    function _deploy(address router_, address usdcFeed_, address ethFeed_) internal returns (NARAIndexFeeCollectorV2) {
        return new NARAIndexFeeCollectorV2(
            address(engine),
            address(nara),
            address(usdc),
            address(weth),
            ADMIN,
            SWAPPER,
            ROUTE_MANAGER,
            _route(router_, usdcFeed_, ethFeed_),
            USDC_MAX_ORACLE_AGE,
            ETH_MAX_ORACLE_AGE,
            100
        );
    }

    function _deployWithOracleAges(uint48 maxUsdcAge, uint48 maxEthAge) internal returns (NARAIndexFeeCollectorV2) {
        return new NARAIndexFeeCollectorV2(
            address(engine),
            address(nara),
            address(usdc),
            address(weth),
            ADMIN,
            SWAPPER,
            ROUTE_MANAGER,
            _route(address(router), address(usdcFeed), address(ethFeed)),
            maxUsdcAge,
            maxEthAge,
            100
        );
    }

    function testRolesAreSeparatedAtConstruction() public view {
        assertTrue(collector.hasRole(collector.DEFAULT_ADMIN_ROLE(), ADMIN));
        assertTrue(collector.hasRole(collector.SWAPPER_ROLE(), SWAPPER));
        assertTrue(collector.hasRole(collector.ROUTE_MANAGER_ROLE(), ROUTE_MANAGER));
        assertFalse(collector.hasRole(collector.SWAPPER_ROLE(), ADMIN));
        assertFalse(collector.hasRole(collector.ROUTE_MANAGER_ROLE(), SWAPPER));
    }

    function testRoleRotationCannotCollapseSeparatedAuthorities() public {
        bytes32 adminRole = collector.DEFAULT_ADMIN_ROLE();
        bytes32 swapperRole = collector.SWAPPER_ROLE();
        bytes32 routeManagerRole = collector.ROUTE_MANAGER_ROLE();
        vm.startPrank(ADMIN);

        vm.expectRevert(NARAIndexFeeCollectorV2.RolesMustDiffer.selector);
        collector.grantRole(swapperRole, ADMIN);

        vm.expectRevert(NARAIndexFeeCollectorV2.RolesMustDiffer.selector);
        collector.grantRole(routeManagerRole, SWAPPER);

        vm.expectRevert(NARAIndexFeeCollectorV2.RolesMustDiffer.selector);
        collector.grantRole(adminRole, SWAPPER);

        vm.expectRevert(abi.encodeWithSelector(NARAIndexFeeCollectorV2.NotAContract.selector, ATTACKER));
        collector.grantRole(routeManagerRole, ATTACKER);

        vm.stopPrank();
    }

    function testConstructorRejectsCollapsedRoles() public {
        vm.expectRevert(NARAIndexFeeCollectorV2.RolesMustDiffer.selector);
        new NARAIndexFeeCollectorV2(
            address(engine),
            address(nara),
            address(usdc),
            address(weth),
            ADMIN,
            ADMIN,
            ROUTE_MANAGER,
            _route(address(router), address(usdcFeed), address(ethFeed)),
            USDC_MAX_ORACLE_AGE,
            ETH_MAX_ORACLE_AGE,
            100
        );
    }

    function testConstructorRequiresContractAdminAndRouteManager() public {
        vm.expectRevert(abi.encodeWithSelector(NARAIndexFeeCollectorV2.NotAContract.selector, ATTACKER));
        new NARAIndexFeeCollectorV2(
            address(engine),
            address(nara),
            address(usdc),
            address(weth),
            ATTACKER,
            SWAPPER,
            ROUTE_MANAGER,
            _route(address(router), address(usdcFeed), address(ethFeed)),
            USDC_MAX_ORACLE_AGE,
            ETH_MAX_ORACLE_AGE,
            100
        );
    }

    function testConstructorRejectsEngineBoundToDifferentNara() public {
        MockTokenCollectorV2 otherNara = new MockTokenCollectorV2("Other", "OTHER", 18);
        MockEngineCollectorV2 wrongEngine = new MockEngineCollectorV2(IERC20(address(otherNara)));

        vm.expectRevert(NARAIndexFeeCollectorV2.InvalidConfig.selector);
        new NARAIndexFeeCollectorV2(
            address(wrongEngine),
            address(nara),
            address(usdc),
            address(weth),
            ADMIN,
            SWAPPER,
            ROUTE_MANAGER,
            _route(address(router), address(usdcFeed), address(ethFeed)),
            USDC_MAX_ORACLE_AGE,
            ETH_MAX_ORACLE_AGE,
            100
        );
    }

    function testPerFeedOracleAgesAreImmutable() public view {
        assertEq(collector.maxUsdcOracleAge(), USDC_MAX_ORACLE_AGE);
        assertEq(collector.maxEthOracleAge(), ETH_MAX_ORACLE_AGE);
    }

    function testConstructorRejectsInvalidPerFeedOracleAges() public {
        uint48 minimum = collector.MIN_ORACLE_AGE();
        uint48 maximum = collector.MAX_ORACLE_AGE();

        vm.expectRevert(NARAIndexFeeCollectorV2.InvalidConfig.selector);
        _deployWithOracleAges(minimum - 1, ETH_MAX_ORACLE_AGE);

        vm.expectRevert(NARAIndexFeeCollectorV2.InvalidConfig.selector);
        _deployWithOracleAges(maximum + 1, ETH_MAX_ORACLE_AGE);

        vm.expectRevert(NARAIndexFeeCollectorV2.InvalidConfig.selector);
        _deployWithOracleAges(USDC_MAX_ORACLE_AGE, minimum - 1);

        vm.expectRevert(NARAIndexFeeCollectorV2.InvalidConfig.selector);
        _deployWithOracleAges(USDC_MAX_ORACLE_AGE, maximum + 1);
    }

    function testOracleMinimumUsesBothFeedsAndImmutableSlippage() public view {
        uint256 minimumOut = collector.minimumWethOut(1_000e6);
        assertEq(minimumOut, 0.495 ether);
    }

    function testConvertUsdcUsesOracleMinimumAndAtomicallyNotifiesEngine() public {
        usdc.mint(address(collector), 1_000e6);
        router.setOutputAmount(0.5 ether);

        vm.prank(SWAPPER);
        uint256 actualOut = collector.convertUsdcAndNotifyEth(1_000e6);

        assertEq(actualOut, 0.5 ether);
        assertEq(engine.ethReceived(), 0.5 ether);
        assertEq(usdc.balanceOf(address(collector)), 0);
        assertEq(weth.balanceOf(address(collector)), 0);
        assertEq(usdc.allowance(address(collector), address(router)), 0);
    }

    function testCallerCannotChooseNearZeroMinimumOutput() public {
        usdc.mint(address(collector), 1_000e6);
        router.setOutputAmount(1);

        vm.prank(SWAPPER);
        vm.expectRevert(abi.encodeWithSelector(NARAIndexFeeCollectorV2.RouteOutputTooLow.selector, 0.495 ether, 1));
        collector.convertUsdcAndNotifyEth(1_000e6);

        assertEq(usdc.balanceOf(address(collector)), 1_000e6);
        assertEq(engine.ethReceived(), 0);
    }

    function testConvertUsesExactWethBalanceDeltaInsteadOfRouterReturnValue() public {
        usdc.mint(address(collector), 1_000e6);
        router.setOutputAmount(1);
        router.setReturnedAmount(100 ether);

        vm.prank(SWAPPER);
        vm.expectRevert(abi.encodeWithSelector(NARAIndexFeeCollectorV2.RouteOutputTooLow.selector, 0.495 ether, 1));
        collector.convertUsdcAndNotifyEth(1_000e6);

        assertEq(usdc.balanceOf(address(collector)), 1_000e6);
        assertEq(weth.balanceOf(address(collector)), 0);
        assertEq(engine.ethReceived(), 0);
    }

    function testConvertRejectsPartialInputConsumption() public {
        usdc.mint(address(collector), 1_000e6);
        router.setOutputAmount(0.5 ether);
        router.setSpendLess(true);

        vm.prank(SWAPPER);
        vm.expectRevert(
            abi.encodeWithSelector(NARAIndexFeeCollectorV2.RouteInputMismatch.selector, 1_000e6, 1_000e6 - 1)
        );
        collector.convertUsdcAndNotifyEth(1_000e6);
    }

    function testStaleEthOracleStopsBeforeApprovalOrSwap() public {
        vm.warp(3 hours);
        usdc.mint(address(collector), 1_000e6);
        usdcFeed.setRound(1e8, block.timestamp, 2, 2);
        ethFeed.setRound(2_000e8, block.timestamp - 2 hours, 2, 2);

        vm.prank(SWAPPER);
        vm.expectRevert(
            abi.encodeWithSelector(
                NARAIndexFeeCollectorV2.OracleStale.selector, address(ethFeed), block.timestamp - 2 hours
            )
        );
        collector.convertUsdcAndNotifyEth(1_000e6);

        assertEq(usdc.allowance(address(collector), address(router)), 0);
        assertEq(usdc.balanceOf(address(collector)), 1_000e6);
    }

    function testDailyUsdcHeartbeatAgeAcceptedWhileEthIsFresh() public {
        vm.warp(30 hours);
        usdcFeed.setRound(1e8, block.timestamp - 25 hours, 2, 2);
        ethFeed.setRound(2_000e8, block.timestamp, 2, 2);

        assertEq(collector.minimumWethOut(1_000e6), 0.495 ether);
    }

    function testStaleUsdcOracleRejectedIndependently() public {
        vm.warp(30 hours);
        usdcFeed.setRound(1e8, block.timestamp - USDC_MAX_ORACLE_AGE - 1, 2, 2);
        ethFeed.setRound(2_000e8, block.timestamp, 2, 2);

        vm.expectRevert(
            abi.encodeWithSelector(
                NARAIndexFeeCollectorV2.OracleStale.selector,
                address(usdcFeed),
                block.timestamp - USDC_MAX_ORACLE_AGE - 1
            )
        );
        collector.minimumWethOut(1_000e6);
    }

    function testEachOracleAgeBoundaryIsAccepted() public {
        vm.warp(30 hours);
        usdcFeed.setRound(1e8, block.timestamp - USDC_MAX_ORACLE_AGE, 2, 2);
        ethFeed.setRound(2_000e8, block.timestamp - ETH_MAX_ORACLE_AGE, 2, 2);

        assertEq(collector.minimumWethOut(1_000e6), 0.495 ether);
    }

    function testInvalidOracleRoundStopsConversion() public {
        usdcFeed.setRound(1e8, block.timestamp, 3, 2);
        vm.expectRevert(abi.encodeWithSelector(NARAIndexFeeCollectorV2.OracleInvalid.selector, address(usdcFeed)));
        collector.minimumWethOut(1_000e6);
    }

    function testUsdcPriceBoundsStopBadFeedConfiguration() public {
        usdcFeed.setAnswer(50_000_000);
        vm.expectRevert(
            abi.encodeWithSelector(
                NARAIndexFeeCollectorV2.OraclePriceOutOfBounds.selector, address(usdcFeed), 0.5 ether
            )
        );
        collector.minimumWethOut(1_000e6);
    }

    function testEthPriceBoundsAcceptExactBoundaries() public {
        ethFeed.setAnswer(100e8);
        assertEq(collector.minimumWethOut(1_000e6), 9.9 ether);

        ethFeed.setAnswer(100_000e8);
        assertEq(collector.minimumWethOut(1_000e6), 0.0099 ether);
    }

    function testEthPriceBoundsRejectOutOfRangeFeedAnswers() public {
        ethFeed.setAnswer(99e8);
        vm.expectRevert(
            abi.encodeWithSelector(NARAIndexFeeCollectorV2.OraclePriceOutOfBounds.selector, address(ethFeed), 99 ether)
        );
        collector.minimumWethOut(1_000e6);

        ethFeed.setAnswer(100_001e8);
        vm.expectRevert(
            abi.encodeWithSelector(
                NARAIndexFeeCollectorV2.OraclePriceOutOfBounds.selector, address(ethFeed), 100_001 ether
            )
        );
        collector.minimumWethOut(1_000e6);
    }

    function testSequencerOutageAndRecoveryGracePeriodStopConversion() public {
        _mockSequencer(1, block.timestamp);
        vm.expectRevert(NARAIndexFeeCollectorV2.SequencerDown.selector);
        collector.minimumWethOut(1_000e6);

        _mockSequencer(0, block.timestamp);
        vm.expectRevert(
            abi.encodeWithSelector(NARAIndexFeeCollectorV2.SequencerGracePeriodNotElapsed.selector, block.timestamp)
        );
        collector.minimumWethOut(1_000e6);

        vm.warp(block.timestamp + 1 hours + 1);
        usdcFeed.setAnswer(1e8);
        ethFeed.setAnswer(2_000e8);
        assertEq(collector.minimumWethOut(1_000e6), 0.495 ether);
    }

    function testOnlySwapperCanConvertOrDeposit() public {
        usdc.mint(address(collector), 1_000e6);
        nara.mint(address(collector), 1 ether);

        vm.prank(ATTACKER);
        vm.expectRevert();
        collector.convertUsdcAndNotifyEth(1_000e6);

        vm.prank(ATTACKER);
        vm.expectRevert();
        collector.depositNaraRewards(1 ether);
    }

    function testDepositNaraRewards() public {
        nara.mint(address(collector), 25 ether);
        vm.prank(SWAPPER);
        collector.depositNaraRewards(25 ether);

        assertEq(engine.naraReceived(), 25 ether);
        assertEq(nara.balanceOf(address(collector)), 0);
        assertEq(nara.allowance(address(collector), address(engine)), 0);
    }

    function testDepositRejectsPartialEngineConsumption() public {
        nara.mint(address(collector), 25 ether);
        engine.setSpendLess(true);

        vm.prank(SWAPPER);
        vm.expectRevert(
            abi.encodeWithSelector(NARAIndexFeeCollectorV2.EngineInputMismatch.selector, 25 ether, 25 ether - 1)
        );
        collector.depositNaraRewards(25 ether);

        assertEq(nara.balanceOf(address(collector)), 25 ether);
        assertEq(engine.naraReceived(), 0);
        assertEq(nara.allowance(address(collector), address(engine)), 0);
    }

    function testUnwrapWethAndNotifyEth() public {
        weth.mint(address(collector), 2 ether);
        vm.prank(SWAPPER);
        collector.unwrapWethAndNotifyEth(2 ether);

        assertEq(engine.ethReceived(), 2 ether);
        assertEq(weth.balanceOf(address(collector)), 0);
    }

    function testNotifyNativeEth() public {
        vm.deal(address(collector), 3 ether);
        vm.prank(SWAPPER);
        collector.notifyNativeEth(3 ether);
        assertEq(engine.ethReceived(), 3 ether);
    }

    function testRouteUpdateRequiresIndependentAdminApprovalAfterEta() public {
        MockRouterCollectorV2 nextRouter = new MockRouterCollectorV2(weth);
        NARAIndexFeeCollectorV2.RouteConfig memory next =
            _route(address(nextRouter), address(usdcFeed), address(ethFeed));

        vm.prank(ATTACKER);
        vm.expectRevert();
        collector.proposeRoute(next);

        vm.prank(ROUTE_MANAGER);
        collector.proposeRoute(next);

        uint48 eta = uint48(block.timestamp + collector.ROUTE_UPDATE_DELAY());
        vm.prank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(NARAIndexFeeCollectorV2.RouteUpdateNotReady.selector, eta));
        collector.executeRoute();

        vm.warp(block.timestamp + collector.ROUTE_UPDATE_DELAY());
        vm.prank(ATTACKER);
        vm.expectRevert();
        collector.executeRoute();

        vm.prank(ADMIN);
        collector.executeRoute();

        (address activeRouter,,,) = collector.routeConfig();
        assertEq(activeRouter, address(nextRouter));
        assertEq(collector.maxUsdcOracleAge(), USDC_MAX_ORACLE_AGE);
        assertEq(collector.maxEthOracleAge(), ETH_MAX_ORACLE_AGE);
    }

    function testRouteManagerCanCancelPendingMigration() public {
        MockRouterCollectorV2 nextRouter = new MockRouterCollectorV2(weth);
        vm.prank(ROUTE_MANAGER);
        collector.proposeRoute(_route(address(nextRouter), address(usdcFeed), address(ethFeed)));

        vm.prank(ROUTE_MANAGER);
        collector.cancelRoute();

        vm.warp(block.timestamp + collector.ROUTE_UPDATE_DELAY());
        vm.prank(ADMIN);
        vm.expectRevert(NARAIndexFeeCollectorV2.NoPendingRoute.selector);
        collector.executeRoute();
    }

    function testAdminGuardianCanCancelRouteManagerProposal() public {
        MockRouterCollectorV2 nextRouter = new MockRouterCollectorV2(weth);
        vm.prank(ROUTE_MANAGER);
        collector.proposeRoute(_route(address(nextRouter), address(usdcFeed), address(ethFeed)));

        vm.prank(ADMIN);
        collector.cancelRoute();

        vm.warp(block.timestamp + collector.ROUTE_UPDATE_DELAY());
        vm.prank(ADMIN);
        vm.expectRevert(NARAIndexFeeCollectorV2.NoPendingRoute.selector);
        collector.executeRoute();
    }

    function testRevokingCompromisedProposerInvalidatesPendingRoute() public {
        MockRouterCollectorV2 nextRouter = new MockRouterCollectorV2(weth);
        vm.prank(ROUTE_MANAGER);
        collector.proposeRoute(_route(address(nextRouter), address(usdcFeed), address(ethFeed)));

        bytes32 routeManagerRole = collector.ROUTE_MANAGER_ROLE();
        vm.prank(ADMIN);
        collector.revokeRole(routeManagerRole, ROUTE_MANAGER);

        vm.warp(block.timestamp + collector.ROUTE_UPDATE_DELAY());
        vm.prank(ADMIN);
        vm.expectRevert(
            abi.encodeWithSelector(NARAIndexFeeCollectorV2.PendingRouteProposerRevoked.selector, ROUTE_MANAGER)
        );
        collector.executeRoute();
    }

    function testCollectorHasNoArbitraryTokenOrEthSweep() public {
        (bool tokenSweepOk,) = address(collector)
            .call(abi.encodeWithSignature("sweepToken(address,address,uint256)", address(usdc), ATTACKER, 1));
        (bool ethSweepOk,) = address(collector).call(abi.encodeWithSignature("sweepETH(address,uint256)", ATTACKER, 1));
        assertFalse(tokenSweepOk);
        assertFalse(ethSweepOk);
    }
}
