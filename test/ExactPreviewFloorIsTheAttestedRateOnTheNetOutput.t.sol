// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  The exact preview carries the floor rate the Solver attests, in the frame it was attested in
//
//  Red at e70ab1f (fin2-router, 4007: the Solver attests `singleOutFloor` on the output net of
//  the input fees): `Quoter._exact` on a route of two hops or more takes the fee out of `carry`
//  at the hop the Router charges (#44), so its exact output is in the net frame too, and then
//  rescaled the attested floor by `gross / route.totalOut`, the GROSS plan figure. Net over
//  gross, twice: the floor a `previewRouteExact` or `previewPlanExact` route carried into the
//  Router sat 28 bps below the rate the Solver attests and the Router enforces. Before 4007 the
//  one deduction was on the Solver's side and the rescale was exact.
//
//  The property: the floor rate of the exact preview is the floor rate the Solver attested, read
//  in the frame each figure lives in. Two hops or more: `singleOutFloor / exactOut` against the
//  attested floor over the plan's output net of the charging hop's fee, `ceil(base * 28 / 10000)`
//  on the bridge hop's input, done here. One hop: the walk takes no fee, so the previewed floor
//  over the walk's gross output against the attested floor over the plan's gross output, whether
//  the fee comes off the output (into a bridge) or off the input (no bridge). Across amounts, at
//  the plan's own and below it.
//
//  The oracle is integer arithmetic on the Solver's plan done here, never the Quoter's own
//  figures; the bound on the two 1e18-scale rates is the one wei the floor's rounding down
//  can take, `1e18 / exactOut`, plus the truncation of the two divisions. The regression is
//  2.5e15 on that scale.
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixQuoter} from "../src/BlazePhoenixQuoter.sol";
import {BlazePhoenixCore as BPC, Hop, Route, RoutePlan} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";

