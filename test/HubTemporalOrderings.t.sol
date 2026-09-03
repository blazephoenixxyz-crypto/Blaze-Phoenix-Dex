// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  C5 - THE OMITTED TEMPORAL ORDERINGS OF THE HUB CONTROL PLANE
//
//  The transition list the project reasons about (register, addBridge,
//  removeBridge, renounce, hook code change, stable flip, registry refresh,
//  swap) does not contain addFactory, setOperator, setRoles, initialize or
//  setAdmin. This file tests three orderings of the ones that touch the Hub's
//  AUTHORITY state, and each test is written against the PROMISE the
//  renounceControl docstring makes, quoted verbatim below (Hub:408-415):
//
//      "Permanently surrender the CONTROL powers - the ones that can redirect
//       or freeze the protocol: setRoles, setOperator, setPaused, setV4Manager
//       and removeBridge can never be used again. The CURATOR powers that only
//       grow the registry - addFactory, addBridge, allowHook - remain
//       available ... Irreversible."
//
//  ORDERING 1  renounceControl() -> setRoles(...)          EXPECTED GREEN today
//      The refusal itself is already pinned by
//      OssificationIsNotDeath.test_Composition_HubPauseThenRenounce_IsRefused.
//      What is NOT pinned anywhere is the CONSEQUENCE named in the Hub's own
//      comment at Hub:417-425: `recordSwap` is `onlyRouter`, `$.router` moves
//      only through `setRoles`, and the Router wraps its call in
//      `try hub.recordSwap(...) {} catch {}` (Router:2032-2035). So after
//      renunciation the registry's ONLY write door is bound to one address for
//      ever, and a successor Router's writes are refused SILENTLY. This file
//      pins that, in both directions: the incumbent keeps learning, the
//      successor cannot, and nothing reverts to the user.
//
//  ORDERING 2  renounceControl() -> initialize(...)        RED before the fix of 2026-09-03, GREEN since
//      `renounceControl` is `onlyAdmin` and the admin exists from the
//      CONSTRUCTOR (Hub:386-394), so it can be called on a Hub that was never
//      initialized. `initialize` (Hub:396-406) is gated only by
//      `$.initialized || msg.sender != $.admin` - it carries no
//      `controlRenounced` term - and it writes `$.admin`, `$.operator[admin_]`
//      and `$.v4PoolManager`. Two of those three are powers the docstring says
//      "can never be used again" (setOperator, setV4Manager), and the Hub has
//      no `setAdmin` at all, so this is also its only admin-transfer door.
//      The test asserts the DOCSTRING. It is RED on 6438fe4. Which side should
//      move - the guard or the sentence - is the owner's call, not this file's.
//
//  ORDERING 3  setOperator(x, true) -> renounceControl()   EXPECTED GREEN today
//      `setOperator` is `onlyControl`, so after renunciation a grant can never
//      be withdrawn by anybody, and the Hub exposes no operator self-revoke.
//      The code and the docstring agree here; the test exists to make the
//      permanence VISIBLE rather than implicit, and to price it: the surviving
//      grant still reaches `seedPool`, which registers a pool as `trusted` and
//      whose `_register` evicts the weakest incumbent UNCONDITIONALLY (no
//      `_canInsert` 25% margin - Hub:1789-1814 versus Hub:1702-1745).
//
//  REPAIR PASS, 2026-09-03. Four control tests were deleted as duplicates of
//  the existing suite; each contract's "controls" banner names what took over.
//  The three orderings, their assertions and every control that has no twin in
//  test/ are untouched. Two of the four mutant entries were also cut as exact
//  duplicates of C1 entries; see .github/scripts/mutants.py for which and why.
//
//  NOTHING IN THIS FILE WAS COMPILED OR RUN. The RED/GREEN calls above were
//  made by reading src/BlazePhoenixHub.sol at 6438fe4.
//
//  Every contract here carries at least one control that is green today and
//  that any fix must keep green, so a fix cannot buy the property by making
//  the door rigid.
//
//  forge test --match-path test/HubTemporalOrderings.t.sol -vv
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixCore as BPC} from "../src/BlazePhoenixCore.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";

