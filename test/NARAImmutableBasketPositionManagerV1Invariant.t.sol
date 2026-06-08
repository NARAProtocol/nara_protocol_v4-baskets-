// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {
    INARABasketSwapAdapterV1,
    NARAImmutableBasketPositionManagerV1
} from "../src/NARAImmutableBasketPositionManagerV1.sol";

contract InvariantBasketMockERC20 is ERC20 {
    uint8 private immutable _decimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract InvariantBasketBlockingERC20 is InvariantBasketMockERC20 {
    bool public transfersBlocked;

    constructor(string memory name_, string memory symbol_, uint8 decimals_)
        InvariantBasketMockERC20(name_, symbol_, decimals_)
    {}

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

contract InvariantBasketMockSwapAdapter is INARABasketSwapAdapterV1 {
    using SafeERC20 for IERC20;

    mapping(address => mapping(address => uint256)) public rate1e18;

    function setRate(address tokenIn, address tokenOut, uint256 rate) external {
        rate1e18[tokenIn][tokenOut] = rate;
    }

    function swapExactInput(address tokenIn, address tokenOut, uint256 amountIn, uint256 minAmountOut, bytes calldata)
        external
        returns (uint256 amountInUsed, uint256 amountOut)
    {
        amountInUsed = amountIn;
        amountOut = amountIn * rate1e18[tokenIn][tokenOut] / 1e18;
        require(amountOut >= minAmountOut, "slippage");

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenOut).safeTransfer(msg.sender, amountOut);
    }
}

contract ManagerLifecycleHandler is Test {
    uint256 internal constant BPS = 10_000;
    bytes32 internal constant CULTURE = keccak256("CULTURE");

    InvariantBasketMockERC20 public usdc;
    InvariantBasketMockERC20 public nara;
    InvariantBasketMockERC20 public pepe;
    InvariantBasketMockERC20 public doge;
    InvariantBasketBlockingERC20 public bonk;
    InvariantBasketMockSwapAdapter public adapter;
    NARAImmutableBasketPositionManagerV1 public manager;

    address public feeRecipient = address(0xFEE);

    address[3] internal buyers;
    address[2] internal referrers;
    address[] internal trackedTokens;
    uint256[] internal openTokenIds;
    uint256[] internal allTokenIds;
    mapping(uint256 => uint256) internal openIndexPlusOne;

    constructor() {
        vm.warp(1);

        buyers[0] = address(0xA11CE);
        buyers[1] = address(0xB0B);
        buyers[2] = address(0xCAFE);
        referrers[0] = address(0xBEEF);
        referrers[1] = address(0xC011);

        usdc = new InvariantBasketMockERC20("USD Coin", "USDC", 18);
        nara = new InvariantBasketMockERC20("NARA", "NARA", 18);
        pepe = new InvariantBasketMockERC20("Pepe", "PEPE", 18);
        doge = new InvariantBasketMockERC20("Doge", "DOGE", 18);
        bonk = new InvariantBasketBlockingERC20("Bonk", "BONK", 18);
        adapter = new InvariantBasketMockSwapAdapter();

        manager = new NARAImmutableBasketPositionManagerV1(
            "NARA Culture Basket Position", "NCBP", address(nara), 1_000, _deploymentConfig()
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

        uint256 inventory = 1_000_000_000_000 ether;
        usdc.mint(address(adapter), inventory);
        nara.mint(address(adapter), inventory);
        pepe.mint(address(adapter), inventory);
        doge.mint(address(adapter), inventory);
        bonk.mint(address(adapter), inventory);

        trackedTokens.push(address(usdc));
        trackedTokens.push(address(nara));
        trackedTokens.push(address(pepe));
        trackedTokens.push(address(doge));
        trackedTokens.push(address(bonk));
    }

    function buy(uint96 rawAmount, uint8 buyerSeed, uint8 refSeed) public {
        if (bonk.transfersBlocked()) return;

        address buyer = buyers[buyerSeed % buyers.length];
        uint256 inputAmount = _boundToRange(uint256(rawAmount), 1, 1_000) * 100 ether;
        address referrer;
        if (refSeed % 3 != 0) {
            referrer = referrers[refSeed % referrers.length];
            if (referrer == buyer) referrer = address(0);
        }

        usdc.mint(buyer, inputAmount);

        vm.startPrank(buyer);
        usdc.approve(address(manager), inputAmount);

        try manager.buyBasket(_buyParams(inputAmount, buyer, referrer)) returns (uint256 tokenId, uint256[] memory) {
            _addOpenTokenId(tokenId);
            allTokenIds.push(tokenId);
            _assertManagerSolvent();
        } catch {}

        vm.stopPrank();
    }

    function sellWholeToUsdc(uint256 seed) public {
        (uint256 tokenId, address owner) = _openPosition(seed);
        if (tokenId == 0) return;
        if (bonk.transfersBlocked() && manager.positionAmountOf(tokenId, address(bonk)) != 0) return;

        uint256 count;
        address[] memory assets = _basketAssets();
        for (uint256 i = 0; i < assets.length; i++) {
            if (manager.positionAmountOf(tokenId, assets[i]) != 0) count++;
        }
        if (count == 0) return;

        NARAImmutableBasketPositionManagerV1.SellParams memory params;
        params.tokenId = tokenId;
        params.outputToken = address(usdc);
        params.receiver = owner;
        params.deadline = block.timestamp + 1 hours;
        params.swaps = new NARAImmutableBasketPositionManagerV1.SwapInstruction[](count);

        uint256 cursor;
        for (uint256 i = 0; i < assets.length; i++) {
            uint256 amount = manager.positionAmountOf(tokenId, assets[i]);
            if (amount == 0) continue;
            params.swaps[cursor++] = _swap(assets[i], address(usdc), amount, amount * 2);
        }

        vm.startPrank(owner);
        try manager.sellBasket(params) returns (uint256, uint256) {
            _removeOpenTokenId(tokenId);
            _assertManagerSolvent();
        } catch {}
        vm.stopPrank();
    }

    function sellWholeToNara(uint256 seed) public {
        (uint256 tokenId, address owner) = _openPosition(seed);
        if (tokenId == 0) return;
        if (bonk.transfersBlocked() && manager.positionAmountOf(tokenId, address(bonk)) != 0) return;

        uint256 count;
        address[] memory assets = _basketAssets();
        for (uint256 i = 0; i < assets.length; i++) {
            if (assets[i] != address(nara) && manager.positionAmountOf(tokenId, assets[i]) != 0) count++;
        }

        NARAImmutableBasketPositionManagerV1.SellParams memory params;
        params.tokenId = tokenId;
        params.outputToken = address(nara);
        params.receiver = owner;
        params.deadline = block.timestamp + 1 hours;
        params.swaps = new NARAImmutableBasketPositionManagerV1.SwapInstruction[](count);

        uint256 cursor;
        for (uint256 i = 0; i < assets.length; i++) {
            uint256 amount = manager.positionAmountOf(tokenId, assets[i]);
            if (assets[i] == address(nara) || amount == 0) continue;
            params.swaps[cursor++] = _swap(assets[i], address(nara), amount, amount);
        }

        vm.startPrank(owner);
        try manager.sellBasket(params) returns (uint256, uint256) {
            _removeOpenTokenId(tokenId);
            _assertManagerSolvent();
        } catch {}
        vm.stopPrank();
    }

    function sellSelectedToUsdc(uint256 seed, uint8 mask) public {
        (uint256 tokenId, address owner) = _openPosition(seed);
        if (tokenId == 0) return;

        address[] memory assets = _basketAssets();
        uint256 count;
        for (uint256 i = 0; i < assets.length; i++) {
            if ((mask & uint8(1 << i)) == 0) continue;
            if (assets[i] == address(bonk) && bonk.transfersBlocked()) continue;
            if (manager.positionAmountOf(tokenId, assets[i]) != 0) count++;
        }
        if (count == 0) return;

        NARAImmutableBasketPositionManagerV1.PartialSellParams memory params;
        params.tokenId = tokenId;
        params.outputToken = address(usdc);
        params.receiver = owner;
        params.deadline = block.timestamp + 1 hours;
        params.swaps = new NARAImmutableBasketPositionManagerV1.SwapInstruction[](count);

        uint256 cursor;
        for (uint256 i = 0; i < assets.length; i++) {
            if ((mask & uint8(1 << i)) == 0) continue;
            if (assets[i] == address(bonk) && bonk.transfersBlocked()) continue;
            uint256 amount = manager.positionAmountOf(tokenId, assets[i]);
            if (amount == 0) continue;
            params.swaps[cursor++] = _swap(assets[i], address(usdc), amount, amount * 2);
        }

        vm.startPrank(owner);
        try manager.sellBasketPartial(params) returns (uint256, uint256, bool closed) {
            if (closed) _removeOpenTokenId(tokenId);
            _assertManagerSolvent();
        } catch {}
        vm.stopPrank();
    }

    function withdrawSelected(uint256 seed, uint8 mask) public {
        (uint256 tokenId, address owner) = _openPosition(seed);
        if (tokenId == 0) return;

        address[] memory assets = _basketAssets();
        uint256 count;
        for (uint256 i = 0; i < assets.length; i++) {
            if ((mask & uint8(1 << i)) == 0) continue;
            if (assets[i] == address(bonk) && bonk.transfersBlocked()) continue;
            if (manager.positionAmountOf(tokenId, assets[i]) != 0) count++;
        }
        if (count == 0) return;

        address[] memory selected = new address[](count);
        uint256 cursor;
        for (uint256 i = 0; i < assets.length; i++) {
            if ((mask & uint8(1 << i)) == 0) continue;
            if (assets[i] == address(bonk) && bonk.transfersBlocked()) continue;
            if (manager.positionAmountOf(tokenId, assets[i]) == 0) continue;
            selected[cursor++] = assets[i];
        }

        vm.startPrank(owner);
        try manager.withdrawUnderlyingPartial(tokenId, owner, selected) returns (uint256[] memory, bool closed) {
            if (closed) _removeOpenTokenId(tokenId);
            _assertManagerSolvent();
        } catch {}
        vm.stopPrank();
    }

    function withdrawWhole(uint256 seed) public {
        (uint256 tokenId, address owner) = _openPosition(seed);
        if (tokenId == 0) return;
        if (bonk.transfersBlocked() && manager.positionAmountOf(tokenId, address(bonk)) != 0) return;

        vm.startPrank(owner);
        try manager.withdrawUnderlying(tokenId, owner) returns (uint256[] memory) {
            _removeOpenTokenId(tokenId);
            _assertManagerSolvent();
        } catch {}
        vm.stopPrank();
    }

    function accrueOne(uint256 seed, uint64 elapsed) public {
        (uint256 tokenId,) = _openPosition(seed);
        if (tokenId == 0) return;

        uint256[] memory ids = new uint256[](1);
        ids[0] = tokenId;
        vm.warp(block.timestamp + _boundToRange(uint256(elapsed), 1, 90 days));

        try manager.accrueHoldingFee(ids) {
            _assertManagerSolvent();
        } catch {}
    }

    function claimReferral(uint8 refSeed, uint8 tokenSeed) public {
        address referrer = referrers[refSeed % referrers.length];
        address token = trackedTokens[tokenSeed % trackedTokens.length];
        if (manager.referralRewards(referrer, token) == 0) return;

        vm.startPrank(referrer);
        try manager.claimReferralReward(token, referrer) returns (uint256) {
            _assertManagerSolvent();
        } catch {}
        vm.stopPrank();
    }

    function sweepFee(uint8 tokenSeed) public {
        address token = trackedTokens[tokenSeed % trackedTokens.length];
        if (token == address(bonk) && bonk.transfersBlocked()) return;
        if (manager.protocolFeeAccrued(token) == 0) return;

        try manager.sweepAccruedFee(token) returns (uint256) {
            _assertManagerSolvent();
        } catch {}
    }

    function setBadTokenBlocked(bool blocked) public {
        bonk.setTransfersBlocked(blocked);
        _assertManagerSolvent();
    }

    function assertManagerSolvent() external view {
        _assertManagerSolvent();
    }

    function trackedTokenCount() external view returns (uint256) {
        return trackedTokens.length;
    }

    function trackedTokenAt(uint256 index) external view returns (address) {
        return trackedTokens[index];
    }

    function allTokenIdCount() external view returns (uint256) {
        return allTokenIds.length;
    }

    function allTokenIdAt(uint256 index) external view returns (uint256) {
        return allTokenIds[index];
    }

    function activeTokenIdCount() external view returns (uint256) {
        return openTokenIds.length;
    }

    function _assertManagerSolvent() internal view {
        for (uint256 i = 0; i < trackedTokens.length; i++) {
            (uint256 balance, uint256 accounted, bool solvent, uint256 surplusOrDeficit) =
                manager.assetSolvency(trackedTokens[i]);

            require(solvent, "manager insolvent");
            require(surplusOrDeficit == 0, "unexpected manager surplus");
            require(balance == accounted, "balance/accounting mismatch");
        }
    }

    function _openPosition(uint256 seed) internal returns (uint256 tokenId, address owner) {
        while (openTokenIds.length != 0) {
            uint256 index = seed % openTokenIds.length;
            tokenId = openTokenIds[index];

            try manager.ownerOf(tokenId) returns (address currentOwner) {
                return (tokenId, currentOwner);
            } catch {
                _removeOpenTokenIdAt(index);
            }
        }

        return (0, address(0));
    }

    function _addOpenTokenId(uint256 tokenId) internal {
        if (openIndexPlusOne[tokenId] != 0) return;
        openTokenIds.push(tokenId);
        openIndexPlusOne[tokenId] = openTokenIds.length;
    }

    function _removeOpenTokenId(uint256 tokenId) internal {
        uint256 indexPlusOne = openIndexPlusOne[tokenId];
        if (indexPlusOne == 0) return;
        _removeOpenTokenIdAt(indexPlusOne - 1);
    }

    function _removeOpenTokenIdAt(uint256 index) internal {
        uint256 tokenId = openTokenIds[index];
        uint256 last = openTokenIds[openTokenIds.length - 1];

        openTokenIds[index] = last;
        openIndexPlusOne[last] = index + 1;
        openTokenIds.pop();
        delete openIndexPlusOne[tokenId];
    }

    function _buyParams(uint256 inputAmount, address receiver, address referrer)
        internal
        view
        returns (NARAImmutableBasketPositionManagerV1.BuyParams memory params)
    {
        uint256 netInput = inputAmount * 9_900 / BPS;

        params.paymentToken = address(usdc);
        params.inputAmount = inputAmount;
        params.receiver = receiver;
        params.referrer = referrer;
        params.deadline = block.timestamp + 1 hours;
        params.directAmountsIn = new uint256[](4);
        params.minAmountsOut = new uint256[](4);
        params.swaps = new NARAImmutableBasketPositionManagerV1.SwapInstruction[](4);
        params.swaps[0] = _swap(address(usdc), address(nara), netInput * 1_000 / BPS, netInput * 1_000 / BPS);
        params.swaps[1] = _swap(address(usdc), address(pepe), netInput * 5_000 / BPS, netInput * 5_000 / BPS * 2);
        params.swaps[2] = _swap(address(usdc), address(doge), netInput * 3_000 / BPS, netInput * 3_000 / BPS);
        params.swaps[3] = _swap(address(usdc), address(bonk), netInput * 1_000 / BPS, netInput * 1_000 / BPS);
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

    function _basketAssets() internal view returns (address[] memory assets) {
        assets = new address[](4);
        assets[0] = address(nara);
        assets[1] = address(pepe);
        assets[2] = address(doge);
        assets[3] = address(bonk);
    }

    function _boundToRange(uint256 value, uint256 min, uint256 max) internal pure returns (uint256) {
        return min + (value % (max - min + 1));
    }

    function _deploymentConfig()
        internal
        view
        returns (NARAImmutableBasketPositionManagerV1.BasketDeploymentConfig memory config)
    {
        address[] memory assets = _basketAssets();

        uint16[] memory weights = new uint16[](4);
        weights[0] = 1_000;
        weights[1] = 5_000;
        weights[2] = 3_000;
        weights[3] = 1_000;

        address[] memory paymentTokens = new address[](1);
        paymentTokens[0] = address(usdc);

        address[] memory adapters = new address[](1);
        adapters[0] = address(adapter);

        config = NARAImmutableBasketPositionManagerV1.BasketDeploymentConfig({
            categoryId: CULTURE,
            basketName: "Culture Basket",
            displayTier: 1,
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
            requiredAssetAdapter: address(adapter)
        });
    }
}

contract NARAImmutableBasketPositionManagerV1InvariantTest is StdInvariant, Test {
    ManagerLifecycleHandler internal handler;

    function setUp() public {
        handler = new ManagerLifecycleHandler();

        bytes4[] memory selectors = new bytes4[](10);
        selectors[0] = ManagerLifecycleHandler.buy.selector;
        selectors[1] = ManagerLifecycleHandler.sellWholeToUsdc.selector;
        selectors[2] = ManagerLifecycleHandler.sellWholeToNara.selector;
        selectors[3] = ManagerLifecycleHandler.sellSelectedToUsdc.selector;
        selectors[4] = ManagerLifecycleHandler.withdrawSelected.selector;
        selectors[5] = ManagerLifecycleHandler.withdrawWhole.selector;
        selectors[6] = ManagerLifecycleHandler.accrueOne.selector;
        selectors[7] = ManagerLifecycleHandler.claimReferral.selector;
        selectors[8] = ManagerLifecycleHandler.sweepFee.selector;
        selectors[9] = ManagerLifecycleHandler.setBadTokenBlocked.selector;

        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_ManagerBalanceEqualsAccountedLiabilities() public view {
        handler.assertManagerSolvent();
    }

    function invariant_TotalAccountedAssetEqualsOpenPositionSums() public view {
        NARAImmutableBasketPositionManagerV1 manager = handler.manager();
        uint256 tokenCount = handler.trackedTokenCount();
        uint256 idCount = handler.allTokenIdCount();

        for (uint256 tokenIndex = 0; tokenIndex < tokenCount; tokenIndex++) {
            address token = handler.trackedTokenAt(tokenIndex);
            if (token == address(handler.usdc())) continue;

            uint256 sum;
            for (uint256 idIndex = 0; idIndex < idCount; idIndex++) {
                sum += manager.positionAmountOf(handler.allTokenIdAt(idIndex), token);
            }

            assertEq(manager.totalAccountedAsset(token), sum, "accounted asset sum mismatch");
        }
    }

    function invariant_ReceiptOpenStateMatchesRemainingAssets() public view {
        NARAImmutableBasketPositionManagerV1 manager = handler.manager();
        uint256 idCount = handler.allTokenIdCount();

        for (uint256 idIndex = 0; idIndex < idCount; idIndex++) {
            uint256 tokenId = handler.allTokenIdAt(idIndex);
            uint256 remaining;

            for (uint256 tokenIndex = 0; tokenIndex < handler.trackedTokenCount(); tokenIndex++) {
                address token = handler.trackedTokenAt(tokenIndex);
                if (token == address(handler.usdc())) continue;
                remaining += manager.positionAmountOf(tokenId, token);
            }

            (,, , , bool closed) = manager.positionOf(tokenId);

            try manager.ownerOf(tokenId) returns (address owner) {
                assertNotEq(owner, address(0), "open receipt owner");
                assertFalse(closed, "open receipt marked closed");
                assertGt(remaining, 0, "open receipt has no remaining assets");
            } catch {
                assertTrue(closed, "burned receipt not marked closed");
                assertEq(remaining, 0, "burned receipt still has assets");
            }
        }
    }

    function testFuzzSelectedAssetRescueKeepsSolvencyWhenBadTokenBlocks(uint8 mode, uint64 elapsed) public {
        handler.buy(10, 0, 1);
        assertEq(handler.activeTokenIdCount(), 1);

        uint256 tokenId = handler.allTokenIdAt(0);
        NARAImmutableBasketPositionManagerV1 manager = handler.manager();
        address badAsset = address(handler.bonk());

        handler.setBadTokenBlocked(true);
        handler.accrueOne(0, elapsed);

        if (mode % 2 == 0) {
            handler.withdrawSelected(0, 0x07);
        } else {
            handler.sellSelectedToUsdc(0, 0x07);
        }

        handler.assertManagerSolvent();
        assertEq(handler.activeTokenIdCount(), 1, "residual bad-token receipt should stay open");
        assertEq(manager.ownerOf(tokenId), address(0xA11CE));
        assertGt(manager.positionAmountOf(tokenId, badAsset), 0, "bad asset remains accounted");
        assertEq(manager.totalAccountedAsset(address(handler.nara())), 0);
        assertEq(manager.totalAccountedAsset(address(handler.pepe())), 0);
        assertEq(manager.totalAccountedAsset(address(handler.doge())), 0);

        handler.setBadTokenBlocked(false);
        handler.withdrawWhole(0);
        handler.assertManagerSolvent();
        assertEq(handler.activeTokenIdCount(), 0, "receipt should close after bad token recovers");
    }
}
