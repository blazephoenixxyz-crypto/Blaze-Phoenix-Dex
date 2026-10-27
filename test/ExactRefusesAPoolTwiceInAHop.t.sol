// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// OC-07 (dx2/it0008): two legs of one hop on the same pool. The exact doors price every leg
// against the pool's state before the swap (`Quoter._exact`); the Router runs the legs in turn,
// and the second meets the pool the first moved. On a V2 pair with a fee a split in sequence
// pays less than the legs priced side by side, so the exact scalar promised more than the
// Router delivers, and a userMinOut taken from it was refused. The Solver never plans a pool
// twice in a hop (it merges a pool's legs); a route built off-chain can, and
// `previewRouteExact` is the door for such routes. Red at c516601: exactOut > delivered.

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixQuoter} from "../src/BlazePhoenixQuoter.sol";
import {BlazePhoenixCore as BPC, Route, RoutePlan, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";
import {Origin} from "./mocks/MockOriginFactory.sol";

contract ExactRefusesAPoolTwiceInAHopTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    BlazePhoenixQuoter quoter;
    BlazePhoenixRouter router;
    MockERC20 tA;
    MockERC20 tB;
    MockV2Pair ab;

    address user = address(0x5E4);
    uint256 constant AMOUNT_IN = 1_000e18;
    uint112 constant RESERVE = 1_000_000e18;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0xBEEF));
        solver = new BlazePhoenixSolver(address(hub), address(0));
        quoter = new BlazePhoenixQuoter(address(hub), address(solver));
        router = new BlazePhoenixRouter(
            address(hub), address(solver), address(this), address(0x7451), address(0x7452)
        );
        tA = new MockERC20("A", "A");
        tB = new MockERC20("B", "B");
        ab = new MockV2Pair(address(tA), address(tB));
        Origin.wire(hub, address(ab), address(tA), address(tB), BPC.KIND_V2, 30);
        tA.mint(address(ab), RESERVE);
        tB.mint(address(ab), RESERVE);
        ab.setReserves(RESERVE, RESERVE);
        hub.setRoles(address(this), address(solver), address(quoter));
        for (uint256 i; i < 5; i++) {
            hub.recordSwap(address(ab), BPC.KIND_V2, 30, address(0),
                address(tA), address(tB), 1e18, 1e18, RESERVE);
        }
        hub.setRoles(address(router), address(solver), address(quoter));
        hub.addBridge(address(tB));
        tA.mint(user, 10_000e18);
        vm.prank(user);
        tA.approve(address(router), type(uint256).max);
    }

    /// @dev The Solver's one-leg route, its leg split in two halves on the same pair.
    function _twoLegsOnOnePool() private view returns (Route memory route) {
        RoutePlan memory plan = solver.findBestRoutePlan(address(tA), address(tB), AMOUNT_IN);
        route = plan.best;
        assertEq(route.hops.length, 1, "premise: a direct route");
        assertEq(route.hops[0].legs.length, 1, "premise: one leg");
        Leg memory l = route.hops[0].legs[0];
        assertEq(l.pool, address(ab), "premise: the leg is the pair");
        Leg[] memory legs = new Leg[](2);
        legs[0] = Leg(l.pool, l.hooks, l.kind, l.fee, l.tickSpacing, l.zeroForOne, l.stable,
            l.amountIn / 2, l.expectedOut / 2, l.auxId);
        legs[1] = Leg(l.pool, l.hooks, l.kind, l.fee, l.tickSpacing, l.zeroForOne, l.stable,
            l.amountIn - l.amountIn / 2, l.expectedOut - l.expectedOut / 2, l.auxId);
        route.hops[0].legs = legs;
    }

    /// @notice OC-07: the exact scalar of a route with a pool twice in a hop is never more than
    ///         the Router delivers for it in the same block.
    function test_APoolTwiceInAHopIsNeverPromisedMoreThanDelivery() public {
        Route memory route = _twoLegsOnOnePool();
        (, uint256 exactOut) = quoter.previewRouteExact(route, AMOUNT_IN);
        uint256 before = tB.balanceOf(user);
        uint256 deadline = block.timestamp;
        vm.prank(user);
        router.swapExactIn(route, AMOUNT_IN, 1, user, deadline);
        uint256 delivered = tB.balanceOf(user) - before;
        assertGt(delivered, 0, "control: the Router fills a pool twice in a hop, leg after leg");
        assertLe(exactOut, delivered, "exactOut is a floor the Router honours in this block");
    }
}