/// @dev The Router's registry-feedback shape, reproduced exactly: Router:2032
///      calls `hub.recordSwap(...)` inside `try {} catch {}`, so a refusal never
///      reaches the user's swap. Without this stub a test could only observe the
///      revert, which is the half that is NOT the interesting half - the point
///      of ordering 1 is that the failure is SILENT.
contract SilentRecorderStub {
    address private immutable hubAddr;

    constructor(address h) { hubAddr = h; }

    /// @return swallowed true when the Hub refused and the refusal was caught.
    function record(
        address pool, uint8 kind, uint24 fee, address hooks,
        address tA, address tB, uint256 depthWad
    ) external returns (bool swallowed) {
        try BlazePhoenixHub(hubAddr).recordSwap(
            pool, kind, fee, hooks, tA, tB, 1e18, 1e18, depthWad
        ) { swallowed = false; } catch { swallowed = true; }
    }
}

// =============================================================================
//  ORDERING 1 - renounceControl() then setRoles(...)
// =============================================================================
contract HubRenounceThenSetRolesTest is Test {
    BlazePhoenixHub hub;
    SilentRecorderStub successorRouter;
    MockV2Pair pairEarly;
    MockV2Pair pairLate;

    // Bare-address tokens, base-test style. tokenA sorts below tokenB.
    address constant tokenA = address(0x2222);
    address constant tokenB = address(0x3333);
    address constant V4MGR  = address(0xD00D);
    address constant STRANGER = address(0xBEEF);

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), V4MGR);
        // This test contract IS the Hub's router role, the house idiom used by
        // ConditionAdequacyHub: recordSwap needs its caller to BE $.router.
        hub.setRoles(address(this), address(this), address(this));
        pairEarly = new MockV2Pair(tokenA, tokenB);
        pairLate  = new MockV2Pair(tokenA, tokenB);
        successorRouter = new SilentRecorderStub(address(hub));
    }

    function _err(uint16 code) private pure returns (bytes memory) {
        return abi.encodeWithSelector(BlazePhoenixHub.HubE.selector, code);
    }

    // ─── controls: green today, and any fix must keep them green ───────────
    //
    //  REMOVED BY THE RECHECK OF 2026-09-03 (duplicate):
    //    test_Control_NonRouterRevertsWithTheAuthorityCode
    //        -> test/BlazePhoenixHub.t.sol:229 test_RecordSwap_OnlyRouter and
    //           test/HubRefusalsObserved.t.sol:338 both already observe an
    //           unwrapped HubE(1) from a non-router recordSwap. What that test
    //           added over the control just below it was the error CODE; the
    //           two existing tests already pin it.

    /// CONTROL. While control survives, the write door MOVES: setRoles re-points
    /// $.router and the new address writes to the registry. This is the positive
    /// half - without it, "the door is pinned" could be green for the wrong
    /// reason (a door that never worked is also a door that never moves).
    function test_Control_BeforeRenounce_TheWriteDoorCanBeRepointed() public {
        address pool = address(pairEarly);
        bytes32 key = hub.keyOf(pool, tokenA, tokenB);
        hub.setRoles(address(successorRouter), address(this), address(this));
        bool swallowed = successorRouter.record(pool, BPC.KIND_V2, 30, address(0), tokenA, tokenB, 1e18);
        assertFalse(swallowed, "the newly wired router was accepted");
        assertEq(hub.getPool(key), pool, "and the registry learned from it");
    }

    /// CONTROL. A non-router write is refused with HubE(1) at any time, and the
    /// refusal writes nothing. This is what makes the silence in the main test
    /// readable: the stub's `swallowed` flag is a real signal, not an artefact.
    function test_Control_NonRouterIsRefusedAndWritesNothing() public {
        address pool = address(pairLate);
        bytes32 key = hub.keyOf(pool, tokenA, tokenB);
        bool swallowed = successorRouter.record(pool, BPC.KIND_V2, 30, address(0), tokenA, tokenB, 1e18);
        assertTrue(swallowed, "a non-router write is refused before renunciation too");
        assertEq(hub.getPool(key), address(0), "nothing was written");
    }

    // ─── the ordering ──────────────────────────────────────────────────────

    /// @notice ORDERING 1, GREEN today. The docstring promises setRoles can
    ///         never be used again; the consequence it does not spell out is
    ///         that `$.router` becomes an immutable, and `recordSwap` - the
    ///         registry's only write door - is bound to that one address for
    ///         the life of the contract. A successor Router is refused, and
    ///         because the Router swallows the refusal (Router:2032-2035) the
    ///         registry simply stops learning, with no symptom at the surface.
    function test_AfterRenounce_TheRegistryWriteDoorIsPinnedToOneAddressForever() public {
        address poolEarly = address(pairEarly);
        address poolLate  = address(pairLate);
        bytes32 keyEarly = hub.keyOf(poolEarly, tokenA, tokenB);
        bytes32 keyLate  = hub.keyOf(poolLate,  tokenA, tokenB);

        // the wired router learns while control is alive
        hub.recordSwap(poolEarly, BPC.KIND_V2, 30, address(0), tokenA, tokenB, 1e18, 1e18, 1e18);
        assertEq(hub.getPool(keyEarly), poolEarly, "the incumbent router wrote before renunciation");

        hub.renounceControl();

        // THE PROMISE: setRoles can never be used again.
        vm.expectRevert(_err(1));
        hub.setRoles(address(successorRouter), address(this), address(this));

        // THE CONSEQUENCE: a successor Router is refused, and refused silently.
        bool swallowed = successorRouter.record(poolLate, BPC.KIND_V2, 30, address(0), tokenA, tokenB, 1e18);
        assertTrue(swallowed, "the successor router's registry write was refused");
        assertEq(hub.getPool(keyLate), address(0),
            "and the refusal is silent: the swap settles, the registry never learns");

        // AND NOT A DEATH: the address pinned at renunciation still writes, so
        // the frozen state is a BINDING to one Router, not a dead registry.
        hub.recordSwap(poolLate, BPC.KIND_V2, 30, address(0), tokenA, tokenB, 1e18, 1e18, 1e18);
        assertEq(hub.getPool(keyLate), poolLate, "the pinned router still writes after renunciation");
    }
}

