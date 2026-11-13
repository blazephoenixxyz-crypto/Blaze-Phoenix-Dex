// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  BASE-GAS (2026-11-13) - THE SWAP DOOR PROVES ORIGIN AT THE NAMED FEE CELL FIRST.
//
//  On e01b503 `Hub.recordSwap` proved a pool's origin (rizki-3107) by running the whole
//  discovery sweep, `discoverFor`, on every cold first registration: every fee cell of
//  every wired row, one CREATE2 derivation and one code probe each. The fix tries first the
//  one cell per row that the swap's own `fee` names, with the producer the sweep walks
//  (`_scanFeeCell`, `_probe`), and keeps the sweep as the fallback. The fee is a
//  COORDINATE, never a fact: a hit at the named cell is a pool the sweep lists, and a miss
//  falls to the sweep, which decides. Lying about the fee only costs the liar the sweep.
//
//  Red on e01b503: test_TargetedOrigin_CostsLessThanTheSweep (both paths ran the sweep).
//  The other tests are guards of the fallback and of the monotonicity against the caller
//  (green on e01b503 too, by design: the fix must not change who is seated, or at what fee).
//  Mutants: .github/scripts/mutants.py, section BASE-GAS, and rizki-3107 [465]/[466].
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, PoolInfo} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";
import {MockV2Factory} from "./mocks/MockV2Factory.sol";
import {MockV3Pool} from "./mocks/MockV3Pool.sol";

/// A deployer the Hub does not wire: same init code, same salt, a different CREATE2 origin.
contract UnwiredV3Deployer {
    function deploy(address a, address b, uint24 fee, bytes32 salt) external returns (address) {
        return address(new MockV3Pool{salt: salt}(a, b, fee));
    }
}

