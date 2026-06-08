// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {UniswapV3BasketAdapterV1} from "../src/adapters/UniswapV3BasketAdapterV1.sol";
import {AerodromeBasketAdapterV1} from "../src/adapters/AerodromeBasketAdapterV1.sol";
import {AerodromeSlipstreamBasketAdapterV1} from "../src/adapters/AerodromeSlipstreamBasketAdapterV1.sol";
import {PancakeV3BasketAdapterV1} from "../src/adapters/PancakeV3BasketAdapterV1.sol";
import {UniswapV4BasketAdapterV1} from "../src/adapters/UniswapV4BasketAdapterV1.sol";
import {NARAIndexFeeCollectorV2} from "../src/NARAIndexFeeCollectorV2.sol";
import {NARAImmutableBasketPositionManagerV1} from "../src/NARAImmutableBasketPositionManagerV1.sol";

/// @notice Mainnet-ready deploy: V3 adapter + V2 fee collector + one launch basket.
/// @dev Use this script instead of DeployBaseMainnet.s.sol once the v4 core is live.
///
///      Required env:
///        PRIVATE_KEY                 — deployer EOA (ephemeral)
///        ADMIN                       — Safe with timelock (required, not an EOA)
///        NARA_ENGINE                 — deployed NARAEngine v4
///        NARA                        — deployed NARA token v4
///        USDC                        — Base USDC 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
///        WETH                        — Base WETH 0x4200000000000000000000000000000000000006
///        UNISWAP_V3_ROUTER02         — Base SwapRouter02 0x2626664c2603336E57B271c5C0b26F421741e481
///
///      Required selector env (Uniswap V3 SwapRouter02.exactInputSingle):
///        EXECUTOR_0_SELECTOR         — 0x04e45aaf
///
///      Per-basket env (only the first basket; subsequent baskets run separately):
///        BASKET_CATEGORY             — "CORE" | "AI" | "FINANCE" | "CULTURE"
///        BASKET_NAME                 — display name
///        BASKET_DISPLAY_TIER         - neutral legacy metadata; do not display as advice
///        BASKET_BUY_FEE_BPS          — configured buy fee; cap 100
///        BASKET_SELL_FEE_BPS         — configured sell fee; cap 100
///        BASKET_WITHDRAW_FEE_BPS     — optional; in-kind raw-withdraw fee; cap 100; defaults to sell fee
///        BASKET_HOLDING_FEE_BPS      — required; annual in-kind holding fee; cap 200 (2%/yr); set 0 to disable
///        BASKET_REFERRAL_SHARE_BPS   — required; referrer share of buy/sell fee; cap 5000 (50% of fee); set 0 to disable
///        BASKET_MAX_WEIGHT_DEV_BPS   — slippage budget; cap 1000
///        BASKET_MIN_NARA_WEIGHT_BPS  — cap 5000
///        BASKET_ASSETS               — comma-separated list, NARA must be first
///        BASKET_WEIGHTS              — comma-separated bps list, sum 10000
contract DeployMainnetReady is Script {
    uint256 internal constant DEFAULT_MIN_INPUT_AMOUNT = 25_000_000; // 25 USDC

    error WrongChain(uint256 chainId);
    error BadSelectorLength();
    error AdminIsDeployer();
    error BadExpectedAddress(string label, address expected, address actual);
    error AddressHasNoCode(string label, address target);
    error ArrayLengthMismatch(string label, uint256 expected, uint256 actual);

    function run() external {
        if (block.chainid != 8453) revert WrongChain(block.chainid);

        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address admin = vm.envAddress("ADMIN");
        if (admin == deployer) revert AdminIsDeployer();
        _requireCode("ADMIN", admin);
        _requireCode("NARA_ENGINE", vm.envAddress("NARA_ENGINE"));
        _requireCode("NARA", vm.envAddress("NARA"));
        _requireCode("USDC", vm.envAddress("USDC"));
        _requireCode("WETH", vm.envAddress("WETH"));
        _requireCode("UNISWAP_V3_ROUTER02", vm.envAddress("UNISWAP_V3_ROUTER02"));

        vm.startBroadcast(pk);

        address[] memory adapters = _deployAdapters();
        NARAIndexFeeCollectorV2 feeCollector = _deployFeeCollector(deployer);
        NARAImmutableBasketPositionManagerV1 manager = _deployBasket(
            vm.envAddress("NARA"), vm.envAddress("USDC"), vm.envAddress("WETH"), adapters, address(feeCollector)
        );
        _handoffRoles(feeCollector, admin, deployer);

        vm.stopBroadcast();

        _logDeploy(deployer, admin, adapters, address(feeCollector), address(manager));
    }

    /// @dev Deploys the full immutable adapter set so every basket can route across the top Base
    ///      venues. Verified Base routers (override via env if Aerodrome/Pancake ever redeploy):
    ///        Aerodrome AMM Router        0xcF77a3Ba9A5CA399B7c97c74d54e5b1Beb874E43
    ///        Aerodrome Slipstream Router 0xBE6D8f0d05cC4be24d5167a3eF062215bE6D18a5
    ///        PancakeSwap V3 SwapRouter   0x1b81D678ffb9C0263b24A97847620C99d213eB14
    function _deployAdapters() internal returns (address[] memory adapters) {
        address router02 = vm.envAddress("UNISWAP_V3_ROUTER02");
        address aeroRouter = vm.envOr("AERODROME_ROUTER", address(0xcF77a3Ba9A5CA399B7c97c74d54e5b1Beb874E43));
        address aeroFactory = vm.envOr("AERODROME_FACTORY", address(0x420DD381b31aEf6683db6B902084cB0FFECe40Da));
        address slipstreamRouter =
            vm.envOr("AERODROME_SLIPSTREAM_ROUTER", address(0xBE6D8f0d05cC4be24d5167a3eF062215bE6D18a5));
        address pancakeRouter = vm.envOr("PANCAKE_V3_ROUTER", address(0x1b81D678ffb9C0263b24A97847620C99d213eB14));
        address universalRouter = vm.envOr("V4_UNIVERSAL_ROUTER", address(0x6fF5693b99212Da76ad316178A184AB56D299b43));
        address permit2 = vm.envOr("V4_PERMIT2", address(0x000000000022D473030F116dDEE9F6B43aC78BA3));
        _requireCode("UNISWAP_V3_ROUTER02", router02);
        _requireCode("AERODROME_ROUTER", aeroRouter);
        _requireCode("AERODROME_SLIPSTREAM_ROUTER", slipstreamRouter);
        _requireCode("PANCAKE_V3_ROUTER", pancakeRouter);
        _requireCode("V4_UNIVERSAL_ROUTER", universalRouter);
        _requireCode("V4_PERMIT2", permit2);

        adapters = new address[](5);
        adapters[0] = address(new UniswapV3BasketAdapterV1(router02));
        adapters[1] = address(new AerodromeBasketAdapterV1(aeroRouter, aeroFactory));
        adapters[2] = address(new AerodromeSlipstreamBasketAdapterV1(slipstreamRouter));
        adapters[3] = address(new PancakeV3BasketAdapterV1(pancakeRouter));
        adapters[4] = address(new UniswapV4BasketAdapterV1(universalRouter, permit2));
    }

    function _deployFeeCollector(address deployer) internal returns (NARAIndexFeeCollectorV2 feeCollector) {
        address router02 = vm.envAddress("UNISWAP_V3_ROUTER02");
        bytes4 executor0Selector = _envSelector("EXECUTOR_0_SELECTOR");
        address naraEngine = vm.envAddress("NARA_ENGINE");
        address nara = vm.envAddress("NARA");
        address weth = vm.envAddress("WETH");
        _requireCode("NARA_ENGINE", naraEngine);
        _requireCode("NARA", nara);
        _requireCode("WETH", weth);
        _requireCode("UNISWAP_V3_ROUTER02", router02);

        address[] memory executors = new address[](1);
        executors[0] = router02;
        feeCollector = new NARAIndexFeeCollectorV2(
            naraEngine, nara, weth, deployer, executors
        );
        feeCollector.setAllowedSelector(router02, executor0Selector, true);
        feeCollector.freezeAllowlist();
    }

    function _handoffRoles(NARAIndexFeeCollectorV2 feeCollector, address admin, address deployer) internal {
        feeCollector.grantRole(feeCollector.DEFAULT_ADMIN_ROLE(), admin);
        feeCollector.grantRole(feeCollector.SWAPPER_ROLE(), admin);
        feeCollector.grantRole(feeCollector.EXECUTOR_MANAGER_ROLE(), admin);

        feeCollector.renounceRole(feeCollector.SWAPPER_ROLE(), deployer);
        feeCollector.renounceRole(feeCollector.EXECUTOR_MANAGER_ROLE(), deployer);
        feeCollector.renounceRole(feeCollector.DEFAULT_ADMIN_ROLE(), deployer);
    }

    function _logDeploy(
        address deployer,
        address admin,
        address[] memory adapters,
        address feeCollector,
        address manager
    ) internal view {
        NARAImmutableBasketPositionManagerV1 liveManager = NARAImmutableBasketPositionManagerV1(manager);
        (
            string memory basketName,
            ,
            uint16 buyFeeBps,
            uint16 sellFeeBps,
            uint16 maxWeightDeviationBps,
            address feeRecipient
        ) = liveManager.basket();
        address[] memory assets = liveManager.getBasketAssets();
        uint16[] memory weights = liveManager.getBasketWeightsBps();
        address[] memory paymentTokens = liveManager.getPaymentTokens();

        console2.log("=== NARA Baskets Mainnet Ready Deploy ===");
        console2.log("Deployer", deployer);
        console2.log("Admin (Safe)", admin);
        console2.log("UniswapV3BasketAdapterV1", adapters[0]);
        console2.log("AerodromeBasketAdapterV1", adapters[1]);
        console2.log("AerodromeSlipstreamBasketAdapterV1", adapters[2]);
        console2.log("PancakeV3BasketAdapterV1", adapters[3]);
        console2.log("UniswapV4BasketAdapterV1", adapters[4]);
        console2.log("NARAIndexFeeCollectorV2", feeCollector);
        console2.log("NARAImmutableBasketPositionManagerV1", manager);
        console2.log("Basket name", basketName);
        console2.log("CategoryId");
        console2.logBytes32(liveManager.categoryId());
        console2.log("ConfigHash");
        console2.logBytes32(liveManager.configHash());
        console2.log("Fee recipient", feeRecipient);
        console2.log("Buy fee bps", buyFeeBps);
        console2.log("Sell fee bps", sellFeeBps);
        console2.log("Withdraw fee bps", liveManager.withdrawFeeBps());
        console2.log("Holding fee bps", liveManager.holdingFeeBps());
        console2.log("Referral share bps", liveManager.referralShareBps());
        console2.log("Max weight deviation bps", maxWeightDeviationBps);
        console2.log("Min NARA weight bps", liveManager.minRequiredAssetWeightBps());
        console2.log("Min input amount", liveManager.minInputAmount());
        console2.log("Required asset", liveManager.requiredAsset());
        console2.log("Payment token count", paymentTokens.length);
        for (uint256 i = 0; i < paymentTokens.length; i++) {
            console2.log("Payment token", paymentTokens[i]);
        }
        if (assets.length != weights.length) {
            revert ArrayLengthMismatch("assets/weights", assets.length, weights.length);
        }
        for (uint256 i = 0; i < assets.length; i++) {
            console2.log("Basket asset", assets[i]);
            console2.log("Weight bps", weights[i]);
        }
    }

    function _envSelector(string memory key) internal view returns (bytes4 selector) {
        bytes memory raw = vm.envBytes(key);
        if (raw.length != 4) revert BadSelectorLength();
        assembly {
            selector := mload(add(raw, 32))
        }
    }

    function _deployBasket(
        address nara,
        address usdc,
        address weth,
        address[] memory adapters,
        address feeCollector
    ) internal returns (NARAImmutableBasketPositionManagerV1 manager) {
        address[] memory assets = _parseAddressList(vm.envString("BASKET_ASSETS"));
        uint16[] memory weights = _parseUint16List(vm.envString("BASKET_WEIGHTS"));
        _requireCode("NARA", nara);
        _requireCode("USDC", usdc);
        _requireCode("WETH", weth);
        _requireCode("FEE_COLLECTOR", feeCollector);
        for (uint256 i = 0; i < assets.length; i++) {
            _requireCode("BASKET_ASSET", assets[i]);
        }
        for (uint256 i = 0; i < adapters.length; i++) {
            _requireCode("BASKET_ADAPTER", adapters[i]);
        }
        if (assets[0] != nara) {
            revert BadExpectedAddress("BASKET_ASSETS[0]", nara, assets[0]);
        }

        address[] memory paymentTokens = new address[](2);
        paymentTokens[0] = usdc;
        paymentTokens[1] = weth;

        NARAImmutableBasketPositionManagerV1.BasketDeploymentConfig memory config;
        config.categoryId = keccak256(bytes(vm.envString("BASKET_CATEGORY")));
        config.basketName = vm.envString("BASKET_NAME");
        config.displayTier = uint8(vm.envUint("BASKET_DISPLAY_TIER"));
        config.assets = assets;
        config.weightsBps = weights;
        config.paymentTokens = paymentTokens;
        config.adapters = adapters;
        config.buyFeeBps = uint16(vm.envUint("BASKET_BUY_FEE_BPS"));
        config.sellFeeBps = uint16(vm.envUint("BASKET_SELL_FEE_BPS"));
        config.withdrawFeeBps = uint16(vm.envOr("BASKET_WITHDRAW_FEE_BPS", vm.envUint("BASKET_SELL_FEE_BPS")));
        config.holdingFeeBps = uint16(vm.envUint("BASKET_HOLDING_FEE_BPS"));
        config.referralShareBps = uint16(vm.envUint("BASKET_REFERRAL_SHARE_BPS"));
        config.maxWeightDeviationBps = uint16(vm.envUint("BASKET_MAX_WEIGHT_DEV_BPS"));
        config.minInputAmount = vm.envOr("BASKET_MIN_INPUT_AMOUNT", DEFAULT_MIN_INPUT_AMOUNT);
        config.feeRecipient = feeCollector;
        config.requiredAssetAdapter = adapters[4];

        uint16 minNaraWeight = uint16(vm.envUint("BASKET_MIN_NARA_WEIGHT_BPS"));

        manager = new NARAImmutableBasketPositionManagerV1(
            vm.envString("BASKET_NAME"),
            "NARABP",
            nara,
            minNaraWeight,
            config
        );
    }

    function _requireCode(string memory label, address target) internal view {
        if (target.code.length == 0) revert AddressHasNoCode(label, target);
    }

    function _parseAddressList(string memory csv) internal pure returns (address[] memory out) {
        bytes memory raw = bytes(csv);
        uint256 count = 1;
        for (uint256 i = 0; i < raw.length; i++) {
            if (raw[i] == 0x2C) count++;
        }
        out = new address[](count);

        uint256 idx;
        uint256 start;
        for (uint256 i = 0; i <= raw.length; i++) {
            if (i == raw.length || raw[i] == 0x2C) {
                out[idx++] = _parseAddress(_substring(raw, start, i));
                start = i + 1;
            }
        }
    }

    function _parseUint16List(string memory csv) internal pure returns (uint16[] memory out) {
        bytes memory raw = bytes(csv);
        uint256 count = 1;
        for (uint256 i = 0; i < raw.length; i++) {
            if (raw[i] == 0x2C) count++;
        }
        out = new uint16[](count);

        uint256 idx;
        uint256 start;
        for (uint256 i = 0; i <= raw.length; i++) {
            if (i == raw.length || raw[i] == 0x2C) {
                out[idx++] = uint16(_parseUint(_substring(raw, start, i)));
                start = i + 1;
            }
        }
    }

    function _substring(bytes memory src, uint256 start, uint256 end) internal pure returns (string memory) {
        bytes memory out = new bytes(end - start);
        for (uint256 i = 0; i < end - start; i++) {
            out[i] = src[start + i];
        }
        return string(out);
    }

    function _parseAddress(string memory s) internal pure returns (address) {
        bytes memory b = bytes(s);
        require(b.length == 42 && b[0] == "0" && b[1] == "x", "bad addr");
        uint160 v;
        for (uint256 i = 2; i < 42; i++) {
            uint8 c = uint8(b[i]);
            uint8 d;
            if (c >= 0x30 && c <= 0x39) d = c - 0x30;
            else if (c >= 0x41 && c <= 0x46) d = c - 0x41 + 10;
            else if (c >= 0x61 && c <= 0x66) d = c - 0x61 + 10;
            else revert("bad hex");
            v = v * 16 + d;
        }
        return address(v);
    }

    function _parseUint(string memory s) internal pure returns (uint256) {
        bytes memory b = bytes(s);
        uint256 v;
        for (uint256 i = 0; i < b.length; i++) {
            uint8 c = uint8(b[i]);
            require(c >= 0x30 && c <= 0x39, "bad uint");
            v = v * 10 + (c - 0x30);
        }
        return v;
    }
}
