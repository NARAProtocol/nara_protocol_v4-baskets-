// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {NARAImmutableBasketPositionManagerV1} from "../src/NARAImmutableBasketPositionManagerV1.sol";

interface IQuoterV2 {
    struct P { address tokenIn; address tokenOut; uint256 amountIn; uint24 fee; uint160 lim; }
    function quoteExactInputSingle(P calldata p) external returns (uint256, uint160, uint32, uint256);
}
interface IAeroRouter {
    struct Route { address from; address to; bool stable; address factory; }
    function getAmountsOut(uint256 a, Route[] calldata r) external view returns (uint256[] memory);
}

/// @notice Proves an env-provided CORE basket on a local fork executes a real buy with real swaps.
/// @dev Required env: FORK_MANAGER_CORE, FORK_V3_ADAPTER, FORK_AERO_ADAPTER, FORK_NARA_TOKEN.
///      This test skips when env/deployed code is absent so stale hardcoded addresses cannot pass.
///      Run against the running anvil fork:
///        forge test --match-contract ForkBuyProof --fork-url http://localhost:8545 -vv
contract ForkBuyProof is Test {
    address constant USDC   = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant WETH   = 0x4200000000000000000000000000000000000006;
    address constant QUOTER = 0x222cA98F00eD15B1faE10B61c277703a194cf5d2;
    address constant AERO_ROUTER  = 0xcF77a3Ba9A5CA399B7c97c74d54e5b1Beb874E43;
    address constant AERO_FACTORY = 0x420DD381b31aEf6683db6B902084cB0FFECe40Da;

    address constant cbBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
    address constant cbETH = 0x2Ae3F1Ec7F1F5012CFEab0185bfc7aa3cf0DEc22;
    address constant AERO  = 0x940181a94A35A4569E4529A3CDfB74e38FD98631;

    address manager;
    address v3Adapter;
    address aeroAdapter;
    address naraToken;
    address user = address(0xBEEF);

    function setUp() public {
        manager = vm.envOr("FORK_MANAGER_CORE", address(0));
        v3Adapter = vm.envOr("FORK_V3_ADAPTER", address(0));
        aeroAdapter = vm.envOr("FORK_AERO_ADAPTER", address(0));
        naraToken = vm.envOr("FORK_NARA_TOKEN", address(0));

        if (
            manager == address(0) || v3Adapter == address(0) || aeroAdapter == address(0)
                || naraToken == address(0)
        ) {
            vm.skip(true, "missing fork proof env");
        }
        if (manager.code.length == 0 || v3Adapter.code.length == 0 || aeroAdapter.code.length == 0) {
            vm.skip(true, "fork proof deployment missing");
        }
    }

    function testForkBuyCore() public {
        // Fund user with 1,000 USDC via forge cheat (works on fork)
        deal(USDC, user, 1_000e6);

        uint256 input = 1_000e6;
        uint256 net = input - (input * 10 / 10000);
        uint16[5] memory w = [uint16(1000), 3000, 3000, 2000, 1000];
        uint256[5] memory a;
        uint256 sum;
        for (uint256 i; i < 5; i++) { a[i] = net * w[i] / 10000; sum += a[i]; }
        a[1] += net - sum;

        uint256 qNara  = _qV3(naraToken, a[0], 3000);
        uint256 qCb    = _qV3(cbBTC, a[1], 500);
        uint256 qWeth  = _qV3(WETH, a[2], 500);
        uint256 qAero  = _qAeroSingle(AERO, a[3]);
        uint256 qCbeth = _qAeroSingle(cbETH, a[4]);

        NARAImmutableBasketPositionManagerV1.SwapInstruction[] memory s =
            new NARAImmutableBasketPositionManagerV1.SwapInstruction[](5);
        s[0] = _v3(naraToken,  a[0], _m(qNara),  3000);
        s[1] = _v3(cbBTC, a[1], _m(qCb),    500);
        s[2] = _v3(WETH,  a[2], _m(qWeth),  500);
        s[3] = _aeroSingle(AERO, a[3], _m(qAero));
        s[4] = _aeroSingle(cbETH, a[4], _m(qCbeth));

        uint256[] memory minOut = new uint256[](5);
        minOut[0]=_m(qNara); minOut[1]=_m(qCb); minOut[2]=_m(qWeth); minOut[3]=_m(qAero); minOut[4]=_m(qCbeth);

        NARAImmutableBasketPositionManagerV1.BuyParams memory p =
        NARAImmutableBasketPositionManagerV1.BuyParams({
            paymentToken: USDC, inputAmount: input,
            directAmountsIn: new uint256[](5), minAmountsOut: minOut,
            swaps: s, receiver: user, referrer: address(0), deadline: block.timestamp + 600
        });

        vm.startPrank(user);
        IERC20(USDC).approve(manager, input);
        (uint256 tokenId, uint256[] memory bought) =
            NARAImmutableBasketPositionManagerV1(manager).buyBasket(p);
        vm.stopPrank();

        console2.log("=== FORK BUY PROOF: CORE basket ===");
        console2.log("tokenId minted to user", tokenId);
        console2.log("NARA bought       ", bought[0]);
        console2.log("cbBTC bought      ", bought[1]);
        console2.log("WETH bought       ", bought[2]);
        console2.log("AERO bought       ", bought[3]);
        console2.log("cbETH bought      ", bought[4]);

        // Assertions: NFT owned by user, all 5 legs non-zero, USDC spent.
        assertEq(NARAImmutableBasketPositionManagerV1(manager).ownerOf(tokenId), user, "user owns NFT");
        for (uint256 i; i < 5; i++) assertGt(bought[i], 0, "each asset bought > 0");
        assertEq(IERC20(USDC).balanceOf(user), 0, "all USDC spent");
    }

    function _m(uint256 q) internal pure returns (uint256) { return q * 9950 / 10000; }
    function _qV3(address o, uint256 amt, uint24 f) internal returns (uint256 out) {
        (out,,,) = IQuoterV2(QUOTER).quoteExactInputSingle(IQuoterV2.P(USDC, o, amt, f, 0));
    }
    function _qAeroSingle(address o, uint256 amt) internal view returns (uint256) {
        IAeroRouter.Route[] memory r = new IAeroRouter.Route[](1);
        r[0] = IAeroRouter.Route(USDC, o, false, AERO_FACTORY);
        uint256[] memory x = IAeroRouter(AERO_ROUTER).getAmountsOut(amt, r);
        return x[x.length-1];
    }
    function _qAeroVia(address o, uint256 amt) internal view returns (uint256) {
        IAeroRouter.Route[] memory r = new IAeroRouter.Route[](2);
        r[0] = IAeroRouter.Route(USDC, WETH, false, AERO_FACTORY);
        r[1] = IAeroRouter.Route(WETH, o, false, AERO_FACTORY);
        uint256[] memory x = IAeroRouter(AERO_ROUTER).getAmountsOut(amt, r);
        return x[x.length-1];
    }
    function _v3(address o, uint256 amt, uint256 mo, uint24 f)
        internal view returns (NARAImmutableBasketPositionManagerV1.SwapInstruction memory)
    {
        return NARAImmutableBasketPositionManagerV1.SwapInstruction(v3Adapter, USDC, o, amt, mo, abi.encode(f, uint160(0)));
    }
    function _aeroSingle(address o, uint256 amt, uint256 mo)
        internal view returns (NARAImmutableBasketPositionManagerV1.SwapInstruction memory)
    {
        IAeroRouter.Route[] memory r = new IAeroRouter.Route[](1);
        r[0] = IAeroRouter.Route(USDC, o, false, AERO_FACTORY);
        return NARAImmutableBasketPositionManagerV1.SwapInstruction(aeroAdapter, USDC, o, amt, mo, abi.encode(r));
    }
    function _aeroVia(address o, uint256 amt, uint256 mo)
        internal view returns (NARAImmutableBasketPositionManagerV1.SwapInstruction memory)
    {
        IAeroRouter.Route[] memory r = new IAeroRouter.Route[](2);
        r[0] = IAeroRouter.Route(USDC, WETH, false, AERO_FACTORY);
        r[1] = IAeroRouter.Route(WETH, o, false, AERO_FACTORY);
        return NARAImmutableBasketPositionManagerV1.SwapInstruction(aeroAdapter, USDC, o, amt, mo, abi.encode(r));
    }
}
