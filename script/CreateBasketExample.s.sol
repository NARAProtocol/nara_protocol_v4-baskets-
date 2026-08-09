// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Script} from "forge-std/Script.sol";

/// @notice Disabled legacy static-vault example.
/// @dev The canonical launch product is deployed only by DeployMainnetReady.s.sol.
contract CreateBasketExample is Script {
    error NoncanonicalDeploymentDisabled();

    function run() external pure {
        revert NoncanonicalDeploymentDisabled();
    }
}
