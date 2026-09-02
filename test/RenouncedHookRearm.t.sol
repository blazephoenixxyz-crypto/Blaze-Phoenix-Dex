// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  F3 — AFTER RENUNCIATION THE SURVIVING CURATOR POWER IS EXACTLY THE ONE THAT
//       CANCELS THE HOOK AUTO-PAUSE; THE POWER TO MAKE IT PERMANENT IS DEAD.
//
//  Hub:480-494, `onlyAdmin` (curator), not `onlyControl`:
//
//      function allowHook(address h, bool ok) external onlyAdmin {
//          if (!ok && $.controlRenounced) revert HubE(1);
//          $.hookAllowed[h] = ok;
//          if (ok) $.hookCodehash[h] = h.codehash; else delete $.hookCodehash[h];
//      }
//
//  Layer 3 is `isHookLive` (Hub:515-519): a hook whose runtime code changed
//  since admission is AUTO-PAUSED, and re-admission re-pins. After
//  renounceControl():
//
//    · allowHook(h, false)  -> DEAD. The de-list, the security response, is gone.
//    · allowHook(h, true)   -> ALIVE, and it re-pins hookCodehash[h] = h.codehash
//                              — precisely the call that UNDOES the auto-pause on
//                              a hook that has just mutated.
//
//  So renunciation removes the ability to stop routing through a hook and keeps
//  the ability to restart routing through a mutated one. The docstring's
//  justification (Hub:408-415) — "a malicious listing cannot drain: pools are
//  validated at quote and execution and bounded by the output floor and the
//  caller's userMinOut" — is an argument about LISTING. It does not address the
//  case it leaves open: a hook admitted honestly, mutated later, auto-paused by
//  the pin, then RE-ARMED by the one surviving lever while no lever to pause it
//  again exists.
//
//  This is NOT the delegate-proxy limitation already written down at
//  Hub:501-514 (a proxy whose own runtime never changes, which the pin cannot
//  see). This is the case the pin DOES catch, being un-caught by the only
//  remaining control action.
//
//  forge test --match-contract RenouncedHookRearm -vv
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";

contract RenouncedHookRearmTest is Test {
    BlazePhoenixHub hub;

    address constant HOOK      = address(0x8888888888888888888888888888888888888000);
    address constant FRESHHOOK = address(0x9999999999999999999999999999999999999000);

    bytes constant CODE_V1 = hex"60016000556000";
    bytes constant CODE_V2 = hex"60026000556000600060006000";

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
    }

    /// Admit a hook at CODE_V1, then mutate its runtime to CODE_V2 — a proxy
    /// upgrade at the same address, or selfdestruct+redeploy. The pin catches it.
    function _admitThenMutate() internal {
        vm.etch(HOOK, CODE_V1);
        hub.allowHook(HOOK, true);
        assertTrue(hub.isHookLive(HOOK), "a freshly admitted hook must be live");

        vm.etch(HOOK, CODE_V2);
        assertFalse(hub.isHookLive(HOOK),
            "Layer 3: a hook whose code changed since admission must auto-pause");
    }

    // ─── HALF ONE (green today): the de-list really is dead ──────────────────

    function test_RenouncedAdmin_CannotDelistHook() public {
        _admitThenMutate();
        hub.renounceControl();

        vm.expectRevert();
        hub.allowHook(HOOK, false);   // HubE(1): grow-only after renunciation
    }

    // ─── HALF TWO (RED): the re-pin survives, and it is the cancel button ────

    /// THE CLAIM: after renounceControl, nothing may make a MUTATED hook live
    /// again. Today `allowHook(h, true)` re-pins hookCodehash to the new code
    /// and the auto-pause is cancelled — by the only surviving lever, while the
    /// lever that would make the pause permanent no longer exists.
    function test_RenouncedAdmin_CanStillRearmMutatedHook() public {
        _admitThenMutate();
        hub.renounceControl();

        // Whatever shape the guard takes (a refusal today: HubE(1)), the
        // observable that matters is that the hook does not come back to life.
        try hub.allowHook(HOOK, true) { } catch { }

        assertFalse(hub.isHookLive(HOOK),
            "a mutated hook became routable again AFTER renunciation, through the one power renunciation kept");
    }

    /// The same fact stated as an observation, so the finding stays legible if
    /// the fix chooses to revert instead of to no-op.
    function test_RearmIsTheOnlyRemainingLever_Asymmetry() public {
        _admitThenMutate();
        hub.renounceControl();

        bool delistReverted;
        try hub.allowHook(HOOK, false) { } catch { delistReverted = true; }
        assertTrue(delistReverted, "de-list is dead after renunciation");

        bool rearmReverted;
        try hub.allowHook(HOOK, true) { } catch { rearmReverted = true; }
        assertTrue(rearmReverted,
            "re-arm outlived de-list: after renunciation the admin can only ever turn hook routing back ON, never off");
    }

    // ─── CONTROL (must stay green): listing a NEW hook is the documented power ─

    /// `renounceControl`'s docstring promises the curator keeps grow-only
    /// powers, and admitting a brand-new hook is squarely that. A fix must gate
    /// the RE-PIN of an already-listed hook, not the listing itself.
    function test_RenouncedAdmin_MayStillListANewHook() public {
        hub.renounceControl();
        vm.etch(FRESHHOOK, CODE_V1);
        hub.allowHook(FRESHHOOK, true);
        assertTrue(hub.isHookLive(FRESHHOOK),
            "grow-only curation must survive renunciation for a hook admitted at its current code");
    }

    /// And a hook that has NOT mutated must stay re-listable without ceremony —
    /// the no-rigidity control for whatever shape the fix takes.
    function test_UnmutatedHook_MayBeRelisted() public {
        vm.etch(HOOK, CODE_V1);
        hub.allowHook(HOOK, true);
        hub.renounceControl();
        hub.allowHook(HOOK, true);
        assertTrue(hub.isHookLive(HOOK), "re-listing an unchanged hook must remain a no-op");
    }
}
