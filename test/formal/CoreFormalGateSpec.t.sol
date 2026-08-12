// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  HARD-GATED symbolic (Halmos) proofs — every check in this contract is
//  MEASURED to discharge cleanly (sub-second, zero over-approximated paths on
//  CI run 31532581231), so the `formal` job runs it WITHOUT `|| true`: a
//  regression in any of these properties fails CI outright.
//
//  The split from CoreFormalSpec is deliberate: checks whose assertions route
//  the SMT solver through the 512-bit assembly mulDiv (mulmod
//  over-approximation, a known Halmos limitation) live there, report-only.
//  Checks land here only after a report-only CI run PROVES they discharge —
//  measured first, gated second.
//
//  Run: halmos --contract CoreFormalGateSpec
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixCore as BPC} from "../../src/BlazePhoenixCore.sol";

contract CoreFormalGateSpec is Test {
    // ─── The iron floor: the protocol's loss bound is UNCONDITIONAL ────────
    //
    // floor ∈ [BPS − FLOOR_HARD_MAX_LOSS_BPS, FLOOR_BASE_BPS] for EVERY input
    // — impact, leg count and sigma can shave the floor but can never push it
    // below the 80% hard cap, and never above the base. This is INV-1's
    // arithmetic heart: no input combination disables the loss bound.
    // (Measured: PASS, 18 paths, 0.17s.)
    function check_ironFloorBps_boundsUnconditional(
        uint256 impactBps, uint256 legCount, uint256 sigmaLn
    ) external pure {
        uint256 f = BPC.ironFloorBps(impactBps, legCount, sigmaLn);
        assert(f >= BPC.BPS - BPC.FLOOR_HARD_MAX_LOSS_BPS);
        assert(f <= BPC.FLOOR_BASE_BPS);
    }

    // ─── V2 impact is always a valid BPS fraction ──────────────────────────
    // (Measured: PASS, 15 paths, 0.19s.)
    function check_impactV2Bps_neverExceedsBPS(uint256 amountIn, uint256 reserveIn)
        external pure
    {
        uint256 i = BPC.impactV2Bps(amountIn, reserveIn);
        assert(i <= BPC.BPS);
    }

    // ─── V3 quote: degenerate inputs fail closed to 0 ──────────────────────
    //
    // A zero amount, zero liquidity, zero price or an invalid fee can never
    // produce a phantom output — the early returns fire before any 512-bit
    // arithmetic, which is also why this discharges cleanly.
    // (Measured: PASS, 9 paths, 0.04s.)
    function check_outV3_failClosedGuards(
        uint256 ain, uint160 sqrtP, uint128 liq, uint24 fee, bool zfo
    ) external pure {
        if (ain == 0 || liq == 0 || sqrtP == 0 || fee >= 1_000_000) {
            assert(BPC.outV3(ain, sqrtP, liq, fee, zfo) == 0);
        }
    }
}
