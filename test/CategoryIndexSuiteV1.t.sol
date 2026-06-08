// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {
    CategoryIndexVaultV1,
    CategoryIndexFactoryV1,
    IndexZapRouterV1,
    IndexLensV1
} from "../src/CategoryIndexSuiteV1.sol";
import {NARAIndexFeeCollectorV1} from "../src/NARAIndexFeeCollectorV1.sol";

contract MockERC20 is ERC20 {
    uint8 private immutable _decimals;

    constructor(string memory n, string memory s, uint8 d) ERC20(n, s) {
        _decimals = d;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockFeeOnTransferERC20 is MockERC20 {
    constructor() MockERC20("Fee Token", "FEE", 18) {}

    function transfer(address to, uint256 amount) public override returns (bool) {
        _transferWithFee(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        address spender = msg.sender;
        _spendAllowance(from, spender, amount);
        _transferWithFee(from, to, amount);
        return true;
    }

    function _transferWithFee(address from, address to, uint256 amount) internal {
        uint256 fee = amount / 10;
        _update(from, to, amount - fee);
        if (fee != 0) _update(from, address(0), fee);
    }
}

contract MockBlockingERC20 is MockERC20 {
    bool public transfersBlocked;

    constructor() MockERC20("Blocking Token", "BLOCK", 18) {}

    function setTransfersBlocked(bool blocked) external {
        transfersBlocked = blocked;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (transfersBlocked) revert("blocked");
        return super.transfer(to, amount);
    }
}

contract MockSwapExecutor {
    mapping(address => mapping(address => uint256)) public rate1e18;

    function setRate(address tokenIn, address tokenOut, uint256 rate) external {
        rate1e18[tokenIn][tokenOut] = rate;
    }

    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minAmountOut)
        external
        returns (uint256 amountOut)
    {
        amountOut = amountIn * rate1e18[tokenIn][tokenOut] / 1e18;
        require(amountOut >= minAmountOut, "slippage");
        require(IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn), "transferFrom failed");
        require(IERC20(tokenOut).transfer(msg.sender, amountOut), "transfer failed");
    }
}

contract MockWETH is MockERC20 {
    constructor() MockERC20("Wrapped Ether", "WETH", 18) {}

    receive() external payable {
        deposit();
    }

    function deposit() public payable {
        _mint(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "eth transfer failed");
    }
}

contract MockNARAEngine {
    IERC20 public immutable nara;
    uint256 public ethRewards;
    uint256 public naraRewards;

    constructor(IERC20 nara_) {
        nara = nara_;
    }

    function notifyEthRewards() external payable {
        ethRewards += msg.value;
    }

    function depositRewards(uint256 amount) external {
        require(nara.transferFrom(msg.sender, address(this), amount), "nara transfer failed");
        naraRewards += amount;
    }
}

contract MockFeeVault is ERC20 {
    IERC20 public immutable asset;

    constructor(IERC20 asset_) ERC20("Mock Fee Vault", "MFV") {
        asset = asset_;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function redeemInKind(uint256 sharesIn, uint256[] calldata minAmountsOut, address receiver)
        external
        returns (uint256[] memory amountsOut)
    {
        require(minAmountsOut.length == 1, "length");
        amountsOut = new uint256[](1);
        amountsOut[0] = sharesIn;
        require(amountsOut[0] >= minAmountsOut[0], "slippage");
        _burn(msg.sender, sharesIn);
        require(asset.transfer(receiver, sharesIn), "transfer failed");
    }
}

contract CategoryIndexSuiteV1Test is Test {
    MockERC20 usdc;
    MockERC20 tokenA;
    MockERC20 tokenB;
    MockERC20 tokenC;
    CategoryIndexFactoryV1 factory;
    IndexZapRouterV1 router;
    IndexLensV1 lens;
    MockSwapExecutor executor;

    address alice = address(0xA11CE);
    address feeRecipient = address(0xFEE);
    address vault;
    bytes32 constant AI = keccak256("AI");

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        tokenA = new MockERC20("AI Token A", "AIA", 18);
        tokenB = new MockERC20("AI Token B", "AIB", 18);
        tokenC = new MockERC20("AI Token C", "AIC", 18);
        factory = new CategoryIndexFactoryV1();
        executor = new MockSwapExecutor();
        lens = new IndexLensV1();
        factory.setAssetAllowed(address(tokenA), true);
        factory.setAssetAllowed(address(tokenB), true);
        factory.setAssetAllowed(address(tokenC), true);

        address[] memory executors = new address[](1);
        executors[0] = address(executor);
        router = new IndexZapRouterV1(address(usdc), address(factory), executors);
        router.setAllowedSelector(address(executor), MockSwapExecutor.swap.selector, true);

        tokenA.mint(address(this), 1_000_000 ether);
        tokenB.mint(address(this), 1_000_000 ether);
        tokenC.mint(address(this), 1_000_000 ether);
        tokenA.mint(address(executor), 1_000_000 ether);
        tokenB.mint(address(executor), 1_000_000 ether);
        tokenC.mint(address(executor), 1_000_000 ether);
        usdc.mint(alice, 1_000_000e6);
        usdc.mint(address(executor), 1_000_000e6);

        executor.setRate(address(usdc), address(tokenA), 1e30);
        executor.setRate(address(usdc), address(tokenB), 1e30);
        executor.setRate(address(usdc), address(tokenC), 1e30);
        executor.setRate(address(tokenA), address(usdc), 1e6);
        executor.setRate(address(tokenB), address(usdc), 1e6);
        executor.setRate(address(tokenC), address(usdc), 1e6);

        vault = _createVault(20, 20);
    }

    function _assets() internal view returns (address[] memory a) {
        a = new address[](3);
        a[0] = address(tokenA);
        a[1] = address(tokenB);
        a[2] = address(tokenC);
    }

    function _weights() internal pure returns (uint256[] memory w) {
        w = new uint256[](3);
        w[0] = 4000;
        w[1] = 3500;
        w[2] = 2500;
    }

    function _seedAmounts() internal pure returns (uint256[] memory s) {
        s = new uint256[](3);
        s[0] = 400 ether;
        s[1] = 350 ether;
        s[2] = 250 ether;
    }

    function _createVault(uint256 mintFeeBps, uint256 redeemFeeBps) internal returns (address created) {
        address[] memory a = _assets();
        uint256[] memory w = _weights();
        uint256[] memory s = _seedAmounts();
        for (uint256 i; i < a.length; i++) {
            IERC20(a[i]).approve(address(factory), s[i]);
        }
        created = factory.createSeededVault(
            "NARA AI Index",
            "NAI",
            "AI",
            AI,
            CategoryIndexVaultV1.RiskTier.Sector,
            a,
            w,
            s,
            mintFeeBps,
            redeemFeeBps,
            feeRecipient,
            address(this)
        );
    }

    function testFactoryCreatesAndSeedsVault() public view {
        assertTrue(factory.isVault(vault));
        assertTrue(factory.isVaultActive(vault));
        assertEq(factory.vaultByCategoryId(AI), vault);
        assertEq(factory.allVaultsLength(), 1);
        CategoryIndexVaultV1 v = CategoryIndexVaultV1(vault);
        assertTrue(v.isSeeded());
        assertEq(v.categoryId(), AI);
        assertEq(v.totalSupply(), 1e18);
        assertEq(tokenA.balanceOf(vault), 400 ether);
        assertEq(tokenB.balanceOf(vault), 350 ether);
        assertEq(tokenC.balanceOf(vault), 250 ether);
    }

    function testFactoryRejectsFeeOnTransferSeedAsset() public {
        MockFeeOnTransferERC20 feeToken = new MockFeeOnTransferERC20();
        factory.setAssetAllowed(address(feeToken), true);
        feeToken.mint(address(this), 100 ether);
        tokenA.approve(address(factory), 100 ether);
        feeToken.approve(address(factory), 100 ether);

        address[] memory a = new address[](2);
        a[0] = address(tokenA);
        a[1] = address(feeToken);
        uint256[] memory w = new uint256[](2);
        w[0] = 5_000;
        w[1] = 5_000;
        uint256[] memory s = new uint256[](2);
        s[0] = 100 ether;
        s[1] = 100 ether;

        vm.expectRevert();
        factory.createSeededVault(
            "Unsafe",
            "UNSAFE",
            "Unsafe",
            keccak256("UNSAFE"),
            CategoryIndexVaultV1.RiskTier.HighRisk,
            a,
            w,
            s,
            0,
            0,
            address(0),
            address(this)
        );
    }

    function testFactoryRejectsUnauthorizedCreator() public {
        address[] memory a = _assets();
        uint256[] memory w = _weights();
        uint256[] memory s = _seedAmounts();

        vm.prank(alice);
        vm.expectRevert();
        factory.createSeededVault(
            "Unauthorized",
            "NOPE",
            "Unauthorized",
            keccak256("UNAUTHORIZED"),
            CategoryIndexVaultV1.RiskTier.Sector,
            a,
            w,
            s,
            0,
            0,
            address(0),
            alice
        );
    }

    function testFactoryRejectsDuplicateCategoryId() public {
        address[] memory a = _assets();
        uint256[] memory w = _weights();
        uint256[] memory s = _seedAmounts();
        for (uint256 i; i < a.length; i++) {
            IERC20(a[i]).approve(address(factory), s[i]);
        }

        vm.expectRevert(CategoryIndexFactoryV1.CategoryExists.selector);
        factory.createSeededVault(
            "Duplicate",
            "DUP",
            "Duplicate",
            AI,
            CategoryIndexVaultV1.RiskTier.Sector,
            a,
            w,
            s,
            0,
            0,
            address(0),
            address(this)
        );
    }

    function testFactoryCanDeactivateVault() public {
        factory.setVaultActive(vault, false);

        assertFalse(factory.isVaultActive(vault));
        assertTrue(factory.isVault(vault));
    }

    function testRedeemRevertsWhenComponentTransferFails() public {
        MockBlockingERC20 blocker = new MockBlockingERC20();
        factory.setAssetAllowed(address(blocker), true);
        tokenA.mint(address(this), 100 ether);
        blocker.mint(address(this), 100 ether);
        tokenA.approve(address(factory), 100 ether);
        blocker.approve(address(factory), 100 ether);

        address[] memory a = new address[](2);
        a[0] = address(tokenA);
        a[1] = address(blocker);
        uint256[] memory w = new uint256[](2);
        w[0] = 5_000;
        w[1] = 5_000;
        uint256[] memory s = new uint256[](2);
        s[0] = 100 ether;
        s[1] = 100 ether;

        address partialVault = factory.createSeededVault(
            "Partial",
            "PART",
            "Partial",
            keccak256("PARTIAL"),
            CategoryIndexVaultV1.RiskTier.Sector,
            a,
            w,
            s,
            0,
            0,
            address(0),
            address(this)
        );

        blocker.setTransfersBlocked(true);
        uint256[] memory minOut = new uint256[](2);
        minOut[0] = 1;
        minOut[1] = 0;
        uint256 tokenABefore = tokenA.balanceOf(address(this));

        vm.expectRevert(bytes("blocked"));
        CategoryIndexVaultV1(partialVault).redeemInKind(0.5e18, minOut, address(this));

        assertEq(tokenA.balanceOf(address(this)), tokenABefore);
        assertEq(blocker.balanceOf(partialVault), 100 ether);
    }

    function testQuoteMint() public view {
        uint256[] memory r = CategoryIndexVaultV1(vault).quoteMint(1e17);
        assertEq(r[0], 40 ether);
        assertEq(r[1], 35 ether);
        assertEq(r[2], 25 ether);
    }

    function testMintExactSharesWithFee() public {
        uint256 sharesWanted = 1e17;
        uint256[] memory r = CategoryIndexVaultV1(vault).quoteMint(sharesWanted);
        tokenA.mint(alice, r[0]);
        tokenB.mint(alice, r[1]);
        tokenC.mint(alice, r[2]);

        vm.startPrank(alice);
        tokenA.approve(vault, r[0]);
        tokenB.approve(vault, r[1]);
        tokenC.approve(vault, r[2]);
        CategoryIndexVaultV1(vault).mintExactShares(sharesWanted, r, alice);
        vm.stopPrank();

        uint256 feeShares = sharesWanted * 20 / 10_000;
        assertEq(CategoryIndexVaultV1(vault).balanceOf(alice), sharesWanted - feeShares);
        assertEq(CategoryIndexVaultV1(vault).balanceOf(feeRecipient), feeShares);
    }

    function testRedeemInKindWithFee() public {
        uint256 sharesIn = 1e17;
        uint256[] memory minOut = new uint256[](3);
        assertTrue(CategoryIndexVaultV1(vault).transfer(alice, sharesIn));

        vm.prank(alice);
        CategoryIndexVaultV1(vault).redeemInKind(sharesIn, minOut, alice);

        uint256 feeShares = sharesIn * 20 / 10_000;
        uint256 netShares = sharesIn - feeShares;
        assertEq(tokenA.balanceOf(alice), 400 ether * netShares / 1e18);
        assertEq(tokenB.balanceOf(alice), 350 ether * netShares / 1e18);
        assertEq(tokenC.balanceOf(alice), 250 ether * netShares / 1e18);
        assertEq(CategoryIndexVaultV1(vault).balanceOf(feeRecipient), feeShares);
    }

    function testDepositUSDCThroughRouter() public {
        uint256 sharesWanted = 1e17;
        uint256[] memory r = CategoryIndexVaultV1(vault).quoteMint(sharesWanted);
        IndexZapRouterV1.SwapCall[] memory swaps = new IndexZapRouterV1.SwapCall[](3);
        swaps[0] = _swap(address(usdc), address(tokenA), 40e6, r[0]);
        swaps[1] = _swap(address(usdc), address(tokenB), 35e6, r[1]);
        swaps[2] = _swap(address(usdc), address(tokenC), 25e6, r[2]);

        vm.startPrank(alice);
        usdc.approve(address(router), 100e6);
        uint256 out = router.depositUSDC(vault, 100e6, sharesWanted, 99e15, swaps, block.timestamp + 1 hours);
        vm.stopPrank();

        uint256 feeShares = sharesWanted * 20 / 10_000;
        assertEq(out, sharesWanted - feeShares);
        assertEq(CategoryIndexVaultV1(vault).balanceOf(alice), out);
    }

    function testDepositRejectsUnknownVault() public {
        IndexZapRouterV1.SwapCall[] memory swaps = new IndexZapRouterV1.SwapCall[](0);
        vm.startPrank(alice);
        usdc.approve(address(router), 100e6);
        vm.expectRevert(IndexZapRouterV1.InvalidVault.selector);
        router.depositUSDC(address(0x1234), 100e6, 1e17, 0, swaps, block.timestamp + 1 hours);
        vm.stopPrank();
    }

    function testDepositRejectsInactiveVault() public {
        factory.setVaultActive(vault, false);
        IndexZapRouterV1.SwapCall[] memory swaps = new IndexZapRouterV1.SwapCall[](0);

        vm.startPrank(alice);
        usdc.approve(address(router), 100e6);
        vm.expectRevert(IndexZapRouterV1.InvalidVault.selector);
        router.depositUSDC(vault, 100e6, 1e17, 0, swaps, block.timestamp + 1 hours);
        vm.stopPrank();
    }

    function testDepositRejectsNonVaultOutputToken() public {
        MockERC20 bad = new MockERC20("Bad", "BAD", 18);
        bad.mint(address(executor), 1000 ether);
        executor.setRate(address(usdc), address(bad), 1e30);
        IndexZapRouterV1.SwapCall[] memory swaps = new IndexZapRouterV1.SwapCall[](1);
        swaps[0] = _swap(address(usdc), address(bad), 10e6, 10 ether);
        vm.startPrank(alice);
        usdc.approve(address(router), 10e6);
        vm.expectRevert(IndexZapRouterV1.TokenNotInVault.selector);
        router.depositUSDC(vault, 10e6, 1e16, 0, swaps, block.timestamp + 1 hours);
        vm.stopPrank();
    }

    function testRedeemToUSDCThroughRouter() public {
        uint256 sharesIn = 1e17;
        assertTrue(CategoryIndexVaultV1(vault).transfer(alice, sharesIn));
        uint256[] memory minOut = new uint256[](3);
        uint256 feeShares = sharesIn * 20 / 10_000;
        uint256 netShares = sharesIn - feeShares;
        uint256 outA = 400 ether * netShares / 1e18;
        uint256 outB = 350 ether * netShares / 1e18;
        uint256 outC = 250 ether * netShares / 1e18;

        IndexZapRouterV1.SwapCall[] memory swaps = new IndexZapRouterV1.SwapCall[](3);
        swaps[0] = _swap(address(tokenA), address(usdc), outA, outA * 1e6 / 1e18);
        swaps[1] = _swap(address(tokenB), address(usdc), outB, outB * 1e6 / 1e18);
        swaps[2] = _swap(address(tokenC), address(usdc), outC, outC * 1e6 / 1e18);

        vm.startPrank(alice);
        CategoryIndexVaultV1(vault).approve(address(router), sharesIn);
        uint256 usdcOut = router.redeemToUSDC(vault, sharesIn, 99e6, minOut, swaps, block.timestamp + 1 hours);
        vm.stopPrank();

        assertGt(usdcOut, 99e6);
    }

    function testRedeemToUSDCCannotSpendRouterDust() public {
        uint256 sharesIn = 1e17;
        assertTrue(CategoryIndexVaultV1(vault).transfer(alice, sharesIn));
        uint256[] memory minOut = new uint256[](3);
        (uint256[] memory amountsOut,,) = CategoryIndexVaultV1(vault).quoteRedeem(sharesIn);

        assertTrue(tokenA.transfer(address(router), 100 ether));

        IndexZapRouterV1.SwapCall[] memory swaps = new IndexZapRouterV1.SwapCall[](1);
        swaps[0] = _swap(address(tokenA), address(usdc), amountsOut[0] + 1 ether, 0);

        vm.startPrank(alice);
        CategoryIndexVaultV1(vault).approve(address(router), sharesIn);
        vm.expectRevert(IndexZapRouterV1.BalanceInsufficient.selector);
        router.redeemToUSDC(vault, sharesIn, 0, minOut, swaps, block.timestamp + 1 hours);
        vm.stopPrank();
    }

    function testRouterRejectsUnapprovedSelector() public {
        router.setAllowedSelector(address(executor), MockSwapExecutor.swap.selector, false);
        uint256[] memory r = CategoryIndexVaultV1(vault).quoteMint(1e17);
        IndexZapRouterV1.SwapCall[] memory swaps = new IndexZapRouterV1.SwapCall[](1);
        swaps[0] = _swap(address(usdc), address(tokenA), 40e6, r[0]);

        vm.startPrank(alice);
        usdc.approve(address(router), 40e6);
        vm.expectRevert(IndexZapRouterV1.ExecutorNotAllowed.selector);
        router.depositUSDC(vault, 40e6, 1e17, 0, swaps, block.timestamp + 1 hours);
        vm.stopPrank();
    }

    function testRouterRejectsZeroMinAmountOut() public {
        IndexZapRouterV1.SwapCall[] memory swaps = new IndexZapRouterV1.SwapCall[](1);
        swaps[0] = _swap(address(usdc), address(tokenA), 40e6, 0);

        vm.startPrank(alice);
        usdc.approve(address(router), 40e6);
        vm.expectRevert(IndexZapRouterV1.ZeroAmount.selector);
        router.depositUSDC(vault, 40e6, 1e17, 0, swaps, block.timestamp + 1 hours);
        vm.stopPrank();
    }

    function testRouterSweepTokenIsAdminOnly() public {
        assertTrue(tokenA.transfer(address(router), 5 ether));

        vm.prank(alice);
        vm.expectRevert();
        router.sweepToken(address(tokenA), alice, 1 ether);

        uint256 beforeBalance = tokenA.balanceOf(alice);
        router.sweepToken(address(tokenA), alice, 1 ether);

        assertEq(tokenA.balanceOf(alice) - beforeBalance, 1 ether);
        assertEq(tokenA.balanceOf(address(router)), 4 ether);
    }

    function testLensVaultInfo() public view {
        IndexLensV1.VaultInfo memory info = lens.getVaultInfo(vault);
        assertEq(info.vault, vault);
        assertEq(info.name, "NARA AI Index");
        assertEq(info.symbol, "NAI");
        assertEq(info.category, "AI");
        assertEq(info.categoryId, AI);
        assertTrue(info.seeded);
        assertEq(info.assets.length, 3);
    }

    function _swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut)
        internal
        view
        returns (IndexZapRouterV1.SwapCall memory call_)
    {
        bytes memory data = abi.encodeWithSelector(MockSwapExecutor.swap.selector, tokenIn, tokenOut, amountIn, minOut);
        call_ = IndexZapRouterV1.SwapCall({
            executor: address(executor),
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            amountIn: amountIn,
            minAmountOut: minOut,
            data: data
        });
    }
}

