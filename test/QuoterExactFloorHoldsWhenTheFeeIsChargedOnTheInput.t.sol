// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// PROPERTY: `previewPlanExact`'s `exactOut` is a floor the Router honours in BOTH fee regimes.
// Its docstring says to derive userMinOut from it, so a swap of the returned route with
// `minOut = exactOut` must settle and deliver at least `exactOut`.
//
// The Router takes the protocol fee off the OUTPUT only on a direct route into a bridge; on
// every other route it takes it off an INPUT (rounded up) and the venue prices what is left.
// A venue's output is an integer step function of its input, so deducting the fee from the
// gross output is not a floor there: the wei removed by the round-up, plus the sqrt-price
// quantum, can leave delivery a few wei under the deduction.
//
// RED at 982c1de: with no bridge registered and a 1e30-liquidity V3 pool, amountIn 12748
// previews exactOut 12699 and the Router delivers 12697, so `minOut = exactOut` reverts.
// The fuzz finds the same gap across small amounts. GREEN once `previewPlanExact` returns
// the lower of the output deduction and the Router's own input-charged funding of the route.
// CONTROL: with the output token registered as a bridge (fee off the output) the scalar is
// the plain deduction, unchanged, and delivery equals it.

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixQuoter} from "../src/BlazePhoenixQuoter.sol";
import {BlazePhoenixCore as BPC, Route} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV3Pool} from "./mocks/MockV3Pool.sol";

contract QuoterExactFloorHoldsWhenTheFeeIsChargedOnTheInputTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    BlazePhoenixRouter router;
    BlazePhoenixQuoter quoter;
    MockERC20 tokenA;
    MockERC20 tokenB;
    MockV3Pool pool;
    address recipient = makeAddr("recipient");

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        tokenA = new MockERC20("A", "A");
        tokenB = new MockERC20("B", "B");
        solver = new BlazePhoenixSolver(address(hub));
        router = new BlazePhoenixRouter(address(hub), address(solver), address(this), makeAddr("t1"), makeAddr("t2"));
        quoter = new BlazePhoenixQuoter(address(hub), address(solver));
        pool = new MockV3Pool(address(tokenA), address(tokenB), 100);
        pool.setState(uint160(BPC.Q96), 1e30);
        tokenB.mint(address(pool), 1e30);
        hub.seedPool(address(pool), BPC.KIND_V3, 100, address(0), address(tokenA), address(tokenB));
    }

    /// Swap the previewed route with `minOut = exactOut`; returns what was delivered.
    function _settleAtExact(uint256 amountIn) internal returns (uint256 exactOut, uint256 out) {
        Route memory route;
        (route, exactOut) = quoter.previewPlanExact(address(tokenA), address(tokenB), amountIn);
        tokenA.mint(address(this), amountIn);
        tokenA.approve(address(router), amountIn);
        out = router.swapExactIn(route, amountIn, exactOut, recipient, block.timestamp + 1);
    }

    function test_InputChargedRouteSettlesAtExactOut() public {
        (uint256 exactOut, uint256 out) = _settleAtExact(12748);
        assertEq(exactOut, 12697, "exactOut is what the Router delivers on this route");
        assertEq(out, exactOut, "delivered == exactOut");
    }

    function testFuzz_InputChargedRouteNeverDeliversBelowExactOut(uint256 amountIn) public {
        amountIn = bound(amountIn, 1000, 1e16);
        (uint256 exactOut, uint256 out) = _settleAtExact(amountIn);
        assertGe(out, exactOut, "delivered >= exactOut");
    }

    function test_Control_OutputChargedRouteKeepsThePlainDeduction() public {
        hub.addBridge(address(tokenB));
        Route memory route;
        uint256 exactOut;
        (route, exactOut) = quoter.previewPlanExact(address(tokenA), address(tokenB), 12748);
        uint256 gross = route.totalOut;
        assertEq(exactOut, gross - BPC.mulDivUp(gross, BPC.PROTOCOL_FEE_BPS, BPC.BPS), "plain deduction");
        tokenA.mint(address(this), 12748);
        tokenA.approve(address(router), 12748);
        uint256 out = router.swapExactIn(route, 12748, exactOut, recipient, block.timestamp + 1);
        assertEq(out, exactOut, "fee off the output: delivered == deduction");
    }
}
