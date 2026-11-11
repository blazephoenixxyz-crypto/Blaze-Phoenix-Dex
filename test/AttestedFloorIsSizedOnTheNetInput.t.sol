// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  `singleOutFloor` is attested on the input the Router executes with (4007)
//
//  Red at 8d2ce64 (fin1111-router): the Solver attested `singleOutFloor` on the GROSS input
//  (its pool math sees no protocol fee). The Router charges the fee on a hop input, rounded up,
//  executes on what is left and compares that delivery against the attested figure, literally.
//  The floor's own slack hides the 28 bps on ordinary sizes; where the round-up is a large part
//  of the base (a whole unit of a low-decimal token, a small bridge leg) the Router refused,
//  with RouterE(5), the very route its own Solver had just planned.
//
//  The property: the Solver attests the floor on the input net of the fee the Router will
//  charge, read from the same calendar (`Core.feeCalendar`: the first hop whose input is a
//  bridge, every hop when there is none, the output when the route is one hop into a bridge),
//  the net input scaled down and the floor rounded up as before; the Router compares the
//  attested floor literally (delivered never below attested), unchanged. On a route whose fee
//  comes off the output the floor is attested on the pre-fee output, as the Router compares it.
//
//  The oracle is constant-product arithmetic done here on reserves read from the pair, the fee
//  as ceil(base * 28 / 10000), and the floor rate read back from the Router's own ExecutionProof
//  (floorUsed / quote: the rate both producers must agree on); never the Solver's own figures.
//  Dimensions: best door, classic door and the Quoter's exact preview; fee on hop 0, on a bridge
//  hop, on the output; every whole amount 2..40, fuzz to 5000; the literal comparison on both
//  sides of the delivery.
// =============================================================================

import {Test, Vm} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixQuoter} from "../src/BlazePhoenixQuoter.sol";
import {BlazePhoenixCore as BPC, Route, RoutePlan} from "../src/BlazePhoenixCore.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";
import {Origin} from "./mocks/MockOriginFactory.sol";
import {MockERC20Dec} from "./adapters/mocks/MockERC20Dec.sol";

abstract contract NetFloorOracle is Test {
    address internal constant USER = address(0xBEEF);
    address internal constant T1 = address(0xFEE1);
    address internal constant T2 = address(0xFEE2);

    function _fee(uint256 base) internal pure returns (uint256) { return (base * 28 + 9_999) / 10_000; }

    /// constant product, 30 bps pool fee
    function _out(uint256 ain, uint256 rIn, uint256 rOut) internal pure returns (uint256) {
        uint256 a = ain * 9_970;
        return (a * rOut) / (rIn * 10_000 + a);
    }

    function _reserves(MockV2Pair p, address tIn) internal view returns (uint256 rIn, uint256 rOut) {
        (uint112 r0, uint112 r1,) = p.getReserves();
        (rIn, rOut) = p.token0() == tIn ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
    }

    function _e5() internal pure returns (bytes memory) {
        return abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, uint16(5));
    }

    /// The Router's ExecutionProof: (quoted, floorUsed).
    function _proof(Vm.Log[] memory logs) internal pure returns (uint256 quoted, uint256 floorUsed) {
        bytes32 sig = keccak256("ExecutionProof(address,address,uint256,uint256,uint256,uint256)");
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] != sig) continue;
            (quoted,, floorUsed,) = abi.decode(logs[i].data, (uint256, uint256, uint256, uint256));
            return (quoted, floorUsed);
        }
        revert("ExecutionProof not emitted");
    }

    function _wire(BlazePhoenixHub hub, MockV2Pair p, MockERC20Dec x, MockERC20Dec y, uint256 rx, uint256 ry) internal {
        Origin.wire(hub, address(p), address(x), address(y), BPC.KIND_V2, 30);
        x.mint(address(p), rx);
        y.mint(address(p), ry);
        if (p.token0() == address(x)) p.setReserves(uint112(rx), uint112(ry));
        else p.setReserves(uint112(ry), uint112(rx));
        for (uint256 i; i < 5; ++i) {
            hub.recordSwap(address(p), BPC.KIND_V2, 30, address(0), address(x), address(y), 10, 10 * ry / rx, rx);
        }
    }
}