// =============================================================================
//  ORDERING 2 - renounceControl() then initialize(...)
// =============================================================================
contract HubRenounceThenInitializeTest is Test {
    BlazePhoenixHub hub;

    address constant MGR_A    = address(0xD00D);
    address constant MGR_B    = address(0xBAD0);
    address constant STRANGER = address(0xBEEF);

    /// @dev DELIBERATELY NOT INITIALIZED. The whole ordering lives in the window
    ///      the constructor opens: `$.admin` is set at construction (Hub:386-394)
    ///      so `renounceControl` (onlyAdmin) is callable before `initialize` ever
    ///      runs. Every other test file in the tree calls `initialize` in setUp,
    ///      which is exactly why this window has no coverage.
    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
    }

    function _err(uint16 code) private pure returns (bytes memory) {
        return abi.encodeWithSelector(BlazePhoenixHub.HubE.selector, code);
    }

    // ─── controls: green today, and any fix must keep them green ───────────
    //
    //  REMOVED BY THE RECHECK OF 2026-09-03 (duplicates):
    //    test_Control_InitializeThenRenounce_SecondInitializeIsRefused
    //        -> test/BlazePhoenixHub.t.sol:340 test_Initialize_RevertsOnSecondCall.
    //           The renounceControl placed between the two calls was the only
    //           novel element and it does not change the outcome ($.initialized
    //           is what refuses, and renunciation does not touch it).
    //    test_Control_NonAdminCannotInitialize
    //        -> test/BlazePhoenixHub.t.sol:345
    //           test_Initialize_RevertsWhenCalledByNonDeployer.

    /// CONTROL. Renunciation on an uninitialized Hub is itself accepted today -
    /// it is `onlyAdmin`, not `onlyControl`, and the paused flag is clear. If a
    /// fix chooses to close the window by refusing THIS instead, this test is
    /// where that decision becomes visible, so it is written with try/catch and
    /// survives either choice.
    function test_Observation_RenounceBeforeInitializeIsAcceptedToday() public {
        try hub.renounceControl() {
            // Accepted. Prove the flag really moved rather than asserting the
            // absence of a revert: setRoles would SUCCEED here (this contract is
            // the constructor admin), so its refusal can only be the new flag.
            vm.expectRevert(_err(1));
            hub.setRoles(address(this), address(this), address(this));
        } catch (bytes memory reason) {
            assertEq(keccak256(reason), keccak256(_err(1)),
                "if a fix closes the window here instead, it must refuse with the authority code");
        }
    }

    // ─── the ordering ──────────────────────────────────────────────────────

    /// @notice ORDERING 2, RED before the fix of 2026-09-03 and GREEN since. THE DOCSTRING PROMISES that after
    ///         renunciation `setOperator` and `setV4Manager` "can never be used
    ///         again". `initialize` is a live `setV4Manager` (it writes
    ///         `$.v4PoolManager`), a live `setOperator` (it writes
    ///         `$.operator[admin_] = true`) and the Hub's ONLY admin transfer
    ///         (there is no `setAdmin` in this contract) - and its gate is
    ///         `$.initialized || msg.sender != $.admin`, with no
    ///         `controlRenounced` term. On 6438fe4 this call SUCCEEDS, so this
    ///         test FAILS. Which side should move - the guard or the sentence -
    ///         is the owner's decision; the test states the sentence.
    function test_AfterRenounce_InitializeIsRefused() public {
        hub.renounceControl();
        vm.expectRevert(_err(1));
        hub.initialize(address(this), MGR_B);
        assertEq(hub.v4PoolManager(), address(0),
            "setV4Manager died with control, as renounceControl says it does");
    }

    /// @notice OBSERVATION, not a requirement, and green in both worlds. It
    ///         records exactly WHICH power the surviving door moves today, so
    ///         the evidence does not disappear the moment the fix lands and so
    ///         nothing here becomes permanently broken by a fix.
    function test_Observation_WhatInitializeAfterRenounceMovesToday() public {
        hub.renounceControl();
        try hub.initialize(address(this), MGR_B) {
            assertEq(hub.v4PoolManager(), MGR_B,
                "today: initialize after renunciation is a live setV4Manager");
        } catch (bytes memory reason) {
            assertEq(keccak256(reason), keccak256(_err(1)),
                "after the fix: refused with the authority code");
            assertEq(hub.v4PoolManager(), address(0), "and nothing moved");
        }
    }
}

