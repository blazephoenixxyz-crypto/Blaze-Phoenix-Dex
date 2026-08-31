// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  BRIDGE PRODUCER DESYNC — the bridges[] array and the isBridge mapping must
//  always agree.
//
//  Hub.addBridge (Hub:472) has NO duplicate guard and isBridge carries NO
//  refcount:
//
//      addBridge(t):   bridges[bridgeCount_++] = t;  isBridge[t] = true;
//      removeBridge(i): isBridge[bridges[i]] = false; <shift left>; count--;
//
//  So the sequence  addBridge(x); addBridge(x); removeBridge(0)  leaves:
//    • bridges[0] == x           (the shift pulled the second copy down)
//    • isBridge[x] == false      (removeBridge cleared the flag for the pair)
//  i.e. bridge(0) == x while isBridgeToken(x) == false — an occupied array
//  seat that the mapping says is NOT a bridge. The two producers of "is x a
//  bridge?" now disagree, and the Router reads BOTH: feeHop walks the array
//  (Router:944) while the fee anchor test uses isBridgeToken (Router:946).
//
//  addBridge is onlyAdmin, removeBridge is onlyControl. After renounceControl()
//  removeBridge is frozen forever (onlyControl -> _auth false) while addBridge
//  survives (curator power) — so the desync, once created, is PERMANENT and the
//  only tool that could repair it is gone.
//
//  RED BEFORE THE FIX:
//    • test_DupAddThenRemove_ArrayMappingDesync — an occupied seat is flagged
//      non-bridge.
//    • test_Boundary_DuplicateAddMustNotConsumeSeat — a duplicate add burns a
//      second of the three MAX_BRIDGES seats.
//    • test_Desync_IsPermanentAfterRenounce — coherence must still hold once
//      the only repair (removeBridge) is frozen.
//
//  forge test --match-contract BridgeProducerDesync -vv
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";

contract BridgeProducerDesyncTest is Test {
    BlazePhoenixHub hub;

    // MAX_BRIDGES is an internal constant (Hub:105). Pinned here so this file
    // breaks if the seat count silently changes under the boundary tests.
    uint8 constant MAX_BRIDGES = 3;

    address constant X = address(0x1111);
    address constant Y = address(0x2222);
    address constant Z = address(0x3333);
    address constant W = address(0x4444);

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        // addBridge/removeBridge are admin/control powers; this contract holds
        // both, so no setRoles is needed.
    }

    /// @dev The coherence invariant, stated once: every OCCUPIED array seat
    ///      (i < bridgeCount) must name a token the mapping flags as a bridge.
    function _assertCoherent() internal view {
        uint8 n = hub.bridgeCount();
        for (uint8 i; i < n; ++i) {
            address t = hub.bridge(i);
            assertTrue(t != address(0), "an occupied seat must not be the zero address");
            assertTrue(hub.isBridgeToken(t),
                "an occupied array seat is flagged NON-bridge by the mapping: array and mapping disagree");
        }
    }

    // ─── NEGATIVE (RED): any add/remove sequence must keep the two in sync ────

    function test_DupAddThenRemove_ArrayMappingDesync() public {
        hub.addBridge(X);
        hub.addBridge(X);       // idempotent: the second add must not take a seat
        hub.removeBridge(0);    // removes the ONE seat X holds

        // Post-condition of the sequence. Before the guard the duplicate took a
        // second seat, compaction shifted it down, and this read 1 occupied seat
        // still holding X while the mapping had already been cleared — the
        // desync. With the guard the duplicate never existed, so removing seat 0
        // removes X entirely and there is nothing left to disagree about.
        assertEq(hub.bridgeCount(), 0, "the duplicate must not have created a second seat");
        assertEq(hub.bridge(0), address(0), "the seat is cleared");
        assertFalse(hub.isBridgeToken(X), "X is no longer a bridge");

        // THE CLAIM: a seat holding X must mean isBridgeToken(X). Before the fix
        // it is false — the mapping and the array disagree about the same token.
        _assertCoherent();
    }

    // ─── POSITIVE (GREEN): a normal single add/remove stays coherent ──────────

    function test_SingleAddRemove_StaysCoherent() public {
        hub.addBridge(X);
        assertEq(hub.bridgeCount(), 1, "one bridge after a single add");
        assertEq(hub.bridge(0), X, "seat 0 holds X");
        assertTrue(hub.isBridgeToken(X), "X is flagged a bridge");
        _assertCoherent();

        hub.removeBridge(0);
        assertEq(hub.bridgeCount(), 0, "no bridges after removal");
        assertFalse(hub.isBridgeToken(X), "X is no longer a bridge");
        assertEq(hub.bridge(0), address(0), "the seat is cleared");
        _assertCoherent();
    }

    // ─── BOUNDARY (GREEN): the MAX_BRIDGES seat limit rejects an overflow ─────

    function test_Boundary_ThreeDistinctBridgesFillSeats_FourthReverts() public {
        hub.addBridge(X);
        hub.addBridge(Y);
        hub.addBridge(Z);
        assertEq(hub.bridgeCount(), MAX_BRIDGES, "three distinct seats fill the registry");
        assertTrue(hub.isBridgeToken(X) && hub.isBridgeToken(Y) && hub.isBridgeToken(Z),
            "all three occupants are flagged bridges");
        _assertCoherent();

        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixHub.HubE.selector, uint16(7)));
        hub.addBridge(W); // HubE(7): bridgeCount_ >= MAX_BRIDGES
    }

    // ─── BOUNDARY (RED): a duplicate add must not consume a second seat ───────

    function test_Boundary_DuplicateAddMustNotConsumeSeat() public {
        hub.addBridge(X);
        hub.addBridge(X); // same token again — must be a no-op on the seat count

        // THE CLAIM: X is one logical bridge and must hold one seat. Before the
        // fix the count is 2 — and repeating it MAX_BRIDGES times lets a single
        // token exhaust every seat, permanently DoS-ing bridge registration.
        assertEq(hub.bridgeCount(), 1,
            "a duplicate addBridge consumed a second MAX_BRIDGES seat");
    }

    // ─── NEGATIVE (RED): the desync outlives its only repair ──────────────────

    function test_Desync_IsPermanentAfterRenounce() public {
        hub.addBridge(X);
        hub.addBridge(X);
        hub.removeBridge(0);   // desync created (bridge(0)==X, isBridge[X]==false)

        hub.renounceControl(); // removeBridge (the only repair) is now frozen

        // The only tool that could delete the incoherent seat is gone…
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixHub.HubE.selector, uint16(1)));
        hub.removeBridge(0);   // onlyControl -> _auth(false) -> HubE(1)

        // …so coherence must have held BEFORE renunciation. It did not, and now
        // it cannot be restored: the invariant below is RED and permanently so.
        _assertCoherent();
    }
}
