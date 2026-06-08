// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {NARAImmutableBasketPositionManagerV1} from "../src/NARAImmutableBasketPositionManagerV1.sol";

interface IQuoterV2 {
    struct QuoteExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint24 fee;
        uint160 sqrtPriceLimitX96;
    }
    function quoteExactInputSingle(QuoteExactInputSingleParams calldata params)
        external returns (uint256 amountOut, uint160, uint32, uint256);
}

interface IAeroRouter {
    struct Route { address from; address to; bool stable; address factory; }
    function getAmountsOut(uint256 amountIn, Route[] calldata routes)
        external view returns (uint256[] memory amounts);
}

/// @notice Fork-only: replicates the UI buy flow for the CORE basket to prove real swaps execute.
contract TestBuyFork is Script {
    address constant USDC    = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant WETH    = 0x4200000000000000000000000000000000000006;
    address constant QUOTER  = 0x222cA98F00eD15B1faE10B61c277703a194cf5d2; // Base QuoterV2
    address constant AERO_ROUTER  = 0xcF77a3Ba9A5CA399B7c97c74d54e5b1Beb874E43;
    address constant AERO_FACTORY = 0x420DD381b31aEf6683db6B902084cB0FFECe40Da;

    address constant LINK  = 0x88Fb150BDc53A65fe94Dea0c9BA0a6dAf8C6e196; // NARA stand-in
    address constant cbBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
    address constant cbETH = 0x2Ae3F1Ec7F1F5012CFEab0185bfc7aa3cf0DEc22;
    address constant AERO  = 0x940181a94A35A4569E4529A3CDfB74e38FD98631;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address user = vm.addr(pk);
        address mgr = vm.envAddress("MANAGER");
        address v3 = vm.envAddress("V3_ADAPTER");
        address aero = vm.envAddress("AERO_ADAPTER");

        uint256 input = 1000e6; // 1,000 USDC
        uint16 buyFeeBps = 10;
        uint256 net = input - (input * buyFeeBps / 10000);

        // CORE weights: LINK 1000 / cbBTC 3000 / WETH 3000 / AERO 2000 / cbETH 1000
        uint16[5] memory w = [uint16(1000), 3000, 3000, 2000, 1000];
        uint256[5] memory alloc;
        uint256 sum;
        for (uint256 i = 0; i < 5; i++) { alloc[i] = net * w[i] / 10000; sum += alloc[i]; }
        alloc[1] += net - sum; // dust to largest (cbBTC), matches UI

        // ── Quotes (USDC -> each asset) ──
        uint256 qLink  = _quoteV3(USDC, LINK, alloc[0], 3000);
        uint256 qCbbtc = _quoteV3(USDC, cbBTC, alloc[1], 500);
        uint256 qWeth  = _quoteV3(USDC, WETH, alloc[2], 500);
        uint256 qAero  = _quoteAeroSingle(USDC, AERO, alloc[3]);
        uint256 qCbeth = _quoteAeroSingle(USDC, cbETH, alloc[4]);

        console2.log("Quotes (raw out):");
        console2.log("  LINK ", qLink);
        console2.log("  cbBTC", qCbbtc);
        console2.log("  WETH ", qWeth);
        console2.log("  AERO ", qAero);
        console2.log("  cbETH", qCbeth);

        // Use prank instead of broadcast so forge doesn't try to relay the minted NFT.
        vm.startPrank(user);

        IERC20(USDC).approve(mgr, input);

        NARAImmutableBasketPositionManagerV1.SwapInstruction[] memory swaps =
            new NARAImmutableBasketPositionManagerV1.SwapInstruction[](5);
        swaps[0] = _v3Swap(v3, USDC, LINK,  alloc[0], _slip(qLink),  3000);
        swaps[1] = _v3Swap(v3, USDC, cbBTC, alloc[1], _slip(qCbbtc), 500);
        swaps[2] = _v3Swap(v3, USDC, WETH,  alloc[2], _slip(qWeth),  500);
        swaps[3] = _aeroSwapSingle(aero, USDC, AERO, alloc[3], _slip(qAero));
        swaps[4] = _aeroSwapSingle(aero, USDC, cbETH, alloc[4], _slip(qCbeth));

        uint256[] memory directIn = new uint256[](5);
        uint256[] memory minOut = new uint256[](5);
        minOut[0] = _slip(qLink); minOut[1] = _slip(qCbbtc); minOut[2] = _slip(qWeth);
        minOut[3] = _slip(qAero); minOut[4] = _slip(qCbeth);

        NARAImmutableBasketPositionManagerV1.BuyParams memory params =
        NARAImmutableBasketPositionManagerV1.BuyParams({
            paymentToken: USDC,
            inputAmount: input,
            directAmountsIn: directIn,
            minAmountsOut: minOut,
            swaps: swaps,
            receiver: user,
            referrer: address(0),
            deadline: block.timestamp + 600
        });

        (uint256 tokenId, uint256[] memory bought) =
            NARAImmutableBasketPositionManagerV1(mgr).buyBasket(params);

        vm.stopPrank();

        console2.log("=== BUY SUCCESS ===");
        console2.log("tokenId", tokenId);
        console2.log("bought LINK ", bought[0]);
        console2.log("bought cbBTC", bought[1]);
        console2.log("bought WETH ", bought[2]);
        console2.log("bought AERO ", bought[3]);
        console2.log("bought cbETH", bought[4]);
    }

    function _slip(uint256 q) internal pure returns (uint256) { return q * 9950 / 10000; }

    function _quoteV3(address i, address o, uint256 a, uint24 f) internal returns (uint256 out) {
        (out,,,) = IQuoterV2(QUOTER).quoteExactInputSingle(
            IQuoterV2.QuoteExactInputSingleParams(i, o, a, f, 0));
    }
    function _quoteAeroSingle(address i, address o, uint256 a) internal view returns (uint256) {
        IAeroRouter.Route[] memory r = new IAeroRouter.Route[](1);
        r[0] = IAeroRouter.Route(i, o, false, AERO_FACTORY);
        uint256[] memory amts = IAeroRouter(AERO_ROUTER).getAmountsOut(a, r);
        return amts[amts.length - 1];
    }
    function _quoteAeroVia(address i, address via, address o, uint256 a) internal view returns (uint256) {
        IAeroRouter.Route[] memory r = new IAeroRouter.Route[](2);
        r[0] = IAeroRouter.Route(i, via, false, AERO_FACTORY);
        r[1] = IAeroRouter.Route(via, o, false, AERO_FACTORY);
        uint256[] memory amts = IAeroRouter(AERO_ROUTER).getAmountsOut(a, r);
        return amts[amts.length - 1];
    }

    function _v3Swap(address adapter, address i, address o, uint256 a, uint256 m, uint24 f)
        internal pure returns (NARAImmutableBasketPositionManagerV1.SwapInstruction memory)
    {
        return NARAImmutableBasketPositionManagerV1.SwapInstruction({
            adapter: adapter, tokenIn: i, tokenOut: o, amountIn: a, minAmountOut: m,
            data: abi.encode(f, uint160(0))
        });
    }
    function _aeroSwapSingle(address adapter, address i, address o, uint256 a, uint256 m)
        internal pure returns (NARAImmutableBasketPositionManagerV1.SwapInstruction memory)
    {
        IAeroRouter.Route[] memory r = new IAeroRouter.Route[](1);
        r[0] = IAeroRouter.Route(i, o, false, AERO_FACTORY);
        return NARAImmutableBasketPositionManagerV1.SwapInstruction({
            adapter: adapter, tokenIn: i, tokenOut: o, amountIn: a, minAmountOut: m, data: abi.encode(r)
        });
    }
    function _aeroSwapVia(address adapter, address i, address via, address o, uint256 a, uint256 m)
        internal pure returns (NARAImmutableBasketPositionManagerV1.SwapInstruction memory)
    {
        IAeroRouter.Route[] memory r = new IAeroRouter.Route[](2);
        r[0] = IAeroRouter.Route(i, via, false, AERO_FACTORY);
        r[1] = IAeroRouter.Route(via, o, false, AERO_FACTORY);
        return NARAImmutableBasketPositionManagerV1.SwapInstruction({
            adapter: adapter, tokenIn: i, tokenOut: o, amountIn: a, minAmountOut: m, data: abi.encode(r)
        });
    }
}
