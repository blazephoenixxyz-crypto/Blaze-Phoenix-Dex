// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// The split gate against its twin: the best single row, EXECUTED on its own. The oracle is never
// the code under test - each twin is a separate swap through the Router with that one venue
// registered, so the gate's own figures (`sR`, `up`, `upH`) never decide the expected value.
//
//   main an honest V4 book whose fine-grained liquidity starts at the current tick (so the
//       funnel's two-stretch held vote weighs it light and the split hands most of the order to
//       a worse rival) against a V2 rival. With the deep walk settled (16-18 stretches), the
//       gate sees the single row is better and collapses onto it. Past the deep walk
//       (256-258 stretches) the single row's ceiling `hi` stays above every rank.
//   control (untruncated) the fine-grained liquidity starts past the funnel's reach, the V4 book
//       keeps its weight, and a split that beats both rows is kept.
//   control (Q2i) the split is better AND truncated past the deep walk: the split stays.
//   late-truncated the V4 row's deep walk stops in the order's last few percent and the row is
//       the chosen single; its split leg, at its share, settles. Red at 6e5067b (the gate vetoed
//       the collapse on the whole-order row's ceiling `hMax > sR`); green with the split's own
//       ceiling `upH` in the gate.
//
// The property every cell asserts: the route, executed, is never under the
// best single row whose rank SETTLED on the whole order, executed alone, by more than
// MIN_SPLIT_IMPROVEMENT_PPM. Both sides are executed through the same Router path, net of its
// fee, so the fee is in both and the only slack is the gate's own 25 ppm.

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver, MIN_SPLIT_IMPROVEMENT_PPM} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Leg, RoutePlan} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";
import {MockV2Factory} from "./mocks/MockV2Factory.sol";
import {MockV4TickManager} from "./mocks/MockV4TickManager.sol";
import {MockWETH9} from "./RouterV4NativeEth.t.sol";

