// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  C4 - the T19 RE-ADMISSION edge: addFactory called TWICE on an Algebra-mode
//  factory whose poolDeployer() answer moved between the two calls.
//
//  WHAT T19 BOUGHT. Hub:690-692 freezes the Algebra CREATE2 origin at
//  admission:
//
//      if (mode == MODE_CREATE2_V3) {
//          $.factoryDeployer[factory] = BPC.resolvePoolDeployer(factory);
//      }
//
//  and Hub:962-967 derives mode-5 fee-0 probes from that attested value
//  instead of asking the factory live. The stated guarantee is that the one
//  derive input a factory could still steer after admission is no longer live.
//
//  WHAT THIS FILE IS ABOUT. `addFactory` is a CURATOR power: `onlyAdmin`, and
//  `renounceControl()` deliberately keeps it alive (Hub:408-416). Every call
//  re-executes the write above unconditionally. So a SECOND admission of an
//  already-admitted factory re-attests whatever the factory answers at that
//  moment, and the mapping is keyed by factory ADDRESS - it is shared by every
//  row of that factory, including the row admitted before the answer moved.
//  The attestation is therefore not a pin against the factory; it is a pin
//  against TIME, re-openable by a call that survives renunciation.
//
//  THE NAMED PROPERTY these tests are tied to (no orphan security logic):
//
//      C4-P1  ATTESTATION MONOTONICITY OF THE ALGEBRA ORIGIN.
//             A second `addFactory` on an already-admitted mode-5 factory must
//             never leave any of that factory's rows deriving from an origin
//             the operator did not attest, and must never leave them deriving
//             from NO attestation at all (a zero pin, which Hub:963 degrades to
//             `orig = fac.factory` and which darkens every Algebra pool of that
//             factory permanently, since there is no removeFactory and every
//             later re-admission re-resolves to the same zero).
//
//  THE SIBLING THAT WAS ALREADY FIXED. `allowHook` (Hub:488-496) is the same
//  shape and was closed hours ago: after renunciation, re-listing an
//  already-listed hook whose runtime moved is REFUSED, while re-listing an
//  UNCHANGED hook still works. `addFactory` is the untreated twin of that fix
//  for the deployer attestation. This file does not write the fix. It writes
//  the tests that decide whether one is needed, and it deliberately keeps the
//  "unchanged answer is still accepted" arm green so that no fix can buy the
//  property with a blanket ban on re-admission.
//
//  VERDICT PER TEST, against main @ 6438fe4, decided by reading the code path
//  (nothing in that pass was compiled or run). THE FIX LANDED on 2026-09-03:
//  after renunciation the attested origin is frozen, a dead resolver never
//  demotes it to zero, and (cluster C3) one address owns one row, refreshed in
//  place - the non-mode-5 test below was rewritten for that shape.
//
//    test_C4_ReAdmit_AfterRenounce_MustNotFollowTheLiveAnswer      RED   then, GREEN since the fix
//    test_C4_ReAdmit_WithDeadResolver_MustNotDemoteToZero          RED   then, GREEN since the fix
//    test_C4_ReAdmit_UnderANonMode5Row_LeavesThePinIntact          GREEN today
//    test_C4_ReAdmit_UnchangedAnswer_AfterRenounce_IsAccepted      GREEN today
//    test_C4_DiscoveryNeverRevertsAfterAnyReAdmission              GREEN today
//
//  Two further GREEN tests were drafted and then REMOVED by the recheck of
//  2026-09-03 as duplicates of test/T19AlgebraDeployerPin.t.sol; the banner
//  where they stood records what covers them and, more importantly, the
//  constraint that existing file places on the fix. Read it before writing one.
//
//  The two RED ones are wrapped in try/catch around `addFactory`, so they stay
//  valid whichever fix shape the owner picks: a refusal (the allowHook shape)
//  and a silent keep-the-first-attestation both satisfy them. The three GREEN
//  ones are the controls that must survive any fix.
//
//  Expected addresses come from an INDEPENDENT inline CREATE2 formula over
//  literal constants - never from asking the code under test what it would
//  derive.
//
//  forge test --match-contract T19ReadmissionEdge -vv
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixCore as BPC, PoolInfo} from "../src/BlazePhoenixCore.sol";

