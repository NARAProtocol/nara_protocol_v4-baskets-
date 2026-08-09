// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Script} from "forge-std/Script.sol";

/// @notice The obsolete single-adapter receipt-basket example is disabled.
/// @dev It cannot satisfy the fixed-v4 adapter, zero launch-fee, role, fork,
///      and deployment-manifest gates required by DeployMainnetReady.
contract CreateReceiptBasketExample is Script {
    error NoncanonicalDeploymentDisabled();

    function run() external pure {
        revert NoncanonicalDeploymentDisabled();
    }
}
