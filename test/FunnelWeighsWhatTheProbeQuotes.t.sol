// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// THE FUNNEL WEIGHS WHAT THE PROBE QUOTES (`Core.hopMass18`, read by `Solver._dropDust`).
// A row's mass in the dust rule is what the probe can make it pay, one question for both:
//   - a pair that reports no reserve of the token sold (a rebase to zero, then sync) is quoted
//     zero by the probe (`rIn == 0 -> 0` in every pair formula), so it weighs zero: before, its
//     out reserve stood in every other row's D and an honest pair beside it fell under the bar,
//     leaving the hop to a row that pays nothing;
//   - a singleton book whose slot0 is initialised DECLARES: its mass is at least 1, the least
//     nonzero mass, so a book whose declared side rounds to zero (liquidity 1) or is zero (an
//     empty current tick, which the probe quotes when its walk holds something) triggers the
//     walk of FUNNEL_STRETCHES (`_heldBooks`) instead of being dropped unread. An uninitialised
//     book weighs nothing. What the walk does not reach (liquidity only past the funnel's two
//     stretches, inside the probe's sixteen) stays outside the funnel by design: the book is
//     dropped unless alone on its pair (pinned below).
//
// Oracles: the V2 formula written here; `MockV4TickManager.specSwap` (the V4 swap loop written
// from the specification); the probe `universalQuoteRank` for the parity pin.
//
// Red before the fix (2934a93): the tests marked RED below.
// Mutants (.github/scripts/mutants.py, block «funnel: the probe's zero»):
//   the pair arm drops `rI != 0` -> `test_DustRule_ZeroQuotingPairWeighsNothing` red;
//   the book arm drops its floor of 1 -> `test_DustRule_BookWithLiquidityOneIsWalked` red;
//   the floor asks `liq4 != 0` instead of `sp4 != 0` ->
//     `test_DustRule_EmptyTickBookHoldingTheNextStretchIsWalkedAndKept` red.

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixQuoter} from "../src/BlazePhoenixQuoter.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, RoutePlan, QuoteCtx, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";
import {MockSolidlyPair} from "./mocks/MockSolidlyPair.sol";
import {MockV4TickManager} from "./mocks/MockV4TickManager.sol";
import {PathologicalERC20} from "./mocks/PathologicalERC20.sol";

