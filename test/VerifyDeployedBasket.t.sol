// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {VerifyDeployedBasket} from "../script/VerifyDeployedBasket.s.sol";

contract VerifyDeployedBasketHarness is VerifyDeployedBasket {
    function requireCodeHash(string memory label, address target, bytes32 expected) external view {
        _requireCodeHash(label, target, expected);
    }

    function requireLaunchFeesZero(uint16 withdrawFee, uint16 holdingFee, uint16 referralShare) external pure {
        _requireLaunchFeesZero(withdrawFee, holdingFee, referralShare);
    }
}

contract VerifyDeployedBasketTest is Test {
    VerifyDeployedBasketHarness internal verifier;
    address internal constant COLLECTOR = address(0xC011EC70);

    function setUp() public {
        verifier = new VerifyDeployedBasketHarness();
        vm.etch(COLLECTOR, hex"60006000f3");
    }

    function testFeeRecipientCodeHashMustMatchExactly() public view {
        verifier.requireCodeHash("collector", COLLECTOR, COLLECTOR.codehash);
    }

    function testFeeRecipientCodeHashMismatchReverts() public {
        bytes32 wrong = keccak256("wrong collector runtime");
        vm.expectRevert(
            abi.encodeWithSelector(
                VerifyDeployedBasket.CodeHashMismatch.selector, "collector", wrong, COLLECTOR.codehash
            )
        );
        verifier.requireCodeHash("collector", COLLECTOR, wrong);
    }

    function testVerifierRejectsEveryNonzeroLaunchFee() public {
        verifier.requireLaunchFeesZero(0, 0, 0);

        vm.expectRevert(
            abi.encodeWithSelector(
                VerifyDeployedBasket.UintMismatch.selector, "launch.withdrawFeeBps", uint256(0), uint256(1)
            )
        );
        verifier.requireLaunchFeesZero(1, 0, 0);

        vm.expectRevert(
            abi.encodeWithSelector(
                VerifyDeployedBasket.UintMismatch.selector, "launch.holdingFeeBps", uint256(0), uint256(1)
            )
        );
        verifier.requireLaunchFeesZero(0, 1, 0);

        vm.expectRevert(
            abi.encodeWithSelector(
                VerifyDeployedBasket.UintMismatch.selector, "launch.referralShareBps", uint256(0), uint256(1)
            )
        );
        verifier.requireLaunchFeesZero(0, 0, 1);
    }
}
