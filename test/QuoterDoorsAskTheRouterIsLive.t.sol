// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// `Preview.canExecute` is a promise about the Router: "this route is not one the Router refuses
// before it moves a token". `_hookRefusedIn` is the one producer of that answer
// (SHARED_QUANTITIES, `_hookRefusedIn`), and it asked every entry refusal but the first one each
// swap door runs: `whenLive`, RouterE(2), while the Router is paused. During a pause every view
// door said executable, both encode doors handed out bytes the Router refuses, and both exact doors
// returned a positive scalar. Red at 6387350: canExecute == true with the Router paused.
//
// The Quoter knows no Router; the Hub seats it (setRoles) and already asks it for the canonical
// WETH instead of keeping a copy. `Hub.routerLive()` asks it the same way, and the Quoter reads
// that answer tolerantly: no Router seated, a Hub with no code or a Router that does not answer
// reads as "not live" (an absent measurement is not a value) and the preview does not revert.

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixQuoter} from "../src/BlazePhoenixQuoter.sol";
import {BlazePhoenixCore as BPC, Route} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";
import {Origin} from "./mocks/MockOriginFactory.sol";

contract QuoterDoorsAskTheRouterIsLiveTest is Test {
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
        router = _newRouter();
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

    /// @dev `Hub.routerLive()` by its selector, so the file also compiles on the tree without it
    ///      (where the getter is absent and every assertion on it fails).
    function _hubSaysLive() internal view returns (bool) {
        (bool ok, bytes memory r) = address(hub).staticcall(abi.encodeWithSignature("routerLive()"));
        require(ok && r.length == 32, "Hub.routerLive() did not answer");
        return abi.decode(r, (bool));
    }

    function _newRouter() internal returns (BlazePhoenixRouter) {
        return new BlazePhoenixRouter(
            address(hub), address(solver), address(this), address(0x7451), address(0x7452)
        );
    }

    /// @dev What every door answers for the same request: the "executes?" bit of each door.
    struct Doors {
        BlazePhoenixQuoter.Preview plan;
        BlazePhoenixQuoter.Preview planMin;
        BlazePhoenixQuoter.Preview route;
        BlazePhoenixQuoter.Preview batch;
        BlazePhoenixQuoter.Preview enc;
        bytes encCall;
        BlazePhoenixQuoter.Preview encMin;
        bytes encMinCall;
        uint256 planExact;
        uint256 routeExact;
    }

    function _askEveryDoor(uint256 amountIn) internal returns (Doors memory d) {
        (d.plan,,) = quoter.previewPlan(address(tA), address(tB), amountIn);
        (d.planMin,,) = quoter.previewPlanWithMinOut(address(tA), address(tB), amountIn, 1);
        d.route = quoter.previewRoute(d.plan.route, 0);
        BlazePhoenixQuoter.BatchEntry[] memory e = new BlazePhoenixQuoter.BatchEntry[](1);
        e[0] = BlazePhoenixQuoter.BatchEntry({tIn: address(tA), tOut: address(tB), amountIn: amountIn, userMinOut: 0});
        d.batch = quoter.batchQuote(e)[0];
        (d.enc, d.encCall) = quoter.previewAndEncode(address(tA), address(tB), amountIn, user, block.timestamp);
        (d.encMin, d.encMinCall) =
            quoter.previewAndEncodeWithMinOut(address(tA), address(tB), amountIn, 1, user, block.timestamp);
        (, d.planExact) = quoter.previewPlanExact(address(tA), address(tB), amountIn);
        (, d.routeExact) = quoter.previewRouteExact(d.plan.route, amountIn);
    }

    function _assertNoDoorExecutes(Doors memory d) internal pure {
        assertFalse(d.plan.canExecute, "previewPlan");
        assertFalse(d.planMin.canExecute, "previewPlanWithMinOut");
        assertFalse(d.route.canExecute, "previewRoute");
        assertFalse(d.batch.canExecute, "batchQuote");
        assertFalse(d.enc.canExecute, "previewAndEncode");
        assertEq(d.encCall.length, 0, "previewAndEncode bytes");
        assertFalse(d.encMin.canExecute, "previewAndEncodeWithMinOut");
        assertEq(d.encMinCall.length, 0, "previewAndEncodeWithMinOut bytes");
        assertEq(d.planExact, 0, "previewPlanExact");
        assertEq(d.routeExact, 0, "previewRouteExact");
    }

    function _assertEveryDoorExecutes(Doors memory d) internal pure {
        assertTrue(d.plan.canExecute, "previewPlan");
        assertTrue(d.planMin.canExecute, "previewPlanWithMinOut");
        assertTrue(d.route.canExecute, "previewRoute");
        assertTrue(d.batch.canExecute, "batchQuote");
        assertTrue(d.enc.canExecute, "previewAndEncode");
        assertGt(d.encCall.length, 0, "previewAndEncode bytes");
        assertTrue(d.encMin.canExecute, "previewAndEncodeWithMinOut");
        assertGt(d.encMinCall.length, 0, "previewAndEncodeWithMinOut bytes");
        assertGt(d.planExact, 0, "previewPlanExact");
        assertGt(d.routeExact, 0, "previewRouteExact");
    }

    /// @notice With the Router paused no door says executable, and the oracle is the Router: the
    ///         bytes the encode door handed out before the pause revert with RouterE(2).
    function test_PausedRouter_NoDoorSaysExecutable() public {
        Doors memory live = _askEveryDoor(AMOUNT_IN);
        _assertEveryDoorExecutes(live);
        router.setPaused(true);
        _assertNoDoorExecutes(_askEveryDoor(AMOUNT_IN));
        Route memory route = live.enc.route;
        uint256 minOut = live.enc.effectiveMinOut;
        uint256 deadline = block.timestamp;
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, uint16(2)));
        router.swapExactIn(route, AMOUNT_IN, minOut, user, deadline);
    }

    /// @notice Control: the pause moves only the "executes?" answer. Unpaused again, every door
    ///         answers to the wei what it answered before, and the bytes settle.
    function test_Unpause_RestoresTheSameAnswers() public {
        Doors memory before = _askEveryDoor(AMOUNT_IN);
        router.setPaused(true);
        router.setPaused(false);
        Doors memory again = _askEveryDoor(AMOUNT_IN);
        _assertEveryDoorExecutes(again);
        assertEq(keccak256(abi.encode(again.plan)), keccak256(abi.encode(before.plan)), "same preview");
        assertEq(keccak256(again.encCall), keccak256(before.encCall), "same bytes");
        assertEq(again.planExact, before.planExact, "same exact scalar");
        vm.prank(user);
        (bool ok,) = address(router).call(again.encCall);
        assertTrue(ok, "the bytes settle once the Router is live");
    }

    /// @notice The pause changes no number: netOut, the floors and the route are the live ones.
    function test_PausedPreview_KeepsItsNumbers() public {
        (BlazePhoenixQuoter.Preview memory live,,) = quoter.previewPlan(address(tA), address(tB), AMOUNT_IN);
        router.setPaused(true);
        (BlazePhoenixQuoter.Preview memory paused,,) = quoter.previewPlan(address(tA), address(tB), AMOUNT_IN);
        assertFalse(paused.canExecute, "premise: paused");
        assertEq(paused.netOut, live.netOut, "netOut");
        assertEq(paused.effectiveMinOut, live.effectiveMinOut, "effectiveMinOut");
        assertEq(paused.ironFloor, live.ironFloor, "ironFloor");
        assertEq(keccak256(abi.encode(paused.route)), keccak256(abi.encode(live.route)), "route");
    }

    /// @notice The Hub's answer follows the Router's flag, and is false with no Router seated.
    function test_routerLive_FollowsTheRoutersFlag() public {
        assertTrue(_hubSaysLive(), "seated and live");
        router.setPaused(true);
        assertFalse(_hubSaysLive(), "seated and paused");
        router.setPaused(false);
        assertTrue(_hubSaysLive(), "live again");
    }

    /// @notice No Router seated: absent is not live, and the preview does not revert.
    function test_HubWithNoRouterSeated_NotExecutable() public {
        (BlazePhoenixQuoter.Preview memory live,,) = quoter.previewPlan(address(tA), address(tB), AMOUNT_IN);
        assertTrue(live.canExecute, "premise: executable with the Router seated");
        hub.setRoles(address(0), address(solver), address(quoter));
        assertFalse(_hubSaysLive(), "no Router seated reads as not live");
        BlazePhoenixQuoter.Preview memory pv = quoter.previewRoute(live.route, 0);
        assertFalse(pv.canExecute, "no Router seated: nothing executes");
        assertEq(pv.netOut, live.netOut, "the number is still the quote");
    }

    /// @notice A seated Router that does not answer `paused()` (here a token): the Hub's own read
    ///         reverts, the Quoter's read is tolerant and says not executable without reverting.
    function test_RouterThatDoesNotAnswer_NotExecutable_AndThePreviewDoesNotRevert() public {
        (BlazePhoenixQuoter.Preview memory live,,) = quoter.previewPlan(address(tA), address(tB), AMOUNT_IN);
        hub.setRoles(address(tA), address(solver), address(quoter));
        BlazePhoenixQuoter.Preview memory pv = quoter.previewRoute(live.route, 0);
        assertFalse(pv.canExecute, "a Router that does not answer is not live");
        assertEq(pv.netOut, live.netOut, "the number is still the quote");
    }

    /// @notice A Quoter over a Hub with no code: the call "succeeds" with no return data, which
    ///         is an absent answer, not a live Router. The preview does not revert.
    function test_HubWithNoCode_NotExecutable_AndThePreviewDoesNotRevert() public {
        (BlazePhoenixQuoter.Preview memory live,,) = quoter.previewPlan(address(tA), address(tB), AMOUNT_IN);
        assertTrue(live.canExecute, "premise: the same route executes over the real Hub");
        BlazePhoenixQuoter bare = new BlazePhoenixQuoter(address(0x1111), address(solver));
        BlazePhoenixQuoter.Preview memory pv = bare.previewRoute(live.route, 0);
        assertFalse(pv.canExecute, "no code at the Hub: not executable");
        assertEq(pv.netOut, live.netOut, "the number is still the quote");
    }

    /// @notice The door follows the Router the Hub seats: a pause of the replaced Router closes
    ///         nothing, a pause of the seated one closes every door.
    function test_RouterSwappedBySetRoles_TheDoorFollowsTheSeatedRouter() public {
        BlazePhoenixRouter fresh = _newRouter();
        hub.setRoles(address(fresh), address(solver), address(quoter));
        router.setPaused(true);
        (BlazePhoenixQuoter.Preview memory pv,,) = quoter.previewPlan(address(tA), address(tB), AMOUNT_IN);
        assertTrue(pv.canExecute, "the replaced Router's pause does not close the door");
        fresh.setPaused(true);
        (pv,,) = quoter.previewPlan(address(tA), address(tB), AMOUNT_IN);
        assertFalse(pv.canExecute, "the seated Router's pause closes it");
    }

    /// @notice Over sizes from 1 wei to 1e30: a paused Router means no door executes, and the
    ///         Router itself refuses with RouterE(2).
    function testFuzz_CanExecuteImpliesTheRouterIsLive(bool paused, uint256 amountIn) public {
        amountIn = bound(amountIn, 1, 1e30);
        router.setPaused(paused);
        BlazePhoenixQuoter.Preview memory pv;
        // A size the Solver finds no route for promises nothing: there is no door to ask.
        try quoter.previewPlan(address(tA), address(tB), amountIn) returns (
            BlazePhoenixQuoter.Preview memory p, Route memory, bool
        ) { pv = p; } catch { return; }
        (, uint256 exactOut) = quoter.previewRouteExact(pv.route, amountIn);
        if (!paused) return;
        assertFalse(pv.canExecute, "paused: not executable");
        assertEq(exactOut, 0, "paused: no exact scalar");
        Route memory route = pv.route;
        uint256 deadline = block.timestamp;
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, uint16(2)));
        router.swapExactIn(route, amountIn, 0, user, deadline);
    }
}
