// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Script} from "forge-std/Script.sol";

/// @notice Disabled legacy deployment entry point.
/// @dev Use DeployMainnetReady.s.sol for the immutable receipt-manager launch.
contract DeployBaseMainnet is Script {
    error LegacyDeployDisabled();

    function run() external pure {
        revert LegacyDeployDisabled();
    }
}
