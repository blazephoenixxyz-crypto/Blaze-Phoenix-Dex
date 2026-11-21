// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  Halmos symbolic checks: the band, the hop fee, the dust probe, the split.
//  Each check names the mutant that turns it red (.github/scripts/mutants.py).
//  Run: halmos --contract SolverBandFeeDustFormalSpec
//  Report-only in CI until measured green there: a timeout or an exhausted
//  loop bound is INCONCLUSIVE, never a pass.
//
//  Assume-guarantee. H1-H4 still call the src. Halmos 0.3.3 abstracts a symbolic
//  mul or div as an uninterpreted function and refines to real 256-bit bvmul and
//  bvudiv when the abstract query is sat; run 44889632809 timed out in those
//  refined queries. So each arithmetic fact a check needs enters as
//  vm.assume(_fX(terms)), built from the SAME EVM terms (mul, div, mulmod) the src
//  produces. Each _fX is branch-free and reads `!pre || fact`, and each is proved
//  over all of uint256 (or the declared width) by its own check_lemmaX, in its own
//  CI shard. A check is green only when the check AND every lemma it assumes are
//  green. An instance whose precondition fails assumes nothing: a missing fact
//  costs time, never soundness.
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixCore as BPC, Hop} from "../../src/BlazePhoenixCore.sol";
import {BlazePhoenixMath as M} from "../../src/BlazePhoenixMath.sol";

