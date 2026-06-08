// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {NARAImmutableBasketPositionManagerV1} from "../src/NARAImmutableBasketPositionManagerV1.sol";
import {NARAIndexFeeCollectorV1} from "../src/NARAIndexFeeCollectorV1.sol";

contract DeployBaseMainnet is Script {
    /// @dev Legacy V1 deploy path is intentionally disabled. Use DeployMainnetReady.s.sol.
    error LegacyDeployDisabled();
    error WrongChain(uint256 chainId);
    error BadSelectorLength();

    function run() external {
        revert LegacyDeployDisabled();

        if (block.chainid != 8453) revert WrongChain(block.chainid);

        uint256 pk = vm.envUint("PRIVATE_KEY");
        address usdc = vm.envAddress("USDC");
        address nara = vm.envAddress("NARA");
        address weth = vm.envAddress("WETH");
        address engine = vm.envAddress("NARA_ENGINE");
        address admin = vm.envAddress("ADMIN");
        address executor0 = vm.envAddress("EXECUTOR_0");
        address basketAdapter = vm.envAddress("BASKET_ADAPTER");
        address paymentToken = vm.envOr("PAYMENT_TOKEN", usdc);
        bytes4 executor0Selector = _envSelector("EXECUTOR_0_SELECTOR");
        uint16 minNaraWeightBps = uint16(vm.envOr("MIN_NARA_WEIGHT_BPS", uint256(500)));

        address[] memory executors = new address[](1);
        executors[0] = executor0;

        vm.startBroadcast(pk);

        address deployer = vm.addr(pk);
        NARAIndexFeeCollectorV1 feeCollector = new NARAIndexFeeCollectorV1(engine, nara, weth, deployer, executors);
        feeCollector.setAllowedSelector(executor0, executor0Selector, true);
        NARAImmutableBasketPositionManagerV1 positionManager = new NARAImmutableBasketPositionManagerV1(
            vm.envOr("POSITION_NAME", string("NARA Basket Position")),
            vm.envOr("POSITION_SYMBOL", string("NBP")),
            nara,
            minNaraWeightBps,
            _basketConfig(nara, paymentToken, basketAdapter, address(feeCollector))
        );

        _handoffFeeCollector(feeCollector, deployer, admin);

        vm.stopBroadcast();

        console2.log("Admin", admin);
        console2.log("USDC", usdc);
        console2.log("NARAImmutableBasketPositionManagerV1", address(positionManager));
        console2.log("NARAIndexFeeCollectorV1", address(feeCollector));
    }

    function _handoffFeeCollector(NARAIndexFeeCollectorV1 feeCollector, address deployer, address admin) internal {
        if (admin == deployer) return;
        feeCollector.grantRole(feeCollector.DEFAULT_ADMIN_ROLE(), admin);
        feeCollector.grantRole(feeCollector.SWAPPER_ROLE(), admin);
        feeCollector.grantRole(feeCollector.EXECUTOR_MANAGER_ROLE(), admin);
        feeCollector.grantRole(feeCollector.REDEEMER_ROLE(), admin);
        feeCollector.grantRole(feeCollector.VAULT_MANAGER_ROLE(), admin);
        feeCollector.renounceRole(feeCollector.SWAPPER_ROLE(), deployer);
        feeCollector.renounceRole(feeCollector.EXECUTOR_MANAGER_ROLE(), deployer);
        feeCollector.renounceRole(feeCollector.REDEEMER_ROLE(), deployer);
        feeCollector.renounceRole(feeCollector.VAULT_MANAGER_ROLE(), deployer);
        feeCollector.renounceRole(feeCollector.DEFAULT_ADMIN_ROLE(), deployer);
    }

    function _envSelector(string memory key) internal view returns (bytes4 selector) {
        bytes memory raw = vm.envBytes(key);
        if (raw.length != 4) revert BadSelectorLength();
        assembly {
            selector := mload(add(raw, 32))
        }
    }

    function _basketConfig(address nara, address paymentToken, address adapter, address feeCollector)
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
        paymentTokens[0] = paymentToken;

        address[] memory adapters = new address[](1);
        adapters[0] = adapter;

        config.categoryId = keccak256(bytes(vm.envOr("CATEGORY", string("CULTURE"))));
        config.basketName = vm.envOr("BASKET_NAME", string("NARA CULTURE Basket"));
        config.displayTier = uint8(vm.envOr("DISPLAY_TIER", uint256(3)));
        config.assets = assets;
        config.weightsBps = weightsBps;
        config.paymentTokens = paymentTokens;
        config.adapters = adapters;
        config.buyFeeBps = uint16(vm.envOr("BUY_FEE_BPS", uint256(30)));
        config.sellFeeBps = uint16(vm.envOr("SELL_FEE_BPS", uint256(30)));
        config.withdrawFeeBps = uint16(vm.envOr("WITHDRAW_FEE_BPS", vm.envOr("SELL_FEE_BPS", uint256(30))));
        config.holdingFeeBps = uint16(vm.envOr("HOLDING_FEE_BPS", uint256(0)));
        config.referralShareBps = uint16(vm.envOr("REFERRAL_SHARE_BPS", uint256(0)));
        config.maxWeightDeviationBps = uint16(vm.envOr("MAX_WEIGHT_DEVIATION_BPS", uint256(50)));
        config.minInputAmount = vm.envOr("MIN_INPUT_AMOUNT", uint256(0));
        config.feeRecipient = feeCollector;
        config.requiredAssetAdapter = adapters[0];
    }
}
