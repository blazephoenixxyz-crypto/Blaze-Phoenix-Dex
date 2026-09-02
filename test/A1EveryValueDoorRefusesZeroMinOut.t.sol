// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  A1 — `userMinOut != 0` is enforced on EVERY entry point that moves value.
//
//  The assumption book (vault note 143) calls A1 the most loaded pillar: half
//  of the fourth-wave verdicts are "bounded by A1". Until this file, its
//  coverage was spread over four files and only ONE door was paired in the
//  mutation guard. One walk, one file, one mutants.py line per door, so a
//  guard that disappears from any door turns exactly one named test red.
//
//  The five doors, by src line at main 19b2f08:
//    1. swapExactIn           -> _checkedSwap        Router:380
//    2. swapExactInWithPermit2                        Router:391
//    3. swapExactInNative                             Router:452
//    4. swapBestExactIn                               Router:489
//    5. selfExecutePrePulled  (self-only, no minOut)  Router:522
//  Door 5 carries no minOut check of its own: its guard is `msg.sender ==
//  address(this)`, which forces every plan through door 4 first. So the
//  A1 claim for door 5 is "a stranger is refused", not "zero minOut is".
//
//  Every refusal is asserted with the EXACT code. Door 4 is asserted with the
//  Solver unwired: if the guard vanished, the call would die in the Solver
//  call with different revert data, and expectRevert(RouterE(10)) still fails.
//  A positive control (door 1 settles with minOut = 1) keeps the fixture
//  from being vacuous.
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixRouter, IPermit2} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";

/// @dev WETH9-shaped mock: deposit() mints the caller's balance 1:1. The same
///      token serves as tokenIn for the ERC20 doors, so one pair covers all five.
contract MockWethA1 is MockERC20 {
    constructor() MockERC20("Wrapped Ether", "WETH") {}
    function deposit() external payable { this.mint(msg.sender, msg.value); }
}

contract A1EveryValueDoorRefusesZeroMinOutTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixRouter router;
    MockWethA1 wethT;
    MockERC20 tokenOut;
    MockV2Pair pair;

    address user = address(0xBEEF);
    uint256 constant AMT = 1e18;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        wethT = new MockWethA1();
        tokenOut = new MockERC20("Out", "OUT");
        pair = new MockV2Pair(address(wethT), address(tokenOut));
        router = new BlazePhoenixRouter(
            address(hub), address(0xBEEF), address(this), address(0xFEE1), address(0xFEE2)
        );
        router.setWeth(address(wethT));

        wethT.mint(address(pair), 10_000e18);
        tokenOut.mint(address(pair), 10_000e18);
        pair.setReserves(10_000e18, 10_000e18);

        wethT.mint(user, 10e18);
        vm.deal(user, 10e18);
        vm.prank(user);
        wethT.approve(address(router), type(uint256).max);
    }

    function _route(uint256 amountIn, uint256 claimedOut) private view returns (Route memory route) {
        Leg[] memory legs = new Leg[](1);
        legs[0] = Leg({
            pool: address(pair), hooks: address(0), kind: BPC.KIND_V2, fee: 30,
            tickSpacing: 0, zeroForOne: address(wethT) < address(tokenOut), stable: false,
            amountIn: amountIn, expectedOut: claimedOut, auxId: bytes32(0)
        });
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({
            tokenIn: address(wethT), tokenOut: address(tokenOut),
            amountIn: amountIn, expectedOut: claimedOut, legs: legs
        });
        route = Route({
            hops: hops, totalOut: claimedOut, singleOut: claimedOut,
            singleOutFloor: 0, expectedImpactBps: 0, confidenceWad: 0,
            estGas: 0, hasSurplus: false, isV4Bundle: false
        });
    }

    function _e(uint16 code) private pure returns (bytes memory) {
        return abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, code);
    }

    // ───────────────────────── positive control ─────────────────────────

    /// The fixture can settle: door 1 with minOut = 1 delivers. Without this,
    /// every refusal below could be the fixture failing for another reason.
    function test_A1_Control_Door1SettlesWithMinOutOne() public {
        uint256 q = BPC.outV2(AMT, 10_000e18, 10_000e18, 30);
        vm.prank(user);
        uint256 got = router.swapExactIn(_route(AMT, q), AMT, 1, user, block.timestamp + 1);
        assertGt(got, 0, "control: the fixture settles");
        assertEq(tokenOut.balanceOf(user), got, "control: output reached the user");
    }

    // ───────────────────────────── the walk ─────────────────────────────

    function test_A1_Door1_SwapExactIn_RefusesZeroMinOut() public {
        vm.prank(user);
        vm.expectRevert(_e(10));
        router.swapExactIn(_route(AMT, 1), AMT, 0, user, block.timestamp + 1);
    }

    function test_A1_Door2_Permit2_RefusesZeroMinOut() public {
        // The guard precedes the permit inspection (Router:391 before :392),
        // so an empty permit and signature never get looked at.
        IPermit2.PermitTransferFrom memory permit;
        vm.prank(user);
        vm.expectRevert(_e(10));
        router.swapExactInWithPermit2(_route(AMT, 1), AMT, 0, user, block.timestamp + 1, permit, "");
    }

    function test_A1_Door3_Native_RefusesZeroMinOut() public {
        // weth is wired and msg.value is non-zero, so RouterE(3) at :449/:451
        // cannot pre-empt: the only refusal left before the wrap is :452.
        vm.prank(user);
        vm.expectRevert(_e(10));
        router.swapExactInNative{value: AMT}(_route(AMT, 1), 0, user, block.timestamp + 1);
    }

    function test_A1_Door4_Best_RefusesZeroMinOut_BeforeTheSolve() public {
        // The Solver is deliberately NOT wired. If the guard at :489 were gone,
        // the call would reach `ISolverR(solver).findBestRoutePlan` on a
        // codeless address and revert with different data; RouterE(10) here
        // therefore proves the refusal PRECEDES the solve.
        vm.prank(user);
        vm.expectRevert(_e(10));
        router.swapBestExactIn(address(wethT), address(tokenOut), AMT, 0, user, block.timestamp + 1);
    }

    function test_A1_Door5_SelfCall_StrangerIsRefused() public {
        // Door 5 has no minOut check: its guard is the self-call gate. A
        // stranger cannot use it to skip door 4's check.
        vm.prank(user);
        vm.expectRevert(_e(1));
        router.selfExecutePrePulled(_route(AMT, 1), AMT, 0, user, block.timestamp + 1, user);
    }
}
