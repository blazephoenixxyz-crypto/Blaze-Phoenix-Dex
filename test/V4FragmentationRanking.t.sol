// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// S2 (V4 fragmentation, reported by Seavia Resources): the sixteen-stretch V4 walk is a safe
// PROMISE and an unsafe RANKING. These tests pin each ranking consumer the fix covers, plus the
// ceiling the deep walk settles on. Companion of test/V4FragmentationReach.t.sol (the gate).
//
//   Q2f  a mirror pool (real liquidity a few ticks deep, dust on every tick, nothing beyond)
//        must not win on its ceiling - the reason the fix resolves the walk instead of
//        comparing by `hi`. Green on the unfixed tree too: it guards the fix, not the bug.
//   Q2g  `_considera`: a fragmented direct route must still beat a worse bridge route.
//   Q2h  the held vote in `_depthWeightedMedian`: a fragmented honest pool must not be voted
//        out of the band by a thin pool priced above it.
//   Q2i  the split gate: a quote still truncated after the deep walk keeps the split instead
//        of collapsing onto a rival (the `hMax` ceiling check).
//   Q2j  the probe: dust inside the probe's reach must not price the honest pool out of the band.
//   Q2k  `_considera` on a bridge route's FIRST hop: dust there must not cost the route the order
//        (stage B is re-quoted on stage A's rank for the judgement). Red on f87364e.
//   Q2l  ...and that re-quote replaces the promise in the judgement, never adds to it: a better
//        direct route keeps the order. Green on f87364e too: it guards the fix.
//   Q2m/Q2n  the same on a two-bridge route, dust on its first stage and on its middle one (the
//        rank is carried stage by stage). Red on f87364e.
//   ceiling  `v4WalkRank` stops at sixteen only when the rest cannot carry the quote past the
//        bar, and never below the truth.
//   B1   the ceiling never saturates under the walk's own figure: on a book whose output
//        passes 2^128 - 1, a ceiling capped there fell under `rank` (and under `lo`), and the
//        Solver's `hi - lo` reverted the whole plan.

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";
import {MockV2Factory} from "./mocks/MockV2Factory.sol";
import {MockV4TickManager} from "./mocks/MockV4TickManager.sol";

