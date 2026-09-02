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
        hub.addBridge(address(tokenB)); // fee on the output, after the floor
        _pool(1_000_000e18);
        _pool(10_000e18);
        tokenA.mint(user, 1_000_000e18);
        vm.prank(user);
        tokenA.approve(address(router), type(uint256).max);
    }

    function _pool(uint256 r) private {
        MockV2Pair p = new MockV2Pair(address(tokenA), address(tokenB));
        tokenA.mint(address(p), r);
        tokenB.mint(address(p), r);
        p.setReserves(uint112(r), uint112(r));
        hub.seedPool(address(p), BPC.KIND_V2, 30, address(0), address(tokenA), address(tokenB));
    }

    function _floorUsed(Vm.Log[] memory logs) private pure returns (uint256 floorUsed, bool found) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == PROOF) {
                (, , floorUsed, ) = abi.decode(logs[i].data, (uint256, uint256, uint256, uint256));
                return (floorUsed, true);
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
}
