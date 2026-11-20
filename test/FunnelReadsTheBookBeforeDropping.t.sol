// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// 4660 (Solver._dropDust): the funnel dropped a V4 book that is thin on its current tick and
// deep next to it, before it was ever quoted. Red at 2c8cbbe.
//
// WHAT WAS WRONG. A singleton book's own mass in the dust rule was its declared side
// (`Core.hopMass18` -> `outSide18`, the current tick's liquidity alone), and the walk that
// reads what the book holds (`Solver._heldBooks`) was made only when a row was dropped at the
// largest D and kept at the smallest, and could only LOWER a figure. A book whose current tick
// is under the 25 ppm bar failed the second condition, so it was dropped UNREAD; and when it
// was read, a walk holding more than the declared side changed nothing.
//
// WHAT IS MEASURED NOW. A singleton row that fails the keep test on its declared side triggers
// the walk (a book that declares mass is never dropped unread; an empty current tick is 4660-B), and the walk's figure is written in both
// directions: what the book adds to the other rows' D is what it holds, and its own mass is
// never under what it holds (it is never cut below its declared side either: a walk cut by
// one-wei positions does not unseat an honest book, test_Funnel_ASingletonBookWhoseWalkDustCutKeepsItsSeat).

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixQuoter} from "../src/BlazePhoenixQuoter.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, RoutePlan} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";
import {MockV4TickManager} from "./mocks/MockV4TickManager.sol";
import {PathologicalERC20} from "./mocks/PathologicalERC20.sol";

