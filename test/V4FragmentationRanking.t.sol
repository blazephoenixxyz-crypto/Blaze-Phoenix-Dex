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
//   ceiling  `v4WalkRank` stops at sixteen only when the rest cannot carry the quote past the
//        bar, and never below the truth.

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
        solver = new BlazePhoenixSolver(address(hub));
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
}
