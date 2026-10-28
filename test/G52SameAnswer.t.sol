// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// G52 META-GUARD: THE TWO GAS MECHANISMS OF WAVE 5.2 CHANGE NO ANSWER, TO THE WEI.
//
// M10 (Solver._firstStage): the first stage of a bridge route, tIn -> bs[i], is built once per
// solve and every later topology opening on bs[i] reads a copy of that build. M11
// (BlazePhoenixMath._byRate): a hop orders its live rates once, and the plain median and every
// weighted median of the hop walk that one order instead of sorting again.
//
// `SolverRef653` is the Solver of 653b1dc with its own frozen library `MathRef653` (both
// literal, renamed). Both Solvers read the same Hub and the same state, and each call must come
// back with the same success and the same returndata bytes, with all the gas and at the door's
// budget (SOLVE_GAS). The fixed rows are the shapes the mechanisms decide on: bridge routes
// whose first stage is shared by three topologies (two-hop and three-hop), the leader and the
// runner-up opening on the same bridge, held grids whose rebuild runs WALK on the leader's
// topology, V4 books whose cut votes run the median three times. The fuzz row draws up to three
// bridges, books on every pair between tIn, tOut and the bridges, V4 books and amounts.
// The rows log the cold gas of both Solvers on the same state.

import {Test} from "forge-std/Test.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixMath} from "../src/BlazePhoenixMath.sol";
import {BlazePhoenixCore as BPC, RoutePlan, PoolInfo} from "../src/BlazePhoenixCore.sol";
import {SolverRef653} from "./ref/SolverRef653.sol";
import {MathRef653} from "./ref/MathRef653.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";
import {MockV4TickManager} from "./mocks/MockV4TickManager.sol";
import {MockV3TickPool} from "./mocks/MockV3TickPool.sol";
import {Origin} from "./mocks/MockOriginFactory.sol";
import {HeavyBookPool} from "./CapacityWalkBudget.t.sol";

