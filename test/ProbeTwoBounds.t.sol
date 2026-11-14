// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// THE PROBE'S TWO ERROR BOUNDS (`BlazePhoenixCore.universalProbe`): `err` at the probe (the size
// that was quoted) and `errOrder` at the order's size. Spec, from the bound's derivation:
//   (i)   err is a function of the probe alone: the order never moves it;
//   (ii)  the order is clamped up to the probe, so errOrder >= err (err is clamped at WAD, errOrder
//         is not: the Solver packs err in 64 bits);
//   (iii) an order at or below the probe reads the probe's bound: min(errOrder, WAD) == err;
//   (iv)  an order whose input reaches the depth reads the whole bound, WAD, at equality too;
//   (v)   a quote with no output (rank 0) is the whole bound on both: (WAD, WAD);
//   (vi)  errOrder covers the REAL output at the order, rank * orderIn / amountIn rounded up:
//         (errOrder - rnd - 3 WAD / n) * depth * amountIn >= rank * orderIn * WAD.
// Reserves run from dust to uint112's ceiling. RED at bb4cdbb with each mutant "L1-124 Core:21.."
// applied (src/BlazePhoenixCore.sol:2104-2126, one per test, .github/scripts/mutants.py); GREEN at HEAD.

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixCore as BPC, QuoteCtx} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";

