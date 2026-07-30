// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {NARAImmutableBasketPositionManagerV1} from "../src/NARAImmutableBasketPositionManagerV1.sol";

interface IFeeCollectorV2Verify {
    function engine() external view returns (address);
    function nara() external view returns (address);
    function usdc() external view returns (address);
    function weth() external view returns (address);
    function maxOracleAge() external view returns (uint48);
    function maxSlippageBps() external view returns (uint16);
    function routeConfig()
        external
        view
        returns (address router, address usdcUsdFeed, address ethUsdFeed, uint24 poolFee);
    function DEFAULT_ADMIN_ROLE() external view returns (bytes32);
    function SWAPPER_ROLE() external view returns (bytes32);
    function ROUTE_MANAGER_ROLE() external view returns (bytes32);
    function hasRole(bytes32 role, address account) external view returns (bool);
}

/// @notice Launch gate for one deployed immutable basket manager.
/// @dev Reads EXPECTED_* env values and reverts on any on-chain mismatch.
contract VerifyDeployedBasket is Script {
    uint256 internal constant DEFAULT_EXPECTED_MIN_INPUT_AMOUNT = 25_000_000; // 25 USDC
    address internal constant RETIRED_V3_NARA = 0xE444de61752bD13D1D37Ee59c31ef4e489bd727C;
    address internal constant RETIRED_V3_ENGINE = 0x62250aEE40F37e2eb2cd300E5a429d7096C8868F;

    error WrongChain(uint256 expected, uint256 actual);
    error AddressHasNoCode(string label, address target);
    error AddressMismatch(string label, address expected, address actual);
    error Bytes32Mismatch(string label, bytes32 expected, bytes32 actual);
    error StringMismatch(string label, string expected, string actual);
    error UintMismatch(string label, uint256 expected, uint256 actual);
    error BoolMismatch(string label);
    error LengthMismatch(string label, uint256 expected, uint256 actual);
    error RetiredAddress(string label, address target);
    error CodeHashMismatch(string label, bytes32 expected, bytes32 actual);

    function run() external {
        uint256 expectedChainId = vm.envOr("EXPECTED_CHAIN_ID", block.chainid);
        if (block.chainid != expectedChainId) revert WrongChain(expectedChainId, block.chainid);

        address managerAddress = vm.envAddress("MANAGER");
        _requireCode("MANAGER", managerAddress);

        NARAImmutableBasketPositionManagerV1 manager = NARAImmutableBasketPositionManagerV1(managerAddress);

        address expectedNara = vm.envAddress("EXPECTED_NARA");
        address expectedFeeRecipient = vm.envAddress("EXPECTED_FEE_RECIPIENT");
        address expectedRequiredAssetAdapter = vm.envAddress("EXPECTED_REQUIRED_ASSET_ADAPTER");
        address expectedEngine = vm.envAddress("EXPECTED_ENGINE");
        address expectedUsdc = vm.envAddress("EXPECTED_USDC");
        address expectedWeth = vm.envAddress("EXPECTED_WETH");
        address expectedAdmin = vm.envAddress("EXPECTED_ADMIN");
        address expectedSwapper = vm.envAddress("EXPECTED_SWAPPER");
        address expectedRouteManager = vm.envAddress("EXPECTED_ROUTE_MANAGER");
        address expectedRouter = vm.envAddress("EXPECTED_ROUTER");
        address expectedUsdcUsdFeed = vm.envAddress("EXPECTED_USDC_USD_FEED");
        address expectedEthUsdFeed = vm.envAddress("EXPECTED_ETH_USD_FEED");
        uint24 expectedPoolFee = uint24(vm.envUint("EXPECTED_FEE_SWAP_POOL_FEE"));
        address[] memory expectedAssets = _parseAddressList(vm.envString("EXPECTED_ASSETS"));
        uint16[] memory expectedWeights = _parseUint16List(vm.envString("EXPECTED_WEIGHTS"));
        address[] memory expectedPaymentTokens = _parseAddressList(vm.envString("EXPECTED_PAYMENT_TOKENS"));
        address[] memory expectedAdapters = _parseAddressList(vm.envString("EXPECTED_ADAPTERS"));

        _rejectRetired("EXPECTED_NARA", expectedNara);
        _rejectRetired("EXPECTED_ENGINE", expectedEngine);

        (
            string memory basketName,
            uint8 displayTier,
            uint16 buyFeeBps,
            uint16 sellFeeBps,
            uint16 maxWeightDeviationBps,
            address feeRecipient
        ) = manager.basket();

        _eq("requiredAsset", expectedNara, manager.requiredAsset());
        _eq("requiredAssetAdapter", expectedRequiredAssetAdapter, manager.requiredAssetAdapter());
        _eq("categoryId", keccak256(bytes(vm.envString("EXPECTED_CATEGORY"))), manager.categoryId());
        _eq("basket.name", vm.envString("EXPECTED_BASKET_NAME"), basketName);
        _eq("basket.displayTier", vm.envUint("EXPECTED_DISPLAY_TIER"), displayTier);
        _eq("basket.buyFeeBps", vm.envUint("EXPECTED_BUY_FEE_BPS"), buyFeeBps);
        _eq("basket.sellFeeBps", vm.envUint("EXPECTED_SELL_FEE_BPS"), sellFeeBps);
        _requireLaunchFeesZero(manager.withdrawFeeBps(), manager.holdingFeeBps(), manager.referralShareBps());
        _eq("withdrawFeeBps", vm.envUint("EXPECTED_WITHDRAW_FEE_BPS"), manager.withdrawFeeBps());
        _eq("holdingFeeBps", vm.envUint("EXPECTED_HOLDING_FEE_BPS"), manager.holdingFeeBps());
        _eq("referralShareBps", vm.envUint("EXPECTED_REFERRAL_SHARE_BPS"), manager.referralShareBps());
        _eq("basket.maxWeightDeviationBps", vm.envUint("EXPECTED_MAX_WEIGHT_DEV_BPS"), maxWeightDeviationBps);
        _eq(
            "minRequiredAssetWeightBps", vm.envUint("EXPECTED_MIN_NARA_WEIGHT_BPS"), manager.minRequiredAssetWeightBps()
        );
        _eq(
            "minInputAmount",
            vm.envOr("EXPECTED_MIN_INPUT_AMOUNT", DEFAULT_EXPECTED_MIN_INPUT_AMOUNT),
            manager.minInputAmount()
        );
        _eq("basket.feeRecipient", expectedFeeRecipient, feeRecipient);
        _requireCode("EXPECTED_FEE_RECIPIENT", expectedFeeRecipient);
        _requireCode("EXPECTED_REQUIRED_ASSET_ADAPTER", expectedRequiredAssetAdapter);
        _requireCode("EXPECTED_ENGINE", expectedEngine);
        _requireCode("EXPECTED_USDC", expectedUsdc);
        _requireCode("EXPECTED_WETH", expectedWeth);
        _requireCode("EXPECTED_ADMIN", expectedAdmin);
        _requireCode("EXPECTED_ROUTE_MANAGER", expectedRouteManager);
        _requireCode("EXPECTED_ROUTER", expectedRouter);
        _requireCode("EXPECTED_USDC_USD_FEED", expectedUsdcUsdFeed);
        _requireCode("EXPECTED_ETH_USD_FEED", expectedEthUsdFeed);
        _requireCodeHash(
            "EXPECTED_FEE_RECIPIENT_CODEHASH", expectedFeeRecipient, vm.envBytes32("EXPECTED_FEE_RECIPIENT_CODEHASH")
        );

        IFeeCollectorV2Verify feeCollector = IFeeCollectorV2Verify(expectedFeeRecipient);
        _eq("feeCollector.engine", expectedEngine, feeCollector.engine());
        _eq("feeCollector.nara", expectedNara, feeCollector.nara());
        _eq("feeCollector.usdc", expectedUsdc, feeCollector.usdc());
        _eq("feeCollector.weth", expectedWeth, feeCollector.weth());
        _eq("feeCollector.maxOracleAge", vm.envUint("EXPECTED_MAX_ORACLE_AGE"), feeCollector.maxOracleAge());
        _eq("feeCollector.maxSlippageBps", vm.envUint("EXPECTED_MAX_SLIPPAGE_BPS"), feeCollector.maxSlippageBps());
        (address router, address usdcUsdFeed, address ethUsdFeed, uint24 poolFee) = feeCollector.routeConfig();
        _eq("feeCollector.route.router", expectedRouter, router);
        _eq("feeCollector.route.usdcUsdFeed", expectedUsdcUsdFeed, usdcUsdFeed);
        _eq("feeCollector.route.ethUsdFeed", expectedEthUsdFeed, ethUsdFeed);
        _eq("feeCollector.route.poolFee", expectedPoolFee, poolFee);
        _true("feeCollector.admin", feeCollector.hasRole(feeCollector.DEFAULT_ADMIN_ROLE(), expectedAdmin));
        _true("feeCollector.swapper", feeCollector.hasRole(feeCollector.SWAPPER_ROLE(), expectedSwapper));
        _true(
            "feeCollector.routeManager", feeCollector.hasRole(feeCollector.ROUTE_MANAGER_ROLE(), expectedRouteManager)
        );

        if (manager.configHash() == bytes32(0)) revert Bytes32Mismatch("configHash", bytes32(uint256(1)), bytes32(0));

        _eqAddressArray("assets", expectedAssets, manager.getBasketAssets());
        _eqUint16Array("weights", expectedWeights, manager.getBasketWeightsBps());
        _eqAddressArray("paymentTokens", expectedPaymentTokens, manager.getPaymentTokens());
        _eqAddressArray("adapters", expectedAdapters, manager.getAdapters());

        if (expectedAssets.length == 0) revert LengthMismatch("assets", 1, 0);
        _eq("assets[0]", expectedNara, expectedAssets[0]);

        for (uint256 i = 0; i < expectedAssets.length; i++) {
            _requireCode("asset", expectedAssets[i]);
        }
        for (uint256 i = 0; i < expectedPaymentTokens.length; i++) {
            _requireCode("paymentToken", expectedPaymentTokens[i]);
            _true("paymentTokenAllowed", manager.isPaymentTokenAllowed(expectedPaymentTokens[i]));
            _true("sellOutputAllowed(payment)", manager.isSellOutputTokenAllowed(expectedPaymentTokens[i]));
        }
        for (uint256 i = 0; i < expectedAdapters.length; i++) {
            _requireCode("adapter", expectedAdapters[i]);
            _true("adapterAllowed", manager.isAdapterAllowed(expectedAdapters[i]));
        }
        _true("requiredAssetAdapterAllowed", manager.isAdapterAllowed(expectedRequiredAssetAdapter));

        _true("sellOutputAllowed(NARA)", manager.isSellOutputTokenAllowed(expectedNara));

        console2.log("=== NARA Basket Verification Passed ===");
        console2.log("Manager", managerAddress);
        console2.log("Basket", basketName);
        console2.log("Fee recipient", feeRecipient);
        console2.log("ConfigHash");
        console2.logBytes32(manager.configHash());
    }

    function _requireCode(string memory label, address target) internal view {
        if (target.code.length == 0) revert AddressHasNoCode(label, target);
    }

    function _requireCodeHash(string memory label, address target, bytes32 expected) internal view {
        bytes32 actual = target.codehash;
        if (actual != expected) revert CodeHashMismatch(label, expected, actual);
    }

    function _requireLaunchFeesZero(uint16 withdrawFee, uint16 holdingFee, uint16 referralShare) internal pure {
        _eq("launch.withdrawFeeBps", 0, withdrawFee);
        _eq("launch.holdingFeeBps", 0, holdingFee);
        _eq("launch.referralShareBps", 0, referralShare);
    }

    function _eq(string memory label, address expected, address actual) internal pure {
        if (expected != actual) revert AddressMismatch(label, expected, actual);
    }

    function _eq(string memory label, bytes32 expected, bytes32 actual) internal pure {
        if (expected != actual) revert Bytes32Mismatch(label, expected, actual);
    }

    function _eq(string memory label, string memory expected, string memory actual) internal pure {
        if (keccak256(bytes(expected)) != keccak256(bytes(actual))) revert StringMismatch(label, expected, actual);
    }

    function _eq(string memory label, uint256 expected, uint256 actual) internal pure {
        if (expected != actual) revert UintMismatch(label, expected, actual);
    }

    function _true(string memory label, bool value) internal pure {
        if (!value) revert BoolMismatch(label);
    }

    function _rejectRetired(string memory label, address target) internal pure {
        if (target == RETIRED_V3_NARA || target == RETIRED_V3_ENGINE) revert RetiredAddress(label, target);
    }

    function _eqAddressArray(string memory label, address[] memory expected, address[] memory actual) internal pure {
        if (expected.length != actual.length) revert LengthMismatch(label, expected.length, actual.length);
        for (uint256 i = 0; i < expected.length; i++) {
            if (expected[i] != actual[i]) revert AddressMismatch(label, expected[i], actual[i]);
        }
    }

    function _eqUint16Array(string memory label, uint16[] memory expected, uint16[] memory actual) internal pure {
        if (expected.length != actual.length) revert LengthMismatch(label, expected.length, actual.length);
        for (uint256 i = 0; i < expected.length; i++) {
            if (expected[i] != actual[i]) revert UintMismatch(label, expected[i], actual[i]);
        }
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
