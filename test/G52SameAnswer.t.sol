// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// G52 META-GUARD: THE TWO GAS MECHANISMS OF WAVE 5.2 CHANGE NO ANSWER, TO THE WEI.
//
// M10 (Solver._firstStage): the first stage of a bridge route, tIn -> bs[i], is built once per
// solve and every later topology opening on bs[i] reads a copy of that build. M11
// (BlazePhoenixMath._byRate, `_byPrice` since MED): a hop orders its live rates (its prices since
// MED) once, and the plain median and every weighted median of the hop walk that one order
// instead of sorting again.
//
// History: M10 left on 2026-11-06 with the three-hop topologies (MAX_HOPS 2, TOPOLOGIES 4: the
// direct route and one two-hop route over each bridge slot), and `_firstStage` and `_copyHop`
// with it. With two hops no topology of the main loop shares a pair with another, so a kept
// first stage was read by none. What this file guards now is the same answer as the reference,
// to the wei (the reference aligned to TOPOLOGIES 4 and five legs a stage, its header), on the
// shapes M10 decided on, rewritten to two hops; each rewritten row carries its own History note.
//
// `SolverRef653` is the Solver of 653b1dc with its own frozen library `MathRef653` (both
// literal, renamed), and both read the Core of cb1d7d9 frozen as `CoreRefCb1d7d9`, so an answer
// the live Core changes turns a row red, with ONE read excepted: the band's vote. Since MAT-02
// (2026-11-10) a book votes with the tokenOut it declares (the Core's `mass`), a unit the frozen
// Core does not have, so the reference takes the vote's mass and rank from the live Core's
// `universalProbe` (its header says how). The reason is what a differential test is for: it
// fixes everything but the unit under test, and the unit here is the Solver, not the Core. A
// reference voting the short side against a Solver voting the tokenOut side would compare two
// changes at once, and a red row could not say which one moved; the Core's unit is held by
// test/Mat01FunnelMassIsHeld.t.sol, test/Mat02BandVoteIsOneUnit.t.sol and the `massa` mutants.
// Both Solvers read the same Hub and the same state, and each call must come
// back with the same success and the same returndata bytes, with all the gas and at the door's
// budget (SOLVE_GAS). The fixed rows are the shapes the mechanisms decide on: bridge routes over
// every bridge slot, the runner-up handed out beside a leader that walks and falls, held grids
// whose rebuild runs WALK on the leader's topology, V4 books whose cut votes run the median
// three times. The fuzz row draws up to three bridges, books on every pair between tIn, tOut and
// the bridges, V4 books and amounts.
//
// MED (2026-10-28) changes the band by design: it judges prices against the fees that bound
// them (BlazePhoenixMath, THE BAND), where the Solver of 653b1dc judged rates against ±5% of
// their median (MEDIAN_FILTER_BPS), so the two Solvers part wherever the two bands keep
// different books. Every row here is drawn where they cannot: each book either at the market
// or 20% from it. A V2 book at 1.00, the wide V4 book at tick 0 and the narrow one within 20
// ticks of it (0.2%) sit inside both bands with any of them as the base (the tightest edge,
// a 0.3% book under a 0.01% base, is 0.31% before the error bounds widen it, and a probe of
// at most 9e17 moves no V2 book of 1e21 or more by 0.1%, nor leaves the narrow range, which
// holds about L * 2e-4 with L >= 1e22); the books at 1.20 and 0.80 sit outside both from any
// other. Rate order and price order agree across those groups, so the base falls in the same
// group and the kept set is the same; nothing else the hop computes reads the band.
// The rows log the cold gas of both Solvers on the same state.
//
// THE STEP SUBSTITUTED (2026-11-13). The frozen Core's outV3 is no longer the cb1d7d9 body:
// it is Uniswap v3-core's exact-input SwapMath step (test/vendor/SwapMathRef.sol), since the
// live Core quotes one V3/Algebra range with the pool's own step. The oracle is still not the
// code under test; the header of the frozen file says why, and test/OutV3StepParityTriple.t.sol
// pins live, Uniswap and the old body against each other.