contract RecordSwapTargetedOriginTest is Test {
    BlazePhoenixHub    hub;
    BlazePhoenixSolver solver;
    BlazePhoenixRouter router;
    MockERC20  tokenA;
    MockERC20  tokenB;
    MockV2Pair honest;
    MockV2Factory factory;

    address t0;
    address t1;
    MockV3Pool poolV3;
    bytes32 initHashV3;

    uint24 constant FEE = 3000;
    uint112 constant DEEP = uint112(3_000_000e18);
    /// Rows: the mode-0 factory (setUp) + the V3 row + at most 14 noise rows = MAX_FACTORIES.
    uint256 constant MAX_NOISE = 14;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        solver = new BlazePhoenixSolver(address(hub), address(0));
        router = new BlazePhoenixRouter(
            address(hub), address(solver), address(this), address(0xFEE1), address(0xFEE2));
        hub.setRoles(address(router), address(solver), address(this));

        tokenA = new MockERC20("A", "A");
        tokenB = new MockERC20("B", "B");
        (t0, t1) = address(tokenA) < address(tokenB)
            ? (address(tokenA), address(tokenB)) : (address(tokenB), address(tokenA));

        honest = new MockV2Pair(address(tokenA), address(tokenB));
        tokenA.mint(address(honest), DEEP);
        tokenB.mint(address(honest), DEEP);
        honest.setReserves(DEEP, DEEP);
        hub.seedPool(address(honest), BPC.KIND_V2, 30, address(0), address(tokenA), address(tokenB));
        factory = new MockV2Factory();
        hub.addFactory(address(factory), BPC.KIND_V2, 0, bytes32(0), new uint24[](0), new int24[](0));
        factory.setPair(address(tokenA), address(tokenB), address(honest));

        // The V3 pool this contract deploys by CREATE2 at the 3000 tier (mode 5, v3Salt).
        poolV3 = new MockV3Pool{salt: keccak256(abi.encode(t0, t1, FEE))}(t0, t1, FEE);
        poolV3.setState(uint160(2 ** 96), 1e24);
        initHashV3 = keccak256(abi.encodePacked(type(MockV3Pool).creationCode, abi.encode(t0, t1, FEE)));
    }

    // ── fixtures ─────────────────────────────────────────────────────────────

    function _tiers() internal pure returns (uint24[] memory f) {
        f = new uint24[](4);
        (f[0], f[1], f[2], f[3]) = (100, 500, 3000, 10000);
    }

    /// Wires `nNoise` mode-5 rows whose derivations land on empty addresses at every tier, and
    /// the V3 row (this contract, `initHashV3`) at position `v3At` among them. At the 100, 500
    /// and 10000 tiers the V3 row itself derives addresses with no code.
    function _wire(uint256 nNoise, uint256 v3At) internal {
        for (uint256 i; i <= nNoise; ++i) {
            if (i == v3At) hub.addFactory(address(this), BPC.KIND_V3, 5, initHashV3, _tiers(), new int24[](0));
            if (i < nNoise) {
                hub.addFactory(address(uint160(0xF000 + i)), BPC.KIND_V3, 5,
                    keccak256(abi.encode("noise", i)), _tiers(), new int24[](0));
            }
        }
        assertEq(BPC.deriveAddress(address(this), t0, t1, FEE, false, 0, 5, initHashV3), address(poolV3),
            "fixture: the V3 row derives poolV3 at 3000");
    }

    function _key(address p) internal view returns (bytes32) {
        return hub.keyOf(p, address(tokenA), address(tokenB));
    }

    function _seated(address p) internal view returns (bool) {
        return hub.getPool(_key(p)) == p;
    }

    function _record(address p, uint8 kind, uint24 fee) internal {
        vm.prank(address(router));
        hub.recordSwap(p, kind, fee, address(0), address(tokenA), address(tokenB), 1e15, 1e15, 30_000e18);
    }

    function _gasOf(address p, uint8 kind, uint24 fee) internal returns (uint256 g) {
        vm.prank(address(router));
        g = gasleft();
        hub.recordSwap(p, kind, fee, address(0), address(tokenA), address(tokenB), 1e15, 1e15, 30_000e18);
        g -= gasleft();
    }

    /// The sweep's verdict: listed by `discoverFor`, and at which fee.
    function _sweep(address p) internal view returns (bool listed, uint24 fee) {
        PoolInfo[] memory hits = hub.discoverFor(address(tokenA), address(tokenB));
        for (uint256 i; i < hits.length; ++i) if (hits[i].pool == p) return (true, hits[i].fee);
    }

    function _trap() internal returns (address) {
        MockV2Pair p = new MockV2Pair(address(tokenA), address(tokenB));
        tokenA.mint(address(p), 30_000e18);
        tokenB.mint(address(p), 30_000e18);
        p.setReserves(uint112(30_000e18), uint112(30_000e18));
        return address(p);
    }

    function _unwiredV3() internal returns (address p) {
        UnwiredV3Deployer dep = new UnwiredV3Deployer();
        p = dep.deploy(t0, t1, FEE, keccak256(abi.encode(t0, t1, FEE)));
        MockV3Pool(p).setState(uint160(2 ** 96), 1e24);
        assertEq(keccak256(p.code), keccak256(address(poolV3).code), "fixture: same runtime code");
        assertTrue(p != address(poolV3), "fixture: another CREATE2 origin");
    }

    // ── gas: the named cell is cheaper than the sweep (relational, no threshold) ──

    /// The honest fee proves the pool at its own cell; the lied fee misses every named cell and
    /// pays the sweep. Honest runs FIRST, so any warmth the second run inherits favours the liar:
    /// on e01b503 both run the same sweep and this assertion is red.
    function test_TargetedOrigin_CostsLessThanTheSweep() public {
        uint256[2] memory ns = [uint256(1), MAX_NOISE];
        for (uint256 j; j < 2; ++j) {
            uint256 snap = vm.snapshotState();
            _wire(ns[j], ns[j]);                       // the V3 row last: the targeted path's worst row order
            uint256 s2 = vm.snapshotState();
            uint256 gHonest = _gasOf(address(poolV3), BPC.KIND_V3, FEE);
            assertTrue(_seated(address(poolV3)), "non-vacuity: the honest fee seats poolV3");
            vm.revertToState(s2);
            assertFalse(_seated(address(poolV3)), "non-vacuity: the revert unseated it");
            uint256 gLiar = _gasOf(address(poolV3), BPC.KIND_V3, 100);
            assertTrue(_seated(address(poolV3)), "non-vacuity: the lied fee still seats poolV3 (fallback)");
            emit log_named_uint("noise rows", ns[j]);
            emit log_named_uint("gas, honest fee (named cell)", gHonest);
            emit log_named_uint("gas, lied fee (sweep fallback)", gLiar);
            assertLt(gHonest, gLiar, "the named cell must cost less than the sweep");
            vm.revertToState(snap);
        }
    }

    // ── parity: the targeted path seats exactly what the sweep lists, at the sweep's fee ──

    function test_TargetedOrigin_AgreesWithTheSweep(uint24 fee, uint256 seed) public {
        if (seed & 1 == 0) fee = _tiers()[(seed >> 1) % 4];   // the tiers, boundaries 100 and 10000 included
        uint256 nNoise = bound(seed >> 8, 0, MAX_NOISE);
        _wire(nNoise, bound(seed >> 16, 0, nNoise));
        address[4] memory pools = [address(honest), address(poolV3), _trap(), _unwiredV3()];
        uint8[4] memory kinds = [BPC.KIND_V2, BPC.KIND_V3, BPC.KIND_V2, BPC.KIND_V3];
        for (uint256 i; i < 4; ++i) {
            (bool listed, uint24 hitFee) = _sweep(pools[i]);
            uint256 snap = vm.snapshotState();
            _record(pools[i], kinds[i], fee);
            assertEq(_seated(pools[i]), listed, "seated by swap iff the sweep lists it");
            if (listed && kinds[i] == BPC.KIND_V3) {
                assertEq(BPC.decodeFee(hub.getSlot(_key(pools[i]))), hitFee, "idFee is the sweep's");
            }
            vm.revertToState(snap);
        }
        // non-vacuity: the fixture holds one listed pool of each kind and two unlisted ones
        (bool l1, ) = _sweep(address(poolV3));
        (bool l2, ) = _sweep(pools[2]);
        (bool l3, ) = _sweep(pools[3]);
        assertTrue(l1 && !l2 && !l3, "non-vacuity: poolV3 listed, the trap and the unwired pool not");
    }

    // ── a lied fee: the sweep decides, and the row keeps the derivation's fee (REG-01) ──

    function test_LiedFee_FallsBackAndSeatsWithTheDerivationFee() public {
        _wire(1, 1);
        PoolInfo[] memory hits = hub.discoverFor(address(tokenA), address(tokenB));
        assertEq(hits[0].pool, address(honest), "non-vacuity: poolV3 is not the sweep's first hit");
        assertFalse(BPC.deriveAddress(address(this), t0, t1, 500, false, 0, 5, initHashV3).code.length > 0,
            "non-vacuity: the named cell (500) derives no pool");
        _record(address(poolV3), BPC.KIND_V3, 500);
        assertTrue(_seated(address(poolV3)), "a derived pool named at a lied fee must still be seated by the sweep");
        assertEq(BPC.decodeFee(hub.getSlot(_key(address(poolV3)))), FEE,
            "the row's fee is the derivation's (3000), never calldata's (500)");
    }

    // ── hostile pool at a valid fee: the cell is a coordinate, not a voucher ──

    function test_AttackerPoolWithValidFee_IsRefused() public {
        _wire(1, 0);
        MockV3Pool p = new MockV3Pool(t0, t1, FEE);
        p.setState(uint160(2 ** 96), 1e24);
        assertEq(p.fee(), FEE, "non-vacuity: the pool answers the named fee");
        (bool listed, ) = _sweep(address(p));
        assertFalse(listed, "non-vacuity: the sweep does not list it");
        _record(address(p), BPC.KIND_V3, FEE);
        assertFalse(_seated(address(p)), "a pool no row derives took a seat by naming a valid fee");
        assertEq(hub.getSlot(_key(address(p))), 0, "the refused pool left a slot behind");
    }

    // ── same init code, same salt, wrong CREATE2 origin ──

    function test_WrongFactoryPool_IsRefused() public {
        _wire(1, 0);
        address p = _unwiredV3();
        _record(p, BPC.KIND_V3, FEE);
        assertFalse(_seated(p), "a pool from an unwired deployer took a seat");
        assertEq(hub.getSlot(_key(p)), 0, "the refused pool left a slot behind");
        _record(address(poolV3), BPC.KIND_V3, FEE);
        assertTrue(_seated(address(poolV3)), "positive control: the wired origin is seated");
    }
}
