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
}