contract FunnelWeighsWhatTheProbeQuotesTest is Test {
    uint24 internal constant FEE = 3000;
    int24 internal constant TS = 60;
    uint256 internal constant PAIR = 100_000e18;      // the honest pair's reserves, each side
    uint256 internal constant AMT = 100_000e18;       // an order that walks into a neighbour range
    uint256 internal constant GAMMA_PPM = 25;         // Solver.MIN_SPLIT_IMPROVEMENT_PPM

    BlazePhoenixHub internal hub;
    BlazePhoenixSolver internal solver;
    BlazePhoenixQuoter internal quoter;
    BlazePhoenixRouter internal router;
    MockV4TickManager internal mgr;
    MockERC20 internal t0;
    MockERC20 internal t1;
    address internal user = address(0xF0A1);

    function setUp() public {
        mgr = new MockV4TickManager();
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(mgr));
        solver = new BlazePhoenixSolver(address(hub), address(0));
        quoter = new BlazePhoenixQuoter(address(hub), address(solver));
        router = new BlazePhoenixRouter(address(hub), address(solver), address(this), address(0x7451), address(0x7452));
        hub.setRoles(address(router), address(solver), address(quoter));
        MockERC20 a = new MockERC20("A", "A");
        MockERC20 b = new MockERC20("B", "B");
        (t0, t1) = address(a) < address(b) ? (a, b) : (b, a);
        t0.mint(address(mgr), 1e30);
        t1.mint(address(mgr), 1e30);
        t0.mint(user, 1e27);
        vm.prank(user);
        t0.approve(address(router), type(uint256).max);
    }

    // ---- fixtures -------------------------------------------------------------------------

    /// A curated V2 pair holding `r0` of t0 and `r1` of t1, reserves equal to balances.
    function _pair(MockERC20 x, MockERC20 y, uint256 rx, uint256 ry) internal returns (MockV2Pair p) {
        p = new MockV2Pair(address(x), address(y));
        x.mint(address(p), rx);
        y.mint(address(p), ry);
        (uint256 r0, uint256 r1) = p.token0() == address(x) ? (rx, ry) : (ry, rx);
        p.setReserves(uint112(r0), uint112(r1));
        hub.seedPool(address(p), BPC.KIND_V2, 30, address(0), p.token0(), p.token1());
    }

    /// A hookless t0/t1 book priced at `tick`, `liqNow` on [lo, hi) around it and `liqDeep` on
    /// the range just under it, [lo - 5940, lo), into which a zeroForOne order walks on the
    /// book's second stretch.
    function _book(uint24 fee, int24 tick, int24 lo, int24 hi, uint128 liqNow, uint128 liqDeep)
        internal returns (bytes32 pid)
    {
        pid = BPC.computeV4PoolId(address(t0), address(t1), fee, TS, address(0));
        mgr.initialize(pid, mgr.sqrtAt(tick), tick, fee);
        if (liqNow != 0) mgr.addPosition(pid, lo, hi, TS, liqNow);
        if (liqDeep != 0) mgr.addPosition(pid, lo - 5940, lo, TS, liqDeep);
        hub.addV4(address(t0), address(t1), fee, TS, address(0));
    }

    function _legsAt(Route memory r, address p) internal pure returns (uint256 k) {
        for (uint256 x; x < r.hops.length; ++x)
            for (uint256 y; y < r.hops[x].legs.length; ++y)
                if (r.hops[x].legs[y].pool == p) ++k;
    }

    function _at(bytes32 pid) internal pure returns (address) { return address(uint160(uint256(pid))); }

    function _plan(uint256 amt) internal returns (Route memory plan, uint256 out) {
        (plan, out) = quoter.previewPlanExact(address(t0), address(t1), amt);
    }

    function _swap(Route memory plan, uint256 amt) internal returns (uint256) {
        vm.prank(user);
        return router.swapExactIn(plan, amt, 1, user, block.timestamp + 1);
    }

    /// x * 0.997 * y / (x' + x * 0.997): Uniswap V2 at 30 bps, written here, not read from the Core.
    function _v2Out(uint256 x, uint256 rIn, uint256 rOut) internal pure returns (uint256) {
        uint256 xf = x * 9970;
        return xf * rOut / (rIn * 10_000 + xf);
    }

    // ---- the pair arm -----------------------------------------------------------------------

    /// RED before the fix (the hop has no route). Pair A reports no reserve of the token sold and
    /// a vast out reserve: the probe quotes it zero. The honest pair B is under 25 ppm of A's out
    /// reserve, so while A weighed what it reports, B was dropped and the hop kept only a row that
    /// pays nothing. Measured by what the probe can make it pay, A weighs zero: B is kept and pays
    /// the V2 formula, from dust to the order that drains half of it.
    function test_DustRule_ZeroQuotingPairWeighsNothing() public {
        MockV2Pair a = _pair(t0, t1, PAIR, PAIR);
        // a rebase of t0 to zero, then sync: the pair reports (0, 1e30) and holds both
        if (a.token0() == address(t0)) a.setReserves(0, uint112(1e30));
        else a.setReserves(uint112(1e30), 0);
        t1.mint(address(a), 1e30);
        MockV2Pair b = _pair(t0, t1, PAIR, PAIR);
        assertLt(PAIR * 1e6, GAMMA_PPM * 1e30, "fixture: B is under the bar against what A reports");
        uint256[4] memory sizes = [uint256(1e6), 1e18, 1_000e18, PAIR];
        for (uint256 i; i < sizes.length; ++i) {
            (bool ok, bytes memory ret) = address(solver).call(
                abi.encodeCall(solver.findBestRoutePlan, (address(t0), address(t1), sizes[i])));
            assertTrue(ok, "the honest pair was dropped beside a pair the probe quotes zero: the hop has no route");
            RoutePlan memory plan = abi.decode(ret, (RoutePlan));
            assertEq(plan.best.hops.length, 1, "the honest pair was dropped beside a pair the probe quotes zero");
            assertEq(plan.best.hops[0].legs.length, 1, "one paying row, one leg");
            Leg memory leg = plan.best.hops[0].legs[0];
            assertEq(leg.pool, address(b), "the leg is not the honest pair");
            assertEq(leg.expectedOut, _v2Out(sizes[i], PAIR, PAIR), "the honest pair pays the V2 formula");
        }
        RoutePlan memory p = solver.findBestRoutePlan(address(t0), address(t1), 1_000e18);
        (, uint256 preview) = _plan(1_000e18);
        uint256 got = _swap(p.best, 1_000e18);
        assertEq(got, preview, "the swap delivers what the preview quotes for the honest pair");
    }

    /// Control, +1 wei: a pair reporting ONE unit of the token sold is quoted by the probe (the
    /// V2 formula pays almost all of its out reserve) and keeps its mass, the out reserve it holds.
    function test_Control_PairReportingOneUnitOfTheSoldTokenKeepsItsMass() public {
        MockV2Pair a = _pair(t0, t1, PAIR, PAIR);
        bool zfo = a.token0() == address(t0);
        if (zfo) a.setReserves(1, uint112(1e30));
        else a.setReserves(uint112(1e30), 1);
        t1.mint(address(a), 1e30);
        assertGt(_v2Out(1e18, 1, 1e30), 0, "fixture: the pair formula quotes the row");
        assertEq(BPC.hopMass18(address(a), BPC.KIND_V2, address(t0), address(t1), zfo, 18, address(mgr), bytes32(0)),
            1e30, "a pair reporting one unit of the token sold lost its mass");
    }

    // ---- the book arm -----------------------------------------------------------------------

    /// RED before the fix (the book is dropped unread). Liquidity 1 on the current range at
    /// tick -1: its declared side, 1 * sqrtP / 2^96 with sqrtP < 2^96, rounds to zero, so the
    /// book declared nothing and no walk was made. The range under it holds 1e24 of liquidity,
    /// which the probe quotes. The book now declares 1, is walked, keeps its seat and the plan
    /// pays more than the pair alone; the swap settles it.
    function test_DustRule_BookWithLiquidityOneIsWalked() public {
        _pair(t0, t1, PAIR, PAIR);
        (, uint256 pairOnly) = _plan(AMT);
        bytes32 pid = _book(FEE, -1, -60, 0, 1, 1_000_000e18);
        assertEq(BPC.outSide18(mgr.liquidity(pid), mgr.sqrtAt(-1), true, 18), 0,
            "fixture: the declared side rounds to zero");
        (Route memory plan, uint256 out) = _plan(AMT);
        assertGt(_legsAt(plan, _at(pid)), 0, "a book of liquidity 1 deep on its next stretch was dropped unread");
        assertGt(out, pairOnly, "the plan pays no more than the pair alone");
        assertGt(_swap(plan, AMT), pairOnly, "the seated book settles above the pair alone");
    }

    /// RED before the fix, on top of the commit that makes the probe quote such a book (the
    /// probe quoted it, the funnel dropped it). The current range [0, 60) is EMPTY, the range
    /// under it holds 1e30: the book now declares 1, is walked over its two stretches, holds
    /// 400,000 times the pair and keeps its seat; the plan pays more than the pair and settles.
    function test_DustRule_EmptyTickBookHoldingTheNextStretchIsWalkedAndKept() public {
        _pair(t0, t1, PAIR, PAIR);
        (, uint256 pairOnly) = _plan(AMT);
        bytes32 pid = _book(FEE, 1, 0, 60, 0, 1e30);
        assertEq(mgr.liquidity(pid), 0, "fixture: the current tick is empty");
        (Route memory plan, uint256 out) = _plan(AMT);
        assertGt(_legsAt(plan, _at(pid)), 0, "a book the probe quotes was dropped by the funnel");
        assertGt(out, pairOnly, "the plan pays no more than the pair alone");
        assertGt(_swap(plan, AMT), pairOnly, "the seated book settles above the pair alone");
    }

    /// Control (the funnel's horizon, FUNNEL_STRETCHES = 2, by design): an empty current tick
    /// whose liquidity starts on the fourth stretch (tick spacing 1, one bitmap word ahead) is
    /// quoted by the probe (sixteen stretches) but holds nothing over the funnel's two: beside a
    /// pair it is dropped; alone on its pair it is never dust, and it is routed.
    function test_Control_EmptyTickBook_LiquidityPastTheFunnelHorizon_IsDroppedUnlessAlone() public {
        bytes32 pid = BPC.computeV4PoolId(address(t0), address(t1), FEE, 1, address(0));
        mgr.initialize(pid, mgr.sqrtAt(0), 0, FEE);
        mgr.addPosition(pid, -366, -266, 1, 1e24);   // upper edge -(256 + 10): pays on stretch 4
        hub.addV4(address(t0), address(t1), FEE, 1, address(0));
        assertEq(BPC.v4Held(address(mgr), pid, 1, true, 2), 0, "fixture: nothing within the funnel's two stretches");
        assertGt(BPC.v4Held(address(mgr), pid, 1, true, 16), 0, "fixture: something within the probe's sixteen");

        (Route memory alone, uint256 aloneOut) = _plan(1e18);
        assertGt(_legsAt(alone, _at(pid)), 0, "a book alone on its pair was not routed");
        (, uint256 pays, , , ) = mgr.specSwap(pid, 1e18, FEE, 1, true);
        assertLe(aloneOut, pays, "the plan promised more than the book pays");

        MockV2Pair p = _pair(t0, t1, PAIR, PAIR);
        RoutePlan memory beside = solver.findBestRoutePlan(address(t0), address(t1), 1e18);
        assertEq(_legsAt(beside.best, _at(pid)), 0, "liquidity past the funnel's two stretches kept its seat");
        assertEq(beside.best.hops.length, 1, "the pair's route is one hop");
        assertEq(beside.best.hops[0].legs.length, 1, "the pair alone, one leg");
        assertEq(beside.best.hops[0].legs[0].pool, address(p), "the pair was not routed");
        assertEq(beside.best.hops[0].legs[0].expectedOut, _v2Out(1e18, PAIR, PAIR), "the pair alone pays the V2 formula");
    }

    /// Control: a book whose slot0 is not initialised declares nothing, at every liquidity the
    /// manager reports.
    function test_Control_UninitialisedBookWeighsNothing() public {
        bytes32 pid = BPC.computeV4PoolId(address(t0), address(t1), 500, TS, address(0));
        assertEq(BPC.hopMass18(address(0), BPC.KIND_V4, address(t0), address(t1), true, 18, address(mgr), pid), 0,
            "an uninitialised book weighs");
        mgr.setSlot(bytes32(uint256(keccak256(abi.encode(pid, uint256(6)))) + 3), bytes32(uint256(1e18)));
        assertEq(mgr.liquidity(pid), 1e18, "fixture: the manager reports liquidity");
        assertEq(BPC.hopMass18(address(0), BPC.KIND_V4, address(t0), address(t1), true, 18, address(mgr), pid), 0,
            "an uninitialised book reporting liquidity weighs");
    }

    /// RED before the fix. A book whose slot0 is initialised declares exactly 1, the least nonzero
    /// mass, when its declared side is zero: an empty current tick, then liquidity 1e18 at a price
    /// so low that the tokenOut side rounds to zero.
    function test_DustRule_AnInitialisedBookDeclaresTheLeastMass() public {
        bytes32 pid = BPC.computeV4PoolId(address(t0), address(t1), 500, TS, address(0));
        mgr.initialize(pid, mgr.sqrtAt(-887_000), -887_000, 500);
        assertEq(mgr.liquidity(pid), 0, "fixture: the current tick is empty");
        assertEq(BPC.hopMass18(address(0), BPC.KIND_V4, address(t0), address(t1), true, 18, address(mgr), pid), 1,
            "an initialised book whose current tick is empty does not declare");
        mgr.setSlot(bytes32(uint256(keccak256(abi.encode(pid, uint256(6)))) + 3), bytes32(uint256(1e18)));
        assertEq(mgr.liquidity(pid), 1e18, "fixture: the manager reports liquidity");
        assertEq(BPC.outSide18(1e18, mgr.sqrtAt(-887_000), true, 18), 0, "fixture: the declared side rounds to zero");
        assertEq(BPC.hopMass18(address(0), BPC.KIND_V4, address(t0), address(t1), true, 18, address(mgr), pid), 1,
            "an initialised book whose declared side rounds to zero does not declare");
    }

    // ---- the plan: two rows on the first hop, two hops ----------------------------------------

    /// tA -> tB -> tC, no direct pool. The first hop has two rows: an honest pair and a book whose
    /// current tick is empty and whose next stretch holds 1e24 of liquidity. The book is seated on
    /// the first hop, the route pays more than the pairs alone, and the swap delivers no less
    /// than the preview promised (to a thousandth) and more than the pairs alone.
    function test_Plan_ABookSittingInAGapIsNotLeftOutOfATwoHopRoute() public {
        MockERC20 c = new MockERC20("C", "C");
        hub.addBridge(address(t1));
        _pair(t0, t1, PAIR, PAIR);
        _pair(t1, c, 1_000_000e18, 1_000_000e18);
        uint256 order = 10_000e18;
        (, uint256 pairsOnly) = quoter.previewPlanExact(address(t0), address(c), order);
        bytes32 pid = _book(FEE, 1, 0, 60, 0, 1e24);
        (Route memory plan, uint256 out) = quoter.previewPlanExact(address(t0), address(c), order);
        assertEq(plan.hops.length, 2, "the route is not the two-hop one");
        assertGt(_legsAt(plan, _at(pid)), 0, "the book in the gap was left out of the first hop");
        assertGt(out, pairsOnly, "the route pays no more than the pairs alone");
        uint256 b1 = c.balanceOf(user);
        vm.prank(user);
        router.swapBestExactIn(address(t0), address(c), order, 1, user, block.timestamp + 1);
        uint256 got = c.balanceOf(user) - b1;
        assertGt(got, pairsOnly, "the route settled no more than the pairs alone");
        assertLe(out, got + got / 1000, "the preview promised more than the route delivered");
    }

    // ---- the parity pin ---------------------------------------------------------------------

    PathologicalERC20 internal fa;
    PathologicalERC20 internal fb;

    /// Row by row, the funnel never drops unread what the probe quotes: probe (1e18 of the token
    /// sold) > 0 => mass != 0; a pair the probe quotes zero weighs zero; an initialised book
    /// declares its virtual side on the current liquidity, and 1 when that rounds to zero, whatever
    /// the probe pays (a book of liquidity 3 at tick -1 declares 2 units and the probe pays 0:
    /// the declared side is not the probe's answer, and the walk settles it). Range: liquidity {0..3}, the sold reserve {0..2},
    /// a deep range {1..3} stretches ahead or none; vectors: a pair after a rebase, a dust V4
    /// book, a volatile Solidly pair; tokenOut at 18 or 6 decimals.
    function testFuzz_FunnelNeverDropsUnreadWhatTheProbeQuotes(
        uint8 liq, uint8 rI, uint8 gapStretches, uint8 shape, bool six
    ) public {
        liq = uint8(bound(liq, 0, 3));
        rI = uint8(bound(rI, 0, 2));
        gapStretches = uint8(bound(gapStretches, 0, 3));
        shape = uint8(bound(shape, 0, 2));
        fa = new PathologicalERC20("A", "A", 18);
        do { fb = new PathologicalERC20("B", "B", six ? 6 : 18); } while (address(fb) < address(fa));
        uint256 rO = 1_000_000 * 10 ** fb.decimals();
        QuoteCtx memory q;
        q.zeroForOne = true;
        q.tokenIn = address(fa);
        q.tokenOther = address(fb);
        q.v4Manager = address(mgr);
        q.hub = address(hub);
        q.decIn1 = 19;
        q.decOther1 = fb.decimals() + 1;
        bytes32 pid;
        if (shape == 0) {
            MockV2Pair p = new MockV2Pair(address(fa), address(fb));
            fa.mint(address(p), rI);
            fb.mint(address(p), rO);
            p.setReserves(uint112(rI), uint112(rO));
            (q.kind, q.pool, q.fee) = (BPC.KIND_V2, address(p), 30);
        } else if (shape == 1) {
            pid = BPC.computeV4PoolId(address(fa), address(fb), FEE, 1, address(0));
            mgr.initialize(pid, mgr.sqrtAt(-1), -1, FEE);
            if (liq != 0) mgr.addPosition(pid, -5, 5, 1, liq);
            // a deep range whose upper edge is `gapStretches - 1` bitmap words and ten ticks under -5
            if (gapStretches != 0) {
                int24 near = int24(int256(256 * uint256(gapStretches - 1) + 15));
                mgr.addPosition(pid, -near - 100, -near, 1, 1e24);
            }
            fb.mint(address(mgr), 1e30);
            (q.kind, q.pool, q.fee, q.tickSpacing) = (BPC.KIND_V4, _at(pid), FEE, 1);
        } else {
            MockSolidlyPair s = new MockSolidlyPair(address(fa), address(fb), false);
            fa.mint(address(s), rI);
            fb.mint(address(s), rO);
            s.setReserves(uint112(rI), uint112(rO));
            (q.kind, q.pool, q.fee) = (BPC.KIND_SOLIDLY, address(s), 30);
        }
        (uint256 probe, , , ) = BPC.universalQuoteRank(q, 1e18, 0, false);
        uint256 mass = BPC.hopMass18(q.pool, q.kind, address(fa), address(fb), true, fb.decimals(), address(mgr), pid);
        if (probe != 0) assertGt(mass, 0, "the probe quotes a row the funnel weighs zero");
        if (shape == 1) {
            uint256 side = BPC.outSide18(uint128(liq), mgr.sqrtAt(-1), true, fb.decimals());
            assertEq(mass, side == 0 ? 1 : side, "an initialised book does not declare its side, or the least mass");
        } else if (probe == 0) {
            assertEq(mass, 0, "a pair the probe quotes zero weighs on the others");
        }
    }
}
