// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Consistency check for a semantic change made to already-shipped code. Two edits landed on
// logic every routing decision depends on:
//
//   1. tickSlot() now increments from the DECAYED swapCount instead of the raw cumulative total.
//   2. vitality() was refactored to delegate its decay arithmetic to _decayedSwapCount instead
//      of carrying a second copy (R5: one implementation per published quantity).
//
// Edit 2 was claimed to be behaviour-preserving. "The suite still passes" is weak evidence for
// that claim — the suite was not written to pin every branch of a scoring function. This file
// re-implements the PRE-REFACTOR vitality() verbatim and fuzzes both against the same inputs,
// so any divergence in any branch (dead slot vs floored-to-1 live slot, the 32-step horizon,
// the never-ticked sentinel, timestamp underflow) fails loudly.
//
// forge test --match-contract VitalityRefactorEquivalence -vv

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixCore as BPC} from "../src/BlazePhoenixCore.sol";

contract VitalityRefactorEquivalenceTest is Test {
    uint256 constant STEP = 24_576; // VITALITY_DECAY_STEP_SECONDS

    /// @dev The exact pre-refactor implementation, copied verbatim from git history
    ///      (BlazePhoenixCore.sol @ 12ded3b, lines 964-978).
    function _vitalityOld(uint256 slot, uint32 currentTs) internal pure returns (uint256 v) {
        if (slot == 0) return 0;
        uint32 lastTs = BPC.decodeLastUpdateTs(slot);
        if (lastTs == 0) return 0;
        uint32 age = currentTs > lastTs ? currentTs - lastTs : 0;
        uint32 swapCount = BPC.decodeSwapCount(slot);
        if (age >= STEP) {
            uint256 shift = age / STEP;
            if (shift > 31) return 0;
            v = uint256(swapCount) >> shift;
        } else {
            v = uint256(swapCount);
        }
        if (v == 0) v = 1;
    }

    /// Broad fuzz over the whole encoded-slot domain.
    function testFuzz_vitality_refactorIsBehaviourPreserving(
        uint24 fee, uint8 kind, uint8 tier, uint16 conc,
        uint32 lastTs, uint32 swapCount, uint32 currentTs
    ) public pure {
        kind = uint8(bound(kind, 0, 7));
        uint256 slot = BPC.encodeSlot(true, fee, kind, tier, conc, lastTs, 0, 0, swapCount, 0, 0);
        assertEq(BPC.vitality(slot, currentTs), _vitalityOld(slot, currentTs),
            "vitality diverged from its pre-refactor behaviour");
    }

    /// The empty slot is its own sentinel and never reaches the codec.
    function testFuzz_vitality_zeroSlot(uint32 currentTs) public pure {
        assertEq(BPC.vitality(0, currentTs), _vitalityOld(0, currentTs));
        assertEq(BPC.vitality(0, currentTs), 0, "an empty slot must score a true zero");
    }

    /// Targeted sweep of the branch boundaries the broad fuzz is unlikely to hit exactly:
    /// the never-ticked sentinel, age 0, the first decay step, the 31/32-step horizon either
    /// side of the cliff, and currentTs < lastTs (clock underflow).
    function testFuzz_vitality_branchBoundaries(uint32 swapCount, uint8 stepSeed) public pure {
        uint32 lastTs = 1_000_000;
        uint256 slot = BPC.encodeSlot(true, 3000, 1, 0, 0, lastTs, 0, 0, swapCount, 0, 0);

        // never-ticked sentinel: lastUpdateTs == 0 must score a true zero, not a floored 1.
        uint256 neverTicked = BPC.encodeSlot(true, 3000, 1, 0, 0, 0, 0, 0, swapCount, 0, 0);
        assertEq(BPC.vitality(neverTicked, lastTs), _vitalityOld(neverTicked, lastTs), "never-ticked");
        assertEq(BPC.vitality(neverTicked, lastTs), 0, "never-ticked slot must be a true zero");

        // clock underflow: currentTs strictly before lastTs.
        assertEq(BPC.vitality(slot, lastTs - 1), _vitalityOld(slot, lastTs - 1), "clock underflow");

        // exact step multiples around the full-decay cliff (shift 0..33).
        uint256 shift = bound(stepSeed, 0, 33);
        uint32 ts = uint32(uint256(lastTs) + shift * STEP);
        assertEq(BPC.vitality(slot, ts), _vitalityOld(slot, ts), "step-multiple boundary");
        // one second either side of each multiple
        assertEq(BPC.vitality(slot, ts + 1), _vitalityOld(slot, ts + 1), "boundary +1s");
        if (ts > lastTs) {
            assertEq(BPC.vitality(slot, ts - 1), _vitalityOld(slot, ts - 1), "boundary -1s");
        }
    }

    /// psi() is the actual consumer — confirm the refactor didn't shift composite fitness either
    /// (psi multiplies vitality by the depth bucket and applies the bridge/concentration bonuses,
    /// so a divergence of 1 in vitality is amplified, not hidden).
    function testFuzz_psi_unchangedByRefactor(
        uint32 lastTs, uint32 swapCount, uint32 currentTs, uint8 bucket, bool bridge, bool conc
    ) public pure {
        uint256 slot = BPC.encodeSlot(true, 3000, 1, 0, 0, lastTs, 0, 0, swapCount, 0, 0);
        slot = BPC.setBucket(slot, uint8(bound(bucket, 0, 15)));

        uint256 vOld = _vitalityOld(slot, currentTs);
        uint256 expected;
        if (vOld != 0) {
            uint256 w = BPC.bucketWeight(BPC.decodeBucket(slot));
            if (w == 0) w = 1;
            expected = vOld * w;
            if (bridge) expected += (expected * 2_500) / BPC.BPS;
            if (conc) expected += (expected * 500) / BPC.BPS;
        }
        assertEq(BPC.psi(slot, currentTs, bridge, conc), expected, "psi diverged after the refactor");
    }
}
