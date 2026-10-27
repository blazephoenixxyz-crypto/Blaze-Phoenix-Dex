// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixCore as BPC} from "../src/BlazePhoenixCore.sol";

/// P-A1 (2026-10-21): the salt-slot <-> kind coherence of addFactory became a table,
/// MODE_KINDS. A refactor, so there is no red: this file is its equivalence proof.
/// Exhaustive equivalence of the LIVE addFactory's kind/mode admission against the
/// predicate of main 85720ef (before the table), copied verbatim from
/// BlazePhoenixHub.sol:173-179 (KINDS_ROUTABLE), 230-239 (MODES_VALID, modes, KINDS_V3_SALT)
/// and 716-748 (the checks). The only edit to the copy: `revert HubE(5)` -> `return false`.
/// One cell changed since, marked where it is: (4, SOLIDLY) admitted (aero-nova, 2026-10-26).
/// Domain, in three sweeps (one test each; the two whole-grid sweeps pause gas metering):
///   - the whole grid: mode 0..255 x kind 0..255, empty fees/spacings, once per initHash {0, 1};
///   - the extras: mode 0..15 x kind 0..15 x initHash {0, 1} x 7 shapes of fees/spacings
///     (empty, zero fee, non-zero fee, paired, unpaired, non-zero in second place). Every
///     routable kind is below 16 (pinned below) and no mode >= 16 has a MODE_KINDS row, so
///     the cells outside this square are refused by the grid's own conditions.
contract HubRoutableProbe is BlazePhoenixHub {
    constructor() BlazePhoenixHub(msg.sender) {}
    function routable() external pure returns (uint256) { return KINDS_ROUTABLE; }
}

