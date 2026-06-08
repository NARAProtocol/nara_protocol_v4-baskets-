// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {
    INARABasketSwapAdapterV1,
    NARAImmutableBasketPositionManagerV1
} from "../src/NARAImmutableBasketPositionManagerV1.sol";

contract BasketMockERC20 is ERC20 {
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

contract BasketBlockingERC20 is BasketMockERC20 {
    bool public transfersBlocked;

    constructor(string memory n, string memory s, uint8 d) BasketMockERC20(n, s, d) {}

    function setTransfersBlocked(bool value) external {
        transfersBlocked = value;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (transfersBlocked) revert("blocked");
        return super.transfer(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (transfersBlocked) revert("blocked");
        return super.transferFrom(from, to, amount);
    }
}

contract BasketMockSwapAdapter is INARABasketSwapAdapterV1 {
    using SafeERC20 for IERC20;

    mapping(address => mapping(address => uint256)) public rate1e18;
    bool public underSpend;
    bool public lieAboutOutput;

    function setRate(address tokenIn, address tokenOut, uint256 rate) external {
        rate1e18[tokenIn][tokenOut] = rate;
    }

    function setUnderSpend(bool value) external {
        underSpend = value;
    }

    function setLieAboutOutput(bool value) external {
        lieAboutOutput = value;
    }

    function swapExactInput(address tokenIn, address tokenOut, uint256 amountIn, uint256 minAmountOut, bytes calldata)
        external
        returns (uint256 amountInUsed, uint256 amountOut)
    {
        amountInUsed = underSpend ? amountIn - 1 : amountIn;
        amountOut = amountInUsed * rate1e18[tokenIn][tokenOut] / 1e18;
        require(amountOut >= minAmountOut, "slippage");
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountInUsed);
        IERC20(tokenOut).safeTransfer(msg.sender, amountOut);
        if (lieAboutOutput) amountOut += 1;
    }
}

contract NARAImmutableBasketPositionManagerV1Test is Test {
    BasketMockERC20 usdc;
    BasketMockERC20 nara;
    BasketMockERC20 pepe;
    BasketMockERC20 doge;
    BasketBlockingERC20 bonk;
    NARAImmutableBasketPositionManagerV1 manager;
    BasketMockSwapAdapter adapter;

    address alice = address(0xA11CE);
    address feeRecipient = address(0xFEE);
    bytes32 constant MEME = keccak256("MEME");

    function setUp() public {
        vm.warp(1);
        usdc = new BasketMockERC20("USD Coin", "USDC", 18);
        nara = new BasketMockERC20("NARA", "NARA", 18);
        pepe = new BasketMockERC20("Pepe", "PEPE", 18);
        doge = new BasketMockERC20("Doge", "DOGE", 18);
        bonk = new BasketBlockingERC20("Bonk", "BONK", 18);
        adapter = new BasketMockSwapAdapter();
        manager = new NARAImmutableBasketPositionManagerV1(
            "NARA Meme Basket Position", "NMBP", address(nara), 1_000, _deploymentConfig(address(adapter))
        );

        adapter.setRate(address(usdc), address(nara), 1e18);
        adapter.setRate(address(usdc), address(pepe), 2e18);
        adapter.setRate(address(usdc), address(doge), 1e18);
        adapter.setRate(address(usdc), address(bonk), 1e18);
        adapter.setRate(address(nara), address(usdc), 2e18);
        adapter.setRate(address(pepe), address(usdc), 2e18);
        adapter.setRate(address(doge), address(usdc), 2e18);
        adapter.setRate(address(bonk), address(usdc), 2e18);
        adapter.setRate(address(pepe), address(nara), 1e18);
        adapter.setRate(address(doge), address(nara), 1e18);
        adapter.setRate(address(bonk), address(nara), 1e18);

        nara.mint(address(adapter), 1_000_000 ether);
        pepe.mint(address(adapter), 1_000_000 ether);
        doge.mint(address(adapter), 1_000_000 ether);
        bonk.mint(address(adapter), 1_000_000 ether);
        usdc.mint(address(adapter), 1_000_000 ether);
        usdc.mint(alice, 10_000 ether);
    }

    function testDeploymentIsImmutableConfigured() public view {
        assertEq(manager.categoryId(), MEME);
        assertEq(manager.requiredAsset(), address(nara));
        assertEq(manager.minRequiredAssetWeightBps(), 1_000);
        assertEq(manager.withdrawFeeBps(), 100);
        assertEq(manager.holdingFeeBps(), 100);
        assertEq(manager.referralShareBps(), 3_000);
        assertEq(manager.paymentTokenCount(), 1);
        assertEq(manager.adapterCount(), 1);
        assertTrue(manager.isPaymentTokenAllowed(address(usdc)));
        assertTrue(manager.isAdapterAllowed(address(adapter)));
        assertTrue(manager.isSellOutputTokenAllowed(address(usdc)));
        assertTrue(manager.isSellOutputTokenAllowed(address(nara)));

        address[] memory assets = manager.getBasketAssets();
        uint16[] memory weights = manager.getBasketWeightsBps();
        assertEq(assets.length, 4);
        assertEq(assets[0], address(nara));
        assertEq(weights[0], 1_000);
    }

    function testBuyBasketMintsReceiptAndStoresBoughtAssets() public {
        NARAImmutableBasketPositionManagerV1.BuyParams memory params = _buyParams(1_000 ether, 0);

        vm.startPrank(alice);
        usdc.approve(address(manager), 1_000 ether);
        (uint256 tokenId, uint256[] memory bought) = manager.buyBasket(params);
        vm.stopPrank();

        assertEq(tokenId, 1);
        assertEq(manager.ownerOf(tokenId), alice);
        // Buy fee (10 USDC) goes to protocolFeeAccrued — not sent to feeRecipient immediately.
        assertEq(manager.protocolFeeAccrued(address(usdc)), 10 ether);
        assertEq(usdc.balanceOf(feeRecipient), 0);
        // Manager holds the 10 USDC fee until sweepAccruedFee is called.
        assertEq(usdc.balanceOf(address(manager)), 10 ether);
        assertEq(bought[0], 99 ether);
        assertEq(bought[1], 990 ether);
        assertEq(bought[2], 297 ether);
        assertEq(bought[3], 99 ether);
        assertEq(manager.positionAmountOf(tokenId, address(nara)), 99 ether);
        assertEq(manager.positionAmountOf(tokenId, address(pepe)), 990 ether);
        assertEq(manager.positionAmountOf(tokenId, address(doge)), 297 ether);
        assertEq(manager.positionAmountOf(tokenId, address(bonk)), 99 ether);
        assertEq(manager.totalAccountedAsset(address(nara)), 99 ether);
        assertEq(manager.totalAccountedAsset(address(pepe)), 990 ether);
        assertEq(manager.totalAccountedAsset(address(doge)), 297 ether);
        assertEq(manager.totalAccountedAsset(address(bonk)), 99 ether);
    }

    function testConstructorRequiresNaraAllocation() public {
        address[] memory assets = new address[](3);
        assets[0] = address(pepe);
        assets[1] = address(doge);
        assets[2] = address(bonk);

        uint16[] memory weights = new uint16[](3);
        weights[0] = 5_000;
        weights[1] = 3_000;
        weights[2] = 2_000;

        NARAImmutableBasketPositionManagerV1.BasketDeploymentConfig memory config = _deploymentConfig(address(adapter));
        config.assets = assets;
        config.weightsBps = weights;

        vm.expectRevert(
            abi.encodeWithSelector(NARAImmutableBasketPositionManagerV1.MissingRequiredAsset.selector, address(nara))
        );
        new NARAImmutableBasketPositionManagerV1("Bad", "BAD", address(nara), 1_000, config);
    }

    function testConstructorRejectsSelfFeeRecipient() public {
        NARAImmutableBasketPositionManagerV1.BasketDeploymentConfig memory config = _deploymentConfig(address(adapter));
        config.feeRecipient = computeCreateAddress(address(this), vm.getNonce(address(this)));

        vm.expectRevert(NARAImmutableBasketPositionManagerV1.ZeroAddress.selector);
        new NARAImmutableBasketPositionManagerV1("Bad", "BAD", address(nara), 1_000, config);
    }

    function testBuyBasketRejectsBadBudgetWeights() public {
        NARAImmutableBasketPositionManagerV1.BuyParams memory params = _buyParams(1_000 ether, 0);
        params.swaps[0].amountIn = 150 ether;
        params.swaps[0].minAmountOut = 1;
        params.swaps[1].amountIn = 444 ether;
        params.swaps[1].minAmountOut = 1;
        params.swaps[2].minAmountOut = 1;
        params.swaps[3].minAmountOut = 1;

        vm.startPrank(alice);
        usdc.approve(address(manager), 1_000 ether);
        vm.expectRevert();
        manager.buyBasket(params);
        vm.stopPrank();
    }

    function testBuyBasketRejectsPerAssetSlippage() public {
        NARAImmutableBasketPositionManagerV1.BuyParams memory params = _buyParams(1_000 ether, 0);
        params.minAmountsOut[1] = 991 ether;

        vm.startPrank(alice);
        usdc.approve(address(manager), 1_000 ether);
        vm.expectRevert();
        manager.buyBasket(params);
        vm.stopPrank();
    }

    function testBuyBasketRejectsAdapterAccountingLie() public {
        adapter.setLieAboutOutput(true);
        NARAImmutableBasketPositionManagerV1.BuyParams memory params = _buyParams(1_000 ether, 0);

        vm.startPrank(alice);
        usdc.approve(address(manager), 1_000 ether);
        vm.expectRevert();
        manager.buyBasket(params);
        vm.stopPrank();
    }

    function testBuyBasketRequiresPinnedAdapterForNaraLeg() public {
        BasketMockSwapAdapter wrongNaraAdapter = new BasketMockSwapAdapter();
        NARAImmutableBasketPositionManagerV1.BasketDeploymentConfig memory config = _deploymentConfig(address(adapter));

        address[] memory adapters = new address[](2);
        adapters[0] = address(adapter);
        adapters[1] = address(wrongNaraAdapter);
        config.adapters = adapters;
        config.requiredAssetAdapter = address(adapter);

        NARAImmutableBasketPositionManagerV1 pinned = new NARAImmutableBasketPositionManagerV1(
            "Pinned Basket", "PIN", address(nara), 1_000, config
        );
        NARAImmutableBasketPositionManagerV1.BuyParams memory params = _buyParams(1_000 ether, 0);
        params.swaps[0].adapter = address(wrongNaraAdapter);

        vm.startPrank(alice);
        usdc.approve(address(pinned), 1_000 ether);
        vm.expectRevert(NARAImmutableBasketPositionManagerV1.AdapterNotAllowed.selector);
        pinned.buyBasket(params);
        vm.stopPrank();
    }

    function testSellBasketSellsWholePositionToUsdcAndChargesFee() public {
        uint256 tokenId = _buyForAlice();

        NARAImmutableBasketPositionManagerV1.SellParams memory params = _sellParams(tokenId, 2_940 ether);

        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        (uint256 grossOutput, uint256 netOutput) = manager.sellBasket(params);

        assertEq(grossOutput, 2_970 ether);
        assertEq(netOutput, 2_940.3 ether);
        assertEq(usdc.balanceOf(alice) - aliceBefore, 2_940.3 ether);
        // 10 buy fee + 29.7 sell fee all in protocolFeeAccrued — none sent to feeRecipient directly.
        assertEq(manager.protocolFeeAccrued(address(usdc)), 39.7 ether);
        assertEq(usdc.balanceOf(feeRecipient), 0);
        assertEq(pepe.balanceOf(address(manager)), 0);
        assertEq(doge.balanceOf(address(manager)), 0);
        assertEq(bonk.balanceOf(address(manager)), 0);
        assertEq(nara.balanceOf(address(manager)), 0);
        assertEq(manager.totalAccountedAsset(address(nara)), 0);
        assertEq(manager.totalAccountedAsset(address(pepe)), 0);
        assertEq(manager.totalAccountedAsset(address(doge)), 0);
        assertEq(manager.totalAccountedAsset(address(bonk)), 0);
        vm.expectRevert();
        manager.ownerOf(tokenId);
    }

    function testSellBasketCanExitFullyToNara() public {
        uint256 tokenId = _buyForAlice();
        assertFalse(manager.paymentTokenAllowed(address(nara)));
        assertTrue(manager.isSellOutputTokenAllowed(address(nara)));

        NARAImmutableBasketPositionManagerV1.SellParams memory params = _sellToNaraParams(tokenId, 1_470 ether);

        uint256 aliceBefore = nara.balanceOf(alice);
        vm.prank(alice);
        (uint256 grossOutput, uint256 netOutput) = manager.sellBasket(params);

        assertEq(grossOutput, 1_485 ether);
        assertEq(netOutput, 1_470.15 ether);
        assertEq(nara.balanceOf(alice) - aliceBefore, 1_470.15 ether);
        // 14.85 NARA sell fee in protocolFeeAccrued; feeRecipient gets nothing until sweep.
        assertEq(manager.protocolFeeAccrued(address(nara)), 14.85 ether);
        assertEq(nara.balanceOf(feeRecipient), 0);
        assertEq(manager.totalAccountedAsset(address(nara)), 0);
        assertEq(manager.totalAccountedAsset(address(pepe)), 0);
        assertEq(manager.totalAccountedAsset(address(doge)), 0);
        assertEq(manager.totalAccountedAsset(address(bonk)), 0);
    }

    function testApprovalsAreDisabled() public {
        uint256 tokenId = _buyForAlice();
        address operator = address(0xB0B);

        // approve() reverts — ERC721 custody approvals are disabled to prevent phishing drains.
        vm.prank(alice);
        vm.expectRevert(NARAImmutableBasketPositionManagerV1.ApprovalsDisabled.selector);
        manager.approve(operator, tokenId);

        // setApprovalForAll() also reverts.
        vm.prank(alice);
        vm.expectRevert(NARAImmutableBasketPositionManagerV1.ApprovalsDisabled.selector);
        manager.setApprovalForAll(operator, true);

        // getApproved() returns zero (no approved address possible).
        assertEq(manager.getApproved(tokenId), address(0));

        // isApprovedForAll() always returns false.
        assertFalse(manager.isApprovedForAll(alice, operator));
    }

    function testNonOwnerCannotSellOrWithdraw() public {
        uint256 tokenId = _buyForAlice();
        address attacker = address(0xBAD);

        NARAImmutableBasketPositionManagerV1.SellParams memory sp = _sellParams(tokenId, 0);
        sp.receiver = attacker;

        vm.prank(attacker);
        vm.expectRevert(NARAImmutableBasketPositionManagerV1.NotPositionOwner.selector);
        manager.sellBasket(sp);

        vm.prank(attacker);
        vm.expectRevert(NARAImmutableBasketPositionManagerV1.NotPositionOwner.selector);
        manager.withdrawUnderlying(tokenId, attacker);
    }

    function testSellBasketRejectsPartialExit() public {
        uint256 tokenId = _buyForAlice();
        NARAImmutableBasketPositionManagerV1.SellParams memory params = _sellParams(tokenId, 0);
        NARAImmutableBasketPositionManagerV1.SwapInstruction[] memory swaps =
            new NARAImmutableBasketPositionManagerV1.SwapInstruction[](2);
        swaps[0] = params.swaps[0];
        swaps[1] = params.swaps[1];
        params.swaps = swaps;

        vm.prank(alice);
        vm.expectRevert();
        manager.sellBasket(params);
    }

    function testSellBasketRejectsTotalOutputSlippage() public {
        uint256 tokenId = _buyForAlice();
        NARAImmutableBasketPositionManagerV1.SellParams memory params = _sellParams(tokenId, 2_941 ether);

        vm.prank(alice);
        vm.expectRevert();
        manager.sellBasket(params);
    }

    function testWithdrawUnderlyingTransfersNetPositionAndChargesFee() public {
        uint256 tokenId = _buyForAlice();

        uint256 pepeBefore = pepe.balanceOf(alice);
        vm.prank(alice);
        uint256[] memory amounts = manager.withdrawUnderlying(tokenId, alice);

        // Returned amounts are gross (removed from the position).
        assertEq(amounts[0], 99 ether);
        assertEq(amounts[1], 990 ether);
        assertEq(amounts[2], 297 ether);
        assertEq(amounts[3], 99 ether);

        // Receiver gets gross minus the 1% withdraw fee.
        assertEq(pepe.balanceOf(alice) - pepeBefore, 980.1 ether);
        assertEq(nara.balanceOf(alice), 98.01 ether);
        assertEq(doge.balanceOf(alice), 294.03 ether);
        assertEq(bonk.balanceOf(alice), 98.01 ether);

        // Withdraw fees go to protocolFeeAccrued (M-09 fix: fee-recipient transfer cannot block exits).
        assertEq(manager.protocolFeeAccrued(address(nara)), 0.99 ether);
        assertEq(manager.protocolFeeAccrued(address(pepe)), 9.9 ether);
        assertEq(manager.protocolFeeAccrued(address(doge)), 2.97 ether);
        assertEq(manager.protocolFeeAccrued(address(bonk)), 0.99 ether);
        assertEq(nara.balanceOf(feeRecipient), 0);
        assertEq(pepe.balanceOf(feeRecipient), 0);

        assertEq(manager.totalAccountedAsset(address(nara)), 0);
        assertEq(manager.totalAccountedAsset(address(pepe)), 0);
        assertEq(manager.totalAccountedAsset(address(doge)), 0);
        assertEq(manager.totalAccountedAsset(address(bonk)), 0);
        vm.expectRevert();
        manager.ownerOf(tokenId);
    }

    function testWithdrawUnderlyingPartialRescuesGoodAssetsWhenOneTokenBlocks() public {
        uint256 tokenId = _buyForAlice();
        bonk.setTransfersBlocked(true);

        vm.prank(alice);
        vm.expectRevert();
        manager.withdrawUnderlying(tokenId, alice);

        address[] memory rescueAssets = new address[](3);
        rescueAssets[0] = address(nara);
        rescueAssets[1] = address(pepe);
        rescueAssets[2] = address(doge);

        vm.prank(alice);
        (uint256[] memory amounts, bool closed) = manager.withdrawUnderlyingPartial(tokenId, alice, rescueAssets);

        assertFalse(closed);
        assertEq(manager.ownerOf(tokenId), alice);
        // Returned amounts are gross; receiver gets gross minus the 1% withdraw fee.
        assertEq(amounts[0], 99 ether);
        assertEq(amounts[1], 990 ether);
        assertEq(amounts[2], 297 ether);
        assertEq(nara.balanceOf(alice), 98.01 ether);
        assertEq(pepe.balanceOf(alice), 980.1 ether);
        assertEq(doge.balanceOf(alice), 294.03 ether);
        assertEq(bonk.balanceOf(alice), 0);
        assertEq(manager.positionAmountOf(tokenId, address(nara)), 0);
        assertEq(manager.positionAmountOf(tokenId, address(pepe)), 0);
        assertEq(manager.positionAmountOf(tokenId, address(doge)), 0);
        assertEq(manager.positionAmountOf(tokenId, address(bonk)), 99 ether);
        assertEq(manager.totalAccountedAsset(address(nara)), 0);
        assertEq(manager.totalAccountedAsset(address(pepe)), 0);
        assertEq(manager.totalAccountedAsset(address(doge)), 0);
        assertEq(manager.totalAccountedAsset(address(bonk)), 99 ether);

        bonk.setTransfersBlocked(false);
        address[] memory finalAsset = new address[](1);
        finalAsset[0] = address(bonk);
        vm.prank(alice);
        (uint256[] memory finalAmounts, bool finalClosed) =
            manager.withdrawUnderlyingPartial(tokenId, alice, finalAsset);

        assertTrue(finalClosed);
        assertEq(finalAmounts[0], 99 ether); // gross removed from position
        assertEq(bonk.balanceOf(alice), 98.01 ether); // net after 1% withdraw fee
        // bonk withdraw fee goes to protocolFeeAccrued, not directly to feeRecipient.
        assertEq(manager.protocolFeeAccrued(address(bonk)), 0.99 ether);
        assertEq(manager.totalAccountedAsset(address(bonk)), 0);
        vm.expectRevert();
        manager.ownerOf(tokenId);
    }

    function testZeroWithdrawFeeSendsFullAmount() public {
        NARAImmutableBasketPositionManagerV1.BasketDeploymentConfig memory cfg = _deploymentConfig(address(adapter));
        cfg.withdrawFeeBps = 0;
        NARAImmutableBasketPositionManagerV1 zeroFeeManager =
            new NARAImmutableBasketPositionManagerV1("Zero Fee Basket", "ZFB", address(nara), 1_000, cfg);

        uint256 tokenId = _buyOn(zeroFeeManager);
        vm.prank(alice);
        zeroFeeManager.withdrawUnderlying(tokenId, alice);

        // No fee: receiver gets the full position, fee recipient gets none of the underlying.
        assertEq(nara.balanceOf(alice), 99 ether);
        assertEq(pepe.balanceOf(alice), 990 ether);
        assertEq(nara.balanceOf(feeRecipient), 0);
        assertEq(pepe.balanceOf(feeRecipient), 0);
    }

    function testWithdrawPartialChargesFeeOnlyOnSelectedAssets() public {
        uint256 tokenId = _buyForAlice();

        address[] memory sel = new address[](1);
        sel[0] = address(pepe);
        vm.prank(alice);
        manager.withdrawUnderlyingPartial(tokenId, alice, sel);

        // 1% fee on the 990 pepe only — goes to protocolFeeAccrued, not feeRecipient.
        assertEq(pepe.balanceOf(alice), 980.1 ether);
        assertEq(manager.protocolFeeAccrued(address(pepe)), 9.9 ether);
        assertEq(pepe.balanceOf(feeRecipient), 0);
        // Untouched assets remain fully accounted in the position; no fee taken on them.
        assertEq(manager.positionAmountOf(tokenId, address(nara)), 99 ether);
        assertEq(manager.protocolFeeAccrued(address(nara)), 0);
    }

    function testAssetSolvencyReturnsCorrectValues() public {
        // Before any buy: balance and accounted both 0.
        (uint256 bal, uint256 acc, bool solvent, uint256 deficit) = manager.assetSolvency(address(nara));
        assertEq(bal, 0);
        assertEq(acc, 0);
        assertTrue(solvent);
        assertEq(deficit, 0);

        uint256 tokenId = _buyForAlice();

        // After buy: accounted == position amount, no deficit.
        (bal, acc, solvent, deficit) = manager.assetSolvency(address(nara));
        assertEq(acc, manager.positionAmountOf(tokenId, address(nara)));
        assertEq(bal, acc);
        assertTrue(solvent);
        assertEq(deficit, 0);

        // After sell to USDC: nara position closed; protocolFeeAccrued[nara] stays 0 (fees were in USDC).
        NARAImmutableBasketPositionManagerV1.SellParams memory sp = _sellParams(tokenId, 0);
        vm.prank(alice);
        manager.sellBasket(sp);
        (bal, acc, solvent, deficit) = manager.assetSolvency(address(nara));
        assertEq(bal, 0);
        assertEq(acc, 0);
        assertTrue(solvent);
        assertEq(deficit, 0);
    }

    function testSellRejectsManagerAsReceiver() public {
        uint256 tokenId = _buyForAlice();
        NARAImmutableBasketPositionManagerV1.SellParams memory sp = _sellParams(tokenId, 0);
        sp.receiver = address(manager);
        vm.prank(alice);
        vm.expectRevert(NARAImmutableBasketPositionManagerV1.ZeroAddress.selector);
        manager.sellBasket(sp);
    }

    function testWithdrawRejectsManagerAsReceiver() public {
        uint256 tokenId = _buyForAlice();
        vm.prank(alice);
        vm.expectRevert(NARAImmutableBasketPositionManagerV1.ZeroAddress.selector);
        manager.withdrawUnderlying(tokenId, address(manager));
    }

    function testConstructorRejectsWithdrawFeeAboveCap() public {
        NARAImmutableBasketPositionManagerV1.BasketDeploymentConfig memory cfg = _deploymentConfig(address(adapter));
        cfg.withdrawFeeBps = 101; // > MAX_FEE_BPS (100)
        vm.expectRevert(NARAImmutableBasketPositionManagerV1.FeeTooHigh.selector);
        new NARAImmutableBasketPositionManagerV1("Bad Fee Basket", "BAD", address(nara), 1_000, cfg);
    }

    function testSellBasketPartialConvertsGoodAssetsWhenOneTokenBlocks() public {
        uint256 tokenId = _buyForAlice();
        bonk.setTransfersBlocked(true);

        NARAImmutableBasketPositionManagerV1.SellParams memory wholeParams = _sellParams(tokenId, 0);
        vm.prank(alice);
        vm.expectRevert();
        manager.sellBasket(wholeParams);

        NARAImmutableBasketPositionManagerV1.PartialSellParams memory params;
        params.tokenId = tokenId;
        params.outputToken = address(usdc);
        params.minOutputAmount = 2_600 ether;
        params.swaps = new NARAImmutableBasketPositionManagerV1.SwapInstruction[](3);
        params.swaps[0] = _swap(address(nara), address(usdc), 99 ether, 198 ether);
        params.swaps[1] = _swap(address(pepe), address(usdc), 990 ether, 1_980 ether);
        params.swaps[2] = _swap(address(doge), address(usdc), 297 ether, 594 ether);
        params.receiver = alice;
        params.deadline = block.timestamp + 1 hours;

        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        (uint256 grossOutput, uint256 netOutput, bool closed) = manager.sellBasketPartial(params);

        assertFalse(closed);
        // gross = (99 + 990 + 297) tokens * 2.0 usdc rate = 2772; 1% sell fee on top.
        assertEq(grossOutput, 2_772 ether);
        assertEq(netOutput, 2_744.28 ether);
        assertEq(usdc.balanceOf(alice) - aliceBefore, 2_744.28 ether);
        // 10 buy fee + 27.72 sell fee both in protocolFeeAccrued; sweep delivers to feeRecipient.
        assertEq(manager.protocolFeeAccrued(address(usdc)), 37.72 ether);
        assertEq(usdc.balanceOf(feeRecipient), 0);
        assertEq(manager.ownerOf(tokenId), alice);
        assertEq(manager.positionAmountOf(tokenId, address(nara)), 0);
        assertEq(manager.positionAmountOf(tokenId, address(pepe)), 0);
        assertEq(manager.positionAmountOf(tokenId, address(doge)), 0);
        assertEq(manager.positionAmountOf(tokenId, address(bonk)), 99 ether);
        assertEq(manager.totalAccountedAsset(address(nara)), 0);
        assertEq(manager.totalAccountedAsset(address(pepe)), 0);
        assertEq(manager.totalAccountedAsset(address(doge)), 0);
        assertEq(manager.totalAccountedAsset(address(bonk)), 99 ether);
    }

    function testPartialSellBurnsReceiptWhenLastAssetIsExited() public {
        uint256 tokenId = _buyForAlice();

        NARAImmutableBasketPositionManagerV1.PartialSellParams memory params;
        params.tokenId = tokenId;
        params.outputToken = address(usdc);
        params.minOutputAmount = 2_940 ether;
        params.swaps = new NARAImmutableBasketPositionManagerV1.SwapInstruction[](4);
        params.swaps[0] = _swap(address(nara), address(usdc), 99 ether, 198 ether);
        params.swaps[1] = _swap(address(pepe), address(usdc), 990 ether, 1_980 ether);
        params.swaps[2] = _swap(address(doge), address(usdc), 297 ether, 594 ether);
        params.swaps[3] = _swap(address(bonk), address(usdc), 99 ether, 198 ether);
        params.receiver = alice;
        params.deadline = block.timestamp + 1 hours;

        vm.prank(alice);
        (uint256 grossOutput, uint256 netOutput, bool closed) = manager.sellBasketPartial(params);

        assertTrue(closed);
        assertEq(grossOutput, 2_970 ether);
        assertEq(netOutput, 2_940.3 ether);
        assertEq(manager.totalAccountedAsset(address(nara)), 0);
        assertEq(manager.totalAccountedAsset(address(pepe)), 0);
        assertEq(manager.totalAccountedAsset(address(doge)), 0);
        assertEq(manager.totalAccountedAsset(address(bonk)), 0);
        vm.expectRevert();
        manager.ownerOf(tokenId);
    }

    function testPartialSellDirectOutputAssetMaintainsSolvency() public {
        uint256 tokenId = _buyForAlice();

        NARAImmutableBasketPositionManagerV1.PartialSellParams memory params;
        params.tokenId = tokenId;
        params.outputToken = address(nara);
        params.directOutputAmount = 50 ether;
        params.minOutputAmount = 49.5 ether;
        params.swaps = new NARAImmutableBasketPositionManagerV1.SwapInstruction[](0);
        params.receiver = alice;
        params.deadline = block.timestamp + 1 hours;

        uint256 aliceBefore = nara.balanceOf(alice);
        vm.prank(alice);
        (uint256 grossOutput, uint256 netOutput, bool closed) = manager.sellBasketPartial(params);

        assertFalse(closed);
        assertEq(grossOutput, 50 ether);
        assertEq(netOutput, 49.5 ether);
        assertEq(nara.balanceOf(alice) - aliceBefore, 49.5 ether);
        assertEq(manager.protocolFeeAccrued(address(nara)), 0.5 ether);
        assertEq(manager.positionAmountOf(tokenId, address(nara)), 49 ether);
        assertEq(manager.totalAccountedAsset(address(nara)), 49 ether);

        (uint256 bal, uint256 acc, bool solvent, uint256 deficit) = manager.assetSolvency(address(nara));
        assertEq(bal, 49.5 ether);
        assertEq(acc, 49.5 ether);
        assertTrue(solvent);
        assertEq(deficit, 0);
    }

    // ---------------------------------------------------------------------
    // Holding fee (in-kind streaming fee)
    // ---------------------------------------------------------------------

    function testHoldingFeeAccruesOverOneYear() public {
        uint256 tokenId = _buyForAlice();
        vm.warp(block.timestamp + 365 days);

        uint256[] memory ids = new uint256[](1);
        ids[0] = tokenId;
        manager.accrueHoldingFee(ids);

        // 1%/yr on each asset after exactly one year.
        assertEq(manager.positionAmountOf(tokenId, address(nara)), 98.01 ether);
        assertEq(manager.positionAmountOf(tokenId, address(pepe)), 980.1 ether);
        assertEq(manager.positionAmountOf(tokenId, address(doge)), 294.03 ether);
        assertEq(manager.positionAmountOf(tokenId, address(bonk)), 98.01 ether);

        assertEq(manager.protocolFeeAccrued(address(nara)), 0.99 ether);
        assertEq(manager.protocolFeeAccrued(address(pepe)), 9.9 ether);
        assertEq(manager.protocolFeeAccrued(address(doge)), 2.97 ether);
        assertEq(manager.protocolFeeAccrued(address(bonk)), 0.99 ether);

        assertEq(manager.totalAccountedAsset(address(nara)), 98.01 ether);

        // Solvency invariant holds: balance == accounted (position + accrued + global referral rewards).
        (uint256 bal, uint256 acc, bool solvent, uint256 deficit) = manager.assetSolvency(address(nara));
        assertEq(bal, 99 ether);
        assertEq(acc, 99 ether); // 98.01 position + 0.99 protocolFeeAccrued
        assertTrue(solvent);
        assertEq(deficit, 0);

        // Sweep routes the accrued slice to the fee recipient.
        manager.sweepAccruedFee(address(nara));
        assertEq(nara.balanceOf(feeRecipient), 0.99 ether);
        assertEq(manager.protocolFeeAccrued(address(nara)), 0);
    }

    function testHoldingFeeSettledOnWithdraw() public {
        uint256 tokenId = _buyForAlice();
        vm.warp(block.timestamp + 365 days);

        vm.prank(alice);
        manager.withdrawUnderlying(tokenId, alice);

        // nara: 99 gross -> 0.99 holding fee -> 98.01 remaining -> 0.9801 withdraw fee -> 97.0299 net.
        assertEq(nara.balanceOf(alice), 97.0299 ether);
        // Both holding and withdraw fees accumulate in protocolFeeAccrued; nothing sent to feeRecipient yet.
        assertEq(manager.protocolFeeAccrued(address(nara)), 0.99 ether + 0.9801 ether); // 1.9701
        assertEq(nara.balanceOf(feeRecipient), 0);
        vm.expectRevert();
        manager.ownerOf(tokenId);
    }

    function testHoldingAccrualNeverTransfersSoFrozenAssetCannotBlockIt() public {
        uint256 tokenId = _buyForAlice();
        vm.warp(block.timestamp + 365 days);
        bonk.setTransfersBlocked(true);

        // Accrual is pure accounting; it succeeds even though bonk cannot transfer.
        uint256[] memory ids = new uint256[](1);
        ids[0] = tokenId;
        manager.accrueHoldingFee(ids);
        assertEq(manager.protocolFeeAccrued(address(bonk)), 0.99 ether);

        // Sweeping the frozen asset reverts; a healthy asset still sweeps.
        vm.expectRevert();
        manager.sweepAccruedFee(address(bonk));
        manager.sweepAccruedFee(address(nara));
        assertEq(nara.balanceOf(feeRecipient), 0.99 ether);
    }

    function testHoldingFeeDoesNotBreakFrozenAssetRescue() public {
        uint256 tokenId = _buyForAlice();
        vm.warp(block.timestamp + 365 days);
        bonk.setTransfersBlocked(true);

        address[] memory rescue = new address[](1);
        rescue[0] = address(pepe);
        vm.prank(alice);
        manager.withdrawUnderlyingPartial(tokenId, alice, rescue);

        // pepe: 990 -> 9.9 holding -> 980.1 remaining -> 9.801 withdraw fee -> 970.299 net.
        assertEq(pepe.balanceOf(alice), 970.299 ether);
        // Position still live; the frozen bonk did not block the rescue despite holding-fee accrual.
        assertEq(manager.ownerOf(tokenId), alice);
    }

    function testZeroHoldingFeeNeverAccrues() public {
        NARAImmutableBasketPositionManagerV1.BasketDeploymentConfig memory cfg = _deploymentConfig(address(adapter));
        cfg.holdingFeeBps = 0;
        NARAImmutableBasketPositionManagerV1 m =
            new NARAImmutableBasketPositionManagerV1("Zero Hold", "ZH", address(nara), 1_000, cfg);

        uint256 tokenId = _buyOn(m);
        vm.warp(block.timestamp + 3650 days);
        uint256[] memory ids = new uint256[](1);
        ids[0] = tokenId;
        m.accrueHoldingFee(ids);

        assertEq(m.positionAmountOf(tokenId, address(nara)), 99 ether);
        assertEq(m.protocolFeeAccrued(address(nara)), 0);
    }

    function testConstructorRejectsHoldingFeeAboveCap() public {
        NARAImmutableBasketPositionManagerV1.BasketDeploymentConfig memory cfg = _deploymentConfig(address(adapter));
        cfg.holdingFeeBps = 201; // > MAX_HOLDING_FEE_BPS (200)
        vm.expectRevert(NARAImmutableBasketPositionManagerV1.FeeTooHigh.selector);
        new NARAImmutableBasketPositionManagerV1("Bad", "BAD", address(nara), 1_000, cfg);
    }

    function testSweepRevertsWhenNothingAccrued() public {
        vm.expectRevert(NARAImmutableBasketPositionManagerV1.ZeroAmount.selector);
        manager.sweepAccruedFee(address(nara));
    }

    function testFuzzHoldingFeeNeverUnderflowsPosition(uint64 elapsed) public {
        uint256 tokenId = _buyForAlice();
        vm.warp(block.timestamp + uint256(elapsed));

        uint256[] memory ids = new uint256[](1);
        ids[0] = tokenId;
        manager.accrueHoldingFee(ids); // must never revert/underflow

        // Conservation: remaining position + accrued protocol fee == original bought amount.
        assertEq(manager.positionAmountOf(tokenId, address(nara)) + manager.protocolFeeAccrued(address(nara)), 99 ether);
    }

    // ---------------------------------------------------------------------
    // Referral (trustless lifetime fee-split)
    // ---------------------------------------------------------------------

    function testReferralSplitsBuyFee() public {
        address ref = address(0xBEEF);
        NARAImmutableBasketPositionManagerV1.BuyParams memory params = _buyParams(1_000 ether, 0);
        params.referrer = ref;

        vm.startPrank(alice);
        usdc.approve(address(manager), 1_000 ether);
        (uint256 tokenId,) = manager.buyBasket(params);
        vm.stopPrank();

        // 10 USDC buy fee; referrer takes 30% -> credited in pull bucket.
        assertEq(manager.referralRewards(ref, address(usdc)), 3 ether);
        // totalReferralRewardsByToken tracks global liability for the solvency check.
        assertEq(manager.totalReferralRewardsByToken(address(usdc)), 3 ether);
        // Protocol 70% goes to protocolFeeAccrued — not sent to feeRecipient during the buy.
        assertEq(manager.protocolFeeAccrued(address(usdc)), 7 ether);
        assertEq(usdc.balanceOf(feeRecipient), 0);
        // Referrer balance is zero until they claim.
        assertEq(usdc.balanceOf(ref), 0);
        assertEq(manager.referrerOf(tokenId), ref);

        // Claim routes the credited amount to the referrer.
        vm.prank(ref);
        manager.claimReferralReward(address(usdc), ref);
        assertEq(usdc.balanceOf(ref), 3 ether);
        assertEq(manager.referralRewards(ref, address(usdc)), 0);
    }

    function testReferralEarnsOnSellForLifetimeOfPosition() public {
        address ref = address(0xBEEF);
        NARAImmutableBasketPositionManagerV1.BuyParams memory bp = _buyParams(1_000 ether, 0);
        bp.referrer = ref;
        vm.startPrank(alice);
        usdc.approve(address(manager), 1_000 ether);
        (uint256 tokenId,) = manager.buyBasket(bp);
        vm.stopPrank();

        // Buy fee 10; referrer credited 3 in pull bucket.
        assertEq(manager.referralRewards(ref, address(usdc)), 3 ether);

        NARAImmutableBasketPositionManagerV1.SellParams memory sp = _sellParams(tokenId, 0);
        vm.prank(alice);
        manager.sellBasket(sp);

        // Sell fee 29.7; referrer credited 30% = 8.91. Lifetime credited: 3 + 8.91 = 11.91.
        assertEq(manager.referralRewards(ref, address(usdc)), 11.91 ether);
        // Protocol parts: 7 buy + 20.79 sell = 27.79 in protocolFeeAccrued.
        assertEq(manager.protocolFeeAccrued(address(usdc)), 27.79 ether);
        assertEq(usdc.balanceOf(feeRecipient), 0);

        // Claim lifetime rewards.
        vm.prank(ref);
        manager.claimReferralReward(address(usdc), ref);
        assertEq(usdc.balanceOf(ref), 11.91 ether);
    }

    function testSelfReferralIsIgnored() public {
        NARAImmutableBasketPositionManagerV1.BuyParams memory params = _buyParams(1_000 ether, 0);
        params.referrer = alice; // buyer == referrer

        vm.startPrank(alice);
        usdc.approve(address(manager), 1_000 ether);
        (uint256 tokenId,) = manager.buyBasket(params);
        vm.stopPrank();

        // No referrer bound; full buy fee to protocolFeeAccrued, nothing in pull bucket.
        assertEq(manager.referrerOf(tokenId), address(0));
        assertEq(manager.protocolFeeAccrued(address(usdc)), 10 ether);
        assertEq(usdc.balanceOf(feeRecipient), 0);
        assertEq(manager.referralRewards(alice, address(usdc)), 0);
    }

    function testReferralSplitsPartialSellFee() public {
        address ref = address(0xBEEF);
        NARAImmutableBasketPositionManagerV1.BuyParams memory bp = _buyParams(1_000 ether, 0);
        bp.referrer = ref;
        vm.startPrank(alice);
        usdc.approve(address(manager), 1_000 ether);
        (uint256 tokenId,) = manager.buyBasket(bp);
        vm.stopPrank();

        // Sell only pepe partially.
        NARAImmutableBasketPositionManagerV1.PartialSellParams memory params;
        params.tokenId = tokenId;
        params.outputToken = address(usdc);
        params.minOutputAmount = 0;
        params.swaps = new NARAImmutableBasketPositionManagerV1.SwapInstruction[](1);
        params.swaps[0] = _swap(address(pepe), address(usdc), 990 ether, 1_980 ether);
        params.receiver = alice;
        params.deadline = block.timestamp + 1 hours;

        vm.prank(alice);
        manager.sellBasketPartial(params);

        // pepe 990 -> 1980 usdc gross; sell fee 19.8; referrer credited 30% = 5.94. Lifetime: 3 + 5.94 = 8.94.
        assertEq(manager.referralRewards(ref, address(usdc)), 8.94 ether);
    }

    function testClaimReferralRewardToThirdParty() public {
        address ref = address(0xBEEF);
        address collector = address(0xC011);
        NARAImmutableBasketPositionManagerV1.BuyParams memory bp = _buyParams(1_000 ether, 0);
        bp.referrer = ref;
        vm.startPrank(alice);
        usdc.approve(address(manager), 1_000 ether);
        manager.buyBasket(bp);
        vm.stopPrank();

        vm.prank(ref);
        manager.claimReferralReward(address(usdc), collector);

        assertEq(usdc.balanceOf(collector), 3 ether);
        assertEq(manager.referralRewards(ref, address(usdc)), 0);
    }

    function testClaimRevertsWhenNoRewards() public {
        vm.expectRevert(NARAImmutableBasketPositionManagerV1.ZeroAmount.selector);
        manager.claimReferralReward(address(usdc), address(0xBEEF));
    }

    function testAccrueHoldingFeeRevertsBatchTooLarge() public {
        uint256[] memory ids = new uint256[](101); // > MAX_ACCRUAL_BATCH (100)
        vm.expectRevert(NARAImmutableBasketPositionManagerV1.BatchTooLarge.selector);
        manager.accrueHoldingFee(ids);
    }

    function testConstructorRejectsReferralShareAboveCap() public {
        NARAImmutableBasketPositionManagerV1.BasketDeploymentConfig memory cfg = _deploymentConfig(address(adapter));
        cfg.referralShareBps = 5_001; // > MAX_REFERRAL_SHARE_BPS (5000)
        vm.expectRevert(NARAImmutableBasketPositionManagerV1.FeeTooHigh.selector);
        new NARAImmutableBasketPositionManagerV1("Bad", "BAD", address(nara), 1_000, cfg);
    }

    // ---------------------------------------------------------------------
    // New tests for contract v2 (material changes)
    // ---------------------------------------------------------------------

    function testConfigHashIsNonZero() public view {
        assertNotEq(manager.configHash(), bytes32(0));
    }

    function testGetPaymentTokensAndAdapters() public view {
        address[] memory tokens = manager.getPaymentTokens();
        assertEq(tokens.length, 1);
        assertEq(tokens[0], address(usdc));

        address[] memory adapters = manager.getAdapters();
        assertEq(adapters.length, 1);
        assertEq(adapters[0], address(adapter));
    }

    function testMinInputAmountEnforced() public {
        NARAImmutableBasketPositionManagerV1.BasketDeploymentConfig memory cfg = _deploymentConfig(address(adapter));
        cfg.minInputAmount = 500 ether;
        NARAImmutableBasketPositionManagerV1 m =
            new NARAImmutableBasketPositionManagerV1("Min Input Basket", "MIB", address(nara), 1_000, cfg);

        NARAImmutableBasketPositionManagerV1.BuyParams memory params = _buyParams(100 ether, 0);
        usdc.mint(alice, 100 ether);
        vm.startPrank(alice);
        usdc.approve(address(m), 100 ether);
        vm.expectRevert(NARAImmutableBasketPositionManagerV1.AmountTooSmall.selector);
        m.buyBasket(params);
        vm.stopPrank();
    }

    function testTooManySwapsRejected() public {
        // More than MAX_SWAPS (40) swap instructions should revert on buy.
        NARAImmutableBasketPositionManagerV1.BuyParams memory params = _buyParams(1_000 ether, 0);
        NARAImmutableBasketPositionManagerV1.SwapInstruction[] memory swaps =
            new NARAImmutableBasketPositionManagerV1.SwapInstruction[](41);
        for (uint256 i = 0; i < 41; i++) {
            swaps[i] = _swap(address(usdc), address(nara), 1 ether, 1);
        }
        params.swaps = swaps;

        vm.startPrank(alice);
        usdc.approve(address(manager), 1_000 ether);
        vm.expectRevert(NARAImmutableBasketPositionManagerV1.TooManySwaps.selector);
        manager.buyBasket(params);
        vm.stopPrank();
    }

    function testSweepDeliversAccruedFeesToRecipient() public {
        uint256 tokenId = _buyForAlice();

        // Buy fee is in protocolFeeAccrued.
        assertEq(manager.protocolFeeAccrued(address(usdc)), 10 ether);

        // sweepAccruedFee transfers the full accrued amount to the immutable feeRecipient.
        uint256 swept = manager.sweepAccruedFee(address(usdc));
        assertEq(swept, 10 ether);
        assertEq(usdc.balanceOf(feeRecipient), 10 ether);
        assertEq(manager.protocolFeeAccrued(address(usdc)), 0);

        // After a sell, sell fee accumulates and can be swept too.
        NARAImmutableBasketPositionManagerV1.SellParams memory sp = _sellParams(tokenId, 0);
        vm.prank(alice);
        manager.sellBasket(sp);

        assertEq(manager.protocolFeeAccrued(address(usdc)), 29.7 ether);
        manager.sweepAccruedFee(address(usdc));
        assertEq(usdc.balanceOf(feeRecipient), 39.7 ether); // 10 + 29.7
    }

    function testHoldingFeeRemainderCarriesForwardOnZeroFeeInterval() public {
        // Verifies H-01 fix: remainder mechanism preserves sub-period fee accumulation.
        // We accrue in 3 chunks (1s + 1s + (365d-2s) = 365d total).
        // The split total must match single-year accrual within 1 wei.
        // Uses explicit timestamps to avoid via-ir optimizer caching block.timestamp across warps.
        uint256 tokenId = _buyForAlice();
        uint256[] memory ids = new uint256[](1);
        ids[0] = tokenId;

        vm.warp(2);  // 1s elapsed since buy (setUp warps to 1)
        manager.accrueHoldingFee(ids);
        assertEq(manager.lastHoldingAccrualAt(tokenId), 2);

        vm.warp(3);  // another 1s
        manager.accrueHoldingFee(ids);
        assertEq(manager.lastHoldingAccrualAt(tokenId), 3);

        vm.warp(3 + 365 days - 2);  // complete the year
        manager.accrueHoldingFee(ids);

        // 1%/yr on 99 ether nara ≈ 0.99 ether. Split accrual charges slightly less due to
        // the fee being calculated on a decreasing balance (simple-interest compound effect).
        // Allow 1e12 tolerance (~1 gwei / 0.0001% of 0.99 ether).
        uint256 accrued = manager.protocolFeeAccrued(address(nara));
        assertApproxEqAbs(accrued, 0.99 ether, 1e12);
    }

    function testAssetSolvencyIncludesGlobalReferralRewards() public {
        address ref = address(0xBEEF);
        NARAImmutableBasketPositionManagerV1.BuyParams memory params = _buyParams(1_000 ether, 0);
        params.referrer = ref;

        vm.startPrank(alice);
        usdc.approve(address(manager), 1_000 ether);
        manager.buyBasket(params);
        vm.stopPrank();

        // After buy: referralRewards = 3, protocolFeeAccrued = 7.
        // assetSolvency must include totalReferralRewardsByToken to be accurate.
        (uint256 bal, uint256 acc, bool solvent, uint256 deficit) = manager.assetSolvency(address(usdc));
        // balance = 10 (fee held), accounted = 7 (protocolFee) + 3 (referral) = 10.
        assertEq(bal, 10 ether);
        assertEq(acc, 10 ether);
        assertTrue(solvent);
        assertEq(deficit, 0);

        // totalReferralRewardsByToken correctly tracks global liability.
        assertEq(manager.totalReferralRewardsByToken(address(usdc)), 3 ether);

        // After claim, liability decreases and solvency still holds.
        vm.prank(ref);
        manager.claimReferralReward(address(usdc), ref);
        (bal, acc, solvent, deficit) = manager.assetSolvency(address(usdc));
        assertEq(manager.totalReferralRewardsByToken(address(usdc)), 0);
        // bal = 7 (ref claimed 3, 7 stays), acc = 7 (protocolFee) + 0 (referral) = 7.
        assertEq(bal, 7 ether);
        assertEq(acc, 7 ether);
        assertTrue(solvent);
        assertEq(deficit, 0);
    }

    function _buyForAlice() internal returns (uint256 tokenId) {
        NARAImmutableBasketPositionManagerV1.BuyParams memory params = _buyParams(1_000 ether, 0);
        vm.startPrank(alice);
        usdc.approve(address(manager), 1_000 ether);
        (tokenId,) = manager.buyBasket(params);
        vm.stopPrank();
    }

    function _buyOn(NARAImmutableBasketPositionManagerV1 m) internal returns (uint256 tokenId) {
        NARAImmutableBasketPositionManagerV1.BuyParams memory params = _buyParams(1_000 ether, 0);
        usdc.mint(alice, 1_000 ether);
        vm.startPrank(alice);
        usdc.approve(address(m), 1_000 ether);
        (tokenId,) = m.buyBasket(params);
        vm.stopPrank();
    }

    function _buyParams(uint256 inputAmount, uint256 minAssetOut)
        internal
        view
        returns (NARAImmutableBasketPositionManagerV1.BuyParams memory params)
    {
        uint256 netInput = inputAmount * 9_900 / 10_000;
        params.paymentToken = address(usdc);
        params.inputAmount = inputAmount;
        params.directAmountsIn = new uint256[](4);
        params.minAmountsOut = new uint256[](4);
        params.minAmountsOut[0] = minAssetOut;
        params.minAmountsOut[1] = minAssetOut;
        params.minAmountsOut[2] = minAssetOut;
        params.minAmountsOut[3] = minAssetOut;
        params.swaps = new NARAImmutableBasketPositionManagerV1.SwapInstruction[](4);
        params.swaps[0] = _swap(address(usdc), address(nara), netInput * 1_000 / 10_000, netInput * 1_000 / 10_000);
        params.swaps[1] = _swap(address(usdc), address(pepe), netInput * 5_000 / 10_000, netInput * 5_000 / 10_000 * 2);
        params.swaps[2] = _swap(address(usdc), address(doge), netInput * 3_000 / 10_000, netInput * 3_000 / 10_000);
        params.swaps[3] = _swap(address(usdc), address(bonk), netInput * 1_000 / 10_000, netInput * 1_000 / 10_000);
        params.receiver = alice;
        params.deadline = block.timestamp + 1 hours;
    }

    function _sellParams(uint256 tokenId, uint256 minOutputAmount)
        internal
        view
        returns (NARAImmutableBasketPositionManagerV1.SellParams memory params)
    {
        params.tokenId = tokenId;
        params.outputToken = address(usdc);
        params.minOutputAmount = minOutputAmount;
        params.swaps = new NARAImmutableBasketPositionManagerV1.SwapInstruction[](4);
        params.swaps[0] = _swap(address(nara), address(usdc), 99 ether, 198 ether);
        params.swaps[1] = _swap(address(pepe), address(usdc), 990 ether, 1_980 ether);
        params.swaps[2] = _swap(address(doge), address(usdc), 297 ether, 594 ether);
        params.swaps[3] = _swap(address(bonk), address(usdc), 99 ether, 198 ether);
        params.receiver = alice;
        params.deadline = block.timestamp + 1 hours;
    }

    function _sellToNaraParams(uint256 tokenId, uint256 minOutputAmount)
        internal
        view
        returns (NARAImmutableBasketPositionManagerV1.SellParams memory params)
    {
        params.tokenId = tokenId;
        params.outputToken = address(nara);
        params.minOutputAmount = minOutputAmount;
        params.swaps = new NARAImmutableBasketPositionManagerV1.SwapInstruction[](3);
        params.swaps[0] = _swap(address(pepe), address(nara), 990 ether, 990 ether);
        params.swaps[1] = _swap(address(doge), address(nara), 297 ether, 297 ether);
        params.swaps[2] = _swap(address(bonk), address(nara), 99 ether, 99 ether);
        params.receiver = alice;
        params.deadline = block.timestamp + 1 hours;
    }

    function _swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minAmountOut)
        internal
        view
        returns (NARAImmutableBasketPositionManagerV1.SwapInstruction memory instruction)
    {
        instruction = NARAImmutableBasketPositionManagerV1.SwapInstruction({
            adapter: address(adapter),
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            amountIn: amountIn,
            minAmountOut: minAmountOut,
            data: ""
        });
    }

    function _deploymentConfig(address adapter_)
        internal
        view
        returns (NARAImmutableBasketPositionManagerV1.BasketDeploymentConfig memory config)
    {
        address[] memory assets = new address[](4);
        assets[0] = address(nara);
        assets[1] = address(pepe);
        assets[2] = address(doge);
        assets[3] = address(bonk);

        uint16[] memory weights = new uint16[](4);
        weights[0] = 1_000;
        weights[1] = 5_000;
        weights[2] = 3_000;
        weights[3] = 1_000;

        address[] memory paymentTokens = new address[](1);
        paymentTokens[0] = address(usdc);

        address[] memory adapters = new address[](1);
        adapters[0] = adapter_;

        config = NARAImmutableBasketPositionManagerV1.BasketDeploymentConfig({
            categoryId: MEME,
            basketName: "Meme Basket",
            displayTier: 3,
            assets: assets,
            weightsBps: weights,
            paymentTokens: paymentTokens,
            adapters: adapters,
            buyFeeBps: 100,
            sellFeeBps: 100,
            withdrawFeeBps: 100,
            holdingFeeBps: 100,
            referralShareBps: 3_000,
            maxWeightDeviationBps: 25,
            minInputAmount: 0,
            feeRecipient: feeRecipient,
            requiredAssetAdapter: adapter_
        });
    }
}