// =============================================================================
//  ORDERING 3 - setOperator(x, true) then renounceControl()
// =============================================================================
contract HubOperatorGrantOutlivesRenounceTest is Test {
    BlazePhoenixHub hub;

    address constant OP       = address(0x0FE7);
    address constant STRANGER = address(0xBEEF);
    address constant tokenA   = address(0x2222);
    address constant tokenB   = address(0x3333);
    address constant V4MGR    = address(0xD00D);
    address constant POOL_A   = address(0x1001);

    /// @dev Hub:87 `MAX_SLOTS = 16`, internal - pinned here the same way
    ///      ConditionAdequacyHub pins the mode constants. If it moves, this
    ///      test stops filling the pair and the eviction assertion goes red,
    ///      which is the correct outcome: the number is load-bearing.
    uint256 constant MAX_SLOTS_PINNED = 16;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), V4MGR);
        hub.setOperator(OP, true);
    }

    function _err(uint16 code) private pure returns (bytes memory) {
        return abi.encodeWithSelector(BlazePhoenixHub.HubE.selector, code);
    }

    // ─── controls: green today, and any fix must keep them green ───────────
    //
    //  REMOVED BY THE RECHECK OF 2026-09-03 (duplicate):
    //    test_Control_BeforeRenounce_TheGrantIsRevocable
    //        -> test/UntestedSurface.t.sol:95-99, the revocation half of
    //           test_SetOperator_OnlyControl_AndGrantsSeedPool, which revokes an
    //           operator grant and asserts the seedPool door closes again with
    //           HubE(1) on a fresh pool address, for the same reason.
    //  The "before" half of this ordering is therefore now owned by that file;
    //  what stays here is the "after" half, which nothing else pins.

    /// CONTROL. A never-granted address is refused after renunciation, so the
    /// door is still closed to everyone else - the permanence is of the GRANT,
    /// not of the door.
    function test_Control_AfterRenounce_AStrangerIsStillRefused() public {
        hub.renounceControl();
        vm.prank(STRANGER);
        vm.expectRevert(_err(1));
        hub.seedPool(POOL_A, BPC.KIND_V2, 30, address(0), tokenA, tokenB);
    }

    // ─── the ordering ──────────────────────────────────────────────────────

    /// @notice ORDERING 3, GREEN today. The docstring says setOperator can never
    ///         be used again; the unstated consequence is that every grant made
    ///         before renunciation is PERMANENT - there is no admin revoke left
    ///         and no operator self-revoke anywhere in the contract. Both halves
    ///         are asserted: the revoke is refused AND the grant still works,
    ///         because "permanent" is only a fact if the power is still live.
    function test_AfterRenounce_TheOperatorGrantIsPermanent() public {
        hub.renounceControl();

        // THE PROMISE: setOperator can never be used again - in either direction.
        vm.expectRevert(_err(1));
        hub.setOperator(OP, false);

        // THE CONSEQUENCE: the grant left behind is fully live, for ever.
        vm.prank(OP);
        bytes32 key = hub.seedPool(POOL_A, BPC.KIND_V2, 30, address(0), tokenA, tokenB);
        assertEq(hub.getPool(key), POOL_A,
            "an operator granted before renunciation still writes the registry after it");
    }

    /// @notice WHAT PERMANENCE COSTS, GREEN today. `seedPool` registers as
    ///         `trusted` through `_register`, and `_register` evicts the weakest
    ///         incumbent UNCONDITIONALLY once the pair is full - it does not go
    ///         through `_canInsert`, so the 25% admission margin that guards the
    ///         swap-driven door does not apply here. A permanent operator can
    ///         therefore keep displacing incumbents on any pair for ever. This
    ///         is not presented as a defect; it is the price of ordering 3, made
    ///         measurable so the owner can decide whether it is acceptable.
    function test_AfterRenounce_ThePermanentOperatorStillEvictsIncumbents() public {
        hub.renounceControl();

        bytes32[] memory keys = new bytes32[](MAX_SLOTS_PINNED);
        for (uint256 i; i < MAX_SLOTS_PINNED; ) {
            address p = address(uint160(0x1000 + i));
            vm.prank(OP);
            keys[i] = hub.seedPool(p, BPC.KIND_V2, 30, address(0), tokenA, tokenB);
            unchecked { ++i; }
        }

        uint256 present;
        for (uint256 i; i < MAX_SLOTS_PINNED; ) {
            if (hub.getPool(keys[i]) != address(0)) present++;
            unchecked { ++i; }
        }
        assertEq(present, MAX_SLOTS_PINNED, "the pair is full: every seeded row is present");

        address newcomer = address(0x2000);
        vm.prank(OP);
        bytes32 nk = hub.seedPool(newcomer, BPC.KIND_V2, 30, address(0), tokenA, tokenB);
        assertEq(hub.getPool(nk), newcomer, "the newcomer entered a full pair");

        present = 0;
        for (uint256 i; i < MAX_SLOTS_PINNED; ) {
            if (hub.getPool(keys[i]) != address(0)) present++;
            unchecked { ++i; }
        }
        assertEq(present, MAX_SLOTS_PINNED - 1,
            "exactly one incumbent was evicted, with no admission margin asked of the newcomer");
    }
}
