// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {CreateBasketExample} from "../script/CreateBasketExample.s.sol";
import {DeployBaseMainnet} from "../script/DeployBaseMainnet.s.sol";
import {DeployBaseSepolia} from "../script/DeployBaseSepolia.s.sol";

contract DisabledLegacyDeploymentTest is Test {
    function testStaticCategorySuiteExampleCannotDeploy() public {
        CreateBasketExample script = new CreateBasketExample();
        vm.expectRevert(CreateBasketExample.NoncanonicalDeploymentDisabled.selector);
        script.run();
    }

    function testLegacyMainnetEntryPointCannotDeploy() public {
        DeployBaseMainnet script = new DeployBaseMainnet();
        vm.expectRevert(DeployBaseMainnet.LegacyDeployDisabled.selector);
        script.run();
    }

    function testLegacySepoliaEntryPointCannotDeploy() public {
        DeployBaseSepolia script = new DeployBaseSepolia();
        vm.expectRevert(DeployBaseSepolia.LegacyDeployDisabled.selector);
        script.run();
    }
}