/// Fee on hop 0 (no bridge on the route) and fee on the output (tokenOut made a bridge).
contract AttestedFloorIsSizedOnTheNetInputTest is NetFloorOracle {
    BlazePhoenixHub internal hub;
    BlazePhoenixSolver internal solver;
    BlazePhoenixRouter internal router;
    BlazePhoenixQuoter internal quoter;
    MockERC20Dec internal tokenIn;
    MockERC20Dec internal tokenOut;
    MockV2Pair internal pair;

    uint256 internal constant RESERVE_IN = 1_000_000;
    uint256 internal constant RESERVE_OUT = 100_000_000;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        solver = new BlazePhoenixSolver(address(hub), address(0));
        router = new BlazePhoenixRouter(address(hub), address(solver), address(this), T1, T2);
        quoter = new BlazePhoenixQuoter(address(hub), address(solver));

        tokenIn = new MockERC20Dec(0);
        tokenOut = new MockERC20Dec(0);
        pair = new MockV2Pair(address(tokenIn), address(tokenOut));
        hub.setRoles(address(this), address(solver), address(this));
        _wire(hub, pair, tokenIn, tokenOut, RESERVE_IN, RESERVE_OUT);
        hub.setRoles(address(router), address(solver), address(this));

        tokenIn.mint(USER, 1_000_000);
        vm.prank(USER);
        tokenIn.approve(address(router), type(uint256).max);
    }

    function _plan(uint256 amt) private view returns (Route memory r) {
        RoutePlan memory plan = solver.findBestRoutePlan(address(tokenIn), address(tokenOut), amt);
        r = plan.best;
        assertEq(r.hops.length, 1, "precondition: direct route");
        assertEq(r.hops[0].legs.length, 1, "precondition: one leg");
        assertEq(r.hops[0].legs[0].pool, address(pair), "precondition: the pair");
    }

    /// The best door settles `amt` and delivers the pool's output on the net input.
    function _bestDoorSettles(uint256 amt) private returns (uint256 delivered) {
        (uint256 rIn, uint256 rOut) = _reserves(pair, address(tokenIn));
        uint256 fee = _fee(amt);
        uint256 expected = _out(amt - fee, rIn, rOut);
        uint256 inBefore = tokenIn.balanceOf(USER);
        uint256 outBefore = tokenOut.balanceOf(USER);
        uint256 feeBefore = tokenIn.balanceOf(T1) + tokenIn.balanceOf(T2);
        vm.prank(USER);
        delivered = router.swapBestExactIn(address(tokenIn), address(tokenOut), amt, 1, USER, block.timestamp + 1);
        assertEq(delivered, expected, "delivers the pool's output on the net input");
        assertEq(tokenOut.balanceOf(USER) - outBefore, expected, "at the recipient");
        assertEq(inBefore - tokenIn.balanceOf(USER), amt, "the payer spent exactly amountIn");
        assertEq(tokenIn.balanceOf(T1) + tokenIn.balanceOf(T2) - feeBefore, fee, "the fee was paid, rounded up");
    }

    // ---- the report ---------------------------------------------------------------------------

    /// THE RED (4007): at 8d2ce64 this reverted RouterE(5): 10 in, fee 1, the floor attested on 10.
    function test_BestDoor_ExecutesTheRouteItPlanned_WhenTheFeeRoundsUpToAWholeUnit() public {
        Route memory r = _plan(10);
        (uint256 rIn, uint256 rOut) = _reserves(pair, address(tokenIn));
        assertLe(r.singleOutFloor, _out(9, rIn, rOut), "the attested floor is above what the net input can deliver");
        assertGt(r.singleOutFloor, 0, "a floor was attested");
        _bestDoorSettles(10);
    }

    function test_BestDoor_ExecutesTheRouteItPlanned_EveryWholeAmountFrom2To40() public {
        for (uint256 amt = 2; amt <= 40; ++amt) _bestDoorSettles(amt);
    }

    function testFuzz_BestDoor_ExecutesTheRouteItPlanned(uint256 amt) public {
        _bestDoorSettles(bound(amt, 2, 5_000));
    }

    /// The classic door with the Solver's own plan, unchanged.
    function test_ClassicDoor_TheSolversPlanSettlesUnderItsOwnFloor() public {
        Route memory r = _plan(10);
        (uint256 rIn, uint256 rOut) = _reserves(pair, address(tokenIn));
        vm.prank(USER);
        uint256 delivered = router.swapExactIn(r, 10, 1, USER, block.timestamp + 1);
        assertEq(delivered, _out(9, rIn, rOut), "delivers the pool's output on the net input");
    }

    /// The Quoter's exact preview of the same plan: the floor it carries is met by the exact output.
    function test_ExactPreview_TheFloorIsMetByTheExactOutput_EveryWholeAmountFrom2To40() public {
        for (uint256 amt = 2; amt <= 40; ++amt) {
            (Route memory r, uint256 exactOut) = quoter.previewPlanExact(address(tokenIn), address(tokenOut), amt);
            assertGt(exactOut, 0, "the preview walks");
            assertLe(r.singleOutFloor, exactOut, "the preview's floor is above its own exact output");
        }
    }

    /// THE PIN of the attestation: the floor is the floor RATE the Router enforces (read from its
    /// proof) applied to the gross output scaled by (base - fee) / base, rounded down, then up.
    /// Amounts whose quote is five figures or more: the rate read back from a rounded-up floor
    /// is then exact to the bps.
    function test_Pin_TheAttestedFloorIsTheRouterRateOnTheNetOutput() public {
        for (uint256 amt = 2_000; amt <= 5_000; amt += 750) {
            Route memory r = _plan(amt);
            vm.recordLogs();
            vm.prank(USER);
            router.swapExactIn(r, amt, 1, USER, block.timestamp + 1);
            (uint256 quoted, uint256 floorUsed) = _proof(vm.getRecordedLogs());
            uint256 rateBps = BPC.mulDiv(floorUsed, BPC.BPS, quoted);
            uint256 net = BPC.mulDiv(r.totalOut, amt - _fee(amt), amt);
            assertEq(r.singleOutFloor, BPC.mulDivUp(net, rateBps, BPC.BPS), "the attested floor is not the rate on the net output");
        }
    }

    /// The Router compares the attested floor literally: at the delivery it settles, one above it refuses.
    function test_TheRouterComparesTheAttestedFloorLiterally() public {
        Route memory r = _plan(10);
        (uint256 rIn, uint256 rOut) = _reserves(pair, address(tokenIn));
        uint256 out = _out(9, rIn, rOut);
        r.singleOutFloor = out + 1;
        vm.prank(USER);
        vm.expectRevert(_e5());
        router.swapExactIn(r, 10, 1, USER, block.timestamp + 1);
        r.singleOutFloor = out;
        vm.prank(USER);
        assertEq(router.swapExactIn(r, 10, 1, USER, block.timestamp + 1), out, "settles at the delivery");
    }

    /// tokenOut made a bridge: the fee comes off the output and the floor is attested on the
    /// pre-fee output, unscaled, which is what the Router compares; the net delivery is below it.
    function test_FeeOnTheOutput_TheFloorIsAttestedOnThePreFeeOutput() public {
        hub.setRoles(address(this), address(solver), address(this));
        hub.addBridge(address(tokenOut));
        hub.setRoles(address(router), address(solver), address(this));
        uint256 amt = 2_000;
        Route memory r = _plan(amt);
        (uint256 rIn, uint256 rOut) = _reserves(pair, address(tokenIn));
        uint256 out = _out(amt, rIn, rOut);
        vm.recordLogs();
        vm.prank(USER);
        uint256 delivered = router.swapExactIn(r, amt, 1, USER, block.timestamp + 1);
        assertEq(delivered, out - _fee(out), "settles; the fee comes off the output");
        (uint256 quoted, uint256 floorUsed) = _proof(vm.getRecordedLogs());
        assertEq(quoted, out, "the Router compares on the pre-fee output");
        uint256 rateBps = BPC.mulDiv(floorUsed, BPC.BPS, quoted);
        assertEq(r.singleOutFloor, BPC.mulDivUp(r.totalOut, rateBps, BPC.BPS), "the attested floor is not the rate on the pre-fee output");
    }
}

