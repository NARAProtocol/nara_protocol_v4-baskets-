// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {DeployMainnetReady} from "../script/DeployMainnetReady.s.sol";
import {NARAImmutableBasketPositionManagerV1} from "../src/NARAImmutableBasketPositionManagerV1.sol";

contract DeployMainnetReadyHarness is DeployMainnetReady {
    function deployBasket(address nara, address usdc, address[] memory adapters, address feeCollector)
        external
        returns (NARAImmutableBasketPositionManagerV1)
    {
        return _deployBasket(nara, usdc, adapters, feeCollector);
    }
}

contract DeployMainnetReadyTest is Test {
    DeployMainnetReadyHarness internal deployer;
    address internal constant NARA = address(0x1001);
    address internal constant USDC = address(0x1002);
    address internal constant FEE_COLLECTOR = address(0x1003);

    function setUp() public {
        deployer = new DeployMainnetReadyHarness();

        vm.etch(NARA, hex"00");
        vm.etch(USDC, hex"00");
        vm.etch(FEE_COLLECTOR, hex"00");

        vm.setEnv("BASKET_ASSETS", "0x0000000000000000000000000000000000001001");
        vm.setEnv("BASKET_WEIGHTS", "10000");
        vm.setEnv("BASKET_CATEGORY", "CORE");
        vm.setEnv("BASKET_NAME", "Core");
        vm.setEnv("BASKET_DISPLAY_TIER", "0");
        vm.setEnv("BASKET_BUY_FEE_BPS", "25");
        vm.setEnv("BASKET_SELL_FEE_BPS", "25");
        vm.setEnv("BASKET_WITHDRAW_FEE_BPS", "0");
        vm.setEnv("BASKET_HOLDING_FEE_BPS", "0");
        vm.setEnv("BASKET_MAX_WEIGHT_DEV_BPS", "500");
        vm.setEnv("BASKET_MIN_NARA_WEIGHT_BPS", "2500");
    }

    function testDeployRejectsNonzeroLaunchFees() public {
        vm.setEnv("BASKET_REFERRAL_SHARE_BPS", "1");

        address[] memory adapters = _codedAdapters();
        vm.expectRevert(DeployMainnetReady.UnsupportedReferralShare.selector);
        deployer.deployBasket(NARA, USDC, adapters, FEE_COLLECTOR);

        vm.setEnv("BASKET_REFERRAL_SHARE_BPS", "0");
        vm.setEnv("BASKET_WITHDRAW_FEE_BPS", "1");
        vm.expectRevert(DeployMainnetReady.UnsupportedInKindFee.selector);
        deployer.deployBasket(NARA, USDC, adapters, FEE_COLLECTOR);

        vm.setEnv("BASKET_WITHDRAW_FEE_BPS", "0");
        vm.setEnv("BASKET_HOLDING_FEE_BPS", "1");
        vm.expectRevert(DeployMainnetReady.UnsupportedInKindFee.selector);
        deployer.deployBasket(NARA, USDC, adapters, FEE_COLLECTOR);
    }

    function testProductionEntrypointAlwaysFailsClosed() public {
        vm.expectRevert(DeployMainnetReady.BasketDeploymentReadinessRequired.selector);
        deployer.run();
    }

    function _codedAdapters() internal returns (address[] memory adapters) {
        adapters = new address[](5);
        for (uint256 i = 0; i < adapters.length; i++) {
            adapters[i] = address(uint160(0x2001 + i));
            vm.etch(adapters[i], hex"00");
        }
    }
}
