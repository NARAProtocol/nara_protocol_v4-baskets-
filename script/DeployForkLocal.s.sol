// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Script} from "forge-std/Script.sol";

/// @notice The legacy LINK-stand-in fork deployment is intentionally disabled.
/// @dev A replacement rehearsal must bind the fresh NARA v4 token, registered
///      hook pool, exact adapter, zero launch-only fees, and approved manifest.
contract DeployForkLocal is Script {
    error ExactFreshV4ForkCandidateRequired();

    function run() external pure {
        revert ExactFreshV4ForkCandidateRequired();
    }
}
