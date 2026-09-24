// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  WHAT A V4 LEG PROMISES IS WHAT ITS POOL PAYS - AND ONE FIGURE RANKS IT TOO.
//
//  The ninth wave found the single-tick model's two answers in conflict: the plan
//  attested a figure the Router then refused (acit aja; mohaseenbasha dex-14; #74
//  split the ranking figure from the promise to stop it), and a pool holding one
//  tick of range out-ranked an honest one (dex-19). Since the walk
//  (`Core.v4WalkOut`) the figure that ranks a venue, the figure its leg attests
//  and the Router's in-frame quote are one computation over the pool's own book.
//  These pin the properties #74 established, against a book whose range really
//  ends: a preview that says executable settles; the published floor never asks
//  for more than the pool pays; the attestation is the Router's own in-frame
//  number; a multi-hop floor is honoured.
//
//  The book is MockV4TickManager's: one position around the price, nothing
//  beyond it, and a swap written from the specification.
// =============================================================================

import {Test, Vm, console2} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixQuoter} from "../src/BlazePhoenixQuoter.sol";
import {BlazePhoenixCore as BPC, Leg, RoutePlan} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV4TickManager} from "./mocks/MockV4TickManager.sol";

contract V4PromiseIsWhatThePoolPays is Test {
    BlazePhoenixHub    hub;
    BlazePhoenixSolver solver;
    BlazePhoenixRouter router;
    BlazePhoenixQuoter quoter;
    MockV4TickManager  mgr;
    MockERC20 A;
    MockERC20 B;

    address user = address(0xBEEF);
    uint24  constant FEE = 3000;
    int24   constant TS  = 60;
    uint128 constant LIQ = 1e18;      // one thin range
    uint256 constant AMT = 1e21;      // an order that leaves it
    bytes32 pid;

    function setUp() public {
        mgr = new MockV4TickManager();
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(mgr));
        solver = new BlazePhoenixSolver(address(hub));
        router = new BlazePhoenixRouter(address(hub), address(solver), address(this), address(0xFEE1), address(0xFEE2));
        quoter = new BlazePhoenixQuoter(address(hub), address(solver));
        hub.setRoles(address(router), address(solver), address(quoter));

        A = new MockERC20("AAA", "AAA");
        B = new MockERC20("BBB", "BBB");
        (address t0, address t1) = address(A) < address(B) ? (address(A), address(B)) : (address(B), address(A));
        pid = BPC.computeV4PoolId(t0, t1, FEE, TS, address(0));
        // [0, 60) with the price at tick 59, and nothing beyond: one direction has 59 ticks
        // of range ahead, the other one.
        mgr.initialize(pid, mgr.sqrtAt(59), 59, FEE);
        mgr.addPosition(pid, 0, 60, TS, LIQ);
        hub.addV4(address(A), address(B), FEE, TS, address(0));

        A.mint(user, AMT);
        A.mint(address(mgr), 1e21);
        B.mint(address(mgr), 1e21);
        vm.prank(user);
        A.approve(address(router), type(uint256).max);
    }

    function _zfo() internal view returns (bool) { return address(A) < address(B); }

    /// What the pool pays for `amt`, from the specification's swap - not from the Core.
    function _pays(uint256 amt) internal view returns (uint256 out) {
        (, out, , , ) = mgr.specSwap(pid, amt, FEE, TS, _zfo());
    }

    function test_ThePublishedFloorNeverExceedsWhatTheVenueCanPay() public {
        (BlazePhoenixQuoter.Preview memory pv,,) = quoter.previewPlan(address(A), address(B), AMT);
        assertTrue(pv.canExecute, "preview must say the route is executable");
        RoutePlan memory plan = solver.findBestRoutePlan(address(A), address(B), AMT);
        Leg memory lg = plan.best.hops[0].legs[0];
        uint256 pays = _pays(lg.amountIn);
        console2.log("leg attestation :", lg.expectedOut);
        console2.log("the pool pays   :", pays);
        console2.log("published floor :", plan.best.singleOutFloor);
        assertLe(plan.best.singleOutFloor, pays, "the published floor asks for more than the pool pays");

        vm.prank(user);
        uint256 got = router.swapExactIn(pv.route, AMT, 1, user, block.timestamp + 1);
        assertGe(got, plan.best.singleOutFloor, "delivered below the floor the plan published");
    }

    /// A preview that says `canExecute` must not be refused by the Router.
    function test_Red_CanExecuteMustNotBeRefused() public {
        (BlazePhoenixQuoter.Preview memory pv,,) = quoter.previewPlan(address(A), address(B), AMT);
        assertTrue(pv.canExecute, "preview must say the route is executable");
        vm.prank(user);
        router.swapExactIn(pv.route, AMT, pv.effectiveMinOut, user, block.timestamp + 1);
    }

    /// The leg attests what its pool pays, and the figure that ranked it is that same one.
    function test_TheLegAttestsWhatThePoolPays_AndRankingIsThatFigure() public view {
        RoutePlan memory plan = solver.findBestRoutePlan(address(A), address(B), AMT);
        Leg memory lg = plan.best.hops[0].legs[0];
        assertApproxEqAbs(lg.expectedOut, _pays(lg.amountIn), 4, "the leg attests other than what the pool pays");
        assertEq(plan.best.totalOut, lg.expectedOut, "the ranking figure and the promise are two numbers again");
    }

    /// One evaluator: the attestation and the Router's in-frame quote, read back from its
    /// own ExecutionProof rather than recomputed here.
    function test_Parity_TheLegAttestsWhatTheRouterQuotesInFrame() public {
        RoutePlan memory plan = solver.findBestRoutePlan(address(A), address(B), AMT);
        assertEq(plan.best.hops.length, 1, "one hop");
        assertEq(plan.best.hops[0].legs.length, 1, "one leg, so the hop's quote is the leg's");
        uint256 attested = plan.best.hops[0].legs[0].expectedOut;

        vm.recordLogs();
        vm.prank(user);
        router.swapExactIn(plan.best, AMT, 1, user, block.timestamp + 1);

        bytes32 sig = keccak256("ExecutionProof(address,address,uint256,uint256,uint256,uint256)");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 quoted;
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(router) || logs[i].topics[0] != sig) continue;
            found = true;
            (quoted, , , ) = abi.decode(logs[i].data, (uint256, uint256, uint256, uint256));
        }
        assertTrue(found, "ExecutionProof missing");
        assertEq(attested, quoted, "the plan's attestation and the Router's in-frame quote are two numbers");
    }
}

