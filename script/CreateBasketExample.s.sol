// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CategoryIndexFactoryV1, CategoryIndexVaultV1} from "../src/CategoryIndexSuiteV1.sol";
import {NARAIndexFeeCollectorV1} from "../src/NARAIndexFeeCollectorV1.sol";

/// @notice Static ERC20 pro-rata vault example.
/// @dev This is not the canonical one-click receipt basket product.
contract CreateBasketExample is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        CategoryIndexFactoryV1 factory = CategoryIndexFactoryV1(vm.envAddress("FACTORY"));
        NARAIndexFeeCollectorV1 feeCollector = NARAIndexFeeCollectorV1(payable(vm.envAddress("FEE_COLLECTOR")));
        address initialReceiver = vm.envAddress("INITIAL_SHARE_RECEIVER");

        address tokenA = vm.envAddress("BASKET_TOKEN_A");
        address tokenB = vm.envAddress("BASKET_TOKEN_B");
        address tokenC = vm.envAddress("BASKET_TOKEN_C");

        address[] memory assets = new address[](3);
        assets[0] = tokenA;
        assets[1] = tokenB;
        assets[2] = tokenC;

        uint256[] memory weightsBps = new uint256[](3);
        weightsBps[0] = 4000;
        weightsBps[1] = 3500;
        weightsBps[2] = 2500;

        uint256[] memory seedAmounts = new uint256[](3);
        seedAmounts[0] = vm.envUint("SEED_AMOUNT_A");
        seedAmounts[1] = vm.envUint("SEED_AMOUNT_B");
        seedAmounts[2] = vm.envUint("SEED_AMOUNT_C");

        vm.startBroadcast(pk);

        for (uint256 i = 0; i < assets.length; i++) {
            if (!factory.isAssetAllowed(assets[i])) {
                factory.setAssetAllowed(assets[i], true);
            }
            IERC20(assets[i]).approve(address(factory), seedAmounts[i]);
        }

        address vault = factory.createSeededVault(
            "NARA AI Index",
            "NAI",
            "AI",
            keccak256("AI"),
            CategoryIndexVaultV1.RiskTier.Sector,
            assets,
            weightsBps,
            seedAmounts,
            20,
            20,
            address(feeCollector),
            initialReceiver
        );
        feeCollector.setAllowedVault(vault, true);

        vm.stopBroadcast();
    }
}
