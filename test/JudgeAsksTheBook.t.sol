// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  THE IMPACT CEILING ASKS THE LEG'S OWN BOOK BEFORE REFUSING (4746/4755).
//
//  The Solver refuses a route when a leg's impact, or the per-hop mean summed over the hops,
//  reaches MAX_ROUTE_IMPACT_BPS. Those figures come from `_legImpactBps`, the single-range
//  model: a concentrated leg is priced as if its current liquidity went on for ever. On a thin
//  range at the price beside a deep book past its edge, the model reads a leg that pays almost
//  1:1 as one that destroys the order, and a two-hop route whose hops each settle near 1:1
//  alone was refused with SolverE(5).
//
//  The fix (`Solver._judgedOnTheBook`) re-judges the route on the refusal path only: each
//  concentrated leg is priced by its own book walked (`Core.v3PaysOnBudget`, JUDGE_READS reads
//  shared across the route), and only a walk that finished inside its reads counts as a
//  measurement. A concentrated leg whose walk did not finish (a book that does not answer, a
//  walk that ran out of reads, a leg handed 5 or fewer) has no verdict and refuses the route:
//  the model figure on trial is not a stand-in. The floor never reads the walked figure: it keeps the
//  single-range one the Router's in-frame arm reads (`Core.legQuoteImpact`).
//
//  Red at 2c8cbbe: the two-hop routes below (the 4746 geometry and the 4755 one at
//  10,000e18) are refused with SolverE(5), and so is every route here that keeps a route. The
//  refusals and the hostile books pass at the red as well: each is a guard whose red is its
//  mutant (.github/scripts/mutants.py, M-JUDGE-*).
// =============================================================================

import {Test, Vm} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixQuoter} from "../src/BlazePhoenixQuoter.sol";
import {BlazePhoenixCore as BPC, RoutePlan, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV3TickPool} from "./mocks/MockV3TickPool.sol";
import {MockV3Pool} from "./mocks/MockV3Pool.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";
import {MockSolidlyPair} from "./mocks/MockSolidlyPair.sol";
import {MockAlgebraPool} from "./mocks/MockAlgebraPool.sol";

