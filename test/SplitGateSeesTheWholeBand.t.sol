// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  R2 - THE FUNNEL CUT (top-`budget` BY WEIGHT) RUNS BEFORE THE SPLIT GATE,
//       SO THE GATE'S "BEST SINGLE LEG AT FULL SIZE" IS COMPARED AGAINST A
//       SUBSET OF THE POOLS THE SOLVER SAW.
//
//  `_buildHop` (Solver.sol) applies two reductions to the same band survivors:
//    * the FUNNEL CUT (`_cutByWeight`, budget = MAX_LEGS_PER_STAGE = 4), which
//      keeps the top-`budget` survivors by WEIGHT (= measured depth); and
//    * the MIN-SPLIT GATE, which compares the split against the best single
//      survivor AT FULL SIZE - but only over the survivors that SURVIVED the
//      funnel cut (`_buildHop:943-948` walks `n`, not `cands.length`).
//
//  Weight is DEPTH. For a small order the best single leg is the best-PRICED
//  pool, which is not necessarily the deepest. When 5+ candidates survive the
//  band and one is a shallower-but-better-priced pool, the funnel cut discards
//  that pool FIRST (weight 100 against four weights of 10000), and the gate
//  never learns it existed. The plan is then the best DEEP pool, which pays
//  strictly less than the discarded pool would have paid alone - a violation
//  of the repo's own named relation MR-R1 ("split never worse than the best
//  single pool"), which RouteMetamorphicRelations.t.sol fuzzes with TWO pools
//  (never enough to trigger the cut) and SplitGateSeesEverySurvivor.t.sol
//  with THREE to five whose depth spread never makes a shallow pool the best.
//
//  BOUND. The cut can only discard pools INSIDE the +/-5% believability band, so
//  the discarded best single is at most MEDIAN_FILTER_BPS better priced than
//  the kept one; the measured ceiling over a 40k-trial random search is
//  ~475 bps, and it is reached exactly at the +5% band edge (below).
//
//  Reported by AnonSecure through the bug bounty programme (and found a day
//  later, independently, by our own economic review); this file is their proof
//  of concept. Since 2026-10-07 the gate measures every survivor of the band,
//  including the ones the cut dropped, so the defect test asserts MR-R1 holds.
//
//  forge test --match-path test/SplitGateSeesTheWholeBand.t.sol -vv
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixCore as BPC, RoutePlan} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";

contract SplitGateSeesTheWholeBandTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    MockERC20 A;
    MockERC20 B;

    uint256 constant ORDER = 1e20;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        solver = new BlazePhoenixSolver(address(hub));
        hub.setRoles(address(this), address(solver), address(this));
        A = new MockERC20("A", "A");
        B = new MockERC20("B", "B");
    }

    function _pool(uint256 rA, uint256 rB) internal returns (MockV2Pair p) {
        p = new MockV2Pair(address(A), address(B));
        A.mint(address(p), rA);
        B.mint(address(p), rB);
        (uint256 r0, uint256 r1) = address(A) < address(B) ? (rA, rB) : (rB, rA);
        p.setReserves(uint112(r0), uint112(r1));
        hub.seedPool(address(p), BPC.KIND_V2, 30, address(0), address(A), address(B));
    }

    /// @dev The oracle's own constant-product arithmetic (NOT outV2).
    function _cp(uint256 a, uint256 rIn, uint256 rOut) internal pure returns (uint256) {
        uint256 aFee = a * 997;
        return (aFee * rOut) / (rIn * 1000 + aFee);
    }

    /// Four deep pools 1e30/1e30 (rate 1.00, weight 10000) and one shallow pool
    /// 1e28/1.0499e28 (rate ~1.0499, weight 100). The shallow rate sits inside
    /// the +5% band around the depth-weighted median (which the four deep pools
    /// anchor at 1.00), so it is a legitimate survivor; the four deep pools
    /// exactly fill the leg budget, so it is the one the funnel cut discards.
    function _pools() internal returns (MockV2Pair shallow) {
        shallow = _pool(1e28, 1e28 * 10499 / 10000); // 1.0499e28
        for (uint256 i; i < 4; ++i) _pool(1e30, 1e30);
    }

    /// THE FINDING. Five band survivors, one of them the best single leg at full
    /// size; the plan must pay at least what that pool pays alone.
    function test_R2_FunnelCutExcludesTheBestSinglePool() public {
        MockV2Pair shallow = _pools();

        uint256 sAlone = _cp(ORDER, 1e28, 1e28 * 10499 / 10000);
        uint256 dAlone = _cp(ORDER, 1e30, 1e30);

        RoutePlan memory plan = solver.findBestRoutePlan(address(A), address(B), ORDER);
        uint256 lossBps = plan.best.totalOut < sAlone ? (sAlone - plan.best.totalOut) * 10_000 / sAlone : 0;

        emit log_named_uint("plan.totalOut              ", plan.best.totalOut);
        emit log_named_uint("shallow alone (best single)", sAlone);
        emit log_named_uint("deep alone (kept single)   ", dAlone);
        emit log_named_uint("legs in hop 0              ", plan.best.hops[0].legs.length);
        emit log_named_address("leg 0 pool                 ", plan.best.hops[0].legs[0].pool);
        emit log_named_uint("LOSS vs best single (bps)  ", lossBps);

        assertGt(sAlone, dAlone, "premise: the shallow pool is the better single leg");
        // MR-R1: the plan is never worse than a single pool the Solver measured.
        assertGe(plan.best.totalOut, sAlone,
            "the plan pays less than a single pool the Solver saw and measured");
        assertEq(lossBps, 0, "no loss against the best single");
        bool named;
        for (uint256 l; l < plan.best.hops[0].legs.length; ++l) {
            if (plan.best.hops[0].legs[l].pool == address(shallow)) named = true;
        }
        assertTrue(named, "the better-priced shallow pool is absent from the route");
    }

    /// CONTROL - the same five pools minus one deep pool: four candidates in
    /// total, so the funnel cut cannot fire. The plan keeps the shallow pool and
    /// pays it. Same Hub, same prices, one candidate fewer: the loss is the cut,
    /// not the price model.
    function test_R2_Control_FourCandidatesNoCutPaysTheBestSingle() public {
        BlazePhoenixHub h2 = new BlazePhoenixHub(address(this));
        h2.initialize(address(this), address(0));
        BlazePhoenixSolver s2 = new BlazePhoenixSolver(address(h2));
        h2.setRoles(address(this), address(s2), address(this));

        MockV2Pair p0 = new MockV2Pair(address(A), address(B));
        A.mint(address(p0), 1e28); B.mint(address(p0), 1e28 * 10499 / 10000);
        (uint256 r0, uint256 r1) = address(A) < address(B)
            ? (uint256(1e28), uint256(1e28 * 10499 / 10000))
            : (uint256(1e28 * 10499 / 10000), uint256(1e28));
        p0.setReserves(uint112(r0), uint112(r1));
        h2.seedPool(address(p0), BPC.KIND_V2, 30, address(0), address(A), address(B));
        for (uint256 i; i < 3; ++i) {
            MockV2Pair d = new MockV2Pair(address(A), address(B));
            A.mint(address(d), 1e30); B.mint(address(d), 1e30);
            d.setReserves(uint112(1e30), uint112(1e30));
            h2.seedPool(address(d), BPC.KIND_V2, 30, address(0), address(A), address(B));
        }

        uint256 sAlone = _cp(ORDER, 1e28, 1e28 * 10499 / 10000);
        RoutePlan memory plan = s2.findBestRoutePlan(address(A), address(B), ORDER);
        emit log_named_uint("control plan.totalOut", plan.best.totalOut);
        emit log_named_uint("control best single  ", sAlone);
        assertGe(plan.best.totalOut, sAlone, "control: no cut, so the plan pays the best single");
    }

    /// BOUND - the cut can only discard pools inside the +/-5% band, so the loss
    /// is capped by the band. Sweep the shallow pool's price across the band and
    /// assert the loss never exceeds the band ceiling (measured max ~475 bps).
    function test_R2_LossIsBoundedByTheBand() public {
        uint256[9] memory devs = [uint256(10_000), 10_050, 10_100, 10_200, 10_300, 10_350, 10_400, 10_450, 10_499];
        for (uint256 d; d < devs.length; ++d) {
            BlazePhoenixHub h = new BlazePhoenixHub(address(this));
            h.initialize(address(this), address(0));
            BlazePhoenixSolver s = new BlazePhoenixSolver(address(h));
            h.setRoles(address(this), address(s), address(this));
            uint256 rB = 1e28 * devs[d] / 10_000;
            MockV2Pair sh = new MockV2Pair(address(A), address(B));
            A.mint(address(sh), 1e28); B.mint(address(sh), rB);
            (uint256 a0, uint256 a1) = address(A) < address(B) ? (uint256(1e28), rB) : (rB, uint256(1e28));
            sh.setReserves(uint112(a0), uint112(a1));
            h.seedPool(address(sh), BPC.KIND_V2, 30, address(0), address(A), address(B));
            for (uint256 i; i < 4; ++i) {
                MockV2Pair dp = new MockV2Pair(address(A), address(B));
                A.mint(address(dp), 1e30); B.mint(address(dp), 1e30);
                dp.setReserves(uint112(1e30), uint112(1e30));
                h.seedPool(address(dp), BPC.KIND_V2, 30, address(0), address(A), address(B));
            }
            uint256 best = _cp(ORDER, 1e28, rB);
            RoutePlan memory plan = s.findBestRoutePlan(address(A), address(B), ORDER);
            uint256 loss = plan.best.totalOut < best ? (best - plan.best.totalOut) * 10_000 / best : 0;
            emit log_named_uint("dev bps / loss bps", devs[d]);
            emit log_named_uint("   loss bps       ", loss);
            assertLe(loss, 500, "the cut's loss can never exceed the band width");
        }
    }
}
