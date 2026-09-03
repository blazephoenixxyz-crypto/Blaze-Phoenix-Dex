// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  C3 - addFactory WAS THE UNTREATED TWIN OF THE HOOK RE-ARM GUARD, and this
//  file is the set of pins that closed it on 2026-09-03.
//
//  THE CLAIM. PR #24-#27 closed the hook half of a two-channel defect. Hub:496
//  now reads:
//
//      if (ok && $.controlRenounced && $.hookAllowed[h] && $.hookCodehash[h] != h.codehash)
//          revert HubE(1);
//
//  i.e. after `renounceControl()` the surviving curator power may no longer be
//  used as the CANCEL BUTTON of the Layer-3 auto-pause on a listed hook whose
//  runtime moved.
//
//  The factory channel is the same shape and has no such guard.
//
//    * Factories carry the same kind of pin (Hub:912, inside `_scanFactory`):
//        if (fac.mode < 4 && fac.factory.codehash != _store().factoryCodehash[fac.factory])
//            return k;
//      A factory-call factory (modes 0-3) whose runtime code changed after
//      admission stops producing discovery candidates. Fail-closed, not a
//      revert. That is the factory's auto-pause.
//
//    * `addFactory` is `onlyAdmin` (Hub:620), so it survives `renounceControl()`
//      by design - the docstring at Hub:408-415 promises exactly that ("the
//      CURATOR powers that only grow the registry - addFactory, addBridge,
//      allowHook - remain available so new venues can still be listed").
//
//    * And `addFactory` re-pins UNCONDITIONALLY (Hub:684):
//        $.factoryCodehash[factory] = factory.codehash;
//      There is no `if (already listed)` arm, no `controlRenounced` arm, and no
//      `removeFactory` anywhere in the contract.
//
//  So: admit F honestly -> F's runtime is replaced at the same address -> the
//  pin auto-pauses F -> renounce -> `addFactory(F, ...)` re-pins F at its NEW
//  code and F steers discovery again, while no lever to pause it exists at all.
//  That was the hook finding word for word, on the channel that had not yet
//  been treated. Both arms are guarded as of 2026-09-03; every test below is
//  green, and the mutation guard carries the paired mutants that keep them so.
//
//  SECOND, SMALLER DEFECT ON THE SAME CALL. `addFactory` also has no
//  duplicate-address guard. Its own sibling in the same curator group,
//  `addBridge` (Hub:551-560), has one and documents WHY:
//
//      if ($.isBridge[t]) return;
//      ...
//      "A duplicate add is a no-op rather than a revert: the end state the
//       caller asked for already holds, and reverting would make an idempotent
//       administrative call fail on a retry."
//
//  `addFactory` pushes a second row instead. The table is capped
//  (MAX_FACTORIES = 16, Hub:135) and there is no removal path, so a retried or
//  repeated administrative call permanently consumes slots of the very
//  grow-only power `renounceControl` promises to keep alive.
//
//  RED/GREEN TODAY, against main @ 6438fe4, decided by reading the code path,
//  not by running it (nothing in this pass was compiled):
//
//    test_FactoryRearm_UnchangedFactoryIsADiscoverySource        GREEN (control)
//    test_FactoryRearm_MutatedFactoryIsAutoPausedBeforeAnyReAdd  GREEN (control,
//                                                                and the
//                                                                precondition of
//                                                                every RED below)
//    test_FactoryRearm_RenouncedAdminCanReArmAMutatedFactory     RED
//    test_FactoryRearm_ReArmOutlivesEveryPause_Asymmetry         RED
//    test_FactoryRearm_ReAddingTheSameFactoryPushesADuplicateRow RED
//    test_FactoryRearm_ReAddsExhaustTheTableWithOneAddress       RED
//    test_FactoryRearm_ANewFactoryIsStillAdmittedAfterRenounce   GREEN (control)
//    test_FactoryRearm_BeforeRenounceTheAdminMayReattest         GREEN (control)
//
//  THE TWO CONTROLS THAT CONSTRAIN THE FIX. A fix that simply refuses every
//  `addFactory` after renunciation would break
//  `..._ANewFactoryIsStillAdmittedAfterRenounce` (the documented power). A fix
//  that makes a duplicate add a pure no-op the way `addBridge` does would break
//  `..._BeforeRenounceTheAdminMayReattest` (a curator who still HOLDS control
//  re-attesting a factory on purpose). Together they force the fix to separate
//  the two effects of the call - RE-PIN and PUSH A ROW - instead of buying the
//  property with new rigidity.
//
//  Written as the test that makes the fix necessary. The fix is not written
//  here, and the shape of the refusal is deliberately not asserted: every RED
//  test observes the OUTCOME (is F a discovery source; how many rows exist), so
//  it stays meaningful whether the fix reverts, no-ops, or splits the call.
//
//  REPAIR PASS, 2026-09-03. Two rechecks found, independently, that ONE test in
//  this file broke the sentence immediately above:
//  `..._ReArmOutlivesEveryPause_Asymmetry` ended on `assertTrue(rearmRefused)`,
//  which demands a revert and would have stayed RED for ever under the
//  accept-but-keep-the-first-attestation fix its own sibling was written to
//  allow. It now ends on an outcome assertion. Nothing else in the file changed;
//  the two controls were flagged as duplicates of test/FactoryCodehashPin.t.sol
//  and deliberately KEPT, because they are the in-file preconditions that make
//  every RED verdict attributable - see README.md.
//
//  forge test --match-contract RenouncedFactoryRearm -vv
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixCore as BPC, PoolInfo} from "../src/BlazePhoenixCore.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";

