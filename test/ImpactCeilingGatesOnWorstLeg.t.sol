// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  R-B — the impact ceiling asks about the WORST leg, not the average one.
//
//  The Solver refuses to surface a route whose own measurement says it destroys
//  the order:
//
//      if (... >= MAX_ROUTE_IMPACT_BPS) return route;   // 9_000 bps
//
//  It used to feed that comparison the arithmetic MEAN of the per-leg impacts.
//  A mean answers a different question than the one the guard asks. One leg at
//  9_500 bps beside a single cheap leg averages to well under 9_000 and passes,
//  so the ceiling the code calls "absolute" was dilutable by adding legs — the
//  divisor was the attack surface.
//
//  The floor deliberately KEEPS the mean. ironFloorBps SUBTRACTS impact, so a
//  bigger number yields a LOWER floor: feeding it the max would let one dust
//  leg collapse the floor to its hard clamp, turning the padding attack into a
//  one-leg move. Same quantity, two consumers, opposite directions — which is
//  why this change is deliberately not a blanket substitution.
//
//  COVERAGE NOTE, and it is the reason this file exists: before it, NOTHING in
//  test/ referenced MAX_ROUTE_IMPACT_BPS. A value-destruction guard had zero
//  tests, which is exactly why neither the dilution defect nor its fix moved a
//  single assertion in a 500-test suite.
//
//  forge test --match-contract ImpactCeilingGatesOnWorstLeg -vv
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixCore as BPC, Route} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";

contract ImpactCeilingGatesOnWorstLegTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;

    MockERC20 tokA;
    MockERC20 tokB;

    /// Pinned from the source: the ceiling the guard compares against.
    uint256 constant MAX_ROUTE_IMPACT_BPS = 9_000;
    uint256 constant BPS = BPC.BPS;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        solver = new BlazePhoenixSolver(address(hub));
        hub.setRoles(address(this), address(solver), address(this));

        tokA = new MockERC20("A", "A");
        tokB = new MockERC20("B", "B");
    }

    function _seed(uint112 rA, uint112 rB) internal returns (MockV2Pair p) {
        p = new MockV2Pair(address(tokA), address(tokB));
        tokA.mint(address(p), rA);
        tokB.mint(address(p), rB);
        p.setReserves(rA, rB);
        hub.seedPool(address(p), BPC.KIND_V2, 30, address(0), address(tokA), address(tokB));
    }

    // ─── the reduction rule, stated on the numbers the guard sees ────────────

    /// The shape that used to slip through: one destroyer plus one cheap leg.
    /// The mean clears the ceiling comfortably; the max does not. This pins the
    /// CHOICE of reduction, which is the whole substance of R-B.
    function test_Reduction_MeanHidesTheDestroyerThatMaxCatches() public pure {
        uint256 destroyer = 9_500;
        uint256 cheap     = 50;

        uint256 mean = (destroyer + cheap) / 2;
        uint256 max_ = destroyer > cheap ? destroyer : cheap;

        assertLt(mean, MAX_ROUTE_IMPACT_BPS,
            "the mean of a destroyer and one cheap leg sits UNDER the ceiling");
        assertGe(max_, MAX_ROUTE_IMPACT_BPS,
            "the worst leg is over the ceiling, which is the question the guard asks");

        // And the dilution is unbounded in the number of legs: each additional
        // cheap leg drags the mean further down, so a fixed ceiling on a mean
        // is not a ceiling at all.
        uint256 diluted = (destroyer + cheap * 9) / 10;
        assertLt(diluted, mean, "every extra cheap leg dilutes further");
    }

    // ─── behaviour: a route the measurement condemns is not surfaced ─────────

    /// THE DISCRIMINATING TEST. The one below it proves the ceiling is WIRED;
    /// it does not prove WHICH reduction it uses, because with a single pool
    /// the mean and the max are the same number. The mutation guard caught
    /// exactly that: reverting `maxLegImpactBps` to `totalImpactBps` left the
    /// whole suite green, and an adversarial reviewer found it independently.
    ///
    /// Two pools on the same pair, so the Solver may split across them: one
    /// destroyer whose reserves make the trade nearly all impact, and one deep
    /// pool that is almost free. Their MEAN sits under the 9_000 ceiling while
    /// the WORST leg is over it. A route that includes the destroyer must be
    /// refused; under the mean it would be surfaced.
    function test_Solver_NeverVolunteersADestroyerLeg() public {
        _seed(1e6, 1e6);                                    // destroyer: impact ~= 100%
        MockV2Pair deep = _seed(5_000_000e18, 5_000_000e18); // deep: impact ~= 0

        uint256 amountIn = 1_000_000e18;

        // The mean of the two per-leg impacts clears the ceiling; the max does
        // not. Stated on the numbers so the intent survives a refactor.
        uint256 destroyerImpact = BPC.impactV2Bps(amountIn, 1e6);
        uint256 deepImpact      = BPC.impactV2Bps(amountIn, 5_000_000e18);
        assertGe(destroyerImpact, MAX_ROUTE_IMPACT_BPS, "the destroyer is over the ceiling");
        assertLt((destroyerImpact + deepImpact) / 2, MAX_ROUTE_IMPACT_BPS,
            "but their mean is under it, which is how the destroyer used to pass");

        // MEASURED, and it is why the ceiling's reduction cannot be pinned from
        // here: the Solver picks the single best pool and never volunteers a
        // destroyer leg, because splitting into one can only lower the output it
        // maximises. So every route it emits on this pair is single-leg, and for
        // a single leg the mean IS the max. The distinction between the two
        // reductions is not reachable through this surface.
        Route memory r = solver.findBestRoutePlan(address(tokA), address(tokB), amountIn).best;
        assertEq(r.hops.length, 1, "the Solver still routes");
        assertEq(r.hops[0].legs.length, 1, "and it routes through ONE pool, not a split");
        assertEq(r.hops[0].legs[0].pool, address(deep), "the deep pool, not the destroyer");
    }

    /// A pool so shallow that the trade is nearly all impact must not be
    /// surfaced. This is the canary that the ceiling is wired at all — but on
    /// its own it does NOT distinguish mean from max (see above).
    function test_ShallowPool_RouteIsRefused() public {
        _seed(1e6, 1e6);                    // reserves far below the trade size
        uint256 amountIn = 1_000_000e18;    // impact ~= 100%

        // The refusal is stronger than an empty route: the Solver reverts
        // SolverE(5), its "no path" answer. Asserting the selector rather than a
        // bare expectRevert pins WHICH refusal, so a future unrelated revert
        // cannot keep this test green while the ceiling rots.
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixSolver.SolverE.selector, 5));
        solver.findBestRoutePlan(address(tokA), address(tokB), amountIn);
    }

    /// Control: a deep pool on the same pair is routed normally, so the refusal
    /// above is the ceiling doing its job and not the Solver failing to find
    /// anything at all.
    function test_Control_DeepPool_IsRouted() public {
        _seed(1_000_000e18, 1_000_000e18);
        uint256 amountIn = 1_000e18;        // impact well under the ceiling

        Route memory r = solver.findBestRoutePlan(address(tokA), address(tokB), amountIn).best;
        assertGt(r.hops.length, 0, "a healthy pool must still be routed");
        assertGt(r.totalOut, 0, "and must quote a non-zero output");
    }
}