import {Test} from "forge-std/Test.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixMath} from "../src/BlazePhoenixMath.sol";
import {BlazePhoenixCore as BPC, RoutePlan, PoolInfo} from "../src/BlazePhoenixCore.sol";
import {SolverRef653} from "./ref/SolverRef653.sol";
import {Frame4007} from "./ref/Frame4007.sol";
import {MathRef653} from "./ref/MathRef653.sol";
import {CoreRefCb1d7d9, RoutePlan as RoutePlanRef} from "./ref/CoreRefCb1d7d9.sol";
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
        touched.push(address(CoreRefCb1d7d9));
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
        // 4007: the floor is attested on the net output since 2026-11-11; the reference's is read
        // in that frame (test/ref/Frame4007.sol), every other field to the byte.
        if (okN) rR = Frame4007.carry(hub, rN, rR);
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

    /// The recorded accesses of one cold solve of `s`.
    function _accesses(address s, bytes memory q) internal returns (VmSafe.AccountAccess[] memory recs) {
        _cool();
        vm.startStateDiffRecording();
        (bool ok, ) = s.staticcall(q);
        recs = vm.stopAndReturnStateDiff();
        assertTrue(ok, "precondition: the row has a route");
    }

    /// Calls and static calls into any of `pools` among `recs`.
    function _reads(VmSafe.AccountAccess[] memory recs, address[] memory pools) internal pure returns (uint256 c) {
        for (uint256 i; i < recs.length; ++i) {
            if (recs[i].kind != VmSafe.AccountAccessKind.Call && recs[i].kind != VmSafe.AccountAccessKind.StaticCall) continue;
            for (uint256 k; k < pools.length; ++k) if (recs[i].account == pools[k]) { ++c; break; }
        }
    }

    /// Registry reads of the pair (a, b), either order (`Hub.getActivePools`), among `recs`.
    function _listed(VmSafe.AccountAccess[] memory recs, address a, address b) internal view returns (uint256 c) {
        for (uint256 i; i < recs.length; ++i) {
            bytes memory d = recs[i].data;
            if (recs[i].account != address(hub) || d.length < 0x44) continue;
            if (bytes4(d) != BlazePhoenixHub.getActivePools.selector) continue;
            address x;
            address y;
            assembly ("memory-safe") { x := mload(add(d, 0x24)) y := mload(add(d, 0x44)) }
            if ((x == a && y == b) || (x == b && y == a)) ++c;
        }
    }

    /// Each pair is read once in the main loop, and its books as often as by the reference.
    /// Three bridges, two books on every pair, the pairs between two bridges included. The four
    /// topologies read tIn -> tOut and, over each bridge, tIn -> bs[i] and bs[i] -> tOut: each of
    /// those pairs is listed from the registry once per solve, and both Solvers call its books
    /// the same number of times. A pair between two bridges sits on no two-hop route: neither
    /// Solver lists it or calls its books. A stage quoted twice where the rank before it did not
    /// rise above its promise (the S2 pass run on every stage) calls its books twice.
    /// History: until 2026-11-06 this row was M10's, `test_G52_EachFirstStageIsBuiltOnce`: the
    /// Solver of 653b1dc built each first stage in three topologies (the two-hop one and the two
    /// three-hop ones over bs[i]), the Solver once, and the Solver called the first-stage books
    /// less (fN < fR). With two hops both build each first stage once: 30 calls each.
    function test_G52_EachPairIsReadOnce() public {
        address[3] memory b = [_token(), _token(), _token()];
        for (uint256 i; i < 3; ++i) hub.addBridge(b[i]);
        address[] memory direct = new address[](2);
        address[] memory first = new address[](6);
        address[] memory last = new address[](6);
        address[] memory between = new address[](6);
        for (uint256 k; k < 2; ++k) {
            direct[k] = _v2(tA, tB, 5_000e18 * (k + 1), 5_000e18 * (k + 1));
            for (uint256 i; i < 3; ++i) {
                first[2 * i + k] = _v2(tA, b[i], 300_000e18 * (k + 1), 300_000e18 * (k + 1));
                last[2 * i + k] = _v2(b[i], tB, 300_000e18 * (k + 1), 300_000e18 * (k + 1));
                for (uint256 j; j < i; ++j) {
                    between[2 * (i * (i - 1) / 2 + j) + k] = _v2(b[j], b[i], 200_000e18 * (k + 1), 200_000e18 * (k + 1));
                }
            }
        }
        bytes memory q = abi.encodeCall(BlazePhoenixSolver.findBestRoutePlan, (tA, tB, 1_000e18));
        VmSafe.AccountAccess[] memory rN = _accesses(address(solver), q);
        VmSafe.AccountAccess[] memory rR = _accesses(address(ref), q);
        emit log_named_uint("direct book reads, 653b1dc", _reads(rR, direct));
        emit log_named_uint("direct book reads, now", _reads(rN, direct));
        emit log_named_uint("first-stage book reads, 653b1dc", _reads(rR, first));
        emit log_named_uint("first-stage book reads, now", _reads(rN, first));
        emit log_named_uint("last-stage book reads, 653b1dc", _reads(rR, last));
        emit log_named_uint("last-stage book reads, now", _reads(rN, last));
        assertGt(_reads(rR, first), 0, "precondition: the reference reads the first-stage books");
        assertEq(_reads(rN, direct), _reads(rR, direct), "the direct books are called as by the reference");
        assertEq(_reads(rN, first), _reads(rR, first), "the first-stage books are called as by the reference");
        assertEq(_reads(rN, last), _reads(rR, last), "the last-stage books are called as by the reference");
        assertEq(_reads(rN, between), 0, "no two-hop route calls a book between two bridges");
        assertEq(_reads(rR, between), 0, "no two-hop route calls a book between two bridges (reference)");
        assertEq(_listed(rN, tA, tB), 1, "the direct pair is listed once per solve");
        for (uint256 i; i < 3; ++i) {
            assertEq(_listed(rN, tA, b[i]), 1, "each first-stage pair is listed once per solve");
            assertEq(_listed(rN, b[i], tB), 1, "each last-stage pair is listed once per solve");
            for (uint256 j; j < i; ++j) assertEq(_listed(rN, b[j], b[i]), 0, "no pair between two bridges is listed");
        }
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

    /// The band's base decides the route: three books whose rates are further apart than
    /// either band (±5% at 653b1dc, the band of no arbitrage since MED), listed so that row
    /// order and rate order differ, and the
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

    /// The runner-up handed out beside a leader that walks and falls. Two bridges, the
    /// runner-up's b1 in the slot before the leader's b0, so the leader displaces it in the
    /// judgement (`_considera`). tA -> b0 is a thick tick one step deep (a book whose promise
    /// falls on its walk, test/V3PromiseIsWhatThePoolPays.t.sol's) beside a small V2 pair, and
    /// b0 -> tB a deep V2 pair; tA -> b1 -> tB are deep V2 pairs at 0.99. The leader's walk
    /// (`_paysWhatItWalks`) writes what its books pay into its legs after the runner-up was read
    /// as the fallback, and its fallen book sends the solve into the rebuild that drops it (N1):
    /// the fallback must come back as the runner-up was built, over b1, not as the leader walked.
    /// History: until 2026-11-06 this row was `test_G52_SameAnswer_RunnerUpSharesTheWalkedFirstStage`:
    /// three bridges, the leader and the runner-up both opening on b0 through three hops, each
    /// reading the first stage M10 kept, and its copy (`_copyHop`, [930] [936] [937]) kept the
    /// walk out of the fallback. With two hops no two routes share a stage.
    function test_G52_SameAnswer_RunnerUpBesideAFallenLeader() public {
        address b0 = _token();
        address b1 = _token();
        hub.addBridge(b1);
        hub.addBridge(b0);
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
        _v2(b0, tB, 1e21, 1e21);
        _v2(tA, b1, 1e21, 0.99e21);
        _v2(b1, tB, 1e21, 1e21);
        // Premises, read on the Solver of 653b1dc (the oracle): the leader opens on b0, the
        // runner-up on b1, and the leader's book fell on its walk (the self-call that drops
        // books, calldata past 0xa4, runs). A Solver that answers otherwise fails the comparison.
        RoutePlanRef memory plan = ref.findBestRoutePlan(tA, tB, 1e18);
        assertEq(plan.best.hops.length, 2, "precondition: a bridge route leads");
        assertEq(plan.best.hops[0].tokenOut, b0, "precondition: the leader opens on b0");
        assertTrue(plan.hasFallback, "precondition: a runner-up is handed out");
        assertEq(plan.fallbackRoute.hops.length, 2, "precondition: the runner-up is a bridge route");
        assertEq(plan.fallbackRoute.hops[0].tokenOut, b1, "precondition: the runner-up opens on b1");
        (, bool drops) = _rebuilds(address(ref), tA, tB, 1e18);
        assertTrue(drops, "precondition: the leader's first-stage book fell on its walk (N1)");
        _row("runner-up beside a leader that walked and fell", tA, tB, 1e18);
    }

    /// M11's one order lists the LIVE rows only, and the weighted median sums and walks exactly
    /// those. Three rows in seed order (one registry depth bucket, so equal psi, and the same fee:
    /// the funnel keeps that order): a book at ~1.10, a book whose probe pays nothing (rate 0, the
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
    /// History: until 2026-11-10 the books at 1.00 were (300e18, 300e18) and (350e18, 350e18) and
    /// a vote was the book's short side. A vote is the tokenOut the book holds (MAT-02), 330e18
    /// and 550e18 for the books at 1.10, so the books at 1.00 moved to keep the votes 1 : 1 and
    /// 1 : 0.7.
    function test_G52_SameAnswer_MedianWalksTheLiveRowsOnly() public {
        address[3] memory x = [
            _v2(tA, tB, 300e18, 330e18),   // ~1.10, vote 330e18
            _v2(tA, tB, 5e33, 300e18),     // dead at the probe: 1e13 * 300e18 / 5e33 < 1
            _v2(tA, tB, 330e18, 330e18)    // ~1.00, vote 330e18
        ];
        address c = _token();
        address d = _token();
        address[3] memory y = [
            _v2(c, d, 500e18, 550e18),     // ~1.10, vote 550e18
            _v2(c, d, 5e33, 300e18),       // dead
            _v2(c, d, 385e18, 385e18)      // ~1.00, vote 385e18 = 0.7 x 550e18
        ];
        // Premises, read on the Solver of 653b1dc (the oracle, so they hold whatever the Solver
        // under test does and a mutant of it fails the comparison): the funnel keeps the seed
        // order (equal psi, equal fee), and the band keeps the book the base names: 1.00 in X,
        // 1.10 in Y.
        _seedOrder(tA, tB, x);
        _seedOrder(c, d, y);
        RoutePlanRef memory px = ref.findBestRoutePlan(tA, tB, 1e15);
        RoutePlanRef memory py = ref.findBestRoutePlan(c, d, 1e15);
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

    /// A held first stage asks for the WALK rebuild. One bridge; tA -> b0 is a V3 book holding
    /// 1.5e18 of b0, so a 1e18 order quotes ~0.996e18, above its cap (30% of what it holds) and
    /// under what it holds: the book is held. b0 -> tB is a deep V2 pair; no pool on (tA, tB).
    /// The route over b0 leads, held by its first stage alone (`_planViaBridges` carries the
    /// mark of each stage into `held`); held, the leader is rebuilt with WALK on its own budget
    /// and the walked route (~0.99e18 against ~0.45e18 at the cap) is the answer: a route that
    /// dropped its first stage's mark would skip the rebuild and answer the cap.
    /// History: until 2026-11-06 this row was `test_G52_SameAnswer_HeldFirstStageReadByAHit`:
    /// two bridges, and the three-hop route over (b0, b1) led on the first stage M10 kept for it
    /// (the hit), whose held flag the kept build carried ([940]). With two hops the stage is
    /// built by the one route that reads it, and its mark travels in `held`.
    function test_G52_SameAnswer_HeldFirstStageAsksTheWalk() public {
        address b0 = _token();
        hub.addBridge(b0);
        MockV3TickPool q = new MockV3TickPool(tA, b0, 3000, 60);
        q.initialize(0);
        q.addPosition(-887220, 887220, 1e21);
        MockERC20(tA).mint(address(q), 1e21);
        MockERC20(b0).mint(address(q), 1.5e18);
        hub.seedPool(address(q), BPC.KIND_V3, 3000, address(0), tA, b0);
        touched.push(address(q));
        _v2(b0, tB, 1e21, 1e21);
        // Premises, read on the Solver of 653b1dc (the oracle): the answer is the two-hop route
        // walked past its cap, and it came from the rebuild the held flag asks for (the
        // self-call's bk carries bit 8). A Solver that answers otherwise fails the comparison.
        RoutePlanRef memory plan = ref.findBestRoutePlan(tA, tB, 1e18);
        assertEq(plan.best.hops.length, 2, "precondition: the two-hop route over b0 leads");
        assertEq(plan.best.hops[0].tokenOut, b0, "precondition: it opens on b0");
        assertGt(plan.best.hops[0].expectedOut, 0.9e18, "precondition: the answer is the walked build, past the cap");
        (bool walk, ) = _rebuilds(address(ref), tA, tB, 1e18);
        assertTrue(walk, "precondition: the held leader is rebuilt with WALK");
        _row("held first stage asks the walk", tA, tB, 1e18);
    }

    /// The self-calls of one solve of `s`: `walk` when one carries the rebuild bit (bk >> 8 != 0,
    /// `findBestRoutePlan`), `drops` when one carries books past bk and u (calldata past 0xa4,
    /// the books whose promise fell, N1).
    function _rebuilds(address s, address a, address b, uint256 amt) internal returns (bool walk, bool drops) {
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
            if (bk >> 8 != 0) walk = true;
            if (dta.length > 0xa4) drops = true;
        }
    }

    /// A fragmented first stage leads on its RANK (test/V4FragmentationRanking.t.sol's Q2m
    /// book). tA -> b0 is an honest V4 book with one-wei dust on the twenty ticks the order walks
    /// first, so its sixteen-stretch promise is cut more than tenfold while the deep walk reads
    /// the book; b0 -> tB is a deep V2 pair and tA -> tB a shallower V2 pair (~8.3e21). The
    /// route over b0 quotes its second stage again on the first stage's rank (S2) and is judged
    /// on `r - p` above its promise (`_considera`): judged on its promise, or on a lift clamped
    /// to it, it would hand the order to the shallower direct pair.
    /// History: until 2026-11-06 this row was `test_G52_SameAnswer_FragmentedFirstStageRankThroughAHit`:
    /// two bridges, and the three-hop route over (b0, b1) led on the first stage M10 kept for it
    /// (the hit), whose rank the kept build carried ([941]). With two hops the stage is built by
    /// the one route that reads it, and its rank travels in `r`.
    function test_G52_SameAnswer_FragmentedFirstStageLeadsOnItsRank() public {
        address b0 = _token();
        hub.addBridge(b0);
        _v4On(tA, b0, 100, 1, 0, -20_000, 20_000, uint128(1e24));
        (address c0, address c1) = tA < b0 ? (tA, b0) : (b0, tA);
        bytes32 pid = BPC.computeV4PoolId(c0, c1, 100, 1, address(0));
        (int24 lo, int24 hi) = tA < b0 ? (int24(-20), int24(0)) : (int24(0), int24(20));
        for (int24 t = lo; t < hi; ++t) mgr.addPosition(pid, t, t + 1, 1, 1);
        _v2(b0, tB, 1e24, 1e24);
        _v2(tA, tB, 5e22, 5e22);
        (uint256 promise_, uint256 rank, ) = BPC.v4WalkRank(address(mgr), pid, 1e22, 100, 1, tA < b0, 0);
        assertLt(promise_ * 10, 1e22, "precondition: the first stage's promise is cut more than tenfold");
        assertGt(rank, 1e22 * 98 / 100, "precondition: the deep walk reads the book");
        // Premises, read on the Solver of 653b1dc (the oracle): the two-hop route leads on its
        // rank, the direct pair behind it. A Solver that hands the order elsewhere fails the
        // comparison.
        RoutePlanRef memory plan = ref.findBestRoutePlan(tA, tB, 1e22);
        assertEq(plan.best.hops.length, 2, "precondition: the two-hop route over b0 leads on its rank");
        assertTrue(plan.hasFallback, "precondition: a runner-up");
        assertEq(plan.fallbackRoute.hops.length, 1, "precondition: the direct pair is the runner-up");
        _row("fragmented first stage leads on its rank", tA, tB, 1e22);
    }

    /// A new `_candsOf` entry laid on a released build writes every word that is read of it.
    /// Once `_buildHop` has replayed the map of its call to `BlazePhoenixMath.select`, it moves
    /// the free pointer back to where that block began, and what the block wrote stays above it
    /// (the copy of the rows' tokenOut balances among it). The next allocations land on it. A new
    /// entry writes its five words [next, tA, tB, list, decimals]; one that left its link
    /// unwritten would hand the walk of the chain a stale word for the address of the entry
    /// before it, and a balance read as an address runs the solve out of gas. The direct pair
    /// holds one deep book and n - 1 small books at 0.8 of its rate: the band keeps one and
    /// `_singleLeg` follows, so little is written over the block. tA -> x0 holds two deep books
    /// and x0 -> tB one; topology 1 lays the (tA, x0) entry over the direct build's released
    /// block, and the (x0, tB) read walks the chain through it. n = 14, 15, 16 lay the entry
    /// over three layouts of that block.
    /// History: until 2026-11-06 the entry had a sixth word, the first stage M10 kept (0: none),
    /// which `_candsOf` zeroed; with n = 15 it fell on a small book's balance (measured with a
    /// probe, reports/plano-1026/onda5/G52-N1-MED-serie.md), and an entry that kept it unzeroed
    /// took the balance for a kept build and ran out of gas reading it. The sixth word left with M10.
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
            RoutePlanRef memory plan = ref.findBestRoutePlan(tA, tB, 1e18);
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

    // History: until 2026-11-06 `test_G52_SameAnswer_LaterStageReadsTheListAsBuilt` built b0 -> tB
    // in two topologies (the last stage of a two-hop and of a three-hop route) and killed gas51
    // [821], the kept list handed out itself. With two hops the only pair read twice in one solve
    // is the rebuild's, in the self-call: [821] is killed in test/SolveBuildsEachPairOnce.t.sol.

    // ─── fuzz ────────────────────────────────────────────────────────────────

    /// A V2 book of depth 1e21..1e24 at the market or 20% from it (header: until MED it drew
    /// ten rates, 1-6% from 1 among them, which the two bands now judge apart), curated or
    /// discovered.
    function _v2Rand(address a, address b, uint256 w) internal {
        uint16[4] memory pct = [uint16(100), 100, 120, 80];
        uint256 d = 1e21 * (1 + w % 1000);
        uint256 rb = d * pct[(w >> 16) % 4] / 100;
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
            int24 t = int24(int256(_w(seed, 501) % 41)) - 20;   // 600 ticks until MED (header)
            _v4(100, 1, t, t - 4, t + 4, uint128(1e22 * (1 + _w(seed, 502) % 10_000)));
        }
        uint256 amt = (1 + (seed >> 16) % 9) * 10 ** (15 + (seed >> 24) % 5);   // to 9e24 until MED (header)
        _same(tA, tB, amt, gasleft());
        _same(tA, tB, amt, SOLVE_GAS);
        _same(tB, tA, amt, gasleft());
        _same(tB, tA, amt, SOLVE_GAS);
    }
}
