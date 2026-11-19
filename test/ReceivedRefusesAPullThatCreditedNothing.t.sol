// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  `Router._received` refuses a pull that credited nothing (RouterE(8))
//
//  Since FU-3 `_noteFot` refuses a measured ratio of zero with the same RouterE(8). A pull that
//  asked for `amountIn > 0` and credited nothing therefore reaches the same refusal, with the same
//  revert data, whether `_received` refuses it or `_noteFot` does: the hostile-token rows cannot
//  tell the two apart, and a mutant that drops the `_received` check survives them.
//
//  The check is the only refuser when the ask is zero. The Permit2 door admits `amountIn == 0`
//  (its zero-floor guard reads `amountIn > 0 && userMinOut == 0`): a zero ask that credited nothing
//  equals the ask, so `_noteFot` never runs, and without the check the swap goes on to
//  `_swapPrePulled`, which refuses with RouterE(3). These tests pin RouterE(8) there, so they go
//  red when the check in `_received` is removed.
//
//  Gamut: a zero ask on an empty Router and under any balance held before the pull (fuzz).
//  Control: the same fixture settles a non-zero ask through the same door.
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixRouter, IPermit2} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";
import {MockPermit2} from "./mocks/MockPermit2.sol";

contract ReceivedRefusesAPullThatCreditedNothingTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixRouter router;
    MockPermit2 permit2;
    MockERC20 inTok;
    MockERC20 outTok;
    MockV2Pair pair;

    address payer = address(0xA11CE);
    address recipient = address(0xCAFE);
    uint256 constant RESERVE = 1_000_000e18;
    uint256 constant AMT = 1e18;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        router = new BlazePhoenixRouter(address(hub), address(0xBEEF), address(this), address(0xFEE1), address(0xFEE2));
        permit2 = new MockPermit2();
        router.setPermit2(address(permit2));

        inTok = new MockERC20("IN", "IN");
        outTok = new MockERC20("OUT", "OUT");
        pair = new MockV2Pair(address(inTok), address(outTok));
        inTok.mint(address(pair), RESERVE);
        outTok.mint(address(pair), RESERVE);
        pair.setReserves(uint112(RESERVE), uint112(RESERVE));

        inTok.mint(payer, 10 * AMT);
        vm.prank(payer);
        inTok.approve(address(permit2), type(uint256).max);
    }

    function _route(uint256 amt) private view returns (Route memory r) {
        Leg[] memory legs = new Leg[](1);
        legs[0] = Leg({
            pool: address(pair), hooks: address(0), kind: BPC.KIND_V2, fee: 30,
            tickSpacing: 0, zeroForOne: pair.token0() == address(inTok), stable: false,
            amountIn: amt, expectedOut: 0, auxId: bytes32(0)
        });
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({tokenIn: address(inTok), tokenOut: address(outTok), amountIn: amt, expectedOut: 0, legs: legs});
        r = Route({
            hops: hops, totalOut: 0, singleOut: 0, singleOutFloor: 0,
            expectedImpactBps: 0, confidenceWad: 0, estGas: 0,
            hasSurplus: false, isV4Bundle: false
        });
    }

    function _permit(uint256 amt) private view returns (IPermit2.PermitTransferFrom memory) {
        return IPermit2.PermitTransferFrom({
            permitted: IPermit2.TokenPermissions({token: address(inTok), amount: amt}),
            nonce: 0,
            deadline: block.timestamp + 60
        });
    }

    function _e(uint16 code) private pure returns (bytes memory) {
        return abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, code);
    }

    /// Control: the fixture settles a non-zero ask through the Permit2 door, so the refusals
    /// below are the zero credit, not the fixture.
    function test_Permit2Door_Control_NonZeroAsk_Settles() public {
        Route memory r = _route(AMT);
        IPermit2.PermitTransferFrom memory p = _permit(AMT);
        vm.prank(payer);
        uint256 got = router.swapExactInWithPermit2(r, AMT, 1, recipient, block.timestamp + 1, p, "");
        assertGt(got, 0, "control: the fixture settles");
        assertEq(outTok.balanceOf(recipient), got, "control: the output reached the recipient");
    }

    /// A zero ask on an empty Router credits nothing: `_received` refuses it with RouterE(8)
    /// (without its check the swap reaches `_swapPrePulled` and refuses with RouterE(3)).
    function test_Received_ZeroCreditOnAZeroAsk_IsRefusedWithRouterE8() public {
        Route memory r = _route(0);
        IPermit2.PermitTransferFrom memory p = _permit(0);
        uint256 payerBefore = inTok.balanceOf(payer);
        vm.prank(payer);
        vm.expectRevert(_e(8));
        router.swapExactInWithPermit2(r, 0, 0, recipient, block.timestamp + 1, p, "");
        assertEq(inTok.balanceOf(payer), payerBefore, "a refusal leaves the payer untouched");
    }

    /// The same under any balance the Router held before the pull: the delta is still zero.
    function testFuzz_Received_ZeroCreditOnAZeroAsk_UnderAHeldBalance_IsRefusedWithRouterE8(uint256 held) public {
        held = bound(held, 1, 1e30);
        inTok.mint(address(router), held);
        Route memory r = _route(0);
        IPermit2.PermitTransferFrom memory p = _permit(0);
        vm.prank(payer);
        vm.expectRevert(_e(8));
        router.swapExactInWithPermit2(r, 0, 0, recipient, block.timestamp + 1, p, "");
        assertEq(inTok.balanceOf(address(router)), held, "what was held before the pull stays whole");
    }
}
