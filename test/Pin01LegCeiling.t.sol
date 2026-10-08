// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  PIN-01 - "how many legs fit in a hop?"
//
//  Two producers of one quantity, with two values:
//    Solver.MAX_LEGS_PER_STAGE = 4
//    Router.MAX_LEGS_PER_HOP   = 5
//  The relation that must hold - the Solver never proposes a hop the Router refuses,
//  MAX_LEGS_PER_STAGE <= MAX_LEGS_PER_HOP - is pinned here on four independent faces:
//   1. both VALUES, read by probe (a 4 -> 5 or 5 -> 4 edit goes red);
//   2. the RELATION stage <= perHop;
//   3. the Router really accepts 5 legs in a hop and refuses 6 with RouterE(3);
//   4. faced with six venues on one pair, the Solver never builds a hop wider than stage.
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, RoutePlan, Hop, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";

/// @dev Exposes the internal constants without widening the contracts' surface
///      (the same probe pattern as test/KindMaskQuestionSeparation.t.sol).
contract SolverCeilingProbe is BlazePhoenixSolver {
    constructor(address h) BlazePhoenixSolver(h) {}
    function stageLegs()  external pure returns (uint8) { return MAX_LEGS_PER_STAGE; }
    function globalLegs() external pure returns (uint8) { return MAX_LEGS; }
}

contract RouterCeilingProbe is BlazePhoenixRouter {
    constructor(address h, address s, address a, address t1, address t2)
        BlazePhoenixRouter(h, s, a, t1, t2) {}
    function perHopLegs() external pure returns (uint8) { return MAX_LEGS_PER_HOP; }
}

contract Pin01LegCeilingTest is Test {
    BlazePhoenixHub hub;
    SolverCeilingProbe solver;
    RouterCeilingProbe router;
    MockERC20 ta;
    MockERC20 tb;
    MockV2Pair[6] pools;

    address user = address(0xBEEF);
    uint112 constant RESERVE = uint112(10_000_000e18);
    uint256 constant AMT = 100_000e18;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        solver = new SolverCeilingProbe(address(hub));
        router = new RouterCeilingProbe(
            address(hub), address(solver), address(this), address(0xFEE1), address(0xFEE2)
        );
        hub.setRoles(address(router), address(solver), address(this));

        ta = new MockERC20("A", "A");
        tb = new MockERC20("B", "B");
        // Six venues on ONE pair, of unequal depth: with 6 candidates the per-hop
        // budget (4) really binds; otherwise face 4 would hold vacuously.
        for (uint256 i; i < 6; ++i) {
            MockV2Pair p = new MockV2Pair(address(ta), address(tb));
            uint112 r = uint112(uint256(RESERVE) / (i + 1));
            ta.mint(address(p), r);
            tb.mint(address(p), r);
            p.setReserves(r, r);
            hub.seedPool(address(p), BPC.KIND_V2, 30, address(0), address(ta), address(tb));
            pools[i] = p;
        }

        ta.mint(user, 10_000_000e18);
        vm.prank(user);
        ta.approve(address(router), type(uint256).max);
    }

    // ── 1+2. The values and the relation ────────────────────────────────────

    /// The two values and the relation between them.
    function test_Constants_StageBudgetIsNotAboveTheRouterCeiling() public view {
        uint8 stage  = solver.stageLegs();
        uint8 perHop = router.perHopLegs();

        assertEq(stage, 4, "Solver.MAX_LEGS_PER_STAGE changed (PIN-01)");
        assertEq(perHop, 5, "Router.MAX_LEGS_PER_HOP changed (PIN-01)");
        assertLe(stage, perHop, "the Solver could propose a hop the Router refuses");
    }

    /// Control: the budgets answer different questions but are ordered -
    /// the global budget (11) is >= the per-hop one, and the per-stage one is the smallest.
    function test_Constants_TheThreeBudgetsAreOrdered() public view {
        uint8 stage  = solver.stageLegs();
        uint8 global = solver.globalLegs();
        assertLe(stage, global, "the per-hop budget exceeds the global one");
        assertGt(global, 0, "the global budget is zero");
    }

    // ── 3. The Router's ceiling, measured from both sides ───────────────────

    /// 5 legs in one hop - exactly MAX_LEGS_PER_HOP - must settle.
    function test_Router_AcceptsFiveLegsInOneHop() public {
        Route memory r = _oneHopWith(5, AMT);   // built before the prank (it reads the pools)
        vm.prank(user);
        uint256 out = router.swapExactIn(r, AMT, 1, user, block.timestamp + 1);
        assertGt(out, 0, "a five-leg hop must settle");
        assertEq(ta.balanceOf(address(router)), 0, "the Router must hold nothing");
    }

    /// 6 legs in one hop - one above - must be refused with RouterE(3).
    function test_Router_RefusesSixLegsInOneHop() public {
        Route memory r = _oneHopWith(6, AMT);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, 3));
        router.swapExactIn(r, AMT, 1, user, block.timestamp + 1);
    }

    // ── 4. The Solver's side ────────────────────────────────────────────────

    /// With six competing venues on the pair, the Solver never builds a hop wider
    /// than its per-stage budget. A Solver 4 -> 5 mutant would build a hop of 5
    /// and this assertion would go red.
    function test_Solver_NeverBuildsAHopWiderThanItsStageBudget() public view {
        RoutePlan memory plan = solver.findBestRoutePlan(address(ta), address(tb), AMT);
        uint8 cap = solver.stageLegs();

        assertGt(plan.best.hops.length, 0, "premise: the Solver returned a plan");
        uint256 total;
        for (uint256 h; h < plan.best.hops.length; ++h) {
            uint256 legs = plan.best.hops[h].legs.length;
            total += legs;
            assertLe(legs, cap, "the Solver built a hop wider than MAX_LEGS_PER_STAGE");
        }
        assertGt(total, 0, "premise: the plan has at least one leg");
    }

    // ── helpers ─────────────────────────────────────────────────────────────

    function _leg(MockV2Pair p, address tIn, uint256 amt) private view returns (Leg memory) {
        (uint112 r0, uint112 r1, ) = p.getReserves();
        bool zfo = p.token0() == tIn;
        uint256 q = BPC.outV2(amt, zfo ? r0 : r1, zfo ? r1 : r0, 30);
        return Leg({
            pool: address(p), hooks: address(0), kind: BPC.KIND_V2, fee: 30, tickSpacing: 0,
            zeroForOne: zfo, stable: false, amountIn: amt, expectedOut: q, auxId: bytes32(0)
        });
    }

    /// An A -> B hop with `nLegs` legs, one per pool[0..nLegs-1], the input split
    /// evenly (the Router rescales by the hop's real proportion).
    function _oneHopWith(uint256 nLegs, uint256 amt) private view returns (Route memory r) {
        Leg[] memory legs = new Leg[](nLegs);
        uint256 expected;
        uint256 part = amt / nLegs;
        for (uint256 i; i < nLegs; ++i) {
            uint256 p = (i == nLegs - 1) ? (amt - part * (nLegs - 1)) : part;
            legs[i] = _leg(pools[i], address(ta), p);
            expected += legs[i].expectedOut;
        }
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({
            tokenIn: address(ta), tokenOut: address(tb), amountIn: amt, expectedOut: expected, legs: legs
        });
        r = Route({
            hops: hops, totalOut: expected, singleOut: expected, singleOutFloor: 0,
            expectedImpactBps: 0, confidenceWad: 0, estGas: 0, hasSurplus: false, isV4Bundle: false
        });
    }
}
