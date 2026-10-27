// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// `Preview.canExecute` is a promise about the Router: "this route, with these arguments, is not
// one the Router refuses before it moves a token". The encode doors make the promise binding -
// they return EMPTY bytes when they already know the call will not settle. Each test here is an
// entry refusal of the Router the promise did not ask (opencode triage, class
// canexecute-misses-entry-checks), asserted on the preview, with the Router's own refusal of the
// same call as the control that the refusal is real.
//
// OC-06 (dx2/it0005): a route with no hops. `_hookRefusedIn` mirrors the RouterE(3) shape checks
// of `Router._execute` but returned false for zero hops - its loop never ran - while
// `Router._swap` refuses `route.hops.length == 0` with RouterE(3). Red at c516601:
// canExecute == true for a hand-built empty route with a positive totalOut.

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixQuoter} from "../src/BlazePhoenixQuoter.sol";
import {BlazePhoenixCore as BPC, Route} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";
import {Origin} from "./mocks/MockOriginFactory.sol";

contract CanExecuteAsksTheRoutersEntryChecksTest is Test {
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

    /// @notice OC-06: a route with no hops cannot execute, as the Router's RouterE(3) says.
    function test_ARouteWithNoHopsCannotExecute() public {
        Route memory empty;
        empty.totalOut = 1_000e18;
        BlazePhoenixQuoter.Preview memory pv = quoter.previewRoute(empty, 1);
        assertGt(pv.netOut, 0, "premise: the claim alone would clear netOut >= effectiveMinOut");
        assertFalse(pv.canExecute, "a route with no hops is one the Router refuses");
        uint256 deadline = block.timestamp;
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, uint16(3)));
        router.swapExactIn(empty, AMOUNT_IN, 1, user, deadline);
    }
}
