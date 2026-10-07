// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  MAX_BRIDGES and the Solver: the third arm is live, not a ghost.
//
//  `Hub.MAX_BRIDGES = 3` and the Solver unrolls three bridge arms by hand.
//  RoutableBridgeAsymmetry pins the flag (every configured bridge gains fitness; a
//  fourth is refused with HubE(7)). This pins the behaviour: with the third bridge
//  the deepest, the Solver routes through it; once removed, it appears in no hop.
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixCore as BPC, RoutePlan} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";

contract MaxBridgesThreeArmsTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;

    MockERC20 tA;
    MockERC20 tB;
    MockERC20 b0;
    MockERC20 b1;
    MockERC20 b2;

    uint256 constant AMT = 1_000e18;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0xBEEF));
        solver = new BlazePhoenixSolver(address(hub));
        hub.setRoles(address(this), address(solver), address(this));

        tA = new MockERC20("A", "A");
        tB = new MockERC20("B", "B");
        b0 = new MockERC20("B0", "B0");
        b1 = new MockERC20("B1", "B1");
        b2 = new MockERC20("B2", "B2");

        hub.addBridge(address(b0));
        hub.addBridge(address(b1));
        hub.addBridge(address(b2));

        // The direct A-B pool is deliberately shallow: it can never win.
        _pool(tA, tB, 2e18);
        // Arms 0 and 1 are thin.
        _pool(tA, b0, 200_000e18); _pool(b0, tB, 200_000e18);
        _pool(tA, b1, 100_000e18); _pool(b1, tB, 100_000e18);
        // Arm 2 is deep: the best route is A -> b2 -> B.
        _pool(tA, b2, 5_000_000e18); _pool(b2, tB, 5_000_000e18);
    }

    function _pool(MockERC20 x, MockERC20 y, uint256 r) private {
        MockV2Pair p = new MockV2Pair(address(x), address(y));
        x.mint(address(p), r);
        y.mint(address(p), r);
        p.setReserves(uint112(r), uint112(r));
        hub.seedPool(address(p), BPC.KIND_V2, 30, address(0), address(x), address(y));
    }

    // ── 1. The limit ────────────────────────────────────────────────────────

    function test_BridgeLimitIsThreeAndAFourthIsRefused() public {
        assertEq(hub.bridgeCount(), 3, "the limit is no longer 3");
        MockERC20 b3 = new MockERC20("B3", "B3");
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixHub.HubE.selector, 7));
        hub.addBridge(address(b3));
    }

    // ── 2. The third arm is reachable ───────────────────────────────────────

    /// With only two arms in the Solver, `b2` would be a ghost bridge and the chosen
    /// route would not go through it.
    function test_ThirdBridgeIsChosenWhenItIsTheBest() public view {
        RoutePlan memory plan = solver.findBestRoutePlan(address(tA), address(tB), AMT);
        assertGt(plan.best.hops.length, 0, "setup: there is a plan");
        assertEq(plan.best.hops[0].tokenOut, address(b2),
            "the deepest route (via bridge 2) was not chosen: the third arm is a ghost");
        assertEq(plan.best.hops.length, 2, "the bridge route has two hops");
    }

    // ── 3. A removed bridge never appears ───────────────────────────────────

    function test_RemovedBridgeNeverAppearsInAnyHop() public {
        hub.removeBridge(2);
        assertEq(hub.bridgeCount(), 2, "removeBridge did not compact");

        RoutePlan memory plan = solver.findBestRoutePlan(address(tA), address(tB), AMT);
        assertGt(plan.best.hops.length, 0, "setup: there is a plan after the removal");
        for (uint256 h; h < plan.best.hops.length; ++h) {
            assertTrue(plan.best.hops[h].tokenIn != address(b2) && plan.best.hops[h].tokenOut != address(b2),
                "a removed bridge appeared in a hop");
        }
        if (plan.hasFallback) {
            for (uint256 h; h < plan.fallbackRoute.hops.length; ++h) {
                assertTrue(
                    plan.fallbackRoute.hops[h].tokenIn != address(b2)
                        && plan.fallbackRoute.hops[h].tokenOut != address(b2),
                    "a removed bridge appeared in the fallback route");
            }
        }
    }
}