contract SolverBandFeeDustFormalSpec is Test {
    uint256 constant PIPS = 1e6;
    uint256 constant WAD = 1e18;
    uint256 constant U112 = type(uint112).max;
    uint256 constant U64 = type(uint64).max;

    // ─── THE FACTS (each proved by the check_lemma named on it) ───

    /// L0 (check_lemmaMulmodFits): a, b < 2^128 => mulmod(a, b, 2^256 - 1) == a * b, so
    /// mulDiv's high word prod1 is 0 and its 512-bit branch is dead.
    function _fFits(uint256 a, uint256 b) internal pure returns (bool ok) {
        assembly {
            let m := 0xffffffffffffffffffffffffffffffff
            ok := or(or(gt(a, m), gt(b, m)), eq(mulmod(a, b, not(0)), mul(a, b)))
        }
    }

    /// EXACT (check_lemmaMulDivExact): x, y < 2^128 => x*y/x == y (x > 0) and x*y/y == x
    /// (y > 0). The first form is solc's checked-mul overflow test.
    function _fExact(uint256 x, uint256 y) internal pure returns (bool ok) {
        assembly {
            let m := 0xffffffffffffffffffffffffffffffff
            let p := mul(x, y)
            ok := or(or(gt(x, m), gt(y, m)),
                and(or(iszero(x), eq(div(p, x), y)), or(iszero(y), eq(div(p, y), x))))
        }
    }

    /// MUL-MONO-R (check_lemmaMulMonoR): a, c < 2^128, b <= c => a*b <= a*c.
    function _fMulMonoR(uint256 a, uint256 b, uint256 c) internal pure returns (bool ok) {
        assembly {
            let m := 0xffffffffffffffffffffffffffffffff
            ok := or(or(or(gt(a, m), gt(c, m)), gt(b, c)), iszero(gt(mul(a, b), mul(a, c))))
        }
    }

    /// MUL-MONO-L (check_lemmaMulMonoL): a, c < 2^128, b <= c => b*a <= c*a.
    function _fMulMonoL(uint256 a, uint256 b, uint256 c) internal pure returns (bool ok) {
        assembly {
            let m := 0xffffffffffffffffffffffffffffffff
            ok := or(or(or(gt(a, m), gt(c, m)), gt(b, c)), iszero(gt(mul(b, a), mul(c, a))))
        }
    }

    /// ASSOC-L (check_lemmaMulAssocL): c in {9970, 1e4} => (p*c)*r == (p*r)*c (mod 2^256).
    function _fAssocL(uint256 p, uint256 r, uint256 c) internal pure returns (bool ok) {
        assembly {
            ok := or(iszero(or(eq(c, 9970), eq(c, 10000))), eq(mul(mul(p, c), r), mul(mul(p, r), c)))
        }
    }

    /// ASSOC-R (check_lemmaMulAssocR): c in {9970, 1e4} => p*(r*c) == (p*r)*c (mod 2^256).
    function _fAssocR(uint256 p, uint256 r, uint256 c) internal pure returns (bool ok) {
        assembly {
            ok := or(iszero(or(eq(c, 9970), eq(c, 10000))), eq(mul(p, mul(r, c)), mul(mul(p, r), c)))
        }
    }

    /// DIST (check_lemmaMulDist): a*x + a*y == a*(x + y) (mod 2^256), no precondition.
    function _fDist(uint256 a, uint256 x, uint256 y) internal pure returns (bool ok) {
        assembly { ok := eq(add(mul(a, x), mul(a, y)), mul(a, add(x, y))) }
    }

    /// DIV-MONO (check_lemmaDivMono, d symbolic; check_lemmaDivMonoConst, d per branch in
    /// {100, 1e4, 1e6, 1e18}): d > 0, x <= y => x/d <= y/d.
    function _fDivMono(uint256 x, uint256 y, uint256 d) internal pure returns (bool ok) {
        assembly { ok := or(or(iszero(d), gt(x, y)), iszero(gt(div(x, d), div(y, d)))) }
    }

    /// DIV-ANTI (check_lemmaDivAnti): 0 < d <= e => x/e <= x/d.
    function _fDivAnti(uint256 x, uint256 d, uint256 e) internal pure returns (bool ok) {
        assembly { ok := or(or(iszero(d), gt(d, e)), iszero(gt(div(x, e), div(x, d)))) }
    }

    /// DIV-FLOOR (check_lemmaDivFloor): d > 0 => (x/d)*d <= x.
    function _fDivFloor(uint256 x, uint256 d) internal pure returns (bool ok) {
        assembly { ok := or(iszero(d), iszero(gt(mul(div(x, d), d), x))) }
    }

    /// DIV-ZERO (check_lemmaDivZero): x < d => x/d == 0.
    function _fDivZero(uint256 x, uint256 d) internal pure returns (bool ok) {
        assembly { ok := or(iszero(lt(x, d)), iszero(div(x, d))) }
    }

    /// FLOOR-SUPERADD (check_lemmaFloorSuperadd): s > 0, x + y < 2^256 => x/s + y/s <= (x+y)/s.
    function _fSuperadd(uint256 x, uint256 y, uint256 s) internal pure returns (bool ok) {
        assembly {
            ok := or(or(iszero(s), gt(x, not(y))), iszero(gt(add(div(x, s), div(y, s)), div(add(x, y), s))))
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
    // Mutant EXACT: `gt(y, m)` -> `gt(y, not(0))` -> check_lemmaMulDivExact red (x = 2, y = 2^255).
    // Mutant MUL-MONO-R: drops `gt(b, c)` -> check_lemmaMulMonoR red (a = 1, b = c + 1).
    // Mutant MUL-MONO-L: drops `gt(b, c)` -> check_lemmaMulMonoL red (a = 1, b = c + 1).
    // Mutant ASSOC-L: right side `mul(mul(p, r), c)` -> `mul(mul(p, r), add(c, 1))` -> check_lemmaMulAssocL red.
    // Mutant ASSOC-R: the same mutation -> check_lemmaMulAssocR red.
    // Mutant DIST: `add(x, y)` -> `add(x, add(y, 1))` -> check_lemmaMulDist red (a = 1).
    // Mutant DIV-MONO: `gt(x, y)` -> `lt(x, y)` -> check_lemmaDivMono and check_lemmaDivMonoConst red.
    // Mutant DIV-ANTI: `gt(d, e)` -> `lt(d, e)` -> check_lemmaDivAnti red.
    // Mutant DIV-FLOOR: `iszero(gt(mul(div(x, d), d), x))` -> `iszero(lt(...))` -> check_lemmaDivFloor red.
    // Mutant DIV-ZERO: `lt(x, d)` -> `gt(x, d)` -> check_lemmaDivZero red.
    // Mutant FLOOR-SUPERADD: `gt(add(div(x, s), div(y, s)), ...)` -> `lt(...)` -> check_lemmaFloorSuperadd
    //     red (x = y = 1, s = 2).
    // Mutant CEIL: src/BlazePhoenixCore.sol:535 mulDivUp `r += 1` -> `r += 0` -> check_lemmaHopFeeIsCeiling red.
    function check_lemmaMulmodFits(uint256 a, uint256 b) public pure {
        assertTrue(_fFits(a, b));
    }

    function check_lemmaMulDivExact(uint256 x, uint256 y) public pure {
        assertTrue(_fExact(x, y));
    }

    function check_lemmaMulMonoR(uint256 a, uint256 b, uint256 c) public pure {
        assertTrue(_fMulMonoR(a, b, c));
    }

    function check_lemmaMulMonoL(uint256 a, uint256 b, uint256 c) public pure {
        assertTrue(_fMulMonoL(a, b, c));
    }

    function check_lemmaMulAssocL(uint256 p, uint256 r, bool k) public pure {
        assertTrue(_fAssocL(p, r, k ? 9970 : 10000));
    }

    function check_lemmaMulAssocR(uint256 p, uint256 r, bool k) public pure {
        assertTrue(_fAssocR(p, r, k ? 9970 : 10000));
    }

    function check_lemmaMulDist(uint256 a, uint256 x, uint256 y) public pure {
        assertTrue(_fDist(a, x, y));
    }

    function check_lemmaDivMono(uint256 x, uint256 y, uint256 d) public pure {
        assertTrue(_fDivMono(x, y, d));
    }

    function check_lemmaDivMonoConst(uint256 x, uint256 y, uint8 k) public pure {
        uint256 d = k == 0 ? 100 : k == 1 ? 1e4 : k == 2 ? PIPS : WAD;
        assertTrue(_fDivMono(x, y, d));
    }

    function check_lemmaDivAnti(uint256 x, uint256 d, uint256 e) public pure {
        assertTrue(_fDivAnti(x, d, e));
    }

    function check_lemmaDivFloor(uint256 x, uint256 d) public pure {
        assertTrue(_fDivFloor(x, d));
    }

    function check_lemmaDivZero(uint256 x, uint256 d) public pure {
        assertTrue(_fDivZero(x, d));
    }

    function check_lemmaFloorSuperadd(uint256 x, uint256 y, uint256 s) public pure {
        assertTrue(_fSuperadd(x, y, s));
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

    /// _keep(f, e)'s terms for f < PIPS: x = (PIPS - f) * 1e12, y = WAD - min(e, WAD) (built
    /// branch-free), k = x*y / WAD. Facts: the checked mul's test and k <= WAD.
    function _keepF(uint256 f, uint256 e) internal pure returns (uint256 x, uint256 y, uint256 k) {
        assembly {
            x := mul(sub(1000000, f), 1000000000000)
            let w := 1000000000000000000
            y := sub(w, xor(e, and(xor(e, w), sub(0, gt(e, w)))))
        }
        uint256 t = _mul(x, y);
        vm.assume(_fExact(x, y));
        vm.assume(_fMulMonoR(x, y, WAD));
        vm.assume(_fDivMono(t, 1e36, WAD));
        k = t / WAD;
    }

    /// One row's edge factors against the base: k = ki*kb/WAD*up/PIPS (upper), kl =
    /// ki*kbLo/WAD (lower). Facts: the checked-mul tests, k and kl <= WAD, and both edges.
    function _rowF(uint256 p, uint256 pb, uint256 ki, uint256 kb, uint256 kbLo, uint256 up)
        internal pure returns (uint256 t2, uint256 k, uint256 kl)
    {
        uint256 t1 = _mul(ki, kb);
        vm.assume(_fExact(ki, kb));
        vm.assume(_fMulMonoR(ki, kb, WAD));
        vm.assume(_fDivMono(t1, 1e36, WAD));
        t2 = t1 / WAD;
        uint256 t3 = _mul(t2, up);
        vm.assume(_fExact(t2, up));
        vm.assume(_fMulMonoR(t2, up, PIPS));
        vm.assume(_fDivMono(t3, 1e24, PIPS));
        k = t3 / PIPS;
        uint256 l1 = _mul(ki, kbLo);
        vm.assume(_fExact(ki, kbLo));
        vm.assume(_fMulMonoR(ki, kbLo, WAD));
        vm.assume(_fDivMono(l1, 1e36, WAD));
        kl = l1 / WAD;
        _edgeF(p, k);
        _edgeF(pb, kl);
    }

    /// mulDiv(q, c, WAD) is q*c/WAD (L0), and q*c/WAD <= q when c <= WAD.
    function _edgeF(uint256 q, uint256 c) internal pure {
        vm.assume(_fFits(q, c));
        vm.assume(_fMulMonoR(q, c, WAD));
        vm.assume(_fDivMono(_mul(q, c), _mul(q, WAD), WAD));
        vm.assume(_fExact(q, WAD));
    }

    /// A smaller factor gives a smaller floor: (a*b)/d <= (a*c)/d (or (b*a)/d <= (c*a)/d).
    function _monoF(uint256 a, uint256 b, uint256 c, uint256 d, bool left) internal pure {
        if (left) {
            vm.assume(_fMulMonoL(a, b, c));
            vm.assume(_fDivMono(_mul(b, a), _mul(c, a), d));
        } else {
            vm.assume(_fMulMonoR(a, b, c));
            vm.assume(_fDivMono(_mul(a, b), _mul(a, c), d));
        }
    }

    function check_bandKeepsLiveBaseAndOnlyWidens(
        uint128 p0, uint128 p1, uint24 f0, uint24 f1, uint64 e0, uint64 e1, uint64 eo0, uint64 e1w
    ) public pure {
        vm.assume(p0 > 0 && f0 < PIPS && f1 < PIPS && eo0 >= e0 && e1w >= e1);
        {
            // The facts on the src's terms (THE FACTS above); row 0 is the base.
            (,, uint256 kb) = _keepF(f0, e0);
            (,, uint256 kbLo) = _keepF(f0, eo0);
            uint256 up = PIPS - f0;
            _rowF(p0, p0, kb, kb, kbLo, up);
            (uint256 x1, uint256 y1, uint256 ki) = _keepF(f1, e1);
            (, uint256 yw, uint256 kiw) = _keepF(f1, e1w);
            (uint256 t2, uint256 k, uint256 kl) = _rowF(p1, p0, ki, kb, kbLo, up);
            (uint256 t2w, uint256 kw, uint256 klw) = _rowF(p1, p0, kiw, kb, kbLo, up);
            _monoF(x1, yw, y1, WAD, false);       // kiw <= ki
            _monoF(kb, kiw, ki, WAD, true);       // t2w <= t2
            _monoF(up, t2w, t2, PIPS, true);      // kw <= k
            _monoF(p1, kw, k, WAD, false);        // the upper edge's left side falls
            _monoF(kbLo, kiw, ki, WAD, true);     // klw <= kl
            _monoF(p0, klw, kl, WAD, false);      // the lower edge's right side falls
        }
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
    function check_dustProbeV2FloorsToZero(uint112 rIn, uint112 rOut, uint64 m) public pure {
        vm.assume(rIn > 0 && rOut > 0);
        vm.assume(_fDivMono(1900, m, 100));           // m >= 1900 => m / 100 >= 19
        vm.assume(_fDivAnti(m, 1, 100));              // m / 100 <= m
        uint256 probe = m / 100 == 0 ? m : m / 100;   // mirrors the Solver's probe
        {
            // outV2(probe): a = probe*9970, n = a*rOut, d = rIn*1e4 + a, o = n/d.
            uint256 a = probe * 9970;
            uint256 n = _mul(a, rOut);
            uint256 r = uint256(rIn) * 10000;
            uint256 d = r + a;
            uint256 o = _div(n, d);
            vm.assume(_fExact(a, rOut));              // the checked mul; n/a == rOut
            vm.assume(_fDivAnti(n, a, d));            // o <= n/a == rOut
            vm.assume(_fDivFloor(n, d));              // o*d <= n
            vm.assume(_fMulMonoR(o, r, d));           // o*(rIn*1e4) <= o*d
            vm.assume(_fAssocR(o, rIn, 10000));       // o*(rIn*1e4) == (o*rIn)*1e4
            vm.assume(_fAssocL(probe, rOut, 9970));   // (probe*9970)*rOut == (probe*rOut)*9970
            vm.assume(_fMulMonoR(o, rIn, U112));      // o*rIn < 2^224
            vm.assume(_fMulMonoR(probe, rOut, U112)); // probe*rOut < 2^176
            vm.assume(_fExact(o, rIn));               // the check's own checked muls
            vm.assume(_fExact(probe, rOut));
            vm.assume(_fDivZero(uint256(rOut) * 9970, r + 9970));   // outV2(1) at price <= 1
        }
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
    // Mutant H4: src/BlazePhoenixSolver.sol:1034
    //     `share = BPC.mulDiv(amountIn, psis[i], sumPsi);` -> `BPC.mulDivUp(...)`.
    //     The lemma holds for floors only; the src mutant is killed by a Solver test,
    //     not by this mirror: test/SplitSharesAreFloors.t.sol (no leg under its floor
    //     share on equal venues; the legs' sum alone cannot see the rounding).
    function check_splitFloorsNeverOvershoot(uint128 a, uint64 w0, uint64 w1, uint64 w2) public pure {
        uint256 s = uint256(w0) + w1 + w2;
        vm.assume(s > 0);
        {
            uint256 w01 = uint256(w0) + w1;
            vm.assume(_fFits(a, w0));                 // L0: both mulDivs are a*w/s
            vm.assume(_fFits(a, w1));
            vm.assume(_fMulMonoR(a, w0, U64));        // a*w < 2^192: the sums below fit
            vm.assume(_fMulMonoR(a, w1, U64));
            vm.assume(_fSuperadd(_mul(a, w0), _mul(a, w1), s));   // floor sum <= floor of the sum
            vm.assume(_fDist(a, w0, w1));             // a*w0 + a*w1 == a*(w0 + w1)
            vm.assume(_fMulMonoR(a, w01, s));         // a*(w0 + w1) <= a*s
            vm.assume(_fDivMono(_mul(a, w01), _mul(a, s), s));
            vm.assume(_fExact(a, s));                 // a*s/s == a
        }
        uint256 alloc = BPC.mulDiv(a, w0, s) + BPC.mulDiv(a, w1, s);
        assertLe(alloc, a, "floors overshoot the order");
        assertEq(alloc + (a - alloc), a, "legs do not sum to the order");
    }
}
