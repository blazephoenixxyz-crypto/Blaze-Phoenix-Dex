// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  The fee is charged once, at the calendar's hop, and the bridge is conserved across it.
//
//  `Core.feeCalendar` (BlazePhoenixCore.sol:433) names the hop that pays: the first hop whose
//  INPUT is a registered bridge. The Router asks it (Router:1122) and charges `_chargeHopFee`
//  only where `paysOnInput` says so (Router:1238). With no bridge on any input every hop pays
//  (immunity by exhaustion): that is the design, pinned here as a control, not a finding.
//
//  Route A -> B -> C with B a bridge: the calendar answers (1, false), so the fee is paid in B
//  on what hop 0 delivered, and in no other token. Measured on balances and on the Router's
//  `Fee` events, never on the Router's own figures:
//    - exactly one `Fee` event, in B, of mulDivUp(deliveredB, 28, 10_000) where deliveredB is
//      what the hop-0 pair paid out;
//    - the treasuries hold no A and no C more than before;
//    - B is conserved at the hop: deliveredB == fee + what the hop-1 pair took in
//      + what stayed in the Router + what went back to the user.
//  The B pool is shallow so hop 1's input runs from a few wei (the fee's round-up is a large
//  part of it) to millions of wei.
//
//  Red under (registered in .github/scripts/mutants.py, block `# 124-L2`): the Router charges
//  hop 0 instead of the calendar's hop (Router:1238).
// =============================================================================

import {Test, Vm} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Hop, Leg, RoutePlan} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";

/// `feeCalendar` reads its route from calldata: this door hands it one.
contract FeeCalendarDoor {
    function calendar(address hub, Hop[] calldata hops, address tokenOut) external view returns (uint256, bool) {
        return BPC.feeCalendar(hub, hops, tokenOut);
    }
}

