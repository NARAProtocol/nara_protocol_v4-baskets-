// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Script} from "forge-std/Script.sol";

/// @notice The legacy v3/LINK-stand-in buy proof is intentionally disabled.
/// @dev Use only an exact fresh-v4 basket candidate after its deployment inputs
///      and round-flow test plan have been approved and recorded in a manifest.
contract TestBuyFork is Script {
    error ExactFreshV4ForkCandidateRequired();

    function run() external pure {
        revert ExactFreshV4ForkCandidateRequired();
    }
}
