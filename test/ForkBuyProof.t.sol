// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {DeployForkLocal} from "../script/DeployForkLocal.s.sol";
import {TestBuyFork} from "../script/TestBuyFork.s.sol";

/// @notice Guards against accidentally reviving obsolete stand-in rehearsals.
contract ForkBuyProof is Test {
    function testLegacyForkDeploymentIsDisabled() public {
        DeployForkLocal script = new DeployForkLocal();
        vm.expectRevert(DeployForkLocal.ExactFreshV4ForkCandidateRequired.selector);
        script.run();
    }

    function testLegacyForkBuyProofIsDisabled() public {
        TestBuyFork script = new TestBuyFork();
        vm.expectRevert(TestBuyFork.ExactFreshV4ForkCandidateRequired.selector);
        script.run();
    }
}