contract ConservationAtTheHopTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    BlazePhoenixRouter router;
    FeeCalendarDoor door;
    MockERC20 tokenA;
    MockERC20 tokenB; // the bridge
    MockERC20 tokenC;
    MockV2Pair pAB;
    MockV2Pair pBC;
    address user = address(0xBEEF);
    address constant T1 = address(0xFEE1);
    address constant T2 = address(0xFEE2);

    bytes32 constant FEE = keccak256("Fee(address,uint256,uint256,uint256)");

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        solver = new BlazePhoenixSolver(address(hub), address(0));
        router = new BlazePhoenixRouter(address(hub), address(solver), address(this), T1, T2);
        hub.setRoles(address(router), address(solver), address(this));
        door = new FeeCalendarDoor();
        tokenA = new MockERC20("A", "A");
        tokenB = new MockERC20("B", "B");
        tokenC = new MockERC20("C", "C");
        hub.addBridge(address(tokenB));
        // Odd reserves; B is scarce, so 1e18 A buys ~1e3 wei of B and hop 1 runs on dust to millions.
        pAB = _pool(tokenA, tokenB, 1_000_003e18 + 17, 1_000_000_007);
        pBC = _pool(tokenB, tokenC, 1_000_000_009, 999_989e18 + 3);
        tokenA.mint(user, 1e30);
        vm.prank(user);
        tokenA.approve(address(router), type(uint256).max);
    }

    function _pool(MockERC20 x, MockERC20 y, uint256 rx, uint256 ry) private returns (MockV2Pair p) {
        p = new MockV2Pair(address(x), address(y));
        x.mint(address(p), rx);
        y.mint(address(p), ry);
        (uint256 r0, uint256 r1) = p.token0() == address(x) ? (rx, ry) : (ry, rx);
        p.setReserves(uint112(r0), uint112(r1));
        hub.seedPool(address(p), BPC.KIND_V2, 30, address(0), address(x), address(y));
    }

    struct Bal { uint256 abB; uint256 bcB; uint256 routerB; uint256 userB; uint256 tB; uint256 tA; uint256 tC; }

    function _bal() private view returns (Bal memory b) {
        b.abB = tokenB.balanceOf(address(pAB));
        b.bcB = tokenB.balanceOf(address(pBC));
        b.routerB = tokenB.balanceOf(address(router));
        b.userB = tokenB.balanceOf(user);
        b.tB = tokenB.balanceOf(T1) + tokenB.balanceOf(T2);
        b.tA = tokenA.balanceOf(T1) + tokenA.balanceOf(T2);
        b.tC = tokenC.balanceOf(T1) + tokenC.balanceOf(T2);
    }

    /// Plans A -> B -> C at `amt`, swaps it, and checks the hop. Returns hop 1's base (deliveredB).
    function _swapAndMeasure(uint256 amt) private returns (uint256 deliveredB) {
        RoutePlan memory plan = solver.findBestRoutePlan(address(tokenA), address(tokenC), amt);
        assertEq(plan.best.hops.length, 2, "premise: A -> B -> C");
        assertEq(plan.best.hops[1].tokenIn, address(tokenB), "premise: hop 1 spends the bridge");
        (uint256 feeHop, bool feeOnOut) = door.calendar(address(hub), plan.best.hops, address(tokenC));
        assertEq(feeHop, 1, "the calendar names hop 1, the first whose input is a bridge");
        assertFalse(feeOnOut, "two hops never pay on the output");

        Bal memory b0 = _bal();
        vm.recordLogs();
        vm.prank(user);
        router.swapExactIn(plan.best, amt, 1, user, block.timestamp + 1);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        Bal memory b1 = _bal();

        uint256 fees;
        uint256 fee;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(router) || logs[i].topics[0] != FEE) continue;
            ++fees;
            assertEq(address(uint160(uint256(logs[i].topics[1]))), address(tokenB), "the fee is paid in the bridge");
            (fee, , ) = abi.decode(logs[i].data, (uint256, uint256, uint256));
        }
        assertEq(fees, 1, "the fee is charged once");

        deliveredB = b0.abB - b1.abB;
        assertGt(deliveredB, 0, "premise: hop 0 delivered");
        assertEq(fee, BPC.mulDivUp(deliveredB, 28, 10_000), "fee == ceil(28 bps of what hop 0 delivered)");
        assertEq(b1.tB - b0.tB, fee, "the treasuries received the fee in B");
        assertEq(b1.tA, b0.tA, "no fee in the input token");
        assertEq(b1.tC, b0.tC, "no fee in the output token");
        assertEq(
            deliveredB,
            fee + (b1.bcB - b0.bcB) + (b1.routerB - b0.routerB) + (b1.userB - b0.userB),
            "B is conserved at the hop: delivered == fee + hop-1 input + left in the Router + refunded"
        );
    }

    /// Fixed amounts: hop 1 on ~5 wei of B (fee 1 wei is 20% of it), on 357/358-wei bases
    /// around the fee's first step, and on millions of wei.
    function test_TheFeeIsChargedOnceAtTheCalendarHop() public {
        _swapAndMeasure(5e15 + 3);
        _swapAndMeasure(358e15 + 1);
        _swapAndMeasure(1e18 + 7);
        _swapAndMeasure(12_345e18 + 1);
        _swapAndMeasure(300_000e18 + 13);
    }

    /// Blind amounts, edges of the range included.
    function testFuzz_TheFeeIsChargedOnceAtTheCalendarHop(uint256 seed) public {
        uint256 e = seed % 16;
        uint256 amt;
        if (e == 0) amt = 5e15;
        else if (e == 1) amt = 3e23;
        else amt = bound(seed, 5e15, 3e23);
        _swapAndMeasure(amt);
    }

    /// Control (the design, not a finding): with no bridge on any input the calendar names no
    /// hop and every hop pays on its own input; a direct route into a bridge pays on its output
    /// and on no input; a bridge on hop 0's input makes hop 0 the only payer.
    function test_Control_TheCalendarShapes() public {
        MockERC20 tokenD = new MockERC20("D", "D");
        Hop[] memory two = new Hop[](2);
        two[0].tokenIn = address(tokenA); two[0].tokenOut = address(tokenC);
        two[1].tokenIn = address(tokenC); two[1].tokenOut = address(tokenD);
        (uint256 feeHop, bool feeOnOut) = door.calendar(address(hub), two, address(tokenD));
        assertEq(feeHop, type(uint256).max, "no bridge: no anchored hop");
        assertFalse(feeOnOut);
        assertTrue(BPC.paysOnInput(0, feeHop, feeOnOut) && BPC.paysOnInput(1, feeHop, feeOnOut),
            "no bridge: every hop pays on its input");

        Hop[] memory one = new Hop[](1);
        one[0].tokenIn = address(tokenA); one[0].tokenOut = address(tokenB);
        (feeHop, feeOnOut) = door.calendar(address(hub), one, address(tokenB));
        assertTrue(feeOnOut, "one hop into a bridge pays on the output");
        assertFalse(BPC.paysOnInput(0, feeHop, feeOnOut), "and on no input");

        two[0].tokenIn = address(tokenB); two[0].tokenOut = address(tokenC);
        two[1].tokenIn = address(tokenC); two[1].tokenOut = address(tokenA);
        (feeHop, feeOnOut) = door.calendar(address(hub), two, address(tokenA));
        assertEq(feeHop, 0, "a bridge on hop 0's input anchors hop 0");
        assertFalse(BPC.paysOnInput(1, feeHop, feeOnOut), "hop 1 then pays nothing");
    }
}
