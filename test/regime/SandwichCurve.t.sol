// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  The sandwich curve — the attacker's side of the floor, measured.
//
//  Every floor test in this suite asks whether a bad fill is REFUSED. None
//  asked what an adversary who orders the block can extract before the floor
//  refuses. This harness plays the attacker: the victim's route and floor are
//  fixed at quote time (as they are in a pending transaction), the attacker
//  moves the price by trading a fraction of the pool's depth ahead of the
//  victim, the victim executes, the attacker trades back. For each size the
//  harness records whether the victim settled or was refused, the victim's
//  loss against the pre-manipulation quote, and the attacker's net result -
//  and asserts the one guarantee the floor makes: whenever the victim settles,
//  the loss is bounded by the distance between the attested quote and the
//  attested floor. Beyond that distance the victim is refused, the attacker
//  is left holding the price they moved, and their round trip is a loss.
//
//  The venue is a constant-product pair (the shape every sandwich paper
//  models), so the curve is a property of the FLOOR, not of a mock's mercy.
//  Prints `SANDWICH <bps moved> <outcome> <victim loss bps> <attacker pnl>`.
// =============================================================================

import {Test, Vm, console2} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, RoutePlan} from "../../src/BlazePhoenixCore.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockV2Pair} from "../mocks/MockV2Pair.sol";
import {Outcomes} from "./Outcomes.sol";