/// @dev Proxy-shaped factory, the EIP-1967 threat model of the T19 report: the
///      runtime code - and therefore the codehash - NEVER changes; only the
///      answer does. `poolDeployer()` is the selector Core resolves (0x3119049a).
///      `setAnswers(false)` makes the getter revert, which is what
///      `BPC.resolvePoolDeployer` reads as "no answer" (it returns address(0)).
contract ReAdmitDeployerFactory {
    address internal dep;
    bool    internal answers = true;

    constructor(address d) { dep = d; }

    function setPoolDeployer(address d) external { dep = d; }
    function setAnswers(bool ok) external { answers = ok; }

    function poolDeployer() external view returns (address) {
        require(answers, "no deployer");
        return dep;
    }
}

contract T19ReadmissionEdgeTest is Test {
    BlazePhoenixHub internal hub;
    ReAdmitDeployerFactory internal fac;

    // Sorted bare-address tokens (house style): tokenA < tokenB. Discovery
    // never calls the tokens, so they need no code.
    address constant tokenA = address(0x2222);
    address constant tokenB = address(0x3333);

    // The origin attested at the FIRST admission, and the one the factory
    // starts answering afterwards.
    address constant DEP_ATTESTED = address(0xA77E57ED);
    address constant DEP_SWAPPED  = address(0xBAD0DE99);
    // The attested origin of a SECOND, healthy factory, used only by the
    // liveness test: it is the pair-mate whose discovery must survive another
    // factory's dependency dying.
    address constant DEP_HEALTHY  = address(0x11EA1747);

    // Hub-internal constants, pinned here by value on purpose: if either moves
    // in the Hub, these tests must be revisited rather than silently follow.
    uint8   constant MODE_CREATE2_V3 = 5;
    uint8   constant MODE_CREATE2_V2 = 4;
    bytes32 constant INIT_HASH = keccak256("c4-algebra-init");

    uint24[] internal noFees;
    int24[]  internal noSpacings;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0xD00D));
        fac = new ReAdmitDeployerFactory(DEP_ATTESTED);
    }

    // --- oracle and helpers (no cheatcode inside them) --------------------

    /// Independent oracle: the consensus CREATE2 formula with the Algebra salt
    /// keccak(abi.encode(t0, t1)) - no fee component. Written from literals so
    /// the object under test is never its own oracle.
    function _algebraPool(address origin) private pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(
            hex"ff", origin, keccak256(abi.encode(tokenA, tokenB)), INIT_HASH
        )))));
    }

    /// The V2-salt derivation of the same factory: keccak(packed(t0, t1)),
    /// origin = the factory itself (mode 4 never consults poolDeployer()).
    function _v2SaltPool(address origin) private pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(
            hex"ff", origin, keccak256(abi.encodePacked(tokenA, tokenB)), INIT_HASH
        )))));
    }

    function _admitAlgebra() private {
        hub.addFactory(
            address(fac), BPC.KIND_ALGEBRA, MODE_CREATE2_V3, INIT_HASH, noFees, noSpacings
        );
    }

    function _assertOnlyCandidateIs(address expected, string memory why) private view {
        PoolInfo[] memory hits = hub.discoverFor(tokenA, tokenB);
        assertEq(hits.length, 1, why);
        assertEq(hits[0].pool, expected, why);
    }

    function _assertNeverServes(address forbidden, string memory why) private view {
        PoolInfo[] memory hits = hub.discoverFor(tokenA, tokenB);
        for (uint256 i; i < hits.length; ++i) assertTrue(hits[i].pool != forbidden, why);
    }

    /// Membership, not count: used where a fix may legitimately change how many
    /// candidates exist but never whether a healthy factory's pool is among them.
    function _serves(address pool) private view returns (bool) {
        PoolInfo[] memory hits = hub.discoverFor(tokenA, tokenB);
        for (uint256 i; i < hits.length; ++i) if (hits[i].pool == pool) return true;
        return false;
    }

    // =========================================================================
    //  BASELINE and POSITIVE ARM - REMOVED BY THE RECHECK OF 2026-09-03, both
    //  as duplicates of test/T19AlgebraDeployerPin.t.sol, which is the file
    //  this harness was modelled on:
    //
    //    test_C4_Baseline_FirstAdmissionServesTheAttestedPool
    //        -> its `_admitAlgebra` + test_T19_AnswerSwap_DerivesFromAttestedDeployer
    //           already establish that a single admission serves the pool
    //           CREATE2-derived from the attested origin.
    //    test_C4_ReAdmit_ControlLive_NeverDarkensTheFactory
    //        -> test/T19AlgebraDeployerPin.t.sol:234
    //           test_T19_ReAdmission_ReAttestsTheCurrentAnswer is the same
    //           scenario asserted MORE strictly (it pins hits[0].pool == poolNew
    //           exactly, where the drafted version accepted either origin), and
    //           its docstring calls the behaviour "by design".
    //
    //  THE CONSEQUENCE THAT MUST TRAVEL WITH THE FIX, and which the drafts did
    //  not record: that existing test is NOT try/catch-tolerant. Any fix that
    //  makes re-admission keep the first attestation UNCONDITIONALLY turns
    //  test_T19_ReAdmission_ReAttestsTheCurrentAnswer red and breaks the 915/915
    //  suite. The fix has to be scoped - either to `controlRenounced` (the
    //  allowHook shape) or to the zero-demotion case (the resolver answered 0).
    //  The two RED tests below are separable exactly along that line, which is
    //  what makes both scopings viable.
    // =========================================================================

    // =========================================================================
    //  C4-P1, NEGATIVE ARM #1 - RED before the fix of 2026-09-03. The allowHook sibling.
    // =========================================================================

    /// CLAIM: after `renounceControl()` there is no control-plane response left
    /// (Hub:408-416 says so, and `allowHook` was closed on exactly that
    /// argument at Hub:496). The surviving curator lever must therefore not
    /// double as the cancel button of the T19 attestation: re-admitting a
    /// factory whose poolDeployer() answer MOVED since admission must not hand
    /// the derivation back to the live answer.
    ///
    /// RED before the fix: `addFactory` survives renunciation, re-executes Hub:691
    /// unconditionally, and `factoryDeployer[fac]` becomes DEP_SWAPPED for the
    /// pre-renounce row as well as the new one. Discovery then serves the pool
    /// the factory steered to, and the honestly attested pool stops being
    /// served entirely.
    ///
    /// Not vacuous: the pool at the attested origin still has code throughout,
    /// so its disappearance from the hit set is a real behavioural change and
    /// not an artefact of `hasCode`. The factory's codehash never moves, so no
    /// codehash pin - present or future - can account for the result.
    ///
    /// try/catch: a fix that REFUSES the re-admission and a fix that accepts it
    /// while keeping the first attestation both satisfy this test.
    function test_C4_ReAdmit_AfterRenounce_MustNotFollowTheLiveAnswer() public {
        _admitAlgebra();
        address poolHonest  = _algebraPool(DEP_ATTESTED);
        address poolSteered = _algebraPool(DEP_SWAPPED);
        vm.etch(poolHonest, hex"fe");
        _assertOnlyCandidateIs(poolHonest, "control: the attested origin governs before renouncing");

        hub.renounceControl();

        bytes32 chBefore = address(fac).codehash;
        fac.setPoolDeployer(DEP_SWAPPED);
        assertEq(address(fac).codehash, chBefore, "premise: a codehash pin sees nothing here");
        vm.etch(poolSteered, hex"fe");

        try hub.addFactory(
            address(fac), BPC.KIND_ALGEBRA, MODE_CREATE2_V3, INIT_HASH, noFees, noSpacings
        ) returns (uint8) {
            _assertOnlyCandidateIs(
                poolHonest,
                "after renouncing, re-admission must not move the attested Algebra origin"
            );
        } catch {
            _assertOnlyCandidateIs(
                poolHonest, "a refused re-admission must leave the attested origin serving"
            );
        }
        _assertNeverServes(poolSteered, "the steered derivation must never become a candidate");
    }

    // =========================================================================
    //  C4-P1, NEGATIVE ARM #2 - RED before the fix of 2026-09-03. The demotion to no attestation.
    // =========================================================================

    /// CLAIM: a second admission must not replace a GOOD attestation with a
    /// zero one. Core:528-532 records that this exact outcome - the attested
    /// origin falling back to the factory and "every Algebra pool of that
    /// factory going dark" - is a failure this codebase already paid to fix
    /// once, at the returndata-policy level. Re-admission re-opens it from the
    /// other side: the write at Hub:691 is unconditional, so a factory whose
    /// resolver has since died attests address(0), Hub:963 degrades that to
    /// `orig = fac.factory`, and the previously served pools stop being
    /// derived. It is unrecoverable: there is no removeFactory, and every
    /// further re-admission resolves to the same zero.
    ///
    /// This one is renunciation-INDEPENDENT: it is written with control still
    /// live, so a fix scoped only to `controlRenounced` (the allowHook shape)
    /// does NOT close it. That is the point of writing it separately.
    ///
    /// RED before the fix: after the re-admission the hit set was empty.
    ///
    /// Not vacuous: the two assertions before the re-admission prove the pool
    /// was being served both with a live resolver AND with a dead one, so the
    /// only delta that can explain its disappearance is the re-admission's
    /// write.
    function test_C4_ReAdmit_WithDeadResolver_MustNotDemoteToZero() public {
        _admitAlgebra();
        address poolHonest = _algebraPool(DEP_ATTESTED);
        vm.etch(poolHonest, hex"fe");
        _assertOnlyCandidateIs(poolHonest, "control: the attested pool is served");

        // The resolver dies. The runtime code, and so the codehash, is
        // untouched - this is a state change inside the factory, not a
        // redeploy. The attestation already taken must carry the derivation.
        fac.setAnswers(false);
        _assertOnlyCandidateIs(
            poolHonest, "control: T19 already keeps this pool served with a dead resolver"
        );

        try hub.addFactory(
            address(fac), BPC.KIND_ALGEBRA, MODE_CREATE2_V3, INIT_HASH, noFees, noSpacings
        ) returns (uint8) {
            _assertOnlyCandidateIs(
                poolHonest,
                "re-admission must not demote a good attestation to a zero one"
            );
        } catch {
            _assertOnlyCandidateIs(
                poolHonest, "a refused re-admission must leave the good attestation in place"
            );
        }
    }

    // =========================================================================
    //  CONTROLS the fix must not break.
    // =========================================================================

    /// CLAIM: the pin write is gated on MODE, not on kind, and that gate is
    /// load-bearing: re-admitting the same factory address under a mode that
    /// never enters the Algebra derive must leave the existing attestation
    /// exactly as it was.
    ///
    /// REWRITTEN WITH THE FIX OF 2026-09-03 (cluster C3): `addFactory` now
    /// keeps ONE row per address and refreshes it in place, so the earlier
    /// shape of this test - "a second row in the V2 slot next to the Algebra
    /// row" - no longer exists. The attestation is keyed by address and
    /// survives the refresh; what the test has to prove is that the mode-4
    /// refresh did not TOUCH it. The pin is not readable from outside, so it is
    /// made observable through the derive: the resolver is killed (a dead
    /// resolver can never re-attest, C4) and the row is put back in the Algebra
    /// slot, at which point whatever the pin holds is what discovery derives
    /// from - the attested origin if the mode gate held, the swapped one if
    /// the mode-4 refresh had been allowed to re-attest.
    ///
    /// GREEN today. Mutant C4-M1 (drop the `mode == MODE_CREATE2_V3` gate on
    /// the pin write) turns this red: the mode-4 refresh re-attests
    /// DEP_SWAPPED while the resolver is still alive, the dead-resolver
    /// re-admission cannot undo it, and the steered pool is served.
    ///
    /// Not vacuous: a pool exists at BOTH derivations, so if the pin moved the
    /// assertion would see the steered pool rather than simply seeing nothing.
    function test_C4_ReAdmit_UnderANonMode5Row_LeavesThePinIntact() public {
        _admitAlgebra();
        address poolHonest  = _algebraPool(DEP_ATTESTED);
        address poolSteered = _algebraPool(DEP_SWAPPED);
        vm.etch(poolHonest, hex"fe");
        vm.etch(poolSteered, hex"fe");
        fac.setPoolDeployer(DEP_SWAPPED);

        // The SAME factory address, refreshed into the V2 CREATE2 slot. Mode 4
        // derives keccak(packed(t0, t1)) from the factory itself and never
        // consults poolDeployer(); nothing is deployed there.
        uint8 row = hub.addFactory(
            address(fac), BPC.KIND_V2, MODE_CREATE2_V2, INIT_HASH, noFees, noSpacings
        );
        assertEq(row, 0, "premise: the row is refreshed in place, not duplicated");
        assertFalse(
            _v2SaltPool(address(fac)).code.length > 0,
            "premise: the V2-salt derivation of this factory is empty"
        );
        assertFalse(_serves(poolHonest), "premise: under the mode-4 row the Algebra derive is idle");

        // Kill the resolver, then put the row back in the Algebra slot: with no
        // live answer the re-admission cannot re-attest, so the derive below
        // reads exactly what the mode-4 refresh left in the pin.
        fac.setAnswers(false);
        hub.addFactory(
            address(fac), BPC.KIND_ALGEBRA, MODE_CREATE2_V3, INIT_HASH, noFees, noSpacings
        );
        _assertOnlyCandidateIs(
            poolHonest, "a non-mode-5 re-admission must leave the Algebra attestation untouched"
        );
        _assertNeverServes(poolSteered, "the steered derivation must never become a candidate");
    }

    /// CLAIM (anti-rigidity): re-admitting a factory whose answer has NOT moved
    /// must keep working, including after renunciation - exactly as `allowHook`
    /// kept "re-listing an unchanged hook still works" alive next to its
    /// refusal. A fix for the two RED tests above must not become a blanket ban
    /// on re-admission, which would strand the operator gesture the registry
    /// depends on (re-adding a factory to widen its fee list).
    ///
    /// GREEN today, and deliberately NOT wrapped in try/catch: a refusal here
    /// is a failure, which is the whole point. Mutant C4-M2 (refuse every
    /// re-admission after renunciation) turns it red.
    function test_C4_ReAdmit_UnchangedAnswer_AfterRenounce_IsAccepted() public {
        _admitAlgebra();
        address poolHonest = _algebraPool(DEP_ATTESTED);
        vm.etch(poolHonest, hex"fe");

        hub.renounceControl();

        // Same address, same answer, same mode: nothing about the dependency
        // has moved, so nothing may refuse it.
        hub.addFactory(
            address(fac), BPC.KIND_ALGEBRA, MODE_CREATE2_V3, INIT_HASH, noFees, noSpacings
        );

        _assertOnlyCandidateIs(
            poolHonest, "re-admitting an unchanged factory must stay possible after renouncing"
        );
    }

    /// CLAIM: whatever the re-admission does to the attestation, discovery
    /// fails CLOSED and never REVERTS. One stale or zeroed dependency may stop
    /// producing candidates; it may never brick `discoverFor` for the pairs
    /// every other factory still serves. This is the same guarantee
    /// `FactoryCodehashPin.t.sol` pins for the codehash arm.
    ///
    /// GREEN today (the zero pin degrades to `orig = fac.factory` and simply
    /// finds no code). It guards against a fix that reverts on a stale pin.
    ///
    /// REPAIRED 2026-09-03 (VACUOUS as drafted). The drafted assertion was
    /// `assertTrue(hits.length <= 1)`, which is true on the broken tree, the
    /// fixed tree and the zero-pin tree alike: one factory address yields one
    /// derived origin and `_probe` dedups (Hub:973-978). Only the absence of a
    /// revert carried meaning, so a green stated no behaviour.
    ///
    /// WHY NOT THE FORM THE LENS PROPOSED. One recheck offered
    /// `if (accepted) assertEq(hits.length, 0) else assertEq(hits.length, 1)`.
    /// That would be green today and PERMANENTLY RED under the very fix the two
    /// RED tests above ask for: a fix that accepts the call but keeps the first
    /// attestation leaves `accepted == true` AND one hit, so the zero branch
    /// fails for ever. It is the same hazard the recheck rejected in C3, in the
    /// opposite direction.
    ///
    /// WHAT IT ASSERTS INSTEAD - the claim the docstring always made and the
    /// draft never tested: a SECOND, healthy factory on the same pair keeps
    /// being discovered after the first factory's resolver dies. That can fail
    /// today (a revert, or a scan that abandons the loop on a dead dependency,
    /// takes the healthy pool with it) and it is green under every admissible
    /// fix, because no fix scoped to the sick factory can darken a healthy one.
    /// The count is deliberately NOT asserted: a fix that keeps the sick
    /// factory serving its first attestation legitimately makes it two.
    function test_C4_DiscoveryNeverRevertsAfterAnyReAdmission() public {
        _admitAlgebra();
        vm.etch(_algebraPool(DEP_ATTESTED), hex"fe");

        ReAdmitDeployerFactory healthy = new ReAdmitDeployerFactory(DEP_HEALTHY);
        hub.addFactory(
            address(healthy), BPC.KIND_ALGEBRA, MODE_CREATE2_V3, INIT_HASH, noFees, noSpacings
        );
        address poolHealthy = _algebraPool(DEP_HEALTHY);
        vm.etch(poolHealthy, hex"fe");
        assertTrue(_serves(poolHealthy),
            "control: the healthy factory serves before the other one falls ill");

        fac.setAnswers(false);
        try hub.addFactory(
            address(fac), BPC.KIND_ALGEBRA, MODE_CREATE2_V3, INIT_HASH, noFees, noSpacings
        ) returns (uint8) {
            // accepted
        } catch {
            // refused
        }

        // Liveness: this call must RETURN. Attribution: it must still carry the
        // healthy factory's pool.
        assertTrue(_serves(poolHealthy),
            "a dead resolver on ONE factory must not stop another factory's pool being discovered");
    }
}
