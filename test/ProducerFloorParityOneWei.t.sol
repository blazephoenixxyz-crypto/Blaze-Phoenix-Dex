// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  One floor, three producers, to the wei.
//
//  The protective floor of a route is produced three times:
//    - the Solver attests it (`singleOutFloor = mulDivUp(base, floorBps, BPS)`,
//      BlazePhoenixSolver.sol:1812);
//    - the Quoter re-walks the route and rescales it onto its own walk output
//      (`floorExact = mulDiv(singleOutFloor, walkOut, planOut)`, BlazePhoenixQuoter.sol:902-903);
//    - the Router enforces its OWN floor from the in-frame quote of the final hop
//      (`protocolFloorOut = mulDivUp(finalHopQuote, floorBps, BPS)`, BlazePhoenixRouter.sol:1588)
//      and emits it in `ExecutionProof`.
//  FloorParitySolverRouter pins Solver == Router on round fixtures. This file asks the
//  same question where the product does NOT divide by BPS (odd reserves, blind amounts),
//  which is where a floor that rounds the other way moves by one wei, and adds the Quoter
//  as the third producer: at the plan's own amount its rescale is the identity, so the
//  three must agree exactly (tolerance 0, where ExactPreviewFloor allows 2).
//
//  tokenOut is a bridge, so the protocol fee comes out of the OUTPUT and the Router's
//  in-frame quote is the Solver's (no input-side fee to fold in).
//
//  Red under: Router:1588 `mulDivUp` -> `mulDiv` (the Router's floor one wei low whenever
//  the product does not divide) and the Quoter's rescale drifting by one unit
//  (registered in .github/scripts/mutants.py). No change to src.
// =============================================================================

import {Test, Vm} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixQuoter} from "../src/BlazePhoenixQuoter.sol";
import {BlazePhoenixCore as BPC, Route, RoutePlan} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";

contract ProducerFloorParityOneWeiTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    BlazePhoenixRouter router;
    BlazePhoenixQuoter quoter;
    MockERC20 tokenA;
    MockERC20 tokenB;
    address user = address(0xBEEF);

    bytes32 constant PROOF = keccak256("ExecutionProof(address,address,uint256,uint256,uint256,uint256)");

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        solver = new BlazePhoenixSolver(address(hub), address(0));
        router = new BlazePhoenixRouter(address(hub), address(solver), address(this), address(0xFEE1), address(0xFEE2));
        hub.setRoles(address(router), address(solver), address(this));
        quoter = new BlazePhoenixQuoter(address(hub), address(solver));
        tokenA = new MockERC20("A", "A");
        tokenB = new MockERC20("B", "B");
        hub.addBridge(address(tokenB)); // fee on the output, after the floor
        // Odd, unequal reserves: the quotes, and so quote * floorBps, are not multiples of BPS.
        _pool(1_000_003e18 + 17, 999_989e18 + 3);
        _pool(10_007e18 + 11, 9_973e18 + 5);
        tokenA.mint(user, 1e30);
        vm.prank(user);
        tokenA.approve(address(router), type(uint256).max);
    }

    function _pool(uint256 r0, uint256 r1) private {
        MockV2Pair p = new MockV2Pair(address(tokenA), address(tokenB));
        tokenA.mint(address(p), r0);
        tokenB.mint(address(p), r1);
        p.setReserves(uint112(r0), uint112(r1));
        hub.seedPool(address(p), BPC.KIND_V2, 30, address(0), address(tokenA), address(tokenB));
    }

    /// (finalHopQuote, protocolFloorOut) of the ExecutionProof: the Router's OWN floor.
    function _proof(Vm.Log[] memory logs) private pure returns (uint256 quote, uint256 floorOut, bool found) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == PROOF) {
                (quote, , floorOut, ) = abi.decode(logs[i].data, (uint256, uint256, uint256, uint256));
                return (quote, floorOut, true);
            }
        }
    }

    /// The three producers of the floor at the plan's amount; returns the number of legs.
    function _threeFloors(uint256 amt) private returns (uint256 legs) {
        RoutePlan memory plan = solver.findBestRoutePlan(address(tokenA), address(tokenB), amt);
        assertGt(plan.best.singleOutFloor, 0, "premise: the Solver attested a floor");
        assertEq(plan.best.hops.length, 1, "premise: a direct route");
        (Route memory r, uint256 exactOut) = quoter.previewRouteExact(plan.best, amt);
        assertGt(exactOut, 0, "premise: the preview walks");
        assertEq(r.totalOut, plan.best.totalOut, "premise: the Quoter re-walks to the Solver's gross");
        assertEq(r.singleOutFloor, plan.best.singleOutFloor,
            "Quoter floorExact == Solver singleOutFloor at the plan's amount, to the wei");
        vm.recordLogs();
        vm.prank(user);
        router.swapExactIn(plan.best, amt, 1, user, block.timestamp + 1);
        (uint256 quote, uint256 floorOut, bool found) = _proof(vm.getRecordedLogs());
        assertTrue(found, "premise: ExecutionProof emitted");
        assertGt(quote, 0, "premise: the Router quoted the final hop");
        assertEq(floorOut, plan.best.singleOutFloor,
            "Router protocolFloorOut == Solver singleOutFloor, to the wei");
        return plan.best.hops[0].legs.length;
    }

    /// Fixed odd amounts. The two pools differ in price by ~0.34%, so the small orders
    /// take the deep pool alone and the large one splits across both: the floor is
    /// checked on a one-leg and on a two-leg hop.
    function test_TheThreeFloorsAgreeToTheWei_SplitRoute() public {
        _threeFloors(1e18 + 7);
        _threeFloors(12_345e15 + 1);
        assertEq(_threeFloors(777_777e18 + 13), 2, "premise: the large order splits across both pools");
    }

    /// Blind amounts with the edges of the range included (1e9 wei to 3e23 wei: the
    /// deep pool's input side holds ~1e24).
    function testFuzz_TheThreeFloorsAgreeToTheWei(uint256 seed) public {
        uint256 amt;
        uint256 e = seed % 16;
        if (e == 0) amt = 1e9;
        else if (e == 1) amt = 3e23;
        else if (e == 2) amt = 1e18 + 7;
        else amt = bound(seed, 1e9, 3e23);
        _threeFloors(amt);
    }
}
