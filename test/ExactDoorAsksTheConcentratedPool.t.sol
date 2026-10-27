// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  3073 [707], the exact door on a capacity-held leg, without a fork.
//  Red against mutant [661] of .github/scripts/mutants.py at 59ecf3f; green on 59ecf3f.
//
//  previewPlanExact re-prices every concentrated leg by dry-running the pool at
//  the leg's input (Quoter._priceLeg -> _simConc); the plan's own claim is only
//  the fallback for a pool that refuses the dry-run. The Base fork matrix pins
//  this (test/fork/FidelityMatrix.t.sol, test_Matriz_DaiEPortaExata), but it
//  skips without DRPC_KEY, so the mutation guard never ran it.
//
//  Here the plan's claim and the pool's answer differ by construction: a V3
//  pool without a tick book (no tickSpacing) whose single-tick quote passes the
//  capacity cap (MAX_CONC_DRAIN_BPS, 30 % of its tokenOut holdings) but not its
//  holdings keeps its whole input and is promised the cap (Solver._capacity, a
//  book that does not answer). The pool pays its single-tick figure. The exact
//  door must report what the pool pays, as delivery measures it.
//
//  forge test --match-path test/ExactDoorAsksTheConcentratedPool.t.sol -vv
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixQuoter} from "../src/BlazePhoenixQuoter.sol";
import {BlazePhoenixCore as BPC, RoutePlan, Route} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV3Pool} from "./mocks/MockV3Pool.sol";

contract ExactDoorAsksTheConcentratedPoolTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    BlazePhoenixRouter router;
    BlazePhoenixQuoter quoter;
    MockV3Pool pool;
    address tIn;
    address tOut;
    address user = address(0xBEEF);

    uint160 constant SP   = uint160(1 << 96);   // price 1
    uint128 constant L    = 1_000e18;
    uint24  constant FEE  = 3_000;
    uint256 constant IN   = 200e18;             // single-tick quote ~166e18
    uint256 constant HELD = 400e18;             // cap 120e18 < quote <= holdings

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        solver = new BlazePhoenixSolver(address(hub), address(0));
        router = new BlazePhoenixRouter(address(hub), address(solver), address(this), address(0xFEE1), address(0xFEE2));
        hub.setRoles(address(router), address(solver), address(0xC0FFEE));
        quoter = new BlazePhoenixQuoter(address(hub), address(solver));
        address a = address(new MockERC20("A", "A"));
        address b = address(new MockERC20("B", "B"));
        (tIn, tOut) = a < b ? (a, b) : (b, a);   // token0 in: zeroForOne
        pool = new MockV3Pool(tIn, tOut, FEE);  // no tickSpacing(): the walk reads no book
        pool.setState(SP, L);
        MockERC20(tOut).mint(address(pool), HELD);
        hub.seedPool(address(pool), BPC.KIND_V3, FEE, address(0), tIn, tOut);
        MockERC20(tIn).mint(user, IN);
        vm.prank(user);
        MockERC20(tIn).approve(address(router), type(uint256).max);
    }

    /// The plan promises the leg its cap; the exact door reports the pool's own dry-run of the
    /// committed input, and the exact scalar is what the Router then delivers for the plan.
    function test_3073_ExactDoor_HeldLeg_IsPricedByThePoolNotByThePlan() public {
        RoutePlan memory plan = solver.findBestRoutePlan(tIn, tOut, IN);
        uint256 cap = BPC.mulDiv(HELD, 3_000, BPC.BPS);
        uint256 single = BPC.outV3(IN, SP, L, FEE, true, 0);   // MockV3Pool.swap's own formula
        assertEq(plan.best.hops.length, 1, "precondition: one hop");
        assertEq(plan.best.hops[0].legs.length, 1, "precondition: one leg");
        assertEq(plan.best.hops[0].legs[0].pool, address(pool), "precondition: the held pool");
        assertEq(plan.best.hops[0].legs[0].amountIn, IN, "precondition: the whole input commits");
        assertEq(plan.best.hops[0].legs[0].expectedOut, cap, "precondition: the plan claims the cap");
        assertGt(single, cap, "precondition: the pool pays past the cap");

        (Route memory ex, uint256 exactOut) = quoter.previewPlanExact(tIn, tOut, IN);
        assertEq(ex.hops[0].legs[0].amountIn, IN, "the exact door prices the committed input");
        assertEq(ex.hops[0].legs[0].expectedOut, single, "the leg is priced by the pool's dry-run, not the plan's claim");

        uint256 b0 = MockERC20(tOut).balanceOf(user);
        vm.prank(user);
        router.swapExactIn(plan.best, IN, 1, user, block.timestamp + 1);
        uint256 delivered = MockERC20(tOut).balanceOf(user) - b0;
        emit log_named_uint("plan claim (cap)", cap);
        emit log_named_uint("exactOut", exactOut);
        emit log_named_uint("delivered", delivered);
        assertLe(exactOut, delivered, "the exact scalar never promises more than delivery");
        // The fee is taken off the scalar's output and off the Router's input (a direct route
        // touching no bridge): on a concave curve the second costs less, a gap under the fee
        // (PROTOCOL_FEE_BPS). The plan's claim sits ~28 % under delivery.
        assertLe(delivered - exactOut, delivered / 1_000, "the exact scalar is delivery (<= 10 bps)");
    }
}
