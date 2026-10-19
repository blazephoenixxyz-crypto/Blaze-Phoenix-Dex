// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  H9 (oc-1018, Info) - the unspent input of a CYCLIC route (tokenIn == tokenOut)
//  belongs to the payer, as the `_execute` docstring states.
//
//  `residIn` is the route input the legs did not spend. It has two producers in
//  `_execute`: the post-loop sweep (acyclic routes, tokenIn != tokenOut) and the
//  between-hops refund at the start of hop 1 (cyclic routes). Both must send it
//  to `payer` and only it: never the pre-swap balance `baseIn`, never to the
//  recipient. Before the fix the cyclic branch skipped the sweep and the residual
//  was folded into `totalReceived` and paid to the RECIPIENT as if it were
//  output - which also let it count towards userMinOut.
//
//  Expected values come from an independent oracle (`BPC.outV3` on the pool
//  state, MockERC20 balances), never from the Router's return value.
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV3Pool} from "./mocks/MockV3Pool.sol";

contract RouterCyclicResidualToPayerTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixRouter router;
    MockERC20 tokenA; // route input AND route output (the cycle)
    MockERC20 tokenB; // bridge
    MockERC20 tokenC; // acyclic control output

    MockV3Pool pAB; // hop 0, A -> B
    MockV3Pool pBA; // hop 1, B -> A (closing leg of the cycle)
    MockV3Pool pBC; // control hop 1, B -> C

    address user = address(0xBEEF);
    address recip = address(0xCAFE);
    uint160 constant Q96 = uint160(uint256(1) << 96);
    uint128 constant LIQ = uint128(1e27);
    uint256 constant AMT = 1_000e18;   // pulled from the payer
    uint256 constant X0 = 400e18;      // hop 0's declared (and only) spend
    // Mis-sent A already in the Router (rescue property). Kept INSIDE the protocol floor's slack
    // on purpose: a refund that forgot `- baseIn` then settles instead of reverting RouterE(5),
    // and only the payer/recipient equalities below can catch it.
    uint256 constant STRAY = 1e18;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        tokenA = new MockERC20("A", "A");
        tokenB = new MockERC20("B", "B");
        tokenC = new MockERC20("C", "C");
        router = new BlazePhoenixRouter(address(hub), address(0xD0D0), address(this), address(0xFEE1), address(0xFEE2));
        hub.addBridge(address(tokenB));

        pAB = new MockV3Pool(address(tokenA), address(tokenB), 3000);
        pAB.setState(Q96, LIQ);
        pBA = new MockV3Pool(address(tokenB), address(tokenA), 3000);
        pBA.setState(Q96, LIQ);
        pBC = new MockV3Pool(address(tokenB), address(tokenC), 3000);
        pBC.setState(Q96, LIQ);

        tokenB.mint(address(pAB), 1_000_000e18);
        tokenA.mint(address(pBA), 1_000_000e18);
        tokenC.mint(address(pBC), 1_000_000e18);

        tokenA.mint(user, 10_000e18);
        vm.prank(user);
        tokenA.approve(address(router), type(uint256).max);
    }

    // --- builders (external calls: always BEFORE any cheatcode) ----------------

    function _leg(MockV3Pool p, address tIn, uint256 amt) private view returns (Leg memory) {
        return Leg({pool: address(p), hooks: address(0), kind: BPC.KIND_V3, fee: 3000, tickSpacing: 0,
            zeroForOne: p.token0() == tIn, stable: false, amountIn: amt, expectedOut: 0, auxId: bytes32(0)});
    }

    function _hop(address tIn, address tOut, uint256 amt, Leg memory l) private pure returns (Hop memory) {
        Leg[] memory ls = new Leg[](1);
        ls[0] = l;
        return Hop({tokenIn: tIn, tokenOut: tOut, amountIn: amt, expectedOut: 0, legs: ls});
    }

    /// Oracle: hop 0 turns X0 of A into b of B; the bridge fee is taken on hop 1's
    /// measured B input; hop 1 turns the net bNet into y. Pool state only.
    function _oracle(MockV3Pool closing) private view returns (uint256 bNet, uint256 y) {
        uint256 b = BPC.outV3(X0, Q96, LIQ, 3000, pAB.token0() == address(tokenA), 0);
        bNet = b - BPC.mulDivUp(b, BPC.PROTOCOL_FEE_BPS, BPC.BPS);
        y = BPC.outV3(bNet, Q96, LIQ, 3000, closing.token0() == address(tokenB), 0);
    }

    /// The cycle A -> B -> A; hop 0 declares X0 < AMT, so `residIn` = AMT - X0.
    function _cyclicRoute() private view returns (Route memory r, uint256 y) {
        uint256 bNet;
        (bNet, y) = _oracle(pBA);
        Hop[] memory hs = new Hop[](2);
        hs[0] = _hop(address(tokenA), address(tokenB), X0, _leg(pAB, address(tokenA), X0));
        hs[1] = _hop(address(tokenB), address(tokenA), bNet, _leg(pBA, address(tokenB), bNet));
        r = Route({hops: hs, totalOut: y, singleOut: y, singleOutFloor: 1, expectedImpactBps: 0,
            confidenceWad: 0, estGas: 0, hasSurplus: false, isV4Bundle: false});
    }

    /// Control: A -> B -> C, same hop 0 and same residIn; the post-loop sweep runs.
    function _acyclicRoute() private view returns (Route memory r, uint256 y) {
        uint256 bNet;
        (bNet, y) = _oracle(pBC);
        Hop[] memory hs = new Hop[](2);
        hs[0] = _hop(address(tokenA), address(tokenB), X0, _leg(pAB, address(tokenA), X0));
        hs[1] = _hop(address(tokenB), address(tokenC), bNet, _leg(pBC, address(tokenB), bNet));
        r = Route({hops: hs, totalOut: y, singleOut: y, singleOutFloor: 1, expectedImpactBps: 0,
            confidenceWad: 0, estGas: 0, hasSurplus: false, isV4Bundle: false});
    }

    // --- the claim -------------------------------------------------------------

    /// THE RED: payer != recipient on a cycle. The payer net-spends only the routed
    /// X0 (residIn refunded), the recipient receives exactly the converted y, and
    /// the Router keeps no A. Unfixed: payer delta == AMT, recipient == y + residIn.
    function test_residIn_Cyclic_RecipientNotPayer_RefundedToPayer() public {
        (Route memory r, uint256 y) = _cyclicRoute();
        assertGt(y, 0, "fixture: the closing hop must produce output");
        uint256 payerBefore = tokenA.balanceOf(user);

        vm.prank(user);
        uint256 delivered = router.swapExactIn(r, AMT, 1, recip, block.timestamp + 1);

        assertEq(tokenA.balanceOf(address(router)), 0, "Router must hold 0 A after the cycle");
        assertEq(payerBefore - tokenA.balanceOf(user), X0, "residIn must be refunded to the payer");
        assertEq(tokenA.balanceOf(recip), y, "recipient must receive the converted output only");
        assertEq(delivered, y, "the return value is the converted output, not output + residIn");
    }

    /// residIn is NOT output: a userMinOut above the converted output must refuse,
    /// even though converted output + residIn would clear it. Unfixed: settles.
    function test_residIn_Cyclic_DoesNotCountTowardsUserMinOut() public {
        (Route memory r, uint256 y) = _cyclicRoute();
        uint256 minOut = y + 1;
        assertLt(minOut, y + (AMT - X0), "fixture: residIn alone would clear the floor");

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, uint16(5)));
        router.swapExactIn(r, AMT, minOut, recip, block.timestamp + 1);
    }

    /// Only THIS swap's residIn is refunded: a balance the Router held before the
    /// swap (the 48h rescue's property) stays put, and nothing of it reaches either
    /// party. Guards the `- baseIn` of the between-hops refund.
    function test_residIn_Cyclic_StrayBalanceUntouched() public {
        tokenA.mint(address(router), STRAY);
        (Route memory r, uint256 y) = _cyclicRoute();
        uint256 payerBefore = tokenA.balanceOf(user);

        vm.prank(user);
        router.swapExactIn(r, AMT, 1, recip, block.timestamp + 1);

        assertEq(tokenA.balanceOf(address(router)), STRAY, "the stray balance must stay in the Router");
        assertEq(payerBefore - tokenA.balanceOf(user), X0, "payer is refunded residIn, never the stray balance");
        assertEq(tokenA.balanceOf(recip), y, "recipient gets the converted output, never the stray balance");
    }

    /// Control: recipient == payer. Same net result before and after the fix.
    function test_residIn_Cyclic_RecipientIsPayer_NetIsRoutedMinusOutput() public {
        (Route memory r, uint256 y) = _cyclicRoute();
        uint256 payerBefore = tokenA.balanceOf(user);

        vm.prank(user);
        router.swapExactIn(r, AMT, 1, user, block.timestamp + 1);

        assertEq(tokenA.balanceOf(address(router)), 0, "Router must hold 0 A after the cycle");
        assertEq(payerBefore - tokenA.balanceOf(user), X0 - y, "recipient == payer: net is X0 - y");
    }

    /// Control: the acyclic producer of residIn (post-loop sweep) - the behaviour
    /// the cyclic branch must match.
    function test_residIn_Acyclic_RecipientNotPayer_SweptToPayer() public {
        (Route memory r, uint256 y) = _acyclicRoute();
        uint256 payerBefore = tokenA.balanceOf(user);

        vm.prank(user);
        uint256 delivered = router.swapExactIn(r, AMT, 1, recip, block.timestamp + 1);

        assertEq(tokenA.balanceOf(address(router)), 0, "Router must hold 0 A after the acyclic route");
        assertEq(payerBefore - tokenA.balanceOf(user), X0, "acyclic: residIn swept to the payer");
        assertEq(delivered, y, "acyclic: delivered is the converted output");
        assertEq(tokenC.balanceOf(recip), y, "acyclic: recipient gets C only");
        assertEq(tokenA.balanceOf(recip), 0, "acyclic: recipient gets no A");
    }
}
