// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  Symbolic (Halmos) specifications for the load-bearing pure math in
//  BlazePhoenixCore. Functions prefixed check_ are executed SYMBOLICALLY by
//  Halmos over the real compiled bytecode — including the Yul/assembly the
//  source-level SMTChecker cannot see — so a pass here is a proof over the
//  entire (bounded) input domain, not a sampled fuzz.
//
//  Run: halmos --contract CoreFormalSpec
//  (CI runs this in the `formal` job; plain `forge test` only compiles this
//  file — there are deliberately no test_ functions.)
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixCore as BPC} from "../../src/BlazePhoenixCore.sol";

contract CoreFormalSpec is Test {
    // ─── The iron floor: the protocol's loss bound is UNCONDITIONAL ────────
    //
    // floor ∈ [BPS − FLOOR_HARD_MAX_LOSS_BPS, FLOOR_BASE_BPS] for EVERY input
    // — impact, leg count and sigma can shave the floor but can never push it
    // below the 80% hard cap, and never above the base. This is INV-1's
    // arithmetic heart: no input combination disables the loss bound.
    function check_ironFloorBps_boundsUnconditional(
        uint256 impactBps, uint256 legCount, uint256 sigmaLn
    ) external pure {
        uint256 f = BPC.ironFloorBps(impactBps, legCount, sigmaLn);
        assert(f >= BPC.BPS - BPC.FLOOR_HARD_MAX_LOSS_BPS);
        assert(f <= BPC.FLOOR_BASE_BPS);
    }

    // ─── V2 impact is always a valid BPS fraction ──────────────────────────
    function check_impactV2Bps_neverExceedsBPS(uint256 amountIn, uint256 reserveIn)
        external pure
    {
        uint256 i = BPC.impactV2Bps(amountIn, reserveIn);
        assert(i <= BPC.BPS);
    }

    // ─── V2 quote can never promise the whole counter-reserve ──────────────
    //
    // Bounded to the UniV2 reserve realm (uint112) and sane fees: the
    // constant-product output is strictly below rOut, so no route plan can be
    // built that drains a pool past its own curve.
    function check_outV2_neverReachesReserveOut(
        uint256 ain, uint256 rIn, uint256 rOut, uint256 fee
    ) external pure {
        vm.assume(rIn > 0 && rIn <= type(uint112).max);
        vm.assume(rOut > 0 && rOut <= type(uint112).max);
        vm.assume(ain > 0 && ain <= type(uint112).max);
        vm.assume(fee <= 1_000); // ≤10% in BPS — every wired venue is far below
        uint256 out = BPC.outV2(ain, rIn, rOut, fee);
        assert(out < rOut);
    }

    // ─── V3 quote: fail-closed guards + virtual-reserve bound ──────────────
    //
    // Degenerate inputs quote 0 (never a phantom output), and the in-tick
    // output can never exceed the virtual token1 reserve L·√P/Q96 — the
    // arithmetic ceiling of the single-tick model.
    function check_outV3_failClosedGuards(
        uint256 ain, uint160 sqrtP, uint128 liq, uint24 fee, bool zfo
    ) external pure {
        if (ain == 0 || liq == 0 || sqrtP == 0 || fee >= 1_000_000) {
            assert(BPC.outV3(ain, sqrtP, liq, fee, zfo) == 0);
        }
    }

    function check_outV3_zeroForOne_boundedByVirtualReserve(
        uint256 ain, uint160 sqrtP, uint128 liq, uint24 fee
    ) external pure {
        vm.assume(sqrtP > 0 && liq > 0 && fee < 1_000_000);
        uint256 out = BPC.outV3(ain, sqrtP, liq, fee, true);
        // out = L·(√P − √P') / Q96  ≤  L·√P / Q96
        assert(out <= BPC.mulDiv(uint256(liq), uint256(sqrtP), BPC.Q96));
    }

    // ─── mulDiv agrees with exact rational arithmetic off the overflow path ─
    //
    // For operands where a·b fits 256 bits, the 512-bit Yul implementation
    // must equal the plain a*b/d — anchoring the assembly to the arithmetic
    // it claims to implement.
    function check_mulDiv_matchesExactWhenNoOverflow(
        uint128 a, uint128 b, uint256 d
    ) external pure {
        vm.assume(d > 0);
        uint256 r = BPC.mulDiv(uint256(a), uint256(b), d);
        assert(r == (uint256(a) * uint256(b)) / d);
    }
}