contract FunnelReadsTheBookBeforeDroppingTest is Test {
    int24 internal constant TS = 60;
    uint256 internal constant AMT = 100_000e18;       // walks deep into a neighbour range
    uint256 internal constant SMALL = 1e15;           // fits the current tick of any book here
    uint256 internal constant PAIR = 100_000e18;      // the V2 incumbent's reserves, each side
    uint256 internal constant GAMMA_PPM = 25;         // MIN_SPLIT_IMPROVEMENT_PPM
    uint256 internal constant SOLVE_GAS = 14_700_000; // BPC.SOLVE_GAS

    BlazePhoenixHub internal hub;
    BlazePhoenixSolver internal solver;
    BlazePhoenixQuoter internal quoter;
    BlazePhoenixRouter internal router;
    MockV4TickManager internal mgr;
    MockV2Pair internal pair;
    MockERC20 internal t0;
    MockERC20 internal t1;
    address internal user = address(0xD05);

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
        pair = new MockV2Pair(address(t0), address(t1));
        t0.mint(address(pair), PAIR);
        t1.mint(address(pair), PAIR);
        pair.setReserves(uint112(PAIR), uint112(PAIR));
        hub.seedPool(address(pair), BPC.KIND_V2, 30, address(0), address(t0), address(t1));
        t1.mint(address(mgr), 1e30);
        t0.mint(user, 1e27);
        vm.prank(user);
        t0.approve(address(router), type(uint256).max);
    }

    // A hookless V4 book priced at tick 1: `liqNow` on the current tick [0, 60), `liqDeep` on
    // the range just under it [-6000, 0), into which a zeroForOne order walks.
    function _book(uint24 fee, uint128 liqNow, uint128 liqDeep) internal returns (bytes32 pid) {
        pid = BPC.computeV4PoolId(address(t0), address(t1), fee, TS, address(0));
        mgr.initialize(pid, mgr.sqrtAt(1), 1, fee);
        if (liqNow != 0) mgr.addPosition(pid, 0, 60, TS, liqNow);
        if (liqDeep != 0) mgr.addPosition(pid, -6000, 0, TS, liqDeep);
        hub.addV4(address(t0), address(t1), fee, TS, address(0));
    }

    function _legs(Route memory r, bytes32 pid) internal pure returns (uint256) {
        return _legsAt(r, address(uint160(uint256(pid))));
    }

    function _legsAt(Route memory r, address p) internal pure returns (uint256 k) {
        for (uint256 x; x < r.hops.length; ++x)
            for (uint256 y; y < r.hops[x].legs.length; ++y)
                if (r.hops[x].legs[y].pool == p) ++k;
    }

    function _plan(uint256 amt) internal returns (Route memory plan, uint256 out) {
        (plan, out) = quoter.previewPlanExact(address(t0), address(t1), amt);
    }

    // ---- the finding --------------------------------------------------------------------

    /// Current tick 1e18 (its declared side is dust against the pair: 1e24 < 25 * 1e23), the
    /// range under it 1e24. The plan must seat the book and pay more than the pair alone.
    function test_ThinCurrentTickDeepNeighbourBookKeepsItsSeat() public {
        (, uint256 pairOnly) = _plan(AMT);
        bytes32 pid = _book(3000, 1e18, 1_000_000e18);
        (, uint256 held, ) = BPC.v4WalkRank(address(mgr), pid, type(uint256).max, 0, TS, true, type(uint256).max);
        assertLt(uint256(1e18) * 1e6, GAMMA_PPM * PAIR, "fixture: the current tick alone is under the bar");
        assertGt(held * 1e6, GAMMA_PPM * PAIR, "fixture: what the book holds is far over the bar");
        (Route memory plan, uint256 out) = _plan(AMT);
        emit log_named_uint("pair_only_out", pairOnly);
        emit log_named_uint("plan_out", out);
        assertGt(_legs(plan, pid), 0, "a deep book thin on its current tick was dropped unread");
        assertGt(out, pairOnly, "the plan pays no more than the pair alone");
        vm.prank(user);
        uint256 settled = router.swapExactIn(plan, AMT, 1, user, block.timestamp + 1);
        assertGt(settled, pairOnly, "the seated book settles above the pair alone");
    }

    /// THE RESIDUAL, PINNED (follow-up 4660-B). The current tick holds NOTHING (the price sits
    /// in a gap), the range under it holds 400,000 times the pair. The probe does not quote a
    /// book with an empty current tick, so the funnel must not weigh it either: walked, it would
    /// make the pair dust and then go unquoted itself, leaving the hop with no route. A one-wei
    /// book beside it makes the walk of the hop happen. Green at 2c8cbbe.
    function test_EmptyCurrentTickBookWeighsOnNobody() public {
        (, uint256 pairOnly) = _plan(AMT);
        bytes32 pid = _book(3000, 0, 1e30);
        _book(500, 1, 1);
        (, uint256 held, ) = BPC.v4WalkRank(address(mgr), pid, type(uint256).max, 0, TS, true, type(uint256).max);
        assertGt(GAMMA_PPM * held, PAIR * 1e6, "fixture: against what the book holds the pair is dust");
        (Route memory plan, uint256 out) = _plan(AMT);
        assertGt(_legsAt(plan, address(pair)), 0, "a book the probe cannot quote unseated the pair");
        assertEq(out, pairOnly, "the plan moved");
    }

    // ---- controls -----------------------------------------------------------------------

    /// Thin current tick AND thin range under it: walked, held under the bar, dropped. A small
    /// order, which a kept book priced 1 bp better would take, still routes on the pair alone.
    function test_TrueDustBookIsStillDropped() public {
        (, uint256 pairOnly) = _plan(SMALL);
        bytes32 pid = _book(3000, 1e18, 1e18);
        (Route memory plan, uint256 out) = _plan(SMALL);
        assertEq(_legs(plan, pid), 0, "a book holding dust kept its seat");
        assertEq(out, pairOnly, "the plan moved although the book is dust");
    }

    /// Current tick over the bar: kept with or without the walk (green on both trees).
    function test_CurrentTickAboveBarKept() public {
        (, uint256 pairOnly) = _plan(AMT);
        bytes32 pid = _book(3000, 1e18 + 1e19, 1_000_000e18);
        (Route memory plan, uint256 out) = _plan(AMT);
        assertGt(_legs(plan, pid), 0, "a book over the bar was dropped");
        assertGt(out, pairOnly, "the plan pays no more than the pair alone");
    }

    /// A book whose walk finds nothing of tokenOut (its liquidity sits wholly above the price, on
    /// the side a zeroForOne order never reaches) adds nothing to the pair's D and drops nobody.
    function test_BookThatDoesNotAnswerIsNotCountedAsMass() public {
        (, uint256 pairOnly) = _plan(SMALL);
        bytes32 pid = BPC.computeV4PoolId(address(t0), address(t1), 3000, TS, address(0));
        mgr.initialize(pid, mgr.sqrtAt(1), 1, 3000);
        mgr.addPosition(pid, 0, 60, TS, 1);                          // the current tick: one wei
        mgr.addPosition(pid, 60, 600_000, TS, type(uint128).max / 4); // all of it above the price
        hub.addV4(address(t0), address(t1), 3000, TS, address(0));
        (Route memory plan, uint256 out) = _plan(SMALL);
        assertGt(_legsAt(plan, address(pair)), 0, "the honest pair was dropped by a book holding nothing");
        assertEq(out, pairOnly, "the plan moved");
    }

    /// MAT-01 non-regression: K one-wei books (each now walked) beside the honest pair. Their
    /// walks hold ~0, so the pair keeps its seat and no one-wei book is quoted.
    function test_AttackerBookWithNoHeldMassStillDropsNobody() public {
        (, uint256 pairOnly) = _plan(AMT);
        uint24[3] memory fees = [uint24(500), 100, 10000];
        bytes32[3] memory pids;
        for (uint256 k; k < 3; ++k) pids[k] = _book(fees[k], 1, 1);
        (Route memory plan, uint256 out) = _plan(AMT);
        assertGt(_legsAt(plan, address(pair)), 0, "one-wei books dropped the honest pair");
        for (uint256 k; k < 3; ++k) assertEq(_legs(plan, pids[k]), 0, "a one-wei book was quoted");
        assertEq(out, pairOnly, "one-wei books moved the plan");
    }

    // ---- fuzz: the seat follows the measurement ------------------------------------------

    /// liqNow 1 .. bar +- 1 region .. 1e20 (0, an empty current tick, is the probe's: 4660-B);
    /// liqDeep 0 .. 1e24. Oracle: the walk (Core) and
    /// the declared side, both read outside the Solver. Held far over the bar => seated for an
    /// order that reaches it; both under the bar => the small order routes on the pair alone.
    function testFuzz_TheSeatFollowsWhatTheBookHolds(uint128 liqNow, uint128 liqDeep) public {
        liqNow = uint128(bound(liqNow, 1, 1e20));
        liqDeep = uint128(bound(liqDeep, 0, 1e24));
        (, uint256 pairOnly) = _plan(SMALL);
        bytes32 pid = _book(3000, liqNow, liqDeep);
        (, uint256 held, ) = BPC.v4WalkRank(address(mgr), pid, type(uint256).max, 0, TS, true, type(uint256).max);
        // the current tick [0,60) at tick 1 declares about liqNow of token1 (sqrt ~ 1)
        uint256 bar = GAMMA_PPM * PAIR / 1e6;
        if (held >= 100 * bar && liqDeep >= 1e22) {
            (Route memory plan, ) = _plan(AMT);
            assertGt(_legs(plan, pid), 0, "a book holding over 100x the bar was dropped");
        } else if (held * 10 < bar && uint256(liqNow) * 10 < bar) {
            (Route memory plan, uint256 out) = _plan(SMALL);
            assertEq(_legs(plan, pid), 0, "a book holding under a tenth of the bar was seated");
            assertEq(out, pairOnly, "a dust book moved the plan");
        }
    }

    // ---- gas: one walk per book, paid once per hop ----------------------------------------

    /// SOLVE_GAS: the deep book plus K one-wei books (each failing on its declared side, so the
    /// walk is now always made). The whole search must stay far inside SOLVE_GAS.
    function test_Gas_OneWeiBooksBesideADeepBookFitSolveGas() public {
        _book(3000, 1e18, 1_000_000e18);
        uint24[3] memory fees = [uint24(500), 100, 10000];
        for (uint256 k; k < 3; ++k) _book(fees[k], 1, 1);
        uint256 g = gasleft();
        RoutePlan memory p = solver.findBestRoutePlan(address(t0), address(t1), AMT);
        uint256 used = g - gasleft();
        emit log_named_uint("solve_gas_deep_plus_3_one_wei_books", used);
        assertGt(p.best.totalOut, 0, "no plan");
        assertLt(used, SOLVE_GAS / 4, "the search over four books takes over a quarter of SOLVE_GAS");
    }

    function test_Gas_FourOneWeiBooksBesideThePairFitSolveGas() public {
        uint24[4] memory fees = [uint24(3000), 500, 100, 10000];
        for (uint256 k; k < 4; ++k) _book(fees[k], 1, 1);
        uint256 g = gasleft();
        solver.findBestRoutePlan(address(t0), address(t1), AMT);
        uint256 used = g - gasleft();
        emit log_named_uint("solve_gas_pair_plus_4_one_wei_books", used);
        assertLt(used, SOLVE_GAS / 4, "four one-wei books take over a quarter of SOLVE_GAS");
    }

    /// The worst a pair can hold: the incumbent plus fifteen one-wei books (MAX_SLOTS 16). Every
    /// book is walked once, in one `_heldBooks` pass for the hop.
    function test_Gas_FifteenOneWeiBooksFillThePair() public {
        for (uint256 k; k < 15; ++k) _book(uint24(101 + 100 * k), 1, 1);
        uint256 g = gasleft();
        RoutePlan memory p = solver.findBestRoutePlan(address(t0), address(t1), AMT);
        uint256 used = g - gasleft();
        emit log_named_uint("solve_gas_pair_plus_15_one_wei_books", used);
        assertGt(p.best.totalOut, 0, "no plan");
        assertLt(used, SOLVE_GAS / 4, "a full pair of one-wei books takes over a quarter of SOLVE_GAS");
    }

    /// The same worst pair reachable BEFORE this fix: one book declaring far over the pair (its
    /// current tick deep) puts the pair's own row in the bracket, which walked every book. Runs
    /// on both trees; the walk count per pair is the same, so the worst case does not move.
    function test_Gas_FullPairWalkedThroughTheOldBracket() public {
        _book(3000, 1e28, 0);
        for (uint256 k; k < 14; ++k) _book(uint24(101 + 100 * k), 1, 1);
        uint256 g = gasleft();
        solver.findBestRoutePlan(address(t0), address(t1), AMT);
        uint256 used = g - gasleft();
        emit log_named_uint("solve_gas_bracket_book_plus_14_one_wei_books", used);
        assertLt(used, SOLVE_GAS / 4, "a full pair walked through the bracket takes over a quarter of SOLVE_GAS");
    }

    // ---- range: a walk past 2^128 is capped like a declared side ---------------------------

    /// tokenOut with 0 decimals (to18 multiplies by 1e18) and a book whose walk over the funnel's
    /// horizon (two stretches) pays past 2^256 / 1e24 units: uncapped, `d * 1e6` leaves uint256
    /// and the whole search reverts. A one-wei book beside it makes the walk happen. The mass is
    /// capped at 2^128 - 1, as `outSide18` caps.
    function test_AWalkPastUint128IsCappedAndTheSearchStands() public {
        PathologicalERC20 a = new PathologicalERC20("A", "A", 18);
        PathologicalERC20 z = new PathologicalERC20("Z", "Z", 0);
        while (address(a) > address(z)) a = new PathologicalERC20("A", "A", 18);
        MockV2Pair p = new MockV2Pair(address(a), address(z));
        a.mint(address(p), 1e30);
        z.mint(address(p), 1e30);
        p.setReserves(uint112(1e30), uint112(1e30));
        hub.seedPool(address(p), BPC.KIND_V2, 30, address(0), address(a), address(z));
        bytes32 deep = BPC.computeV4PoolId(address(a), address(z), 3000, TS, address(0));
        mgr.initialize(deep, mgr.sqrtAt(800_040), 800_040, 3000);
        mgr.addPosition(deep, 799_980, 800_100, TS, 1);
        mgr.addPosition(deep, 700_020, 799_980, TS, type(uint128).max / 2);
        hub.addV4(address(a), address(z), 3000, TS, address(0));
        bytes32 dust = BPC.computeV4PoolId(address(a), address(z), 500, TS, address(0));
        mgr.initialize(dust, mgr.sqrtAt(1), 1, 500);
        mgr.addPosition(dust, 0, 60, TS, 1);
        hub.addV4(address(a), address(z), 500, TS, address(0));
        uint256 held = BPC.v4Held(address(mgr), deep, TS, true, 2);
        emit log_named_uint("deep_walk_raw", held);
        assertGt(held, type(uint256).max / 1e24, "fixture: the funnel's walk, uncapped, leaves uint256 at d * 1e6");
        solver.findBestRoutePlan(address(a), address(z), 1e18);
    }

    // ---- dust books do not buy the search's walks (4660 dust) -----------------------------
    //
    // A walk is the dearest read of the funnel and a one-wei book buys the dearest walk there
    // is (sixteen empty words). The walks are therefore spent in order of declared capital,
    // largest first, and the hop stops walking when the books a walk proved to be dust are as
    // many as the rows seated on a measurement. A book left unread is decided on its declared
    // side and adds nothing to the other rows' D.

    /// Slots of the manager the search reads, and the gas of the search.
    function _reads(uint256 amt) internal returns (uint256 n, uint256 gasUsed) {
        vm.record();
        uint256 g = gasleft();
        solver.findBestRoutePlan(address(t0), address(t1), amt);
        gasUsed = g - gasleft();
        (bytes32[] memory rd, ) = vm.accesses(address(mgr));
        n = rd.length;
    }

    /// Slots one declared-side read (`Core.hopMass18`) and one walk make on `pid`.
    function _readsOfOneBook(bytes32 pid) internal returns (uint256 mass, uint256 walk) {
        vm.record();
        BPC.hopMass18(address(uint160(uint256(pid))), BPC.KIND_V4, address(t0), address(t1), true, 18, address(mgr), pid);
        (bytes32[] memory rd, ) = vm.accesses(address(mgr));
        mass = rd.length;
        vm.record();
        BPC.v4WalkRank(address(mgr), pid, type(uint256).max, 0, TS, true, type(uint256).max);
        (rd, ) = vm.accesses(address(mgr));
        walk = rd.length;
    }

    /// COUNTED. Two one-wei books beside the pair: the search reads two declared sides and two
    /// walks of the funnel's horizon (two stretches) on the manager, exactly. Each book is walked
    /// once, and a dropped book is not probed.
    function test_EachBookUnderTheBarIsWalkedOnce() public {
        (uint256 r0, ) = _reads(AMT);
        bytes32 a = _book(500, 1, 1);
        _book(100, 1, 1);
        (uint256 r2, ) = _reads(AMT);
        (uint256 mass, ) = _readsOfOneBook(a);
        uint256 walk = _walkReads(a, 2);
        assertGt(walk, mass, "fixture: a walk reads more than a declared side");
        assertEq(r2 - r0, 2 * mass + 2 * walk, "two one-wei books cost other than two declared sides and two walks");
    }

    /// NO QUEUE. Fourteen one-wei books registered BEFORE the thin-tick book: every book under
    /// the bar is walked, so the books ahead of it do not stand between it and its seat.
    function test_ThinTickBookIsReadBeforeOneWeiBooks() public {
        (, uint256 pairOnly) = _plan(AMT);
        for (uint256 k; k < 14; ++k) _book(uint24(101 + 100 * k), 1, 1);
        bytes32 pid = _book(3000, 1e18, 1_000_000e18);
        (Route memory plan, uint256 out) = _plan(AMT);
        assertGt(_legs(plan, pid), 0, "one-wei books stood between a deep book and its walk");
        assertGt(out, pairOnly, "the plan pays no more than the pair alone");
    }

    /// Declared sides 1e18 (deep), 1e17 (dust), 1e16 (deep) beside the pair: a dust book that
    /// declares more than a deep one does not use up its walk. Both deep books are seated.
    function test_ADustBookDeclaringMoreDoesNotHideADeepBook() public {
        bytes32 h2 = _book(100, 1e16, 1_000_000e18);
        bytes32 dust = _book(500, 1e17, 1e17);
        bytes32 h1 = _book(3000, 1e18, 1_000_000e18);
        (Route memory plan, ) = _plan(AMT);
        assertGt(_legs(plan, h1), 0, "the deep book declaring most was dropped");
        assertGt(_legs(plan, h2), 0, "a deep book behind one dust book was dropped unread");
        assertEq(_legs(plan, dust), 0, "the dust book was seated");
    }

    /// FREE DUST. A singleton book's declared side is virtual (L * sqrtP of its current tick),
    /// so declaring more than an honest book costs an attacker about two wei. Any rule that
    /// stops walking after some number of dust books drops the honest book behind them: here
    /// one dust book declares ten times what the deep book does, beside one measured seat.
    function test_ADeepBookOutDeclaredByDustBooksIsStillRead() public {
        (, uint256 pairOnly) = _plan(AMT);
        bytes32 dust = _book(500, 1e18, 1e18);
        bytes32 pid = _book(3000, 1e17, 1_000_000e18);
        (Route memory plan, uint256 out) = _plan(AMT);
        assertGt(_legs(plan, pid), 0, "a deep book out-declared by a dust book was dropped unread");
        assertEq(_legs(plan, dust), 0, "the dust book was seated");
        assertGt(out, pairOnly, "the plan pays no more than the pair alone");
    }

    // ---- both directions, hooked, two hops ----------------------------------------------

    /// BOTH WAYS. What a book adds to the other rows' D is what it holds, also when that is
    /// MORE than it declares. A second pair holding ten tokens is four times over the bar
    /// against the declared sides and under it against the book's walk: it takes a small order
    /// before the book exists and is dropped beside it, like any row that is dust against the
    /// pair's measured depth.
    function test_ADeepBookWeighsWhatItHoldsOnTheOtherRows() public {
        uint256 q = 10.01e18;
        MockV2Pair small = new MockV2Pair(address(t0), address(t1));
        t0.mint(address(small), 10e18);
        t1.mint(address(small), q);
        small.setReserves(uint112(10e18), uint112(q));
        hub.seedPool(address(small), BPC.KIND_V2, 30, address(0), address(t0), address(t1));
        (Route memory alone, ) = _plan(SMALL);
        assertGt(_legsAt(alone, address(small)), 0, "fixture: the small pair, priced 10 bp better, takes a small order");
        bytes32 pid = _book(3000, 1e18, 40_000_000e18);
        (, uint256 held, ) = BPC.v4WalkRank(address(mgr), pid, type(uint256).max, 0, TS, true, type(uint256).max);
        assertGe(q * 1e6, GAMMA_PPM * (PAIR + 2e18), "fixture: against the declared sides the small pair is over the bar");
        assertLt(q * 1e6, GAMMA_PPM * (PAIR + held), "fixture: against what the book holds the small pair is dust");
        assertGe(PAIR * 1e6, GAMMA_PPM * (q + held), "fixture: the incumbent is not dust against the book");
        (Route memory plan, ) = _plan(SMALL);
        assertEq(_legsAt(plan, address(small)), 0, "a row that is dust against what the book holds kept its seat");
        assertGt(plan.hops.length, 0, "the pair lost its route");
    }

    /// HOOKED. The same thin-tick book behind an allowed hook is read like a hookless one and
    /// keeps its seat, after the hookless leg.
    function test_HookedThinCurrentTickDeepNeighbourBookKeepsItsSeat() public {
        address hook = address(1);
        hub.allowHook(hook, true);
        (, uint256 pairOnly) = _plan(AMT);
        bytes32 pid = BPC.computeV4PoolId(address(t0), address(t1), 3000, TS, hook);
        mgr.initialize(pid, mgr.sqrtAt(1), 1, 3000);
        mgr.addPosition(pid, 0, 60, TS, 1e18);
        mgr.addPosition(pid, -6000, 0, TS, 1_000_000e18);
        hub.addV4(address(t0), address(t1), 3000, TS, hook);
        (Route memory plan, uint256 out) = _plan(AMT);
        assertGt(_legs(plan, pid), 0, "a deep hooked book thin on its current tick was dropped unread");
        assertGt(out, pairOnly, "the plan pays no more than the pair alone");
        assertEq(plan.hops[0].legs[plan.hops[0].legs.length - 1].hooks, hook, "the hooked leg is not last in its hop");
    }

    /// TWO HOPS, SIX DECIMALS. X -> M -> Y with M a bridge of six decimals: on the first hop the
    /// masses are counts of M restated to 18 decimals, the walk's answer with them. A walk
    /// compared raw would be twelve orders short and the book would lose its seat.
    function test_TwoHops_SixDecimals_ThinTickBookKeepsItsSeatOnTheFirstHop() public {
        PathologicalERC20 x = new PathologicalERC20("X", "X", 18);
        PathologicalERC20 m = new PathologicalERC20("M", "M", 6);
        PathologicalERC20 y = new PathologicalERC20("Y", "Y", 18);
        while (address(x) > address(m)) x = new PathologicalERC20("X", "X", 18);
        hub.addBridge(address(m));
        _seedPair(address(x), address(m), PAIR, PAIR);
        _seedPair(address(m), address(y), 10 * PAIR, 10 * PAIR);
        m.mint(address(mgr), 1e30);
        (, uint256 pairOnly) = quoter.previewPlanExact(address(x), address(y), AMT);
        assertGt(pairOnly, 0, "fixture: the pairs alone route the two hops");
        bytes32 pid = BPC.computeV4PoolId(address(x), address(m), 3000, TS, address(0));
        mgr.initialize(pid, mgr.sqrtAt(1), 1, 3000);
        mgr.addPosition(pid, 0, 60, TS, 1e18);
        mgr.addPosition(pid, -6000, 0, TS, 1_000_000e18);
        hub.addV4(address(x), address(m), 3000, TS, address(0));
        (, uint256 held, ) = BPC.v4WalkRank(address(mgr), pid, type(uint256).max, 0, TS, true, type(uint256).max);
        assertLt(held * 1e6, GAMMA_PPM * PAIR * 1e12, "fixture: the walk read raw is under the bar of the pair in 18 decimals");
        assertGt(held * 1e6, GAMMA_PPM * PAIR, "fixture: in one unit it is far over the bar");
        (Route memory plan, uint256 out) = quoter.previewPlanExact(address(x), address(y), AMT);
        assertEq(plan.hops.length, 2, "fixture: not a two-hop plan");
        assertGt(_legs(plan, pid), 0, "a deep book of a six-decimal token was dropped on the first hop");
        assertGt(out, pairOnly, "the plan pays no more than the pairs alone");
    }

    // ---- the funnel's horizon (I-FUNNEL-STRETCHES, 4660 E1, h = 2) -------------------------
    // Each singleton book under the bar is walked FUNNEL_STRETCHES = 2 stretches, its current
    // tick and the next, whatever else sits on the pair: what the funnel reads on a pair is two
    // stretches a book, and no declared figure or count of books moves it.

    /// Slots one walk of `h` stretches (`Core.v4Held`) makes on `pid`.
    function _walkReads(bytes32 pid, uint256 h) internal returns (uint256) {
        vm.record();
        BPC.v4Held(address(mgr), pid, TS, true, h);
        (bytes32[] memory rd, ) = vm.accesses(address(mgr));
        return rd.length;
    }

    /// `nb` one-wei books beside the pair: the search reads, on the manager, nb declared sides
    /// and nb walks of exactly two stretches, and a walk of two reads other than one of one or three.
    function _assertTwoStretches(uint256 nb) internal returns (bytes32 a) {
        (uint256 r0, ) = _reads(AMT);
        for (uint256 k; k < nb; ++k) a = _book(uint24(101 + 100 * k), 1, 1);
        (uint256 rn, ) = _reads(AMT);
        (uint256 mass, ) = _readsOfOneBook(a);
        uint256 w = _walkReads(a, 2);
        assertGt(w, _walkReads(a, 1), "fixture: one stretch reads as much as two");
        assertLt(w, _walkReads(a, 3), "fixture: three stretches read as much as two");
        assertEq(rn - r0, nb * (mass + w), "the books were not each walked on two stretches");
    }

    /// COUNTED, one book: two stretches, fewer than the promise's sixteen.
    function test_FunnelHorizon_OneBookIsReadOnTwoStretches() public {
        bytes32 a = _assertTwoStretches(1);
        (, uint256 promise_) = _readsOfOneBook(a);
        assertLt(_walkReads(a, 2), promise_, "fixture: two stretches read as much as the promise's walk");
    }

    /// COUNTED, a full pair (the incumbent and fifteen books): two stretches each, so the pair
    /// reads thirty stretches and not two hundred and forty.
    function test_FunnelHorizon_FifteenBooksReadTwoStretchesEach() public { _assertTwoStretches(15); }

    /// Books whose current tick is empty declare nothing and are not walked: eight of them beside
    /// two one-wei books leave the read at two declared sides and two walks of two stretches.
    function test_FunnelHorizon_EmptyTickBooksAreNotWalked() public {
        (uint256 r0, ) = _reads(AMT);
        bytes32 e;
        for (uint256 k; k < 8; ++k) e = _book(uint24(101 + 100 * k), 0, 1);
        bytes32 a = _book(5_001, 1, 1);
        _book(5_101, 1, 1);
        (uint256 rn, ) = _reads(AMT);
        (uint256 massE, ) = _readsOfOneBook(e);
        (uint256 mass, ) = _readsOfOneBook(a);
        assertEq(rn - r0, 8 * massE + 2 * (mass + _walkReads(a, 2)), "empty-tick books were walked");
    }

    /// A book at tick 1: `liqNow` on [0, 60), one wei on [-120, 0), `liqDeep` on [-6000, -120):
    /// its capital starts on the THIRD stretch of a zeroForOne walk.
    function _bookFar(uint24 fee, uint128 liqNow, uint128 liqDeep) internal returns (bytes32 pid) {
        pid = BPC.computeV4PoolId(address(t0), address(t1), fee, TS, address(0));
        mgr.initialize(pid, mgr.sqrtAt(1), 1, fee);
        mgr.addPosition(pid, 0, 60, TS, liqNow);
        mgr.addPosition(pid, -120, 0, TS, 1);
        mgr.addPosition(pid, -6000, -120, TS, liqDeep);
        hub.addV4(address(t0), address(t1), fee, TS, address(0));
    }

    /// THE RESIDUAL, PINNED. Alone beside the pair, a book whose capital starts on its third
    /// stretch is dropped, though sixteen stretches would seat it. Hiding capital past the
    /// horizon costs the book its own seat, never another row's; this pins the horizon at two
    /// so that it moves only by decision.
    function test_FunnelHorizon_CapitalPastTheNeighbourIsNotASeat() public {
        bytes32 far = _bookFar(500, 1e18, 1_000_000e18);
        assertLt(uint256(1e18) * 1e6, GAMMA_PPM * PAIR, "fixture: the current tick alone is under the bar");
        assertLt(BPC.v4Held(address(mgr), far, TS, true, 2) * 1e6, GAMMA_PPM * PAIR, "fixture: two stretches hold under the bar");
        assertGt(BPC.v4Held(address(mgr), far, TS, true, 16) * 1e6, GAMMA_PPM * PAIR, "fixture: sixteen stretches hold over the bar");
        (Route memory plan, ) = _plan(AMT);
        assertEq(_legs(plan, far), 0, "the funnel read past two stretches of a lone book");
    }

    /// THE HORIZON DOES NOT MOVE WITH THE CROWD. Thirteen one-wei books beside the pair: the book
    /// deep on its second stretch keeps its seat, the one deep on its third is dropped.
    function test_FunnelHorizon_ACrowdedPairReadsTheSameTwoStretches() public {
        for (uint256 k; k < 13; ++k) _book(uint24(101 + 100 * k), 1, 1);
        bytes32 near = _book(3000, 1e18, 1_000_000e18);
        bytes32 far = _bookFar(500, 1e18, 1_000_000e18);
        (Route memory plan, ) = _plan(AMT);
        assertGt(_legs(plan, near), 0, "a crowded pair dropped the book deep on its second stretch");
        assertEq(_legs(plan, far), 0, "a crowded pair read past two stretches a book");
    }

    /// CROWDED, WEIGHED (other rows). Twelve one-wei books beside the deep book of
    /// test_ADeepBookWeighsWhatItHoldsOnTheOtherRows: read on two stretches, it still adds what it
    /// holds, not its declared side, to the other rows' D, and the small pair is dropped.
    function test_FunnelHorizon_ACrowdedDeepBookWeighsWhatItHoldsOnTheOtherRows() public {
        uint256 q = 10.01e18;
        MockV2Pair small = new MockV2Pair(address(t0), address(t1));
        t0.mint(address(small), 10e18);
        t1.mint(address(small), q);
        small.setReserves(uint112(10e18), uint112(q));
        hub.seedPool(address(small), BPC.KIND_V2, 30, address(0), address(t0), address(t1));
        for (uint256 k; k < 12; ++k) _book(uint24(101 + 100 * k), 1, 1);
        bytes32 pid = _book(3000, 1e18, 40_000_000e18);
        uint256 held = BPC.v4Held(address(mgr), pid, TS, true, 2);
        assertGe(q * 1e6, GAMMA_PPM * (PAIR + 2e18), "fixture: against the declared sides the small pair is over the bar");
        assertLt(q * 1e6, GAMMA_PPM * (PAIR + held), "fixture: against two stretches of the book the small pair is dust");
        (Route memory plan, ) = _plan(SMALL);
        assertEq(_legsAt(plan, address(small)), 0, "a crowded book weighed its declared side, not what it holds");
        assertGt(plan.hops.length, 0, "the pair lost its route");
    }

    function _seedPair(address a, address b, uint256 ra, uint256 rb) internal {
        (address c0, address c1, uint256 r0, uint256 r1) = a < b ? (a, b, ra, rb) : (b, a, rb, ra);
        MockV2Pair p = new MockV2Pair(c0, c1);
        PathologicalERC20(c0).mint(address(p), r0);
        PathologicalERC20(c1).mint(address(p), r1);
        p.setReserves(uint112(r0), uint112(r1));
        hub.seedPool(address(p), BPC.KIND_V2, 30, address(0), c0, c1);
    }
}
