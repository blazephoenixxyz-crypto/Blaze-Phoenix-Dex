// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  Halmos symbolic checks: the band, the hop fee, the dust probe, the split.
//  Each check names the mutant that turns it red (.github/scripts/mutants.py).
//  Run: halmos --contract SolverBandFeeDustFormalSpec
//  Report-only in CI until measured green there: a timeout or an exhausted
//  loop bound is INCONCLUSIVE, never a pass.
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixCore as BPC, Hop} from "../../src/BlazePhoenixCore.sol";
import {BlazePhoenixMath as M} from "../../src/BlazePhoenixMath.sol";

contract SolverBandFeeDustFormalSpec is Test {
    uint256 constant PIPS = 1e6;

    // ─── H1: THE BAND (Math._inBand / _keep) ───
    // (a) a live base is always in its own band: both edges hold at i == b because
    //     k_b <= WAD and (1 - f_b) <= 1, and every product rounds down;
    // (b) raising an error bound never drops a row: k falls, so the upper edge's
    //     left side falls and the lower edge's right side falls (monotone floors);
    // (c) no base (b >= n) keeps nothing; a dead row (price 0) is never kept.
    // Mutant 124-HAL-H1: src/BlazePhoenixMath.sol:538 `, BPC.WAD) <= pb` -> `, BPC.WAD) < pb`
    //     (f_b = e_b = 0 makes the product equal pb: the base drops itself).
    function _fe(uint24 f, uint64 e, uint64 eo) internal pure returns (uint256) {
        return uint256(f) | uint256(e) << 24 | uint256(eo) << 88;
    }

    function check_bandKeepsLiveBaseAndOnlyWidens(
        uint128 p0, uint128 p1, uint24 f0, uint24 f1, uint64 e0, uint64 e1, uint64 eo0, uint64 e1w
    ) public pure {
        vm.assume(p0 > 0 && f0 < PIPS && f1 < PIPS && eo0 >= e0 && e1w >= e1);
        uint256[] memory prices = new uint256[](2);
        uint256[] memory fe = new uint256[](2);
        prices[0] = p0;
        prices[1] = p1;
        fe[0] = _fe(f0, e0, eo0);
        fe[1] = _fe(f1, e1, e1);
        uint256 set = M._inBand(prices, fe, 2, 0);
        assertEq(set & 1, 1, "live base dropped from its own band");
        fe[1] = _fe(f1, e1w, e1w);
        uint256 wider = M._inBand(prices, fe, 2, 0);
        assertEq(set & ~wider, 0, "a wider bound dropped a row");
        assertEq(M._inBand(prices, fe, 2, 2), 0, "b >= n kept a row");
        prices[1] = 0;
        assertEq(M._inBand(prices, fe, 2, 0) & 2, 0, "a dead row was kept");
    }

    // ─── H2: THE HOP FEE (Router._chargeHopFee, Core.netOfInputFees) ───
    // fee = ceil(b * 28 / 1e4) for every b <= uint128.max (oracle: the integer
    // ceiling, not the code's mulDivUp); b > 0 => fee > 0 (no fee-free swap at
    // 357 wei or less); b >= 2 => fee < b (RouterE(8) only at b == 1); the Core
    // sibling scales a one-hop output by (b - fee) / b, rounded down.
    // Mutant 124-HAL-H2: src/BlazePhoenixCore.sol:461 `mulDivUp(b, PROTOCOL_FEE_BPS, BPS)`
    //     -> `mulDiv(b, PROTOCOL_FEE_BPS, BPS)`. Router `_chargeHopFee` is private: its
    //     own mutant (mulDivUp -> mulDiv) is killed by the forge tests on the 357-wei
    //     edge, not by this check.
    function check_hopFeeRoundsUpAndNetMatches(uint128 b, uint128 base) public pure {
        uint256 oracle = (uint256(b) * BPC.PROTOCOL_FEE_BPS + BPC.BPS - 1) / BPC.BPS;
        uint256 fee = BPC.mulDivUp(b, BPC.PROTOCOL_FEE_BPS, BPC.BPS);
        assertEq(fee, oracle, "fee is not the ceiling");
        if (b > 0) assertGt(fee, 0, "non-zero base paid no fee");
        if (b >= 2) assertLt(fee, b, "fee swallowed a base of 2 wei or more");
        Hop[] memory hops = new Hop[](1);
        hops[0].amountIn = b;
        uint256 net = BPC.netOfInputFees(hops, base, type(uint256).max, false);
        uint256 want = b > oracle ? uint256(base) * (uint256(b) - oracle) / b : 0;
        assertEq(net, want, "net of the input fee differs from the ceiling fee");
    }

    // ─── H3: THE DUST PROBE (Solver probe m / 100, Core.outV2) ───
    // The probe is m / 100, or m when that is 0. Under 19 wei the rounding terms
    // widen the band past the 2x row (test/FindingAnchorDonation.t.sol:124); at
    // 1 wei a V2 row at price <= 1 quotes 0 (a floor), so it does not vote
    // (Solver `if (o > 0)`). Never above spot, at any size.
    // Mutant 124-HAL-H3: src/BlazePhoenixCore.sol:1413
    //     `return (amtFee * rOut) / (rIn * BPS + amtFee);`
    //  -> `return (amtFee * rOut + rIn * BPS + amtFee - 1) / (rIn * BPS + amtFee);`
    //     (a ceiling: the dead dust row quotes 1 and votes).
    function check_dustProbeV2FloorsToZero(uint112 rIn, uint112 rOut, uint64 m) public pure {
        vm.assume(rIn > 0 && rOut > 0);
        uint256 probe = m / 100 == 0 ? m : m / 100;   // mirrors the Solver's probe
        if (m >= 1900) assertGe(probe, 19, "dust probe above m = 1900");
        if (rOut <= rIn) assertEq(BPC.outV2(1, rIn, rOut, 30), 0, "1 wei quoted at price <= 1");
        assertLe(BPC.outV2(probe, rIn, rOut, 30) * uint256(rIn), probe * uint256(rOut), "quote above spot");
    }

    // ─── H4: THE SPLIT (Solver._split: floors, then the remainder) ───
    // With sumPsi the sum of the psis, the floors of amountIn * psi_i / sumPsi over
    // the first n - 1 legs sum to at most amountIn, so the last leg's
    // `amountIn - allocated` never underflows and the legs sum to EXACTLY the
    // order, never more. A lemma: `_split` and `_weights` are private, so this
    // mirrors the floor at n = 3.
    // Mutant 124-HAL-H4: src/BlazePhoenixSolver.sol:1034
    //     `share = BPC.mulDiv(amountIn, psis[i], sumPsi);` -> `BPC.mulDivUp(...)`.
    //     The lemma holds for floors only; the src mutant is killed by a Solver test,
    //     not by this mirror: test/SplitSharesAreFloors.t.sol (no leg under its floor
    //     share on equal venues; the legs' sum alone cannot see the rounding).
    function check_splitFloorsNeverOvershoot(uint128 a, uint64 w0, uint64 w1, uint64 w2) public pure {
        uint256 s = uint256(w0) + w1 + w2;
        vm.assume(s > 0);
        uint256 alloc = BPC.mulDiv(a, w0, s) + BPC.mulDiv(a, w1, s);
        assertLe(alloc, a, "floors overshoot the order");
        assertEq(alloc + (a - alloc), a, "legs do not sum to the order");
    }
}
