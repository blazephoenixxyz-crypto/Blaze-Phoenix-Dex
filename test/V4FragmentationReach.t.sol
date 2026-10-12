// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  IS THE V4 FRAGMENTATION ATTACK REACHABLE WITHOUT AN OPERATOR?
//
//  The report (seavia) seats the attacker's rival venue with `hub.seedPool`,
//  which is `onlyOperator`, and names the permissionless door it did not run:
//  discovery (`Hub.discoverFor`, called by `Solver._topKPools` whenever the
//  pair's registry is not fresh). This file runs that door.
//
//  What is configuration and what is the attacker:
//    - configuration (once, at deployment): the admin admits a V2 factory and the
//      operator registers the honest V4 pool. Neither names the attacker's pool.
//    - the attacker, with no role: creates and funds a pair in the admitted
//      factory (UniswapV2Factory.createPair is permissionless; the mock's
//      `setPair` stands for it) and mints twenty one-wei positions in the honest
//      pool (`modifyLiquidity` has no access control; measured against the
//      canonical PoolManager in test/fork/V4FragmentationPermissionlessFork.t.sol).
//
//  Red at dcca0da (main after #98): the order leaves the honest pool, because the
//  sixteen-stretch walk (`Core.v4WalkOut`) was both the promise and the ranking.
//  Green once the ranking reads the deep walk (`Core.v4WalkRank`); the promise is
//  still `v4WalkOut`, unchanged.
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, PoolInfo} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";
import {MockV2Factory} from "./mocks/MockV2Factory.sol";
import {MockV4TickManager} from "./mocks/MockV4TickManager.sol";

contract V4FragmentationReachTest is Test {
    MockV4TickManager mgr;
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    BlazePhoenixRouter router;
    MockV2Factory fac;
    MockV2Pair pair;
    address t0;
    address t1;
    address user     = address(0xBEEF);
    address attacker = address(0xBAD);

    uint8   constant MODE_ASK = 0;
    uint24  constant FEE = 100;       // 0.01% tier, tickSpacing 1
    int24   constant TS  = 1;
    uint128 constant L   = 1e24;
    uint256 constant ORDER = 1e22;

    function setUp() public {
        mgr = new MockV4TickManager();
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(mgr));
        solver = new BlazePhoenixSolver(address(hub));
        router = new BlazePhoenixRouter(address(hub), address(solver), address(this), address(0xFEE1), address(0xFEE2));
        hub.setRoles(address(router), address(solver), address(0xC0FFEE));
        MockERC20 a = new MockERC20("A", "A");
        MockERC20 b = new MockERC20("B", "B");
        (t0, t1) = address(a) < address(b) ? (address(a), address(b)) : (address(b), address(a));
        MockERC20(t0).mint(address(mgr), 1e30);
        MockERC20(t1).mint(address(mgr), 1e30);
        MockERC20(t0).mint(user, 10 * ORDER);
        vm.prank(user);
        MockERC20(t0).approve(address(router), type(uint256).max);
        // Configuration: one V2 factory admitted by the admin. It names no pool.
        fac = new MockV2Factory();
        hub.addFactory(address(fac), BPC.KIND_V2, MODE_ASK, bytes32(0), new uint24[](0), new int24[](0));
    }

    function _pid() internal view returns (bytes32) { return BPC.computeV4PoolId(t0, t1, FEE, TS, address(0)); }

    function _honestV4() internal {
        mgr.initialize(_pid(), BPC.sqrtPriceAtTick(0), 0, FEE);
        mgr.addPosition(_pid(), -20_000, 20_000, TS, L);
        hub.addV4(t0, t1, FEE, TS, address(0));
    }

    /// The attacker's rival, created and funded by the attacker alone: no seedPool.
    function _rivalByAttacker(uint112 r0, uint112 r1) internal {
        vm.startPrank(attacker);
        pair = new MockV2Pair(t0, t1);
        fac.setPair(t0, t1, address(pair));      // UniswapV2Factory.createPair: permissionless
        vm.stopPrank();
        MockERC20(t0).mint(address(pair), r0);
        MockERC20(t1).mint(address(pair), r1);
        pair.setReserves(r0, r1);
    }

    function _fragment(int24 lo, int24 hi) internal {
        vm.startPrank(attacker);
        for (int24 t = lo; t < hi; ++t) mgr.addPosition(_pid(), t, t + 1, TS, 1);
        vm.stopPrank();
    }

    function _swap() internal returns (uint256 got) {
        uint256 b1 = MockERC20(t1).balanceOf(user);
        vm.prank(user);
        router.swapBestExactIn(t0, t1, ORDER, 1, user, block.timestamp + 1);
        got = MockERC20(t1).balanceOf(user) - b1;
    }

    /// The rival is never registered: only discovery lists it, and the registry holds
    /// one curated row, below MIN_FRESH_VENUES, so the Solver runs discovery.
    function test_Reach_RivalIsDiscoveredNotSeeded() public {
        _honestV4();
        _rivalByAttacker(2e22, 2e22);
        PoolInfo[] memory reg = hub.getActivePools(t0, t1);
        for (uint256 i; i < reg.length; ++i) assertTrue(reg[i].pool != address(pair), "rival must not be registered");
        PoolInfo[] memory dis = hub.discoverFor(t0, t1);
        bool seen;
        for (uint256 i; i < dis.length; ++i) if (dis[i].pool == address(pair)) seen = true;
        assertTrue(seen, "discovery lists the attacker's pair");
    }

    /// The whole attack with no operator action on the attacker's side: a stranger's
    /// twenty one-wei mints must not move the order off the honest pool.
    function test_Reach_NoOperator_FragmentationDoesNotMoveTheOrder() public {
        uint256 snap = vm.snapshotState();
        _honestV4();
        _rivalByAttacker(2e22, 2e22);
        uint256 clean = _swap();
        vm.revertToState(snap);
        _honestV4();
        _rivalByAttacker(2e22, 2e22);
        _fragment(-20, 0);
        uint256 dirty = _swap();
        emit log_named_uint("delivered, clean pool      ", clean);
        emit log_named_uint("delivered, fragmented pool ", dirty);
        emit log_named_uint("user loss (wei of token1)  ", clean > dirty ? clean - dirty : 0);
        assertGt(clean, 9e21, "control: the deep pool fills near par");
        assertLe(clean > dirty ? clean - dirty : 0, 1e18, "fragmentation moved the order off the honest pool");
    }
}
