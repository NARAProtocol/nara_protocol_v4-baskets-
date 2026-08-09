// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Script} from "forge-std/Script.sol";

/// @notice Disabled legacy deployment entry point.
/// @dev Use DeployMainnetReady.s.sol against a separately verified test environment.
contract DeployBaseSepolia is Script {
    error LegacyDeployDisabled();

    function run() external pure {
        revert LegacyDeployDisabled();
    }
}
