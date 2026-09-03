// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  C1 - THE HUB AUTHORITY LAYER, GIVEN NEGATIVE TESTS AND MUTANTS.
//
//  WHAT THIS FILE CLAIMS. The Hub's five modifiers and its two un-modified
//  authority doors are the highest-severity surface in SECURITY.md (a wrong
//  caller here is permanent freeze or permanent misdirection of the registry),
//  and until this file none of them had a mutant in .github/scripts/mutants.py.
//  Mutation is the only instrument that answers "does a test NOTICE when this
//  guard is deleted?", so an unmutated modifier is a guard nobody is watching.
//
//      Hub:434  modifier onlyAdmin()    { _auth(msg.sender == _store().admin); _; }
//      Hub:436  modifier onlyControl()  { ... _auth(msg.sender == $.admin && !$.controlRenounced); ... }
//      Hub:441  modifier onlyOperator() { _auth(_store().operator[msg.sender] || msg.sender == _store().admin); _; }
//      Hub:442  modifier onlyRouter()   { _auth(msg.sender == _store().router); _; }
//      Hub:443  modifier whenLive()     { if (_store().paused) revert HubE(2); _; }
//      Hub:396  function initialize(address admin_, address v4Manager_) external
//      Hub:476  function setV4Manager(address m) external onlyControl
//
//  RED OR GREEN TODAY, against main @ 6438fe4: EVERY TEST IN THIS FILE IS
//  EXPECTED GREEN. This cluster reports no defect. It closes an EVIDENCE gap,
//  not a behaviour gap: each test is written so that the paired mutant in
//  .github/scripts/mutants.py turns it RED, and each carries a control that must stay
//  green after any future change to the authority layer.
//
//  REPAIR PASS, 2026-09-03. Three recheck lenses read this file and found that
//  15 of the 23 drafted tests re-pinned a property the suite already pins. All
//  15 were deleted; NO mutant was lost with them - each entry in
//  .github/scripts/mutants.py now names the existing test that already dies to it, and
//  every section banner below says which test took over. What survives here is
//  only what the suite did not have: the un-pranked renounceControl door, the
//  gas discrimination on allowHook, the setPaused arm, the pause-is-not-a-
//  tombstone control, the modifier ORDER, initialize's third code, and the
//  hand-over control. The 16 mutant entries - the thing this cluster actually
//  existed to produce - are all still here.
//
//  WHY THE ERROR CODE IS NOT ENOUGH, and how this file answers it. `_auth`
//  reverts HubE(1) and so do OTHER checks inside the Hub - notably the two
//  inside `allowHook` (Hub:488, Hub:496) and the compound inside `initialize`
//  (Hub:399). A test that only asserts "it reverted with HubE(1)" can be green
//  because a check two steps further on produced the same code; that is the
//  exact defect the header of mutants.py documents. Three answers are used
//  here, in this order of preference:
//    1. CHOOSE A DOOR WHOSE BODY CANNOT PRODUCE THE CODE. `addBridge` reverts
//       only HubE(3)/HubE(7); `setV4Manager` and `setPaused` have no revert at
//       all; `seedPool` reverts HubE(3)/HubE(4); `recordSwap` never reverts in
//       its body (it returns). On those doors HubE(1) can only be the modifier.
//    2. WHERE THE BODY DOES SHARE THE CODE (`allowHook`), DISCRIMINATE BY GAS,
//       the trick documented in test/RoutableBridgeAsymmetry.t.sol: the
//       modifier reverts strictly earlier and therefore strictly cheaper.
//    3. PAIR EVERY REFUSAL WITH A STATE OBSERVABLE - the bridge table, the
//       registry slot, the v4PoolManager getter - so a refusal for the wrong
//       reason still has to explain an unchanged world.
//
//  forge test --match-contract HubAuthorityLayer -vv
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixCore as BPC} from "../src/BlazePhoenixCore.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";

