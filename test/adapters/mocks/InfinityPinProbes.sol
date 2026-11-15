// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {BlazePhoenixAdapterInfinityCL} from "../../../src/adapters/BlazePhoenixAdapterInfinityCL.sol";
import {BlazePhoenixAdapterInfinityBin} from "../../../src/adapters/BlazePhoenixAdapterInfinityBin.sol";

/// The Infinity adapters pin hooks into ExtAdapterBase's three slots, which are `internal`: these
/// probes run the adapter's own constructor unchanged and only read the slots back.
contract InfinityCLPinProbe is BlazePhoenixAdapterInfinityCL {
    constructor(address gate, address clManager, address[3] memory refHooks)
        BlazePhoenixAdapterInfinityCL(gate, clManager, refHooks) {}

    function pins() external view returns (bytes32, bytes32, bytes32) {
        return (HOOK_CODEHASH0, HOOK_CODEHASH1, HOOK_CODEHASH2);
    }
}

contract InfinityBinPinProbe is BlazePhoenixAdapterInfinityBin {
    constructor(address gate, address binManager, address[3] memory refHooks)
        BlazePhoenixAdapterInfinityBin(gate, binManager, refHooks) {}

    function pins() external view returns (bytes32, bytes32, bytes32) {
        return (HOOK_CODEHASH0, HOOK_CODEHASH1, HOOK_CODEHASH2);
    }
}