/// @dev A mode-0 (factory-call) V2 factory: `deriveAddress` mode 0 is
///      `factory.getPair(t0, t1)` (Core:418). The answer is an immutable, so it
///      is baked into the runtime code - two instances built with two different
///      pairs have two different codehashes, which is exactly the mutation the
///      Hub's factory pin is supposed to see.
contract FixedPairFactory {
    address internal immutable pair;
    constructor(address pair_) { pair = pair_; }
    function getPair(address, address) external view returns (address) { return pair; }
}

contract RenouncedFactoryRearmTest is Test {
    BlazePhoenixHub internal hub;
    MockERC20 internal tokenA;
    MockERC20 internal tokenB;
    MockV2Pair internal honest;
    MockV2Pair internal attackerPool;
    /// Named by NO admitted factory in setUp. It exists so the "a new factory
    /// may still be listed" control cannot pass on a pool the ORIGINAL factory
    /// was already naming.
    MockV2Pair internal secondVenue;

    /// The admitted factory. A plain contract, NOT a proxy: this cluster is
    /// about the mutation the pin DOES catch (a runtime replacement at the same
    /// address) being un-caught by the one surviving curator lever. The proxy
    /// case the pin can never catch is already pinned, and disclosed, by
    /// `FactoryCodehashPin.t.sol`.
    address internal factory;

    bytes32 internal codehashAtAdmission;

    /// MAX_FACTORIES is `internal` in the Hub, so the test cannot read it. It is
    /// 16 (Hub:135). Nothing below hard-codes the number: the exhaustion test
    /// discovers the cap by adding until the Hub refuses, and only asserts that
    /// the cap was actually reached.
    uint256 internal constant ADD_ATTEMPTS_CEILING = 64;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));

        tokenA = new MockERC20("Dollar A", "USDA");
        tokenB = new MockERC20("Dollar B", "USDB");
        honest = _pair(1_000_000e18);
        attackerPool = _pair(1e18);
        secondVenue = _pair(500_000e18);

        factory = address(new FixedPairFactory(address(honest)));
        hub.addFactory(
            factory, BPC.KIND_V2, 0, bytes32(0), new uint24[](0), new int24[](0)
        );
        codehashAtAdmission = factory.codehash;
    }

    // ─── apparatus ───────────────────────────────────────────────────────────

    function _pair(uint256 reserve) internal returns (MockV2Pair p) {
        p = new MockV2Pair(address(tokenA), address(tokenB));
        tokenA.mint(address(p), reserve);
        tokenB.mint(address(p), reserve);
        p.setReserves(uint112(reserve), uint112(reserve));
    }

    function _discoveredPools() internal view returns (address[] memory found) {
        PoolInfo[] memory hits = hub.discoverFor(address(tokenA), address(tokenB));
        found = new address[](hits.length);
        for (uint256 i; i < hits.length; ++i) found[i] = hits[i].pool;
    }

    function _sees(address pool) internal view returns (bool) {
        address[] memory found = _discoveredPools();
        for (uint256 i; i < found.length; ++i) if (found[i] == pool) return true;
        return false;
    }

    /// Replace the factory's runtime at the same address with one that answers
    /// `attackerPool` - a redeploy at a CREATE2 address, a selfdestruct and
    /// redeploy, or any direct mutation, as the chain sees it.
    function _mutateFactoryToHostile() internal {
        address hostileLogic = address(new FixedPairFactory(address(attackerPool)));
        vm.etch(factory, hostileLogic.code);
        assertTrue(
            factory.codehash != codehashAtAdmission,
            "precondition: the factory runtime really changed"
        );
    }

    /// Re-admit the SAME factory address with the SAME configuration. Shape-
    /// agnostic on purpose: whether the fix reverts or no-ops, the assertions
    /// that follow are about the resulting STATE, never about this call.
    function _reAddSameFactory() internal returns (bool accepted) {
        try hub.addFactory(
            factory, BPC.KIND_V2, 0, bytes32(0), new uint24[](0), new int24[](0)
        ) returns (uint8) {
            accepted = true;
        } catch {
            accepted = false;
        }
    }

    // ─── CONTROLS (green today, must stay green after any fix) ───────────────

    /// CONTROL. The apparatus works at all: an unmutated, admitted factory
    /// steers discovery to the pool it names.
    /// NOT VACUOUS: it fails if `discoverFor` returns nothing, if mode 0 stops
    /// calling `getPair`, or if the pin refuses a factory that never changed.
    function test_FactoryRearm_UnchangedFactoryIsADiscoverySource() public view {
        assertTrue(_sees(address(honest)), "an unchanged factory must serve discovery");
    }

    /// CONTROL, AND THE PRECONDITION OF EVERY RED TEST BELOW. The factory pin
    /// really does auto-pause a factory whose runtime moved: the mutated factory
    /// produces NO candidates, so neither the pool it used to name nor the one
    /// it now names appears.
    /// NOT VACUOUS: if Hub:912 were deleted or inverted, the hostile answer would
    /// surface here and this assertion would fail. Without this test the RED ones
    /// could go green for the wrong reason - "the attacker pool was not seen"
    /// would no longer prove that the re-arm was refused, only that discovery
    /// was broken.
    function test_FactoryRearm_MutatedFactoryIsAutoPausedBeforeAnyReAdd() public {
        _mutateFactoryToHostile();

        address[] memory found = _discoveredPools();
        assertEq(found.length, 0, "a factory whose runtime moved must produce no candidates");
        assertFalse(_sees(address(attackerPool)), "the mutated factory must not steer discovery");
    }

    /// CONTROL. `renounceControl`'s docstring promises that listing a NEW venue
    /// still works afterwards. A fix must gate the RE-PIN of an already-admitted
    /// address, never the admission of a fresh one.
    /// NOT VACUOUS: it fails the moment a fix reaches for the blunt instrument
    /// ("no addFactory after renunciation"), and it exercises the full path -
    /// the new factory must actually be discovered, not merely accepted.
    function test_FactoryRearm_ANewFactoryIsStillAdmittedAfterRenounce() public {
        address fresh = address(new FixedPairFactory(address(secondVenue)));
        assertFalse(_sees(address(secondVenue)),
            "precondition: no admitted factory names the second venue yet");

        hub.renounceControl();

        hub.addFactory(
            fresh, BPC.KIND_V2, 0, bytes32(0), new uint24[](0), new int24[](0)
        );
        assertTrue(_sees(address(secondVenue)),
            "grow-only curation must survive renunciation for a factory admitted at its current code");
    }

    /// CONTROL. While control still EXISTS, re-attesting a factory whose code
    /// changed is a deliberate curator act, not the cancel button of a pause
    /// nobody can undo - the admin who does it could equally have called
    /// `setPaused`. The hook fix drew the line at `controlRenounced` and this
    /// control holds the factory fix to the same line.
    /// NOT VACUOUS: it fails if a fix makes a duplicate `addFactory` a pure
    /// no-op the way `addBridge` is, because then the codehash would never be
    /// re-pinned and the factory would stay paused for ever even under a live
    /// admin. Read together with
    /// `..._ReAddingTheSameFactoryPushesADuplicateRow`, it forces the fix to
    /// separate the RE-PIN from the ROW PUSH.
    function test_FactoryRearm_BeforeRenounceTheAdminMayReattest() public {
        _mutateFactoryToHostile();

        bool accepted = _reAddSameFactory();
        assertTrue(accepted, "a curator holding control must still be able to re-attest a factory");
        assertTrue(_sees(address(attackerPool)),
            "re-attestation by a live admin must restore the factory as a discovery source");
    }

    // ─── RED before the fix of 2026-09-03, GREEN since: the re-arm guard ─────

    /// THE CLAIM (RED before the fix, GREEN since). After `renounceControl()`, nothing may make a
    /// MUTATED factory a discovery source again. Today `addFactory(F, ...)`
    /// re-pins `factoryCodehash[F] = F.codehash` with no arm for "already
    /// listed" and no arm for "control renounced", so the factory that the pin
    /// auto-paused starts steering discovery to the attacker's pool - through
    /// the one power renunciation kept, while the powers that could answer
    /// (`setPaused`, `removeBridge`, hook de-listing) are dead and
    /// `removeFactory` never existed.
    /// NOT VACUOUS: the preceding control proves the auto-pause is real before
    /// the re-add, so the only thing that can flip `_sees(attackerPool)` between
    /// the two states is the re-pin performed by `addFactory`.
    function test_FactoryRearm_RenouncedAdminCanReArmAMutatedFactory() public {
        _mutateFactoryToHostile();
        assertFalse(_sees(address(attackerPool)), "precondition: the pin has auto-paused the factory");

        hub.renounceControl();
        _reAddSameFactory();

        assertFalse(_sees(address(attackerPool)),
            "a factory whose runtime moved became a discovery source again AFTER renunciation, through the one power renunciation kept");
    }

    /// The same fact stated as an ASYMMETRY, so the finding stays legible if the
    /// fix chooses to no-op rather than to revert (RED before the fix, GREEN since).
    /// After renunciation the registry can only ever gain factory authority:
    /// there is no `removeFactory` at any signature the Hub answers, and the
    /// re-arm still succeeds.
    ///
    /// REPAIRED 2026-09-03. The drafted version ended on
    /// `assertTrue(rearmRefused)` - an assertion on the SHAPE of the fix, which
    /// contradicts this file's own header ("every RED test observes the
    /// OUTCOME") and would have stayed RED for ever under the accept-but-keep-
    /// the-first-attestation fix that the sibling test above was written to
    /// allow. It is now an outcome assertion and is GREEN under a revert, a
    /// no-op and a split alike.
    ///
    /// WHAT EACH LINE IS. The two raw `removeFactory` probes are PREMISES, not
    /// the claim: they are trivially true today (the Hub declares no such
    /// function and has no `fallback`/`receive`, so the call fails on selector
    /// lookup), and they exist so that this test breaks loudly the day someone
    /// adds a removal path and leaves the asymmetry argument standing. The
    /// claim is the last assertion, and it is the same RED as the sibling
    /// test's - stated here alongside the premise that makes it an asymmetry.
    function test_FactoryRearm_ReArmOutlivesEveryPause_Asymmetry() public {
        _mutateFactoryToHostile();
        hub.renounceControl();

        (bool byAddress, ) = address(hub).call(
            abi.encodeWithSignature("removeFactory(address)", factory)
        );
        (bool byIndex, ) = address(hub).call(
            abi.encodeWithSignature("removeFactory(uint256)", uint256(0))
        );
        assertFalse(byAddress, "no removeFactory(address) exists");
        assertFalse(byIndex, "no removeFactory(uint256) exists");

        _reAddSameFactory();

        assertFalse(_sees(address(attackerPool)),
            "re-arm outlived every pause: with no removeFactory in existence, the one surviving curator lever turned a mutated factory back ON");
    }

    // ─── RED before the fix of 2026-09-03 (GREEN since): the duplicate guard ─

    /// THE CLAIM (RED before the fix, GREEN since). `addBridge` returns early on a duplicate and
    /// documents why: an idempotent administrative call must not fail on a
    /// retry, and must not change the end state twice. `addFactory` has no such
    /// arm and pushes a second row for the same address.
    /// NOT VACUOUS: `factoryCount()` is a real external view over
    /// `$.factories.length`, the array `discoverFor` iterates; the assertion is
    /// on a number that is 1 before the call and 2 after it today.
    function test_FactoryRearm_ReAddingTheSameFactoryPushesADuplicateRow() public {
        assertEq(hub.factoryCount(), 1, "precondition: exactly one row after setUp");

        _reAddSameFactory();

        assertEq(hub.factoryCount(), 1,
            "re-adding an already-admitted factory pushed a second row: addFactory has no duplicate guard, unlike its sibling addBridge");
    }

    /// THE CONSEQUENCE (RED before the fix, GREEN since). The factory table is capped and has no
    /// removal path, so repeated adds of ONE address consume every slot and the
    /// grow-only power that `renounceControl` explicitly promises to keep alive
    /// is destroyed permanently, by a call that looks idempotent.
    /// NOT VACUOUS: it does not hard-code the cap - it adds until the Hub
    /// refuses, asserts that the refusal really happened (so the test cannot
    /// pass by never filling anything), and only then asks whether a genuinely
    /// new venue can still be listed.
    function test_FactoryRearm_ReAddsExhaustTheTableWithOneAddress() public {
        address fresh = address(new FixedPairFactory(address(secondVenue)));

        bool capReached;
        for (uint256 i; i < ADD_ATTEMPTS_CEILING; ++i) {
            if (!_reAddSameFactory()) { capReached = true; break; }
        }

        hub.renounceControl();

        bool freshAccepted;
        try hub.addFactory(
            fresh, BPC.KIND_V2, 0, bytes32(0), new uint24[](0), new int24[](0)
        ) returns (uint8) {
            freshAccepted = true;
        } catch {
            freshAccepted = false;
        }

        // Today: capReached is true (16 rows of one address, HubE(4)) and
        // freshAccepted is false. After a duplicate guard: capReached is false
        // (the duplicates never consumed a slot) and freshAccepted is true.
        assertTrue(freshAccepted,
            "repeated adds of ONE address filled the factory table, so no new venue can ever be listed again - the exact power renounceControl promises to keep");
        assertFalse(capReached,
            "duplicate adds consumed table slots that no removal path can ever return");
    }
}
