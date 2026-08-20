// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Script} from "forge-std/Script.sol";
import {NARAImmutableBasketPositionManagerV1} from "../src/NARAImmutableBasketPositionManagerV1.sol";

interface ICanonicalV4BasketAdapter {
    function router() external view returns (address);
    function permit2() external view returns (address);
    function canonicalFee() external view returns (uint24);
    function canonicalTickSpacing() external view returns (int24);
    function canonicalHooks() external view returns (address);
    function canonicalToken() external view returns (address);
    function canonicalBase() external view returns (address);
    function canonicalPoolId() external view returns (bytes32);
}

interface ICanonicalNARAV4Hook {
    function token() external view returns (address);
    function base() external view returns (address);
    function poolRegistered() external view returns (bool);
    function registeredPoolId() external view returns (bytes32);
}

/// @notice Fail-closed production entrypoint pending basket deployment authorization.
/// @dev The corrected-v4 protocol handoff is immutable and verified. The environment
///      list below is context for the isolated basket-configuration helper; it is not
///      a production procedure until `run()` is rebuilt from an approved basket release
///      with exact-Base-fork round-flow evidence and a reviewed manifest schema.
///
///      Required env:
///        PRIVATE_KEY                 — deployer EOA (ephemeral)
///        ADMIN                       — contract Safe; fee-collector role admin
///        SWAPPER                     — separate low-trust keeper address
///        ROUTE_MANAGER               — separate contract timelock for delayed route changes
///        NARA_ENGINE                 — deployed NARAEngine v4
///        NARA                        — deployed NARA token v4
///        USDC                        — Base USDC 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
///        WETH                        — Base WETH 0x4200000000000000000000000000000000000006
///        UNISWAP_V3_ROUTER02         — Base SwapRouter02 0x2626664c2603336E57B271c5C0b26F421741e481
///
///        USDC_USD_FEED               — reviewed Base Chainlink-compatible USDC/USD feed
///        ETH_USD_FEED                — reviewed Base Chainlink-compatible ETH/USD feed
///        FEE_SWAP_POOL_FEE           — direct USDC/WETH Uniswap v3 fee tier
///        FEE_SWAP_MAX_USDC_ORACLE_AGE — 300..172800 seconds
///        FEE_SWAP_MAX_ETH_ORACLE_AGE — 300..172800 seconds
///        FEE_SWAP_MAX_SLIPPAGE_BPS   — 0..500 bps
///
///      Per-basket env (only the first basket; subsequent baskets run separately):
///        BASKET_CATEGORY             — "CORE" | "AI" | "FINANCE" | "CULTURE"
///        BASKET_NAME                 — display name
///        BASKET_DISPLAY_TIER         - neutral legacy metadata; do not display as advice
///        BASKET_BUY_FEE_BPS          — configured buy fee; cap 100
///        BASKET_SELL_FEE_BPS         — configured sell fee; cap 100
///        BASKET_WITHDRAW_FEE_BPS     — must be 0 at launch; avoids long-tail fee assets
///        BASKET_HOLDING_FEE_BPS      — must be 0 at launch; avoids long-tail fee assets
///        BASKET_REFERRAL_SHARE_BPS   — must be 0 at launch; avoids permissionless self-referral fee capture
///        BASKET_MAX_WEIGHT_DEV_BPS   — slippage budget; cap 1000
///        BASKET_MIN_NARA_WEIGHT_BPS  — cap 5000
///        BASKET_ASSETS               — comma-separated list, NARA must be first
///        BASKET_WEIGHTS              — comma-separated bps list, sum 10000
contract DeployMainnetReady is Script {
    uint256 internal constant DEFAULT_MIN_INPUT_AMOUNT = 25_000_000; // 25 USDC
    uint160 internal constant ALL_HOOK_PERMISSION_FLAGS = (1 << 14) - 1;
    uint160 internal constant REQUIRED_HOOK_PERMISSION_FLAGS = 0x2088;

    error UnsupportedInKindFee();
    error UnsupportedReferralShare();
    error BadExpectedAddress(string label, address expected, address actual);
    error BadExpectedUint(string label, uint256 expected, uint256 actual);
    error BadExpectedBytes32(string label, bytes32 expected, bytes32 actual);
    error AddressHasNoCode(string label, address target);
    error BasketDeploymentReadinessRequired();
    error V4PoolNotRegistered();

    /// @notice Intentionally fail closed until a basket-specific deployment is
    ///         authorized after exact-fork, route, role, and manifest review.
    function run() external pure {
        revert BasketDeploymentReadinessRequired();
    }

    // This helper is retained only for isolated configuration tests. The
    // callable script path above cannot reach it.
    function _deployBasket(address nara, address usdc, address[] memory adapters, address feeCollector)
        internal
        returns (NARAImmutableBasketPositionManagerV1 manager)
    {
        address[] memory assets = _parseAddressList(vm.envString("BASKET_ASSETS"));
        uint16[] memory weights = _parseUint16List(vm.envString("BASKET_WEIGHTS"));
        _requireCode("NARA", nara);
        _requireCode("USDC", usdc);
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

        // Basket V1 launches with USDC only. The canonical NARA adapter is a
        // single-hop NARA/USDC adapter; allowing WETH would create an immutable
        // payment path that reverts on the required NARA allocation.
        address[] memory paymentTokens = new address[](1);
        paymentTokens[0] = usdc;

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
        uint256 withdrawFeeBps = vm.envOr("BASKET_WITHDRAW_FEE_BPS", uint256(0));
        uint256 holdingFeeBps = vm.envOr("BASKET_HOLDING_FEE_BPS", uint256(0));
        if (withdrawFeeBps != 0 || holdingFeeBps != 0) revert UnsupportedInKindFee();
        config.withdrawFeeBps = 0;
        config.holdingFeeBps = 0;
        uint256 referralShareBps = vm.envOr("BASKET_REFERRAL_SHARE_BPS", uint256(0));
        if (referralShareBps != 0) revert UnsupportedReferralShare();
        config.referralShareBps = 0;
        _requireCanonicalV4Binding(
            ICanonicalV4BasketAdapter(adapters[4]),
            nara,
            usdc,
            vm.envAddress("V4_UNIVERSAL_ROUTER"),
            vm.envAddress("V4_PERMIT2"),
            uint24(vm.envUint("NARA_V4_POOL_FEE")),
            int24(uint24(vm.envUint("NARA_V4_POOL_TICK_SPACING"))),
            vm.envAddress("NARA_V4_LIQUIDITY_GROWTH_HOOK"),
            vm.envBytes32("NARA_V4_POOL_ID")
        );
        config.maxWeightDeviationBps = uint16(vm.envUint("BASKET_MAX_WEIGHT_DEV_BPS"));
        config.minInputAmount = vm.envOr("BASKET_MIN_INPUT_AMOUNT", DEFAULT_MIN_INPUT_AMOUNT);
        config.feeRecipient = feeCollector;
        config.requiredAssetAdapter = adapters[4];

        uint16 minNaraWeight = uint16(vm.envUint("BASKET_MIN_NARA_WEIGHT_BPS"));

        manager = new NARAImmutableBasketPositionManagerV1(
            vm.envString("BASKET_NAME"), "NARABP", nara, minNaraWeight, config
        );
    }

    function _requireCanonicalV4Binding(
        ICanonicalV4BasketAdapter adapter,
        address expectedToken,
        address expectedBase,
        address expectedRouter,
        address expectedPermit2,
        uint24 expectedFee,
        int24 expectedTickSpacing,
        address expectedHook,
        bytes32 expectedPoolId
    ) internal view {
        uint160 actualFlags = uint160(expectedHook) & ALL_HOOK_PERMISSION_FLAGS;
        if (actualFlags != REQUIRED_HOOK_PERMISSION_FLAGS) {
            revert BadExpectedUint("v4Hook.permissionFlags", REQUIRED_HOOK_PERMISSION_FLAGS, actualFlags);
        }

        ICanonicalNARAV4Hook hook = ICanonicalNARAV4Hook(expectedHook);
        _requireAddress("v4Hook.token", expectedToken, hook.token());
        _requireAddress("v4Hook.base", expectedBase, hook.base());
        if (!hook.poolRegistered()) revert V4PoolNotRegistered();

        bytes32 recomputedPoolId =
            _v4PoolId(expectedToken, expectedBase, expectedFee, expectedTickSpacing, expectedHook);
        _requireBytes32("v4Hook.expectedPoolId", recomputedPoolId, expectedPoolId);
        _requireBytes32("v4Hook.registeredPoolId", recomputedPoolId, hook.registeredPoolId());
        _requireAddress("v4Adapter.router", expectedRouter, adapter.router());
        _requireAddress("v4Adapter.permit2", expectedPermit2, adapter.permit2());
        _requireUint("v4Adapter.canonicalFee", expectedFee, adapter.canonicalFee());
        _requireUint(
            "v4Adapter.canonicalTickSpacing",
            uint256(uint24(expectedTickSpacing)),
            uint256(uint24(adapter.canonicalTickSpacing()))
        );
        _requireAddress("v4Adapter.canonicalHooks", expectedHook, adapter.canonicalHooks());
        _requireAddress("v4Adapter.canonicalToken", expectedToken, adapter.canonicalToken());
        _requireAddress("v4Adapter.canonicalBase", expectedBase, adapter.canonicalBase());
        _requireBytes32("v4Adapter.canonicalPoolId", recomputedPoolId, adapter.canonicalPoolId());
    }

    function _v4PoolId(address token, address base, uint24 fee, int24 tickSpacing, address hooks)
        internal
        pure
        returns (bytes32)
    {
        (address currency0, address currency1) = token < base ? (token, base) : (base, token);
        return keccak256(abi.encode(currency0, currency1, fee, tickSpacing, hooks));
    }

    function _requireAddress(string memory label, address expected, address actual) internal pure {
        if (actual != expected) revert BadExpectedAddress(label, expected, actual);
    }

    function _requireUint(string memory label, uint256 expected, uint256 actual) internal pure {
        if (actual != expected) revert BadExpectedUint(label, expected, actual);
    }

    function _requireBytes32(string memory label, bytes32 expected, bytes32 actual) internal pure {
        if (actual != expected) revert BadExpectedBytes32(label, expected, actual);
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