contract ModeKindsTableIsTheOldPredicateTest is Test {
    BlazePhoenixHub hub;
    address constant FAC = address(0x3333);

    // ---- main 85720ef, verbatim ----
    uint256 internal constant KINDS_ROUTABLE =
          (uint256(1) << BPC.KIND_V2)      // 0 — constant-product
        | (uint256(1) << BPC.KIND_V3)      // 1 — concentrated
        | (uint256(1) << BPC.KIND_V4)      // 4 — singleton, via MODE_V4_DERIVE
        | (uint256(1) << BPC.KIND_SOLIDLY) // 5 — stable/volatile pairs
        | (uint256(1) << BPC.KIND_ALGEBRA)  // 6 — concentrated, dynamic fee
        | (uint256(1) << BPC.KIND_EXTERNAL);// 9 — Gate wrappers, via MODE_CREATE2_V3 only
    uint256 internal constant MODES_VALID = 0x2FF; // bits 0-7 and 9; bit 8 is a tombstone
    uint8   internal constant MODE_CREATE2_V2        = 4;
    uint8   internal constant MODE_CREATE2_V3        = 5;
    uint256 internal constant KINDS_V3_SALT =
          (uint256(1) << BPC.KIND_V3) | (uint256(1) << BPC.KIND_ALGEBRA) | (uint256(1) << BPC.KIND_EXTERNAL);
    uint8   internal constant MODE_CREATE2_CLONE     = 6;
    uint8   internal constant MODE_V4_DERIVE         = 9;

    function _old(uint8 kind, uint8 mode, bytes32 initHash, uint24[] storage fees, int24[] storage spacings)
        internal view returns (bool)
    {
        if (((KINDS_ROUTABLE >> kind) & 1) == 0) return false; // invalidKind
        if (((MODES_VALID    >> mode) & 1) == 0) return false; // invalidMode
        if (
            mode >= MODE_CREATE2_V2
                && mode != MODE_V4_DERIVE && initHash == bytes32(0)
        ) return false;
        // aero-nova: `&& kind != BPC.KIND_SOLIDLY` added; the rest of the copy is 85720ef's.
        if (mode == MODE_CREATE2_V2 && kind != BPC.KIND_V2 && kind != BPC.KIND_SOLIDLY) return false;
        if (mode == MODE_CREATE2_CLONE && kind != BPC.KIND_SOLIDLY) return false;
        if (kind == BPC.KIND_EXTERNAL && mode != MODE_CREATE2_V3) return false;
        if (mode == MODE_CREATE2_V3) {
            if (((KINDS_V3_SALT >> kind) & 1) == 0) return false;
            if (kind == BPC.KIND_ALGEBRA) {
                for (uint256 i; i < fees.length; ) {
                    if (fees[i] != 0) return false;
                    unchecked { ++i; }
                }
            }
        }
        if (mode == MODE_V4_DERIVE) {
            if (kind != BPC.KIND_V4) return false;
            if (fees.length != spacings.length) return false;
        }
        return true;
    }
    // ---- end of the copy ----
    // (The arrays are storage pointers so the 65 536-cell loop copies nothing; the body is the
    // copy's, unchanged.)

    bytes32 internal ih_;
    uint24[] internal fees_;
    int24[] internal sp_;
    bytes32 internal e5_;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0xBEEF));
        hub.setRoles(address(this), address(this), address(this));
        e5_ = keccak256(abi.encodeWithSelector(BlazePhoenixHub.HubE.selector, uint256(5)));
    }

    /// s: 0 ([],[]) 1 ([0],[]) 2 ([500],[]) 3 ([0],[1]) 4 ([500],[1]) 5 ([],[1]) 6 ([0,500],[1,2])
    function _shape(uint256 s) internal {
        uint256 nf = (s == 0 || s == 5) ? 0 : (s == 6 ? 2 : 1);
        uint256 ns = s <= 2 ? 0 : (s == 6 ? 2 : 1);
        delete fees_;
        delete sp_;
        for (uint256 i; i < nf; ++i) fees_.push(0);
        for (uint256 i; i < ns; ++i) sp_.push(int24(int256(i + 1)));
        if (s == 2 || s == 4) fees_[0] = 500;
        if (s == 6) fees_[1] = 500;
    }

    /// Sweeps mode 0..mMax-1 x kind 0..kMax-1 under the current (ih_, fees_, sp_); returns the
    /// tallies [both refuse, both admit, mismatch, refused by other than HubE(5)].
    function _sweep(uint256 mMax, uint256 kMax) internal returns (uint256[4] memory n) {
        // Calldata is encoded once per sweep; each cell patches the last byte of ABI word 1 (kind,
        // memory cd+99) and word 2 (mode, cd+131). The low-level call keeps the stack shallow and
        // the memory flat.
        bytes memory cd = abi.encodeWithSelector(
            BlazePhoenixHub.addFactory.selector, FAC, uint8(0), uint8(0), ih_, fees_, sp_);
        // The snapshot id stays on the stack: a storage copy would be rolled back by the first
        // revertToState to the value it had before the snapshot was taken.
        uint256 snap = vm.snapshotState();
        for (uint256 m; m < mMax; ++m) {
            for (uint256 k; k < kMax; ++k) {
                ++n[_one(cd, m, k, snap)];
            }
        }
    }

    /// One (mode, kind) cell: 0 both refuse, 1 both admit, 2 mismatch, 3 refused by other than HubE(5).
    function _one(bytes memory cd, uint256 m, uint256 k, uint256 snap) internal returns (uint256 code) {
        bool want = _old(uint8(k), uint8(m), ih_, fees_, sp_);
        address h = address(hub);
        bytes32 e5 = e5_;
        bool got;
        bool isE5;
        assembly ("memory-safe") {
            mstore8(add(cd, 99), k)
            mstore8(add(cd, 131), m)
            got := call(gas(), h, 0, add(cd, 32), mload(cd), 0, 0)
            let p := mload(0x40)
            returndatacopy(p, 0, returndatasize())
            isE5 := eq(keccak256(p, returndatasize()), e5)
        }
        if (got != want) {
            code = 2;
            emit log_named_uint("mismatch mode", m);
            emit log_named_uint("         kind", k);
        } else if (got) {
            code = 1;
        } else if (!isE5) {
            code = 3;
        }
        if (got) vm.revertToState(snap);
    }

    function _judge(uint256[4] memory n, uint256 admitted) internal pure {
        assertEq(n[2], 0, "admission differs from the 85720ef predicate");
        assertEq(n[3], 0, "a refusal other than HubE(5)");
        assertEq(n[1], admitted, "the admitted cells are the 85720ef count");
    }

    /// @notice The whole (mode, kind) grid without an init-code hash: the live door admits
    ///         exactly the cells the 85720ef predicate admits. Only the modes that need no hash
    ///         admit: 0-3 with the 5 lookup kinds, and (9, V4): 5 x 4 + 1 = 21.
    function test_AddFactoryAdmitsExactlyThe85720efCellsWithoutAHash() public {
        vm.pauseGasMetering(); // 65 536 calls are above the test gas limit; the proof is the tally
        _shape(0);
        ih_ = bytes32(0);
        _judge(_sweep(256, 256), 21);
    }

    /// @notice The whole (mode, kind) grid with an init-code hash: the 5 lookup kinds in each
    ///         of the modes 0-3 and 7 (25), plus (4, V2), (4, SOLIDLY) (aero-nova), (5, V3),
    ///         (5, ALGEBRA), (5, EXTERNAL), (6, SOLIDLY) and (9, V4): 32.
    function test_AddFactoryAdmitsExactlyThe85720efCellsWithAHash() public {
        vm.pauseGasMetering(); // 65 536 calls are above the test gas limit; the proof is the tally
        _shape(0);
        ih_ = bytes32(uint256(1));
        _judge(_sweep(256, 256), 32);
    }

    /// @notice The fee/spacing extras on every mode with a row and every kind below 16: the
    ///         Algebra zero-fee rule and the V4 pairing rule refuse the same cells as at 85720ef.
    function test_AddFactoryExtrasRulesAreThe85720efOnes() public {
        for (uint256 h; h < 2; ++h) {
            ih_ = bytes32(h);
            for (uint256 s; s < 7; ++s) {
                _shape(s);
                uint256[4] memory n = _sweep(16, 16);
                assertEq(n[2], 0, "admission differs from the 85720ef predicate");
                assertEq(n[3], 0, "a refusal other than HubE(5)");
                assertGt(n[1], 0, "vacuous sweep");
            }
        }
    }

    /// The table has 16 bits per mode: a routable kind >= 16 would read the next mode's row.
    function test_RoutableKindsFitOneModeKindsRow() public {
        HubRoutableProbe p = new HubRoutableProbe();
        assertEq(p.routable() >> 16, 0, "a routable kind >= 16 bleeds into the next MODE_KINDS row");
        assertEq(p.routable(), KINDS_ROUTABLE, "the copied mask is the live one");
    }
}
