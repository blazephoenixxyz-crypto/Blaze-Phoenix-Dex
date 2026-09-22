// =============================================================================
//  THE DERIVATION OF A LIVE FACTORY ROW IS FIXED AFTER RENUNCIATION.
//
//  `addFactory` refreshes a known row in place rather than appending a second one,
//  which is what keeps the sixteen seats of a grow-only registry from being spent
//  by a repeated administrative call. The refresh writes five fields. This file
//  pins which of them a renounced registry will accept.
//
//  THE CLAIM: after `renounceControl()`, the address an admitted row derives is
//  fixed. The codehash pin answers for the factory's runtime and cannot answer for
//  the row's own CREATE2 derivation input, which lives in the row; so the guard
//  names that input directly, as it already names the runtime and the mode family.
//
//  WHAT MUST STAY OPEN, and is asserted here so a future edit cannot quietly close
//  it: an identical re-add is a no-op refresh, and a factory that was never listed
//  is still admissible. Hub:411-418 guarantees both. A guard that took them away
//  would be over-tight, and the two control tests are what tell the two apart.
//
//  The apparatus asserts its own preconditions: the factory used here is immutable,
//  so the codehash guard can never be the thing that makes a test pass, and a live
//  admin is shown re-attesting freely before renunciation.
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixCore as BPC} from "../src/BlazePhoenixCore.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";

/// @dev An immutable factory: its runtime never moves, so the codehash pin is
///      satisfied for ever. This is the ordinary case, not a contrived one.
contract ImmutableFactory {
    function getPair(address, address) external pure returns (address) { return address(0); }
}

