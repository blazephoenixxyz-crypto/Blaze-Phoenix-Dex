// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  renounceControl says: only the CURATOR powers that GROW the registry survive
//  (addFactory, addBridge, allowHook). But `allowHook(h, false)` is a removal:
//  it de-lists a hook and auto-pauses every pool routed through it, a
//  pause-shaped power over the hooked V4 subset. It was `onlyAdmin`, so it
//  survived renunciation while `setPaused` and `removeBridge` did not.
//
//  This file pins the docstring: after renounceControl, allowing a hook still
//  works (grows), de-listing one is refused (shrinks). Before renunciation the
//  admin keeps both arms.
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";

contract HookStub { function beforeSwap() external pure returns (uint256) { return 1; } }

contract HubAllowHookAfterRenounceTest is Test {
    BlazePhoenixHub hub;
    address hookA;
    address hookB;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0xD00D));
        hookA = address(new HookStub());
        hookB = address(new HookStub());
    }

    function _err(uint16 code) private pure returns (bytes memory) {
        return abi.encodeWithSelector(BlazePhoenixHub.HubE.selector, code);
    }

    /// Control: before renunciation the admin can list and de-list.
    function test_Control_BeforeRenounce_AdminCanListAndDelist() public {
        hub.allowHook(hookA, true);
        assertTrue(hub.isHookLive(hookA), "listed");
        hub.allowHook(hookA, false);
        assertFalse(hub.isHookLive(hookA), "de-listed");
    }

    /// RED on main: the de-list arm survives renunciation.
    function test_AfterRenounce_DelistingAHookIsRefused() public {
        hub.allowHook(hookA, true);
        hub.renounceControl();
        vm.expectRevert(_err(1));
        hub.allowHook(hookA, false);
        assertTrue(hub.isHookLive(hookA), "the hook stays live: removals died with control");
    }

    /// Guard: the GROWING arm keeps working after renunciation, exactly as the
    /// docstring promises. A fix that gated the whole function would kill this.
    function test_AfterRenounce_ListingANewHookStillWorks() public {
        hub.renounceControl();
        hub.allowHook(hookB, true);
        assertTrue(hub.isHookLive(hookB), "curator power survives");
    }

    /// Guard: re-listing an already listed hook after renunciation re-pins its
    /// codehash (a grow, not a shrink) and must remain allowed.
    function test_AfterRenounce_RelistingRepinsAndIsAllowed() public {
        hub.allowHook(hookA, true);
        hub.renounceControl();
        hub.allowHook(hookA, true);
        assertTrue(hub.isHookLive(hookA), "re-pinned, still live");
    }
}
