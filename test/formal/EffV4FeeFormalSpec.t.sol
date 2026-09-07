// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  Halmos symbolic proof — INV-20 (V4-FEE-MEASURED): the static key composes
//  the manager's per-direction protocol fee; the dynamic key fails closed. Keyless, free:
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

    /// A static-fee key is truth when the manager takes no protocol fee in the
    /// swap's direction: slot0's lpFee is ignored, the key fee returns verbatim.
    function check_staticKeyIsTruthWithoutProtocolFee(uint24 keyFee, uint24 lpFee, uint24 protoFee, bool zeroForOne) public pure {
        vm.assume(keyFee != DYN);
        uint256 pf = zeroForOne ? uint256(protoFee & 0xFFF) : uint256(protoFee >> 12);
        vm.assume(pf == 0);
        assertEq(uint256(BPC.effV4Fee(keyFee, lpFee, protoFee, zeroForOne)), uint256(keyFee));
    }

    /// With a protocol fee p in the swap's direction, a static key composes
    /// p + lp − p·lp/1e6 (v4-core's calculateSwapFee): never below the key fee,
    /// never above key fee + p, and — for any LP fee the manager admits (≤ 1e6)
    /// — never the unquotable band, so a static pool is always priced.
    function check_staticKeyComposesProtocolFee(uint24 keyFee, uint24 lpFee, uint24 protoFee, bool zeroForOne) public pure {
        vm.assume(keyFee != DYN && keyFee <= 1_000_000);
        uint256 pf = zeroForOne ? uint256(protoFee & 0xFFF) : uint256(protoFee >> 12);
        vm.assume(pf != 0);
        uint256 r = uint256(BPC.effV4Fee(keyFee, lpFee, protoFee, zeroForOne));
        assertEq(r, pf + uint256(keyFee) - (pf * uint256(keyFee)) / 1_000_000);
        assertGe(r, uint256(keyFee));
        assertLe(r, uint256(keyFee) + pf);
        assertLe(r, 1_000_000);
    }

    /// A dynamic-fee pool with ANY non-zero protocolFee fails closed to >= 1e6
    /// (unquotable) — it can never under-charge.
    function check_dynamicProtoFeeFailsClosed(uint24 lpFee, uint24 protoFee) public pure {
        vm.assume(protoFee != 0);
        assertGe(uint256(BPC.effV4Fee(DYN, lpFee, protoFee, true)), 1_000_000);
        assertGe(uint256(BPC.effV4Fee(DYN, lpFee, protoFee, false)), 1_000_000);
    }

    /// A live dynamic-fee pool (protoFee == 0) prices from the measured slot0 lpFee.
    function check_dynamicUsesMeasuredLpFee(uint24 lpFee) public pure {
        assertEq(uint256(BPC.effV4Fee(DYN, lpFee, 0, true)), uint256(lpFee));
    }

    /// The sentinel itself is never the resolved fee for a live pool — so it only
    /// ever reaches outV3's >=1e6 guard when we deliberately fail closed.
    function check_sentinelNeverSurvivesForLivePool(uint24 lpFee) public pure {
        uint24 r = BPC.effV4Fee(DYN, lpFee, 0, true);
        assertTrue(r != DYN || lpFee == DYN);
    }
}