contract HubAuthorityLayerTest is Test {
    BlazePhoenixHub hub;

    // The admin/deployer is address(this) throughout, exactly as every other
    // Hub test in this repo sets itself up.
    address constant MGR      = address(0xBEEF);
    address constant ROUTER   = address(0x2001);
    address constant SOLVER   = address(0x2002);
    address constant QUOTER   = address(0x2003);
    address constant STRANGER = address(0xA11CE);
    address constant NEWADMIN = address(0x4001);
    address constant NEWMGR   = address(0x4002);

    address constant TOK_A    = address(0x1111);
    address constant TOK_B    = address(0x2222);
    address constant HOOK     = address(0x6001);
    address constant BRIDGE   = address(0x7001);
    address constant BRIDGE2  = address(0x7002);

    /// Hub:381 `_auth` and Hub:382 `_ne0` / Hub:443 `whenLive` codes, pinned
    /// here so a renumbering of the error table breaks this file loudly.
    function _e(uint16 code) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(BlazePhoenixHub.HubE.selector, code);
    }

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), MGR);
        // The router seat is a DISTINCT address on purpose. Most Hub tests wire
        // it to address(this), which makes "the router may call recordSwap"
        // indistinguishable from "the admin may call recordSwap" - and the
        // second is false. Keeping them apart is what makes the ordering test
        // in section 5 measure the router door and not the admin seat.
        hub.setRoles(ROUTER, SOLVER, QUOTER);
    }

    // =========================================================================
    //  1. onlyAdmin  (Hub:434) - the curator seat that survives renunciation
    //
    //  REMOVED BY THE RECHECK (duplicate): StrangerCannotAddBridge, already
    //  pinned by test/HubRefusalsObserved.t.sol:338
    //  test_Auth_PrivilegedDoorsRefuseAStranger. The "onlyAdmin deleted" mutant
    //  now names the renunciation test below, which is the door nothing in the
    //  suite pranks.
    // =========================================================================

    /// CLAIM: a stranger cannot spend the protocol's one irreversible power.
    /// GREEN today.
    /// SEVERITY: `renounceControl` is permanent. A stranger who could call it
    /// would freeze setRoles/setOperator/setPaused/setV4Manager/removeBridge
    /// for ever - the "permanent freeze" row of SECURITY.md - with no recovery
    /// path in the contract.
    /// NOT VACUOUS: the observable is not the revert but the CONTROL PLANE
    /// STILL BEING ALIVE afterwards, proven by a control-only call succeeding.
    /// KILLED BY: mutants "onlyAdmin - the identity check is gone" and
    /// "renounceControl loses onlyAdmin".
    function test_Authority_OnlyAdmin_StrangerCannotRenounceControl() public {
        bytes memory e1 = _e(1);

        vm.prank(STRANGER);
        vm.expectRevert(e1);
        hub.renounceControl();

        // If the stranger had renounced, this onlyControl call would revert.
        hub.setV4Manager(NEWMGR);
        assertEq(hub.v4PoolManager(), NEWMGR,
            "the control plane is still alive: the stranger did not renounce it");
    }

    /// CLAIM: after renunciation the seat is STILL admin-only on the one arm
    /// the body itself never refuses. `allowHook(h, false)` dies in the body
    /// after renounce for everyone (Hub:488), so on that arm the modifier is
    /// masked: a stranger and the admin are refused alike, and nothing
    /// observable tells the two refusals apart. (The gas ordering an earlier
    /// version of this test measured did not either: the admin's call warms
    /// what the stranger's call then reads, so the two were ordered for a
    /// reason unrelated to the modifier, and the "onlyAdmin gone" mutant
    /// survived it - recorded on 2026-09-03.) The `ok == true` arm is the
    /// UNMASKED one: the body accepts it after renunciation, because admission
    /// is the power that survives, so the modifier is the only thing between
    /// a stranger and the hook allow-list of a registry nobody can pause.
    /// GREEN today.
    /// SEVERITY: the allow-list is the gate of the hooked V4 subset, and after
    /// renunciation there is no pause left to answer an admission the operator
    /// never made.
    /// NOT VACUOUS: the identical call from the admin succeeds right after, so
    /// the stranger's refusal is the modifier's and not the body's.
    /// KILLED BY: mutant "onlyAdmin gone - a stranger may admit a hook after
    /// renunciation".
    function test_Authority_OnlyAdmin_StrangerCannotAdmitAHookAfterRenounce() public {
        vm.etch(HOOK, hex"fe");
        hub.renounceControl();

        vm.prank(STRANGER);
        vm.expectRevert(_e(1));
        hub.allowHook(HOOK, true);
        assertFalse(hub.isHookLive(HOOK), "the stranger's admission must not have landed");

        hub.allowHook(HOOK, true);
        assertTrue(hub.isHookLive(HOOK),
            "the admin's admission still lands: the seat survives, the stranger does not sit in it");
    }

    // =========================================================================
    //  2. onlyControl  (Hub:436) - two sub-conditions, tested one at a time
    //
    //  REMOVED BY THE RECHECK (duplicates):
    //    StrangerCannotSetV4Manager        -> test/UntestedSurface.t.sol:103
    //                                         test_SetV4Manager_OnlyControl_AndTakesEffect
    //    AdminMaySetV4ManagerBeforeRenounce -> the same test's second half, and
    //                                         the first two lines of the test
    //                                         immediately below.
    //  The identity-arm mutant now names StrangerCannotSetPaused, which is in
    //  this file and dies to it for the same reason (a stranger who passes the
    //  arm freezes the registry and the recordSwap that follows reverts).
    // =========================================================================

    /// CLAIM (second sub-condition, `!$.controlRenounced`): after renunciation
    /// even the ADMIN cannot repoint the V4 singleton. This is the arm that
    /// makes onlyControl different from onlyAdmin, and nothing tested it.
    /// GREEN today.
    /// NOT VACUOUS: the same caller, the same arguments, succeed before the
    /// renunciation and are refused after it - the only thing that changed is
    /// the bit the second arm reads. The closing `addBridge` line proves the
    /// caller did not lose the admin seat, so the refusal cannot be the first
    /// arm firing.
    /// KILLED BY: mutants "onlyControl: the renunciation arm is gone" and
    /// "setV4Manager loses its modifier".
    function test_Authority_SetV4Manager_RenouncedAdminCannotRepointTheSingleton() public {
        bytes memory e1 = _e(1);

        hub.setV4Manager(NEWMGR);
        assertEq(hub.v4PoolManager(), NEWMGR, "before renunciation the admin may move the singleton");

        hub.renounceControl();

        vm.expectRevert(e1);
        hub.setV4Manager(MGR);
        assertEq(hub.v4PoolManager(), NEWMGR, "after renunciation the singleton is frozen");

        // The caller is still the admin - proven by a CURATOR power, which
        // renunciation is documented to keep (Hub:408-415). Without this the
        // refusal above could be read as "this caller stopped being admin".
        hub.addBridge(BRIDGE);
        assertTrue(hub.isBridgeToken(BRIDGE),
            "the refusal was the renunciation arm, not a lost admin seat");
    }

    /// CLAIM: the emergency switch is control-plane only.
    /// GREEN today.
    /// NOT VACUOUS: `setPaused`'s body is a single assignment plus an event -
    /// no revert - and the observable is that the hub was never actually
    /// paused, proven by the router recording a swap right afterwards. If the
    /// modifier were gone the stranger would freeze the registry and that
    /// recordSwap would revert HubE(2).
    /// KILLED BY: mutant "onlyControl: the whole guard is gone".
    function test_Authority_OnlyControl_StrangerCannotSetPaused() public {
        address pool = address(new MockV2Pair(TOK_A, TOK_B));
        bytes32 key  = hub.keyOf(pool, TOK_A, TOK_B);
        bytes memory e1 = _e(1);

        vm.prank(STRANGER);
        vm.expectRevert(e1);
        hub.setPaused(true);

        vm.prank(ROUTER);
        hub.recordSwap(pool, BPC.KIND_V2, 30, address(0), TOK_A, TOK_B, 1e18, 1e18, 1e18);
        assertEq(BPC.decodeSwapCount(hub.getSlot(key)), 1,
            "the hub was never paused: the stranger's freeze was refused");
    }

    // =========================================================================
    //  3. onlyOperator  (Hub:441) - a disjunction, one arm at a time
    //  4. onlyRouter  (Hub:442) - the only writer of swap-driven registry state
    //
    //  THESE TWO SECTIONS HOLD NO TEST ON PURPOSE. The recheck of 2026-09-03
    //  found that every test drafted here already existed in the suite, so the
    //  mutants below name the existing test instead of a fresh copy of it. What
    //  this cluster was missing was never the tests - it was the ENTRIES:
    //
    //    onlyOperator, whole guard deleted
    //        -> test/BlazePhoenixHub.t.sol:214 test_SeedPool_OnlyOperator
    //    onlyOperator, operator-map arm deleted
    //        -> test/UntestedSurface.t.sol:78 test_SetOperator_OnlyControl_AndGrantsSeedPool
    //           (it also covers the revocation half)
    //    onlyOperator, admin arm deleted
    //        -> test/ConditionAdequacyHub.t.sol:160
    //           test_L432_AdminWhoIsNotOperator_StillPassesOperatorDoor
    //    onlyRouter, identity check deleted
    //        -> test/BlazePhoenixHub.t.sol:229 test_RecordSwap_OnlyRouter
    //           (it repoints $.router to 0xF00D and calls as the admin - the
    //           same discrimination the deleted AdminIsNotTheRouter made)
    //           and, for the ORDERING claim, section 5's test below.
    //    "the wired router really can record"
    //        -> test/BlazePhoenixHub.t.sol:241
    //           test_RecordSwap_NewPoolRegistersThenTicksOnNextCall
    // =========================================================================

    // =========================================================================
    //  5. whenLive  (Hub:443) - the emergency switch on the only surface it guards
    //
    //  REMOVED BY THE RECHECK (duplicate): PausedHubRefusesRecordSwap, already
    //  pinned by test/BlazePhoenixHub.t.sol:235 test_RecordSwap_RevertsWhenPaused,
    //  which both whenLive mutants now name. What stays here is the half the
    //  suite did NOT have: the pause is a switch and not a tombstone, and the
    //  two modifiers fire in declaration order.
    // =========================================================================

    /// CONTROL, must stay green after any fix: the pause is a switch, not a
    /// tombstone. Unpausing restores recording for the same caller and the same
    /// pool.
    function test_Authority_WhenLive_UnpausingRestoresRecording() public {
        address pool = address(new MockV2Pair(TOK_A, TOK_B));
        bytes32 key  = hub.keyOf(pool, TOK_A, TOK_B);

        hub.setPaused(true);
        hub.setPaused(false);

        vm.prank(ROUTER);
        hub.recordSwap(pool, BPC.KIND_V2, 30, address(0), TOK_A, TOK_B, 1e18, 1e18, 1e18);

        assertEq(BPC.decodeSwapCount(hub.getSlot(key)), 1,
            "unpausing must restore the learning path, not leave it dead");
    }

    /// CLAIM: the two modifiers on `recordSwap` fire in declaration order -
    /// `onlyRouter` first, `whenLive` second (Hub:1474).
    /// GREEN today.
    /// WHY IT MATTERS: the ordering is what stops the pause flag from being a
    /// side channel. If `whenLive` ran first, any caller could probe the hub's
    /// paused state by the error code it gets back; more importantly, a future
    /// reorder would let an unauthorized caller receive HubE(2) - a refusal
    /// that reads as "temporarily closed" rather than "you are not the router",
    /// and refusal codes are what the Router branches on.
    /// NOT VACUOUS: it asserts the SPECIFIC code, not merely that it reverted.
    /// Delete `onlyRouter`'s check and the stranger gets HubE(2) instead of
    /// HubE(1) and this test fails.
    /// KILLED BY: mutant "onlyRouter: the identity check is gone".
    function test_Authority_ModifierOrder_AuthCodeWinsOverThePauseCode() public {
        address pool = address(new MockV2Pair(TOK_A, TOK_B));
        bytes memory e1 = _e(1);

        hub.setPaused(true);

        vm.prank(STRANGER);
        vm.expectRevert(e1);
        hub.recordSwap(pool, BPC.KIND_V2, 30, address(0), TOK_A, TOK_B, 1e18, 1e18, 1e18);
    }

    // =========================================================================
    //  6. initialize  (Hub:396) - one compound guard, two independent arms
    //
    //  REMOVED BY THE RECHECK (duplicates):
    //    OnlyTheConstructorAdminMayInitialize -> test/BlazePhoenixHub.t.sol:345
    //                                            test_Initialize_RevertsWhenCalledByNonDeployer
    //    CannotBeCalledTwice                  -> test/BlazePhoenixHub.t.sol:340
    //                                            test_Initialize_RevertsOnSecondCall
    //  Both existing tests isolate the arm the mutant neutralises (that file's
    //  `admin` IS address(this), so the caller arm is false in the second-call
    //  test and the initialized arm is false in the fresh-hub test), so the two
    //  arm-level mutants name them directly.
    // =========================================================================

    /// CLAIM: `_ne0(admin_)` runs AFTER the authority check, and answers with a
    /// DIFFERENT code (HubE(3)).
    /// GREEN today.
    /// WHY IT IS HERE: it is the cheap discriminator that makes the two tests
    /// above readable. Two guards in one function sharing one code is the
    /// pattern that produced this repo's documented false greens; here the
    /// third guard has its own code, and pinning that fact stops a future
    /// "unify the error codes" cleanup from silently merging them.
    /// NOT VACUOUS: it asserts code 3, not merely a revert.
    function test_Authority_Initialize_ZeroAdminIsRefusedWithItsOwnCode() public {
        BlazePhoenixHub fresh = new BlazePhoenixHub(address(this));
        bytes memory e3 = _e(3);

        vm.expectRevert(e3);
        fresh.initialize(address(0), MGR);
    }

    /// CONTROL, must stay green after any fix: initialize really hands the
    /// registry over. The deployer seat is spent, the named admin holds the
    /// curator power, and the V4 singleton is the one that was passed in.
    /// This is the "a fix must not buy the negatives with new rigidity" half:
    /// a stricter initialize that refused a legitimate hand-over would break
    /// here.
    function test_Authority_Initialize_HandsTheRegistryToTheNamedAdmin() public {
        BlazePhoenixHub fresh = new BlazePhoenixHub(address(this));
        bytes memory e1 = _e(1);

        fresh.initialize(NEWADMIN, MGR);
        assertEq(fresh.v4PoolManager(), MGR, "the singleton passed in is the one seated");

        vm.prank(NEWADMIN);
        fresh.addBridge(BRIDGE);
        assertTrue(fresh.isBridgeToken(BRIDGE), "the named admin holds the curator power");

        // The deployer's seat was spent by the hand-over.
        vm.expectRevert(e1);
        fresh.addBridge(BRIDGE2);
        assertEq(fresh.bridgeCount(), 1, "the deployer is no longer the admin");
    }

    // =========================================================================
    //  7. Cross-cutting controls - the promises a fix here must not break
    //
    //  BOTH CONTROLS DRAFTED HERE WERE REMOVED BY THE RECHECK OF 2026-09-03, as
    //  duplicates. They are not lost, only re-homed:
    //
    //    "the curator powers survive renunciation"
    //        -> test/BlazePhoenixHub.t.sol:64 test_RenounceControl_LeavesCuratorPowersAvailable
    //           and :77 test_RenounceControl_AddBridgeAndAddFactoryStillWork
    //    "an operator granted before renunciation may still seed after it"
    //        -> C5's test_AfterRenounce_TheOperatorGrantIsPermanent, which is
    //           strictly stronger: it also pins that setOperator can never
    //           revoke the grant again. C5 owns the normative question and this
    //           file must not own it twice.
    //
    //  The controls that remain in this file are the in-section ones:
    //  UnpausingRestoresRecording (section 5) and
    //  Initialize_HandsTheRegistryToTheNamedAdmin (section 6).
    // =========================================================================
}
