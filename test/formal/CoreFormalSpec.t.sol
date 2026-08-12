// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  Symbolic (Halmos) specifications for the load-bearing pure math in
//  BlazePhoenixCore. Functions prefixed check_ are executed SYMBOLICALLY by
//  Halmos over the real compiled bytecode — including the Yul/assembly the
//  source-level SMTChecker cannot see — so a pass here is a proof over the
//  entire (bounded) input domain, not a sampled fuzz.
//
//  REPORT-ONLY residue: every check remaining in this contract asserts
//  THROUGH the 512-bit assembly mulDiv, which Halmos over-approximates
//  (mulmod — known limitation), so the solver TIMEOUTs instead of
//  discharging (measured 60–189s each on CI run 31532581231). The checks
//  that discharge cleanly were promoted to CoreFormalGateSpec.t.sol and are
//  hard-gated there. If a solver upgrade ever discharges one of these, move
//  it over — measured first, gated second.
//
//  Run: halmos --contract CoreFormalSpec
//  (CI runs this in the `formal` job; plain `forge test` only compiles this
//  file — there are deliberately no test_ functions.)
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixCore as BPC} from "../../src/BlazePhoenixCore.sol";

contract CoreFormalSpec is Test {
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

    // ─── V3 quote: in-tick output bounded by the virtual reserve ───────────
    //
    // The in-tick output can never exceed the virtual token1 reserve
    // L·√P/Q96 — the arithmetic ceiling of the single-tick model. (The
    // companion fail-closed-guards check was promoted to the hard gate.)
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
