// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  DISCOVERY ASKS EACH DERIVATION ONCE.
//
//  A factory row carries a grid, `fees` by `spacings`, and `_scanFactory` used
//  to probe every cell of it. A probe is `BPC.deriveAddress`, and each mode
//  reads only some of the grid's inputs (Core `deriveAddress` / `_factoryLookup`):
//    mode 0 getPair(t0, t1)            mode 4 keccak(t0, t1)
//    mode 1 getPool(t0, t1, fee)       mode 5 keccak(t0, t1, fee)
//    mode 2 getPool(t0, t1, stable)    mode 6 keccak(t0, t1, stable)
//    mode 3 getPool(t0, t1, spacing)   mode 7 keccak(t0, t1, spacing)
//  So two cells that differ only in an input their mode never reads ask the
//  same question twice, and the answer can only be the pool the dedup drops or
//  the same absence. A V3 row of four fees by four spacings asked each pool
//  four times (the 5.0 census: 12 repeats of 16 probes on the Uniswap V3 row
//  of T00). `_axes` collapses such an axis to its first cell, the cell whose
//  hit the dedup kept. It reads the axes from two masks, `MODES_READ_FEE`
//  (modes 1, 5) and `MODES_READ_SPACING` (modes 3, 7): a hand copy of what
//  Core's `deriveAddress` reads, pinned here (SHARED_QUANTITIES.md).
//
//  1. The census (red before the fix): `deriveAddress` calls per row, read
//     from the state diff, equal the distinct questions the row's mode can ask.
//     Before: 9 per row (18 on a Solidly row), 3 on the rows with an empty axis.
//  2. The differential: the scan lists exactly what the whole grid lists when
//     it is replayed through `deriveAddress` itself, pool by pool, field by
//     field, in the same order. The pools a mode does not tell apart by an
//     axis are planted at that axis's LAST cell, so a mode that did read the
//     axis would derive a different address there and the scan, which asks
//     the first cell only, would miss it.
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixCore as BPC, PoolInfo} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";

/// @dev A factory of the four asking shapes (modes 0-3) for one pair, each answer settable by
///      the input its shape reads. No `poolByPair` and no 3-argument `getPair`: the two dialect
///      fallbacks revert, which reads as "no pool".
contract GridAskFactory {
    address public immutable t0;
    address public immutable t1;
    address public pair;
    mapping(uint24 => address) public byFee;
    mapping(bool => address) public byStable;
    mapping(int24 => address) public bySpacing;

    constructor(address a, address b) { (t0, t1) = a < b ? (a, b) : (b, a); }

    function setPair(address p) external { pair = p; }
    function setFee(uint24 f, address p) external { byFee[f] = p; }
    function setStable(bool s, address p) external { byStable[s] = p; }
    function setSpacing(int24 s, address p) external { bySpacing[s] = p; }

    function _ours(address a, address b) internal view returns (bool) { return a == t0 && b == t1; }

    function getPair(address a, address b) external view returns (address) {
        return _ours(a, b) ? pair : address(0);
    }
    function getPool(address a, address b, uint24 f) external view returns (address) {
        return _ours(a, b) ? byFee[f] : address(0);
    }
    function getPool(address a, address b, bool s) external view returns (address) {
        return _ours(a, b) ? byStable[s] : address(0);
    }
    function getPool(address a, address b, int24 s) external view returns (address) {
        return _ours(a, b) ? bySpacing[s] : address(0);
    }
}

