// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// Measurement harness for the registry lifecycle — not a correctness suite. Answers, with real
// numbers rather than claims, the questions the vitality/discovery redesign raised:
//
//   1. What does a COLD solve cost (registry empty -> full discoverFor sweep across factories)?
//   2. What does the same solve cost WARM (>= MIN_FRESH_VENUES pools ticked inside
//      DISCOVERY_TTL_SECONDS, so _registryFresh short-circuits discovery entirely)?
//   3. How does vitality/psi actually evolve across real swaps, then across a decay window,
//      then across a reactivating swap — i.e. does the R3 fix hold end-to-end through the
//      Router->Hub path, not just in the unit test that pokes tickSlot directly?
//   4. What does a swap cost as the registry warms?
//
// Read via: forge test --match-contract LifecycleMetrics -vv
//
// NOTE: time is tracked in a local accumulator, never by re-reading block.timestamp at a second
// call site — that pattern is miscompiled on this forge build (see the repo's test conventions).

import {Test, console2} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, PoolInfo, Route, RoutePlan} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";
import {MockV2Factory} from "./mocks/MockV2Factory.sol";

contract LifecycleMetricsTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    BlazePhoenixRouter router;
    MockERC20 tokenIn;
    MockERC20 tokenOut;
    MockV2Pair[] pools;
    address user = address(0xBEEF);

    uint256 constant N_POOLS = 4; // > MIN_FRESH_VENUES (3), so the pair can reach "fresh"
    uint256 constant TTL = 3_600; // DISCOVERY_TTL_SECONDS
    uint256 constant DECAY_STEP = 24_576; // VITALITY_DECAY_STEP_SECONDS
    uint256 constant AMT = 100e18;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        solver = new BlazePhoenixSolver(address(hub));
        router = new BlazePhoenixRouter(
            address(hub), address(solver), address(this), address(0xFEE1), address(0xFEE2));
        hub.setRoles(address(router), address(solver), address(this));

        tokenIn = new MockERC20("IN", "IN");
        tokenOut = new MockERC20("OUT", "OUT");

        // Pools reachable ONLY via factory discovery — deliberately NOT seeded into the
        // registry, so the first solve genuinely pays the cold-discovery cost.
        for (uint256 i; i < N_POOLS; ++i) {
            MockV2Pair p = new MockV2Pair(address(tokenIn), address(tokenOut));
            tokenIn.mint(address(p), 1_000_000e18);
            tokenOut.mint(address(p), 1_000_000e18);
            p.setReserves(uint112(1_000_000e18), uint112(1_000_000e18));
            pools.push(p);

            MockV2Factory f = new MockV2Factory();
            f.setPair(address(tokenIn), address(tokenOut), address(p));
            hub.addFactory(address(f), BPC.KIND_V2, 0, bytes32(0), new uint24[](0), new int24[](0));
        }

        tokenIn.mint(user, 1_000_000e18);
        vm.prank(user);
        tokenIn.approve(address(router), type(uint256).max);
    }

    function _solveGas() internal returns (uint256 gasUsed, uint256 legs) {
        uint256 g0 = gasleft();
        RoutePlan memory plan = solver.findBestRoutePlan(address(tokenIn), address(tokenOut), AMT);
        gasUsed = g0 - gasleft();
        legs = plan.best.hops.length == 0 ? 0 : plan.best.hops[0].legs.length;
    }

    function _swapGas() internal returns (uint256 gasUsed) {
        RoutePlan memory plan = solver.findBestRoutePlan(address(tokenIn), address(tokenOut), AMT);
        Route memory route = plan.best;
        vm.prank(user);
        uint256 g0 = gasleft();
        // BP-04: userMinOut must be > 0 (RouterE(10)). 1 wei satisfies the
        // guard without constraining the fill — this harness measures GAS,
        // not slippage. Calldata cost rises 12 gas (one zero byte -> non-
        // zero) on BOTH sides of every live-vs-paused comparison, so the
        // reported DELTAS are unchanged; absolute figures shift once versus
        // pre-BP-04 logs.
        router.swapExactIn(route, AMT, 1, user, type(uint256).max);
        gasUsed = g0 - gasleft();
    }

    /// @dev Vitality of the pair's currently-registered pools, as the scorer sees it.
    function _vitalitySnapshot(uint32 ts) internal view returns (uint256 registered, uint256 vitSum, uint256 psiSum) {
        PoolInfo[] memory reg = hub.getActivePools(address(tokenIn), address(tokenOut));
        registered = reg.length;
        for (uint256 i; i < reg.length; ++i) {
            uint256 slot = hub.getSlot(hub.keyOf(reg[i].pool, reg[i].token0, reg[i].token1));
            vitSum += BPC.vitality(slot, ts);
            psiSum += BPC.psi(slot, ts, false, false);
        }
    }

    /// @notice What does registry feedback actually cost INSIDE a swap? The Router calls
    ///         `hub.recordSwap` once per leg, wrapped in try/catch. Pausing the Hub makes that
    ///         call revert on `whenLive` and be swallowed, so the delta isolates the write-side
    ///         work (tick + stamp + the eviction/insert logic) that a live registry performs.
    ///         This is the only part of the discovery/registry machinery a USER pays for —
    ///         solving itself is a free `view` call and never runs inside the transaction.
    function test_Metrics_RegistryFeedbackCostPerSwap() public {
        uint256 t = block.timestamp;
        // Warm everything first so we measure steady state, not first-touch registration.
        for (uint256 i; i < 3; ++i) { t += 60; vm.warp(t); _swapGas(); }

        t += 60; vm.warp(t);
        uint256 gLive = _swapGas();

        hub.setPaused(true);
        t += 60; vm.warp(t);
        uint256 gPaused = _swapGas();
        hub.setPaused(false);

        console2.log("=== registry feedback cost inside a swap ===");
        console2.log("swap with Hub live   (recordSwap writes), gas:", gLive);
        console2.log("swap with Hub paused (recordSwap reverts), gas:", gPaused);
        if (gLive > gPaused) {
            console2.log("registry write cost per swap, gas:", gLive - gPaused);
            console2.log("   as percent of the swap:", ((gLive - gPaused) * 100) / gLive);
            console2.log("   legs in this route:", pools.length);
        }
    }

    function test_Metrics_DiscoveryColdVsWarm_AndVitalityLifecycle() public {
        uint256 t = block.timestamp;

        console2.log("=== PHASE 1: COLD (registry empty, full discovery sweep) ===");
        console2.log("factories wired:", hub.factoryCount());
        uint256 gDiscover;
        {
            uint256 g0 = gasleft();
            hub.discoverFor(address(tokenIn), address(tokenOut));
            gDiscover = g0 - gasleft();
        }
        console2.log("discoverFor() alone, gas:", gDiscover);
        (uint256 gColdSolve, uint256 legsCold) = _solveGas();
        console2.log("findBestRoutePlan COLD, gas:", gColdSolve);
        console2.log("  legs planned:", legsCold);
        (uint256 regCold,,) = _vitalitySnapshot(uint32(t));
        console2.log("  pools registered before any swap:", regCold);

        console2.log("");
        console2.log("=== PHASE 2: real swaps through the Router (each ticks the Hub) ===");
        uint256[] memory swapGas = new uint256[](5);
        for (uint256 i; i < 5; ++i) {
            t += 60; // one minute apart, well inside the TTL
            vm.warp(t);
            swapGas[i] = _swapGas();
            (uint256 reg, uint256 vit, uint256 psiS) = _vitalitySnapshot(uint32(t));
            console2.log("swap #", i + 1);
            console2.log("   gas:", swapGas[i]);
            console2.log("   registered pools:", reg);
            console2.log("   vitality sum:", vit);
            console2.log("   psi sum:", psiS);
        }

        console2.log("");
        console2.log("=== PHASE 3: WARM solve (registry fresh -> discovery skipped) ===");
        (uint256 gWarmSolve, uint256 legsWarm) = _solveGas();
        console2.log("findBestRoutePlan WARM, gas:", gWarmSolve);
        console2.log("  legs planned:", legsWarm);
        if (gColdSolve > gWarmSolve) {
            console2.log("  reduction vs COLD, gas saved:", gColdSolve - gWarmSolve);
            console2.log("  reduction, percent:", ((gColdSolve - gWarmSolve) * 100) / gColdSolve);
        } else {
            console2.log("  NO reduction (registry did not reach fresh)");
        }

        console2.log("");
        console2.log("=== PHASE 4: TTL lapses -> discovery runs again ===");
        t += TTL + 1;
        vm.warp(t);
        (uint256 gStaleSolve,) = _solveGas();
        console2.log("findBestRoutePlan after TTL, gas:", gStaleSolve);

        console2.log("");
        console2.log("=== PHASE 5: vitality decay over a full window ===");
        (, uint256 vitBeforeDecay,) = _vitalitySnapshot(uint32(t));
        console2.log("vitality sum before decay:", vitBeforeDecay);
        // one decay step
        uint256 tStep = t + DECAY_STEP;
        (, uint256 vitOneStep,) = _vitalitySnapshot(uint32(tStep));
        console2.log("vitality sum after 1 decay step (~6.8h):", vitOneStep);
        // full decay horizon (32 steps ~ 9.1 days)
        uint256 tDead = t + (DECAY_STEP * 33);
        (, uint256 vitDead,) = _vitalitySnapshot(uint32(tDead));
        console2.log("vitality sum past the 32-step horizon (~9.1d):", vitDead);

        console2.log("");
        console2.log("=== PHASE 6: R3 check - reactivation must NOT restore history ===");
        t = tDead;
        vm.warp(t);
        uint256 gReviveSwap = _swapGas();
        (uint256 regRevive, uint256 vitRevive,) = _vitalitySnapshot(uint32(t));
        console2.log("reactivating swap, gas:", gReviveSwap);
        console2.log("registered pools:", regRevive);
        console2.log("vitality sum after reactivation:", vitRevive);
        console2.log("(pre-decay vitality sum was:", vitBeforeDecay);
        assertLt(vitRevive, vitBeforeDecay,
            "R3: a swap after full decay must not restore the pre-decay vitality");

        // Report-grade assertions: the measurement itself must be meaningful.
        // regCold is 0 BY DESIGN — in the cold phase the pools are reachable only through
        // discovery and are not registry entries yet; the signal that cold routing works is
        // that the solve still planned legs.
        assertEq(regCold, 0, "cold phase premise: the registry must genuinely start empty");
        assertGt(legsCold, 0, "cold phase must still route via discovery despite an empty registry");
        assertGt(swapGas[0], 0, "swaps must actually execute for these numbers to mean anything");
        assertLt(gWarmSolve, gColdSolve, "a fresh registry must make the solve cheaper, not dearer");
        assertGt(gStaleSolve, gWarmSolve, "once the TTL lapses the solve must pay for discovery again");
        assertEq(vitDead, 0, "past the 32-step horizon every pool must score a true zero");
    }
}
