// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixQuoter} from "../src/BlazePhoenixQuoter.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";

/// @notice THE HOP CEILING IS TWO (owner, 2026-11-06: "Ajusta as topologias a 2 hop"). Core's
///         file-level MAX_HOPS is its one producer: the Router refuses a longer route with
///         RouterE(3), the Quoter previews one as not executable, and the Solver's bridge path is
///         a literal of MAX_HOPS + 1 tokens, so a ceiling it does not build does not compile.
///
///         A ceiling needs both sides. Asserting the refusal alone does not pin the value -
///         `RouterE(3)` is raised at 24 distinct sites in the Router, so the code says only "one
///         of twenty-four things went wrong". The discriminating fact is that the route ONE HOP
///         SHORTER settles: two hops through, three refused, and the pair moves together only if
///         the ceiling does. Each route is asked of the preview too, so a preview that endorses a
///         route the Router refuses, or refuses one it takes, goes red with the Router's answer.
///
///         History: from the review of 2026-09-02 to 2026-11-06 the ceiling was 3 (the Router's
///         own constant, with a literal 3 in the Quoter), pinned here as "three settle, four are
///         refused" (RouteHopCeilingIsThree.t.sol).
contract RouteHopCeilingIsTwoTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixQuoter quoter;
    BlazePhoenixRouter router;
    MockERC20[4] t;                 // t0 -> t1 -> t2 -> t3
    MockV2Pair[3] p;
    address user = address(0xBEEF);
    uint256 constant AMT = 100e18;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        BlazePhoenixSolver solver = new BlazePhoenixSolver(address(hub), address(0));
        quoter = new BlazePhoenixQuoter(address(hub), address(solver));
        router = new BlazePhoenixRouter(
            address(hub), address(solver), address(this), address(0xFEE1), address(0xFEE2));
        for (uint256 i; i < 4; ++i) t[i] = new MockERC20("T", "T");
        for (uint256 i; i < 3; ++i) {
            p[i] = new MockV2Pair(address(t[i]), address(t[i + 1]));
            t[i].mint(address(p[i]), 10_000e18);
            t[i + 1].mint(address(p[i]), 10_000e18);
            p[i].setReserves(10_000e18, 10_000e18);
        }
        t[0].mint(user, 10_000e18);
        vm.prank(user);
        t[0].approve(address(router), type(uint256).max);
    }

    function _route(uint256 hopCount) private view returns (Route memory r) {
        Hop[] memory hops = new Hop[](hopCount);
        for (uint256 h; h < hopCount; ++h) {
            Leg[] memory legs = new Leg[](1);
            legs[0] = Leg({pool: address(p[h]), hooks: address(0), kind: BPC.KIND_V2, fee: 30,
                           tickSpacing: 0, zeroForOne: address(t[h]) < address(t[h + 1]),
                           stable: false, amountIn: AMT, expectedOut: 0,
                           auxId: bytes32(0)});
            // Every hop declares the same nominal figure: the Router rescales each hop by what
            // it MEASURED arriving, so the declaration only has to be non-zero to be spent.
            hops[h] = Hop({tokenIn: address(t[h]), tokenOut: address(t[h + 1]),
                           amountIn: AMT, expectedOut: 0, legs: legs});
        }
        // A positive claim: the preview's netOut needs one; the Router reads none.
        r = Route({hops: hops, totalOut: 1e18, singleOut: 1e18, singleOutFloor: 0,
                   expectedImpactBps: 0, confidenceWad: 0, estGas: 0,
                   hasSurplus: false, isV4Bundle: false});
    }

    /// @notice Two hops is the ceiling, previews as executable and settles. Without this arm the
    ///         refusal below proves nothing: a Router that refused every route would satisfy it.
    function test_TwoHopsIsInsideTheCeilingAndSettles() public {
        Route memory r = _route(2);
        assertTrue(quoter.previewRoute(r, 1).canExecute, "the preview refuses a two-hop route the Router takes");
        vm.prank(user);
        uint256 got = router.swapExactIn(r, AMT, 1, user, block.timestamp + 1);
        assertGt(got, 0, "a two-hop route must settle: it is at the ceiling, not past it");
        assertEq(t[2].balanceOf(user), got, "and it must deliver the second hop's output token");
    }

    /// @notice Three is past it: previewed as not executable, and refused with RouterE(3).
    function test_ThreeHopsIsPastTheCeilingAndRefused() public {
        Route memory r = _route(3);
        assertFalse(quoter.previewRoute(r, 1).canExecute, "the preview endorses a three-hop route the Router refuses");
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, uint16(3)));
        router.swapExactIn(r, AMT, 1, user, block.timestamp + 1);
    }
}