contract DiscoveryProbesEachDerivationOnceTest is Test {
    BlazePhoenixHub hub;
    address t0;
    address t1;

    struct Row {
        address factory;
        uint8 kind;
        uint8 mode;
        bytes32 initHash;
        uint24[] fees;
        int24[] spacings;
    }

    Row[] rows;

    bytes4 constant DERIVE =
        bytes4(keccak256("deriveAddress(address,address,address,uint24,bool,int24,uint8,bytes32)"));

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        address a = address(new MockERC20("A", "A"));
        address b = address(new MockERC20("B", "B"));
        (t0, t1) = a < b ? (a, b) : (b, a);

        uint24[] memory fees = new uint24[](3);
        (fees[0], fees[1], fees[2]) = (100, 500, 3000);
        int24[] memory sps = new int24[](3);
        (sps[0], sps[1], sps[2]) = (1, 10, 60);

        // Asking rows. Row 1 has no pool at fee 500, row 2 none at stable = false, row 3 none
        // at spacing 10: the absences are probed too.
        GridAskFactory f0 = _asker(BPC.KIND_V2, 0, fees, sps);
        f0.setPair(_pair());
        GridAskFactory f1 = _asker(BPC.KIND_V3, 1, fees, sps);
        f1.setFee(100, _pair());
        f1.setFee(3000, _pair());
        GridAskFactory f2 = _asker(BPC.KIND_SOLIDLY, 2, fees, sps);
        f2.setStable(true, _pair());
        GridAskFactory f3 = _asker(BPC.KIND_V3, 3, fees, sps);
        f3.setSpacing(1, _pair());
        f3.setSpacing(60, _pair());

        // Deriving rows, codeless factories: a pool is code planted at the derived address.
        _deriver(makeAddr("grid factory 4"), BPC.KIND_V2, 4, fees, sps);
        _plant(4, 3000, false, 60);
        _deriver(makeAddr("grid factory 5"), BPC.KIND_V3, 5, fees, sps);
        _plant(5, 500, false, 60);
        _plant(5, 3000, false, 60);
        _deriver(makeAddr("grid factory 6"), BPC.KIND_SOLIDLY, 6, fees, sps);
        _plant(6, 3000, false, 60);
        _deriver(makeAddr("grid factory 7"), BPC.KIND_V3, 7, fees, sps);
        _plant(7, 3000, false, 10);
        _plant(7, 3000, false, 60);

        // An empty axis is one cell at 0, read or not.
        GridAskFactory f8 = _asker(BPC.KIND_V3, 1, new uint24[](0), sps);
        f8.setFee(0, _pair());
        GridAskFactory f9 = _asker(BPC.KIND_V3, 3, fees, new int24[](0));
        f9.setSpacing(0, _pair());
    }

    // ─── fixture ──────────────────────────────────────────────────────────

    function _pair() internal returns (address) { return address(new MockV2Pair(t0, t1)); }

    function _row(address f, uint8 kind, uint8 mode, bytes32 ih, uint24[] memory fees, int24[] memory sps)
        internal
    {
        hub.addFactory(f, kind, mode, ih, fees, sps);
        rows.push();
        Row storage w = rows[rows.length - 1];
        (w.factory, w.kind, w.mode, w.initHash) = (f, kind, mode, ih);
        for (uint256 i; i < fees.length; ++i) w.fees.push(fees[i]);
        for (uint256 i; i < sps.length; ++i) w.spacings.push(sps[i]);
    }

    function _asker(uint8 kind, uint8 mode, uint24[] memory fees, int24[] memory sps)
        internal returns (GridAskFactory f)
    {
        f = new GridAskFactory(t0, t1);
        _row(address(f), kind, mode, bytes32(0), fees, sps);
    }

    function _deriver(address f, uint8 kind, uint8 mode, uint24[] memory fees, int24[] memory sps) internal {
        _row(f, kind, mode, keccak256(abi.encode("grid", mode)), fees, sps);
    }

    /// Code at the address the last row of `mode` derives for (fee, stable, spacing).
    function _plant(uint8 mode, uint24 fee, bool stable, int24 sp) internal {
        Row storage w = rows[rows.length - 1];
        assertEq(w.mode, mode, "fixture: plant on the row just added");
        vm.etch(BPC.deriveAddress(w.factory, t0, t1, fee, stable, sp, mode, w.initHash), hex"00");
    }

    // ─── the census ───────────────────────────────────────────────────────

    /// One scan, with the `deriveAddress` calls it made counted per row (the factory is the
    /// call's first argument) and its gas.
    function _scan() internal returns (PoolInfo[] memory hits, uint256[] memory probes, uint256 gasUsed) {
        vm.startStateDiffRecording();
        uint256 g = gasleft();
        hits = hub.discoverFor(t1, t0);
        gasUsed = g - gasleft();
        VmSafe.AccountAccess[] memory recs = vm.stopAndReturnStateDiff();
        probes = new uint256[](rows.length);
        for (uint256 i; i < recs.length; ++i) {
            VmSafe.AccountAccess memory r = recs[i];
            if (r.kind != VmSafe.AccountAccessKind.DelegateCall || r.data.length < 36) continue;
            if (bytes4(r.data) != DERIVE) continue;
            bytes memory d = r.data;
            address f;
            assembly { f := mload(add(d, 36)) }
            for (uint256 w; w < rows.length; ++w) if (rows[w].factory == f) ++probes[w];
        }
    }

    /// The distinct questions each row can ask: the cells of the axes its mode reads, times
    /// two on a Solidly row (`stable`), one cell for an empty axis.
    function test_EachDerivationIsAskedOnce() public {
        (, uint256[] memory probes, uint256 gasUsed) = _scan();
        emit log_named_uint("discoverFor gas, ten rows", gasUsed);
        uint8[10] memory want = [1, 3, 2, 3, 1, 3, 2, 3, 1, 1];
        assertEq(rows.length, want.length, "fixture: ten rows");
        uint256 total;
        for (uint256 w; w < rows.length; ++w) {
            emit log_named_uint(string.concat("row ", vm.toString(w), " probes"), probes[w]);
            total += probes[w];
        }
        for (uint256 w; w < rows.length; ++w) {
            assertEq(
                probes[w], uint256(want[w]),
                string.concat("row ", vm.toString(w), " (mode ", vm.toString(rows[w].mode), ") asked a question twice")
            );
        }
        assertEq(total, 20, "twenty distinct questions");
    }

    // ─── the differential ─────────────────────────────────────────────────

    /// The grid as it was asked before: every fee cell by every spacing cell, both `stable`
    /// variants on a Solidly row, through the producer itself, with `_probe`'s three filters
    /// (code at the address; an asked pool proves its own pair; the first listing wins).
    function _everyCell() internal view returns (PoolInfo[] memory out) {
        out = new PoolInfo[](256);
        uint256 k;
        for (uint256 r; r < rows.length; ++r) {
            Row storage w = rows[r];
            uint256 nf = w.fees.length == 0 ? 1 : w.fees.length;
            uint256 ns = w.spacings.length == 0 ? 1 : w.spacings.length;
            uint256 nv = (w.mode == 2 || w.mode == 6) ? 2 : 1;
            for (uint256 fi; fi < nf; ++fi) {
                uint24 fee = w.fees.length == 0 ? 0 : w.fees[fi];
                for (uint256 si; si < ns; ++si) {
                    int24 sp = w.spacings.length == 0 ? int24(0) : w.spacings[si];
                    for (uint256 v; v < nv; ++v) k = _cell(w, fee, v == 1, sp, out, k);
                }
            }
        }
        assembly { mstore(out, k) }
    }

    function _cell(Row storage w, uint24 fee, bool st, int24 sp, PoolInfo[] memory out, uint256 k)
        internal view returns (uint256)
    {
        address p = BPC.deriveAddress(w.factory, t0, t1, fee, st, sp, w.mode, w.initHash);
        if (p == address(0) || p.code.length == 0) return k;
        if (w.mode < 4 && (MockV2Pair(p).token0() != t0 || MockV2Pair(p).token1() != t1)) return k;
        for (uint256 d; d < k; ++d) if (out[d].pool == p) return k;
        out[k] = PoolInfo({
            active: true, stable: st, kind: w.kind, fee: fee, tickSpacing: sp,
            token0: t0, token1: t1, pool: p, hooks: address(0)
        });
        return k + 1;
    }

    function test_ScanListsWhatEveryCellLists() public view {
        PoolInfo[] memory got = hub.discoverFor(t0, t1);
        PoolInfo[] memory ref = _everyCell();
        assertEq(ref.length, 14, "fixture: fourteen pools");
        assertEq(got.length, ref.length, "the scan lists as many pools as the whole grid");
        for (uint256 i; i < ref.length; ++i) {
            string memory where = string.concat(" at listing ", vm.toString(i));
            assertEq(got[i].pool, ref[i].pool, string.concat("pool", where));
            assertEq(got[i].fee, ref[i].fee, string.concat("fee", where));
            assertEq(got[i].tickSpacing, ref[i].tickSpacing, string.concat("tickSpacing", where));
            assertEq(got[i].stable, ref[i].stable, string.concat("stable", where));
            assertEq(got[i].kind, ref[i].kind, string.concat("kind", where));
            assertEq(got[i].token0, ref[i].token0, string.concat("token0", where));
            assertEq(got[i].token1, ref[i].token1, string.concat("token1", where));
            assertEq(got[i].active, ref[i].active, string.concat("active", where));
            assertEq(got[i].hooks, ref[i].hooks, string.concat("hooks", where));
        }
    }
}