contract NARAIndexFeeCollectorV1Test is Test {
    MockERC20 asset;
    MockERC20 nara;
    MockERC20 badOutput;
    MockWETH weth;
    MockSwapExecutor executor;
    MockNARAEngine engine;
    MockFeeVault feeVault;
    NARAIndexFeeCollectorV1 collector;

    function setUp() public {
        asset = new MockERC20("Fee Asset", "FEEA", 18);
        nara = new MockERC20("NARA", "NARA", 18);
        badOutput = new MockERC20("Bad Output", "BAD", 18);
        weth = new MockWETH();
        executor = new MockSwapExecutor();
        engine = new MockNARAEngine(IERC20(address(nara)));

        address[] memory executors = new address[](1);
        executors[0] = address(executor);
        collector = new NARAIndexFeeCollectorV1(address(engine), address(nara), address(weth), address(this), executors);
        collector.setAllowedSelector(address(executor), MockSwapExecutor.swap.selector, true);
        feeVault = new MockFeeVault(IERC20(address(asset)));
        collector.setAllowedVault(address(feeVault), true);

        asset.mint(address(collector), 1_000 ether);
        asset.mint(address(feeVault), 100 ether);
        feeVault.mint(address(collector), 100 ether);
        nara.mint(address(executor), 1_000 ether);
        badOutput.mint(address(executor), 1_000 ether);
        executor.setRate(address(asset), address(nara), 1e18);
        executor.setRate(address(asset), address(badOutput), 1e18);
    }

    function testFeeCollectorRedeemsAllowedVault() public {
        uint256[] memory minOut = new uint256[](1);
        minOut[0] = 10 ether;
        uint256 beforeBalance = asset.balanceOf(address(collector));

        collector.redeemIndexFeeShares(address(feeVault), 10 ether, minOut);

        assertEq(asset.balanceOf(address(collector)) - beforeBalance, 10 ether);
        assertEq(feeVault.balanceOf(address(collector)), 90 ether);
    }

    function testFeeCollectorRejectsUnauthorizedRedeemer() public {
        uint256[] memory minOut = new uint256[](1);

        vm.prank(address(0xBEEF));
        vm.expectRevert();
        collector.redeemIndexFeeShares(address(feeVault), 10 ether, minOut);
    }

    function testFeeCollectorRejectsUnallowedVault() public {
        MockFeeVault unallowedVault = new MockFeeVault(IERC20(address(asset)));
        asset.mint(address(unallowedVault), 10 ether);
        unallowedVault.mint(address(collector), 10 ether);
        uint256[] memory minOut = new uint256[](1);

        vm.expectRevert(NARAIndexFeeCollectorV1.InvalidVault.selector);
        collector.redeemIndexFeeShares(address(unallowedVault), 10 ether, minOut);
    }

    function testFeeCollectorSwapsOnlyToNaraOrWeth() public {
        NARAIndexFeeCollectorV1.SwapCall memory swapCall =
            _feeSwap(address(asset), address(badOutput), 10 ether, 10 ether);

        vm.expectRevert(NARAIndexFeeCollectorV1.InvalidRewardOutput.selector);
        collector.executeFeeSwap(swapCall);
    }

    function testFeeCollectorSwapsFeeAssetToNara() public {
        NARAIndexFeeCollectorV1.SwapCall memory swapCall = _feeSwap(address(asset), address(nara), 10 ether, 10 ether);

        collector.executeFeeSwap(swapCall);

        assertEq(asset.balanceOf(address(collector)), 990 ether);
        assertEq(nara.balanceOf(address(collector)), 10 ether);
    }

    function testFeeCollectorRejectsUnauthorizedSwapper() public {
        NARAIndexFeeCollectorV1.SwapCall memory swapCall = _feeSwap(address(asset), address(nara), 10 ether, 10 ether);

        vm.prank(address(0xBEEF));
        vm.expectRevert();
        collector.executeFeeSwap(swapCall);
    }

    function testFeeCollectorRejectsUnapprovedSelector() public {
        collector.setAllowedSelector(address(executor), MockSwapExecutor.swap.selector, false);
        NARAIndexFeeCollectorV1.SwapCall memory swapCall = _feeSwap(address(asset), address(nara), 10 ether, 10 ether);

        vm.expectRevert(NARAIndexFeeCollectorV1.ExecutorNotAllowed.selector);
        collector.executeFeeSwap(swapCall);
    }

    function testFeeCollectorRejectsZeroMinAmountOut() public {
        NARAIndexFeeCollectorV1.SwapCall memory swapCall = _feeSwap(address(asset), address(nara), 10 ether, 0);

        vm.expectRevert(NARAIndexFeeCollectorV1.ZeroAmount.selector);
        collector.executeFeeSwap(swapCall);
    }

    function testFeeCollectorDepositsNaraRewards() public {
        nara.mint(address(collector), 25 ether);

        collector.depositNaraRewards(25 ether);

        assertEq(engine.naraRewards(), 25 ether);
        assertEq(nara.balanceOf(address(engine)), 25 ether);
    }

    function testFeeCollectorRewardRoutingRequiresSwapper() public {
        nara.mint(address(collector), 25 ether);

        vm.prank(address(0xBEEF));
        vm.expectRevert();
        collector.depositNaraRewards(25 ether);
    }

    function testFeeCollectorChecksRewardBalances() public {
        vm.expectRevert(NARAIndexFeeCollectorV1.BalanceInsufficient.selector);
        collector.depositNaraRewards(25 ether);
    }

    function testFeeCollectorUnwrapsWethAndNotifiesEthRewards() public {
        vm.deal(address(this), 1 ether);
        weth.deposit{value: 1 ether}();
        assertTrue(weth.transfer(address(collector), 1 ether));

        collector.unwrapWethAndNotifyEth(1 ether);

        assertEq(engine.ethRewards(), 1 ether);
        assertEq(address(engine).balance, 1 ether);
    }

    function testFeeCollectorSweepIsAdminOnly() public {
        asset.mint(address(collector), 5 ether);

        vm.prank(address(0xBEEF));
        vm.expectRevert();
        collector.sweepToken(address(asset), address(0xBEEF), 1 ether);

        uint256 beforeBalance = asset.balanceOf(address(0xBEEF));
        collector.sweepToken(address(asset), address(0xBEEF), 1 ether);

        assertEq(asset.balanceOf(address(0xBEEF)) - beforeBalance, 1 ether);
    }

    function testFeeCollectorCannotSweepRewardAssets() public {
        nara.mint(address(collector), 5 ether);
        vm.deal(address(this), 5 ether);
        weth.deposit{value: 5 ether}();
        assertTrue(weth.transfer(address(collector), 5 ether));

        vm.expectRevert(NARAIndexFeeCollectorV1.InvalidRewardOutput.selector);
        collector.sweepToken(address(nara), address(0xBEEF), 1 ether);

        vm.expectRevert(NARAIndexFeeCollectorV1.InvalidRewardOutput.selector);
        collector.sweepToken(address(weth), address(0xBEEF), 1 ether);
    }

    function _feeSwap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut)
        internal
        view
        returns (NARAIndexFeeCollectorV1.SwapCall memory call_)
    {
        bytes memory data = abi.encodeWithSelector(MockSwapExecutor.swap.selector, tokenIn, tokenOut, amountIn, minOut);
        call_ = NARAIndexFeeCollectorV1.SwapCall({
            executor: address(executor),
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            amountIn: amountIn,
            minAmountOut: minOut,
            data: data
        });
    }
}
