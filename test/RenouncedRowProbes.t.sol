// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  PROBES — questions this file does not know the answer to.
//
//  Every test below is written as a probe rather than an assertion: it records
//  what happens in both branches instead of asserting the one we expect. The
//  single finding this file's sibling produced came from the only test written
//  that way; the ones written from a belief could only ever confirm the belief.
//
//  A probe that logs OPEN has found a door. A probe that logs REFUSED has bought
//  a pin for free. Neither is a failure, and that is the point.
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixCore as BPC} from "../src/BlazePhoenixCore.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";

contract ImmutableFactoryP {
    function getPair(address, address) external pure returns (address) { return address(0); }
}

contract RenouncedRowProbes is Test {
    uint8 internal constant MODE_ASK        = 0;
    uint8 internal constant MODE_CREATE2_V2 = 4;
    uint8 internal constant MODE_CREATE2_V3 = 5;
    uint8 internal constant MODE_V4_DERIVE  = 9;
    bytes32 internal constant INIT_A =
        0x96e8ac4279504d8dd2f6b71f7a2f2d1bdcbeb63f3a9b4acdbbe8b4cbdef5f5f5;

    function _hub() internal returns (BlazePhoenixHub h) {
        h = new BlazePhoenixHub(address(this));
        h.initialize(address(this), address(0));
    }

    /// @dev PROBE 1 — THE FAMILY IS NOT PINNED. The renounced guard names the
    ///      derivation input, the mode direction and the paired extras. It does
    ///      NOT name `kind`, and ask -> derive is allowed on purpose as a
    ///      tightening. An ask row carries no derivation-input requirement, so its
    ///      input is zero, and MODE_V4_DERIVE is the one derive mode that also
    ///      accepts a zero input. Does a live ask row become a V4 derive row after
    ///      renunciation, changing both the family and what it enumerates?
    function test_Probe_AskRowBecomesAV4DeriveRowAfterRenunciation() public {
        BlazePhoenixHub h = _hub();
        address f = address(new ImmutableFactoryP());
        h.addFactory(f, BPC.KIND_V2, MODE_ASK, bytes32(0), new uint24[](0), new int24[](0));
        h.renounceControl();
        try h.addFactory(f, BPC.KIND_V4, MODE_V4_DERIVE, bytes32(0),
                         new uint24[](0), new int24[](0)) {
            emit log("OPEN: a live ask row became a V4 derive row after renunciation");
            emit log_named_uint("rows", h.factoryCount());
        } catch (bytes memory e) {
            emit log_named_bytes("REFUSED", e);
        }
    }

    /// @dev PROBE 2 — THE SAME MOVE WITH EXTRAS PRESENT, in case an empty-to-empty
    ///      extras comparison is what decides probe 1 rather than the family rule.
    function test_Probe_AskRowWithExtrasBecomesADeriveRow() public {
        BlazePhoenixHub h = _hub();
        address f = address(new ImmutableFactoryP());
        uint24[] memory fees = new uint24[](1);
        int24[] memory sp = new int24[](1);
        fees[0] = 3000; sp[0] = 60;
        try h.addFactory(f, BPC.KIND_V4, MODE_ASK, bytes32(0), fees, sp) {
            h.renounceControl();
            try h.addFactory(f, BPC.KIND_V4, MODE_V4_DERIVE, bytes32(0), fees, sp) {
                emit log("OPEN: ask -> V4 derive with identical extras, after renunciation");
            } catch (bytes memory e) { emit log_named_bytes("REFUSED on the move", e); }
        } catch (bytes memory e) { emit log_named_bytes("REFUSED at admission", e); }
    }

    /// @dev PROBE 3 — A DERIVE ROW WITH NOTHING TO DERIVE FROM. MODE_V4_DERIVE
    ///      requires fees.length == spacings.length, and zero equals zero. Is an
    ///      empty derive row admissible, and what does the registry then think it
    ///      enumerates?
    function test_Probe_AnEmptyV4DeriveRowIsAdmissible() public {
        BlazePhoenixHub h = _hub();
        address f = address(new ImmutableFactoryP());
        try h.addFactory(f, BPC.KIND_V4, MODE_V4_DERIVE, bytes32(0),
                         new uint24[](0), new int24[](0)) {
            emit log("OPEN: a V4 derive row with no fee/spacing pairs was admitted");
            emit log_named_uint("rows", h.factoryCount());
        } catch (bytes memory e) { emit log_named_bytes("REFUSED", e); }
    }

    /// @dev PROBE 4 — MOVING BETWEEN CREATE2 PRODUCERS WITH THE SAME INPUT. Modes
    ///      4, 5 and 7 are different producers. Same derivation input, same extras,
    ///      different producer: does the guard see a change at all?
    function test_Probe_MoveBetweenCreate2ProducersAfterRenunciation() public {
        uint8[3] memory from = [MODE_CREATE2_V2, MODE_CREATE2_V3, uint8(7)];
        uint8[3] memory to   = [MODE_CREATE2_V3, uint8(7), MODE_CREATE2_V2];
        for (uint256 i; i < 3; ++i) {
            BlazePhoenixHub h = _hub();
            address f = address(new ImmutableFactoryP());
            try h.addFactory(f, BPC.KIND_V3, from[i], INIT_A, new uint24[](0), new int24[](0)) {
                h.renounceControl();
                try h.addFactory(f, BPC.KIND_V3, to[i], INIT_A, new uint24[](0), new int24[](0)) {
                    emit log_named_uint("OPEN: producer moved on a live row, from", from[i]);
                    emit log_named_uint("  to", to[i]);
                } catch { }
            } catch { }
        }
    }

    /// @dev PROBE 5 — A ROW WHOSE FACTORY HAS NO CODE. An address with no code
    ///      hashes to zero rather than to the pinned value, so a re-add should be
    ///      refused. But is such an address admissible in the first place, and
    ///      what does the row claim while nothing stands behind it?
    function test_Probe_RowWhoseFactoryHasNoCode() public {
        BlazePhoenixHub h = _hub();
        address ghost = address(0xDEAD);
        try h.addFactory(ghost, BPC.KIND_V2, MODE_ASK, bytes32(0),
                         new uint24[](0), new int24[](0)) {
            emit log("OPEN: a codeless address was admitted as a factory");
            emit log_named_uint("rows", h.factoryCount());
            h.renounceControl();
            try h.addFactory(ghost, BPC.KIND_V2, MODE_ASK, bytes32(0),
                             new uint24[](0), new int24[](0)) {
                emit log("OPEN: and re-added after renunciation");
            } catch (bytes memory e) { emit log_named_bytes("REFUSED on re-add", e); }
        } catch (bytes memory e) { emit log_named_bytes("REFUSED at admission", e); }
    }

    /// @dev PROBE 6 — THE EXTRAS ON A ROW THAT IS NOT A DERIVE ROW. An ask row
    ///      carries no derivation, so its extras decide nothing; freezing them
    ///      there would be over-tight. Are they frozen anyway?
    function test_Probe_ExtrasOnAnAskRowAfterRenunciation() public {
        BlazePhoenixHub h = _hub();
        address f = address(new ImmutableFactoryP());
        uint24[] memory fees = new uint24[](1);
        int24[] memory sp = new int24[](1);
        fees[0] = 3000; sp[0] = 60;
        try h.addFactory(f, BPC.KIND_V3, MODE_ASK, bytes32(0), fees, sp) {
            h.renounceControl();
            uint24[] memory fees2 = new uint24[](1);
            int24[] memory sp2 = new int24[](1);
            fees2[0] = 500; sp2[0] = 10;
            try h.addFactory(f, BPC.KIND_V3, MODE_ASK, bytes32(0), fees2, sp2) {
                emit log("OPEN: an ask row's extras still move after renunciation");
            } catch (bytes memory e) { emit log_named_bytes("REFUSED (freeze reaches ask rows too)", e); }
        } catch (bytes memory e) { emit log_named_bytes("REFUSED at admission", e); }
    }
}