contract G52SameAnswerTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    SolverRef653 ref;
    MockV4TickManager mgr;
    address tA;
    address tB;
    address[] touched;
    address[] bridges;

    /// Mirrors `BlazePhoenixRouter.SOLVE_GAS`, the budget the automatic door hands a solve.
    uint256 constant SOLVE_GAS = 14_700_000;
    uint160 constant SP = uint160(1 << 96);   // price 1, tick 0
    uint128 constant L = 1_000e18;
    int24 constant TS = 60;

    function setUp() public {
        mgr = new MockV4TickManager();
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(mgr));
        solver = new BlazePhoenixSolver(address(hub), address(0));
        ref = new SolverRef653(address(hub), address(0));
        hub.setRoles(address(this), address(solver), address(this));
        address a = _token();
        address b = _token();
        (tA, tB) = a < b ? (a, b) : (b, a);
        MockERC20(tA).mint(address(mgr), 1e30);
        MockERC20(tB).mint(address(mgr), 1e30);
        touched.push(address(hub));
        touched.push(address(solver));
        touched.push(address(ref));
        touched.push(address(mgr));
        touched.push(address(BlazePhoenixMath));
        touched.push(address(MathRef653));
        touched.push(address(BPC));
    }

    // ─── fixtures ────────────────────────────────────────────────────────────

    function _token() internal returns (address t) {
        t = address(new MockERC20("T", "T"));
        touched.push(t);
    }

    /// A curated V2 row holding `ra` of `a` and `rb` of `b`.
    function _v2(address a, address b, uint256 ra, uint256 rb) internal returns (address) {
        MockV2Pair p = new MockV2Pair(a, b);
        MockERC20(a).mint(address(p), ra);
        MockERC20(b).mint(address(p), rb);
        (uint256 r0, uint256 r1) = p.token0() == a ? (ra, rb) : (rb, ra);
        p.setReserves(uint112(r0), uint112(r1));
        hub.seedPool(address(p), BPC.KIND_V2, 30, address(0), a, b);
        touched.push(address(p));
        return address(p);
    }

    /// The same pool found by discovery (its factory is admitted) and then traded once through
    /// the swap door, as test/BandBaseBreakdownPoint.t.sol wires its pools.
    function _v2Found(address a, address b, uint256 ra, uint256 rb) internal returns (address) {
        MockV2Pair p = new MockV2Pair(a, b);
        MockERC20(a).mint(address(p), ra);
        MockERC20(b).mint(address(p), rb);
        (uint256 r0, uint256 r1) = p.token0() == a ? (ra, rb) : (rb, ra);
        p.setReserves(uint112(r0), uint112(r1));
        touched.push(address(Origin.wire(hub, address(p), a, b, BPC.KIND_V2, 30)));
        hub.recordSwap(address(p), BPC.KIND_V2, 30, address(0), a, b, 1e18, 1e18, ra < rb ? ra : rb);
        touched.push(address(p));
        return address(p);
    }

    /// A V4 book on (tA, tB) at `tick`, liquidity `liq` over [lo, hi].
    function _v4(uint24 fee, int24 ts, int24 tick, int24 lo, int24 hi, uint128 liq) internal {
        bytes32 pid = BPC.computeV4PoolId(tA, tB, fee, ts, address(0));
        mgr.initialize(pid, mgr.sqrtAt(tick), tick, fee);
        mgr.addPosition(pid, lo, hi, ts, liq);
        hub.seedPool(address(uint160(uint256(pid))), BPC.KIND_V4, fee, address(0), tA, tB);
    }

    /// A V4 book on (a, b), either order, at `tick`, liquidity `liq` over [lo, hi].
    function _v4On(address a, address b, uint24 fee, int24 ts, int24 tick, int24 lo, int24 hi, uint128 liq) internal {
        (address c0, address c1) = a < b ? (a, b) : (b, a);
        MockERC20(c0).mint(address(mgr), 1e30);
        MockERC20(c1).mint(address(mgr), 1e30);
        bytes32 pid = BPC.computeV4PoolId(c0, c1, fee, ts, address(0));
        mgr.initialize(pid, mgr.sqrtAt(tick), tick, fee);
        mgr.addPosition(pid, lo, hi, ts, liq);
        hub.seedPool(address(uint160(uint256(pid))), BPC.KIND_V4, fee, address(0), c0, c1);
    }

    /// A V3 book the cap binds (test/CapacityWalkBudget.t.sol's), twenty ticks on each side.
    function _heavy(address a, address b, uint24 fee, uint128 liq, uint256 held) internal {
        HeavyBookPool p = new HeavyBookPool(a, b, fee, TS);
        p.setState(SP, liq);
        for (int24 i = 1; i <= 20; ++i) {
            p.setTick(-i * TS, int128(liq / 1000));
            p.setTick(i * TS, -int128(liq / 1000));
        }
        MockERC20(a).mint(address(p), held);
        MockERC20(b).mint(address(p), held);
        hub.seedPool(address(p), BPC.KIND_V3, fee, address(0), a, b);
        touched.push(address(p));
    }

    /// test/CapacityWalkBudget.t.sol's grid: every pair of tA, tB and `nBridges` bridges gets
    /// `perPair` heavy books holding `held`, the direct books declaring `dLiq`.
    function _grid(uint256 nBridges, uint256 perPair, uint256 held, uint128 dLiq) internal {
        uint24[6] memory fees = [uint24(3_000), 500, 10_000, 100, 2_500, 400];
        address[] memory b = new address[](nBridges);
        for (uint256 i; i < nBridges; ++i) { b[i] = _token(); hub.addBridge(b[i]); }
        for (uint256 k; k < perPair; ++k) {
            _heavy(tA, tB, fees[k], dLiq, held);
            for (uint256 i; i < nBridges; ++i) {
                _heavy(tA, b[i], fees[k], L, held);
                _heavy(b[i], tB, fees[k], L, held);
                for (uint256 j; j < i; ++j) _heavy(b[j], b[i], fees[k], L, held);
            }
        }
    }

    function _cool() internal {
        for (uint256 i; i < touched.length; ++i) vm.cool(touched[i]);
    }

    // ─── the comparison ──────────────────────────────────────────────────────

    /// Both Solvers on the same call, cold, with the same gas: the same success and the same bytes.
    function _same(address a, address b, uint256 amt, uint256 g)
        internal returns (bool ok, uint256 gasNew, uint256 gasRef)
    {
        bytes memory q = abi.encodeCall(BlazePhoenixSolver.findBestRoutePlan, (a, b, amt));
        _cool();
        uint256 g0 = gasleft();
        (bool okN, bytes memory rN) = address(solver).staticcall{gas: g}(q);
        gasNew = g0 - gasleft();
        _cool();
        g0 = gasleft();
        (bool okR, bytes memory rR) = address(ref).staticcall{gas: g}(q);
        gasRef = g0 - gasleft();
        assertEq(okN, okR, "G52: one Solver answered and the other refused");
        assertEq(rN, rR, "G52: the Solver and the Solver of 653b1dc disagree");
        ok = okN;
    }

    /// The comparison with all the gas, then at the door's budget; the first must find a route.
    function _row(string memory name, address a, address b, uint256 amt) internal {
        (bool ok, uint256 gN, uint256 gR) = _same(a, b, amt, gasleft());
        assertTrue(ok, "precondition: the row has a route, so the comparison is not of two refusals");
        emit log_named_string("row", name);
        emit log_named_uint("  gas new, cold", gN);
        emit log_named_uint("  gas 653b1dc, cold", gR);
        emit log_named_int("  saved", int256(gR) - int256(gN));
        (ok, , ) = _same(a, b, amt, SOLVE_GAS);
        emit log_named_string("  at SOLVE_GAS", ok ? "both answered, same bytes" : "both refused, same bytes");
    }

    // ─── fixed rows ──────────────────────────────────────────────────────────

    /// Calls and static calls into any of `pools` among the recorded accesses of one solve.
    function _reads(address s, bytes memory q, address[] memory pools) internal returns (uint256 c) {
        _cool();
        vm.startStateDiffRecording();
        (bool ok, ) = s.staticcall(q);
        VmSafe.AccountAccess[] memory recs = vm.stopAndReturnStateDiff();
        assertTrue(ok, "precondition: the row has a route");
        for (uint256 i; i < recs.length; ++i) {
            if (recs[i].kind != VmSafe.AccountAccessKind.Call && recs[i].kind != VmSafe.AccountAccessKind.StaticCall) continue;
            for (uint256 k; k < pools.length; ++k) if (recs[i].account == pools[k]) { ++c; break; }
        }
    }

    /// M10, counted: three bridges, two books on every pair. The Solver of 653b1dc builds each
    /// first stage tIn -> bs[i] in three topologies (the two-hop one and the two three-hop ones
    /// over bs[i]); the Solver builds it once, so the books of the first stages are read less,
    /// the books of the last stages (built on what the stage before produced) as often, and the
    /// answer is the same.
    function test_G52_EachFirstStageIsBuiltOnce() public {
        address[3] memory b = [_token(), _token(), _token()];
        for (uint256 i; i < 3; ++i) hub.addBridge(b[i]);
        address[] memory first = new address[](6);
        address[] memory last = new address[](6);
        for (uint256 k; k < 2; ++k) {
            _v2(tA, tB, 5_000e18 * (k + 1), 5_000e18 * (k + 1));
            for (uint256 i; i < 3; ++i) {
                first[2 * i + k] = _v2(tA, b[i], 300_000e18 * (k + 1), 300_000e18 * (k + 1));
                last[2 * i + k] = _v2(b[i], tB, 300_000e18 * (k + 1), 300_000e18 * (k + 1));
                for (uint256 j; j < i; ++j) _v2(b[j], b[i], 200_000e18 * (k + 1), 200_000e18 * (k + 1));
            }
        }
        bytes memory q = abi.encodeCall(BlazePhoenixSolver.findBestRoutePlan, (tA, tB, 1_000e18));
        uint256 fN = _reads(address(solver), q, first);
        uint256 fR = _reads(address(ref), q, first);
        uint256 lN = _reads(address(solver), q, last);
        uint256 lR = _reads(address(ref), q, last);
        emit log_named_uint("first-stage book reads, 653b1dc", fR);
        emit log_named_uint("first-stage book reads, now", fN);
        emit log_named_uint("last-stage book reads, 653b1dc", lR);
        emit log_named_uint("last-stage book reads, now", lN);
        assertGt(fR, 0, "precondition: the reference reads the first-stage books");
        assertLt(fN, fR, "each first stage is built once per solve, not once per topology");
        assertEq(lN, lR, "the last stages are built as before");
        (bool ok, , ) = _same(tA, tB, 1_000e18, gasleft());
        assertTrue(ok, "precondition: the row has a route");
    }

    /// Three bridges, books on every pair: each first stage is shared by a two-hop and two
    /// three-hop topologies, and the leader and the runner-up can open on the same bridge.
    function test_G52_SameAnswer_ThreeBridgesEveryPair() public {
        address[3] memory b = [_token(), _token(), _token()];
        for (uint256 i; i < 3; ++i) hub.addBridge(b[i]);
        _v2(tA, tB, 5_000e18, 5_000e18);
        for (uint256 i; i < 3; ++i) {
            for (uint256 k; k < 2; ++k) {
                _v2(tA, b[i], 300_000e18 * (k + 1), (300_000e18 + i * 900e18) * (k + 1));
                _v2(b[i], tB, 300_000e18 * (k + 1), (301_000e18 - i * 700e18) * (k + 1));
            }
            for (uint256 j; j < i; ++j) _v2(b[j], b[i], 200_000e18, 200_000e18 + j * 500e18);
        }
        // A V4 leg on a first stage: the kept build carries a leg whose every word is read.
        _v4On(tA, b[0], 3000, 60, 0, -887220, 887220, uint128(1e24));
        _row("3 bridges, every pair", tA, tB, 1_000e18);
        _row("3 bridges, every pair, large", tA, tB, 150_000e18);
        _row("the other way", tB, tA, 150_000e18);
    }

    /// Held books on every pair of three bridges: the leader is rebuilt with WALK on its own
    /// budget, and a bridge route leads.
    function test_G52_SameAnswer_HeldGridBridgeLeads() public {
        _grid(3, 6, 100e18, 100e18);
        _row("held, a bridge leads", tA, tB, 200e18);
    }

    /// The direct split leads held over three bridges and six books a pair.
    function test_G52_SameAnswer_HeldGridThreeBridgesSixBooks() public {
        _grid(3, 6, 100e18, L);
        _row("held, 3 bridges, 6 books per pair", tA, tB, 200e18);
    }

    /// V4 books cut by the sixteen-stretch walk next to V2 books: the band's median runs more
    /// than one pass over the hop's one order, with dead and tied rates in it.
    function test_G52_SameAnswer_MedianPassesOverOneOrder() public {
        _v2(tA, tB, 50_000e18, 50_000e18);
        _v2(tA, tB, 50_000e18, 50_000e18);   // a tie
        _v2(tA, tB, 1e21, 1_030e18);
        _v4(3000, 60, 0, -887220, 887220, uint128(1e24));
        _v4(100, 1, 0, -4, 4, uint128(1e26));
        _v4(500, 10, 0, -20, 20, uint128(1e25));
        _row("V2 and fragmented V4", tA, tB, 1_000e18);
        _row("V2 and fragmented V4, large", tA, tB, 40_000e18);
        _row("the other way", tB, tA, 40_000e18);
    }

    /// The band's base decides the route: three books whose rates are further apart than the
    /// band (+-MEDIAN_FILTER_BPS), listed so that row order and rate order differ, and the
    /// heaviest one at the top rate. A median that walked the votes in row order, or summed
    /// the mass over the wrong rows, would centre the band on another book.
    function test_G52_SameAnswer_MedianPicksTheBand() public {
        _v2(tA, tB, 200_000e18, 216_000e18);   // rate 1.08, the heaviest
        _v2(tA, tB, 10_000e18, 9_300e18);      // rate 0.93, light
        _v2(tA, tB, 100_000e18, 100_000e18);   // rate 1.00
        _row("rates 1.08 / 0.93 / 1.00, mass 20:1:10", tA, tB, 100e18);
        _row("the other way", tB, tA, 100e18);
    }

    /// N1 on a bridge route (test/V3PromiseIsWhatThePoolPays.t.sol's rebuild fixture with a
    /// second book on the first stage): the leader's second hop is held, so the self-call
    /// rebuilds it with WALK and keeps that first stage; the leader's first-stage book promised
    /// more than it pays, so the self-call drops it (`_sitsOut`) and builds again. The second
    /// build must not read the first stage kept before the list changed. The book beyond the
    /// thick range is thin (the pass-over fixture of that file, :314), so the stage without it
    /// pays more than the walked one and the build without it leads: a kept first stage read
    /// again would rebuild the WALK build and lose to it.
    function test_G52_SameAnswer_RebuildDropsAFirstStageBook() public {
        address mid = _token();
        hub.addBridge(mid);
        bool zq = tA < mid;
        MockV3TickPool q = new MockV3TickPool(tA, mid, 3000, 60);
        q.initialize(zq ? int24(1) : int24(59));
        q.addPosition(0, 60, 1e21);
        q.addPosition(-887220, 887220, 1e17);
        MockERC20(tA).mint(address(q), 1e21);
        MockERC20(mid).mint(address(q), 1e21);
        hub.seedPool(address(q), BPC.KIND_V3, 3000, address(0), tA, mid);
        touched.push(address(q));
        _v2(tA, mid, 1e18, 1e18);
        MockV3TickPool p = new MockV3TickPool(mid, tB, 3000, 60);
        p.initialize(0);
        p.addPosition(-887220, 887220, 1e21);
        MockERC20(mid).mint(address(p), 1e21);
        MockERC20(tB).mint(address(p), 1.5e18);
        hub.seedPool(address(p), BPC.KIND_V3, 3000, address(0), mid, tB);
        touched.push(address(p));
        // Premise: the self-call that drops books (calldata past 0xa4) runs.
        bytes memory qd = abi.encodeCall(BlazePhoenixSolver.findBestRoutePlan, (tA, tB, 1e18));
        _cool();
        vm.startStateDiffRecording();
        (bool ok, ) = address(solver).staticcall(qd);
        VmSafe.AccountAccess[] memory recs = vm.stopAndReturnStateDiff();
        assertTrue(ok, "precondition: the row has a route");
        bool drops;
        for (uint256 i; i < recs.length; ++i) {
            if (recs[i].account == address(solver) && recs[i].accessor == address(solver) && recs[i].data.length > 0xa4) drops = true;
        }
        assertTrue(drops, "precondition: the rebuild drops a book (N1, _sitsOut)");
        _row("N1 rebuild drops a first-stage book", tA, tB, 1e18);
    }

    /// M10's copy, on the runner-up: three bridges, and only b0 opens from tIn, so the leader and
    /// the runner-up both open on b0 (b0 -> b1 and b0 -> b2), each reading the first stage the
    /// two-hop topology kept. The leader's first-stage book promised more than it pays, and its
    /// walk (`_paysWhatItWalks`) writes what it pays into its legs AFTER the runner-up was handed
    /// out as the fallback: a first stage the two shared would carry that write into the fallback.
    function test_G52_SameAnswer_RunnerUpSharesTheWalkedFirstStage() public {
        address b0 = _token();
        address b1 = _token();
        address b2 = _token();
        hub.addBridge(b0);
        hub.addBridge(b1);
        hub.addBridge(b2);
        bool zq = tA < b0;
        MockV3TickPool q = new MockV3TickPool(tA, b0, 3000, 60);
        q.initialize(zq ? int24(1) : int24(59));
        q.addPosition(0, 60, 1e21);
        if (zq) q.addPosition(-600, 0, 1e20);
        else q.addPosition(60, 660, 1e20);
        MockERC20(tA).mint(address(q), 1e21);
        MockERC20(b0).mint(address(q), 1e21);
        hub.seedPool(address(q), BPC.KIND_V3, 3000, address(0), tA, b0);
        touched.push(address(q));
        _v2(tA, b0, 1e18, 1e18);
        _v2(b0, b1, 1e21, 1e21);
        _v2(b1, tB, 1e21, 1e21);
        _v2(b0, b2, 1e21, 0.99e21);
        _v2(b2, tB, 1e21, 1e21);
        // Premises: both routes open on b0 through three hops, and the leader's walk fell (the
        // self-call that drops books, calldata past 0xa4, runs).
        RoutePlan memory plan = solver.findBestRoutePlan(tA, tB, 1e18);
        assertTrue(plan.hasFallback, "precondition: a runner-up is handed out");
        assertEq(plan.fallbackRoute.hops.length, 3, "precondition: the runner-up is a three-hop route");
        assertEq(plan.fallbackRoute.hops[0].tokenOut, b0, "precondition: the runner-up opens on b0");
        bytes memory qd = abi.encodeCall(BlazePhoenixSolver.findBestRoutePlan, (tA, tB, 1e18));
        _cool();
        vm.startStateDiffRecording();
        (bool ok, ) = address(solver).staticcall(qd);
        VmSafe.AccountAccess[] memory recs = vm.stopAndReturnStateDiff();
        assertTrue(ok, "precondition: the row has a route");
        bool drops;
        for (uint256 i; i < recs.length; ++i) {
            if (recs[i].account == address(solver) && recs[i].accessor == address(solver) && recs[i].data.length > 0xa4) drops = true;
        }
        assertTrue(drops, "precondition: the leader's first-stage book fell on its walk (N1)");
        _row("runner-up shares the walked first stage", tA, tB, 1e18);
    }

    /// M11's one order lists the LIVE rows only, and the weighted median sums and walks exactly
    /// those. Three rows in seed order (equal registry depth, so equal psi and the same fee: the
    /// funnel keeps that order): a book at ~1.10, a book whose probe pays nothing (rate 0, the
    /// dead row in the middle) and a book at ~1.00. Rates 10% apart, so the band keeps one book
    /// and the base names it.
    ///   X, equal votes D: half the mass is D, the walk meets it exactly on the book at 1.00
    ///     (`acc >= half`), so that book sets the base. An order that kept the dead row's slot
    ///     (index 0 there, the book at 1.10) would add its vote and centre the band on 1.10; a
    ///     strict `acc > half` would walk past the exact half.
    ///   Y, votes D and 0.7 D: the book at 1.10 holds the median. A mass summed over the first
    ///     m rows instead of the m live ones (D + 0, the dead row sits among them) halves at
    ///     0.5 D and centres the band on 1.00.
    /// The amount is small (probe 1e13) so a dead row can sit at the same depth as the others.
    function test_G52_SameAnswer_MedianWalksTheLiveRowsOnly() public {
        address[3] memory x = [
            _v2(tA, tB, 300e18, 330e18),   // ~1.10, vote 300e18
            _v2(tA, tB, 5e33, 300e18),     // dead at the probe: 1e13 * 300e18 / 5e33 < 1
            _v2(tA, tB, 300e18, 300e18)    // ~1.00, vote 300e18
        ];
        address c = _token();
        address d = _token();
        address[3] memory y = [
            _v2(c, d, 500e18, 550e18),     // ~1.10, vote 500e18
            _v2(c, d, 5e33, 300e18),       // dead
            _v2(c, d, 350e18, 350e18)      // ~1.00, vote 350e18 = 0.7 x 500e18
        ];
        // Premises, read on the Solver of 653b1dc (the oracle, so they hold whatever the Solver
        // under test does and a mutant of it fails the comparison): the funnel keeps the seed
        // order (equal psi, equal fee), and the band keeps the book the base names: 1.00 in X,
        // 1.10 in Y.
        _seedOrder(tA, tB, x);
        _seedOrder(c, d, y);
        RoutePlan memory px = ref.findBestRoutePlan(tA, tB, 1e15);
        RoutePlan memory py = ref.findBestRoutePlan(c, d, 1e15);
        assertEq(px.best.hops[0].legs.length, 1, "precondition X: the band keeps one book");
        assertLt(px.best.totalOut, 1e15, "precondition X: the book at 1.00 sets the base");
        assertEq(py.best.hops[0].legs.length, 1, "precondition Y: the band keeps one book");
        assertGt(py.best.totalOut, 1.05e15, "precondition Y: the book at 1.10 sets the base");
        _row("median, equal votes, a dead row in the middle", tA, tB, 1e15);
        _row("median, votes 1 : 0.7, a dead row in the middle", c, d, 1e15);
    }

    /// The registry lists the pair's rows in seed order with one psi and one fee, so the
    /// funnel's selection sort (psi descending, then fee) leaves them in that order.
    function _seedOrder(address a, address b, address[3] memory seeded) internal view {
        (address t0, address t1) = a < b ? (a, b) : (b, a);
        PoolInfo[] memory rows = hub.getActivePools(t0, t1);
        assertEq(rows.length, 3, "precondition: three rows");
        for (uint256 i; i < 3; ++i) assertEq(rows[i].pool, seeded[i], "precondition: the registry lists the rows in seed order");
        address[] memory pls = new address[](3);
        address[] memory t0s = new address[](3);
        address[] memory t1s = new address[](3);
        for (uint256 i; i < 3; ++i) { pls[i] = rows[i].pool; t0s[i] = rows[i].token0; t1s[i] = rows[i].token1; }
        uint256[] memory ps = hub.psisOf(pls, t0s, t1s);
        assertEq(ps[0], ps[1], "precondition: one psi");
        assertEq(ps[1], ps[2], "precondition: one psi");
    }

    /// M10 on a held first stage read by a HIT. Two bridges; tA -> b0 is a V3 book holding
    /// 1.5e18 of b0, so a 1e18 order quotes ~0.996e18, above its cap (30% of what it holds) and
    /// under what it holds: the book is held. b0 -> b1 -> tB are deep V2 pairs; no pool on
    /// (tA, tB), (b0, tB) or (tA, b1). The two-hop topology over b0 builds the first stage (the
    /// miss) and stops at its empty second stage; the three-hop one over (b0, b1) reads it (the
    /// hit) and leads, held by its first stage alone. Held, the leader is rebuilt with WALK on
    /// its own budget and the walked route (~0.99e18 against ~0.45e18 at the cap) is the
    /// answer: a hit that dropped the held flag would skip the rebuild and answer the cap.
    function test_G52_SameAnswer_HeldFirstStageReadByAHit() public {
        address b0 = _token();
        address b1 = _token();
        hub.addBridge(b0);
        hub.addBridge(b1);
        MockV3TickPool q = new MockV3TickPool(tA, b0, 3000, 60);
        q.initialize(0);
        q.addPosition(-887220, 887220, 1e21);
        MockERC20(tA).mint(address(q), 1e21);
        MockERC20(b0).mint(address(q), 1.5e18);
        hub.seedPool(address(q), BPC.KIND_V3, 3000, address(0), tA, b0);
        touched.push(address(q));
        _v2(b0, b1, 1e21, 1e21);
        _v2(b1, tB, 1e21, 1e21);
        // Premises, read on the Solver of 653b1dc (the oracle): the answer is the three-hop route
        // walked past its cap, and it came from the rebuild the held flag asks for (the
        // self-call's bk carries bit 8). A Solver that answers otherwise fails the comparison.
        RoutePlan memory plan = ref.findBestRoutePlan(tA, tB, 1e18);
        assertEq(plan.best.hops.length, 3, "precondition: the three-hop route over (b0, b1) leads");
        assertEq(plan.best.hops[0].tokenOut, b0, "precondition: it opens on b0");
        assertGt(plan.best.hops[0].expectedOut, 0.9e18, "precondition: the answer is the walked build, past the cap");
        assertTrue(_rebuildAsked(address(ref), tA, tB, 1e18), "precondition: the held leader is rebuilt with WALK");
        _row("held first stage read by a hit", tA, tB, 1e18);
    }

    /// True when the solve of `s` makes a self-call carrying the rebuild bit (bk >> 8 != 0,
    /// `findBestRoutePlan`).
    function _rebuildAsked(address s, address a, address b, uint256 amt) internal returns (bool asked) {
        bytes memory q = abi.encodeCall(BlazePhoenixSolver.findBestRoutePlan, (a, b, amt));
        _cool();
        vm.startStateDiffRecording();
        (bool ok, ) = s.staticcall(q);
        VmSafe.AccountAccess[] memory recs = vm.stopAndReturnStateDiff();
        assertTrue(ok, "precondition: the row has a route");
        for (uint256 i; i < recs.length; ++i) {
            if (recs[i].account != s || recs[i].accessor != s) continue;
            bytes memory dta = recs[i].data;
            if (dta.length < 0xa4) continue;
            uint256 bk;
            assembly ("memory-safe") { bk := mload(add(dta, 0x84)) }
            if (bk >> 8 != 0) asked = true;
        }
    }

    /// M10 carries the first stage's RANK through a hit (test/V4FragmentationRanking.t.sol's Q2m
    /// book). tA -> b0 is an honest V4 book with one-wei dust on the twenty ticks the order walks
    /// first, so its sixteen-stretch promise is cut more than tenfold while the deep walk reads
    /// the book; b0 -> b1 -> tB are deep V2 pairs and tA -> tB a shallower V2 pair (~8.3e21).
    /// The two-hop topology over b0 builds the first stage (the miss); the three-hop one over
    /// (b0, b1) reads it (the hit) and is judged on the stage's rank, not on its promise: a hit
    /// that dropped the rank would hand the order to the shallower direct pair.
    function test_G52_SameAnswer_FragmentedFirstStageRankThroughAHit() public {
        address b0 = _token();
        address b1 = _token();
        hub.addBridge(b0);
        hub.addBridge(b1);
        _v4On(tA, b0, 100, 1, 0, -20_000, 20_000, uint128(1e24));
        (address c0, address c1) = tA < b0 ? (tA, b0) : (b0, tA);
        bytes32 pid = BPC.computeV4PoolId(c0, c1, 100, 1, address(0));
        (int24 lo, int24 hi) = tA < b0 ? (int24(-20), int24(0)) : (int24(0), int24(20));
        for (int24 t = lo; t < hi; ++t) mgr.addPosition(pid, t, t + 1, 1, 1);
        _v2(b0, b1, 1e24, 1e24);
        _v2(b1, tB, 1e24, 1e24);
        _v2(tA, tB, 5e22, 5e22);
        (uint256 promise_, uint256 rank, ) = BPC.v4WalkRank(address(mgr), pid, 1e22, 100, 1, tA < b0, 0);
        assertLt(promise_ * 10, 1e22, "precondition: the first stage's promise is cut more than tenfold");
        assertGt(rank, 1e22 * 98 / 100, "precondition: the deep walk reads the book");
        // Premise, read on the Solver of 653b1dc (the oracle): the three-hop route leads on its
        // rank. A Solver that hands the order elsewhere fails the comparison.
        RoutePlan memory plan = ref.findBestRoutePlan(tA, tB, 1e22);
        assertEq(plan.best.hops.length, 3, "precondition: the three-hop route over (b0, b1) leads on its rank");
        _row("fragmented first stage, rank through a hit", tA, tB, 1e22);
    }

    /// M10's sixth word starts at zero. Once `_buildHop` has replayed the map of its call to
    /// `BlazePhoenixMath.select`, it moves the free pointer back to where that block began, and
    /// what the block wrote stays above it, `b0` among it (the copy of the rows' tokenOut
    /// balances). The next allocations land on it. A new `_candsOf` entry writes its first five
    /// words and zeroes the sixth, the first stage it keeps (0: none); an entry laid on a balance
    /// would take the balance for the address of a kept build and run out of gas reading it.
    /// The direct pair holds one deep book and n - 1 small books at 0.8 of its rate: the band keeps one and
    /// `_singleLeg` follows, so little is written over the block. tA -> x0 holds two deep books
    /// and x0 -> tB one, and topology 1 makes the (tA, x0) entry. With n = 15 that entry's sixth
    /// word falls on a small book's balance (measured with a probe, reports/plano-1026/onda5/
    /// G52-N1-MED-serie.md); each row more moves the balances 13 words up, so n = 14, 15, 16 meet
    /// the entry under a shift of the layout from 17 words down to 24 words up.
    function test_G52_SameAnswer_NewEntryOverAReleasedBuild() public {
        for (uint256 n = 14; n <= 16; ++n) {
            uint256 s = vm.snapshotState();
            address x0 = _token();
            hub.addBridge(x0);
            address deep = _v2(tA, tB, 1e24, 1e24);
            for (uint256 i = 1; i < n; ++i) _v2(tA, tB, 1e21, 8e20);
            _v2(tA, x0, 1e24, 1e24);
            _v2(tA, x0, 1e24, 1e24);
            _v2(x0, tB, 1e24, 1e24);
            // Premises, read on the Solver of 653b1dc (the oracle): the direct build keeps the
            // deep book alone and leads, and the route over x0 was built (it is the runner-up).
            RoutePlan memory plan = ref.findBestRoutePlan(tA, tB, 1e18);
            assertEq(plan.best.hops.length, 1, "precondition: the direct route leads");
            assertEq(plan.best.hops[0].legs.length, 1, "precondition: the band keeps one book");
            assertEq(plan.best.hops[0].legs[0].pool, deep, "precondition: the deep book");
            assertTrue(plan.hasFallback, "precondition: a runner-up");
            assertEq(plan.fallbackRoute.hops.length, 2, "precondition: the route over x0 was built");
            (bool ok, uint256 gN, uint256 gR) = _same(tA, tB, 1e18, SOLVE_GAS);
            assertTrue(ok, "precondition: both answer at the door's budget");
            emit log_named_uint("rows on the direct pair", n);
            emit log_named_uint("  gas new, cold", gN);
            emit log_named_uint("  gas 653b1dc, cold", gR);
            vm.revertToState(s);
        }
    }

    /// M10 keeps the first stages only. A later stage is built on what the stage before
    /// produced, so each topology builds it again from the pair's list, and that list must reach
    /// it as built: `_candsOf` hands out a copy (gas51), because `_buildHop` compacts the list it
    /// is handed. Two bridges: tA -> b0 is a shallower book (1% of impact on the order), b0 -> tB
    /// three books in seed order (deep, one at 0.8 of the rate, deep), tA -> b1 and b1 -> b0 deep; no pool on
    /// (tA, tB) or (b1, tB). The two-hop route over b0 builds b0 -> tB first: its band drops the
    /// book at 0.8 and the compaction moves the second deep book over it, so the list it was
    /// handed reads [deep, deep', deep']. The three-hop route over (b1, b0) builds b0 -> tB again
    /// as its third stage and leads; handed the compacted list, that stage would seat three legs,
    /// one book promised twice.
    function test_G52_SameAnswer_LaterStageReadsTheListAsBuilt() public {
        address b0 = _token();
        address b1 = _token();
        hub.addBridge(b0);
        hub.addBridge(b1);
        _v2(tA, b0, 1e23, 1e23);
        // The book at 0.8 holds as much tB as the deep ones (its short side, so its registry
        // depth and psi are theirs and the funnel keeps the seed order).
        address[3] memory q = [_v2(b0, tB, 1e24, 1e24), _v2(b0, tB, 1.25e24, 1e24), _v2(b0, tB, 1e24, 1e24)];
        _v2(tA, b1, 1e24, 1e24);
        _v2(b1, b0, 1e24, 1e24);
        _seedOrder(b0, tB, q);
        // Premises, read on the Solver of 653b1dc (the oracle): the three-hop route over (b1, b0)
        // leads and its last stage seats the two deep books; the two-hop route over b0, which
        // built b0 -> tB first, is the runner-up.
        RoutePlan memory plan = ref.findBestRoutePlan(tA, tB, 1e21);
        assertEq(plan.best.hops.length, 3, "precondition: the three-hop route leads");
        assertEq(plan.best.hops[0].tokenOut, b1, "precondition: it opens on b1");
        assertEq(plan.best.hops[2].legs.length, 2, "precondition: its last stage seats the two deep books");
        assertTrue(plan.hasFallback, "precondition: a runner-up");
        assertEq(plan.fallbackRoute.hops.length, 2, "precondition: the two-hop route over b0 is the runner-up");
        assertEq(plan.fallbackRoute.hops[1].legs.length, 2, "precondition: its band dropped the book at 0.8");
        _row("a later stage built by two topologies", tA, tB, 1e21);
    }

    // ─── fuzz ────────────────────────────────────────────────────────────────

    /// A V2 book of depth 1e21..1e24 at one of ten rates around 1 (some inside the band, some
    /// outside), curated or discovered.
    function _v2Rand(address a, address b, uint256 w) internal {
        uint16[10] memory pct = [uint16(100), 100, 101, 99, 103, 97, 106, 94, 120, 80];
        uint256 d = 1e21 * (1 + w % 1000);
        uint256 rb = d * pct[(w >> 16) % 10] / 100;
        if ((w >> 32) % 4 == 0) _v2Found(a, b, d, rb);
        else _v2(a, b, d, rb);
    }

    function _w(uint256 seed, uint256 i) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(seed, i)));
    }

    /// Up to three bridges with books on tIn, tOut and between the bridges, V4 books and amounts
    /// drawn from one seed: both Solvers give the same bytes, both ways, with all the gas and at
    /// the door's budget.
    function testFuzz_G52_SameAnswer(uint256 seed) public {
        uint256 nDirect = seed % 5;
        for (uint256 i; i < nDirect; ++i) _v2Rand(tA, tB, _w(seed, i));
        uint256 nb = (seed >> 8) % 4;
        for (uint256 i; i < nb; ++i) { bridges.push(_token()); hub.addBridge(bridges[i]); }
        for (uint256 i; i < nb; ++i) {
            uint256 nx = 1 + (_w(seed, 50 + i) % 3);
            for (uint256 k; k < nx; ++k) {
                _v2Rand(tA, bridges[i], _w(seed, 100 + 10 * i + k));
                _v2Rand(bridges[i], tB, _w(seed, 200 + 10 * i + k));
            }
            for (uint256 j; j < i; ++j) if (_w(seed, 300 + 10 * i + j) % 2 == 0) _v2Rand(bridges[j], bridges[i], _w(seed, 400 + 10 * i + j));
        }
        if ((seed >> 12) & 1 == 1) _v4(3000, 60, 0, -887220, 887220, uint128(1e22 * (1 + _w(seed, 500) % 1000)));
        if ((seed >> 13) & 1 == 1) {
            int24 t = int24(int256(_w(seed, 501) % 1201)) - 600;
            _v4(100, 1, t, t - 4, t + 4, uint128(1e22 * (1 + _w(seed, 502) % 10_000)));
        }
        uint256 amt = (1 + (seed >> 16) % 9) * 10 ** (15 + (seed >> 24) % 10);
        _same(tA, tB, amt, gasleft());
        _same(tA, tB, amt, SOLVE_GAS);
        _same(tB, tA, amt, gasleft());
        _same(tB, tA, amt, SOLVE_GAS);
    }
}
