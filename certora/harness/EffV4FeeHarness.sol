// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {BlazePhoenixCore as BPC} from "../../src/BlazePhoenixCore.sol";

/// @notice Certora harness exposing the pure INV-20 fee resolver so the Prover
///         can verify its fail-closed guarantees end-to-end. effV4Fee is a
///         library-internal pure function (inlined here); no state, no
///         assembly, no transient storage — a clean target for CVL.
contract EffV4FeeHarness {
    function effV4Fee(uint24 keyFee, uint24 lpFee, uint24 protoFee)
        external
        pure
        returns (uint24)
    {
        return BPC.effV4Fee(keyFee, lpFee, protoFee);
    }
}