/// The same across hops: A -> B leaves its one thin range, B -> C is deep and never
/// reaches an edge. Each hop is ranked, sized and promised on what its pool pays.
contract V4PromiseAcrossHops is Test {
    BlazePhoenixHub    hub;
    BlazePhoenixSolver solver;
    BlazePhoenixRouter router;
    MockV4TickManager  mgr;
    MockERC20 A;
    MockERC20 B;
    MockERC20 C;

    address user = address(0xBEEF);
    uint24  constant FEE = 3000;
    int24   constant TS  = 60;
    uint256 constant AMT = 1e21;

    function setUp() public {
        mgr = new MockV4TickManager();
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(mgr));
        solver = new BlazePhoenixSolver(address(hub));
        router = new BlazePhoenixRouter(address(hub), address(solver), address(this), address(0xFEE1), address(0xFEE2));
        BlazePhoenixQuoter quoter = new BlazePhoenixQuoter(address(hub), address(solver));
        hub.setRoles(address(router), address(solver), address(quoter));

        A = new MockERC20("AAA", "AAA");
        B = new MockERC20("BBB", "BBB");
        C = new MockERC20("CCC", "CCC");

        _pool(address(A), address(B), 59, 0, 60, 1e18);          // thin: the order leaves it
        _pool(address(B), address(C), 30, -6000, 6000, 1e27);    // deep: no edge is reached

        hub.addV4(address(A), address(B), FEE, TS, address(0));
        hub.addV4(address(B), address(C), FEE, TS, address(0));
        hub.addBridge(address(B));

        A.mint(user, AMT);
        A.mint(address(mgr), 1e21);
        B.mint(address(mgr), 1e21);
        C.mint(address(mgr), 1e21);
        vm.prank(user);
        A.approve(address(router), type(uint256).max);
    }

    function _pool(address x, address y, int24 tick, int24 lo, int24 hi, uint128 liq) internal {
        (address t0, address t1) = x < y ? (x, y) : (y, x);
        bytes32 id = BPC.computeV4PoolId(t0, t1, FEE, TS, address(0));
        mgr.initialize(id, mgr.sqrtAt(tick), tick, FEE);
        mgr.addPosition(id, lo, hi, TS, liq);
    }

    function test_TheMultiHopFloorFollowsTheChainOfPromises() public {
        RoutePlan memory plan = solver.findBestRoutePlan(address(A), address(C), AMT);
        assertEq(plan.best.hops.length, 2, "the route bridges through B");
        (address t0, address t1) = address(A) < address(B) ? (address(A), address(B)) : (address(B), address(A));
        (, uint256 pays, , , ) = mgr.specSwap(BPC.computeV4PoolId(t0, t1, FEE, TS, address(0)),
            plan.best.hops[0].amountIn, FEE, TS, address(A) < address(B));
        assertApproxEqAbs(plan.best.hops[0].expectedOut, pays, 4,
            "the first hop was ranked on more than its pool pays, and the second sized on it");

        vm.prank(user);
        uint256 got = router.swapExactIn(plan.best, AMT, 1, user, block.timestamp + 1);
        console2.log("route.singleOutFloor :", plan.best.singleOutFloor);
        console2.log("delivered            :", got);
        assertGe(got, plan.best.singleOutFloor, "delivered below the floor the plan published");
    }
}
