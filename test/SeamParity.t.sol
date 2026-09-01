// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  SeamParity — four relationships that are correct today and were pinned by
//  nothing. Each test pins one seam between the plan side (Solver/Core) and
//  the execution side (Router), so a future edit to ONE side of a pair cannot
//  drift silently past a green suite.
//
//  1. The Solidly no-answer fallback haircut (`* 9800 / BPS`) is a literal
//     written TWICE — Core.universalQuote's Solidly arm and the Router's
//     Solidly execution path — with no shared constant. It only fires on a
//     fork whose pair hides getAmountOut, the one venue family with no exact
//     oracle, so a drift between the copies would be silent. Pinned by an
//     exact quote == delivery parity through that arm.
//
//  2. The executor's per-hop leg cap (Router.MAX_LEGS_PER_HOP) and the
//     planner's per-hop budget (Solver.MAX_LEGS_PER_STAGE) name the same
//     concept and hold different values. Safe only while executor >= planner;
//     nothing asserted the direction. Pinned by the mirror comparison, by a
//     behavioural boundary probe of the executor's cap, and by executing a
//     Solver-emitted max-split route through the Router.
//
//  3. The Solver's GLOBAL leg ceiling (MAX_LEGS = 11) has no executor
//     counterpart: the Router validates legs per hop only. Pinned by the
//     concrete consequence — a 12-leg hand-built route, more legs than the
//     Solver can ever emit, executes to completion.
//
//  4. The absolute impact ceiling (MAX_ROUTE_IMPACT_BPS = 9_000) exists only
//     on the plan side. The Router computes impact but never refuses on it:
//     a hand-built route into a near-empty pool executes, held only by the
//     protocol floor (fill QUALITY, relative to the Router's own re-quote)
//     and the user's own userMinOut (fill VALUE). Pinned with numbers.
//
//  forge test --match-contract SeamParity -vv
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {
    BlazePhoenixCore as BPC,
    Route, Hop, Leg, RoutePlan, QuoteCtx
} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";
import {MockSolidlyPair} from "./mocks/MockSolidlyPair.sol";

