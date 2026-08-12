// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  Halmos symbolic proof — INV-20 (V4-FEE-MEASURED) fail-closed. Keyless, free:
//  the same guarantees the Certora scaffold targets, proved here with Halmos so
//  no paid prover key is needed. effV4Fee is pure comparisons (no 512-bit mulDiv
//  over-approximation), so these run as a REAL gate, not report-only.
//
//  Run: halmos --contract EffV4FeeFormalSpec
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixCore as BPC} from "../../src/BlazePhoenixCore.sol";

contract EffV4FeeFormalSpec is Test {
    uint24 constant DYN = 0x800000; // dynamic-fee sentinel

    /// A static-fee key is truth: slot0 is ignored, the key fee is returned verbatim.
    function check_staticKeyIsTruth(uint24 keyFee, uint24 lpFee, uint24 protoFee) public pure {
        vm.assume(keyFee != DYN);
        assertEq(uint256(BPC.effV4Fee(keyFee, lpFee, protoFee)), uint256(keyFee));
    }

    /// A dynamic-fee pool with ANY non-zero protocolFee fails closed to >= 1e6
    /// (unquotable) — it can never under-charge.
    function check_dynamicProtoFeeFailsClosed(uint24 lpFee, uint24 protoFee) public pure {
        vm.assume(protoFee != 0);
        assertGe(uint256(BPC.effV4Fee(DYN, lpFee, protoFee)), 1_000_000);
    }

    /// A live dynamic-fee pool (protoFee == 0) prices from the measured slot0 lpFee.
    function check_dynamicUsesMeasuredLpFee(uint24 lpFee) public pure {
        assertEq(uint256(BPC.effV4Fee(DYN, lpFee, 0)), uint256(lpFee));
    }

    /// The sentinel itself is never the resolved fee for a live pool — so it only
    /// ever reaches outV3's >=1e6 guard when we deliberately fail closed.
    function check_sentinelNeverSurvivesForLivePool(uint24 lpFee) public pure {
        uint24 r = BPC.effV4Fee(DYN, lpFee, 0);
        assertTrue(r != DYN || lpFee == DYN);
    }
}
