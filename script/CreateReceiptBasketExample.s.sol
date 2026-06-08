// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {NARAImmutableBasketPositionManagerV1} from "../src/NARAImmutableBasketPositionManagerV1.sol";

/// @notice Canonical V1 one-click receipt basket example.
/// @dev Deploys one immutable basket manager. Run once per basket/category.
contract CreateReceiptBasketExample is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address nara = vm.envAddress("NARA");
        uint16 minNaraWeightBps = uint16(vm.envOr("MIN_NARA_WEIGHT_BPS", uint256(500)));

        NARAImmutableBasketPositionManagerV1.BasketDeploymentConfig memory config = _buildConfig(nara);

        vm.startBroadcast(pk);

        NARAImmutableBasketPositionManagerV1 manager = new NARAImmutableBasketPositionManagerV1(
            vm.envOr("POSITION_NAME", string("NARA Basket Position")),
            vm.envOr("POSITION_SYMBOL", string("NBP")),
            nara,
            minNaraWeightBps,
            config
        );

        vm.stopBroadcast();

        console2.log("NARAImmutableBasketPositionManagerV1", address(manager));
    }

    function _buildConfig(address nara)
        internal
        view
        returns (NARAImmutableBasketPositionManagerV1.BasketDeploymentConfig memory config)
    {
        address[] memory assets = new address[](4);
        assets[0] = nara;
        assets[1] = vm.envAddress("BASKET_TOKEN_A");
        assets[2] = vm.envAddress("BASKET_TOKEN_B");
        assets[3] = vm.envAddress("BASKET_TOKEN_C");

        uint16[] memory weightsBps = new uint16[](4);
        weightsBps[0] = uint16(vm.envOr("NARA_WEIGHT_BPS", uint256(1000)));
        weightsBps[1] = uint16(vm.envOr("WEIGHT_A_BPS", uint256(4000)));
        weightsBps[2] = uint16(vm.envOr("WEIGHT_B_BPS", uint256(3000)));
        weightsBps[3] = uint16(vm.envOr("WEIGHT_C_BPS", uint256(2000)));

        address[] memory paymentTokens = new address[](1);
        paymentTokens[0] = vm.envAddress("PAYMENT_TOKEN");

        address[] memory adapters = new address[](1);
        adapters[0] = vm.envAddress("BASKET_ADAPTER");

        uint16 sellFee = uint16(vm.envOr("SELL_FEE_BPS", uint256(30)));
        address feeCollector = vm.envAddress("FEE_COLLECTOR");

        config.categoryId = keccak256(bytes(vm.envOr("CATEGORY", string("CULTURE"))));
        config.basketName = vm.envOr("BASKET_NAME", string("NARA CULTURE Basket"));
        config.displayTier = uint8(vm.envOr("DISPLAY_TIER", uint256(3)));
        config.assets = assets;
        config.weightsBps = weightsBps;
        config.paymentTokens = paymentTokens;
        config.adapters = adapters;
        config.buyFeeBps = uint16(vm.envOr("BUY_FEE_BPS", uint256(30)));
        config.sellFeeBps = sellFee;
        config.withdrawFeeBps = sellFee;
        config.holdingFeeBps = uint16(vm.envOr("HOLDING_FEE_BPS", uint256(0)));
        config.referralShareBps = uint16(vm.envOr("REFERRAL_SHARE_BPS", uint256(0)));
        config.maxWeightDeviationBps = uint16(vm.envOr("MAX_WEIGHT_DEVIATION_BPS", uint256(50)));
        config.minInputAmount = vm.envOr("MIN_INPUT_AMOUNT", uint256(0));
        config.feeRecipient = feeCollector;
        config.requiredAssetAdapter = adapters[0];
    }
}
