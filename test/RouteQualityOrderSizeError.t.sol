// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// ROUTEQ (2026-11-13): THE BAND'S ERROR BOUND IS ASKED AT THE ORDER'S SIZE. `Core.universalProbe`
// formed a row's error bound `err` with its impact term m = min(a, o) at the PROBE (1% of the
// order), while the band (`BlazePhoenixMath._inBand`) decides the WHOLE order with it. A thin row
// far from the market read a small width by construction, could be the base, and then kept itself
// alone: USDC->DAI 10k on Base at block 49800000 went whole into one Pancake V3 venue 1631 ticks off
// the market, 47% impact, 6550 DAI out (run 43410379085). The bound now takes m at `orderIn`, the
// hop's amountIn; the rounding terms stay at the probe. Red before the fix: the matrix and the
// fuzz below (m at the probe reads a width the order does not have) and the Solver book (the far
// base keeps itself alone, one leg). Mutants: .github/scripts/mutants.py, "ROUTEQ".
//
// Matrix (range x vector x dimension):
//   order/probe 1x, 10x, 100x; decimals 6->18, 18->6, 18->18, 8->18; depth thin (the order
//   outgrows the short side) and deep (1e3 orders)            x  V2 pair  x  unit on `err`
//   orderIn 0, probe - 1, probe (the floor); orderIn at the short side and 1 wei under   x  unit
//   any book, any probe, any two orders                        x  fuzz: monotone, covers m
//   a far thin base against two market rows, 10k order         x  Solver, 1 hop, ERC20
//   the trace's book                                           x  fork (test/fork/RouteQualityProbe.t.sol)

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixCore as BPC, QuoteCtx, Route, Leg} from "../src/BlazePhoenixCore.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";

/// A bare token with the decimals it is built with.
contract RqoToken {
    uint8 public immutable decimals;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(uint8 d) { decimals = d; }
    function mint(address to, uint256 a) external { balanceOf[to] += a; }
    function approve(address s, uint256 a) external returns (bool) { allowance[msg.sender][s] = a; return true; }
    function transfer(address to, uint256 a) external returns (bool) {
        balanceOf[msg.sender] -= a; balanceOf[to] += a; return true;
    }
    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        allowance[f][msg.sender] -= a; balanceOf[f] -= a; balanceOf[to] += a; return true;
    }
}