contract SeamParityTest is Test {
    BlazePhoenixHub    hub;
    BlazePhoenixSolver solver;
    BlazePhoenixRouter router;
    MockERC20 tokA; // tokenIn of every route here
    MockERC20 tokB; // tokenOut

    address treasury1 = address(0xFEE1);
    address treasury2 = address(0xFEE2);
    address user      = address(0xBEEF);

    bool aFirst; // does tokA sort as token0 in an (A,B) pair?

    // ─── Mirrored plan/exec constants ───────────────────────────────────────
    //
    // All four constants below are `internal constant` in their contracts —
    // not externally readable — so the test MIRRORS them. Each mirror states
    // where it was read from; the Router-side mirror is additionally verified
    // BEHAVIOURALLY in test_Seam2_RouterCap_BoundaryProbe (accept at the cap,
    // RouterE(3) one past it), so that mirror cannot rot silently.

    /// Mirrored from src/BlazePhoenixRouter.sol:
    ///     `uint8 internal constant MAX_LEGS_PER_HOP = 5;`
    /// (internal — no getter). Behaviourally re-verified below.
    uint256 constant ROUTER_MAX_LEGS_PER_HOP = 5;

    /// Mirrored from src/BlazePhoenixSolver.sol:
    ///     `uint8 internal constant MAX_LEGS_PER_STAGE = 4;`
    /// (internal — no getter). Upper-bounded behaviourally by asserting the
    /// Solver never emits a hop with more legs than this even when offered
    /// more candidates than the budget.
    uint256 constant SOLVER_MAX_LEGS_PER_STAGE = 4;

    /// Mirrored from src/BlazePhoenixSolver.sol:
    ///     `uint8 internal constant MAX_LEGS = 11;`
    /// (internal — no getter). The Router has NO counterpart of this value;
    /// that absence is exactly what test_Seam3 pins.
    uint256 constant SOLVER_MAX_LEGS = 11;

    /// Mirrored from src/BlazePhoenixSolver.sol:
    ///     `uint16 internal constant MAX_ROUTE_IMPACT_BPS = 9_000;`
    /// (internal — no getter). Same mirror ImpactCeilingGatesOnWorstLeg uses.
    uint256 constant SOLVER_MAX_ROUTE_IMPACT_BPS = 9_000;

    uint112 constant RESERVE_DEEP = 1_000_000e18;
    uint256 constant BPS = BPC.BPS;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        tokA = new MockERC20("A", "A");
        tokB = new MockERC20("B", "B");
        aFirst = address(tokA) < address(tokB);
        solver = new BlazePhoenixSolver(address(hub));
        router = new BlazePhoenixRouter(
            address(hub), address(solver), address(this), treasury1, treasury2
        );
        tokA.mint(user, 10_000_000e18);
        vm.prank(user);
        tokA.approve(address(router), type(uint256).max);
    }

    // ─── shared builders ─────────────────────────────────────────────────────

    /// Net input after the protocol's input-side fee: hop 0 charges
    /// mulDivUp(base, PROTOCOL_FEE_BPS, BPS) before any leg spends.
    function _netIn(uint256 a) internal pure returns (uint256) {
        return a - BPC.mulDivUp(a, BPC.PROTOCOL_FEE_BPS, BPS);
    }

    function _leg(address pool, uint8 kind, bool zf, uint256 aIn, uint256 eOut)
        internal pure returns (Leg memory)
    {
        return Leg({
            pool: pool, hooks: address(0), kind: kind, fee: 30,
            tickSpacing: 0, zeroForOne: zf, stable: false,
            amountIn: aIn, expectedOut: eOut, auxId: bytes32(0)
        });
    }

    function _routeFromHops(Hop[] memory hops, uint256 totalOut)
        internal pure returns (Route memory)
    {
        return Route({
            hops: hops, totalOut: totalOut, singleOut: totalOut,
            singleOutFloor: 0, expectedImpactBps: 0, confidenceWad: 0,
            estGas: 0, hasSurplus: false, isV4Bundle: false
        });
    }

    /// A fresh funded V2 pair, NOT registered in the Hub — the raw material of
    /// a hand-built route (the Router's direct door needs no admission).
    function _v2Pair(uint112 rA, uint112 rB) internal returns (MockV2Pair p) {
        p = new MockV2Pair(address(tokA), address(tokB));
        tokA.mint(address(p), rA);
        tokB.mint(address(p), rB);
        (uint112 r0, uint112 r1) = aFirst ? (rA, rB) : (rB, rA);
        p.setReserves(r0, r1);
    }

    /// One hop of `n` equal legs, each into its own fresh deep pool.
    /// Direction: aToB selects tokenIn/tokenOut and the legs' zeroForOne.
    function _fanHop(uint256 n, bool aToB, uint256 hopIn)
        internal returns (Hop memory hop, uint256 outSum)
    {
        Leg[] memory legs = new Leg[](n);
        uint256 legIn = hopIn / n;
        for (uint256 i; i < n; ++i) {
            MockV2Pair p = _v2Pair(RESERVE_DEEP, RESERVE_DEEP);
            uint256 legOut = BPC.outV2(legIn, RESERVE_DEEP, RESERVE_DEEP, 30);
            legs[i] = _leg(address(p), BPC.KIND_V2, aToB ? aFirst : !aFirst, legIn, legOut);
            outSum += legOut;
        }
        hop = Hop({
            tokenIn: aToB ? address(tokA) : address(tokB),
            tokenOut: aToB ? address(tokB) : address(tokA),
            amountIn: legIn * n, // == Σ leg.amountIn: one truth (issue #1)
            expectedOut: outSum,
            legs: legs
        });
    }

    // =========================================================================
    //  SEAM 1 — the duplicated Solidly haircut literal.
    //
    //  Every other multi-site literal (protocol fee, V2 fee ceiling, the curve
    //  itself) was collapsed to a single Core producer with a parity test; the
    //  200 bps no-answer haircut was missed and lives as `* 9800 / BPS` in two
    //  files. This test drives BOTH copies over the same pool and the same
    //  input and demands exact agreement. If either copy is ever edited alone,
    //  quote != delivery and this fails.
    // =========================================================================

    function test_Seam1_SolidlyHaircut_CoreQuoteEqualsRouterDelivery() public {
        MockSolidlyPair pair = new MockSolidlyPair(address(tokA), address(tokB), false);
        tokA.mint(address(pair), RESERVE_DEEP);
        tokB.mint(address(pair), RESERVE_DEEP);
        pair.setReserves(RESERVE_DEEP, RESERVE_DEEP);
        // Hide getAmountOut: the ONE venue family with no exact oracle, so
        // both channels are forced onto the replicated-curve fallback where
        // the two literals live.
        pair.setHideGetAmountOut(true);

        uint256 amountIn = 50_000e18;
        uint256 netIn = _netIn(amountIn); // the input the leg actually spends

        // Precondition: the pool really answers nothing, on the exact input
        // the executor will ask about — both sides are on the fallback arm.
        assertEq(
            BPC.solidlyGetAmountOut(address(pair), netIn, address(tokA)), 0,
            "harness: getAmountOut must be hidden for the fallback to fire"
        );

        // The Core's quote, through universalQuote's Solidly arm, at the same
        // input the Router will push into the pool.
        QuoteCtx memory ctx = QuoteCtx({
            kind: BPC.KIND_SOLIDLY, pool: address(pair), zeroForOne: aFirst,
            fee: 30, tickSpacing: 0, stable: false,
            tokenIn: address(tokA), tokenOther: address(tokB),
            hooks: address(0), v4Manager: address(0), decIn1: 0, decOther1: 0
        });
        (uint256 coreQuote, ) = BPC.universalQuote(ctx, netIn);
        assertGt(coreQuote, 0, "the fallback quote must be positive");

        // Control that the HAIRCUT arm was really taken: the quote sits
        // strictly below the raw replicated curve. (Deliberately does not
        // restate the 9800 literal — the seam is the AGREEMENT of the two
        // copies, not this test owning a third one.)
        uint256 rawCurve = BPC.solidlyCurveOut(
            address(pair), netIn, RESERVE_DEEP, RESERVE_DEEP, false, 30, address(tokA)
        );
        assertLt(coreQuote, rawCurve, "the no-answer haircut must have been applied");

        // An honest planner's attestation for the nominal input.
        (uint256 attested, ) = BPC.universalQuote(ctx, amountIn);
        Leg[] memory legs = new Leg[](1);
        legs[0] = _leg(address(pair), BPC.KIND_SOLIDLY, aFirst, amountIn, attested);
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({
            tokenIn: address(tokA), tokenOut: address(tokB),
            amountIn: amountIn, expectedOut: attested, legs: legs
        });

        vm.prank(user);
        uint256 delivered = router.swapExactIn(
            _routeFromHops(hops, attested), amountIn, 1, user, block.timestamp + 1
        );

        // THE SEAM: Core's `out = (out * 9800) / BPS` and the Router's
        // `outAmt = (outAmt * 9800) / BPC.BPS` must be the same number. A
        // drift in either copy breaks this exact equality.
        assertEq(
            delivered, coreQuote,
            "Solidly no-answer haircut drifted: Core quote != Router delivery"
        );
    }

    // =========================================================================
    //  SEAM 2 — legs per hop: the executor must cover the planner.
    //
    //  Router.MAX_LEGS_PER_HOP (execution cap) and Solver.MAX_LEGS_PER_STAGE
    //  (planning budget) name the same concept with different values. The safe
    //  direction is executor >= planner; if someone lowered the Router's cap
    //  below the Solver's budget, honest planned routes would start reverting
    //  RouterE(3) and nothing would catch it. Three pins, weakest to hardest.
    // =========================================================================

    /// The direction itself, on the mirrored constants.
    function test_Seam2_LegBudget_ExecutorCapCoversPlannerBudget() public pure {
        assertGe(
            ROUTER_MAX_LEGS_PER_HOP, SOLVER_MAX_LEGS_PER_STAGE,
            "executor's per-hop cap fell below the planner's budget: honest planned routes will revert"
        );
    }

    /// Behavioural anchor of the ROUTER mirror: a hop with exactly the cap
    /// executes; one leg past it is refused with RouterE(3). If the source
    /// constant moves, one of these two halves fails and the mirror is caught.
    function test_Seam2_RouterCap_BoundaryProbe() public {
        // At the cap: 5 legs across 5 deep pools execute and deliver.
        (Hop memory hopOk, uint256 outOk) =
            _fanHop(ROUTER_MAX_LEGS_PER_HOP, true, 5_000e18);
        Hop[] memory hops = new Hop[](1);
        hops[0] = hopOk;
        vm.prank(user);
        uint256 delivered = router.swapExactIn(
            _routeFromHops(hops, outOk), 5_000e18, 1, user, block.timestamp + 1
        );
        assertGt(delivered, 0, "a hop at MAX_LEGS_PER_HOP must execute");

        // One past the cap: refused before any leg runs.
        (Hop memory hopOver, uint256 outOver) =
            _fanHop(ROUTER_MAX_LEGS_PER_HOP + 1, true, 6_000e18);
        hops[0] = hopOver;
        Route memory over = _routeFromHops(hops, outOver);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, uint16(3)));
        router.swapExactIn(over, 6_000e18, 1, user, block.timestamp + 1);
    }

    /// The seam end-to-end: offered MORE candidates than its per-hop budget,
    /// the Solver splits up to that budget and never past it — and the route
    /// it emits executes through the Router. This is the sentence "the
    /// executor accepts everything the planner produces", run, not assumed.
    function test_Seam2_SolverMaxSplit_ExecutesThroughRouter() public {
        // Six identical deep pools on the pair: more candidates than the
        // stage budget, and an order big enough (10% of depth) that splitting
        // is strictly better than any single pool.
        for (uint256 i; i < 6; ++i) {
            MockV2Pair p = _v2Pair(RESERVE_DEEP, RESERVE_DEEP);
            hub.seedPool(address(p), BPC.KIND_V2, 30, address(0), address(tokA), address(tokB));
        }
        uint256 order = 100_000e18;

        Route memory best = solver.findBestRoutePlan(address(tokA), address(tokB), order).best;
        assertEq(best.hops.length, 1, "direct pair: single hop expected");
        uint256 emitted = best.hops[0].legs.length;
        assertGt(emitted, 1, "with six identical deep pools and a 10%-of-depth order the Solver splits");
        assertLe(
            emitted, SOLVER_MAX_LEGS_PER_STAGE,
            "the Solver emitted more legs per hop than its mirrored budget - update the mirror"
        );
        assertLe(
            emitted, ROUTER_MAX_LEGS_PER_HOP,
            "the planner's emission exceeds the executor's cap: planned routes revert"
        );

        vm.prank(user);
        uint256 delivered = router.swapExactIn(best, order, 1, user, block.timestamp + 1);
        assertGt(delivered, 0, "a Solver-planned max-split route must execute through the Router");
    }

    // =========================================================================
    //  SEAM 3 — the global leg ceiling exists only on the plan side.
    //
    //  The Solver refuses any route beyond MAX_LEGS = 11 total. The Router has
    //  NO global route-leg cap — only the per-hop one — so the concrete
    //  consequence is pinned: a hand-built 12-leg route, more legs than the
    //  Solver can ever emit, sails through and executes to completion. If a
    //  global executor cap is ever added, this test fails and is REWRITTEN to
    //  assert the new relationship (cap >= the Solver's 11).
    // =========================================================================

    function test_Seam3_RouterHasNoGlobalLegCap_TwelveLegRouteExecutes() public {
        // Three chained hops (A→B→A→B) of 4 legs each: 12 legs total, every
        // hop individually inside the per-hop cap.
        (Hop memory h0, uint256 o0) = _fanHop(4, true, 4_000e18);
        (Hop memory h1, uint256 o1) = _fanHop(4, false, o0);
        (Hop memory h2, uint256 o2) = _fanHop(4, true, o1);
        Hop[] memory hops = new Hop[](3);
        hops[0] = h0; hops[1] = h1; hops[2] = h2;

        uint256 totalLegs =
            hops[0].legs.length + hops[1].legs.length + hops[2].legs.length;
        assertGt(
            totalLegs, SOLVER_MAX_LEGS,
            "harness: the route must exceed the Solver's global budget to probe the seam"
        );
        for (uint256 h; h < hops.length; ++h) {
            assertLe(hops[h].legs.length, ROUTER_MAX_LEGS_PER_HOP,
                "harness: each hop stays inside the per-hop cap on purpose");
        }

        vm.prank(user);
        uint256 delivered = router.swapExactIn(
            _routeFromHops(hops, o2), 4_000e18, 1, user, block.timestamp + 1
        );

        // The consequence, pinned: the Router executes a route the Solver
        // could never have emitted — no refusal, an essentially full honest
        // fill (the only shrink is the per-hop 28 bps protocol fee, charged
        // on every hop of this bridgeless route, plus rounding).
        assertGt(delivered, 0, "the Router accepted and executed 12 legs");
        assertLe(delivered, o2, "sanity: cannot exceed the honest plan-time quote");
        assertGe(
            delivered, BPC.mulDiv(o2, 9_800, BPS),
            "the 12-leg route executed to completion, not to a truncation"
        );
    }

    // =========================================================================
    //  SEAM 4 — the absolute impact ceiling exists only on the plan side.
    //
    //  The Solver refuses a route whose worst leg meets MAX_ROUTE_IMPACT_BPS;
    //  the Router computes impact but never refuses on it. So the same route
    //  the Solver refuses to plan EXECUTES when hand-built and fed to the
    //  Router's direct door. What actually holds the line is (a) the protocol
    //  floor — but it prices fill QUALITY off the Router's own re-quote of the
    //  final hop, so on a near-empty pool it shrinks with the quote and
    //  objects to nothing — and (b) the user's own userMinOut, the only bound
    //  denominated in the user's expectation. Both are shown doing that job,
    //  with numbers.
    // =========================================================================

    uint112 constant TINY = 1e6; // wei-scale reserves: a near-empty pool
    uint256 constant BIG_IN = 1_000_000e18;

    function test_Seam4_ImpactCeiling_PlanRefuses_ExecutionDoesNot() public {
        // The worst (only) leg is over the Solver's ceiling — by construction.
        assertGe(
            BPC.impactV2Bps(BIG_IN, TINY), SOLVER_MAX_ROUTE_IMPACT_BPS,
            "harness: the leg must exceed the plan-side ceiling"
        );

        // (a) THE PLAN SIDE REFUSES. The near-empty pool is the pair's only
        // registered venue; the Solver's answer is its "no path" revert,
        // pinned by selector+code so an unrelated revert cannot stand in.
        MockV2Pair tiny = _v2Pair(TINY, TINY);
        hub.seedPool(address(tiny), BPC.KIND_V2, 30, address(0), address(tokA), address(tokB));
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixSolver.SolverE.selector, uint16(5)));
        solver.findBestRoutePlan(address(tokA), address(tokB), BIG_IN);

        // The same route, hand-built. The attestation is HONEST — the pool's
        // true (dust) quote — so no other guard has grounds to object; only
        // an impact ceiling could, and the Router does not have one.
        uint256 dustQuote = BPC.outV2(BIG_IN, TINY, TINY, 30);
        Leg[] memory legs = new Leg[](1);
        legs[0] = _leg(address(tiny), BPC.KIND_V2, aFirst, BIG_IN, dustQuote);
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({
            tokenIn: address(tokA), tokenOut: address(tokB),
            amountIn: BIG_IN, expectedOut: dustQuote, legs: legs
        });
        Route memory route = _routeFromHops(hops, dustQuote);

        // (b) userMinOut DOES THE CEILING'S JOB when the user states an honest
        // expectation: asking for even half the input's nominal value (the
        // pool prices 1:1) is refused — RouterE(5), the floor/minOut revert.
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, uint16(5)));
        router.swapExactIn(route, BIG_IN, BIG_IN / 2, user, block.timestamp + 1);

        // (c) With the minimum lawful userMinOut (the entrypoints refuse 0),
        // the SAME route EXECUTES. The delivery is exactly the Router's own
        // re-quote of the net input — quote-faithful, and worthless.
        uint256 netIn = _netIn(BIG_IN);
        uint256 routerOwnQuote = BPC.outV2(netIn, TINY, TINY, 30);
        vm.prank(user);
        uint256 delivered = router.swapExactIn(
            route, BIG_IN, 1, user, block.timestamp + 1
        );
        assertEq(
            delivered, routerOwnQuote,
            "execution is quote-faithful into the near-empty pool - nothing refused it"
        );

        // THE NUMBERS. The user paid 1,000,000 tokens (1e24 wei) and received
        // fewer than 1e6 wei — less than one trillionth of the input — and no
        // protocol gate objected:
        assertLt(delivered, uint256(TINY), "the whole delivery is bounded by the dust reserve");
        assertLt(delivered * 1e12, BIG_IN, "over 99.9999999999% of value destroyed, executed anyway");

        // THE FLOOR DID ITS (different) JOB: at full impact the iron floor
        // clamps at its hard 80% — of the Router's OWN dust quote. Fill
        // quality held; fill value was never its question.
        assertEq(
            BPC.ironFloorBps(BPS, 1, 0), BPS - 2_000,
            "the hard floor the substitute rests on is 80% (mirrors FLOOR_HARD_MAX_LOSS_BPS)"
        );
        assertGe(
            delivered, BPC.mulDivUp(routerOwnQuote, BPS - 2_000, BPS),
            "the protocol floor held >=80% of the Router's own re-quote (quality, not value)"
        );
    }
}
