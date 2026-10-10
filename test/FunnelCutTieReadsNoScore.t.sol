// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  INV-7 AT THE FUNNEL CUT: A WEIGHT TIE IS NOT SETTLED BY THE SCORE.
//
//  INV-7: psi ranks and truncates candidates; no quote, floor or allocation
//  reads it. When more band survivors remain than legs allowed, `_cutByWeight`
//  keeps the heaviest by measured weight. Red at f909422: at equal weight the
//  selection kept the LOWER INDEX, and the index order is the psi order the
//  candidates arrived in, so the pool dropped from the allocation was chosen by
//  a score that decays with time and that a dust swap raises. The same pools,
//  holdings and trades at a different time paid the same order differently
//  (Seavia Resources, bug bounty; fixture adapted from the report).
//
//  At equal weight the cut now keeps the better marginal rate, then the lower
//  pool address: both are properties of the pool, not of its history.
//
//  Oracle: two histories that differ only in WHEN the same dust trades land;
//  the isolation asserts prove that only the score differs between them.
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg, RoutePlan} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";

contract FunnelCutTieReadsNoScoreTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    BlazePhoenixRouter router;
    MockERC20 X;
    MockERC20 Y;

    MockV2Pair[5] p; // equal holdings of X; p[3] the best price, p[4] the worst
    address constant USER = address(0xBEEF);
    address constant TRADER = address(0xD057);

    uint256 constant ORDER = 100e18;
    uint256 constant DUST = 1e15;
    uint256 constant M = 6;
    uint256 constant GAP = 4 days;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        solver = new BlazePhoenixSolver(address(hub));
        router = new BlazePhoenixRouter(address(hub), address(solver), address(this), address(0xFEE1), address(0xFEE2));
        hub.setRoles(address(router), address(solver), address(this));
        X = new MockERC20("X", "X");
        Y = new MockERC20("Y", "Y");
        X.mint(USER, 10_000e18);
        vm.prank(USER);
        X.approve(address(router), type(uint256).max);
        X.mint(TRADER, 10_000e18);
        vm.prank(TRADER);
        X.approve(address(router), type(uint256).max);
    }

    /// Five pools of equal X holdings, so every measured weight ties and the
    /// four-leg budget must drop exactly one. `yPerX[i]` sets each pool's price.
    function _pools(uint256[5] memory yPerX) internal {
        for (uint256 i; i < 5; i++) p[i] = _pair(300e18, 300e18 * yPerX[i]);
    }

    function _band() internal { _pools([uint256(2000), 2000, 2000, 2040, 1960]); }

    function _pair(uint256 x, uint256 y) internal returns (MockV2Pair q) {
        q = new MockV2Pair(address(X), address(Y));
        X.mint(address(q), x);
        Y.mint(address(q), y);
        (uint112 r0, uint112 r1) = address(X) < address(Y) ? (uint112(x), uint112(y)) : (uint112(y), uint112(x));
        q.setReserves(r0, r1);
        hub.seedPool(address(q), BPC.KIND_V2, 30, address(0), address(X), address(Y));
    }

    function _dust(address pool) internal {
        Leg[] memory legs = new Leg[](1);
        legs[0] = Leg({pool: pool, hooks: address(0), kind: BPC.KIND_V2, fee: 30, tickSpacing: 0,
            zeroForOne: address(X) < address(Y), stable: false, amountIn: DUST, expectedOut: 0, auxId: bytes32(0)});
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({tokenIn: address(X), tokenOut: address(Y), amountIn: DUST, expectedOut: 0, legs: legs});
        Route memory r = Route({hops: hops, totalOut: 0, singleOut: 0, singleOutFloor: 0, expectedImpactBps: 0,
            confidenceWad: 0, estGas: 0, hasSurplus: false, isV4Bundle: false});
        vm.prank(TRADER);
        router.swapExactIn(r, DUST, 1, TRADER, type(uint256).max);
    }

    /// `early` takes its M dust trades at t0, every other pool its M at t0 + gap:
    /// the same trades on the same pools, only the clock differs.
    function _history(uint256 early, uint256 gap) internal {
        uint256 t0 = vm.getBlockTimestamp();
        for (uint256 k; k < M; k++) _dust(address(p[early]));
        vm.warp(t0 + gap);
        for (uint256 i; i < 5; i++) {
            if (i != early) for (uint256 k; k < M; k++) _dust(address(p[i]));
        }
    }

    struct Shot {
        uint256 delivered;
        uint256 totalOut;
        bytes32 holdings;
        bytes32 planSet; // which of p[0..4] the plan routes through
        bytes32 psis;
        bool goodInPlan;
        bool badInPlan;
    }

    function _shot() internal returns (Shot memory s) {
        uint256[] memory hb = new uint256[](10);
        uint256[] memory ps = new uint256[](5);
        for (uint256 i; i < 5; i++) {
            hb[2 * i] = X.balanceOf(address(p[i]));
            hb[2 * i + 1] = Y.balanceOf(address(p[i]));
            ps[i] = hub.getPsi(address(p[i]), address(X), address(Y));
        }
        s.holdings = keccak256(abi.encode(hb));
        s.psis = keccak256(abi.encode(ps));
        RoutePlan memory rp = solver.findBestRoutePlan(address(X), address(Y), ORDER);
        s.totalOut = rp.best.totalOut;
        Leg[] memory lg = rp.best.hops[0].legs;
        bool[5] memory inPlan;
        for (uint256 i; i < lg.length; i++) {
            for (uint256 j; j < 5; j++) if (lg[i].pool == address(p[j])) inPlan[j] = true;
        }
        s.planSet = keccak256(abi.encode(inPlan));
        s.goodInPlan = inPlan[3];
        s.badInPlan = inPlan[4];
        vm.prank(USER);
        s.delivered = router.swapBestExactIn(address(X), address(Y), ORDER, 1, USER, type(uint256).max);
    }

    function _twoHistories(uint256 a, uint256 b, uint256 gap) internal returns (Shot memory h1, Shot memory h2) {
        uint256 snap = vm.snapshotState();
        _history(a, gap);
        h1 = _shot();
        vm.revertToState(snap);
        _history(b, gap);
        h2 = _shot();
        vm.revertToState(snap);
        assertEq(h1.holdings, h2.holdings, "isolation: every pool holds the same tokens");
    }

    // --- the property ---------------------------------------------------------

    /// RED at f909422: the same trades at a different time paid differently.
    function test_FunnelCut_WeightTie_AllocationDoesNotReadThePsiOrder() public {
        _band();
        (Shot memory h1, Shot memory h2) = _twoHistories(3, 4, GAP);
        assertTrue(h1.psis != h2.psis, "isolation: the score really differs");
        assertEq(h1.planSet, h2.planSet, "INV-7: the score chose which pool the cut dropped");
        assertEq(h1.totalOut, h2.totalOut, "INV-7: the quote read the score");
        assertEq(h1.delivered, h2.delivered, "INV-7: the payout read the score");
    }

    /// Watches the rate tie-break: at equal weight the better-priced pool stays
    /// and the worse-priced one goes, whichever traded early.
    function test_FunnelCut_WeightTie_KeepsTheBetterPricedPool() public {
        _band();
        (Shot memory h1, Shot memory h2) = _twoHistories(3, 4, GAP);
        assertTrue(h1.goodInPlan && h2.goodInPlan, "the best-priced pool must survive a weight tie");
        assertTrue(!h1.badInPlan && !h2.badInPlan, "the worst-priced pool is the one dropped");
    }

    /// Watches the address tie-break: five identical pools tie on weight AND on
    /// rate; the pool dropped must still not depend on the history.
    function test_FunnelCut_DoubleTie_PlanSetDoesNotReadThePsiOrder() public {
        _pools([uint256(2000), 2000, 2000, 2000, 2000]);
        uint256 hiA;
        uint256 loA;
        for (uint256 i = 1; i < 5; i++) {
            if (address(p[i]) > address(p[hiA])) hiA = i;
            if (address(p[i]) < address(p[loA])) loA = i;
        }
        // Each history makes a different pool the score's favourite to drop.
        (Shot memory h1, Shot memory h2) = _twoHistories(hiA, loA, GAP);
        assertTrue(h1.psis != h2.psis, "isolation: the score really differs");
        assertEq(h1.planSet, h2.planSet, "INV-7: the score chose which identical pool was dropped");
    }

    /// Fuzz over which pool trades early and how long the gap is: the plan and
    /// the payout are those of the reference history.
    /// forge-config: default.fuzz.runs = 32
    /// forge-config: release.fuzz.runs = 32
    function testFuzz_FunnelCut_WeightTie_AnyTiming_PaysTheSame(uint256 early, uint256 gap) public {
        early = bound(early, 0, 4);
        gap = bound(gap, 1 hours, 30 days);
        _band();
        (Shot memory h1, Shot memory h2) = _twoHistories(0, early, gap);
        assertEq(h1.planSet, h2.planSet, "INV-7: plan set read the score");
        assertEq(h1.delivered, h2.delivered, "INV-7: payout read the score");
    }

    // --- the neighbouring legitimate paths ------------------------------------

    /// Distinct weights: the cut keeps the heaviest, timing changes nothing.
    function test_FunnelCut_DistinctWeights_KeepsTheHeaviest() public {
        uint256[5] memory xs = [uint256(600e18), 500e18, 400e18, 300e18, 200e18];
        for (uint256 i; i < 5; i++) p[i] = _pair(xs[i], xs[i] * 2000);
        (Shot memory h1, Shot memory h2) = _twoHistories(0, 4, GAP);
        assertEq(h1.delivered, h2.delivered, "no tie, no score channel");
        assertTrue(!h1.badInPlan && !h2.badInPlan, "the lightest pool is the one cut");
    }

    /// Real mass still moves the payout.
    function test_FunnelCut_RealMass_MovesThePayout() public {
        _band();
        uint256 snap = vm.snapshotState();
        Shot memory a = _shot();
        vm.revertToState(snap);
        X.mint(address(p[0]), 300e18);
        Y.mint(address(p[0]), 600_000e18);
        (uint112 r0, uint112 r1) = address(X) < address(Y)
            ? (uint112(600e18), uint112(1_200_000e18)) : (uint112(1_200_000e18), uint112(600e18));
        p[0].setReserves(r0, r1);
        Shot memory b = _shot();
        assertGt(b.delivered, a.delivered, "real mass moves the payout");
    }
}
