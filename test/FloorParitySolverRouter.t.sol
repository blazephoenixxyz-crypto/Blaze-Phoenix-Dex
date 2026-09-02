// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  The floor the Solver ATTESTS and the floor the Router ENFORCES are two
//  producers of one quantity. They drifted on two axes (6th bounty wave,
//  2026-09-02; review F6/F8 the same day): the Solver averaged leg impacts
//  UNWEIGHTED and rounded the floor DOWN, the Router weights by the leg's
//  share (`_wImp`) and rounds UP. PreviewExecutionParity never compared the
//  two, so its green was not evidence.
//
//  This is the missing refuter: the same route, the same block, the Solver's
//  `singleOutFloor` must equal the `floorUsed` the Router emits. tokenOut is
//  a bridge so the fee comes out of the OUTPUT and the Router's in-frame
//  quote equals the Solver's (no input-side fee to fold in).
//  RED on main a1ec7cd (off by the rounding, and by the weighting whenever the
//  legs' impacts differ).
// =============================================================================

import {Test, Vm} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, RoutePlan} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";

contract FloorParitySolverRouterTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    BlazePhoenixRouter router;
    MockERC20 tokenA;
    MockERC20 tokenB;
    MockERC20 tokenC;
    address user = address(0xBEEF);

    bytes32 constant PROOF = keccak256("ExecutionProof(address,address,uint256,uint256,uint256,uint256)");

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        solver = new BlazePhoenixSolver(address(hub));
        router = new BlazePhoenixRouter(address(hub), address(solver), address(this), address(0xFEE1), address(0xFEE2));
        hub.setRoles(address(router), address(solver), address(this));
        tokenA = new MockERC20("A", "A");
        tokenB = new MockERC20("B", "B");
        tokenC = new MockERC20("C", "C");
        hub.addBridge(address(tokenB)); // fee on the output, after the floor
        _pool(tokenA, tokenB, 1_000_000e18);
        _pool(tokenA, tokenB, 10_000e18);
        // The second hop of the A -> B -> C route: the same depth contrast, so
        // both hops split and both concentrate their input in the deep leg.
        _pool(tokenB, tokenC, 1_000_000e18);
        _pool(tokenB, tokenC, 10_000e18);
        tokenA.mint(user, 1_000_000e18);
        vm.prank(user);
        tokenA.approve(address(router), type(uint256).max);
    }

    function _pool(MockERC20 t0, MockERC20 t1, uint256 r) private {
        MockV2Pair p = new MockV2Pair(address(t0), address(t1));
        t0.mint(address(p), r);
        t1.mint(address(p), r);
        p.setReserves(uint112(r), uint112(r));
        hub.seedPool(address(p), BPC.KIND_V2, 30, address(0), address(t0), address(t1));
    }

    function _floorUsed(Vm.Log[] memory logs) private pure returns (uint256 floorUsed, bool found) {
        (uint256 q, uint256 f, bool ok) = _proof(logs);
        q;
        return (f, ok);
    }

    /// @dev (finalHopQuote, protocolFloorOut) of the ExecutionProof: the
    ///      Router's OWN floor, not the max with the attested one.
    function _proof(Vm.Log[] memory logs) private pure returns (uint256 quote, uint256 floorOut, bool found) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == PROOF) {
                (quote, , floorOut, ) = abi.decode(logs[i].data, (uint256, uint256, uint256, uint256));
                return (quote, floorOut, true);
            }
        }
    }

    function _parity(uint256 amt) private {
        RoutePlan memory plan = solver.findBestRoutePlan(address(tokenA), address(tokenB), amt);
        assertGt(plan.best.singleOutFloor, 0, "premise: the Solver attested a floor");
        vm.recordLogs();
        vm.prank(user);
        router.swapExactIn(plan.best, amt, 1, user, block.timestamp + 1);
        (uint256 floorUsed, bool found) = _floorUsed(vm.getRecordedLogs());
        assertTrue(found, "premise: ExecutionProof emitted");
        assertEq(floorUsed, plan.best.singleOutFloor,
            "the floor the Solver attests must be the floor the Router enforces, on the same block");
    }

    /// A split across two pools of different depth: the legs carry different
    /// shares, so weighting (not just rounding) is exercised.
    function test_Parity_SplitRoute_AttestedFloorEqualsEnforcedFloor() public {
        RoutePlan memory plan = solver.findBestRoutePlan(address(tokenA), address(tokenB), 50_000e18);
        assertGt(plan.best.hops[0].legs.length, 1, "premise: the plan splits across pools");
        _parity(50_000e18);
    }

    /// A small order the Solver routes through one pool: the rounding axis alone.
    function test_Parity_SingleLegRoute_AttestedFloorEqualsEnforcedFloor() public {
        _parity(777e15);
    }

    /// THE TWIN. A -> B -> C over the bridge, both hops split with ~99% of the
    /// input in the deep leg: exactly the regime where the multi-hop arm's
    /// unweighted per-hop mean, summed across hops, attested a floor TIGHTER
    /// than the Router's share-weighted global mean (review 2026-09-02, after
    /// PR #25 fixed only the single-hop arm and declared this one safe).
    /// The fee is taken on hop 1's bridge input here, so the two absolute
    /// floors are priced on different bases; the floor RATE is what both
    /// producers must agree on, and mulDivUp on 1e18-scale quotes cannot
    /// move it by a whole bps.
    function test_Parity_TwoHopSplitRoute_AttestedFloorRateEqualsEnforcedFloorRate() public {
        uint256 amt = 50_000e18;
        RoutePlan memory plan = solver.findBestRoutePlan(address(tokenA), address(tokenC), amt);
        assertEq(plan.best.hops.length, 2, "premise: the route crosses the bridge");
        assertGt(plan.best.hops[0].legs.length, 1, "premise: hop 0 splits");
        assertGt(plan.best.hops[1].legs.length, 1, "premise: hop 1 splits");
        assertGt(plan.best.singleOutFloor, 0, "premise: the Solver attested a floor");

        vm.recordLogs();
        vm.prank(user);
        router.swapExactIn(plan.best, amt, 1, user, block.timestamp + 1);
        (uint256 quote, uint256 floorOut, bool found) = _proof(vm.getRecordedLogs());
        assertTrue(found, "premise: ExecutionProof emitted");

        uint256 attestedBps = BPC.mulDiv(plan.best.singleOutFloor, BPC.BPS, plan.best.totalOut);
        uint256 enforcedBps = BPC.mulDiv(floorOut, BPC.BPS, quote);
        assertEq(attestedBps, enforcedBps,
            "two hops: the floor rate the Solver attests must be the floor rate the Router enforces");
    }
}