contract ExactPreviewFloorIsTheAttestedRateOnTheNetOutputTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    BlazePhoenixRouter router;
    BlazePhoenixQuoter quoter;
    MockERC20 tokenA;
    MockERC20 tokenB;
    MockERC20 tokenC;

    uint256 constant ONE = 1e18;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        solver = new BlazePhoenixSolver(address(hub), address(0));
        router = new BlazePhoenixRouter(address(hub), address(solver), address(this), address(0xFEE1), address(0xFEE2));
        quoter = new BlazePhoenixQuoter(address(hub), address(solver));
        hub.setRoles(address(router), address(solver), address(this));
        tokenA = new MockERC20("A", "A");
        tokenB = new MockERC20("B", "B");
        tokenC = new MockERC20("C", "C");
        hub.addBridge(address(tokenB)); // A -> B -> C pays on hop 1's input; A -> B on its output
        _pool(tokenA, tokenB, 1_000_000e18);
        _pool(tokenA, tokenB, 10_000e18);
        _pool(tokenB, tokenC, 1_000_000e18);
        _pool(tokenB, tokenC, 10_000e18);
    }

    function _pool(MockERC20 t0, MockERC20 t1, uint256 r) private {
        MockV2Pair p = new MockV2Pair(address(t0), address(t1));
        t0.mint(address(p), r);
        t1.mint(address(p), r);
        p.setReserves(uint112(r), uint112(r));
        hub.seedPool(address(p), BPC.KIND_V2, 30, address(0), address(t0), address(t1));
    }

    /// @dev `floor * 1e18 / base`.
    function _rate(uint256 floorOut, uint256 base) private pure returns (uint256) {
        return BPC.mulDiv(floorOut, ONE, base);
    }

    /// @dev The two-hop plan's output net of the fee the Router charges on hop 1, the bridge hop:
    ///      `ceil(b * 28 / 10000)` off `b = hops[1].amountIn`, the output scaled by what is left.
    function _netOut(Route memory plan) private pure returns (uint256) {
        uint256 b = plan.hops[1].amountIn;
        uint256 f = (b * BPC.PROTOCOL_FEE_BPS + BPC.BPS - 1) / BPC.BPS;
        return plan.totalOut * (b - f) / b;
    }

    function _twoHopPlan(uint256 amt) private view returns (Route memory best) {
        RoutePlan memory plan = solver.findBestRoutePlan(address(tokenA), address(tokenC), amt);
        best = plan.best;
        assertEq(best.hops.length, 2, "premise: the route crosses the bridge");
        assertEq(best.hops[1].tokenIn, address(tokenB), "premise: hop 1 takes the bridge in");
        assertGt(best.singleOutFloor, 0, "premise: the Solver attested a floor");
    }

    /// @dev The previewed floor rate over `exactOut` equals the attested floor rate over `base`,
    ///      within the wei the rescale's rounding down can take on the exact output.
    function _assertRate(Route memory r, uint256 exactOut, Route memory plan, uint256 base, string memory where) private {
        assertGt(exactOut, 0, "premise: the preview walks");
        assertGt(r.singleOutFloor, 0, "premise: the preview carries a floor");
        assertApproxEqAbs(_rate(r.singleOutFloor, exactOut), _rate(plan.singleOutFloor, base), ONE / exactOut + 2, where);
    }

    /// Two hops, the fee on hop 1's bridge input: the exact preview's floor over its exact
    /// output is the attested floor over the plan's net output, through both exact doors.
    function test_TwoHops_TheExactPreviewFloorRateIsTheAttestedRateOnTheNetOutput() public {
        uint256 amt = 50_000e18;
        Route memory plan = _twoHopPlan(amt);
        (Route memory r, uint256 exactOut) = quoter.previewRouteExact(plan, amt);
        _assertRate(r, exactOut, plan, _netOut(plan),
            "two hops: previewRouteExact's floor rate is not the attested rate on the net output");
        (Route memory p, uint256 plannedOut) = quoter.previewPlanExact(address(tokenA), address(tokenC), amt);
        _assertRate(p, plannedOut, plan, _netOut(plan),
            "two hops: previewPlanExact's floor rate is not the attested rate on the net output");
    }

    /// The same across amounts, at the plan's own amount and at half of it (the walk rescales
    /// every hop; the rate it carries is the plan's).
    function testFuzz_TwoHops_TheExactPreviewFloorRateIsTheAttestedRateOnTheNetOutput(uint256 amt) public {
        amt = bound(amt, 1e18, 100_000e18);
        Route memory plan = _twoHopPlan(amt);
        (Route memory r, uint256 exactOut) = quoter.previewRouteExact(plan, amt);
        _assertRate(r, exactOut, plan, _netOut(plan), "two hops, the plan's amount");
        (r, exactOut) = quoter.previewRouteExact(plan, amt / 2);
        _assertRate(r, exactOut, plan, _netOut(plan), "two hops, half the plan's amount");
    }

    /// The producer both callers read: the net figure rounds DOWN, before the floor rounds up
    /// (a floor one unit above what the net input delivers is a floor the route cannot meet);
    /// a hop that pays nothing leaves the figure alone, a hop the fee swallows nets to zero.
    function test_Producer_TheNetOutputRoundsDown_BeforeTheFloorRoundsUp() public pure {
        Hop[] memory hops = new Hop[](2);
        hops[0].amountIn = 1000; // pays nothing: hop 1 is the charging hop
        hops[1].amountIn = 3;    // fee ceil(3 * 28 / 10000) = 1, what is left 2 of 3
        assertEq(BPC.netOfInputFees(hops, 7, 1, false), 4, "7 * 2 / 3 rounds down to 4, not up to 5");
        assertEq(BPC.netOfInputFees(hops, 9, 1, false), 6, "an exact share is itself");
        assertEq(BPC.netOfInputFees(hops, 7, 1, true), 7, "the fee on the output: no hop nets");
        hops[1].amountIn = 1;    // the fee swallows the hop's input
        assertEq(BPC.netOfInputFees(hops, 7, 1, false), 0, "a hop the fee swallows nets to zero");
        hops[1].amountIn = 3;
        assertEq(BPC.netOfInputFees(hops, 7, type(uint256).max, false), 4,
            "no bridge: every hop charges, 7 * 997 / 1000 rounds down to 6, then 6 * 2 / 3 to 4");
    }

    /// Control: one hop into the bridge, the fee off the output after the comparison; the
    /// attested floor is on the gross output, the walk takes no fee, and the previewed floor
    /// over the walk's gross output is the attested rate.
    function test_OneHop_IntoABridge_TheExactPreviewFloorRateIsTheAttestedRateOnTheGrossOutput() public {
        uint256 amt = 50_000e18;
        RoutePlan memory plan = solver.findBestRoutePlan(address(tokenA), address(tokenB), amt);
        assertEq(plan.best.hops.length, 1, "premise: a direct route");
        (Route memory r, uint256 exactOut) = quoter.previewRouteExact(plan.best, amt);
        assertGt(exactOut, 0, "premise: the preview walks");
        _assertRate(r, r.totalOut, plan.best, plan.best.totalOut,
            "one hop into a bridge: the previewed floor rate is not the attested rate on the gross output");
    }

    /// Control: one hop with no bridge, the fee on the input; the Solver attests on the output
    /// net of it, the walk of one hop takes no fee and the rescale keeps the gross plan figure
    /// as its divisor, so the previewed floor over the walk's gross output is the attested floor
    /// over the plan's gross output.
    function test_OneHop_FeeOnTheInput_TheExactPreviewFloorRateIsTheAttestedRateOnTheGrossOutput() public {
        hub.removeBridge(0);
        uint256 amt = 50_000e18;
        RoutePlan memory plan = solver.findBestRoutePlan(address(tokenA), address(tokenB), amt);
        assertEq(plan.best.hops.length, 1, "premise: a direct route");
        (Route memory r, uint256 exactOut) = quoter.previewRouteExact(plan.best, amt);
        assertGt(exactOut, 0, "premise: the preview walks");
        _assertRate(r, r.totalOut, plan.best, plan.best.totalOut,
            "one hop with the fee on the input: the previewed floor rate is not the attested rate on the gross output");
    }
}