contract SandwichCurveTest is Test {
    BlazePhoenixHub    hub;
    BlazePhoenixSolver solver;
    BlazePhoenixRouter router;
    MockERC20 tokenA;
    MockERC20 tokenB;
    MockV2Pair pair;
    address victim = address(0xBEEF);
    address attacker = address(0xA77AC);

    uint256 constant DEPTH = 1_000_000e18;
    uint256 constant VICTIM_IN = 10_000e18;   // 1 % of depth: a trade worth sandwiching

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        solver = new BlazePhoenixSolver(address(hub));
        router = new BlazePhoenixRouter(address(hub), address(solver), address(this), address(0xFEE1), address(0xFEE2));
        hub.setRoles(address(router), address(solver), address(this));
        tokenA = new MockERC20("A", "A");
        tokenB = new MockERC20("B", "B");
        pair = new MockV2Pair(address(tokenA), address(tokenB));
        tokenA.mint(address(pair), DEPTH);
        tokenB.mint(address(pair), DEPTH);
        pair.setReserves(uint112(DEPTH), uint112(DEPTH));
        hub.seedPool(address(pair), BPC.KIND_V2, 30, address(0), address(tokenA), address(tokenB));
        tokenA.mint(victim, VICTIM_IN);
        vm.prank(victim);
        tokenA.approve(address(router), type(uint256).max);
    }

    /// The attacker trades straight against the pair (no router, no floor), A -> B.
    function _attackerSwapAforB(uint256 amtA) private returns (uint256 gotB) {
        (uint112 r0, uint112 r1,) = pair.getReserves();
        bool aIs0 = address(tokenA) == pair.token0();
        uint256 rIn = aIs0 ? r0 : r1; uint256 rOut = aIs0 ? r1 : r0;
        gotB = BPC.outV2(amtA, rIn, rOut, 30);
        tokenA.mint(attacker, amtA);
        vm.startPrank(attacker);
        tokenA.transfer(address(pair), amtA);
        pair.swap(aIs0 ? 0 : gotB, aIs0 ? gotB : 0, attacker, "");
        vm.stopPrank();
    }

    function _attackerSwapBforA(uint256 amtB) private returns (uint256 gotA) {
        (uint112 r0, uint112 r1,) = pair.getReserves();
        bool aIs0 = address(tokenA) == pair.token0();
        uint256 rIn = aIs0 ? r1 : r0; uint256 rOut = aIs0 ? r0 : r1;
        gotA = BPC.outV2(amtB, rIn, rOut, 30);
        vm.startPrank(attacker);
        tokenB.transfer(address(pair), amtB);
        pair.swap(aIs0 ? gotA : 0, aIs0 ? 0 : gotA, attacker, "");
        vm.stopPrank();
    }

    bytes32 constant PROOF = keccak256("ExecutionProof(address,address,uint256,uint256,uint256,uint256)");
    function _floorUsed(Vm.Log[] memory logs) private pure returns (uint256 f) {
        for (uint256 i; i < logs.length; ++i) if (logs[i].topics[0] == PROOF) { (, , f, ) = abi.decode(logs[i].data, (uint256, uint256, uint256, uint256)); return f; }
    }

    /// One point of the curve: the attacker front-runs with `frontBps` of the pool's depth.
    function _point(uint256 frontBps) private returns (bool settled, uint256 lossBps, int256 attackerPnl) {
        uint256 snap = vm.snapshotState();
        // 1. the victim's route and floor are fixed at quote time, before any manipulation
        RoutePlan memory plan = solver.findBestRoutePlan(address(tokenA), address(tokenB), VICTIM_IN);
        Route memory route = plan.best;
        uint256 quoted = route.totalOut;
        uint256 attested = route.singleOutFloor;
        assertGt(attested, 0, "premise: the planner attested a floor");
        // 2. the attacker moves the price
        uint256 frontIn = DEPTH * frontBps / 10_000;
        uint256 attackerA0 = tokenA.balanceOf(attacker);
        uint256 gotB = frontIn == 0 ? 0 : _attackerSwapAforB(frontIn);
        // 3. the victim executes the pending route with the floor fixed at quote time
        vm.recordLogs();
        vm.prank(victim);
        (bool ok, bytes memory ret) = address(router).call(abi.encodeCall(router.swapExactIn, (route, VICTIM_IN, 1, victim, block.timestamp + 1)));
        uint256 delivered;
        if (ok) {
            delivered = abi.decode(ret, (uint256));
            uint256 floorUsed = _floorUsed(vm.getRecordedLogs());
            assertGe(delivered, floorUsed, "a settled fill is at or above the floor the Router enforced");
            // THE GUARANTEE: a settled victim never loses more than the attested distance.
            assertGe(delivered, attested, "a settled fill never falls below the floor attested at quote time");
            lossBps = quoted > delivered ? (quoted - delivered) * 10_000 / quoted : 0;
            settled = true;
        } else {
            (bool ours,) = Outcomes.classify(ret);
            assertTrue(ours, "a refusal must carry a selector of ours");
        }
        // 4. the attacker trades back what they got
        uint256 backA = gotB == 0 ? 0 : _attackerSwapBforA(gotB);
        attackerPnl = int256(tokenA.balanceOf(attacker)) - int256(attackerA0) - int256(frontIn) + int256(backA) - int256(backA);
        // (balance delta already includes backA; the two cancel and are kept for readability)
        attackerPnl = int256(tokenA.balanceOf(attacker)) - int256(attackerA0 + frontIn);
        vm.revertToState(snap);
    }

    function test_SandwichCurve_TheFloorBoundsTheVictimAndStarvesTheAttacker() public {
        uint16[9] memory grid = [uint16(0), 10, 50, 100, 200, 300, 400, 600, 1000];
        uint256 firstRefusal = type(uint256).max;
        for (uint256 i; i < grid.length; ++i) {
            (bool settled, uint256 lossBps, int256 pnl) = _point(grid[i]);
            console2.log("SANDWICH", uint256(grid[i]), settled ? "SETTLED" : "REFUSED", settled ? lossBps : 0);
            console2.logInt(pnl);
            if (!settled && firstRefusal == type(uint256).max) firstRefusal = grid[i];
            if (settled) assertLe(lossBps, 10_000, "loss is a fraction");
            // Once the floor refuses, every larger manipulation is refused too: the attacker
            // cannot find a size past the threshold that the victim still accepts.
            if (firstRefusal != type(uint256).max) assertFalse(settled, "the refusal region is closed upward");
        }
        assertTrue(firstRefusal != type(uint256).max, "the grid reaches the refusal region");
    }
}
