// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  Halmos symbolic checks: the band, the hop fee, the dust probe.
//  Each check names the mutant that turns it red (.github/scripts/mutants.py).
//  Run: halmos --contract SolverBandFeeDustFormalSpec
//  Report-only in CI until measured green there: a timeout or an exhausted
//  loop bound is INCONCLUSIVE, never a pass.
//
//  Every check here calls the src and states a property of that code. Only the
//  hop fee assumes facts (vm.assume), and only two: L0 (mulDiv's 512-bit branch
//  is dead under 2^128 x 2^128) and CEIL (the code's mulDivUp at the protocol
//  fee is the integer ceiling). Each is proved by its own check_lemma in its own
//  CI shard; H2 counts as green only with both lemmas green. The band and the
//  dust probe assume nothing. Each fact is branch-free and reads `!pre || fact`:
//  an instance whose precondition fails assumes nothing.
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixCore as BPC, Hop} from "../../src/BlazePhoenixCore.sol";
import {BlazePhoenixMath as M} from "../../src/BlazePhoenixMath.sol";

contract SolverBandFeeDustFormalSpec is Test {
    uint256 constant PIPS = 1e6;

    // ─── THE FACTS (each proved by the check_lemma named on it) ───

    /// L0 (check_lemmaMulmodFits): a, b < 2^128 => mulmod(a, b, 2^256 - 1) == a * b, so
    /// mulDiv's high word prod1 is 0 and its 512-bit branch is dead.
    function _fFits(uint256 a, uint256 b) internal pure returns (bool ok) {
        assembly {
            let m := 0xffffffffffffffffffffffffffffffff
            ok := or(or(gt(a, m), gt(b, m)), eq(mulmod(a, b, not(0)), mul(a, b)))
        }
    }

    /// CEIL (check_lemmaHopFeeIsCeiling): b < 2^128 => fee*1e4 >= 28b and fee*1e4 < 28b + 1e4,
    /// i.e. fee == ceil(28b / 1e4), the integer ceiling with no division in the oracle.
    function _fCeil(uint256 b, uint256 fee) internal pure returns (bool ok) {
        assembly {
            let t := mul(b, 28)
            let u := mul(fee, 10000)
            ok := or(gt(b, 0xffffffffffffffffffffffffffffffff), and(iszero(lt(u, t)), lt(u, add(t, 10000))))
        }
    }

    function _mul(uint256 a, uint256 b) internal pure returns (uint256 r) {
        assembly { r := mul(a, b) }
    }

    function _div(uint256 a, uint256 b) internal pure returns (uint256 r) {
        assembly { r := div(a, b) }
    }

    // ─── THE LEMMAS: one fact each, one CI shard each ───
    // Mutant L0: _fFits drops `gt(b, m)` -> check_lemmaMulmodFits red (a = b = 2^128).
    // Mutant CEIL: src/BlazePhoenixCore.sol:535 mulDivUp `r += 1` -> `r += 0` -> check_lemmaHopFeeIsCeiling red.
    function check_lemmaMulmodFits(uint256 a, uint256 b) public pure {
        assertTrue(_fFits(a, b));
    }

    /// The hop fee is the integer ceiling: the code's mulDivUp, fee*1e4 bracketing 28b.
    function check_lemmaHopFeeIsCeiling(uint128 b) public pure {
        vm.assume(_fFits(b, BPC.PROTOCOL_FEE_BPS));   // L0
        assertTrue(_fCeil(b, BPC.mulDivUp(b, BPC.PROTOCOL_FEE_BPS, BPC.BPS)));
    }

    // ─── H1: THE BAND (Math._inBand / _keep) ───
    // (a) a live base is always in its own band: both edges hold at i == b because
    //     k_b <= WAD and (1 - f_b) <= 1, and every product rounds down;
    // (b) raising an error bound never drops a row: k falls, so the upper edge's
    //     left side falls and the lower edge's right side falls (monotone floors);
    // (c) no base (b >= n) keeps nothing; a dead row (price 0) is never kept.
    // Mutant H1: src/BlazePhoenixMath.sol:538 `, BPC.WAD) <= pb` -> `, BPC.WAD) < pb`
    //     (f_b = e_b = 0 makes the product equal pb: the base drops itself).
    function _fe(uint24 f, uint64 e, uint64 eo) internal pure returns (uint256) {
        return uint256(f) | uint256(e) << 24 | uint256(eo) << 88;
    }

    // (a), (b) and (c) are three checks over the same domain (same arguments, same
    // assumptions, same rows): forall x: a and b and c holds iff each holds on its own,
    // and _inBand is pure. Split so each check makes one or two _inBand calls instead of
    // four (the solver's paths multiply per call). Mutant H1 is killed by (a).
    function _bandRows(uint128 p0, uint128 p1, uint24 f0, uint24 f1, uint64 e0, uint64 e1, uint64 eo0)
        internal
        pure
        returns (uint256[] memory prices, uint256[] memory fe)
    {
        prices = new uint256[](2);
        fe = new uint256[](2);
        prices[0] = p0;
        prices[1] = p1;
        fe[0] = _fe(f0, e0, eo0);
        fe[1] = _fe(f1, e1, e1);
    }

    function check_bandKeepsLiveBase(
        uint128 p0, uint128 p1, uint24 f0, uint24 f1, uint64 e0, uint64 e1, uint64 eo0, uint64 e1w
    ) public pure {
        vm.assume(p0 > 0 && f0 < PIPS && f1 < PIPS && eo0 >= e0 && e1w >= e1);
        (uint256[] memory prices, uint256[] memory fe) = _bandRows(p0, p1, f0, f1, e0, e1, eo0);
        assertEq(M._inBand(prices, fe, 2, 0) & 1, 1, "live base dropped from its own band");
    }

    function check_bandOnlyWidens(
        uint128 p0, uint128 p1, uint24 f0, uint24 f1, uint64 e0, uint64 e1, uint64 eo0, uint64 e1w
    ) public pure {
        vm.assume(p0 > 0 && f0 < PIPS && f1 < PIPS && eo0 >= e0 && e1w >= e1);
        (uint256[] memory prices, uint256[] memory fe) = _bandRows(p0, p1, f0, f1, e0, e1, eo0);
        uint256 set = M._inBand(prices, fe, 2, 0);
        fe[1] = _fe(f1, e1w, e1w);
        uint256 wider = M._inBand(prices, fe, 2, 0);
        assertEq(set & ~wider, 0, "a wider bound dropped a row");
    }

    function check_bandNoBaseAndDeadRow(
        uint128 p0, uint128 p1, uint24 f0, uint24 f1, uint64 e0, uint64 e1, uint64 eo0, uint64 e1w
    ) public pure {
        vm.assume(p0 > 0 && f0 < PIPS && f1 < PIPS && eo0 >= e0 && e1w >= e1);
        (uint256[] memory prices, uint256[] memory fe) = _bandRows(p0, p1, f0, f1, e0, e1, eo0);
        fe[1] = _fe(f1, e1w, e1w);
        assertEq(M._inBand(prices, fe, 2, 2), 0, "b >= n kept a row");
        prices[1] = 0;
        assertEq(M._inBand(prices, fe, 2, 0) & 2, 0, "a dead row was kept");
    }

    // ─── H2: THE HOP FEE (Router._chargeHopFee, Core.netOfInputFees) ───
    // fee = ceil(b * 28 / 1e4) for every b <= uint128.max (oracle: the integer
    // ceiling, not the code's mulDivUp; proved by check_lemmaHopFeeIsCeiling as
    // fee*1e4 in [28b, 28b + 1e4)); b > 0 => fee > 0 (no fee-free swap at
    // 357 wei or less); b >= 2 => fee < b (RouterE(8) only at b == 1); the Core
    // sibling scales a one-hop output by (b - fee) / b, rounded down.
    // Mutant H2: src/BlazePhoenixCore.sol:461 `mulDivUp(b, PROTOCOL_FEE_BPS, BPS)`
    //     -> `mulDiv(b, PROTOCOL_FEE_BPS, BPS)`: net no longer matches the scale by the
    //     ceiling fee. Router `_chargeHopFee` is private: its own mutant
    //     (mulDivUp -> mulDiv) is killed by the forge tests on the 357-wei edge.
    function check_hopFeeRoundsUpAndNetMatches(uint128 b, uint128 base) public pure {
        vm.assume(_fFits(b, BPC.PROTOCOL_FEE_BPS));
        uint256 fee = BPC.mulDivUp(b, BPC.PROTOCOL_FEE_BPS, BPC.BPS);
        vm.assume(_fCeil(b, fee));
        if (b > 0) assertGt(fee, 0, "non-zero base paid no fee");
        if (b >= 2) assertLt(fee, b, "fee swallowed a base of 2 wei or more");
        uint256 keep;
        assembly { keep := sub(b, fee) }   // wraps when fee > b: L0's precondition then fails
        vm.assume(_fFits(base, keep));
        Hop[] memory hops = new Hop[](1);
        hops[0].amountIn = b;
        uint256 net = BPC.netOfInputFees(hops, base, type(uint256).max, false);
        uint256 want = b > fee ? _div(_mul(base, keep), b) : 0;
        assertEq(net, want, "net of the input fee differs from the ceiling fee");
    }

    // ─── H3: THE DUST PROBE (Solver probe m / 100, Core.outV2) ───
    // The probe is m / 100, or m when that is 0. Under 19 wei the rounding terms
    // widen the band past the 2x row (test/FindingAnchorDonation.t.sol:124); at
    // 1 wei a V2 row at price <= 1 quotes 0 (a floor), so it does not vote
    // (Solver `if (o > 0)`). Never above spot, at any size.
    // Mutant H3: src/BlazePhoenixCore.sol:1413
    //     `return (amtFee * rOut) / (rIn * BPS + amtFee);`
    //  -> `return (amtFee * rOut + rIn * BPS + amtFee - 1) / (rIn * BPS + amtFee);`
    //     (a ceiling: the dead dust row quotes 1 and votes).
    // (i) and (ii) in one check, (iii) in another, over the same domain and the same
    // probe: forall x: a and b holds iff each holds on its own (outV2 is pure). Split so
    // the floor at 1 wei and the spot bound at the probe each get the solver's whole
    // budget. Mutant H3 is killed by (ii).
    function check_dustProbeV2FloorsToZero(uint112 rIn, uint112 rOut, uint64 m) public pure {
        vm.assume(rIn > 0 && rOut > 0);
        uint256 probe = m / 100 == 0 ? m : m / 100;   // mirrors the Solver's probe
        if (m >= 1900) assertGe(probe, 19, "dust probe above m = 1900");
        if (rOut <= rIn) assertEq(BPC.outV2(1, rIn, rOut, 30), 0, "1 wei quoted at price <= 1");
    }

    function check_dustProbeNeverAboveSpot(uint112 rIn, uint112 rOut, uint64 m) public pure {
        vm.assume(rIn > 0 && rOut > 0);
        uint256 probe = m / 100 == 0 ? m : m / 100;   // mirrors the Solver's probe
        assertLe(BPC.outV2(probe, rIn, rOut, 30) * uint256(rIn), probe * uint256(rOut), "quote above spot");
    }
}
