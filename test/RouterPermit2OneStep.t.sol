// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  One-step swap via Permit2 SignatureTransfer — the previously-untested
//  happy path. A user with NO standing allowance to the Router (only the
//  usual one to Permit2 itself) approves-and-swaps in a single call:
//  swapExactInWithPermit2 pulls through Permit2, measures the actual
//  receive (fee-on-transfer safe, mirroring the classic path), executes,
//  and holds nothing afterward.
//
//  Harness mirrors test/BlazePhoenixRouter.t.sol (real constructor, real
//  Route/Hop/Leg types, MockV2Pair liquidity).
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixRouter, IPermit2} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";
import {MockPermit2} from "./mocks/MockPermit2.sol";

contract RouterPermit2OneStepTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixRouter router;
    MockPermit2 permit2;
    MockERC20 tokenIn;
    MockERC20 tokenOut;
    MockV2Pair pair;

    address treasury1 = address(0xFEE1);
    address treasury2 = address(0xFEE2);
    address user = address(0xBEEF);

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        tokenIn = new MockERC20("In", "IN");
        tokenOut = new MockERC20("Out", "OUT");
        pair = new MockV2Pair(address(tokenIn), address(tokenOut));

        router = new BlazePhoenixRouter(
            address(hub), address(0xBEEF), address(this), treasury1, treasury2
        );
        permit2 = new MockPermit2();
        router.setPermit2(address(permit2));

        tokenIn.mint(address(pair), 10_000e18);
        tokenOut.mint(address(pair), 10_000e18);
        pair.setReserves(10_000e18, 10_000e18);

        // The user's ONLY approval is to Permit2 (the standing approval every
        // Permit2 user already has) — deliberately NONE to the Router, which
        // is the whole point of the one-step flow.
        tokenIn.mint(user, 3_000e18);
        vm.prank(user);
        tokenIn.approve(address(permit2), type(uint256).max);
    }

    function _buildRoute(uint256 amountIn, uint256 claimedTotalOut) private view returns (Route memory route) {
        bool zeroForOne = address(tokenIn) < address(tokenOut);
        Leg[] memory legs = new Leg[](1);
        legs[0] = Leg({
            pool: address(pair), hooks: address(0), kind: BPC.KIND_V2, fee: 30,
            tickSpacing: 0, zeroForOne: zeroForOne, stable: false,
            amountIn: amountIn, expectedOut: claimedTotalOut, auxId: bytes32(0)
        });
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({
            tokenIn: address(tokenIn), tokenOut: address(tokenOut),
            amountIn: amountIn, expectedOut: claimedTotalOut, legs: legs
        });
        route = Route({
            hops: hops, totalOut: claimedTotalOut, singleOut: claimedTotalOut,
            singleOutFloor: 0, expectedImpactBps: 0, confidenceWad: 0,
            estGas: 0, hasSurplus: false, isV4Bundle: false
        });
    }

    function _permitFor(uint256 amount) private view returns (IPermit2.PermitTransferFrom memory p) {
        p = IPermit2.PermitTransferFrom({
            permitted: IPermit2.TokenPermissions({ token: address(tokenIn), amount: amount }),
            nonce: 0,
            deadline: block.timestamp + 60
        });
    }

    /// @notice The one-step happy path: no Router allowance, tokens flow
    ///         user -> Permit2.transferFrom -> Router -> pool, output lands at
    ///         the recipient, the Router holds nothing afterward.
    function test_OneStep_SwapWithPermit2_NoRouterAllowance() public {
        uint256 amountIn = 1_000e18;
        assertEq(tokenIn.allowance(user, address(router)), 0, "precondition: zero Router allowance");

        uint256 realQuote = BPC.outV2(amountIn, 10_000e18, 10_000e18, 30);
        Route memory route = _buildRoute(amountIn, realQuote);

        vm.prank(user);
        uint256 delivered = router.swapExactInWithPermit2(
            route, amountIn, 1, user, block.timestamp + 1, _permitFor(amountIn), ""
        );

        assertGt(delivered, 0, "one-step swap must deliver");
        assertEq(tokenOut.balanceOf(user), delivered, "recipient got exactly the returned amount");
        assertEq(tokenIn.balanceOf(address(router)), 0, "router holds no tokenIn");
        assertEq(tokenOut.balanceOf(address(router)), 0, "router holds no tokenOut");
        assertEq(tokenIn.balanceOf(user), 3_000e18 - amountIn, "user paid exactly amountIn");
    }

    /// @notice A permit authorizing less than amountIn must revert RouterE(3)
    ///         before any token movement.
    function test_OneStep_PermitBelowAmountIn_Reverts() public {
        uint256 amountIn = 1_000e18;
        Route memory route = _buildRoute(amountIn, 1);
        IPermit2.PermitTransferFrom memory permit = _permitFor(amountIn - 1);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, uint16(3)));
        router.swapExactInWithPermit2(route, amountIn, 1, user, block.timestamp + 1, permit, "");
        assertEq(tokenIn.balanceOf(user), 3_000e18, "no tokens moved");
    }

    /// @notice An empty route must revert RouterE(3) BEFORE the Permit2 pull —
    ///         the measured-receive fix moved the hops-length check ahead of
    ///         the token movement, so nothing transfers on a malformed route.
    function test_OneStep_EmptyRoute_RevertsBeforePull() public {
        uint256 amountIn = 1_000e18;
        Route memory route; // zero hops

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, uint16(3)));
        router.swapExactInWithPermit2(route, amountIn, 1, user, block.timestamp + 1, _permitFor(amountIn), "");
        assertEq(tokenIn.balanceOf(user), 3_000e18, "no tokens moved");
    }
}