contract RenouncedRowDerivationFreeze is Test {
    BlazePhoenixHub internal hub;
    address internal factory;
    bytes32 internal codehashAtAdmission;

    uint8 internal constant MODE_CREATE2_V2 = 4;   // Hub:229
    uint8 internal constant MODE_ASK        = 0;   // factory-call family
    uint16 internal constant HUB_REFUSED    = 1;   // HubE(1)

    bytes32 internal constant INIT_A =
        0x96e8ac4279504d8dd2f6b71f7a2f2d1bdcbeb63f3a9b4acdbbe8b4cbdef5f5f5;
    bytes32 internal constant INIT_B =
        0x0000000000000000000000000000000000000000000000000000000000000b0b;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));

        factory = address(new ImmutableFactory());
        hub.addFactory(
            factory, BPC.KIND_V2, MODE_CREATE2_V2, INIT_A,
            new uint24[](0), new int24[](0)
        );
        codehashAtAdmission = factory.codehash;
    }

    // ─── the apparatus is honest about itself ──────────────────────────────

    /// @dev CONTROL. If the factory's code could move, the existing codehash
    ///      guard would catch the re-add and every test below would pass for
    ///      the wrong reason. It cannot: the factory is immutable.
    function test_Control_FactoryRuntimeNeverMoves() public view {
        assertEq(factory.codehash, codehashAtAdmission, "factory runtime moved");
    }

    /// @dev CONTROL. Before renunciation the admin is entitled to re-attest, so
    ///      a rewrite here MUST be allowed. A guard that refused this one would
    ///      be over-tight, and this test is what tells the two apart.
    function test_Control_LiveAdminMayStillReattest() public {
        hub.addFactory(
            factory, BPC.KIND_V2, MODE_CREATE2_V2, INIT_B,
            new uint24[](0), new int24[](0)
        );
        assertEq(hub.factoryCount(), 1, "re-attestation must refresh, never append");
    }

    // ─── the defect ────────────────────────────────────────────────────────

    /// @dev THE FINDING. After renunciation the derivation of a LIVE row must
    ///      be fixed, and this is the assertion that says so.
    function test_RenouncedRowRefusesInitHashRewrite() public {
        hub.renounceControl();
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixHub.HubE.selector, HUB_REFUSED));
        hub.addFactory(
            factory, BPC.KIND_V2, MODE_CREATE2_V2, INIT_B,
            new uint24[](0), new int24[](0)
        );
    }

    /// @dev THE SIBLING THAT TURNED OUT TO BE CLOSED, and it is worth a pin
    ///      rather than a fix. `kind` is written by the same instruction and is
    ///      also a derivation input, so it was the obvious second hole — but the
    ///      kind/mode domain check upstream (HubE(5), Hub:687-688) already
    ///      refuses KIND_V3 on a MODE_CREATE2_V2 row, renounced or not. Measured
    ///      2026-09-21: the red run returned HubE(5), not HubE(1). Pinned at the
    ///      error it actually raises, so that if the domain check is ever
    ///      loosened this test fails and the renounce guard is reconsidered.
    function test_RenouncedRowKindRewriteIsRefusedByTheDomainCheck() public {
        hub.renounceControl();
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixHub.HubE.selector, uint16(5)));
        hub.addFactory(
            factory, BPC.KIND_V3, MODE_CREATE2_V2, INIT_A,
            new uint24[](0), new int24[](0)
        );
    }

    /// @dev THE IDENTITY CASE. Re-admitting a row UNCHANGED is not a rewrite and
    ///      must keep working: the docstring calls it re-listing "without
    ///      ceremony", and a guard that broke it would take away the grow-only
    ///      power renunciation keeps. This is the test that stops the fix from
    ///      being a blunt `revert` after renunciation.
    function test_RenouncedRowStillAcceptsAnIdenticalReAdd() public {
        hub.renounceControl();
        hub.addFactory(
            factory, BPC.KIND_V2, MODE_CREATE2_V2, INIT_A,
            new uint24[](0), new int24[](0)
        );
        assertEq(hub.factoryCount(), 1, "identical re-add must remain a no-op refresh");
    }

    /// @dev THE MODE FAMILY, asserted alongside the new arm so that an edit to
    ///      this guard cannot drop it. DERIVE -> ASK after renunciation would hand
    ///      discovery the factory's own answer for every pair.
    function test_RenouncedRowStillRefusesDeriveToAskConversion() public {
        hub.renounceControl();
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixHub.HubE.selector, HUB_REFUSED));
        hub.addFactory(
            factory, BPC.KIND_V2, MODE_ASK, bytes32(0),
            new uint24[](0), new int24[](0)
        );
    }

    /// @dev A FRESH LISTING IS STILL FREE. Renunciation keeps the power to admit
    ///      a venue that was never listed — freezing live rows must not freeze
    ///      the registry (pinned by RenouncedFactoryRearm.t.sol too).
    function test_RenouncedRegistryStillAdmitsANewFactory() public {
        hub.renounceControl();
        address fresh = address(new ImmutableFactory());
        hub.addFactory(
            fresh, BPC.KIND_V2, MODE_CREATE2_V2, INIT_B,
            new uint24[](0), new int24[](0)
        );
        assertEq(hub.factoryCount(), 2, "a never-listed factory must still be admissible");
    }

    // ─── the rest of the surface this guard sits on ────────────────────────

    uint8 internal constant MODE_CREATE2_V3    = 5;   // Hub:230
    uint8 internal constant MODE_CREATE2_CLONE = 6;   // Hub:231
    uint8 internal constant MODE_V4_DERIVE     = 9;   // Hub:244

    /// @dev THE OTHER DOOR, asserted rather than assumed. Freezing a live row does
    ///      not stop a NEW listing, and it is not meant to: Hub:411-418 keeps that
    ///      power. What must hold is that the new listing lands on its own row and
    ///      leaves the admitted one exactly as it was.
    function test_RenouncedFreshListingDoesNotDisturbTheAdmittedRow() public {
        hub.renounceControl();
        address fresh = address(new ImmutableFactory());
        hub.addFactory(
            fresh, BPC.KIND_V2, MODE_CREATE2_V2, INIT_B,
            new uint24[](0), new int24[](0)
        );
        assertEq(hub.factoryCount(), 2, "a fresh listing takes its own row");
        // the admitted row is unchanged: re-adding it identically is still a no-op
        hub.addFactory(
            factory, BPC.KIND_V2, MODE_CREATE2_V2, INIT_A,
            new uint24[](0), new int24[](0)
        );
        assertEq(hub.factoryCount(), 2, "the admitted row was not disturbed");
    }

    /// @dev WITHIN THE DERIVE FAMILY. Modes 4-7 are different CREATE2 producers, so
    ///      moving between them moves the derived address with the SAME derivation
    ///      input. The existing arm only refuses derive -> ask.
    function test_RenouncedRowAndAMoveInsideTheDeriveFamily() public {
        hub.renounceControl();
        try hub.addFactory(
            factory, BPC.KIND_V2, MODE_CREATE2_CLONE, INIT_A,
            new uint24[](0), new int24[](0)
        ) {
            emit log("OPEN: a live row moved between CREATE2 producers after renunciation");
            assertEq(hub.factoryCount(), 1, "it refreshed in place rather than appending");
        } catch (bytes memory err) {
            emit log_named_bytes("refused with", err);
        }
    }

    /// @dev THE PAIRED EXTRAS. On a derive row `fees`/`spacings` are derivation
    ///      inputs, written by the same instruction as the input this guard names.
    function test_RenouncedRowAndTheDerivationExtras() public {
        uint24[] memory fees = new uint24[](1);
        int24[] memory sp = new int24[](1);
        fees[0] = 3000; sp[0] = 60;

        BlazePhoenixHub h2 = new BlazePhoenixHub(address(this));
        h2.initialize(address(this), address(0));
        address f2 = address(new ImmutableFactory());
        h2.addFactory(f2, BPC.KIND_V4, MODE_V4_DERIVE, INIT_A, fees, sp);
        h2.renounceControl();

        uint24[] memory fees2 = new uint24[](1);
        int24[] memory sp2 = new int24[](1);
        fees2[0] = 500; sp2[0] = 10;
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixHub.HubE.selector, HUB_REFUSED));
        h2.addFactory(f2, BPC.KIND_V4, MODE_V4_DERIVE, INIT_A, fees2, sp2);

        // and the identical extras are still a no-op refresh
        h2.addFactory(f2, BPC.KIND_V4, MODE_V4_DERIVE, INIT_A, fees, sp);
        assertEq(h2.factoryCount(), 1, "identical extras must remain admissible");
    }

    /// @dev THE TERMINAL-STATE COMPOSITION. renounceControl() is refused while
    ///      paused (Hub:429), so the two terminal states cannot be combined into a
    ///      registry that can never learn again. Pinned here because this guard
    ///      lives in the same terminal-state family.
    function test_PausedThenRenounceIsStillRefused() public {
        hub.setPaused(true);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixHub.HubE.selector, uint16(2)));
        hub.renounceControl();
    }

    /// @dev THE GUARD READS THE ROW, NOT THE ARGUMENT. Admitting a SECOND factory
    ///      and then rewriting the FIRST must still be refused: a scan that matched
    ///      the wrong row would make the freeze depend on listing order.
    function test_RenouncedFreezeIsPerRowNotPerPosition() public {
        address second = address(new ImmutableFactory());
        hub.addFactory(
            second, BPC.KIND_V2, MODE_CREATE2_V2, INIT_B,
            new uint24[](0), new int24[](0)
        );
        hub.renounceControl();
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixHub.HubE.selector, HUB_REFUSED));
        hub.addFactory(
            factory, BPC.KIND_V2, MODE_CREATE2_V2, INIT_B,
            new uint24[](0), new int24[](0)
        );
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixHub.HubE.selector, HUB_REFUSED));
        hub.addFactory(
            second, BPC.KIND_V2, MODE_CREATE2_V2, INIT_A,
            new uint24[](0), new int24[](0)
        );
    }

    /// @dev THE PRODUCER, PINNED. Modes 4, 5 and 7 are different CREATE2 producers:
    ///      the same derivation input under a different producer lands on a
    ///      different address. Found by a probe, asserted here, so that a mutant
    ///      dropping the mode arm has something that can fail. A probe discovers; an
    ///      assertion is what keeps the door shut.
    function test_RenouncedRowRefusesAMoveBetweenCreate2Producers() public {
        //      Mode 5 -> 7 is the pair the probe measured as legal on both sides of
        //      the move for this kind; the others are refused upstream by the
        //      kind/mode domain check with HubE(5), which is a different guard
        //      answering a different question. Asserting only the pair that
        //      actually reaches this guard is what keeps the test about this guard.
        BlazePhoenixHub h = new BlazePhoenixHub(address(this));
        h.initialize(address(this), address(0));
        address f = address(new ImmutableFactory());
        h.addFactory(f, BPC.KIND_V3, MODE_CREATE2_V3, INIT_A, new uint24[](0), new int24[](0));
        h.renounceControl();
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixHub.HubE.selector, HUB_REFUSED));
        h.addFactory(f, BPC.KIND_V3, uint8(7), INIT_A, new uint24[](0), new int24[](0));
    }

    /// @dev FUZZ. Any derivation input other than the admitted one is refused, and
    ///      the admitted one is always accepted. One property, both directions.
    function testFuzz_RenouncedRowAcceptsOnlyItsOwnDerivation(bytes32 h) public {
        hub.renounceControl();
        if (h == INIT_A) {
            hub.addFactory(factory, BPC.KIND_V2, MODE_CREATE2_V2, h,
                           new uint24[](0), new int24[](0));
            assertEq(hub.factoryCount(), 1);
        } else if (h != bytes32(0)) {
            vm.expectRevert(abi.encodeWithSelector(BlazePhoenixHub.HubE.selector, HUB_REFUSED));
            hub.addFactory(factory, BPC.KIND_V2, MODE_CREATE2_V2, h,
                           new uint24[](0), new int24[](0));
        }
    }

    // ─── scale: every legal pair, and the extras compared exactly ──────────

    /// @dev THE WHOLE (kind, mode) DOMAIN, not the one pair that happened to be
    ///      handy. `kind` is written by the same instruction as the derivation
    ///      input; the domain check refuses many pairs upstream, but "many" is not
    ///      "all", and a pair that is legal on both sides of the move would let a
    ///      live row change family after renunciation. This sweeps them and reports
    ///      any that gets through, rather than asserting a result we assumed.
    function test_RenouncedRowKindMoveAcrossEveryLegalPair() public {
        uint8[5] memory kinds = [BPC.KIND_V2, BPC.KIND_V3, BPC.KIND_V4, uint8(8), uint8(2)];
        uint8[5] memory modes = [MODE_CREATE2_V2, MODE_CREATE2_V3, MODE_CREATE2_CLONE, uint8(7), MODE_V4_DERIVE];
        uint256 through;
        for (uint256 k; k < kinds.length; ++k) {
            for (uint256 m; m < modes.length; ++m) {
                BlazePhoenixHub h = new BlazePhoenixHub(address(this));
                h.initialize(address(this), address(0));
                address f = address(new ImmutableFactory());
                try h.addFactory(f, kinds[k], modes[m], INIT_A, new uint24[](0), new int24[](0)) {
                    h.renounceControl();
                    for (uint256 k2; k2 < kinds.length; ++k2) {
                        if (k2 == k) continue;
                        try h.addFactory(f, kinds[k2], modes[m], INIT_A, new uint24[](0), new int24[](0)) {
                            through++;
                            emit log_named_uint("kind moved on a live row, mode", modes[m]);
                            emit log_named_uint("  from kind", kinds[k]);
                            emit log_named_uint("  to kind", kinds[k2]);
                        } catch { }
                    }
                } catch { }
            }
        }
        assertEq(through, 0, "a live row changed family after renunciation");
    }

    /// @dev THE EXTRAS ARE COMPARED ELEMENT-WISE, not by length. A comparison that
    ///      only checked lengths would pass a row whose every fee moved.
    function testFuzz_RenouncedExtrasAreComparedElementWise(uint24 fee, int24 sp) public {
        uint24[] memory f1 = new uint24[](2);
        int24[] memory s1 = new int24[](2);
        f1[0] = 3000; f1[1] = 500; s1[0] = 60; s1[1] = 10;

        BlazePhoenixHub h = new BlazePhoenixHub(address(this));
        h.initialize(address(this), address(0));
        address fac = address(new ImmutableFactory());
        h.addFactory(fac, BPC.KIND_V4, MODE_V4_DERIVE, INIT_A, f1, s1);
        h.renounceControl();

        uint24[] memory f2 = new uint24[](2);
        int24[] memory s2 = new int24[](2);
        f2[0] = 3000; f2[1] = fee; s2[0] = 60; s2[1] = sp;

        if (fee == 500 && sp == 10) {
            h.addFactory(fac, BPC.KIND_V4, MODE_V4_DERIVE, INIT_A, f2, s2);
            assertEq(h.factoryCount(), 1, "the identical row stays admissible");
        } else {
            vm.expectRevert(abi.encodeWithSelector(BlazePhoenixHub.HubE.selector, HUB_REFUSED));
            h.addFactory(fac, BPC.KIND_V4, MODE_V4_DERIVE, INIT_A, f2, s2);
        }
    }

    /// @dev LENGTH IS NOT CONTENT, AND CONTENT IS NOT LENGTH. A shorter or longer
    ///      extras array changes the derived set as surely as a different value.
    function test_RenouncedExtrasRefuseALengthChange() public {
        uint24[] memory f1 = new uint24[](2);
        int24[] memory s1 = new int24[](2);
        f1[0] = 3000; f1[1] = 500; s1[0] = 60; s1[1] = 10;

        BlazePhoenixHub h = new BlazePhoenixHub(address(this));
        h.initialize(address(this), address(0));
        address fac = address(new ImmutableFactory());
        h.addFactory(fac, BPC.KIND_V4, MODE_V4_DERIVE, INIT_A, f1, s1);
        h.renounceControl();

        uint24[] memory f3 = new uint24[](3);
        int24[] memory s3 = new int24[](3);
        f3[0] = 3000; f3[1] = 500; f3[2] = 100;
        s3[0] = 60;   s3[1] = 10;  s3[2] = 1;
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixHub.HubE.selector, HUB_REFUSED));
        h.addFactory(fac, BPC.KIND_V4, MODE_V4_DERIVE, INIT_A, f3, s3);
    }

    /// @dev THE ROW INDEX IS STABLE. addFactory returns the row it wrote; an
    ///      identical re-add after renunciation must return the same index, or an
    ///      integrator reading that return value learns a row moved when none did.
    function test_RenouncedIdenticalReAddReturnsTheSameRow() public {
        address second = address(new ImmutableFactory());
        uint8 rowSecond = hub.addFactory(
            second, BPC.KIND_V2, MODE_CREATE2_V2, INIT_B, new uint24[](0), new int24[](0)
        );
        hub.renounceControl();
        uint8 again = hub.addFactory(
            second, BPC.KIND_V2, MODE_CREATE2_V2, INIT_B, new uint24[](0), new int24[](0)
        );
        assertEq(again, rowSecond, "an identical re-add must not move the row");
        assertEq(hub.factoryCount(), 2, "and must not append");
    }

    /// @dev SEATS ARE FINITE AND THERE IS NO REMOVAL. With the table full and the
    ///      registry renounced, an identical re-add must still be accepted — the
    ///      grow-only power is what keeps a full table usable — and a new listing
    ///      must be refused for want of a seat, not silently overwrite a row.
    function test_RenouncedFullTableStillRefreshesButCannotGrow() public {
        for (uint256 i = 1; i < 16; ++i) {
            hub.addFactory(
                address(new ImmutableFactory()), BPC.KIND_V2, MODE_CREATE2_V2,
                INIT_B, new uint24[](0), new int24[](0)
            );
        }
        assertEq(hub.factoryCount(), 16, "the table is full");
        hub.renounceControl();
        hub.addFactory(
            factory, BPC.KIND_V2, MODE_CREATE2_V2, INIT_A, new uint24[](0), new int24[](0)
        );
        assertEq(hub.factoryCount(), 16, "an identical re-add on a full table is a refresh");
        // The deployment happens FIRST: a contract creation inside the call's
        // arguments consumes the cheatcode, and the assertion would then be made
        // about the wrong call. Cheatcodes go after the builder, always.
        address seventeenth = address(new ImmutableFactory());
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixHub.HubE.selector, uint16(4)));
        hub.addFactory(
            seventeenth, BPC.KIND_V2, MODE_CREATE2_V2,
            INIT_B, new uint24[](0), new int24[](0)
        );
    }
}
