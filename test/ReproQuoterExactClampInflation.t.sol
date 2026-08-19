// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// Recovered from adversarial audit workflow wf_8e3fd5d8 (2026-08-18); re-derived as red-first.
// previewPlanExact (BlazePhoenixQuoter.sol:352) starts carry = amountIn (the caller's FULL order)
// and rescales every leg by carry/plannedIn. When the Solver's capacity clamp fired (hop.amountIn =
// committed leg < amountIn), that ratio > 1 reconstructs the PRE-CLAMP order and dry-runs the pool
// with it, overstating the "execution-grade" quote by up to ~166x — reintroducing the NetGakarot bug
// the Router caps at BlazePhoenixRouter.sol:514 (`if (h==0 && scaleNum>scaleDen) scaleNum=scaleDen`).
// Setup mirrors RouterUndoesSolverCapacityClamp.t.sol.
//
// RED-FIRST: the exact quote and the route it returns must be deliverable/executable. Present code
// overstates and returns an unexecutable route -> these tests FAIL today, and pass once the exact
// path caps hop-0 spend at the committed sum the way the Router already does.

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixQuoter} from "../src/BlazePhoenixQuoter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg, RoutePlan} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV3Pool} from "./mocks/MockV3Pool.sol";

contract ReproQuoterExactClampInflationTest is Test {
    BlazePhoenixHub    hub;
    BlazePhoenixSolver solver;
    BlazePhoenixRouter router;
    BlazePhoenixQuoter quoter;
    MockERC20 tokenA;
    MockERC20 tokenB;

    address treasury1 = address(0xFEE1);
    address treasury2 = address(0xFEE2);
    address user      = address(0xBEEF);

    uint128 constant DEEP_L         = 1e26;
    uint256 constant ORDER          = 50_000e18;
    uint256 constant POOL_HOLDING_B = 1_000e18;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        tokenA = new MockERC20("A", "A");
        tokenB = new MockERC20("B", "B");
        solver = new BlazePhoenixSolver(address(hub));
        router = new BlazePhoenixRouter(
            address(hub), address(solver), address(this), treasury1, treasury2
        );
        quoter = new BlazePhoenixQuoter(address(hub), address(solver));

        MockV3Pool p = new MockV3Pool(address(tokenA), address(tokenB), 100);
        p.setState(uint160(BPC.Q96), DEEP_L);
        tokenB.mint(address(p), POOL_HOLDING_B);
        hub.seedPool(address(p), BPC.KIND_V3, 100, address(0), address(tokenA), address(tokenB));

        tokenA.mint(user, ORDER);
        vm.prank(user);
        tokenA.approve(address(router), type(uint256).max);
    }

    // RED-FIRST: the exact quote must not overstate what execution of the Solver's own (clamped)
    // route delivers. Present code overstates by ~166x -> assertLe FAILS.
    function test_ExactQuoteMustNotOverstateDeliverable() public {
        RoutePlan memory plan = solver.findBestRoutePlan(address(tokenA), address(tokenB), ORDER);
        (, uint256 exactOut) = quoter.previewPlanExact(address(tokenA), address(tokenB), ORDER);

        vm.prank(user);
        uint256 delivered = router.swapExactIn(plan.best, ORDER, 1, user, block.timestamp + 1);

        emit log_named_uint("previewPlanExact exactOut", exactOut);
        emit log_named_uint("router delivered      ", delivered);
        assertGt(delivered, 0, "sanity: clamped route should deliver something");
        assertLe(exactOut, delivered * 2, "previewPlanExact overstates deliverable output (clamp re-inflation)");
    }

    // RED-FIRST: a swap sized to 95% of the quoter's OWN exact quote must be fillable, not revert.
    // Present code: the inflated quote makes userMinOut unreachable -> the swap reverts (test FAILS).
    function test_MinOutFromExactQuoteMustBeAchievable() public {
        (, uint256 exactOut) = quoter.previewPlanExact(address(tokenA), address(tokenB), ORDER);
        uint256 userMinOut = BPC.mulDiv(exactOut, 9_500, BPC.BPS); // 95% of the "exact" quote
        vm.prank(user);
        router.swapBestExactIn(address(tokenA), address(tokenB), ORDER, userMinOut, user, block.timestamp + 1);
    }

    // RED-FIRST: the exact route the quoter returns must be executable as-is. Present code returns
    // legs carrying the FULL order into a pool holding 1k B with an inflated singleOutFloor -> revert.
    function test_ReturnedExactRouteMustExecute() public {
        (Route memory exactRoute, ) = quoter.previewPlanExact(address(tokenA), address(tokenB), ORDER);
        vm.prank(user);
        router.swapExactIn(exactRoute, ORDER, 1, user, block.timestamp + 1);
    }
}
