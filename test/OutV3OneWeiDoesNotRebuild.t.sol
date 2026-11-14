// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// End to end, the rebuild's question for the order of test/OutV3IsNotAboveThePoolsSwap.t.sol:
// an honest flat book (price 1, L = 1e24, fee 500, spacing 10, holdings far above the cap) is
// the only venue, and the order ends inside the pool's first step. Its promise is the
// single-range figure (`Core.outV3`, on the walk's own step `Core._nextSqrtFromInput`);
// `Solver._paysWhatItWalks` walks its own book.
//
// With the figure a wei above the pool's swap (the price rounded down, before e5ced25), the
// promise "fell" by that wei: the book was handed back on `fl`, `d = 1`, and the solve ran the
// rebuild without it - a static self-call on WALK_GAS (2.5M), which a solve that cannot hand
// over stops on (empty revert). The plan it returned was the same; the order paid a rebuild
// for a wei of rounding, and was refused below that gas.
//
// Pinned here: the book is promised what its pool pays, to the wei, and the solve completes on a
// gas a rebuild cannot run on.

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixCore as BPC, RoutePlan, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV3BookPool} from "./mocks/MockV3BookPool.sol";

contract OutV3OneWeiDoesNotRebuildTest is Test {
    uint256 constant AIN  = 150905615719094812618;
    uint128 constant L    = 1e24;
    uint24  constant FEE  = 500;
    uint256 constant POOL_PAYS = 150807416604020658248; // exact integers, see OutV3IsNotAboveThePoolsSwap
    // Under WALK_GAS * 64 / 63 + 20,000: a solve that must rebuild cannot run on it.
    uint256 constant SOLVE_GAS = 2_000_000;

    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    address t0;
    address t1;
    MockV3BookPool pool;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        solver = new BlazePhoenixSolver(address(hub), address(0));
        MockERC20 a = new MockERC20("A", "A");
        MockERC20 b = new MockERC20("B", "B");
        (t0, t1) = address(a) < address(b) ? (address(a), address(b)) : (address(b), address(a));
        pool = new MockV3BookPool(address(a), address(b), FEE, 10);
        pool.setState(uint160(BPC.Q96), L);
        MockERC20(t1).mint(address(pool), 1e24);
        hub.seedPool(address(pool), BPC.KIND_V3, FEE, address(0), address(a), address(b));
    }

    function test_AnHonestBookIsPromisedWhatItsPoolPays() public view {
        RoutePlan memory plan = solver.findBestRoutePlan(t0, t1, AIN);
        Leg memory leg = plan.best.hops[0].legs[0];
        assertEq(leg.pool, address(pool), "precondition: the book carries the order");
        assertEq(leg.amountIn, AIN, "precondition: the whole input on the book");
        assertEq(leg.expectedOut, POOL_PAYS, "the book is promised what its pool pays");
        assertEq(plan.best.totalOut, POOL_PAYS, "the route pays what the pool pays");
    }

    function test_AWeiOfRoundingDoesNotBuyARebuild() public {
        uint256 g = gasleft();
        solver.findBestRoutePlan(t0, t1, AIN);
        emit log_named_uint("solve gas", g - gasleft());
        (bool ok, ) = address(solver).staticcall{gas: SOLVE_GAS}(
            abi.encodeCall(BlazePhoenixSolver.findBestRoutePlan, (t0, t1, AIN))
        );
        assertTrue(ok, "an honest book's order needs no rebuild: the solve completes under WALK_GAS");
    }
}
