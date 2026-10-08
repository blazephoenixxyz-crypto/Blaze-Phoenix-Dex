// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  The lifecycle guards of the Permit2 door.
//
//  swapExactInWithPermit2 is `external whenLive nrEntrant`. The pause and the
//  reentrancy lock are asserted on the classic door elsewhere; this pins both on
//  this door, with the exact revert code: paused -> RouterE(2), re-entered during
//  the pull -> RouterE(7).
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixRouter, IPermit2} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";
import {MockPermit2} from "./mocks/MockPermit2.sol";
import {MaliciousReentrantERC20} from "./mocks/MaliciousReentrantERC20.sol";

contract Permit2DoorLifecycleGuardsTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixRouter router;
    MockPermit2 permit2;
    MockERC20 tokenOut;

    address treasury1 = address(0xFEE1);
    address treasury2 = address(0xFEE2);
    address user = address(0xBEEF);

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        tokenOut = new MockERC20("Out", "OUT");
        router = new BlazePhoenixRouter(
            address(hub), address(0xBEEF), address(this), treasury1, treasury2
        );
        permit2 = new MockPermit2();
        router.setPermit2(address(permit2));
    }

    function _route(address tokenIn, address pair, uint256 amountIn, uint256 claimedOut)
        private view returns (Route memory route)
    {
        bool zfo = tokenIn < address(tokenOut);
        Leg[] memory legs = new Leg[](1);
        legs[0] = Leg({
            pool: pair, hooks: address(0), kind: BPC.KIND_V2, fee: 30,
            tickSpacing: 0, zeroForOne: zfo, stable: false,
            amountIn: amountIn, expectedOut: claimedOut, auxId: bytes32(0)
        });
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({
            tokenIn: tokenIn, tokenOut: address(tokenOut),
            amountIn: amountIn, expectedOut: claimedOut, legs: legs
        });
        route = Route({
            hops: hops, totalOut: claimedOut, singleOut: claimedOut,
            singleOutFloor: 0, expectedImpactBps: 0, confidenceWad: 0,
            estGas: 0, hasSurplus: false, isV4Bundle: false
        });
    }

    function _permitFor(address token, uint256 amount)
        private view returns (IPermit2.PermitTransferFrom memory p)
    {
        p = IPermit2.PermitTransferFrom({
            permitted: IPermit2.TokenPermissions({ token: token, amount: amount }),
            nonce: 0,
            deadline: block.timestamp + 60
        });
    }

    // =========================================================================
    //  1. whenLive on the Permit2 door: paused ⇒ RouterE(2), nothing moves.
    // =========================================================================

    function test_Permit2Door_PausedRevertsRouterE2() public {
        MockERC20 tokenIn = new MockERC20("In", "IN");
        MockV2Pair pair = new MockV2Pair(address(tokenIn), address(tokenOut));
        tokenIn.mint(address(pair), 10_000e18);
        tokenOut.mint(address(pair), 10_000e18);
        pair.setReserves(10_000e18, 10_000e18);
        tokenIn.mint(user, 3_000e18);
        vm.prank(user);
        tokenIn.approve(address(permit2), type(uint256).max);

        uint256 amountIn = 1_000e18;
        Route memory route = _route(address(tokenIn), address(pair), amountIn, 1);

        router.setPaused(true);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, uint16(2)));
        router.swapExactInWithPermit2(
            route, amountIn, 1, user, block.timestamp + 1, _permitFor(address(tokenIn), amountIn), ""
        );
        // The brake fires BEFORE the pull: the user still holds every token.
        assertEq(tokenIn.balanceOf(user), 3_000e18, "paused door must not move tokens");
        assertEq(tokenIn.balanceOf(address(router)), 0, "router must not receive tokens while paused");
    }

    // =========================================================================
    //  2. nrEntrant on the Permit2 door: a nested call mid-pull ⇒ RouterE(7).
    // =========================================================================

    function test_Permit2Door_ReentrancyBlockedRouterE7() public {
        MaliciousReentrantERC20 evil = new MaliciousReentrantERC20();
        MockV2Pair evilPair = new MockV2Pair(address(evil), address(tokenOut));
        evil.mint(address(evilPair), 10_000e18);
        tokenOut.mint(address(evilPair), 10_000e18);
        evilPair.setReserves(10_000e18, 10_000e18);

        uint256 amountIn = 100e18;
        evil.mint(user, 1_000e18);
        // The user's ONLY standing approval is to Permit2 (the Permit2 model).
        vm.prank(user);
        evil.approve(address(permit2), type(uint256).max);

        Route memory route = _route(address(evil), address(evilPair), amountIn, 1);

        // The nested attempt is a CLASSIC-door call: the lock is shared
        // (TSLOT_LOCK), so if the Permit2 door armed it, the nested call is
        // refused by the lock. This is exactly what pins nrEntrant HERE.
        bytes memory nested = abi.encodeWithSelector(
            router.swapExactIn.selector, route, amountIn, uint256(1), user, block.timestamp + 1
        );
        evil.setAttack(address(router), nested);

        vm.prank(user);
        uint256 delivered = router.swapExactInWithPermit2(
            route, amountIn, 1, user, block.timestamp + 1, _permitFor(address(evil), amountIn), ""
        );

        assertGt(delivered, 0, "the OUTER Permit2 swap must complete");
        assertTrue(evil.lastReentryAttempted(), "transferFrom must have attempted the nested call");
        assertTrue(evil.lastReentryReverted(), "nrEntrant must block the nested call mid-pull");

        // AND IT MUST BE THE LOCK. A nested call mid-pull reverts for several
        // unrelated reasons, so asserting only "it reverted" leaves the lock
        // unwatched. Pin the exact code.
        bytes memory ret = evil.lastReentryReturndata();
        assertEq(ret.length, 36, "nested revert must carry RouterE(uint16)");
        assertEq(bytes4(ret), BlazePhoenixRouter.RouterE.selector, "must be a RouterE");
        uint256 code;
        assembly { code := mload(add(ret, 36)) }
        assertEq(code, 7, "the refusal must be the reentrancy lock, RouterE(7)");
    }
}