contract V4FragmentationRankingTest is Test {
    MockV4TickManager mgr;
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    BlazePhoenixRouter router;
    MockV2Factory fac;
    address t0;
    address t1;
    address user     = address(0xBEEF);
    address attacker = address(0xBAD);

    uint8   constant MODE_ASK = 0;
    uint24  constant FEE = 100;       // 0.01% tier, tickSpacing 1
    int24   constant TS  = 1;
    uint128 constant L   = 1e24;
    uint256 constant ORDER = 1e22;

    function setUp() public {
        mgr = new MockV4TickManager();
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(mgr));
        solver = new BlazePhoenixSolver(address(hub), address(0));
        router = new BlazePhoenixRouter(address(hub), address(solver), address(this), address(0xFEE1), address(0xFEE2));
        hub.setRoles(address(router), address(solver), address(0xC0FFEE));
        (t0, t1) = _pair();
        MockERC20(t0).mint(address(mgr), 1e30);
        MockERC20(t1).mint(address(mgr), 1e30);
        MockERC20(t0).mint(user, 10 * ORDER);
        vm.prank(user);
        MockERC20(t0).approve(address(router), type(uint256).max);
        fac = new MockV2Factory();
        hub.addFactory(address(fac), BPC.KIND_V2, MODE_ASK, bytes32(0), new uint24[](0), new int24[](0));
    }

    function _pair() internal returns (address x, address y) {
        address a = address(new MockERC20("A", "A"));
        address b = address(new MockERC20("B", "B"));
        (x, y) = a < b ? (a, b) : (b, a);
    }

    function _pid(uint24 fee) internal view returns (bytes32) { return BPC.computeV4PoolId(t0, t1, fee, TS, address(0)); }

    function _honestV4() internal {
        mgr.initialize(_pid(FEE), BPC.sqrtPriceAtTick(0), 0, FEE);
        mgr.addPosition(_pid(FEE), -20_000, 20_000, TS, L);
        hub.addV4(t0, t1, FEE, TS, address(0));
    }

    /// A V2 pair found by discovery (a factory pair, not a curated row).
    function _v2(address a, address b, uint112 ra, uint112 rb) internal {
        MockV2Pair p = new MockV2Pair(a, b);
        fac.setPair(a, b, address(p));
        (uint112 r0, uint112 r1) = a < b ? (ra, rb) : (rb, ra);
        MockERC20(p.token0()).mint(address(p), r0);
        MockERC20(p.token1()).mint(address(p), r1);
        p.setReserves(r0, r1);
    }

    function _fragment(bytes32 pid, int24 lo, int24 hi) internal {
        vm.startPrank(attacker);
        for (int24 t = lo; t < hi; ++t) mgr.addPosition(pid, t, t + 1, TS, 1);
        vm.stopPrank();
    }

    function _swap() internal returns (uint256 got) {
        uint256 b1 = MockERC20(t1).balanceOf(user);
        vm.prank(user);
        router.swapBestExactIn(t0, t1, ORDER, 1, user, block.timestamp + 1);
        got = MockERC20(t1).balanceOf(user) - b1;
    }

    function _report(uint256 clean, uint256 dirty) internal {
        emit log_named_uint("delivered, clean     ", clean);
        emit log_named_uint("delivered, attacked  ", dirty);
        emit log_named_uint("user loss (wei)      ", clean > dirty ? clean - dirty : 0);
    }

    /// Q2f. The attacker's own V4 pool: real liquidity over ticks [-20, 1), one-wei dust on
    /// every tick inside it, and nothing beyond. Its sixteen-stretch ceiling looks better than
    /// the honest V2 pool, but it pays only what the twenty ticks hold. Registered by the
    /// operator here, the worst case for the solver: the mirror is in every candidate set.
    function test_Q2f_MirrorPoolDoesNotWinOnItsCeiling() public {
        uint24 mf = 500;
        uint256 snap = vm.snapshotState();
        _v2(t0, t1, 1e23, 1e23);
        uint256 clean = _swap();
        vm.revertToState(snap);
        _v2(t0, t1, 1e23, 1e23);
        mgr.initialize(_pid(mf), BPC.sqrtPriceAtTick(0), 0, mf);
        mgr.addPosition(_pid(mf), -20, 1, TS, L);
        _fragment(_pid(mf), -20, 0);
        hub.addV4(t0, t1, mf, TS, address(0));
        uint256 dirty = _swap();
        _report(clean, dirty);
        assertGt(clean, 9e21, "control: the V2 pool fills the order");
        assertGe(dirty + 1e18, clean, "the mirror pool took the order on its ceiling");
    }

    /// Q2g. `_considera`: the only direct candidate is the fragmented honest pool, and a bridge
    /// route through two V2 pairs delivers about 7.1e21. The direct route pays ~9.9e21 and its
    /// sixteen-stretch promise is under 1e21, so a judgement by `totalOut` alone picks the bridge.
    function test_Q2g_FragmentedDirectRouteBeatsAWorseBridgeRoute() public {
        address bridge = address(new MockERC20("BR", "BR"));
        hub.addBridge(bridge);
        uint256 snap = vm.snapshotState();
        _honestV4();
        _v2(t0, bridge, 5e22, 5e22);
        _v2(bridge, t1, 5e22, 5e22);
        uint256 clean = _swap();
        vm.revertToState(snap);
        _honestV4();
        _v2(t0, bridge, 5e22, 5e22);
        _v2(bridge, t1, 5e22, 5e22);
        _fragment(_pid(FEE), -20, 0);
        uint256 dirty = _swap();
        _report(clean, dirty);
        assertGt(clean, 9e21, "control: the direct V4 route fills near par");
        assertLe(clean > dirty ? clean - dirty : 0, 1e18, "fragmentation moved the order to the bridge route");
    }

    /// An honest V4 book between `a` and `b` (either orientation) and its pool id.
    function _honestV4Between(address a, address b) internal returns (bytes32 pid) {
        (address c0, address c1) = a < b ? (a, b) : (b, a);
        pid = BPC.computeV4PoolId(c0, c1, FEE, TS, address(0));
        mgr.initialize(pid, BPC.sqrtPriceAtTick(0), 0, FEE);
        mgr.addPosition(pid, -20_000, 20_000, TS, L);
        hub.addV4(c0, c1, FEE, TS, address(0));
    }

    /// The dust an outsider puts on the twenty ticks an `a -> b` order walks first.
    function _fragmentPath(bytes32 pid, address a, address b) internal {
        if (a < b) _fragment(pid, -20, 0);
        else       _fragment(pid, 0, 20);
    }

    /// The Q2k book: an honest V4 book on t0 -> bridge, a deep V2 pair on bridge -> t1, and a
    /// shallower V2 pair on t0 -> t1 as the only direct candidate.
    function _bridgeBook(address bridge) internal returns (bytes32 pid) {
        pid = _honestV4Between(t0, bridge);
        _v2(bridge, t1, 1e24, 1e24);
        _v2(t0, t1, 5e22, 5e22);
    }

    /// Q2k. `_considera` on the FIRST hop of a bridge route. The bridge route runs through an
    /// honest V4 book (t0 -> bridge) and a deep V2 pair (bridge -> t1) and delivers ~9.8e21; the
    /// only direct candidate is a V2 pair that delivers ~8.3e21. Dust on the first hop cuts its
    /// sixteen-stretch promise under 1e21, and the second hop is quoted on that promise, so a
    /// judgement by the promise alone hands the order to the worse direct pair.
    function test_Q2k_FragmentedBridgeFirstHopKeepsTheBridgeRoute() public {
        address bridge = address(new MockERC20("BR", "BR"));
        MockERC20(bridge).mint(address(mgr), 1e30);
        hub.addBridge(bridge);
        uint256 snap = vm.snapshotState();
        _bridgeBook(bridge);
        uint256 clean = _swap();
        vm.revertToState(snap);
        bytes32 pid = _bridgeBook(bridge);
        _fragmentPath(pid, t0, bridge);
        (uint256 lo, uint256 rank, ) = BPC.v4WalkRank(address(mgr), pid, ORDER, FEE, TS, t0 < bridge, 0);
        uint256 dirty = _swap();
        _report(clean, dirty);
        assertLt(lo * 10, ORDER, "precondition: the first hop's promise is cut more than tenfold");
        assertGt(rank, ORDER * 98 / 100, "precondition: the deep walk reads the book");
        assertGt(clean, 9.5e21, "control: the bridge route fills near par");
        assertLe(clean > dirty ? clean - dirty : 0, 1e18, "fragmentation of the first hop moved the order off the bridge route");
    }

    /// Q2l. The other side of Q2k: the first hop's rank must not be counted on top of the promise
    /// it re-quotes. The direct V2 pair here (priced 2% above par) pays ~1.007e22 and beats the
    /// bridge route (~9.8e21) on a clean book and on a fragmented one; a judgement that added the
    /// re-quoted stage B to the promise instead of replacing it would rank the bridge route at
    /// ~1.05e22 and hand it the order. Green on f87364e too: it guards the fix, not the bug.
    function test_Q2l_FragmentedBridgeFirstHopDoesNotOutrankABetterDirectRoute() public {
        address bridge = address(new MockERC20("BR", "BR"));
        MockERC20(bridge).mint(address(mgr), 1e30);
        hub.addBridge(bridge);
        uint256 snap = vm.snapshotState();
        _honestV4Between(t0, bridge);
        _v2(bridge, t1, 1e24, 1e24);
        _v2(t0, t1, 1e24, 1.02e24);
        uint256 clean = _swap();
        vm.revertToState(snap);
        bytes32 pid = _honestV4Between(t0, bridge);
        _v2(bridge, t1, 1e24, 1e24);
        _v2(t0, t1, 1e24, 1.02e24);
        _fragmentPath(pid, t0, bridge);
        uint256 dirty = _swap();
        _report(clean, dirty);
        assertGt(clean, 1e22, "control: the direct pair fills above par");
        assertLe(clean > dirty ? clean - dirty : 0, 1e18, "the bridge route out-ranked a better direct route");
    }

    /// Q2k regression, one bridge: on a clean book the plan and the fill are what they were
    /// before the first hop's rank entered the judgement. Pinned values read on f87364e.
    function test_Q2k_CleanBridgeRouteUnchanged() public {
        address bridge = address(new MockERC20("BR", "BR"));
        MockERC20(bridge).mint(address(mgr), 1e30);
        hub.addBridge(bridge);
        _bridgeBook(bridge);
        uint256 promised = solver.findBestRoutePlan(t0, t1, ORDER).best.totalOut;
        uint256 got = _swap();
        assertEq(promised, 9773838954436299115942, "the clean bridge route's promise moved");
        assertEq(got, 9746738941922775479386, "the clean bridge route's fill moved");
    }

    /// Q2k regression, two bridges: t0 -> b1 on an honest V4 book, b1 -> b2 and b2 -> t1 on V2
    /// pairs, no shorter route. Pinned values read on f87364e.
    function test_Q2k_CleanTwoBridgeRouteUnchanged() public {
        address b1 = address(new MockERC20("B1", "B1"));
        address b2 = address(new MockERC20("B2", "B2"));
        MockERC20(b1).mint(address(mgr), 1e30);
        hub.addBridge(b1);
        hub.addBridge(b2);
        _honestV4Between(t0, b1);
        _v2(b1, b2, 1e24, 1e24);
        _v2(b2, t1, 1e24, 1e24);
        uint256 promised = solver.findBestRoutePlan(t0, t1, ORDER).best.totalOut;
        uint256 got = _swap();
        assertEq(promised, 9650478184622023178868, "the clean two-bridge route's promise moved");
        assertEq(got, 9623977733739036085623, "the clean two-bridge route's fill moved");
    }

    /// The Q2m/Q2n book: t0 -> b1 -> b2 -> t1, with the V4 book on stage `v4Stage` (0 or 1) and
    /// deep V2 pairs on the other two, beside a shallower V2 pair on t0 -> t1 (~8.3e21).
    function _twoBridgeBook(address b1, address b2, uint256 v4Stage) internal returns (bytes32 pid) {
        if (v4Stage == 0) { pid = _honestV4Between(t0, b1); _v2(b1, b2, 1e24, 1e24); }
        else              { _v2(t0, b1, 1e24, 1e24); pid = _honestV4Between(b1, b2); }
        _v2(b2, t1, 1e24, 1e24);
        _v2(t0, t1, 5e22, 5e22);
    }

    function _twoBridgeAttack(uint256 v4Stage) internal {
        address b1 = address(new MockERC20("B1", "B1"));
        address b2 = address(new MockERC20("B2", "B2"));
        MockERC20(b1).mint(address(mgr), 1e30);
        MockERC20(b2).mint(address(mgr), 1e30);
        hub.addBridge(b1);
        hub.addBridge(b2);
        uint256 snap = vm.snapshotState();
        _twoBridgeBook(b1, b2, v4Stage);
        uint256 clean = _swap();
        vm.revertToState(snap);
        bytes32 pid = _twoBridgeBook(b1, b2, v4Stage);
        (address a, address b) = v4Stage == 0 ? (t0, b1) : (b1, b2);
        _fragmentPath(pid, a, b);
        uint256 dirty = _swap();
        _report(clean, dirty);
        assertGt(clean, 9.5e21, "control: the two-bridge route fills near par");
        assertLe(clean > dirty ? clean - dirty : 0, 1e18, "fragmentation moved the order off the two-bridge route");
    }

    /// Q2m. Q2k on a two-bridge route: dust on its FIRST stage (t0 -> b1).
    function test_Q2m_FragmentedTwoBridgeFirstStageKeepsTheRoute() public { _twoBridgeAttack(0); }

    /// Q2n. Q2k on a two-bridge route: dust on its MIDDLE stage (b1 -> b2), so the rank has to
    /// be carried into the last stage from a stage that was itself quoted on a promise.
    function test_Q2n_FragmentedTwoBridgeMiddleStageKeepsTheRoute() public { _twoBridgeAttack(1); }

    /// Q2h. The held vote: a thin V2 pair priced ~5.6% above the honest pool at the probe. Clean,
    /// the honest pool's depth sets the band and the thin pair falls out of it. Fragmented, the
    /// sixteen-stretch held cuts the honest vote ~1000x, the thin pair sets the band, and the
    /// honest pool is filtered out before any leg is quoted.
    function test_Q2h_FragmentedHeldVoteDoesNotDropTheHonestPool() public {
        uint256 snap = vm.snapshotState();
        _honestV4();
        _v2(t0, t1, 1e22, 1.07e22);
        uint256 clean = _swap();
        vm.revertToState(snap);
        _honestV4();
        _v2(t0, t1, 1e22, 1.07e22);
        _fragment(_pid(FEE), -20, 0);
        uint256 dirty = _swap();
        _report(clean, dirty);
        assertGt(clean, 9e21, "control: the honest pool fills near par");
        assertLe(clean > dirty ? clean - dirty : 0, 1e18, "the held vote dropped the honest pool from the band");
    }

    /// Q2i. Past the deep walk. A shallower honest book (L = 1e23, so the order spans ~2,000
    /// ticks) with dust on 300 ticks that start just past the probe's reach (~20 ticks), so the
    /// pool's probe rate is exact and it stays in the band. The order is still unspent when the
    /// deep walk ends, so the honest pool's rank is only a lower bound and its ceiling is far
    /// above the rival's quote. The split gate must keep the split (the honest pool kept by
    /// weight) rather than collapse onto the rival on a figure the dust wrote.
    function test_Q2i_TruncatedPastTheDeepWalkKeepsTheSplit() public {
        uint256 snap = vm.snapshotState();
        _v2(t0, t1, 2e22, 2e22);
        uint256 rivalOnly = _swap();
        vm.revertToState(snap);
        mgr.initialize(_pid(FEE), BPC.sqrtPriceAtTick(0), 0, FEE);
        mgr.addPosition(_pid(FEE), -20_000, 20_000, TS, 1e23);
        hub.addV4(t0, t1, FEE, TS, address(0));
        _v2(t0, t1, 2e22, 2e22);
        _fragment(_pid(FEE), -330, -30);
        (uint256 lo, uint256 rank, uint256 hi) = BPC.v4WalkRank(address(mgr), _pid(FEE), ORDER, FEE, TS, true, 0);
        uint256 dirty = _swap();
        emit log_named_uint("rival alone          ", rivalOnly);
        emit log_named_uint("delivered, attacked  ", dirty);
        emit log_named_uint("deep rank / ceiling  ", rank);
        assertLt(lo * 10, rivalOnly, "precondition: the promise is far under the rival");
        assertLt(rank, rivalOnly, "precondition: the deep walk is still truncated under the rival");
        assertGt(hi, rivalOnly, "precondition: the ceiling stays above the rival");
        assertGt(dirty, rivalOnly + rivalOnly / 10, "the gate collapsed onto the rival on a truncated rank");
    }

    /// Q2j. The probe. The Q2i book with the dust starting at the current tick, inside the
    /// probe's reach: the probe (a hundredth of the order) crosses more than sixteen stretches,
    /// so a probe rate read on the sixteen-stretch figure prices the honest pool ~25% under the
    /// rival and the band filter drops it before any leg is quoted.
    function test_Q2j_FragmentedProbeKeepsTheHonestPoolInTheBand() public {
        uint256 snap = vm.snapshotState();
        _v2(t0, t1, 2e22, 2e22);
        uint256 rivalOnly = _swap();
        vm.revertToState(snap);
        mgr.initialize(_pid(FEE), BPC.sqrtPriceAtTick(0), 0, FEE);
        mgr.addPosition(_pid(FEE), -20_000, 20_000, TS, 1e23);
        hub.addV4(t0, t1, FEE, TS, address(0));
        _v2(t0, t1, 2e22, 2e22);
        _fragment(_pid(FEE), -300, 0);
        (uint256 lo, , ) = BPC.v4WalkRank(address(mgr), _pid(FEE), ORDER / 100, FEE, TS, true, 0);
        uint256 dirty = _swap();
        emit log_named_uint("rival alone          ", rivalOnly);
        emit log_named_uint("delivered, attacked  ", dirty);
        assertLt(lo * 100, (ORDER / 100) * 90, "precondition: the probe's promise is cut more than 10%");
        assertGt(dirty, rivalOnly + rivalOnly / 10, "the probe dropped the honest pool on a cut rate");
    }

    /// The ceiling. Fee 5% so the fee term is far wider than the rest's own slippage (~0.9%):
    /// a bar 3% of the rest above the truth is out of reach WITH the fee and within reach
    /// without it, so it pins the `(1 - fee)` factor; a bar one wei below the truth must walk on.
    function test_Ceiling_SettlesOnlyWhatTheRestCannotCarry() public {
        uint24 f = 50_000;
        bytes32 pid = _pid(f);
        mgr.initialize(pid, BPC.sqrtPriceAtTick(0), 0, f);
        mgr.addPosition(pid, -20_000, 20_000, TS, L);
        _fragment(pid, -20, 0);
        (uint256 lo, uint256 truth, uint256 hi) = BPC.v4WalkRank(address(mgr), pid, ORDER, f, TS, true, 0);
        (, uint256 spec, , , ) = mgr.specSwap(pid, ORDER, f, TS, true);
        assertEq(lo, BPC.v4WalkOut(address(mgr), pid, ORDER, f, TS, true), "lo is the promise");
        assertLt(lo * 5, truth, "precondition: sixteen stretches are truncated");
        assertApproxEqAbs(truth, spec, 64, "the deep walk is the pool's own swap");
        assertEq(hi, truth, "a finished walk is its own ceiling");

        (, uint256 r1, ) = BPC.v4WalkRank(address(mgr), pid, ORDER, f, TS, true, truth - 1);
        assertEq(r1, truth, "a rest that can carry the quote past the bar is walked");

        uint256 bar = truth + (truth - lo) * 3 / 100;
        (uint256 lo2, uint256 r2, uint256 h2) = BPC.v4WalkRank(address(mgr), pid, ORDER, f, TS, true, bar);
        assertEq(lo2, lo, "same promise");
        assertEq(r2, lo, "a rest that cannot reach the bar is not walked");
        assertLe(h2, bar, "the ceiling it settled on is under the bar");
        assertGe(h2, truth, "and still over the truth");
    }

    /// Soundness of the sixteen-stretch ceiling over sizes, fees and dust: it never settles a
    /// quote below what the pool pays.
    function testFuzz_Ceiling_NeverBelowTheTruth(uint256 amt, uint24 f, uint8 dust, uint256 b) public {
        amt = bound(amt, 1e18, 5e22);
        f = uint24(bound(f, 0, 200_000));
        dust = uint8(bound(dust, 0, 60));
        bytes32 pid = _pid(f);
        mgr.initialize(pid, BPC.sqrtPriceAtTick(0), 0, f);
        mgr.addPosition(pid, -20_000, 20_000, TS, L);
        _fragment(pid, -int24(uint24(dust)), 0);
        (, uint256 truth, ) = BPC.v4WalkRank(address(mgr), pid, amt, f, TS, true, 0);
        (, , uint256 h16) = BPC.v4WalkRank(address(mgr), pid, amt, f, TS, true, type(uint256).max - 1);
        assertGe(h16, truth, "sixteen-stretch ceiling under the truth");
        if (truth == 0) return;
        (, uint256 r, ) = BPC.v4WalkRank(address(mgr), pid, amt, f, TS, true, bound(b, 0, truth - 1));
        assertEq(r, truth, "settled below the truth");
    }

    // ── B1: the ceiling never saturates under the walk's own figure ─────────────────────────

    int24   constant HIGH  = 800_000;            // ~2^115 token1 per token0
    uint128 constant L_BIG = uint128(1) << 100;
    uint256 constant ORDER_BIG = 1e12;           // ~2^28 of input crosses one dusted tick

    /// A book whose output passes 2^128 - 1 within a few stretches: tick 800,000 and 2^100 of
    /// liquidity, one-wei dust on the `n` ticks under the price so every stretch is one tick.
    /// Only a pool holding more than ~3.4e38 raw units of tokenOut reaches this.
    function _hugeBook(uint256 n) internal returns (bytes32 pid) {
        pid = _pid(FEE);
        mgr.initialize(pid, BPC.sqrtPriceAtTick(HIGH), HIGH, FEE);
        mgr.addPosition(pid, HIGH - 20_000, HIGH + 20_000, TS, L_BIG);
        _fragment(pid, HIGH - int24(uint24(n)), HIGH);
    }

    /// B1, at sixteen. Both ways a quote is cut there - `bar` the maximum (the promise alone)
    /// and a bar the saturated ceiling sits under - must return a ceiling at or above the rank.
    function test_B1_SixteenStretchCeilingNeverUnderTheRank() public {
        bytes32 pid = _hugeBook(40);
        (uint256 lo, uint256 rank, uint256 hi) =
            BPC.v4WalkRank(address(mgr), pid, ORDER_BIG, FEE, TS, true, type(uint256).max);
        assertGt(lo, type(uint128).max, "precondition: sixteen stretches pay more than 2^128 - 1");
        assertEq(rank, lo, "the promise alone is not walked deep");
        assertGe(hi, rank, "bar = max: the ceiling fell under the rank");
        (lo, rank, hi) = BPC.v4WalkRank(address(mgr), pid, ORDER_BIG, FEE, TS, true, type(uint256).max - 1);
        assertEq(rank, lo, "precondition: the saturated ceiling settled the quote at sixteen");
        assertGe(hi, rank, "settled at sixteen: the ceiling fell under the rank");
        // An unspent rest above 2^128 (the net-input saturation).
        (lo, rank, hi) = BPC.v4WalkRank(address(mgr), pid, uint256(1) << 130, FEE, TS, true, type(uint256).max - 1);
        assertEq(rank, lo, "precondition: settled at sixteen with the rest above 2^128");
        assertGe(hi, rank, "rest above 2^128: the ceiling fell under the rank");
        // An ordinary book cut at sixteen keeps the documented 2^128 - 1 when the promise is all
        // that is asked: the floor of the ceiling is still 2^128 - 1, not the rank.
        bytes32 small = _pid(3000);
        mgr.initialize(small, BPC.sqrtPriceAtTick(0), 0, 3000);
        mgr.addPosition(small, -20_000, 20_000, TS, L);
        _fragment(small, -20, 0);
        (, rank, ) = BPC.v4WalkRank(address(mgr), small, ORDER, 3000, TS, true, 0);
        (lo, , hi) = BPC.v4WalkRank(address(mgr), small, ORDER, 3000, TS, true, type(uint256).max);
        assertLt(lo, rank, "precondition: truncated");
        assertEq(hi, type(uint128).max, "bar = max on an ordinary book: 2^128 - 1");
    }

    /// B1, a small unspent rest: the ceiling's own `c + out` saturation. 2^83 of liquidity at
    /// tick 800,000 makes sixteen stretches pay ~2^130 while a rest of a few thousand wei is
    /// priced under 2^128; the sweep puts the rest left at sixteen across that window.
    function test_B1_SmallRestCeilingNeverUnderTheRank() public {
        bytes32 pid = _pid(FEE);
        mgr.initialize(pid, BPC.sqrtPriceAtTick(HIGH), HIGH, FEE);
        mgr.addPosition(pid, HIGH - 20_000, HIGH + 20_000, TS, uint128(1) << 83);
        _fragment(pid, HIGH - 40, HIGH);
        uint256 past;
        for (uint256 a = 20_000; a <= 60_000; a += 2_000) {
            (uint256 lo, uint256 rank, uint256 hi) =
                BPC.v4WalkRank(address(mgr), pid, a, FEE, TS, true, type(uint256).max - 1);
            if (lo > type(uint128).max) ++past;
            assertLe(lo, rank, "lo above the rank");
            assertGe(hi, rank, "small rest: the ceiling fell under the rank");
        }
        assertGt(past, 0, "precondition: some promise passes 2^128 - 1");
    }

    /// B1, at the deep limit, through the whole plan. Dust on 300 ticks: the deep walk ends at
    /// 256 stretches with input unspent, `_v4Ceil` saturated at 2^128 - 1 under the promise,
    /// and `_singleLeg`'s `hi -= out_` underflowed - `findBestRoutePlan` reverted.
    function test_B1_TruncatedDeepWalkDoesNotRevertThePlan() public {
        bytes32 pid = _hugeBook(300);
        hub.addV4(t0, t1, FEE, TS, address(0));
        (uint256 lo, uint256 rank, uint256 hi) = BPC.v4WalkRank(address(mgr), pid, ORDER_BIG, FEE, TS, true, 0);
        (, uint256 spec, , , ) = mgr.specSwap(pid, ORDER_BIG, FEE, TS, true);
        assertGt(lo, type(uint128).max, "precondition: the promise passes 2^128 - 1");
        assertLt(rank, spec, "precondition: the deep walk is still truncated");
        solver.findBestRoutePlan(t0, t1, ORDER_BIG);
        assertLe(lo, rank, "lo above the rank");
        assertGe(hi, rank, "deep limit: the ceiling fell under the rank");
    }

    /// B1, the invariant: `lo <= rank <= hi` on every return of the walk - every bar class
    /// (the maximum, zero, any), both directions, prices up to ~2^115 and liquidity up to 2^110.
    /// Half the runs (`dust` >= 128) are drawn where the output passes 2^128 - 1 with the walk
    /// cut: a price at least 2^86 in the trade's favour, deep liquidity and more dust ticks than
    /// sixteen stretches cross - the region the bug lived in, which a uniform draw rarely hits.
    function testFuzz_B1_WalkKeepsLoRankHiOrdered(
        uint256 amt, uint24 f, uint8 dust, uint256 bar, int24 tick, uint8 lShift, bool zfo
    ) public {
        amt = bound(amt, 1, type(uint128).max);
        f = uint24(bound(f, 0, 200_000));
        uint128 liq;
        if (dust >= 128) {
            dust = uint8(bound(dust, 17, 40));
            tick = int24(bound(tick, 600_000, 800_000));
            if (!zfo) tick = -tick;
            liq = uint128(1) << uint8(bound(lShift, 80, 110));
        } else {
            dust = uint8(bound(dust, 0, 40));
            tick = int24(bound(tick, -800_000, 800_000));
            liq = uint128(1) << uint8(bound(lShift, 0, 110));
        }
        if (bar % 3 == 0) bar = type(uint256).max;
        else if (bar % 3 == 1) bar = 0;
        bytes32 pid = _pid(f);
        mgr.initialize(pid, BPC.sqrtPriceAtTick(tick), tick, f);
        mgr.addPosition(pid, tick - 20_000, tick + 20_000, TS, liq);
        if (zfo) _fragment(pid, tick - int24(uint24(dust)), tick);
        else _fragment(pid, tick + 1, tick + 1 + int24(uint24(dust)));
        (uint256 lo, uint256 rank, uint256 hi) = BPC.v4WalkRank(address(mgr), pid, amt, f, TS, zfo, bar);
        assertLe(lo, rank, "lo above the rank");
        assertLe(rank, hi, "the ceiling fell under the rank");
    }
}