contract SplitGateTwinTest is Test {
    MockV4TickManager mgr;
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    BlazePhoenixRouter router;
    MockV2Factory fac;
    address t0;
    address t1;
    address user = address(0xBEEF);
    address lp   = address(0x1D);

    uint8   constant MODE_ASK = 0;
    uint24  constant FEE = 100;       // 0.01% tier, tickSpacing 1
    int24   constant TS  = 1;
    uint256 constant M   = 1e22;      // the order; the cells also run M / 10
    uint256 constant PPM = MIN_SPLIT_IMPROVEMENT_PPM;   // the gate's only slack, read from the Solver

    /// One cell: the V4 book (a base position `lb` over [-20000, 20000] plus `k` one-tick
    /// positions of `lx` each on [start - k, start)), the rival (`rf`, `rl`), the order.
    struct Cell {
        uint128 lb;
        uint256 k;
        int24   start;
        uint128 lx;
        uint24  rf;     // rival: 0 = a V2 pair holding `rl` of each token; else a V4 book of fee `rf`, L = `rl`
        uint128 rl;     // 0 = no rival
        uint256 amt;
    }

    struct Seen {
        uint256 got;    // the solver's route, executed
        uint256 v4;     // twin: the V4 book alone, executed
        uint256 rv;     // twin: the rival alone, executed
        uint256 lo;     // v4WalkRank of the whole order on the V4 book, bar 0
        uint256 rank;
        uint256 hi;
        uint256 legs;   // legs of the solver's first hop
        uint256 v4In;   // input the solver's plan sends to the V4 book
        bool rvSettled; // the rival's walk settles on the whole order (a V2 pair has no walk)
    }

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
        MockERC20(t0).mint(user, 100 * M);
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

    function _pid() internal view returns (bytes32) { return _pidOf(FEE); }

    function _pidOf(uint24 fee) internal view returns (bytes32) { return BPC.computeV4PoolId(t0, t1, fee, TS, address(0)); }

    /// The cell's liquidity scaled to its order: the M / 10 cell is the M cell shrunk tenfold.
    function _sc(uint128 l, uint256 amt) internal pure returns (uint128) { return uint128(uint256(l) * amt / M); }

    /// An honest V4 book: every position carries real liquidity (`lx` is not dust).
    function _book(Cell memory c) internal {
        mgr.initialize(_pid(), BPC.sqrtPriceAtTick(0), 0, FEE);
        if (c.lb != 0) mgr.addPosition(_pid(), -20_000, 20_000, TS, _sc(c.lb, c.amt));
        vm.startPrank(lp);
        for (uint256 j; j < c.k; ++j) {
            int24 t = c.start - int24(int256(j)) - 1;
            mgr.addPosition(_pid(), t, t + 1, TS, _sc(c.lx, c.amt));
        }
        vm.stopPrank();
        hub.addV4(t0, t1, FEE, TS, address(0));
    }

    /// The rival row: a V2 pair found by discovery, or a full-range V4 book of another fee tier
    /// at the same price (an honest venue: its fee-free price is the V4 book's).
    function _rival(Cell memory c) internal {
        uint128 l = _sc(c.rl, c.amt);
        if (c.rf == 0) return _v2(uint112(l), uint112(l));
        mgr.initialize(_pidOf(c.rf), BPC.sqrtPriceAtTick(0), 0, c.rf);
        mgr.addPosition(_pidOf(c.rf), -20_000, 20_000, TS, l);
        hub.addV4(t0, t1, c.rf, TS, address(0));
    }

    /// A V2 pair found by discovery (a factory pair, not a curated row).
    function _v2(uint112 ra, uint112 rb) internal {
        MockV2Pair p = new MockV2Pair(t0, t1);
        fac.setPair(t0, t1, address(p));
        MockERC20(p.token0()).mint(address(p), ra);
        MockERC20(p.token1()).mint(address(p), rb);
        p.setReserves(ra, rb);
    }

    function _swap(uint256 amt) internal returns (uint256 got) {
        uint256 b1 = MockERC20(t1).balanceOf(user);
        vm.prank(user);
        router.swapBestExactIn(t0, t1, amt, 1, user, block.timestamp + 1);
        got = MockERC20(t1).balanceOf(user) - b1;
    }

    function _run(Cell memory c) internal returns (Seen memory s) {
        uint256 snap = vm.snapshotState();
        _book(c);
        s.v4 = _swap(c.amt);
        vm.revertToState(snap);
        if (c.rl != 0) {
            _rival(c);
            s.rv = _swap(c.amt);
            vm.revertToState(snap);
        }
        _book(c);
        if (c.rl != 0) _rival(c);
        (s.lo, s.rank, s.hi) = BPC.v4WalkRank(address(mgr), _pid(), c.amt, FEE, TS, true, 0);
        if (c.rl != 0 && c.rf != 0) {
            (, uint256 rr, uint256 rh) = BPC.v4WalkRank(address(mgr), _pidOf(c.rf), c.amt, c.rf, TS, true, 0);
            s.rvSettled = rr == rh;
        } else {
            s.rvSettled = true;
        }
        RoutePlan memory p = solver.findBestRoutePlan(t0, t1, c.amt);
        Leg[] memory legs = p.best.hops[0].legs;
        s.legs = legs.length;
        for (uint256 i; i < legs.length; ++i) {
            if (legs[i].pool == address(uint160(uint256(_pid())))) s.v4In += legs[i].amountIn;
        }
        s.got = _swap(c.amt);
        vm.revertToState(snap);
        emit log_named_uint("cell k               ", c.k);
        emit log_named_uint("cell order           ", c.amt);
        emit log_named_uint("delivered            ", s.got);
        emit log_named_uint("twin V4 alone        ", s.v4);
        emit log_named_uint("twin rival alone     ", s.rv);
        emit log_named_uint("V4 lo                ", s.lo);
        emit log_named_uint("V4 rank              ", s.rank);
        emit log_named_uint("V4 hi                ", s.hi);
        emit log_named_uint("legs                 ", s.legs);
        emit log_named_uint("V4 leg input         ", s.v4In);
    }

    function _twin(Seen memory s) internal pure returns (uint256) { return s.v4 > s.rv ? s.v4 : s.rv; }

    /// The twin of the property: the best row whose deep walk SETTLED on the whole
    /// order, executed alone. A truncated row stays out.
    function _settledBest(Seen memory s) internal pure returns (uint256 best) {
        if (s.hi == s.rank) best = s.v4;
        if (s.rvSettled && s.rv > best) best = s.rv;
    }

    /// `got` is not under `twin` by more than MIN_SPLIT_IMPROVEMENT_PPM: got * (1 + 25 ppm) >= twin.
    function _within(uint256 got, uint256 twin) internal pure returns (bool) {
        return got * (1e6 + PPM) >= twin * 1e6;
    }

    uint24 constant HI_FEE  = 100_000;   // 10%: an honest tier at the same price, real liquidity
    uint24 constant MID_FEE = 30_000;    // 3%

    /// A split that pays less than the best settled single row alone is not kept on a
    /// ceiling. The V4 book's fine liquidity starts at the current tick; the rival is a 10%-fee
    /// tier at the same price, which the split's weights hand half the order. Cells: 16-18
    /// one-tick positions in the order's path (the promise is cut, the deep walk settles) and
    /// 256-258 (past the deep walk, `hi > rank`: on this book it is cut from 253, measured), at
    /// M / 10 and M. Asserted against the best settled row (see the header).
    function test_TruncatedV4LegWithHiAboveRankDoesNotWinTheSplit() public {
        uint256[6] memory ks = [uint256(16), 17, 18, 256, 257, 258];
        uint256 bad;
        bool deep;
        bool cut;
        for (uint256 o; o < 2; ++o) {
            uint256 amt = o == 0 ? M / 10 : M;
            for (uint256 i; i < 6; ++i) {
                Cell memory c = Cell(3e23, ks[i], 0, 3e22, HI_FEE, 3e23, amt);
                Seen memory s = _run(c);
                if (s.hi > s.rank) deep = true;
                if (s.lo != s.rank && s.hi == s.rank) cut = true;
                if (!_within(s.got, _settledBest(s))) {
                    ++bad;
                    emit log_named_uint("FAIL: cell k         ", c.k);
                    emit log_named_uint("FAIL: cell order     ", c.amt);
                }
            }
        }
        assertTrue(cut, "non-vacuity: no cell had its promise cut and its deep walk settled");
        assertTrue(deep, "non-vacuity: no cell went past the deep walk");
        assertEq(bad, 0, "a split paying under the best settled row alone was kept");
    }

    /// Control (anti-vacuity of the test above): the same book against a 3%-fee rival, which the split
    /// beats both rows with. Untruncated deep walk (1, 8, 15, 16 and 252 one-tick positions; on
    /// this book the deep walk settles up to 252 and is cut from 253, measured): the split
    /// is kept and pays at least MIN_SPLIT_IMPROVEMENT_PPM over the best row alone.
    function test_Control_UntruncatedWalkSplitStillWins() public {
        uint256[5] memory ks = [uint256(1), 8, 15, 16, 252];
        for (uint256 i; i < 5; ++i) {
            Seen memory s = _run(Cell(3e23, ks[i], 0, 3e22, MID_FEE, 3e23, M));
            assertEq(s.hi, s.rank, "precondition: the deep walk settles");
            assertEq(s.legs, 2, "the split that beats both rows was collapsed");
            assertGe(s.got * 1e6, _twin(s) * (1e6 + PPM), "the kept split does not beat the best row alone");
        }
    }

    /// Control: the Q2i cell (test/V4FragmentationRanking.t.sol). An honest book with one-wei
    /// dust on 300 ticks past the probe's reach, against a V2 rival: the split is better AND
    /// still truncated after the deep walk. The split stays.
    function test_Control_Q2i_BetterTruncatedSplitStays() public {
        Seen memory s = _run(Cell(1e23, 300, -30, 1, 0, 2e22, M));
        assertLt(s.lo * 10, s.rv, "precondition: the promise is far under the rival");
        assertLt(s.rank, s.rv, "precondition: the deep walk is still truncated under the rival");
        assertGt(s.hi, s.rv, "precondition: the ceiling stays above the rival");
        assertGt(s.got, s.rv + s.rv / 10, "the gate collapsed onto the rival on a truncated rank");
        assertGe(s.got * 100, _twin(s) * 99, "the split pays under the best row alone");
    }

    // ---- the late-truncated cell: the deep walk stops in the order's last few percent -------

    /// The V4 row is truncated LATE (rank 96% of what it pays) and is the chosen single; the
    /// split's V4 leg, at its share, settles. The ceiling `hMax` of the whole-order row stays
    /// above `sR`, and the gate must not keep a split that pays far less than that row alone.
    /// Book: base L 1e23 over [-20000, 20000] + 254 one-tick positions of 6.5e23 on [-254, 0);
    /// rival: a 20 %-fee tier, L 1e24, same price. Order 1e22.
    /// Red at 6e5067b: delivered 8105506137923813639213 against the V4 row alone
    /// 9838944794050420276862 (-17.62%): `hMax > sR` vetoed the collapse. Green with the
    /// split's own ceiling `upH` in the gate. Mutant: `hMax <= sR &&` back in the
    /// gate condition turns it red (that is the base, measured).
    function test_LateTruncatedV4RowIsNotVetoedByItsOwnCeiling() public {
        (Seen memory s, bool late) = _late(254, M, 6.5e23);
        assertGt(s.hi, s.rank, "precondition: the V4 row is truncated past the deep walk");
        assertTrue(late, "precondition: truncated late, and still outranking the rival");
        assertTrue(_within(s.got, s.v4), "a split paying under the late-truncated row was kept");
    }

    uint24 constant LATE_RIVAL_FEE = 200_000;   // 20 %

    /// The late cell at `k` one-tick positions of `lx`, order `amt`. `late`: the V4 row is
    /// truncated past the deep walk, its rank is within 5% of what it pays alone, and it still
    /// outranks the rival (so it is the gate's chosen single).
    function _late(uint256 k, uint256 amt, uint128 lx) internal returns (Seen memory s, bool late) {
        Cell memory c = Cell(1e23, k, 0, lx, LATE_RIVAL_FEE, 1e24, amt);
        s = _run(c);
        late = s.hi > s.rank && s.rank * 100 >= s.v4 * 95 && s.rank > s.rv;
    }

    /// A late-truncated chosen row is never beaten by a split its own ceiling would not keep:
    /// the route pays that row alone, less 25 ppm. Any other cell: the property in the header.
    function _lateHolds(Seen memory s, bool late) internal pure {
        if (late) assertTrue(_within(s.got, s.v4), "a split paying under the late-truncated row was kept");
        else assertTrue(_within(s.got, _settledBest(s)), "under the best settled row alone");
    }

    /// The late cell across the deep walk's edge, k = 252..254 (the order crosses the positions
    /// last; the walk's 256 steps end inside or just past them).
    function test_LateTruncated_EdgeOfTheDeepWalk_252to254() public {
        uint256 nLate;
        for (uint256 k = 252; k <= 254; ++k) {
            (Seen memory s, bool late) = _late(k, M, 6.5e23);
            if (late) ++nLate;
            _lateHolds(s, late);
        }
        emit log_named_uint("late cells", nLate);
    }

    /// The late cell across the deep walk's edge, k = 255..257.
    function test_LateTruncated_EdgeOfTheDeepWalk_255to257() public {
        uint256 nLate;
        for (uint256 k = 255; k <= 257; ++k) {
            (Seen memory s, bool late) = _late(k, M, 6.5e23);
            if (late) ++nLate;
            _lateHolds(s, late);
        }
        emit log_named_uint("late cells", nLate);
    }

    /// The late cell at the order +- 1 wei: every one is late and pays the V4 row alone.
    function test_LateTruncated_OrderPlusMinusOneWei() public {
        for (uint256 d; d < 3; ++d) {
            (Seen memory s, bool late) = _late(254, M - 1 + d, 6.5e23);
            assertTrue(late, "precondition: truncated late, and still outranking the rival");
            assertTrue(_within(s.got, s.v4), "a split paying under the late-truncated row was kept");
        }
    }

    /// Fuzz over the order (M +- 1%) and the one-tick positions' liquidity (5.5e23..6.8e23, the
    /// span measured truncated late at M).
    function testFuzz_LateTruncated_NeverKeepsASplitUnderTheChosenRow(uint256 amt, uint256 lx) public {
        amt = bound(amt, M - M / 100, M + M / 100);
        lx = bound(lx, 5.5e23, 6.8e23);
        (Seen memory s, bool late) = _late(254, amt, uint128(lx));
        _lateHolds(s, late);
    }

    // ---- fuzz: the truncated V4 leg ---------------------------------------------------------

    function _fuzzCell(uint256 k, uint256 amt) internal returns (Cell memory c, Seen memory s) {
        k = bound(k, 1, 600);
        amt = bound(amt, 1e6, M);
        c = Cell(3e23, k, 0, 3e22, HI_FEE, 3e23, amt);
        s = _run(c);
    }

    /// Never under the best row whose rank SETTLED, executed, by more than 25 ppm.
    /// A row truncated by the deep walk stays out of the twin.
    /// The domain is not vacuous: its cell shape at k = 16-18 (promise cut, deep walk settled)
    /// and k = 256-258 (past the deep walk) is asserted so by the truncated-V4-leg unit test above.
    function testFuzz_TruncatedLegNeverBeatsTheSingleRow(uint256 k, uint256 amt) public {
        (, Seen memory s) = _fuzzCell(k, amt);
        assertTrue(_within(s.got, _settledBest(s)), "under the best settled row alone");
    }

    // ---- two hops, ETH in -------------------------------------------------------------------

    MockWETH9 weth;
    address br;

    /// A V4 book on (a -> b) at fee `fee`: base `lb` + `k` one-tick positions of `lx` along the
    /// swap's direction from the current tick.
    function _bookAB(address a, address b, uint24 fee, uint128 lb, uint256 k, uint128 lx) internal {
        (address c0, address c1) = a < b ? (a, b) : (b, a);
        bytes32 pid = BPC.computeV4PoolId(c0, c1, fee, TS, address(0));
        mgr.initialize(pid, BPC.sqrtPriceAtTick(0), 0, fee);
        if (lb != 0) mgr.addPosition(pid, -20_000, 20_000, TS, lb);
        for (uint256 j; j < k; ++j) {
            int24 t = a == c0 ? -int24(int256(j)) - 1 : int24(int256(j));
            mgr.addPosition(pid, t, t + 1, TS, lx);
        }
        hub.addV4(c0, c1, fee, TS, address(0));
    }

    function _hop2() internal {
        MockV2Pair p = new MockV2Pair(br, t1);
        fac.setPair(br, t1, address(p));
        MockERC20(br).mint(address(p), 1e27);
        MockERC20(t1).mint(address(p), 1e27);
        p.setReserves(uint112(1e27), uint112(1e27));
    }

    function _native(uint256 amt) internal returns (uint256 got) {
        RoutePlan memory p = solver.findBestRoutePlan(address(weth), t1, amt);
        vm.deal(user, amt);
        uint256 b1 = MockERC20(t1).balanceOf(user);
        vm.prank(user);
        router.swapExactInNative{value: amt}(p.best, 1, user, block.timestamp + 1);
        got = MockERC20(t1).balanceOf(user) - b1;
    }

    /// One 2-hop cell: hop 1 WETH -> bridge carries the truncated-V4-leg book (k one-tick positions) and the
    /// 10% rival; hop 2 bridge -> t1 is a deep V2 pair. `which`: 1 = V4 only, 2 = rival only, 3 = both.
    function _cell2(uint256 k, uint256 amt, uint256 which) internal returns (uint256 got) {
        uint256 snap = vm.snapshotState();
        if (which & 1 != 0) _bookAB(address(weth), br, FEE, _sc(3e23, amt), k, _sc(3e22, amt));
        if (which & 2 != 0) _bookAB(address(weth), br, HI_FEE, _sc(3e23, amt), 0, 0);
        _hop2();
        got = _native(amt);
        vm.revertToState(snap);
    }

    function _twoHops(uint256 k) internal returns (uint256 got, uint256 v4, uint256 rv, uint256 rank, uint256 hi, uint256 best) {
        weth = new MockWETH9();
        router.setWeth(address(weth));
        br = address(new MockERC20("BR", "BR"));
        hub.addBridge(br);
        MockERC20(br).mint(address(mgr), 1e30);
        v4 = _cell2(k, M, 1);
        rv = _cell2(k, M, 2);
        got = _cell2(k, M, 3);
        uint256 snap = vm.snapshotState();
        _bookAB(address(weth), br, FEE, 3e23, k, 3e22);
        (address c0, address c1) = address(weth) < br ? (address(weth), br) : (br, address(weth));
        (, rank, hi) = BPC.v4WalkRank(address(mgr), BPC.computeV4PoolId(c0, c1, FEE, TS, address(0)), M, FEE, TS, address(weth) == c0, 0);
        vm.revertToState(snap);
        best = rv;   // the rival is full range: it settles
        if (hi == rank && v4 > best) best = v4;
    }

    /// Two hops, ETH in: hop 1 truncated (k in {17, 257}); never under the best row whose rank
    /// settled, executed as the same 2-hop route, by more than 25 ppm.
    function test_TwoHops_ETH_TruncatedLegOnHop1() public {
        uint256[2] memory ks = [uint256(17), 257];
        for (uint256 i; i < 2; ++i) {
            (uint256 got, , , , , uint256 best) = _twoHops(ks[i]);
            assertTrue(_within(got, best), "2 hops: under the best settled row");
        }
    }
}