contract RouteQualityOrderSizeErrorTest is Test {
    uint256 constant WAD = 1e18;

    /// A V2 pair holding x of tokenIn and y of tokenOut, and the probe context the Solver builds.
    function _book(uint8 dIn, uint8 dOut, uint256 x, uint256 y) internal returns (QuoteCtx memory c) {
        RqoToken tIn = new RqoToken(dIn);
        RqoToken tOut = new RqoToken(dOut);
        MockV2Pair p = new MockV2Pair(address(tIn), address(tOut));
        (uint256 r0, uint256 r1) = address(tIn) < address(tOut) ? (x, y) : (y, x);
        p.setReserves(uint112(r0), uint112(r1));
        tIn.mint(address(p), x);
        tOut.mint(address(p), y);
        c.kind = BPC.KIND_V2;
        // the venue's address, QuoteCtx's second field (word 0x20)
        assembly ("memory-safe") { mstore(add(c, 0x20), p) }
        c.zeroForOne = address(tIn) < address(tOut);
        c.fee = 30;
        c.tokenIn = address(tIn);
        c.tokenOther = address(tOut);
        c.decIn1 = dIn + 1;
        c.decOther1 = dOut + 1;
    }

    /// The bound at the probe `a` and at `order`, checked against the impact term at the order.
    function _check(uint8 dIn, uint8 dOut, uint256 x, uint256 y, uint256 a, uint256 order) internal {
        QuoteCtx memory c = _book(dIn, dOut, x, y);
        (, uint256 o, , uint256 eP) = BPC.universalProbe(c, a, 0, true, a);
        (, uint256 o2, , uint256 eO) = BPC.universalProbe(c, a, 0, true, order);
        assertGt(o, 0, "precondition: a live probe");
        assertEq(o2, o, "the order's size moves the bound, never the rank");
        uint256 x18 = BPC.to18(x, dIn);
        uint256 y18 = BPC.to18(y, dOut);
        uint256 dW = x18 < y18 ? x18 : y18;
        uint256 a18 = BPC.to18(order, dIn);
        uint256 o18 = BPC.to18(BPC.mulDivUp(o, order, a), dOut);
        uint256 m = a18 < o18 ? a18 : o18;
        if (m >= dW) assertEq(eO, WAD, "a row the order outgrows states no width");
        else assertGe(eO, BPC.mulDivUp(m, WAD, dW), "the bound covers the impact at the order's size");
        assertGe(eO, eP, "the order's bound is never narrower than the probe's");
        if (order == a) assertEq(eO, eP, "at order == probe the bound is the probe's");
    }

    function test_ErrIsAskedAtTheOrdersSize_matrix() public {
        uint8[4] memory dIn = [uint8(6), 18, 18, 8];
        uint8[4] memory dOut = [uint8(18), 6, 18, 18];
        uint256[3] memory ratio = [uint256(1), 10, 100];
        for (uint256 d; d < 4; ++d) {
            uint256 order = 10_000 * 10 ** dIn[d];
            for (uint256 r; r < 3; ++r) {
                uint256 a = order / ratio[r];
                // thin and far: half the order on the in side, three times its value on the out side
                _check(dIn[d], dOut[d], order / 2, 15_000 * 10 ** dOut[d], a, order);
                // deep and at market: a thousand orders a side
                _check(dIn[d], dOut[d], 1_000 * order, 10_000_000 * 10 ** dOut[d], a, order);
            }
        }
    }

    /// The floor: an order at or under the probe reads as the probe (0, probe - 1, probe).
    function test_ErrOrderUnderTheProbeReadsAsTheProbe() public {
        QuoteCtx memory c = _book(18, 18, 1e25, 1e25);
        uint256 a = 1e20;
        (, , , uint256 eP) = BPC.universalProbe(c, a, 0, true, a);
        (, , , uint256 e0) = BPC.universalProbe(c, a, 0, true, 0);
        (, , , uint256 e1) = BPC.universalProbe(c, a, 0, true, a - 1);
        (, , , uint256 e2) = BPC.universalProbe(c, a, 0, true, a + 1);
        (, , , uint256 e3) = BPC.universalProbe(c, a, 0, true, a / 2);
        assertEq(e3, eP, "orderIn at half the probe reads as the probe");
        assertEq(e0, eP, "orderIn 0 reads as the probe");
        assertEq(e1, eP, "orderIn one wei under the probe reads as the probe");
        assertGe(e2, eP, "one wei over the probe never narrows");
    }

    /// The edge m == depthWad: an order equal to the short side states no width; one wei under, bounded.
    function test_ErrAtTheShortSide_plusMinusOneWei() public {
        uint256 x = 1e22;
        _check(18, 18, x, 3e22, 1e20, x);
        _check(18, 18, x, 3e22, 1e20, x - 1);
        _check(18, 18, x, 3e22, 1e20, x + 1);
    }

    function testFuzz_ErrGrowsWithTheOrderAndCoversIt(uint256 x, uint256 y, uint256 a, uint256 o1, uint256 o2) public {
        x = bound(x, 1e15, 1e30);
        y = bound(y, 1e15, 1e30);
        a = bound(a, 1e6, x / 10);
        o1 = bound(o1, a, 1e30);
        o2 = bound(o2, o1, 1e30);
        QuoteCtx memory c = _book(18, 18, x, y);
        (, uint256 o, , uint256 eP) = BPC.universalProbe(c, a, 0, true, a);
        if (o == 0) return;   // a dead probe has no bound to grow
        (, , , uint256 e1) = BPC.universalProbe(c, a, 0, true, o1);
        (, , , uint256 e2) = BPC.universalProbe(c, a, 0, true, o2);
        assertLe(eP, e1, "probe <= order");
        assertLe(e1, e2, "monotone in the order");
        _check(18, 18, x, y, a, o2);
    }

    /// THE SOLVER (1 hop). A far thin pair P (3,000 USDC / 9,000 DAI: spot 3 DAI per USDC) holds
    /// most of the tokenOut, so its vote makes it the base; two market pairs (4,000 / 4,000 and
    /// 3,000 / 3,000) hold the rest. Before the fix P's width at the probe (100 USDC) was ~3.3%
    /// and the band around it held P alone: 10,000 USDC went into P, 6,918 DAI out. At the
    /// order's size P states no width and the band keeps the market rows.
    function test_FarThinBaseNoLongerExcludesTheDeepRows() public {
        BlazePhoenixHub hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        BlazePhoenixSolver solver = new BlazePhoenixSolver(address(hub), address(0));
        RqoToken usdc = new RqoToken(6);
        RqoToken dai = new RqoToken(18);
        _pair(hub, usdc, dai, 3_000e6, 9_000e18);
        address a = _pair(hub, usdc, dai, 4_000e6, 4_000e18);
        _pair(hub, usdc, dai, 3_000e6, 3_000e18);
        uint256 amt = 10_000e6;
        uint256 pAlone = amt * 997 * 9_000e18 / (3_000e6 * 1000 + amt * 997);
        Route memory best = solver.findBestRoutePlan(address(usdc), address(dai), amt).best;
        assertEq(best.hops.length, 1, "one hop: two tokens");
        assertGt(best.hops[0].legs.length, 1, "the far thin base kept itself alone");
        bool sawA;
        for (uint256 i; i < best.hops[0].legs.length; ++i) {
            if (_venue(best.hops[0].legs[i]) == a) sawA = true;
        }
        assertTrue(sawA, "the deepest market row is in the hop");
        assertGt(best.totalOut, pAlone, "the route pays more than the far row alone");
    }

    /// A leg's venue, Leg's first field.
    function _venue(Leg memory l) internal pure returns (address v) {
        assembly ("memory-safe") { v := mload(l) }
    }

    function _pair(BlazePhoenixHub hub, RqoToken tIn, RqoToken tOut, uint256 x, uint256 y) internal returns (address) {
        MockV2Pair q = new MockV2Pair(address(tIn), address(tOut));
        (uint256 r0, uint256 r1) = address(tIn) < address(tOut) ? (x, y) : (y, x);
        q.setReserves(uint112(r0), uint112(r1));
        tIn.mint(address(q), x);
        tOut.mint(address(q), y);
        hub.seedPool(address(q), BPC.KIND_V2, 30, address(0), address(tIn), address(tOut));
        return address(q);
    }
}
