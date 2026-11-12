// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {
    BlazePhoenixCore as BPC,
    PoolInfo, Route, Hop, Leg, RoutePlan, MAX_HOPS, MAX_LEGS_PER_HOP
} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";
import {MockV3Pool} from "./mocks/MockV3Pool.sol";
import {MockV2Factory} from "./mocks/MockV2Factory.sol";

/// @notice Coverage for BlazePhoenixSolver — previously zero tests (see
///         TESTING.md "Known gaps"). Exercises the median-rate filter, the
///         capital anchor, the two-tier capacity clamp (MAX_CONC_DRAIN_BPS),
///         bridge topology selection/ranking, the leg-budget funnel cut,
///         and the registry-freshness discovery gate.
contract BlazePhoenixSolverTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;

    MockERC20 tokenA;
    MockERC20 tokenB;
    MockERC20 bridgeToken;
    MockERC20 b2Tok;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        solver = new BlazePhoenixSolver(address(hub), address(0));

        tokenA = new MockERC20("A", "A");
        tokenB = new MockERC20("B", "B");
        bridgeToken = new MockERC20("BRIDGE", "BR");
        b2Tok       = new MockERC20("BRIDGE2", "BR2");
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
        // amountIn is 10% of the deep reserve so the split's impact saving
        // (~83 bps over single-pool) clears MIN_SPLIT_IMPROVEMENT_PPM — the
        // gate keeps splits that genuinely pay for their legs.
        MockV2Pair deep    = _seedV2(address(tokenA), address(tokenB), 1_000_000e18, 1_600_000e18);
        MockV2Pair shallow = _seedV2(address(tokenA), address(tokenB), 100_000e18,   160_000e18);

        uint256 amountIn = 100_000e18;
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
    //  Min-split improvement gate: a split must EARN its extra legs
    // =========================================================================

    /// @notice Same two-pool topology, but a small trade (1% of the deep
    ///         reserve): a poupanca de impacto do split fica ABAIXO de
    ///         MIN_SPLIT_IMPROVEMENT_PPM, logo o plano tem de colapsar na perna
    ///         funda unica.
    ///
    ///         CENARIO REAJUSTADO A 2026-08-21. O limiar desceu de 20 para 5
    ///         bps (ver test/SplitThreshold.t.sol: o ponto morto REAL da Base
    ///         e 0,030 bps, e os 20 estavam 667x acima do que representavam).
    ///         O trade de 10.000e18 dava ~9 bps de ganho — que a 5 bps passa a
    ///         SOBREVIVER, e bem: 9 bps sao 300x o ponto morto. Para continuar
    ///         a pinar o invariante ("ganho abaixo do limiar colapsa") o trade
    ///         desceu para 1.000e18: menos impacto na pool funda, logo menos a
    ///         ganhar com o split.
    /// @dev OS DOIS LADOS DO LIMIAR, e a razao de o teste ter mudado de forma.
    ///
    ///      A versao anterior pinava so um lado ("este montante colapsa") e por
    ///      isso teve de ser recalibrada de cada vez que o limiar desceu:
    ///      10.000e18 quando o gate era 20 bps, 1.000e18 quando passou a 5, e
    ///      teria de descer outra vez agora que sao 0,25. Um teste que muda
    ///      sempre que a constante muda nao esta a pinar a constante — esta a
    ///      segui-la.
    ///
    ///      Pinar os DOIS lados amarra o que interessa de facto: que existe um
    ///      limiar, que abaixo dele colapsa e acima dele divide. Isso continua
    ///      verdadeiro para qualquer valor do gate, e falha se alguem apagar o
    ///      gate (tudo dividiria) ou o puser absurdamente alto (nada dividiria).
    function test_MinSplitGate_LimiarTemDoisLados() public {
        MockV2Pair deep = _seedV2(address(tokenA), address(tokenB), 1_000_000e18, 1_600_000e18);
        _seedV2(address(tokenA), address(tokenB), 100_000e18, 160_000e18);

        // ABAIXO: 0,01% da pool funda. A poupanca de impacto do split e
        // minuscula face ao custo das pernas — tem de colapsar.
        RoutePlan memory pequeno =
            solver.findBestRoutePlan(address(tokenA), address(tokenB), 100e18);
        assertEq(pequeno.best.hops[0].legs.length, 1,
            "abaixo do limiar: o micro-split tem de colapsar numa perna");
        assertEq(pequeno.best.hops[0].legs[0].pool, address(deep),
            "e a perna unica e a melhor, nao uma qualquer");
        assertEq(pequeno.best.hops[0].amountIn, 100e18,
            "o colapso nao pode deixar capital para tras");

        // ACIMA: 10% da pool funda. Aqui o split paga-se largamente.
        RoutePlan memory grande =
            solver.findBestRoutePlan(address(tokenA), address(tokenB), 100_000e18);
        assertGe(grande.best.hops[0].legs.length, 2,
            "acima do limiar: o split tem de acontecer, senao o gate esta a matar valor real");
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
        uint256 rawOut = BPC.outV3(amountIn, sqrtP, liq, 3000, tokenA < tokenB, 0);
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
        uint256 rawOut = BPC.outV3(amountIn, sqrtP, liq, 3000, tokenA < tokenB, 0);
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
    //  Leg-budget funnel cut (MAX_LEGS_PER_HOP) — top-K by weight, not discovery/list order
    // =========================================================================

    /// @notice Same-rate pools of strictly increasing depth, two more than one hop's leg budget
    ///         (MAX_LEGS_PER_HOP, the Router's ceiling), so seven today. The median filter keeps
    ///         them all, so the funnel cut must keep exactly the MAX_LEGS_PER_HOP deepest, each
    ///         with its leg, and drop the two shallowest.
    ///         History: until 2026-11-06 this was test_FunnelCut_KeepsDeepestFourOfSeven, under
    ///         the Solver's own per-stage budget MAX_LEGS_PER_STAGE = 4.
    function test_FunnelCut_KeepsDeepestFiveOfSeven() public {
        uint256 n = uint256(MAX_LEGS_PER_HOP) + 2;
        MockV2Pair[] memory pools = new MockV2Pair[](n);
        for (uint256 i; i < n; ++i) {
            uint256 mag = (i + 1) * 2_000e18;
            pools[i] = _seedV2(address(tokenA), address(tokenB), mag, mag * 16 / 10);
        }

        uint256 amountIn = 1_000e18;
        RoutePlan memory plan = solver.findBestRoutePlan(address(tokenA), address(tokenB), amountIn);

        Leg[] memory legs = plan.best.hops[0].legs;
        assertEq(legs.length, uint256(MAX_LEGS_PER_HOP), "one hop's budget is MAX_LEGS_PER_HOP, and the cut fills it");
        for (uint256 i; i < n; ++i) {
            bool seen;
            for (uint256 l; l < legs.length; ++l) if (legs[l].pool == address(pools[i])) seen = true;
            if (i < 2) assertFalse(seen, "the 2 shallowest pools must be cut by the funnel");
            else assertTrue(seen, "each of the MAX_LEGS_PER_HOP deepest pools keeps its leg");
        }
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

    // ═════════════════════════════════════════════════════════════════════════
    //  TWO-BRIDGE CHAINS — one bridge per route since 2026-11-06 (MAX_HOPS = 2)
    // ═════════════════════════════════════════════════════════════════════════
    //
    //  History: this section held test_TresHopsPorDuasPontes and its control, added with the
    //  two-bridge topology of 2026-08-22. They replaced test/ThreeHopRanking.t.sol, which
    //  declared a `struct M` and a `_considera` inside the test and never deployed the Solver:
    //  deleting the three-hop planner left it green. Since 2026-11-06 the bridge planner builds
    //  one bridge per route (`_planViaBridges`, a path of MAX_HOPS + 1 tokens, so a planner of
    //  three hops does not compile): the same chain has no route, and the two-hop route through
    //  a bridge is what the Solver plans when one exists.

    /// @notice Only a chain through BOTH bridges connects A to B (no direct pool, neither
    ///         A -> bridge -> B nor A -> bridge2 -> B): that route is three hops, past MAX_HOPS,
    ///         and the Solver refuses with SolverE(5). One shallow pair more, bridge -> B, opens
    ///         the two-hop analogue, which pays ~1,445e18 against the chain's ~1,581e18
    ///         [derived: outV2 at 30 bps, 1,000e18 in]. It is the plan: the chain is not built,
    ///         so it cannot outrank it.
    ///         History: until 2026-11-06 this was test_TresHopsPorDuasPontes, which asserted the
    ///         three-hop route A -> bridge -> bridge2 -> B on the first book.
    function test_TwoBridgeChain_IsRefused_OneBridgeAnalogueIsPlanned() public {
        hub.addBridge(address(bridgeToken));
        hub.addBridge(address(b2Tok));
        _seedV2(address(tokenA),      address(bridgeToken), 1_000_000e18, 1_000_000e18);
        _seedV2(address(bridgeToken), address(b2Tok),       1_000_000e18, 1_000_000e18);
        _seedV2(address(b2Tok),       address(tokenB),      1_000_000e18, 1_600_000e18);

        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixSolver.SolverE.selector, 5));
        solver.findBestRoutePlan(address(tokenA), address(tokenB), 1_000e18);

        _seedV2(address(bridgeToken), address(tokenB), 10_000e18, 16_000e18);
        RoutePlan memory plan =
            solver.findBestRoutePlan(address(tokenA), address(tokenB), 1_000e18);
        assertEq(plan.best.hops.length, MAX_HOPS, "the analogue is one bridge, two hops");
        assertEq(plan.best.hops[0].tokenOut, address(bridgeToken), "hop 0 -> bridge");
        assertEq(plan.best.hops[1].tokenOut, address(tokenB),      "hop 1 -> destination");
        assertFalse(plan.hasFallback, "no other route exists: the chain is not a candidate");
    }

    /// @notice THE NEGATIVE CONTROL, and the owner's literal question: "if the best price is
    ///         direct there is no need for 2 hops". With a far deeper direct pool, the direct
    ///         route must win over the routable one-bridge route, with both bridges registered.
    ///         Without this test, the one above would stay green with a Solver that ALWAYS
    ///         PREFERRED the longer route.
    ///         History: until 2026-11-06 the bridge competitor was the two-bridge chain alone;
    ///         with MAX_HOPS = 2 the chain is not built, so the pair bridge -> B was added to keep
    ///         a bridge route in the race (it is the fallback).
    function test_DirectaMelhorGanhaSobreAsDuasPontes() public {
        hub.addBridge(address(bridgeToken));
        hub.addBridge(address(b2Tok));
        _seedV2(address(tokenA), address(tokenB), 10_000_000e18, 16_000_000e18);
        _seedV2(address(tokenA),      address(bridgeToken), 5_000e18, 5_000e18);
        _seedV2(address(bridgeToken), address(b2Tok),       5_000e18, 5_000e18);
        _seedV2(address(b2Tok),       address(tokenB),      5_000e18, 8_000e18);
        _seedV2(address(bridgeToken), address(tokenB),      5_000e18, 8_000e18);

        RoutePlan memory plan =
            solver.findBestRoutePlan(address(tokenA), address(tokenB), 1_000e18);
        assertEq(plan.best.hops.length, 1, "the direct route pays more: it must win");
        assertTrue(plan.hasFallback, "the one-bridge route was in the race");
        assertEq(plan.fallbackRoute.hops.length, MAX_HOPS, "the fallback is the one-bridge route");
    }
}
