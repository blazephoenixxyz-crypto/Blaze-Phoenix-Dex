// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {
    BlazePhoenixCore as BPC,
    PoolInfo, Route, Hop, Leg, RoutePlan
} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";
import {MockV3Pool} from "./mocks/MockV3Pool.sol";
import {MockV2Factory} from "./mocks/MockV2Factory.sol";

/// @notice Coverage for BlazePhoenixSolver — previously zero tests (see
///         TESTING.md "Known gaps"). Exercises the median-rate filter, the
///         capital anchor, the two-tier capacity clamp (MAX_CONC_DRAIN_BPS),
///         bridge topology selection/ranking, the MAX_CANDIDATES funnel cut,
///         and the registry-freshness discovery gate.
contract BlazePhoenixSolverTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;

    MockERC20 tokenA;
    MockERC20 tokenB;
    MockERC20 bridgeToken;

    function setUp() public {
        hub = new BlazePhoenixHub();
        hub.initialize(address(this), address(0));
        solver = new BlazePhoenixSolver(address(hub));

        tokenA = new MockERC20("A", "A");
        tokenB = new MockERC20("B", "B");
        bridgeToken = new MockERC20("BRIDGE", "BR");
    }

    // ─── helpers ──────────────────────────────────────────────────────

    function _seedV2(address tX, address tY, uint256 reserveX, uint256 reserveY)
        internal returns (MockV2Pair p)
    {
        p = new MockV2Pair(tX, tY);
        MockERC20(tX).mint(address(p), reserveX);
        MockERC20(tY).mint(address(p), reserveY);
        (address t0, ) = tX < tY ? (tX, tY) : (tY, tX);
        p.setReserves(
            uint112(tX == t0 ? reserveX : reserveY),
            uint112(tX == t0 ? reserveY : reserveX)
        );
        hub.seedPool(address(p), BPC.KIND_V2, 30, address(0), tX, tY);
    }

    function _seedV3(address tX, address tY, uint160 sqrtP, uint128 liq, uint256 realHoldingsOfY)
        internal returns (MockV3Pool p)
    {
        p = new MockV3Pool(tX, tY, 3000);
        p.setState(sqrtP, liq);
        MockERC20(tY).mint(address(p), realHoldingsOfY);
        hub.seedPool(address(p), BPC.KIND_V3, 3000, address(0), tX, tY);
    }

    // =========================================================================
    //  Input validation
    // =========================================================================

    function test_FindBestRoutePlan_RevertsOnZeroTokenIn() public {
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixSolver.SolverE.selector, 4));
        solver.findBestRoutePlan(address(0), address(tokenB), 1e18);
    }

    function test_FindBestRoutePlan_RevertsOnZeroTokenOut() public {
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixSolver.SolverE.selector, 4));
        solver.findBestRoutePlan(address(tokenA), address(0), 1e18);
    }

    function test_FindBestRoutePlan_RevertsOnSameToken() public {
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixSolver.SolverE.selector, 4));
        solver.findBestRoutePlan(address(tokenA), address(tokenA), 1e18);
    }

    function test_FindBestRoutePlan_RevertsOnZeroAmountIn() public {
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixSolver.SolverE.selector, 4));
        solver.findBestRoutePlan(address(tokenA), address(tokenB), 0);
    }

    function test_FindBestRoutePlan_RevertsWhenNoRouteExists() public {
        // No pools registered anywhere, no bridges, no factories.
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixSolver.SolverE.selector, 5));
        solver.findBestRoutePlan(address(tokenA), address(tokenB), 1e18);
    }

    // =========================================================================
    //  Single-pool direct route
    // =========================================================================

    function test_Direct_SinglePool() public {
        MockV2Pair pool = _seedV2(address(tokenA), address(tokenB), 100_000e18, 160_000e18);
        uint256 amountIn = 1_000e18;

        RoutePlan memory plan = solver.findBestRoutePlan(address(tokenA), address(tokenB), amountIn);

        assertEq(plan.best.hops.length, 1);
        assertEq(plan.best.hops[0].legs.length, 1);
        assertEq(plan.best.hops[0].legs[0].pool, address(pool));
        assertGt(plan.best.totalOut, 0);
        assertEq(plan.best.totalOut, BPC.outV2(amountIn, 100_000e18, 160_000e18, 30));
        assertFalse(plan.hasFallback, "no bridge configured, no second candidate");
    }

    // =========================================================================
    //  Depth-weighted split across pools with the SAME marginal rate
    // =========================================================================

    function test_Direct_SplitsProportionallyToDepth() public {
        // Same 1.6 ratio, one pool 10x deeper than the other -> both survive
        // the median band filter (near-identical marginal rate) and the
        // depth-weighted split must allocate roughly 10x more to the deep one.
        MockV2Pair deep    = _seedV2(address(tokenA), address(tokenB), 1_000_000e18, 1_600_000e18);
        MockV2Pair shallow = _seedV2(address(tokenA), address(tokenB), 100_000e18,   160_000e18);

        uint256 amountIn = 10_000e18;
        RoutePlan memory plan = solver.findBestRoutePlan(address(tokenA), address(tokenB), amountIn);

        assertEq(plan.best.hops[0].legs.length, 2, "both pools should survive the band filter");
        uint256 amtDeep;
        uint256 amtShallow;
        for (uint256 i; i < 2; ++i) {
            Leg memory leg = plan.best.hops[0].legs[i];
            if (leg.pool == address(deep)) amtDeep = leg.amountIn;
            if (leg.pool == address(shallow)) amtShallow = leg.amountIn;
        }
        assertGt(amtDeep, 0);
        assertGt(amtShallow, 0);
        // Deep pool must take a materially larger share (roughly 10x, allow slack).
        assertGt(amtDeep, amtShallow * 5);
        // Full conservation: nothing lost, nothing invented.
        assertEq(amtDeep + amtShallow, amountIn);
    }

    // =========================================================================
    //  Median filter excludes a stale-priced outlier
    // =========================================================================

    function test_MedianFilter_ExcludesOutlierPool() public {
        // Honest deep pool at the true rate (1.6), larger real balance -> it
        // becomes the capital anchor. Outlier pool quotes a wildly different
        // rate (10x) from thin reserves.
        MockV2Pair honest  = _seedV2(address(tokenA), address(tokenB), 100_000e18, 160_000e18);
        MockV2Pair outlier = _seedV2(address(tokenA), address(tokenB), 100e18,     1_000e18);

        uint256 amountIn = 1_000e18;
        RoutePlan memory plan = solver.findBestRoutePlan(address(tokenA), address(tokenB), amountIn);

        assertEq(plan.best.hops[0].legs.length, 1, "outlier must be filtered out");
        assertEq(plan.best.hops[0].legs[0].pool, address(honest));
        outlier; // silence unused warning if optimized away
    }

    // =========================================================================
    //  Capital anchor overrides a plain (dust-majority) median
    // =========================================================================

    function test_CapitalAnchor_DustMajorityDoesNotOutvoteDeepPool() public {
        // Two dust pools agree on a stale ~1.0 rate; one deep pool quotes the
        // true 1.6 rate. A NAIVE median of {1.0, 1.0, 1.6} would pick 1.0 as
        // the consensus and filter the deep pool out as the "outlier". The
        // capital anchor must instead base the band on the deep pool (larger
        // real tokenB balance), excluding the dust pools instead.
        MockV2Pair dust1 = _seedV2(address(tokenA), address(tokenB), 1_000e18, 1_000e18);
        MockV2Pair dust2 = _seedV2(address(tokenA), address(tokenB), 1_000e18, 1_000e18);
        MockV2Pair deep  = _seedV2(address(tokenA), address(tokenB), 1_000_000e18, 1_600_000e18);

        uint256 amountIn = 1_000e18;
        RoutePlan memory plan = solver.findBestRoutePlan(address(tokenA), address(tokenB), amountIn);

        assertEq(plan.best.hops[0].legs.length, 1,
            "capital anchor must exclude the two dust pools, not the deep one");
        assertEq(plan.best.hops[0].legs[0].pool, address(deep));
        dust1; dust2;
    }

    // =========================================================================
    //  Capacity clamp — two-tier MAX_CONC_DRAIN_BPS doctrine
    // =========================================================================

    function test_CapacityClamp_AggressiveButPossible_CapsPromiseOnly() public {
        // rawOut is above the 30% cap but at or below the pool's whole
        // holdings -> only the promise is capped, the full input commits.
        uint160 sqrtP = uint160(BPC.Q96);
        uint128 liq   = 1_000_000e18;
        uint256 balOut = 10_000e18;
        MockV3Pool pool = _seedV3(address(tokenA), address(tokenB), sqrtP, liq, balOut);

        uint256 amountIn = 6_000e18;
        uint256 rawOut = BPC.outV3(amountIn, sqrtP, liq, 3000, tokenA < tokenB);
        uint256 cap = BPC.mulDiv(balOut, 3_000, BPC.BPS);
        // Sanity-check the scenario actually lands in the intended regime.
        assertGt(rawOut, cap, "precondition: raw quote must exceed the 30% cap");
        assertLe(rawOut, balOut, "precondition: raw quote must not exceed whole holdings");

        RoutePlan memory plan = solver.findBestRoutePlan(address(tokenA), address(tokenB), amountIn);

        assertEq(plan.best.hops[0].legs.length, 1);
        Leg memory leg = plan.best.hops[0].legs[0];
        assertEq(leg.pool, address(pool));
        assertEq(leg.amountIn, amountIn, "input must NOT be cut in the aggressive-but-possible regime");
        assertEq(leg.expectedOut, cap, "promise must be capped to 30% of real holdings");
    }

    function test_CapacityClamp_PhantomPromise_CutsInputToo() public {
        // rawOut exceeds the pool's WHOLE holdings -> physically impossible;
        // both the promise AND the committed input must be cut.
        uint160 sqrtP = uint160(BPC.Q96);
        uint128 liq   = 1_000_000e18;
        uint256 balOut = 4_200e18; // deliberately thin, matching the vault note's example
        MockV3Pool pool = _seedV3(address(tokenA), address(tokenB), sqrtP, liq, balOut);

        uint256 amountIn = 500_000e18;
        uint256 rawOut = BPC.outV3(amountIn, sqrtP, liq, 3000, tokenA < tokenB);
        uint256 cap = BPC.mulDiv(balOut, 3_000, BPC.BPS);
        assertGt(rawOut, balOut, "precondition: raw quote must exceed whole holdings (phantom)");

        RoutePlan memory plan = solver.findBestRoutePlan(address(tokenA), address(tokenB), amountIn);

        assertEq(plan.best.hops[0].legs.length, 1);
        Leg memory leg = plan.best.hops[0].legs[0];
        assertEq(leg.pool, address(pool));
        assertLt(leg.amountIn, amountIn, "input must be cut in the phantom-promise regime");
        assertEq(leg.expectedOut, cap, "promise must still be capped to 30% of real holdings");
        // Cut ratio must match: legIn / amountIn ≈ cap / rawOut.
        assertApproxEqRel(leg.amountIn, BPC.mulDiv(amountIn, cap, rawOut), 0.001e18);
    }

    // =========================================================================
    //  Bridge topology
    // =========================================================================

    function test_ViaBridge_UsedWhenNoDirectPoolExists() public {
        hub.addBridge(address(bridgeToken));
        MockV2Pair legA = _seedV2(address(tokenA), address(bridgeToken), 100_000e18, 100_000e18);
        MockV2Pair legB = _seedV2(address(bridgeToken), address(tokenB), 100_000e18, 160_000e18);

        uint256 amountIn = 1_000e18;
        RoutePlan memory plan = solver.findBestRoutePlan(address(tokenA), address(tokenB), amountIn);

        assertEq(plan.best.hops.length, 2, "no direct pool -> must route via the bridge");
        assertEq(plan.best.hops[0].tokenIn, address(tokenA));
        assertEq(plan.best.hops[0].tokenOut, address(bridgeToken));
        assertEq(plan.best.hops[1].tokenIn, address(bridgeToken));
        assertEq(plan.best.hops[1].tokenOut, address(tokenB));
        assertGt(plan.best.totalOut, 0);
        assertFalse(plan.hasFallback, "only one non-zero topology (direct is impossible here)");
        legA; legB;
    }

    function test_Ranking_BestAndFallbackBothPopulated() public {
        // A direct pool AND a (deliberately worse) bridge route both exist —
        // the Solver must rank them and expose the loser as fallbackRoute.
        MockV2Pair direct = _seedV2(address(tokenA), address(tokenB), 1_000_000e18, 1_600_000e18);

        hub.addBridge(address(bridgeToken));
        // Intentionally thin bridge legs -> worse total output than direct.
        _seedV2(address(tokenA), address(bridgeToken), 2_000e18, 2_000e18);
        _seedV2(address(bridgeToken), address(tokenB), 2_000e18, 3_000e18);

        uint256 amountIn = 1_000e18;
        RoutePlan memory plan = solver.findBestRoutePlan(address(tokenA), address(tokenB), amountIn);

        assertTrue(plan.hasFallback, "both topologies are viable -> a fallback must be reported");
        assertEq(plan.best.hops.length, 1, "the deep direct pool should win");
        assertEq(plan.best.hops[0].legs[0].pool, address(direct));
        assertGt(plan.best.totalOut, plan.fallbackRoute.totalOut);
    }

    // =========================================================================
    //  MAX_CANDIDATES funnel cut — top-K by weight, not discovery/list order
    // =========================================================================

    function test_FunnelCut_KeepsDeepestFiveOfSeven() public {
        // Seven same-rate pools with strictly increasing depth. The direct
        // topology's leg budget is MAX_LEGS = 5, so after the median filter
        // keeps all 7 (same rate), the funnel cut must retain exactly the 5
        // deepest and drop the 2 shallowest.
        MockV2Pair[] memory pools = new MockV2Pair[](7);
        for (uint256 i; i < 7; ++i) {
            uint256 mag = (i + 1) * 2_000e18;
            pools[i] = _seedV2(address(tokenA), address(tokenB), mag, mag * 16 / 10);
        }

        uint256 amountIn = 1_000e18;
        RoutePlan memory plan = solver.findBestRoutePlan(address(tokenA), address(tokenB), amountIn);

        assertEq(plan.best.hops[0].legs.length, 5, "budget is MAX_LEGS=5");
        bool sawShallowest;
        bool sawSecondShallowest;
        for (uint256 i; i < plan.best.hops[0].legs.length; ++i) {
            address p = plan.best.hops[0].legs[i].pool;
            if (p == address(pools[0])) sawShallowest = true;
            if (p == address(pools[1])) sawSecondShallowest = true;
        }
        assertFalse(sawShallowest, "the 2 shallowest pools must be cut by the funnel");
        assertFalse(sawSecondShallowest, "the 2 shallowest pools must be cut by the funnel");
    }

    // =========================================================================
    //  Registry-freshness discovery gate (_registryFresh early exit)
    // =========================================================================

    function test_Discovery_RunsWhenRegistryIsNotFresh() public {
        MockV2Factory factory = new MockV2Factory();
        hub.addFactory(address(factory), BPC.KIND_V2, 0, bytes32(0), new uint24[](0), new int24[](0));

        // Fewer than MIN_FRESH_VENUES(3) registered -> registry is NOT fresh
        // -> discoverFor() must run and the factory-derived pool must be used.
        MockV2Pair discovered = new MockV2Pair(address(tokenA), address(tokenB));
        tokenA.mint(address(discovered), 100_000e18);
        tokenB.mint(address(discovered), 160_000e18);
        discovered.setReserves(100_000e18, 160_000e18);
        (address t0, address t1) = address(tokenA) < address(tokenB)
            ? (address(tokenA), address(tokenB)) : (address(tokenB), address(tokenA));
        factory.setPair(t0, t1, address(discovered));

        RoutePlan memory plan = solver.findBestRoutePlan(address(tokenA), address(tokenB), 1_000e18);
        assertEq(plan.best.hops[0].legs.length, 1);
        assertEq(plan.best.hops[0].legs[0].pool, address(discovered));
    }

    function test_Discovery_SkippedWhenRegistryIsFresh() public {
        // Three freshly-registered pools satisfy MIN_FRESH_VENUES -> the
        // freshness gate must skip discoverFor() entirely, so a much better
        // discoverable pool is NOT picked up even though the factory can see it.
        _seedV2(address(tokenA), address(tokenB), 100_000e18, 100_000e18);
        _seedV2(address(tokenA), address(tokenB), 100_000e18, 100_000e18);
        _seedV2(address(tokenA), address(tokenB), 100_000e18, 100_000e18);

        MockV2Factory factory = new MockV2Factory();
        hub.addFactory(address(factory), BPC.KIND_V2, 0, bytes32(0), new uint24[](0), new int24[](0));
        // A vastly better pool the factory WOULD surface if discovery ran.
        MockV2Pair betterPool = new MockV2Pair(address(tokenA), address(tokenB));
        tokenA.mint(address(betterPool), 10_000_000e18);
        tokenB.mint(address(betterPool), 100_000_000e18); // absurdly good rate
        betterPool.setReserves(10_000_000e18, 100_000_000e18);
        (address t0, address t1) = address(tokenA) < address(tokenB)
            ? (address(tokenA), address(tokenB)) : (address(tokenB), address(tokenA));
        factory.setPair(t0, t1, address(betterPool));

        RoutePlan memory plan = solver.findBestRoutePlan(address(tokenA), address(tokenB), 1_000e18);
        for (uint256 i; i < plan.best.hops[0].legs.length; ++i) {
            assertTrue(plan.best.hops[0].legs[i].pool != address(betterPool),
                "fresh registry must skip discovery; the undiscovered pool cannot appear");
        }
    }
}