/// Fee on the bridge input of a two-hop route, where hop 0 multiplies the amount: the fee on the
/// bridge is several units while the fee on the ask is one.
contract AttestedFloorIsSizedOnTheNetBridgeInputTest is NetFloorOracle {
    BlazePhoenixHub internal hub;
    BlazePhoenixSolver internal solver;
    BlazePhoenixRouter internal router;
    MockERC20Dec internal tokenA;
    MockERC20Dec internal bridge;
    MockERC20Dec internal tokenC;
    MockV2Pair internal pairAB;
    MockV2Pair internal pairBC;

    uint256 internal constant RESERVE_A = 1_000_000;
    uint256 internal constant RESERVE_B = 100_000_000;
    uint256 internal constant RESERVE_C = 100_000_000;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        solver = new BlazePhoenixSolver(address(hub), address(0));
        router = new BlazePhoenixRouter(address(hub), address(solver), address(this), T1, T2);
        tokenA = new MockERC20Dec(0);
        bridge = new MockERC20Dec(0);
        tokenC = new MockERC20Dec(0);
        pairAB = new MockV2Pair(address(tokenA), address(bridge));
        pairBC = new MockV2Pair(address(bridge), address(tokenC));

        hub.setRoles(address(this), address(solver), address(this));
        _wire(hub, pairAB, tokenA, bridge, RESERVE_A, RESERVE_B);
        _wire(hub, pairBC, bridge, tokenC, RESERVE_B, RESERVE_C);
        hub.addBridge(address(bridge));
        hub.setRoles(address(router), address(solver), address(this));

        tokenA.mint(USER, 1_000_000);
        vm.prank(USER);
        tokenA.approve(address(router), type(uint256).max);
    }

    function _plan(uint256 amt) private view returns (Route memory r) {
        r = solver.findBestRoutePlan(address(tokenA), address(tokenC), amt).best;
        assertEq(r.hops.length, 2, "precondition: through the bridge");
        assertEq(r.hops[1].tokenIn, address(bridge), "precondition: the fee hop is the bridge input");
    }

    function _bestDoorSettles(uint256 amt) private {
        (uint256 rIn, uint256 rOut) = _reserves(pairAB, address(tokenA));
        uint256 mid = _out(amt, rIn, rOut);
        uint256 fee = _fee(mid);
        (rIn, rOut) = _reserves(pairBC, address(bridge));
        uint256 expected = _out(mid - fee, rIn, rOut);
        uint256 feeBefore = bridge.balanceOf(T1) + bridge.balanceOf(T2);
        uint256 outBefore = tokenC.balanceOf(USER);
        vm.prank(USER);
        uint256 delivered = router.swapBestExactIn(address(tokenA), address(tokenC), amt, 1, USER, block.timestamp + 1);
        assertEq(delivered, expected, "delivers the second pool's output on the net bridge input");
        assertEq(tokenC.balanceOf(USER) - outBefore, expected, "at the recipient");
        assertEq(bridge.balanceOf(T1) + bridge.balanceOf(T2) - feeBefore, fee, "the fee was paid in the bridge, rounded up");
    }

    /// THE RED (4007, the bridge half): 10 in, ~997 of the bridge, fee 3, the floor attested on all 997.
    function test_BestDoor_BridgeHopFee_ExecutesTheRouteItPlanned() public {
        Route memory r = _plan(10);
        (uint256 rIn, uint256 rOut) = _reserves(pairAB, address(tokenA));
        uint256 mid = _out(10, rIn, rOut);
        assertGt(_fee(mid), _fee(10), "precondition: the bridge fee is more units than the ask's");
        (rIn, rOut) = _reserves(pairBC, address(bridge));
        assertLe(r.singleOutFloor, _out(mid - _fee(mid), rIn, rOut), "the attested floor is above what the net bridge input can deliver");
        _bestDoorSettles(10);
    }

    function test_BestDoor_BridgeHopFee_EveryWholeAmountFrom2To40() public {
        for (uint256 amt = 2; amt <= 40; ++amt) _bestDoorSettles(amt);
    }

    /// THE PIN on the bridge hop: the net factor is the BRIDGE input's, not the ask's. Amounts
    /// whose quote is five figures or more, as in the direct pin.
    function test_Pin_TheAttestedFloorIsTheRouterRateOnTheOutputNetOfTheBridgeFee() public {
        for (uint256 amt = 100; amt <= 5_000; amt += 700) {
            Route memory r = _plan(amt);
            uint256 b = r.hops[1].amountIn;
            vm.recordLogs();
            vm.prank(USER);
            router.swapExactIn(r, amt, 1, USER, block.timestamp + 1);
            (uint256 quoted, uint256 floorUsed) = _proof(vm.getRecordedLogs());
            uint256 rateBps = BPC.mulDiv(floorUsed, BPC.BPS, quoted);
            uint256 net = BPC.mulDiv(r.totalOut, b - _fee(b), b);
            assertEq(r.singleOutFloor, BPC.mulDivUp(net, rateBps, BPC.BPS), "the attested floor is not the rate on the output net of the bridge fee");
        }
    }
}
