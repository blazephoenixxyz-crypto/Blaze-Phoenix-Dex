// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  REGRESSION — the residual must go back to the payer, not to whoever the
//  frame calls msg.sender.
//
//  The property "the caller gets the uncommitted remainder back" was already
//  owned by a test: RouterUndoesSolverCapacityClamp exercises exactly this
//  scenario (a phantom-tier clamp cuts the leg, so the Router pulls the full
//  order and must sweep the unspent part home) and asserts the caller spends
//  only the committed input. That test passed throughout the bug's lifetime.
//
//  It passed because it enters through swapExactIn, where the Router is called
//  directly and msg.sender in the sweep frame IS the user. swapBestExactIn
//  reaches the same sweep through `this.selfExecutePrePulled(...)` — an
//  EXTERNAL self-call, which rewrites msg.sender to the Router itself. The
//  sweep then paid the residual to the Router, stranding it there: funds lost
//  to the user and, worse, left sitting in a contract whose stated invariant
//  is that it holds nothing between transactions.
//
//  So the invariant was correct, enforced, and tested — and still broke, because
//  no test drove it through the one entry point where msg.sender is not the
//  payer. The identity of "who funded this swap" is not observable from the
//  frame that spends it; it has to be carried. Hence the explicit `payer`
//  parameter, and hence this file: the same property, through the other door.
//
//  forge test --match-contract RouterBestExactInRefundsPayer -vv
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, RoutePlan} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV3Pool} from "./mocks/MockV3Pool.sol";

contract RouterBestExactInRefundsPayerTest is Test {
    BlazePhoenixHub    hub;
    BlazePhoenixSolver solver;
    BlazePhoenixRouter router;
    MockERC20 tokenA; // tokenIn
    MockERC20 tokenB; // tokenOut

    address treasury1 = address(0xFEE1);
    address treasury2 = address(0xFEE2);
    address user      = address(0xBEEF);

    // Same shape as RouterUndoesSolverCapacityClamp: a pool quoting ~1:1 on deep
    // nominal liquidity while actually holding very little tokenB. The phantom
    // tier clamps the leg far below the order, which is what leaves a residual.
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
        hub.setRoles(address(router), address(solver), address(this));
        tokenA.mint(user, ORDER);
        vm.prank(user);
        tokenA.approve(address(router), type(uint256).max);
    }

    function _seedThinV3() internal returns (MockV3Pool p) {
        p = new MockV3Pool(address(tokenA), address(tokenB), 100);
        p.setState(uint160(BPC.Q96), DEEP_L);
        tokenB.mint(address(p), POOL_HOLDING_B);
        hub.seedPool(address(p), BPC.KIND_V3, 100, address(0), address(tokenA), address(tokenB));
    }

    /// THE REGRESSION. swapBestExactIn discovers the route inside the swap and
    /// then bridges through the external self-call, so this is the only entry
    /// point where the sweep frame's msg.sender is the Router. The residual must
    /// still reach the user, and the Router must end the transaction empty.
    function test_BestExactIn_ResidualReturnsToUser_NotStrandedInRouter() public {
        _seedThinV3();

        // Ask the Solver the same question the Router will ask, so we know how
        // much of the order is actually committed — the rest is the residual.
        RoutePlan memory plan = solver.findBestRoutePlan(address(tokenA), address(tokenB), ORDER);
        uint256 committed = plan.best.hops[0].legs[0].amountIn;
        assertLt(committed, ORDER, "setup is void unless the clamp leaves a residual");

        uint256 userABefore = tokenA.balanceOf(user);

        vm.prank(user);
        router.swapBestExactIn(
            address(tokenA), address(tokenB), ORDER, 1, user, block.timestamp + 1
        );

        // 1. The user paid only for what was actually routed. Pre-fix this was
        //    the full ORDER, because the refund went to the Router instead.
        uint256 spent = userABefore - tokenA.balanceOf(user);
        assertApproxEqAbs(spent, committed, 2, "user must spend only the committed input");

        // 2. The Router holds nothing afterwards — the standing invariant, and
        //    the exact thing the stranded residual violated.
        assertEq(tokenA.balanceOf(address(router)), 0, "router must strand no tokenIn");
        assertEq(tokenB.balanceOf(address(router)), 0, "router must strand no tokenOut");

        // 3. The swap still did its job.
        assertGt(tokenB.balanceOf(user), 0, "user must receive the honest partial fill");
    }

    /// The two entry points must agree. A user who routes the same order through
    /// the direct entry and through in-transaction discovery should be out the
    /// same input either way — the property the single-door test could not see.
    function test_BothEntryPoints_ChargeTheSameInput() public {
        _seedThinV3();
        RoutePlan memory plan = solver.findBestRoutePlan(address(tokenA), address(tokenB), ORDER);
        Route memory route = plan.best;

        uint256 before1 = tokenA.balanceOf(user);
        vm.prank(user);
        router.swapExactIn(route, ORDER, 1, user, block.timestamp + 1);
        uint256 spentDirect = before1 - tokenA.balanceOf(user);

        // Re-fund the user and rebuild the pool so the second leg of the
        // comparison meets the same state, not the depleted remains of the first.
        tokenA.mint(user, ORDER);
        _seedThinV3();

        uint256 before2 = tokenA.balanceOf(user);
        vm.prank(user);
        router.swapBestExactIn(
            address(tokenA), address(tokenB), ORDER, 1, user, block.timestamp + 1
        );
        uint256 spentDiscovered = before2 - tokenA.balanceOf(user);

        assertApproxEqRel(
            spentDiscovered, spentDirect, 0.01e18,
            "in-transaction discovery must not cost the user more than the direct entry"
        );
    }
}