contract JudgeAsksTheBook is Test {
    BlazePhoenixHub    hub;
    BlazePhoenixSolver solver;
    BlazePhoenixRouter router;
    BlazePhoenixQuoter quoter;

    address user = address(0xBEEF);
    uint24  constant FEE  = 3000;
    int24   constant TS   = 60;
    uint128 constant CUR  = 1e18;    // the thin current range [0, 60)
    uint128 constant DEEP = 1e22;    // the book past its edge
    uint256 constant ORD  = 2e18;    // an order the model reads at ~6,700 bps on one thin range
    uint256 constant BIG  = 1e19;    // an order the model reads at >= 9,000 bps on one thin range
    bytes32 constant PROOF = keccak256("ExecutionProof(address,address,uint256,uint256,uint256,uint256)");

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        solver = new BlazePhoenixSolver(address(hub), address(0));
        router = new BlazePhoenixRouter(address(hub), address(solver), address(this), address(0xFEE1), address(0xFEE2));
        quoter = new BlazePhoenixQuoter(address(hub), address(solver));
        hub.setRoles(address(router), address(solver), address(quoter));
    }

    function _refusal() internal pure returns (bytes memory) {
        return abi.encodeWithSelector(BlazePhoenixSolver.SolverE.selector, uint16(5));
    }

    // -- books ------------------------------------------------------------------------------

    /// @dev A V3 book, the price one tick inside [0, 60) on the side the order moves toward,
    ///      so the thin range ends one tick ahead. `deep` sits past that edge over 6,000 ticks.
    function _book(MockERC20 a, MockERC20 b, uint128 cur, uint128 deep) internal returns (MockV3TickPool q) {
        q = _bare(a, b);
        q.addPosition(0, 60, cur);
        if (deep != 0) {
            if (address(a) < address(b)) q.addPosition(-6000, 0, deep);
            else q.addPosition(60, 6060, deep);
        }
        _fund(q, a, b, 1e26);
    }

    /// @dev The book past the edge is shallow: `sh` over 46,080 ticks, read in three bitmap words.
    function _shallow(MockERC20 a, MockERC20 b, uint128 cur, uint128 sh) internal returns (MockV3TickPool q) {
        q = _bare(a, b);
        q.addPosition(0, 60, cur);
        if (address(a) < address(b)) q.addPosition(-46080, 0, sh);
        else q.addPosition(60, 46140, sh);
        _fund(q, a, b, 1e26);
    }

    /// @dev Past the edge, `n` adjacent 60-tick positions of `per` each: every tick is initialized
    ///      and every crossing costs a read, so the walk runs out of reads long before the order ends.
    function _dense(MockERC20 a, MockERC20 b, uint128 cur, uint128 per, uint256 n) internal returns (MockV3TickPool q) {
        q = _bare(a, b);
        q.addPosition(0, 60, cur);
        bool z = address(a) < address(b);
        for (uint256 k; k < n; ++k) {
            int24 s = int24(int256(k)) * 60;
            if (z) q.addPosition(-s - 60, -s, per);
            else q.addPosition(60 + s, 120 + s, per);
        }
        _fund(q, a, b, 1e26);
    }

    function _bare(MockERC20 a, MockERC20 b) internal returns (MockV3TickPool q) {
        q = new MockV3TickPool(address(a), address(b), FEE, TS);
        q.initialize(address(a) < address(b) ? int24(1) : int24(59));
    }

    function _fund(MockV3TickPool q, MockERC20 a, MockERC20 b, uint256 amt) internal {
        a.mint(address(q), amt);
        b.mint(address(q), amt);
        hub.seedPool(address(q), BPC.KIND_V3, FEE, address(0), address(a), address(b));
    }

    function _three() internal returns (MockERC20 c, MockERC20 mid, MockERC20 d) {
        c = new MockERC20("CCC", "CCC");
        mid = new MockERC20("MMM", "MMM");
        d = new MockERC20("DDD", "DDD");
        hub.addBridge(address(mid));
    }

    function _settle(RoutePlan memory plan, MockERC20 tin, uint256 amt) internal returns (uint256 got) {
        tin.mint(user, amt);
        vm.startPrank(user);
        tin.approve(address(router), type(uint256).max);
        got = router.swapExactIn(plan.best, amt, plan.best.singleOutFloor, user, block.timestamp + 1);
        vm.stopPrank();
    }

    /// @dev Plans `amt` from c to d, asserts a two-hop route, settles it against its own floor.
    function _keepsARoute(MockERC20 c, MockERC20 d, uint256 amt) internal returns (uint256 got, RoutePlan memory plan) {
        plan = solver.findBestRoutePlan(address(c), address(d), amt);
        assertEq(plan.best.hops.length, 2, "the two-hop order keeps a route");
        assertGt(plan.best.singleOutFloor, 0, "premise: the Solver attested a floor");
        // Settles: the Router already holds it to singleOutFloor (`_settle` passes it as minOut).
        got = _settle(plan, c, amt);
    }

    // -- the oracle: what the book pays, from the specification's swap, not from the Core ------

    function _limit(bool z) internal pure returns (uint160) {
        return z ? BPC.MIN_SQRT_PRICE_PLUS_ONE : BPC.MAX_SQRT_PRICE_MINUS_ONE;
    }

    /// @dev Impact in bps of `out` for `amt` against the pool's price before the swap; an input the
    ///      book cannot take whole reads as total impact.
    function _walkedBps(MockV3TickPool q, bool z, uint256 amt) internal view returns (uint256 bps, uint256 out) {
        uint256 used;
        (used, out, , , ) = q.specSwap(amt, z, _limit(z));
        (uint160 sp, , , , , , ) = q.slot0();
        if (used < amt || out == 0) return (10_000, out);
        uint256 q96 = 1 << 96;
        uint256 v = z ? (out * q96 / sp) * q96 / sp : (out * sp / q96) * sp / q96;
        uint256 ratio = v * 10_000 / amt;
        bps = ratio >= 10_000 ? 0 : 10_000 - ratio;
    }

    // =========================================================================================
    //  (a, b) The two-hop route the model refused keeps a route and settles.
    // =========================================================================================

    /// 4746: two V3 hops, thin current range (1e18), deep book past the edge (1e22), 2e18 in.
    function test_TwoConcentratedHopsOverTheirEdgeKeepARoute() public {
        (MockERC20 c, MockERC20 mid, MockERC20 d) = _three();
        MockV3TickPool q = _book(c, mid, CUR, DEEP);
        _book(mid, d, CUR, DEEP);
        (uint256 w0, ) = _walkedBps(q, address(c) < address(mid), ORD);
        assertLt(w0, 100, "premise: hop 0's book pays the order within 100 bps");
        (uint256 got, ) = _keepsARoute(c, d, ORD);
        assertGt(got, ORD * 9 / 10, "the two hops, walked, lose under 10%");
    }

    /// 4755: the same geometry at 10,000e18, current range 5e21, book 1e25.
    function test_V3V3At10kKeepsARoute() public {
        (MockERC20 c, MockERC20 mid, MockERC20 d) = _three();
        _book(c, mid, 5e21, 1e25);
        _book(mid, d, 5e21, 1e25);
        (uint256 got, ) = _keepsARoute(c, d, 10_000e18);
        assertGt(got, 10_000e18 * 9 / 10, "the two hops, walked, lose under 10%");
    }

    // =========================================================================================
    //  (c, d, e) What stays refused: a measured shallow book, a book that does not answer, a
    //  walk that does not finish inside its reads.
    // =========================================================================================

    /// A thin range (1e17) and, past the edge, a book as shallow (1e17 over 46,080 ticks): the walk finishes and measures
    /// a destroyer, so the route stays refused.
    function test_ShallowBookBeyondTheEdgeStaysRefused() public {
        (MockERC20 c, MockERC20 mid, MockERC20 d) = _three();
        MockV3TickPool q = _shallow(c, mid, 1e17, 1e17);
        _shallow(mid, d, 1e17, 1e17);
        uint256 amt = 8e17;
        (uint256 w0, ) = _walkedBps(q, address(c) < address(mid), amt);
        assertGt(w0, 8_500, "premise: hop 0's own book loses more than 85% of the order");
        vm.expectRevert(_refusal());
        solver.findBestRoutePlan(address(c), address(d), amt);
    }

    /// The 4746 geometry with both books' slot0 tick lying (100 ticks off the price, against the
    /// order): the walk does not read a book whose tick disagrees with its price (it answers the
    /// cap it was handed), so the leg has no verdict and the route stays refused.
    function test_BookThatDoesNotAnswerStaysRefused() public {
        (MockERC20 c, MockERC20 mid, MockERC20 d) = _three();
        MockV3TickPool q = _book(c, mid, CUR, DEEP);
        MockV3TickPool p = _book(mid, d, CUR, DEEP);
        q.lieAboutTheTick(address(c) < address(mid) ? int24(100) : int24(-100));
        p.lieAboutTheTick(address(mid) < address(d) ? int24(100) : int24(-100));
        vm.expectRevert(_refusal());
        solver.findBestRoutePlan(address(c), address(d), ORD);
    }

    /// Past the edge, 40 adjacent 60-tick positions (1e20 each): every tick is initialized, the
    /// walk runs out of reads before the order ends, and an unfinished walk is not a measurement.
    function test_WalkThatDoesNotFinishStaysRefused() public {
        (MockERC20 c, MockERC20 mid, MockERC20 d) = _three();
        MockV3TickPool q = _dense(c, mid, CUR, 1e20, 40);
        _dense(mid, d, CUR, 1e20, 40);
        (uint256 w0, ) = _walkedBps(q, address(c) < address(mid), ORD);
        assertLt(w0, 500, "premise: the book itself pays the order (it is the walk's budget that ends)");
        vm.expectRevert(_refusal());
        solver.findBestRoutePlan(address(c), address(d), ORD);
    }

    // =========================================================================================
    //  (f) The floor keeps its figure: attested floor rate == the Router's enforced floor rate.
    // =========================================================================================

    function _proof(Vm.Log[] memory logs) private pure returns (uint256 quote, uint256 floorOut, bool found) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == PROOF) {
                (quote, , floorOut, ) = abi.decode(logs[i].data, (uint256, uint256, uint256, uint256));
                return (quote, floorOut, true);
            }
        }
    }

    /// On the route the judge admitted (4746 geometry), the floor rate the Solver attests is the
    /// floor rate the Router enforces: the walked figure never reaches the floor.
    function test_FloorFigureUnchangedByTheJudge() public {
        (MockERC20 c, MockERC20 mid, MockERC20 d) = _three();
        _book(c, mid, CUR, DEEP);
        _book(mid, d, CUR, DEEP);
        RoutePlan memory plan = solver.findBestRoutePlan(address(c), address(d), ORD);
        assertEq(plan.best.hops.length, 2, "premise: the route crosses the bridge");
        assertGt(plan.best.singleOutFloor, 0, "premise: the Solver attested a floor");
        c.mint(user, ORD);
        vm.prank(user);
        c.approve(address(router), type(uint256).max);
        vm.recordLogs();
        vm.prank(user);
        router.swapExactIn(plan.best, ORD, 1, user, block.timestamp + 1);
        (uint256 quote, uint256 floorOut, bool found) = _proof(vm.getRecordedLogs());
        assertTrue(found, "premise: ExecutionProof emitted");

        uint256 b = plan.best.hops[1].amountIn;
        uint256 netOut = BPC.mulDiv(plan.best.totalOut, b - BPC.mulDivUp(b, BPC.PROTOCOL_FEE_BPS, BPC.BPS), b);
        uint256 attestedBps = BPC.mulDiv(plan.best.singleOutFloor, BPC.BPS, netOut);
        uint256 enforcedBps = BPC.mulDiv(floorOut, BPC.BPS, quote);
        emit log_named_uint("attested floor rate (bps)", attestedBps);
        emit log_named_uint("enforced floor rate (bps)", enforcedBps);
        assertEq(attestedBps, enforcedBps,
            "the judge's walked figure must not move the floor rate off the Router's own");
    }

    // =========================================================================================
    //  (g) Vectors at hop 0: V2, Solidly (reserves, no walk), Algebra (concentrated, no book).
    // =========================================================================================

    function _deepV2(MockERC20 a, MockERC20 b) internal {
        MockV2Pair p = new MockV2Pair(address(a), address(b));
        a.mint(address(p), 1e24);
        b.mint(address(p), 1e24);
        p.setReserves(uint112(1e24), uint112(1e24));
        hub.seedPool(address(p), BPC.KIND_V2, 30, address(0), address(a), address(b));
    }

    function _deepSolidly(MockERC20 a, MockERC20 b) internal {
        MockSolidlyPair p = new MockSolidlyPair(address(a), address(b), false);
        a.mint(address(p), 1e24);
        b.mint(address(p), 1e24);
        p.setReserves(uint112(1e24), uint112(1e24));
        hub.seedPool(address(p), BPC.KIND_SOLIDLY, 30, address(0), address(a), address(b));
    }

    function _algebra(MockERC20 a, MockERC20 b, uint128 liq) internal {
        MockAlgebraPool p = new MockAlgebraPool(address(a), address(b), 3000);
        p.setState(uint160(1 << 96), liq);
        a.mint(address(p), 1e26);
        b.mint(address(p), 1e26);
        hub.seedPool(address(p), BPC.KIND_ALGEBRA, 0, address(0), address(a), address(b));
    }

    /// V2 at hop 0 spends none of the judge's reads; hop 1's thin range (model >= 9,000 bps at
    /// 1e19) is walked into its deep book and the route is kept.
    function test_V2ThenV3OverItsEdgeKeepsARoute() public {
        (MockERC20 c, MockERC20 mid, MockERC20 d) = _three();
        _deepV2(c, mid);
        _book(mid, d, CUR, DEEP);
        (uint256 got, ) = _keepsARoute(c, d, BIG);
        assertGt(got, BIG * 9 / 10, "the two hops lose under 10%");
    }

    /// Solidly (volatile) at hop 0 rides the reserves arm, as V2.
    function test_SolidlyThenV3OverItsEdgeKeepsARoute() public {
        (MockERC20 c, MockERC20 mid, MockERC20 d) = _three();
        _deepSolidly(c, mid);
        _book(mid, d, CUR, DEEP);
        (uint256 got, ) = _keepsARoute(c, d, BIG);
        assertGt(got, BIG * 9 / 10, "the two hops lose under 10%");
    }

    /// Algebra at hop 0 is concentrated, but its book is not read (no tickSpacing): the walk
    /// answers the cap, so the leg has no verdict and the model's refusal stands, however deep
    /// its single range and whatever hop 1's book pays. Admitted at 9b2855e on the unwalked
    /// leg's model figure summed with hop 1's walked one; red under M-JUDGE-11.
    function test_AlgebraDeepThenV3OverItsEdgeStaysRefused() public {
        (MockERC20 c, MockERC20 mid, MockERC20 d) = _three();
        _algebra(c, mid, 1e24);
        MockV3TickPool q1 = _book(mid, d, CUR, DEEP);
        bool z1 = address(mid) < address(d);
        (uint256 out1, uint256 left1) = _judgeWalk(q1, z1, BIG);
        assertTrue(out1 != type(uint256).max && left1 != 0, "premise: hop 1 is measured, up to the whole order");
        (uint160 sp1, , , , , , ) = q1.slot0();
        assertLt(BPC.impactV3FromOut(out1, BIG, sp1, z1), 1_000, "premise: hop 1's book pays near 1:1");
        vm.expectRevert(_refusal());
        solver.findBestRoutePlan(address(c), address(d), BIG);
    }

    /// A thin Algebra single range at hop 0 cannot be walked: its model figure (>= 9,000 bps)
    /// stands, and the route stays refused even though hop 1 would be admitted on its book.
    function test_AlgebraThinAtHop0StaysRefused() public {
        (MockERC20 c, MockERC20 mid, MockERC20 d) = _three();
        _algebra(c, mid, CUR);
        _book(mid, d, CUR, DEEP);
        vm.expectRevert(_refusal());
        solver.findBestRoutePlan(address(c), address(d), BIG);
    }

    // =========================================================================================
    //  (h) Hostile: a book whose liquidityNet claims a deep book that is not there.
    // =========================================================================================

    /// Both books hold only the thin range, but tick 0 (60 on the other side) claims that the
    /// liquidity past the edge is 1e22, and each pool holds only 1e18 of what it must pay. The
    /// walk reads the lie and the judge may admit the route; what binds is the pool's payment:
    /// the route either is refused, reverts at the pool, or settles at or above its floor.
    function test_LyingNetCannotSettleUnderTheFloor() public {
        (MockERC20 c, MockERC20 mid, MockERC20 d) = _three();
        MockV3TickPool q = _liar(c, mid);
        MockV3TickPool p = _liar(mid, d);
        q; p;
        (bool okPlan, bytes memory ret) = address(solver).call(
            abi.encodeCall(BlazePhoenixSolver.findBestRoutePlan, (address(c), address(d), ORD)));
        if (!okPlan) {
            assertEq(ret, _refusal(), "a refused plan is refused with SolverE(5)");
            emit log("hostile net: refused at the plan, SolverE(5)");
            return;
        }
        RoutePlan memory plan = abi.decode(ret, (RoutePlan));
        emit log_named_uint("hostile net: admitted, hops", plan.best.hops.length);
        c.mint(user, ORD);
        vm.prank(user);
        c.approve(address(router), type(uint256).max);
        uint256 floor = plan.best.singleOutFloor;
        vm.prank(user);
        try router.swapExactIn(plan.best, ORD, floor, user, block.timestamp + 1) returns (uint256 got) {
            emit log_named_uint("hostile net: settled", got);
            assertGe(got, floor, "settled at or above the floor");
        } catch (bytes memory err) {
            emit log_named_bytes("hostile net: swap reverted with", err);
            assertGt(err.length, 0, "the revert names its cause");
        }
    }

    function _liar(MockERC20 a, MockERC20 b) internal returns (MockV3TickPool q) {
        q = _bare(a, b);
        q.addPosition(0, 60, CUR);
        if (address(a) < address(b)) q.lieAboutTheNet(0, int128(CUR) - int128(DEEP));
        else q.lieAboutTheNet(60, int128(DEEP) - int128(CUR));
        a.mint(address(q), 1e18);
        b.mint(address(q), 1e18);
        hub.seedPool(address(q), BPC.KIND_V3, FEE, address(0), address(a), address(b));
    }

    // =========================================================================================
    //  (i) Fuzz over the 4746 geometry, and one wei either side of the model's 9,000 bps.
    // =========================================================================================

    /// Either a route that settles at or above its floor, or SolverE(5) only when what the books
    /// pay, walked by the specification's swap, reaches the ceiling: a hop at >= 9,000 bps, or the
    /// two hops' figures summed at >= 9,000 bps.
    function testFuzz_RefusedOnlyWhenTheBooksDestroyTheOrder(uint256 ord, uint256 cur) public {
        ord = bound(ord, 1e15, 1e22);
        cur = bound(cur, 1e17, 1e21);
        (MockERC20 c, MockERC20 mid, MockERC20 d) = _three();
        MockV3TickPool q = _book(c, mid, uint128(cur), DEEP);
        MockV3TickPool p = _book(mid, d, uint128(cur), DEEP);
        (bool okPlan, bytes memory ret) = address(solver).call(
            abi.encodeCall(BlazePhoenixSolver.findBestRoutePlan, (address(c), address(d), ord)));
        if (okPlan) {
            RoutePlan memory plan = abi.decode(ret, (RoutePlan));
            _settle(plan, c, ord); // settles: the Router already holds it to singleOutFloor (minOut)
            return;
        }
        assertEq(ret, _refusal(), "a refusal is SolverE(5)");
        (uint256 w0, uint256 out0) = _walkedBps(q, address(c) < address(mid), ord);
        uint256 in1 = out0 - BPC.mulDivUp(out0, BPC.PROTOCOL_FEE_BPS, BPC.BPS);
        (uint256 w1, ) = in1 == 0 ? (uint256(10_000), uint256(0)) : _walkedBps(p, address(mid) < address(d), in1);
        emit log_named_uint("walked hop0 bps", w0);
        emit log_named_uint("walked hop1 bps", w1);
        assertGe(w0 > w1 ? (w0 >= 9_000 ? w0 : w0 + w1) : (w1 >= 9_000 ? w1 : w0 + w1), 9_000,
            "SolverE(5) only when the books walked reach the ceiling");
    }

    /// The order at which hop 0's single-range model figure first reaches 9,000 bps, by bisection
    /// on the model the ceiling reads (`Core.impactV3Bps`, as `_legImpactBps` calls it).
    function _modelEdge(MockV3TickPool q, bool z) internal view returns (uint256 lo) {
        (uint160 sp, , , , , , ) = q.slot0();
        uint128 liq = q.liquidity();
        lo = 1e15;
        uint256 hi = 1e22;
        require(BPC.impactV3Bps(hi, sp, liq, FEE, z) >= 9_000 && BPC.impactV3Bps(lo, sp, liq, FEE, z) < 9_000, "bracket");
        while (hi - lo > 1) {
            uint256 m = lo + (hi - lo) / 2;
            if (BPC.impactV3Bps(m, sp, liq, FEE, z) >= 9_000) hi = m; else lo = m;
        }
        lo = hi; // the least order whose model figure reaches 9,000
    }

    /// Hop 0 is the 4746 thin range over its deep book, hop 1 a deep V2 pair: one wei either side
    /// of where hop 0's model figure reaches 9,000 bps, the route is kept and settles.
    function test_OneWeiEitherSideOfTheModelCeilingKeepsARoute() public {
        (MockERC20 c, MockERC20 mid, MockERC20 d) = _three();
        MockV3TickPool q = _book(c, mid, CUR, DEEP);
        _deepV2(mid, d);
        uint256 edge = _modelEdge(q, address(c) < address(mid));
        emit log_named_uint("model edge (least order at >= 9,000 bps)", edge);
        uint256 snap = vm.snapshotState();
        _keepsARoute(c, d, edge - 1);
        vm.revertToState(snap);
        _keepsARoute(c, d, edge);
        vm.revertToState(snap);
        _keepsARoute(c, d, edge + 1);
    }

    // =========================================================================================
    //  (j) Gas of the plan on the refusal path and on an admitted route the judge never runs on.
    // =========================================================================================

    function _planGas(address tin, address tout, uint256 amt) internal returns (uint256 used, bool ok) {
        bytes memory cd = abi.encodeCall(BlazePhoenixSolver.findBestRoutePlan, (tin, tout, amt));
        uint256 g = gasleft();
        (ok, ) = address(solver).call(cd);
        used = g - gasleft();
    }

    function test_Gas_JudgeOnTheRefusalPathAndOffTheAdmittedOne() public {
        (MockERC20 c, MockERC20 mid, MockERC20 d) = _three();
        _shallow(c, mid, 1e17, 1e17);
        _shallow(mid, d, 1e17, 1e17);
        (uint256 gRef, bool okRef) = _planGas(address(c), address(d), 8e17);
        assertFalse(okRef, "premise: (c) is refused");
        emit log_named_uint("gas: refused route (shallow book, 2 hops x 1 leg)", gRef);

        (MockERC20 e, MockERC20 mid2, MockERC20 f) = _three();
        _book(e, mid2, 1e25, 1e25);
        _book(mid2, f, 1e25, 1e25);
        (uint256 gAdm, bool okAdm) = _planGas(address(e), address(f), 10_000e18);
        assertTrue(okAdm, "premise: the deep route is admitted without the judge");
        emit log_named_uint("gas: admitted route (deep current ranges, judge not run)", gAdm);

        // Worst case shape: two hops of five thin books each, all refused.
        (MockERC20 g, MockERC20 mid3, MockERC20 h) = _three();
        for (uint256 k; k < 5; ++k) {
            _shallow(g, mid3, 1e17, 1e17);
            _shallow(mid3, h, 1e17, 1e17);
        }
        (uint256 gW, bool okW) = _planGas(address(g), address(h), 4e18);
        emit log_named_uint("gas: 2 hops x 5 thin books (worst case built)", gW);
        emit log_named_uint("gas: worst case planned (1) or refused (0)", okW ? 1 : 0);
    }

    // =========================================================================================
    //  (k) The judge's reads: per hop, under one allowance per solve frame (F2 4746 EMENDA).
    // =========================================================================================

    /// @dev The judge's reads per hop (`JUDGE_READS`, private in the Solver).
    uint256 constant HOP_READS = 12;

    /// @dev What the Core's budgeted walk answers for `amt` on `q` with one hop's reads: `left`
    ///      is what it did not spend, `out == max` is a book that did not answer.
    function _judgeWalk(MockV3TickPool q, bool z, uint256 amt) internal view returns (uint256 out, uint256 left) {
        (out, left) = BPC.v3PaysOnBudget(address(q), amt, z, type(uint256).max, HOP_READS);
    }

    /// @dev [0, 60) `cur`, then `n` adjacent 60-tick stairs of `per` past the edge, then `deep`
    ///      over 6,000 ticks past the stairs: the walk crosses n + 1 initialized ticks before it
    ///      finishes in the deep book, 5 + 2(n + 1) + 1 reads.
    function _stairs(MockERC20 a, MockERC20 b, uint128 cur, uint128 per, uint256 n, uint128 deep)
        internal returns (MockV3TickPool q)
    {
        q = _bare(a, b);
        q.addPosition(0, 60, cur);
        bool z = address(a) < address(b);
        for (uint256 k; k < n; ++k) {
            int24 s = int24(int256(k)) * 60;
            if (z) q.addPosition(-s - 60, -s, per);
            else q.addPosition(60 + s, 120 + s, per);
        }
        int24 e = int24(int256(n)) * 60;
        if (z) q.addPosition(-e - 6000, -e, deep);
        else q.addPosition(60 + e, 6060 + e, deep);
        _fund(q, a, b, 1e26);
    }

    /// @dev One range [0, 4000) of `cur` and nothing past it, on a 4,000-tick spacing: the next
    ///      bitmap word past the edge holds no tick, so the walk reaches the price bound in 8 reads.
    function _endsAtTheBound(MockERC20 a, MockERC20 b, uint128 cur) internal returns (MockV3TickPool q) {
        q = new MockV3TickPool(address(a), address(b), FEE, 4000);
        q.initialize(address(a) < address(b) ? int24(1) : int24(3999));
        q.addPosition(0, 4000, cur);
        _fund(q, a, b, 1e26);
    }

    /// Hop 1 alone reads >= 9,000 bps on the model (1e17 current range); hop 0 crosses its edge
    /// first (8 reads). Each hop has its own reads, so hop 1 is walked into its deep book and the
    /// route is kept. Red at base 2c8cbbe (no judge) and under M-JUDGE-4 (reads hoisted out of the hop loop).
    function test_SecondHopIsMeasuredAfterTheFirstCrossesItsEdge() public {
        (MockERC20 c, MockERC20 mid, MockERC20 d) = _three();
        MockV3TickPool q = _book(c, mid, CUR, DEEP);
        MockV3TickPool p = _book(mid, d, 1e17, DEEP);
        bool z0 = address(c) < address(mid);
        bool z1 = address(mid) < address(d);
        (uint160 sp1, , , , , , ) = p.slot0();
        assertGe(BPC.impactV3Bps(ORD * 99 / 100, sp1, p.liquidity(), FEE, z1), 9_000, "premise: hop 1's model alone destroys the order");
        (, uint256 left0) = _judgeWalk(q, z0, ORD);
        assertEq(HOP_READS - left0, 8, "premise: hop 0 spends 8 reads crossing its edge");
        (uint256 out1, uint256 left1) = _judgeWalk(p, z1, ORD * 99 / 100);
        assertTrue(out1 != type(uint256).max && left1 != 0, "premise: hop 1, on its own 12 reads, is measured");
        (uint256 got, ) = _keepsARoute(c, d, ORD);
        assertGt(got, ORD * 9 / 10, "the two hops, walked, lose under 10%");
    }

    /// Hop 0's book has a stair past its edge: its walk finishes on 10 of the hop's 12 reads.
    /// Hop 1 (model >= 9,000) is still handed its own 12, is measured, and the route is kept: red
    /// under M-JUDGE-4 (hop 1 left 2 reads, not walked). The same hop 0 dense past its edge (every
    /// 60 ticks initialized) spends all 12 reads and does not finish: it has no verdict and the
    /// route is refused, whatever hop 1 measures (admitted at 9b2855e on hop 0's model figure,
    /// ~6,700; red under M-JUDGE-11).
    function test_DenseBookOnTheFirstHopDoesNotStarveTheSecond() public {
        (MockERC20 c, MockERC20 mid, MockERC20 d) = _three();
        uint256 snap = vm.snapshotState();
        MockV3TickPool q = _stairs(c, mid, CUR, 1e15, 1, DEEP);
        _book(mid, d, 1e17, DEEP);
        (uint256 out0, uint256 left0) = _judgeWalk(q, address(c) < address(mid), ORD);
        assertTrue(out0 != type(uint256).max && left0 == 2, "premise: hop 0's walk finishes on 10 of its 12 reads");
        _keepsARoute(c, d, ORD);
        vm.revertToState(snap);
        q = _dense(c, mid, CUR, 1e20, 40);
        _book(mid, d, 1e17, DEEP);
        (, left0) = _judgeWalk(q, address(c) < address(mid), ORD);
        assertEq(left0, 0, "premise: hop 0's walk spends every read and does not finish");
        vm.expectRevert(_refusal());
        solver.findBestRoutePlan(address(c), address(d), ORD);
    }

    /// Two equal concentrated books at hop 0 (1e17 range, deep past the edge), 4e18 in, split
    /// across both: the first leg's walk spends 8 of the hop's 12 reads, the second is handed 4,
    /// is not walked, has no verdict and the route stays refused. The same
    /// book alone, one leg, is measured and kept. Green at base 2c8cbbe (a guard); red under M-JUDGE-5
    /// (reads restarted per leg).
    function test_TwoConcentratedLegsInOneHopShareTheHopsReads() public {
        (MockERC20 c, MockERC20 mid, MockERC20 d) = _three();
        _deepV2(mid, d);
        uint256 snap = vm.snapshotState();
        _book(c, mid, 1e17, DEEP);
        (, RoutePlan memory one) = _keepsARoute(c, d, ORD);
        assertEq(one.best.hops[0].legs.length, 1, "premise: one book, one leg, measured and kept");
        vm.revertToState(snap);
        MockV3TickPool q = _book(c, mid, 1e17, DEEP);
        _book(c, mid, 1e17, DEEP);
        (, uint256 left) = _judgeWalk(q, address(c) < address(mid), ORD);
        assertEq(left, 4, "premise: the first leg leaves 4 reads, under the 6 a walk needs");
        vm.expectRevert(_refusal());
        solver.findBestRoutePlan(address(c), address(d), 2 * ORD);
    }

    /// +-1 read: one stair past the edge, two initialized crossings, the walk finishes on 10 of
    /// its 12 reads and is measured, the route is kept.
    function test_WalkWithOneReadSpareIsMeasured() public {
        (MockERC20 c, MockERC20 mid, MockERC20 d) = _three();
        MockV3TickPool q = _stairs(c, mid, 1e17, 1e15, 1, DEEP);
        _deepV2(mid, d);
        (uint256 out, uint256 left) = _judgeWalk(q, address(c) < address(mid), ORD);
        assertEq(left, 2, "premise: 10 reads spent, 2 spare");
        assertTrue(out != type(uint256).max, "premise: the book answered");
        _keepsARoute(c, d, ORD);
    }

    /// +-1 read: two stairs, three initialized crossings, the walk finishes on its 12th read:
    /// counted unmeasured (fail closed): no verdict, refused. Green
    /// at base 2c8cbbe (a guard); red under M-JUDGE-2a (`reads != 0` dropped).
    function test_WalkEndingOnItsLastReadCountsAsUnmeasured() public {
        (MockERC20 c, MockERC20 mid, MockERC20 d) = _three();
        MockV3TickPool q = _stairs(c, mid, 1e17, 1e15, 2, DEEP);
        _deepV2(mid, d);
        (uint256 out, uint256 left) = _judgeWalk(q, address(c) < address(mid), ORD);
        assertEq(left, 0, "premise: all 12 reads spent");
        assertTrue(out != type(uint256).max, "premise: the book answered");
        (uint256 w0, ) = _walkedBps(q, address(c) < address(mid), ORD);
        assertLt(w0, 500, "premise: the book itself pays the order");
        vm.expectRevert(_refusal());
        solver.findBestRoutePlan(address(c), address(d), ORD);
    }

    /// A book that ends: one range and nothing past it. The walk reaches the price bound with
    /// input left inside its reads: that is a measurement (out = all the book pays), its figure
    /// is >= 9,000 bps and the route is refused. Green at base 2c8cbbe (a guard).
    function test_BookEndingAtThePriceBoundIsMeasuredAndRefused() public {
        (MockERC20 c, MockERC20 mid, MockERC20 d) = _three();
        MockV3TickPool q = _endsAtTheBound(c, mid, 1e17);
        _deepV2(mid, d);
        bool z = address(c) < address(mid);
        (uint256 out, uint256 left) = _judgeWalk(q, z, ORD);
        assertTrue(out != type(uint256).max && left != 0, "premise: measured (answered, reads left)");
        (uint160 sp, , , , , , ) = q.slot0();
        assertGe(BPC.impactV3FromOut(out, ORD, sp, z), 9_000, "premise: what the book pays destroys the order");
        vm.expectRevert(_refusal());
        solver.findBestRoutePlan(address(c), address(d), ORD);
    }

    /// Three bridges, three refused topologies in order: the first two spend the solve's 24 reads
    /// on dense books that do not finish (model >= 9,000), the third (hop 1 alone >= 9,000 on the
    /// model, kept when measured, shown first on its own) is handed none: its concentrated legs
    /// are not walked and have no verdict, refused, SolverE(5) as at base 2c8cbbe. Red under
    /// M-JUDGE-6 (the leftover not written back).
    function test_SolveAllowanceExhaustedKeepsTheModel() public {
        MockERC20 c = new MockERC20("CCC", "CCC");
        MockERC20 d = new MockERC20("DDD", "DDD");
        MockERC20 m1 = new MockERC20("M1", "M1");
        MockERC20 m2 = new MockERC20("M2", "M2");
        MockERC20 m3 = new MockERC20("M3", "M3");
        hub.addBridge(address(m1));
        hub.addBridge(address(m2));
        hub.addBridge(address(m3));
        _book(c, m3, CUR, DEEP);
        _book(m3, d, 1e17, DEEP);
        uint256 snap = vm.snapshotState();
        _keepsARoute(c, d, ORD);
        vm.revertToState(snap);
        MockV3TickPool q1 = _dense(c, m1, 1e17, 1e20, 40);
        _deepV2(m1, d);
        MockV3TickPool q2 = _dense(c, m2, 1e17, 1e20, 40);
        _deepV2(m2, d);
        (, uint256 l1) = _judgeWalk(q1, address(c) < address(m1), ORD);
        (, uint256 l2) = _judgeWalk(q2, address(c) < address(m2), ORD);
        assertEq(l1 + l2, 0, "premise: each dense topology spends its hop's 12 reads");
        vm.expectRevert(_refusal());
        solver.findBestRoutePlan(address(c), address(d), ORD);
    }

    /// The leader the judge admitted, re-assembled on what its books pay (`_paysWhatItWalks`)
    /// with the frame's reads already spent: hop 0 a deep range at the price over a shallow book
    /// past its edge, whose walk finishes inside the hop's reads (a measured leg) and pays less
    /// than the single-range model promised, so its promise falls; hop 1 a 1e17 range whose model
    /// figure, summed with hop 0's, crosses the line, so the route exists only because the build's
    /// judge admitted it on both legs' walks. Three (range, shallow book, order) vectors.
    /// The re-assembly keeps that verdict: the answer is the two-hop route, never SolverE(5) on
    /// the frame's spent reads and never an empty plan. Red at f96bf6c (an empty `best`) and at
    /// c54fd92 (SolverE(5)), on a hop 0 that did not finish its walk; since the judge admits only
    /// on finished walks (5408/5608), hop 0 is measured. Settles (the Router holds it to
    /// singleOutFloor), or the Router refuses it under the floor (RouterE(5)), the limit
    /// `What this does not do` names.
    function test_LeaderAdmittedByTheJudgeDoesNotLeaveAnEmptyPlan() public {
        uint128[3] memory cur = [uint128(1e19), 3e18, 3e19];
        uint128[3] memory sh = [uint128(3e18), 1e18, 1e18];
        uint256[3] memory ord = [ORD, ORD, 15e17];
        for (uint256 i; i < 3; ++i) {
            uint256 snap = vm.snapshotState();
            (MockERC20 c, MockERC20 mid, MockERC20 d) = _three();
            MockV3TickPool q = _shallow(c, mid, cur[i], sh[i]);
            MockV3TickPool q1 = _book(mid, d, 1e17, DEEP);
            bool z0 = address(c) < address(mid);
            (uint256 w0, uint256 left0) = _judgeWalk(q, z0, ord[i]);
            assertGt(left0, 0, "premise: hop 0's walk finishes inside the hop's reads");
            assertLt(w0, _modelOut(q, ord[i], z0), "premise: hop 0's promise falls on the walk");
            (uint256 wb0, ) = _walkedBps(q, z0, ord[i]);
            assertLt(wb0, 9_000, "premise: what hop 0's book pays does not cross the line");
            RoutePlan memory plan = solver.findBestRoutePlan(address(c), address(d), ord[i]);
            assertEq(plan.best.hops.length, 2, "the leader the judge admitted is the answer, never an empty plan");
            assertGe(_modelBps(q, ord[i], address(c) < address(mid))
                + _modelBps(q1, plan.best.hops[1].amountIn, address(mid) < address(d)), 9_000,
                "premise: the model refuses the plan's own amounts, only the judge admits the route");
            assertGt(plan.best.totalOut, 0, "a route that pays");
            (bool ok, bytes memory ret) = address(this).call(abi.encodeCall(this.settleExt, (plan, c, ord[i])));
            // Settles (the Router already holds it to singleOutFloor, `_settle`'s minOut) or is refused.
            if (!ok) assertEq(ret, abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, uint16(5)), "or the Router refuses it");
            vm.revertToState(snap);
        }
    }

    /// The leader's book pays nothing on its walk: the price sits on the lower edge of its only
    /// range [0, 60) of 1e24 and nothing lies below, so the single-range model reads ~0.997 of the
    /// order while the first crossing leaves the walk no liquidity. The re-assembly's output is 0;
    /// the book is handed back on `fl` and the leader is rebuilt without it (N1), so the V2 pair
    /// on the same two tokens takes the order. Red at c54fd92 (SolverE(5) on `totalOut == 0`).
    function test_LeaderWhoseBookPaysNothingIsRebuiltWithoutIt() public {
        MockERC20 c = new MockERC20("CCC", "CCC");
        MockERC20 d = new MockERC20("DDD", "DDD");
        if (address(d) < address(c)) (c, d) = (d, c);
        MockV3TickPool q = new MockV3TickPool(address(c), address(d), FEE, TS);
        q.initialize(0);
        q.addPosition(0, 60, 1e24);
        _fund(q, c, d, 1e26);
        MockV2Pair p = new MockV2Pair(address(c), address(d));
        c.mint(address(p), 1e20);
        d.mint(address(p), 1e20);
        p.setReserves(1e20, 1e20);
        hub.seedPool(address(p), BPC.KIND_V2, 30, address(0), address(c), address(d));
        uint256 amt = 1e18;
        (uint256 walked, ) = _judgeWalk(q, true, amt);
        assertEq(walked, 0, "premise: the walk crosses the range's lower edge into an empty book");
        assertGt(_modelOut(q, amt, true), amt * 9970 * 1e20 / (1e20 * 10_000 + amt * 9970),
            "premise: the model ranks the book above the pair");
        RoutePlan memory plan = solver.findBestRoutePlan(address(c), address(d), amt);
        assertEq(plan.best.hops.length, 1, "the order keeps a route");
        assertEq(plan.best.hops[0].legs.length, 1, "on one leg");
        assertEq(plan.best.hops[0].legs[0].pool, address(p), "the pair, rebuilt without the book that pays 0");
        assertGt(plan.best.totalOut, 0, "a route that pays");
        assertGt(_settle(plan, c, amt), 0, "the rebuilt route settles");
    }

    /// The leader the judge admitted keeps that verdict on its re-assembly. Hop 0 a deep range
    /// over a shallow book past its edge, whose walk finishes inside the hop's reads (measured)
    /// and pays less than the model promised, so its promise falls; hop 1 a range whose model
    /// figure, summed with hop 0's, crosses the line, and which the build's judge measured on
    /// what was left of the frame's reads. The re-assembly hands hop 0 the same amounts and every
    /// later hop less, and impact (model or walked) is monotone in the amount: asking the judge
    /// again on the frame's spent reads can only refuse (a leg left without reads has no verdict
    /// and refuses). The route the judge admitted stays the
    /// answer. Red at c54fd92 (SolverE(5)), on a hop 0 that did not finish its walk; since the
    /// judge admits only on finished walks (5408/5608), hop 0 is measured.
    function test_JudgedLeaderReassembledKeepsTheVerdict() public {
        (MockERC20 c, MockERC20 mid, MockERC20 d) = _three();
        MockV3TickPool q0 = _shallow(c, mid, 3e18, 1e18);
        MockV3TickPool q1 = _book(mid, d, 3e17, DEEP);
        _pair(c, d, 2e17);
        uint256 amt = ORD;
        bool z0 = address(c) < address(mid);
        bool z1 = address(mid) < address(d);
        uint256 out0 = _modelOut(q0, amt, z0);
        uint256 in1 = out0 - BPC.mulDivUp(out0, BPC.PROTOCOL_FEE_BPS, BPC.BPS);
        (uint256 w0, uint256 left0) = _judgeWalk(q0, z0, amt);
        uint256 win1 = w0 - BPC.mulDivUp(w0, BPC.PROTOCOL_FEE_BPS, BPC.BPS);
        uint256 m0 = _modelBps(q0, amt, z0);
        uint256 m1 = _modelBps(q1, in1, z1);
        assertLt(m0, 9_000, "premise: no leg crosses the line on the model");
        assertLt(m1, 9_000, "premise: no leg crosses the line on the model");
        assertGe(m0 + m1, 9_000, "premise: the model sum refuses the route, only the judge admits it");
        assertGt(left0, 0, "premise: hop 0's walk finishes inside the hop's reads");
        assertLt(w0, out0, "premise: hop 0's promise falls on the walk");
        (uint256 wb0, ) = _walkedBps(q0, z0, amt);
        assertLt(wb0, 9_000, "premise: what hop 0's book pays does not cross the line");
        assertGe(m0 + _modelBps(q1, win1, z1), 9_000, "premise: the model still refuses after the fall");
        RoutePlan memory plan = solver.findBestRoutePlan(address(c), address(d), amt);
        assertEq(plan.best.hops.length, 2, "the route the judge admitted keeps its verdict");
        uint256 pair = amt * 9970 * 2e17 / (2e17 * 10_000 + amt * 9970);
        assertGt(_settle(plan, c, amt), pair, "and settles above the pair the model alone leaves");
    }

    /// A leader whose book pays 0 beside a pair the ceiling refuses: no route pays the order,
    /// so the solve stops with SolverE(5) (no viable action reverts), never a plan of totalOut
    /// 0. Red at 24959f0 and at 2c8cbbe (a plan on the book, totalOut 0, singleOutFloor 0).
    function test_LeaderPayingNothingWithNoRebuildIsNotHandedOut() public {
        MockERC20 c = new MockERC20("CCC", "CCC");
        MockERC20 d = new MockERC20("DDD", "DDD");
        if (address(d) < address(c)) (c, d) = (d, c);
        MockV3TickPool q = new MockV3TickPool(address(c), address(d), FEE, TS);
        q.initialize(0);
        q.addPosition(0, 60, 1e24);
        _fund(q, c, d, 1e26);
        _pair(c, d, 5e16);
        (uint256 walked, ) = _judgeWalk(q, true, 1e18);
        assertEq(walked, 0, "premise: the book pays 0 on its walk");
        vm.expectRevert(_refusal());
        solver.findBestRoutePlan(address(c), address(d), 1e18);
    }

    // =========================================================================================
    //  (l) The judge admits only on measured legs (5408/5608): a concentrated leg whose book
    //  was not walked to its end inside the reads has no verdict, and the model's refusal stands.
    //  Red at 9b2855e: each route below was admitted on a sum of walked and model figures.
    // =========================================================================================

    /// @dev A deep range [0, 60) at the price and almost nothing past it: `n` adjacent 60-tick
    ///      stairs of `per`. The single-range model reads the leg as near 1:1; the book pays
    ///      about one tick of `cur` and cannot take the rest of the order.
    function _cliff(MockERC20 a, MockERC20 b, uint128 cur, uint128 per, uint256 n) internal returns (MockV3TickPool q) {
        q = _dense(a, b, cur, per, n);
    }

    /// Hop 0 is a cliff whose stairs spend the hop's 12 reads: its walk does not finish, its model
    /// figure is low, and its own book cannot take the order. Hop 1 (a thin range over a deep
    /// book, model >= 9,000) is measured near 1:1. No instrument gave the sum that admitted this
    /// route: hop 0 has no verdict, the route stays refused. Red under M-JUDGE-11.
    function test_UnfinishedWalkBesideAMeasuredHopStaysRefused() public {
        (MockERC20 c, MockERC20 mid, MockERC20 d) = _three();
        MockV3TickPool q0 = _cliff(c, mid, 1e20, 1e13, 40);
        MockV3TickPool q1 = _book(mid, d, 1e14, DEEP);
        bool z0 = address(c) < address(mid);
        bool z1 = address(mid) < address(d);
        (uint256 out0, uint256 left0) = _judgeWalk(q0, z0, ORD);
        assertTrue(out0 != type(uint256).max && left0 == 0, "premise: hop 0's walk answers, spends every read and does not finish");
        assertLt(_modelBps(q0, ORD, z0), 1_000, "premise: hop 0's model figure is low");
        (uint256 w0, ) = _walkedBps(q0, z0, ORD);
        assertGe(w0, 9_000, "premise: hop 0's own book destroys the order");
        uint256 in1 = out0 - BPC.mulDivUp(out0, BPC.PROTOCOL_FEE_BPS, BPC.BPS);
        assertGe(_modelBps(q1, in1, z1), 9_000, "premise: hop 1's model alone reaches the ceiling, so the judge runs");
        (uint256 out1, uint256 left1) = _judgeWalk(q1, z1, in1);
        assertTrue(out1 != type(uint256).max && left1 != 0, "premise: hop 1 is measured");
        (uint160 sp1, , , , , , ) = q1.slot0();
        assertLt(BPC.impactV3FromOut(out1, in1, sp1, z1), 1_000, "premise: hop 1's book pays near 1:1");
        vm.expectRevert(_refusal());
        solver.findBestRoutePlan(address(c), address(d), ORD);
    }

    /// 5608: two concentrated legs in hop 0, split by their current liquidity, so the model
    /// reads both alike (~6,700). The first (thin range, deep book) spends 8 of the hop's 12
    /// reads and is measured near 1:1; the second, a cliff, is handed 4, under the 6 a walk
    /// needs, and is not walked: its own book cannot take its share. Hop 1 (model ~6,700, the
    /// sum reaches the ceiling) is measured near 1:1. A leg left without reads has no verdict:
    /// the route stays refused. Red under M-JUDGE-12.
    function test_LegLeftWithoutReadsInItsHopStaysRefused() public {
        (MockERC20 c, MockERC20 mid, MockERC20 d) = _three();
        MockV3TickPool qa = _book(c, mid, 1e18, DEEP);
        MockV3TickPool qb = _cliff(c, mid, 3e18, 1e13, 40);
        MockV3TickPool q1 = _book(mid, d, 1e18, DEEP);
        bool z0 = address(c) < address(mid);
        bool z1 = address(mid) < address(d);
        uint256 ina = ORD;      // the split follows the current liquidity, 1 : 3 of 4 * ORD
        uint256 inb = 3 * ORD;
        (uint256 outa, uint256 lefta) = _judgeWalk(qa, z0, ina);
        assertTrue(outa != type(uint256).max && lefta == 4, "premise: the first leg is measured on 8 reads and leaves 4");
        (uint160 spa, , , , , , ) = qa.slot0();
        assertLt(BPC.impactV3FromOut(outa, ina, spa, z0), 1_000, "premise: the first leg's book pays near 1:1");
        uint256 ma = _modelBps(qa, ina, z0);
        uint256 mb = _modelBps(qb, inb, z0);
        assertTrue(ma < 9_000 && mb < 9_000, "premise: neither leg is a destroyer on the model");
        (uint256 wb, ) = _walkedBps(qb, z0, inb);
        assertGe(wb, 9_000, "premise: the second leg's own book cannot take its share");
        uint256 in1 = outa - BPC.mulDivUp(outa, BPC.PROTOCOL_FEE_BPS, BPC.BPS);
        assertGe((ma + mb) / 2 + _modelBps(q1, in1, z1), 9_000, "premise: the model figures reach the ceiling, so the judge runs");
        (uint256 out1, uint256 left1) = _judgeWalk(q1, z1, 4 * ORD);
        assertTrue(out1 != type(uint256).max && left1 != 0, "premise: hop 1 is measured, up to the whole order");
        (uint160 sp1, , , , , , ) = q1.slot0();
        assertLt(BPC.impactV3FromOut(out1, 4 * ORD, sp1, z1), 1_000, "premise: hop 1's book pays near 1:1");
        (bool okS, bytes memory retS) = address(solver).call(
            abi.encodeCall(BlazePhoenixSolver.findBestRoutePlan, (address(c), address(d), ORD / 25)));
        assertTrue(okS, "premise: a size the model admits keeps a route");
        Leg[] memory ls = abi.decode(retS, (RoutePlan)).best.hops[0].legs;
        assertTrue(ls.length == 2 && ls[0].pool == address(qa) && ls[1].pool == address(qb),
            "premise: the plan lists the measured book first, the cliff second");
        assertEq(ls[1].amountIn / ls[0].amountIn, 3, "premise: the split follows the current liquidity");
        (bool ok, bytes memory ret) = address(solver).call(
            abi.encodeCall(BlazePhoenixSolver.findBestRoutePlan, (address(c), address(d), 4 * ORD)));
        assertFalse(ok, "a leg left without reads has no verdict");
        assertEq(ret, _refusal(), "a refusal is SolverE(5)");
    }

    /// 5408: the frame's reads are spent before hop 1 is asked. The first topology (a dense book
    /// that does not finish, model >= 9,000) spends 12; the second's hop 0 (thin range, deep
    /// book) spends 8 and is measured near 1:1, so its hop 1 is handed the 4 left and is not
    /// walked. Hop 1 is a deep range at the price with nothing past it: low on the model, and
    /// on its own reads (shown first, the second topology alone) measured a destroyer and
    /// refused. A hop the frame hands no walk has no verdict: refused. Red under M-JUDGE-11.
    function test_HopHandedNoReadsByTheFrameStaysRefused() public {
        MockERC20 c = new MockERC20("CCC", "CCC");
        MockERC20 d = new MockERC20("DDD", "DDD");
        MockERC20 m1 = new MockERC20("M1", "M1");
        MockERC20 m2 = new MockERC20("M2", "M2");
        hub.addBridge(address(m1));
        hub.addBridge(address(m2));
        MockV3TickPool q0 = _book(c, m2, 1e17, DEEP);
        MockV3TickPool q1 = _endsAtTheBound(m2, d, 1e20);
        bool z0 = address(c) < address(m2);
        bool z1 = address(m2) < address(d);
        (uint256 out0, uint256 left0) = _judgeWalk(q0, z0, ORD);
        assertEq(HOP_READS - left0, 8, "premise: hop 0 spends 8 reads and is measured");
        uint256 in1 = out0 - BPC.mulDivUp(out0, BPC.PROTOCOL_FEE_BPS, BPC.BPS);
        assertLt(_modelBps(q1, in1, z1), 1_000, "premise: hop 1's model figure is low");
        (uint256 out1, uint256 left1) = _judgeWalk(q1, z1, in1);
        assertTrue(out1 != type(uint256).max && left1 != 0, "premise: hop 1, on its own 12 reads, is measured");
        (uint160 sp1, , , , , , ) = q1.slot0();
        assertGe(BPC.impactV3FromOut(out1, in1, sp1, z1), 9_000, "premise: what hop 1's book pays destroys the order");
        bytes memory ask = abi.encodeCall(BlazePhoenixSolver.findBestRoutePlan, (address(c), address(d), ORD));
        (bool ok, bytes memory ret) = address(solver).call(ask);
        assertFalse(ok, "premise: handed its own reads, hop 1 is measured and the route refused");
        assertEq(ret, _refusal(), "premise: that refusal is SolverE(5)");
        MockV3TickPool qd = _dense(c, m1, 1e17, 1e20, 40);
        _deepV2(m1, d);
        (, uint256 ld) = _judgeWalk(qd, address(c) < address(m1), ORD);
        assertEq(ld, 0, "premise: the first topology spends its hop's 12 reads");
        (ok, ret) = address(solver).call(ask);
        assertFalse(ok, "a hop the frame hands no walk has no verdict");
        assertEq(ret, _refusal(), "a refusal is SolverE(5)");
    }

    /// @dev The route's gate on Core's model figures, recomputed on the plan's legs; when it
    ///      reaches the ceiling the route exists only by the judge, and every concentrated leg
    ///      must then finish its walk on what its hop's 12 reads leave it, in the plan's order.
    function _admittedOnlyOnFinishedWalks(RoutePlan memory p) internal view returns (bool judged) {
        uint256 gate;
        for (uint256 h; h < p.best.hops.length; ++h) {
            Leg[] memory ls = p.best.hops[h].legs;
            uint256 hop;
            for (uint256 i; i < ls.length; ++i) {
                uint256 li = _modelFigure(ls[i]);
                hop += li;
                if (li >= 9_000) gate += 9_000;
            }
            if (ls.length > 0) gate += hop / ls.length;
        }
        if (gate < 9_000) return false;
        for (uint256 h; h < p.best.hops.length; ++h) {
            Leg[] memory ls = p.best.hops[h].legs;
            uint256 reads = HOP_READS;
            for (uint256 i; i < ls.length; ++i) {
                if (!BPC.kindHas(ls[i].kind, BPC.A_CONC_POOL)) continue;
                uint256 out;
                (out, reads) = BPC.v3PaysOnBudget(ls[i].pool, ls[i].amountIn, ls[i].zeroForOne, type(uint256).max, reads);
                assertTrue(out != type(uint256).max && reads != 0,
                    "a route the model refuses is admitted only when every concentrated leg finished its walk");
            }
        }
        return true;
    }

    /// Any route handed out whose model figures reach the ceiling was admitted by the judge, so
    /// each of its concentrated legs finishes its walk inside its hop's reads. Thin range `cur`,
    /// `s0` / `s1` stairs past the edge of hop 0 / hop 1 (0 or 1: the walk finishes; 2: it ends
    /// on its last read; 3 and up: it does not finish), one or two books at hop 0, one or two
    /// hops. Half the runs sit on the 0..3 boundary. Red at 9b2855e and under M-JUDGE-11.
    function testFuzz_AdmittedByTheJudgeMeansEveryConcentratedLegFinishedItsWalk(
        uint256 ord, uint256 cur, uint256 s0, uint256 s1, uint8 shape
    ) public {
        ord = bound(ord, 1e15, 1e24);
        cur = bound(cur, ord / 8, ord * 2);
        s0 = bound(s0, 0, 81);
        s1 = bound(s1, 0, 81);
        if (s0 > 40) s0 = (s0 - 41) % 4;
        if (s1 > 40) s1 = (s1 - 41) % 4;
        (MockERC20 c, MockERC20 mid, MockERC20 d) = _three();
        _stairs(c, mid, uint128(cur), uint128(cur / 100 + 1), s0, DEEP);
        if (shape & 1 != 0) _stairs(c, mid, uint128(cur), uint128(cur / 100 + 1), s1, DEEP);
        bool twoHops = shape & 2 != 0;
        if (twoHops) _stairs(mid, d, uint128(cur / 10 + 1), uint128(cur / 1000 + 1), s1, DEEP);
        (bool okPlan, bytes memory ret) = address(solver).call(abi.encodeCall(
            BlazePhoenixSolver.findBestRoutePlan, (address(c), address(twoHops ? d : mid), ord)));
        if (!okPlan) {
            assertEq(ret, _refusal(), "a refusal is SolverE(5)");
            return;
        }
        _admittedOnlyOnFinishedWalks(abi.decode(ret, (RoutePlan)));
    }

    function settleExt(RoutePlan memory plan, MockERC20 tin, uint256 amt) external returns (uint256) {
        return _settle(plan, tin, amt);
    }

    function _modelOut(MockV3TickPool q, uint256 amt, bool z) internal view returns (uint256) {
        (uint160 sp, , , , , , ) = q.slot0();
        return BPC.outV3(amt, sp, BPC.getLiquidity(address(q)), FEE, z, 0);
    }

    function _modelBps(MockV3TickPool q, uint256 amt, bool z) internal view returns (uint256) {
        (uint160 sp, , , , , , ) = q.slot0();
        return BPC.impactV3Bps(amt, sp, BPC.getLiquidity(address(q)), FEE, z);
    }

    /// @dev Two V2 pairs in a row: the judge never runs (no concentrated leg), so the folded
    ///      ceiling (gate + CAP per leg at >= CAP) must refuse exactly what the two reductions
    ///      refused (worst leg >= 9,000, or the hops' figures summed >= 9,000). Oracle: Core's own
    ///      V2 figure per leg, recomputed here; orders within 60 bps of the line are skipped.
    function testFuzz_FoldedCeilingRefusesWhatTheTwoReductionsRefuse(uint256 ord, uint256 r0, uint256 r1) public {
        ord = bound(ord, 1e15, 1e23);
        r0 = bound(r0, 1e18, 1e24);
        r1 = bound(r1, 1e18, 1e24);
        (MockERC20 c, MockERC20 mid, MockERC20 d) = _three();
        _pair(c, mid, r0);
        _pair(mid, d, r1);
        uint256 li0 = BPC.impactV2Bps(ord, r0);
        uint256 out0 = ord * 9970 * r0 / (r0 * 10_000 + ord * 9970);
        uint256 in1 = out0 - BPC.mulDivUp(out0, BPC.PROTOCOL_FEE_BPS, BPC.BPS);
        uint256 li1 = BPC.impactV2Bps(in1, r1);
        uint256 worst = li0 > li1 ? li0 : li1;
        uint256 sum = li0 + li1;
        if (_near(worst) || _near(sum)) return;
        bool oracleRefuses = worst >= 9_000 || sum >= 9_000;
        (bool okPlan, bytes memory ret) = address(solver).call(
            abi.encodeCall(BlazePhoenixSolver.findBestRoutePlan, (address(c), address(d), ord)));
        if (oracleRefuses) {
            assertFalse(okPlan, "the reductions refuse: the fold refuses");
            assertEq(ret, _refusal(), "a refusal is SolverE(5)");
        } else {
            assertTrue(okPlan, "the reductions admit: the fold admits");
        }
    }

    /// @dev The two-leg twin, in the shape of `test_L1498c1`: one hop splits between a deep
    ///      phantom book cut to dust by what it holds and a destroyer that takes the remainder, so
    ///      the hop's mean stays under the line while its worst leg may cross it, the case only
    ///      the fold's per-leg CAP term refuses. Neither book answers the judge's walk (no ticks),
    ///      so the judge cannot admit and the model's verdict stands. Oracle: an admitted route has every leg under
    ///      9,000 and the hops' means summed under 9,000, by Core's own figures recomputed on the
    ///      plan's legs (the reductions' admission); a refusal is SolverE(5). One hop or two.
    function testFuzz_FoldedCeilingRefusesWhatTheTwoReductionsRefuseOnATwoLegHop(
        uint256 ord, uint256 ld, bool twoHops
    ) public {
        ord = bound(ord, 1e21, 1e23);
        ld = bound(ld, 5e20, 5e22);
        (MockERC20 c, MockERC20 mid, MockERC20 d) = _three();
        // Spot 1.69 in the trade direction, as in L1498c1: the destroyer's probe lands in the band.
        uint160 spD = address(c) < address(mid) ? uint160(BPC.Q96 * 13 / 10) : uint160(BPC.Q96 * 10 / 13);
        _modelBook(c, mid, uint160(BPC.Q96), 1e26, 100e18);   // phantom: deep, holds dust
        _modelBook(c, mid, spD, uint128(ld), 100_000e18);       // destroyer: holds what it pays
        if (twoHops) _pair(mid, d, 1e24);
        (bool okPlan, bytes memory ret) = address(solver).call(abi.encodeCall(
            BlazePhoenixSolver.findBestRoutePlan, (address(c), address(twoHops ? d : mid), ord)));
        if (!okPlan) {
            assertEq(ret, _refusal(), "a refusal is SolverE(5)");
            return;
        }
        RoutePlan memory p = abi.decode(ret, (RoutePlan));
        uint256 sum;
        for (uint256 h; h < p.best.hops.length; ++h) {
            Leg[] memory ls = p.best.hops[h].legs;
            uint256 hop;
            for (uint256 i; i < ls.length; ++i) {
                uint256 li = _modelFigure(ls[i]);
                assertLt(li, 9_000, "an admitted route has no leg at or over the line");
                hop += li;
            }
            if (ls.length > 0) sum += hop / ls.length;
        }
        assertLt(sum, 9_000, "an admitted route has its hops' means summed under the line");
    }

    /// @dev A single-range book (state decoupled from holdings, no ticks): the judge's walk gets
    ///      no answer from it, so the leg has no verdict and the model's verdict stands.
    function _modelBook(MockERC20 a, MockERC20 b, uint160 sp, uint128 liq, uint256 holdsB) internal {
        MockV3Pool q = new MockV3Pool(address(a), address(b), FEE);
        q.setState(sp, liq);
        b.mint(address(q), holdsB);
        hub.seedPool(address(q), BPC.KIND_V3, FEE, address(0), address(a), address(b));
    }

    /// @dev Core's model figure for one leg (`_legImpactBps`, recomputed here).
    function _modelFigure(Leg memory L) internal view returns (uint256) {
        if (BPC.kindHas(L.kind, BPC.A_RESERVES)) {
            (uint256 r0, uint256 r1) = BPC.getReserves(L.pool);
            return BPC.impactV2Bps(L.amountIn, L.zeroForOne ? r0 : r1);
        }
        (uint160 sp, uint24 dynFee, bool dyn) = BPC.v3StateAndDynFee(L.pool);
        return BPC.impactV3Bps(L.amountIn, sp, BPC.getLiquidity(L.pool),
            BPC.quoteV3Fee(L.pool, uint24(L.fee), dynFee, dyn), L.zeroForOne);
    }

    function _near(uint256 x) internal pure returns (bool) {
        return x + 60 > 9_000 && x < 9_000 + 60;
    }

    function _pair(MockERC20 a, MockERC20 b, uint256 r) internal {
        MockV2Pair p = new MockV2Pair(address(a), address(b));
        a.mint(address(p), r);
        b.mint(address(p), r);
        p.setReserves(uint112(r), uint112(r));
        hub.seedPool(address(p), BPC.KIND_V2, 30, address(0), address(a), address(b));
    }
}