contract ProbeTwoBoundsTest is Test {
    uint256 constant WAD = 1e18;
    MockERC20 tA;
    MockERC20 tB;

    function setUp() public {
        tA = new MockERC20("A", "A");
        tB = new MockERC20("B", "B");
    }

    /// A pair holding x of the input token and y of the output, 30 bps, both 18 decimals.
    function _pair(uint256 x, uint256 y) internal returns (QuoteCtx memory c) {
        (address t0, address t1) = address(tA) < address(tB) ? (address(tA), address(tB)) : (address(tB), address(tA));
        MockV2Pair p = new MockV2Pair(t0, t1);
        (uint256 r0, uint256 r1) = address(tA) == t0 ? (x, y) : (y, x);
        p.setReserves(uint112(r0), uint112(r1));
        MockERC20(t0).mint(address(p), r0);
        MockERC20(t1).mint(address(p), r1);
        c.kind = BPC.KIND_V2;
        c.pool = address(p);
        c.zeroForOne = address(tA) == t0;
        c.fee = 30;
        c.tokenIn = address(tA);
        c.tokenOther = address(tB);
        c.decIn1 = 19;
        c.decOther1 = 19;
    }

    function _probe(QuoteCtx memory c, uint256 a, uint256 o)
        internal view returns (uint256 mass, uint256 rank, uint256 fee, uint256 err, uint256 errOrder)
    {
        return BPC.universalProbe(c, a, 0, true, o);
    }

    // (i) mutant "L1-124 Core:2112: err's input side is read at the order"
    function testFuzz_ErrAtTheProbeIgnoresTheOrder(uint256 x, uint256 y, uint256 a, uint256 o1, uint256 o2) public {
        x = bound(x, 10, type(uint112).max);
        y = bound(y, 1, type(uint112).max);
        a = bound(a, 1, x / 10);
        QuoteCtx memory c = _pair(x, y);
        (uint256 m1, uint256 r1, uint256 f1, uint256 e1, ) = _probe(c, a, a);
        uint256[5] memory os = [bound(o1, 0, 1 << 128), bound(o2, 0, 1 << 128), 0, a - 1, 1 << 128];
        for (uint256 k; k < 5; ++k) {
            (uint256 m2, uint256 r2, uint256 f2, uint256 e2, ) = _probe(c, a, os[k]);
            assertEq(e2, e1, "the probe's bound moved with the order");
            assertEq(m2, m1, "mass");
            assertEq(r2, r1, "rank");
            assertEq(f2, f1, "fee");
        }
    }

    // (ii) mutant "L1-124 Core:2124: the order's impact term rounds down"
    function testFuzz_ErrOrderIsNeverBelowErr(uint256 x, uint256 y, uint256 a, uint256 o) public {
        x = bound(x, 10, type(uint112).max);
        y = bound(y, 1, type(uint112).max);
        a = bound(a, 1, x / 10);
        QuoteCtx memory c = _pair(x, y);
        uint256[4] memory os = [bound(o, 0, 1 << 128), a, 0, a + 1];
        for (uint256 k; k < 4; ++k) {
            (, , , uint256 err, uint256 errOrder) = _probe(c, a, os[k]);
            assertLe(err, WAD, "err is packed in 64 bits: never past WAD");
            assertGe(errOrder, err, "the order's bound fell below the probe's");
        }
    }

    // (iii) mutant "L1-124 Core:2118: an order one wei under the probe escapes the clamp"
    function test_OrderOneWeiUnderTheProbeReadsTheProbesBound() public {
        // price 4, depth 1e18: one wei of the order's input is one unit of the bound
        QuoteCtx memory c = _pair(1e18, 4e18);
        uint256 a = 1e15;
        (, uint256 rank, , uint256 err, uint256 atProbe) = _probe(c, a, a);
        assertGt(rank, a, "the output side is the long one: the impact reads the input");
        assertLt(err, WAD, "control: a finite bound");
        assertEq(atProbe, err, "the order at the probe reads the probe's bound");
        (, , , , uint256 under) = _probe(c, a, a - 1);
        assertEq(under, err, "one wei under the probe still reads the probe's bound");
        (, , , , uint256 zero) = _probe(c, a, 0);
        assertEq(zero, err, "no order reads the probe's bound");
    }

    function testFuzz_OrderAtOrBelowTheProbeReadsTheProbesBound(uint256 x, uint256 y, uint256 a, uint256 o) public {
        x = bound(x, 20, type(uint112).max);
        y = bound(y, 1, type(uint112).max);
        a = bound(a, 2, x / 10);
        o = bound(o, 0, a);
        QuoteCtx memory c = _pair(x, y);
        uint256[4] memory os = [o, a - 1, a, 0];
        for (uint256 k; k < 4; ++k) {
            (, , , uint256 err, uint256 errOrder) = _probe(c, a, os[k]);
            assertEq(errOrder < WAD ? errOrder : WAD, err, "an order at or under the probe left the probe's bound");
        }
    }

    // (iv) mutant "L1-124 Core:2124: an order exactly at the depth is not the whole bound"
    function test_OrderAtTheDepthReadsWAD() public {
        QuoteCtx memory c = _pair(1e18, 4e18);   // price 4: the input side is the short one
        uint256 a = 1e15;
        (, uint256 depth, , ) = BPC.universalQuoteRank(c, a, 0, true);
        assertEq(depth, 1e18, "the pair's depth is its short side");
        (, , , , uint256 atDepth) = _probe(c, a, depth);
        assertEq(atDepth, WAD, "an order whose input equals the depth reads the whole bound");
        (, , , , uint256 past) = _probe(c, a, 1e30);
        assertEq(past, WAD, "an order past the depth reads the whole bound");
        (, , , , uint256 under) = _probe(c, a, depth - 1);
        assertGe(under, WAD, "one wei under the depth the impact term alone is a whole WAD");
        (, , , , uint256 atProbe) = _probe(c, a, a);
        assertLt(atProbe, WAD, "control: the order at the probe is a finite bound");
    }

    // (v) mutant "L1-124 Core:2104: rank 0 reads a zero bound"
    function test_RankZeroIsTheWholeBound() public {
        (, uint256 rank, , uint256 err, uint256 errOrder) = _probe(_pair(0, 0), 1e15, 1e15);
        assertEq(rank, 0, "an empty pair ranks nothing");
        assertEq(err, WAD, "no output: the probe's bound is whole");
        assertEq(errOrder, WAD, "no output: the order's bound is whole");
        (, rank, , err, errOrder) = _probe(_pair(1e18, 1e18), 1e15, 1e15);
        assertGt(rank, 0, "control: a funded pair ranks");
        assertLt(err, WAD, "control: a funded pair's bound is finite");
        assertLt(errOrder, WAD, "control: and so is the order's");
    }

    // mutant "L1-124 Core:2126: err is not clamped at WAD"
    function test_TheProbesBoundStopsAtWADTheOrdersDoesNot() public {
        // a = 3 wei on 1e18 / 1e18 at 30 bps: rank 2, n = 2, rnd = (3e18 + 6) / 2 + 1, so the
        // unclamped bound is rnd + 1.5e18 + 2 = 3e18 + 6: past WAD.
        (, uint256 rank, , uint256 err, uint256 errOrder) = _probe(_pair(1e18, 1e18), 3, 3);
        assertEq(rank, 2, "three wei buy two");
        assertEq(err, WAD, "the probe's bound stops at WAD");
        assertEq(errOrder, (3 * WAD + 6) / 2 + 1 + 3 * WAD / 2 + 2, "the order's bound is not clamped");
        for (uint256 a = 1; a <= 2; ++a) {
            (, , , err, ) = _probe(_pair(1e18, 1e18), a, a);
            assertEq(err, WAD, "one or two wei: the whole bound");
        }
    }

    /// (vi) on a pair whose depth is 1e15: one wei of output is 1e3 units of the bound, so the
    /// rounding of rank * orderIn / amountIn is visible.
    function _coversTheRealOutput(QuoteCtx memory c, uint256 a, uint256 o) internal view {
        (, uint256 depth, , ) = BPC.universalQuoteRank(c, a, 0, true);
        (, uint256 rank, uint256 fee, , uint256 errOrder) = _probe(c, a, o);
        if (rank == 0 || errOrder == WAD) return;   // the whole bound covers everything
        uint256 n = a * (1_000_000 - fee) / 1_000_000;
        uint256 base = (3 * WAD + 2 * a) / rank + 1 + 3 * WAD / n;
        assertGe(errOrder, base, "the order's bound lost its rounding terms");
        assertGe((errOrder - base) * depth * a, rank * o * WAD, "the order's bound misses the real output at the order");
    }

    // mutant "L1-124 Core:2122: the order's output rounds down"
    function test_TheOrdersBoundCoversTheRealOutputAtTheOrder() public {
        QuoteCtx memory c = _pair(1e18, 1e15);
        uint256 a = 1e12;
        (, uint256 rank, , , ) = _probe(c, a, a);
        assertGt((rank * (7 * a + 3)) % a, 0, "the order's output is not a whole wei");
        _coversTheRealOutput(c, a, 7 * a + 3);
        _coversTheRealOutput(c, a, a + 1);
    }

    function testFuzz_TheOrdersBoundCoversTheRealOutputAtTheOrder(uint256 x, uint256 y, uint256 a, uint256 o) public {
        x = bound(x, 1e18, 1e24);
        y = bound(y, 1e12, 1e15);
        a = bound(a, 1e9, x / 10);
        o = bound(o, a, x / 2);
        _coversTheRealOutput(_pair(x, y), a, o);
    }
}
