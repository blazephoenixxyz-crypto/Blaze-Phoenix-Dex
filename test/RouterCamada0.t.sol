// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  Camada-0 regression tests — BP-04: force userMinOut > 0.
//
//  BP-04 (spec: docs/internal/v3-hardening-spec.md §5): every swap entry
//  point must REVERT with RouterE(10) when userMinOut == 0 and amountIn > 0.
//  userMinOut is the only sandwich-resistant protection; the protocol floors
//  merely bound the loss. Invariant I8 (idempotence) is preserved: the guard
//  is conditioned on amountIn > 0, so a zero-amount call never reverts
//  solely because userMinOut is 0.
//
//  Setup/harness mirrors test/BlazePhoenixRouter.t.sol so these tests
//  compile against the real constructor and Route/Hop/Leg types.
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixRouter, IPermit2} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";

contract RouterCamada0Test is Test {
    BlazePhoenixHub hub;
    BlazePhoenixRouter router;
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

        tokenIn.mint(address(pair), 10_000e18);
        tokenOut.mint(address(pair), 10_000e18);
        pair.setReserves(10_000e18, 10_000e18);

        tokenIn.mint(user, 3_000e18);
        vm.prank(user);
        tokenIn.approve(address(router), type(uint256).max);
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

    // =========================================================================
    //  BP-04 — userMinOut == 0 with amountIn > 0 must revert RouterE(10)
    // =========================================================================

    function test_BP04_reverts_zero_minout_with_amount() public {
        uint256 amountIn = 1_000e18;
        Route memory route = _buildRoute(amountIn, 1);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, 10));
        router.swapExactIn(route, amountIn, 0, user, block.timestamp + 1);
    }

    function test_BP04_reverts_zero_minout_with_amount_permit2() public {
        uint256 amountIn = 1_000e18;
        Route memory route = _buildRoute(amountIn, 1);
        // The guard is the FIRST statement of the body — it must fire before
        // the permit is even inspected, so an empty permit/signature is fine.
        IPermit2.PermitTransferFrom memory permit;
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, 10));
        router.swapExactInWithPermit2(route, amountIn, 0, user, block.timestamp + 1, permit, "");
    }

    // =========================================================================
    //  I8 — amountIn == 0 must NOT trip the BP-04 guard
    // =========================================================================

    /// @notice I8 (idempotence): a zero-amount call must never revert BECAUSE
    ///         userMinOut == 0 — the BP-04 guard (RouterE(10)) must not fire.
    ///         NOTE: the Router's pre-existing input validation (_swap, since
    ///         v2.0.0) rejects amountIn == 0 with RouterE(3); that behaviour
    ///         predates and is outside BP-04's scope (see
    ///         test_SwapExactIn_RevertsOnZeroAmountIn in
    ///         BlazePhoenixRouter.t.sol, which pins it). This test therefore
    ///         asserts the I8-relevant property BP-04 owns: IF the call
    ///         reverts, it is the pre-existing RouterE(3) — never the new
    ///         RouterE(10). If a later Camada task turns amountIn == 0 into a
    ///         true non-reverting no-op, this test keeps passing unchanged.
    function test_BP04_zero_amount_is_noop() public {
        Route memory route = _buildRoute(0, 1);
        uint256 deadline = block.timestamp + 1;
        vm.prank(user);
        (bool ok, bytes memory ret) = address(router).call(
            abi.encodeWithSelector(
                router.swapExactIn.selector, route, uint256(0), uint256(0), user, deadline
            )
        );
        if (!ok) {
            assertEq(
                ret,
                abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, 3),
                "amountIn==0 must never trip the BP-04 guard (RouterE(10)); only the pre-existing RouterE(3) input validation may fire"
            );
        }
    }

    // test_BP04_zero_amount_is_noop_7702 removed with the 7702 alias — the
    // classic test_BP04_zero_amount_is_noop above covers the identical guard.
}
