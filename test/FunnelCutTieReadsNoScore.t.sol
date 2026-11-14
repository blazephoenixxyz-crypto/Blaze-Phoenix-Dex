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
//  Oracle: two histories that differ only in WHEN the same trades land;
//  the isolation asserts prove that only the score differs between them.
//  Since fix-1102 A dust moves no clock, so the trades are material, in rounds
//  a minute apart, and the dust that follows them moves no psi.
//
//  The fixture holds N = MAX_LEGS_PER_HOP + 1 pools, one more than the leg
//  budget (Core's MAX_LEGS_PER_HOP, the budget the Solver builds every stage
//  on), so the cut runs and drops exactly one, and every history asserts it.
//  History: until 2026-11-06 the budget was the Solver's MAX_LEGS_PER_STAGE = 4
//  and the fixture held five pools. When the budget became MAX_LEGS_PER_HOP = 5
//  the five pools all fitted and the cut stopped running: two tests here went
//  red and the other four passed without a cut to watch.
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg, RoutePlan, MAX_LEGS_PER_HOP} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";

contract FunnelCutTieReadsNoScoreTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    BlazePhoenixRouter router;
    MockERC20 X;
    MockERC20 Y;

    /// One pool more than the leg budget: the cut has exactly one pool to drop.
    uint256 constant N = MAX_LEGS_PER_HOP + 1;

    MockV2Pair[N] p; // equal holdings of X; p[N - 2] the best price, p[N - 1] the worst
    address constant USER = address(0xBEEF);
    address constant TRADER = address(0xD057);

    uint256 constant ORDER = 100e18;
    uint256 constant DUST = 1e15; // under every pool's anchor here: 200e18 >> 16 (BlazePhoenixCore.sol:2854)
    uint256 constant TRADE = 2e16; // material on every pool here: 2.2x the 600 X pool's anchor 600e18 >> 16
    uint256 constant M = 6;
    uint256 constant CADENCE = 60; // s between rounds: each closes a real interval (BlazePhoenixCore.sol:2898)
    // fix-1102 A: was 4 days; now 12 hours: the early pool's step is 4 tau = 11,140 s (BlazePhoenixCore.sol:2634), so
    // it decays to count 0 and stays live (:2637), and the late pools' first interval moves tau only 1/8 (:2907)
    uint256 constant GAP = 12 hours;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        solver = new BlazePhoenixSolver(address(hub), address(0));
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

    /// N pools of equal X holdings, so every measured weight ties and the leg
    /// budget must drop exactly one. `yPerX[i]` sets each pool's price.
    function _pools(uint256[N] memory yPerX) internal {
        for (uint256 i; i < N; i++) p[i] = _pair(300e18, 300e18 * yPerX[i]);
    }

    function _flat(uint256 yPerX) internal pure returns (uint256[N] memory y) {
        for (uint256 i; i < N; i++) y[i] = yPerX;
    }

    /// N prices inside the band: 2000 for all but the last two, the best (2010) at
    /// p[N - 2] and the worst (1990) at p[N - 1]. Since MED (2026-10-28) the band is
    /// the one of no arbitrage (BlazePhoenixMath, THE BAND): two 0.3% pools stay within
    /// about -0.6% / +0.9% of each other, widened by the two probes' error bounds (here
    /// about 0.33% each: a probe of a hundredth of the order is a third of a percent of
    /// each pool). The +-2% this fixture used until then put the best and the worst pool
    /// out of the band, the cut had too few pools for its legs and dropped none; at
    /// +-0.5% all N stay and the cut drops one.
    function _band() internal {
        uint256[N] memory y = _flat(2000);
        y[N - 2] = 2010;
        y[N - 1] = 1990;
        _pools(y);
    }

    function _pair(uint256 x, uint256 y) internal returns (MockV2Pair q) {
        q = new MockV2Pair(address(X), address(Y));
        X.mint(address(q), x);
        Y.mint(address(q), y);
        (uint112 r0, uint112 r1) = address(X) < address(Y) ? (uint112(x), uint112(y)) : (uint112(y), uint112(x));
        q.setReserves(r0, r1);
        hub.seedPool(address(q), BPC.KIND_V2, 30, address(0), address(X), address(Y));
    }

    function _swap(address pool, uint256 amt) internal {
        // The Router anchors on the declared leg output (BlazePhoenixRouter.sol:2288): attest 1 Y per X, far under ~2000
        Leg[] memory legs = new Leg[](1);
        legs[0] = Leg({pool: pool, hooks: address(0), kind: BPC.KIND_V2, fee: 30, tickSpacing: 0,
            zeroForOne: address(X) < address(Y), stable: false, amountIn: amt, expectedOut: amt, auxId: bytes32(0)});
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({tokenIn: address(X), tokenOut: address(Y), amountIn: amt, expectedOut: amt, legs: legs});
        Route memory r = Route({hops: hops, totalOut: 0, singleOut: 0, singleOutFloor: 0, expectedImpactBps: 0,
            confidenceWad: 0, estGas: 0, hasSurplus: false, isV4Bundle: false});
        vm.prank(TRADER);
        router.swapExactIn(r, amt, 1, TRADER, type(uint256).max);
    }

    /// `early` takes its M rounds of material trades from t0 + 1 (the registration second
    /// counts nothing), every other pool its M from t0 + gap, CADENCE apart: the same
    /// trades on the same pools, only the clock differs. In a second of its own after the
    /// last round, dust through every pool moves no psi (BlazePhoenixCore.sol:2898).
    function _history(uint256 early, uint256 gap) internal {
        uint256 t0 = vm.getBlockTimestamp();
        for (uint256 k; k < M; k++) {
            vm.warp(t0 + 1 + k * CADENCE);
            _swap(address(p[early]), TRADE);
        }
        for (uint256 k; k < M; k++) {
            vm.warp(t0 + gap + k * CADENCE);
            for (uint256 i; i < N; i++) if (i != early) _swap(address(p[i]), TRADE);
        }
        vm.warp(t0 + gap + (M - 1) * CADENCE + 1);
        for (uint256 i; i < N; i++) {
            uint256 before = hub.getPsi(address(p[i]), address(X), address(Y));
            _swap(address(p[i]), DUST);
            assertEq(hub.getPsi(address(p[i]), address(X), address(Y)), before, "dust pumped the psi");
        }
    }

    struct Shot {
        uint256 delivered;
        uint256 totalOut;
        bytes32 holdings;
        bytes32 planSet; // which of p[0..N-1] the plan routes through
        uint256 inPlan;  // how many of them
        bytes32 psis;
        bool goodInPlan;
        bool badInPlan;
    }

    function _shot() internal returns (Shot memory s) {
        uint256[] memory hb = new uint256[](2 * N);
        uint256[] memory ps = new uint256[](N);
        for (uint256 i; i < N; i++) {
            hb[2 * i] = X.balanceOf(address(p[i]));
            hb[2 * i + 1] = Y.balanceOf(address(p[i]));
            ps[i] = hub.getPsi(address(p[i]), address(X), address(Y));
        }
        s.holdings = keccak256(abi.encode(hb));
        s.psis = keccak256(abi.encode(ps));
        RoutePlan memory rp = solver.findBestRoutePlan(address(X), address(Y), ORDER);
        s.totalOut = rp.best.totalOut;
        Leg[] memory lg = rp.best.hops[0].legs;
        bool[N] memory inPlan;
        for (uint256 i; i < lg.length; i++) {
            for (uint256 j; j < N; j++) if (lg[i].pool == address(p[j])) inPlan[j] = true;
        }
        for (uint256 j; j < N; j++) if (inPlan[j]) s.inPlan++;
        s.planSet = keccak256(abi.encode(inPlan));
        s.goodInPlan = inPlan[N - 2];
        s.badInPlan = inPlan[N - 1];
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
        // Not vacuous: N pools for MAX_LEGS_PER_HOP legs, so each plan leaves exactly one out.
        assertEq(h1.inPlan, N - 1, "premise: the cut dropped exactly one pool (first history)");
        assertEq(h2.inPlan, N - 1, "premise: the cut dropped exactly one pool (second history)");
    }

    // --- the property ---------------------------------------------------------

    /// RED at f909422: the same trades at a different time paid differently.
    function test_FunnelCut_WeightTie_AllocationDoesNotReadThePsiOrder() public {
        _band();
        (Shot memory h1, Shot memory h2) = _twoHistories(N - 2, N - 1, GAP);
        assertTrue(h1.psis != h2.psis, "isolation: the score really differs");
        assertEq(h1.planSet, h2.planSet, "INV-7: the score chose which pool the cut dropped");
        assertEq(h1.totalOut, h2.totalOut, "INV-7: the quote read the score");
        assertEq(h1.delivered, h2.delivered, "INV-7: the payout read the score");
    }

    /// Watches the rate tie-break: at equal weight the better-priced pool stays
    /// and the worse-priced one goes, whichever traded early.
    function test_FunnelCut_WeightTie_KeepsTheBetterPricedPool() public {
        _band();
        (Shot memory h1, Shot memory h2) = _twoHistories(N - 2, N - 1, GAP);
        assertTrue(h1.goodInPlan && h2.goodInPlan, "the best-priced pool must survive a weight tie");
        assertTrue(!h1.badInPlan && !h2.badInPlan, "the worst-priced pool is the one dropped");
    }

    /// Watches the address tie-break: N identical pools tie on weight AND on
    /// rate; the pool dropped must still not depend on the history.
    function test_FunnelCut_DoubleTie_PlanSetDoesNotReadThePsiOrder() public {
        _pools(_flat(2000));
        uint256 hiA;
        uint256 loA;
        for (uint256 i = 1; i < N; i++) {
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
        early = bound(early, 0, N - 1);
        gap = bound(gap, 1 hours, 30 days);
        _band();
        (Shot memory h1, Shot memory h2) = _twoHistories(0, early, gap);
        assertEq(h1.planSet, h2.planSet, "INV-7: plan set read the score");
        assertEq(h1.delivered, h2.delivered, "INV-7: payout read the score");
    }

    // --- the neighbouring legitimate paths ------------------------------------

    /// Distinct weights: the cut keeps the heaviest, timing changes nothing.
    /// p[i] holds (N + 1 - i) x 100 X (600 down to 200 when N was five).
    function test_FunnelCut_DistinctWeights_KeepsTheHeaviest() public {
        for (uint256 i; i < N; i++) {
            uint256 x = (N + 1 - i) * 100e18;
            p[i] = _pair(x, x * 2000);
        }
        (Shot memory h1, Shot memory h2) = _twoHistories(0, N - 1, GAP);
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
