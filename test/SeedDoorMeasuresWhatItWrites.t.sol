// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  THE OPERATOR'S DOOR MEASURES WHAT IT WRITES, LIKE EVERY OTHER DOOR.
//
//  The registry has three doors. The swap door (`recordSwap`) refutes a declared
//  kind by the pool's shape, measures the fee where the shape reports one, and
//  seals the row at the depth the Router measured. The V4 claim door seals at
//  the depth it reads from the singleton. The operator's door (`seedPool`) wrote
//  kind and fee as declared and sealed every row at depth bucket 0, and a row is
//  only re-read when a swap ticks it - so a mis-declared row kept its error, and
//  a deep pool seeded cold ranked below dust that had been swapped twice, fell
//  out of the funnel's top-K, and was never swapped to be corrected.
//
//  And admission scored a newcomer without the pair's bridge term while scoring
//  every incumbent with it - the term `_pairBridged` declares uniform across a
//  pair, "so the bonus can no longer reorder anything".
//
//  The operator's door now asks the swap door's questions of the same producers:
//  `Core.provenShape` for the family, `Hub._concRowFee` for a concentrated row's fee
//  (the tier its derivation is keyed by when the pool agrees, else 0, the live read:
//  aero-nova 2026-10-26, a fee() snapshot is not a key), and `Core.registryDepth18` -
//  the measurement `_recordHits` hands the registry after every swap - for the depth.
//
//  Reported by mohaseenbasha (dex-16, dex-17, dex-12), ninth bounty wave.
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixCore as BPC, RoutePlan} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";
import {MockV3Pool} from "./mocks/MockV3Pool.sol";
import {MockSolidlyPair} from "./mocks/MockSolidlyPair.sol";
import {MockAlgebraPool} from "./mocks/MockAlgebraPool.sol";
import {Origin} from "./mocks/MockOriginFactory.sol";

contract SeedDoorMeasuresWhatItWritesTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    MockERC20 A;
    MockERC20 B;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        solver = new BlazePhoenixSolver(address(hub), address(0));
        // This contract stands in for the Router on `recordSwap`: the depth it passes is
        // the one the Router would have measured on the same pool.
        hub.setRoles(address(this), address(solver), address(this));
        A = new MockERC20("A", "A");
        B = new MockERC20("B", "B");
    }

    function _v2(uint256 r) internal returns (MockV2Pair p) {
        p = new MockV2Pair(address(A), address(B));
        A.mint(address(p), r);
        B.mint(address(p), r);
        p.setReserves(uint112(r), uint112(r));
    }

    function _key(address pool) internal view returns (bytes32) { return hub.keyOf(pool, address(A), address(B)); }

    /// Swaps recorded until the row's count reaches `n`, each at the given measured depth.
    function _warm(address pool, uint256 depthWad, uint32 n) internal {
        while (BPC.decodeSwapCount(hub.getSlot(_key(pool))) < n) {
            hub.recordSwap(pool, BPC.KIND_V2, 30, address(0), address(A), address(B), 1, 1, depthWad);
        }
    }

    // ── dex-16: kind and fee ───────────────────────────────────────────────────

    function test_TheOperatorDoorRefusesAKindTheShapeContradicts() public {
        MockV3Pool p = new MockV3Pool(address(A), address(B), 3000);
        p.setState(uint160(BPC.Q96), 1e21);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixHub.HubE.selector, uint16(4)));
        hub.seedPool(address(p), BPC.KIND_V2, 30, address(0), address(A), address(B));
    }

    /// The declared 500 never prices a pool that charges 3000. No wired factory derives this
    /// pool, so its row reads the pool live (0); a derived one carries its tier (below).
    function test_TheOperatorDoorWritesTheFeeTheShapeReports() public {
        MockV3Pool p = new MockV3Pool(address(A), address(B), 3000);
        p.setState(uint160(BPC.Q96), 1e21);
        hub.seedPool(address(p), BPC.KIND_V3, 500, address(0), address(A), address(B));
        uint24 row = BPC.decodeFee(hub.getSlot(_key(address(p))));
        assertEq(row, 0, "a pool no wired factory derives must read live, not keep a snapshot");
        assertEq(BPC.quoteV3Fee(address(p), row, 0, false), 3000,
            "the registry kept the declared fee, not the one the pool reports");
    }

    /// The same door, the same producer as the swap door: a pool a wired factory derives at the
    /// tier it charges is written at that tier, a static key no quote has to ask again.
    function test_TheOperatorDoorWritesTheDerivedTierWhenThePoolAgrees() public {
        MockV3Pool p = new MockV3Pool(address(A), address(B), 3000);
        p.setState(uint160(BPC.Q96), 1e21);
        Origin.wire(hub, address(p), address(A), address(B), BPC.KIND_V3, 3000);
        hub.seedPool(address(p), BPC.KIND_V3, 500, address(0), address(A), address(B));
        assertEq(BPC.decodeFee(hub.getSlot(_key(address(p)))), 3000,
            "a derived tier the pool agrees with is the row's static fee");
    }

    // ── dex-17: a seeded row is born at the depth measured at the door ─────────

    function test_ASeededDeepPoolIsNotCutFromTheFunnelByWarmDust() public {
        MockV2Pair deep = _v2(1e24);
        hub.seedPool(address(deep), BPC.KIND_V2, 30, address(0), address(A), address(B));
        for (uint256 i; i < 8; ++i) {                     // the funnel keeps eight
            MockV2Pair dust = _v2(1e14);
            hub.seedPool(address(dust), BPC.KIND_V2, 30, address(0), address(A), address(B));
            _warm(address(dust), 1e14, 3);
        }
        uint256 order = 1e21;
        uint256 deepAlone = BPC.outV2(order, 1e24, 1e24, 30);
        try solver.findBestRoutePlan(address(A), address(B), order) returns (RoutePlan memory plan) {
            bool deepRouted;
            for (uint256 i; i < plan.best.hops[0].legs.length; ++i) {
                if (plan.best.hops[0].legs[i].pool == address(deep)) deepRouted = true;
            }
            assertTrue(deepRouted, "the seeded deep pool was cut from the funnel by warm dust");
            assertGe(plan.best.totalOut, deepAlone * 99 / 100, "and the order was not given its depth");
        } catch {
            assertTrue(false, "no route at all: the only deep pool on the pair was cut from the funnel");
        }
    }

    /// Red against mutant [270] of .github/scripts/mutants.py at 59ecf3f; green on 59ecf3f.
    /// Re-armed on 3e150b4, red against [270] there and green without it: since poda-1027 no
    /// count cuts the funnel (`Solver._dropDust` weighs every row's live depth against the
    /// pair's) and `_seatDeepest` is gone, so the bucket a row was born at no longer decides
    /// whether it is quoted, and eight warm dust rows passed this test with every seeded row
    /// born at bucket 0 (mutation guard, PR #112).
    ///
    /// WHERE THE BUCKET STILL RANKS A ROW: THE PAIR'S SIXTEEN SEATS. `_register` evicts the row
    /// of lowest psi (vitality x 2^bucket, ties to the shallower bucket) and `_canInsert` admits
    /// a newcomer only above the weakest incumbent's psi plus a quarter. A seeded row has never
    /// been swapped (vitality 1), so only its bucket ranks it above warm dust. Born at the
    /// bucket measured at the door, the two deep rows score 512 and 256 against warm dust's 3,
    /// and a newcomer at bucket 1 (weight 2) is refused (2 > 3 + 3/4 is false). Born at bucket
    /// 0, each deep row scores 1: the same newcomer is admitted (2 > 1 + 1/4) over the first of
    /// them and a second one evicts the other - and an evicted row is never swapped to be
    /// corrected. Both deep rows must keep their seats, and the order both pools' depth.
    function test_ASecondSeededDeepPoolOutranksWarmDustWithoutTheGuaranteedSeat() public {
        MockV2Pair deeper = _v2(1e24);
        MockV2Pair deep = _v2(5e23);
        hub.seedPool(address(deeper), BPC.KIND_V2, 30, address(0), address(A), address(B));
        hub.seedPool(address(deep), BPC.KIND_V2, 30, address(0), address(A), address(B));
        for (uint256 i; i < 14; ++i) {                    // with the two deep rows, the pair's 16 (MAX_SLOTS)
            MockV2Pair dust = _v2(1e14);
            hub.seedPool(address(dust), BPC.KIND_V2, 30, address(0), address(A), address(B));
            _warm(address(dust), 1e14, 3);
        }
        assertEq(hub.getActivePools(address(A), address(B)).length, 16, "setup: the pair must hold its sixteen rows");
        // Two newcomers at the swap door, each a pool a wired factory derives (rizki-3107), at
        // depth bucket 1.
        for (uint256 i; i < 2; ++i) {
            MockV2Pair newcomer = _v2(1e16);
            Origin.wire(hub, address(newcomer), address(A), address(B), BPC.KIND_V2, 30);
            hub.recordSwap(address(newcomer), BPC.KIND_V2, 30, address(0), address(A), address(B), 1, 1, 1e16);
        }
        assertEq(hub.getPool(_key(address(deeper))), address(deeper), "a seeded deep pool was evicted below warm dust");
        assertEq(hub.getPool(_key(address(deep))), address(deep), "the second seeded deep pool was evicted below warm dust");
        uint256 order = 1e23;
        // Two equal-price constant-product pools at the same fee, split in proportion to their
        // reserves, pay what one pool holding both would: the most this order can get.
        uint256 bothDeep = BPC.outV2(order, 15e23, 15e23, 30);
        try solver.findBestRoutePlan(address(A), address(B), order) returns (RoutePlan memory plan) {
            bool deepRouted;
            for (uint256 i; i < plan.best.hops[0].legs.length; ++i) {
                if (plan.best.hops[0].legs[i].pool == address(deep)) deepRouted = true;
            }
            assertTrue(deepRouted, "the second seeded deep pool was cut from the funnel by warm dust");
            assertGe(plan.best.totalOut, bothDeep * 99 / 100, "and the order was not given both pools' depth");
        } catch {
            assertTrue(false, "no route at all on a pair holding two deep pools");
        }
    }

    // ── dex-12: the pair's bridge term is the newcomer's too ───────────────────

    function test_ANewcomerOnABridgedPairCarriesTheBridgeTermItsRivalsCarry() public {
        hub.addBridge(address(B));
        // Sixteen incumbents (MAX_SLOTS), each at depth bucket 1 (weight 2) and three swaps:
        // fitness 6 bare, 7 with the bridge term.
        for (uint256 i; i < 16; ++i) {
            MockV2Pair inc = _v2(5e16);
            hub.seedPool(address(inc), BPC.KIND_V2, 30, address(0), address(A), address(B));
            _warm(address(inc), 5e16, 3);
        }
        // A newcomer at depth bucket 3 (weight 8). With the term on both sides it scores 10
        // against a bar of 7 + 7/4 = 8; without it on its own side, 8 against 8.
        MockV2Pair newcomer = _v2(5e18);
        // rizki-3107: the swap door seats only a pool a wired factory derives; derived, the
        // newcomer is refused or seated by the score alone.
        Origin.wire(hub, address(newcomer), address(A), address(B), BPC.KIND_V2, 30);
        hub.recordSwap(address(newcomer), BPC.KIND_V2, 30, address(0), address(A), address(B), 1, 1, 5e18);
        assertEq(hub.getPool(_key(address(newcomer))), address(newcomer),
            "the newcomer was refused by a bridge term only its rivals were scored with");
    }

    // ── dex-16 and dex-17 across the matrix: every real shape under every declared family ──

    function _shape(uint256 s) internal returns (address pool) {
        if (s == 0) { MockV2Pair p = new MockV2Pair(address(A), address(B)); p.setReserves(uint112(1e24), uint112(1e24)); pool = address(p); }
        else if (s == 1) { MockSolidlyPair p = new MockSolidlyPair(address(A), address(B), false); p.setReserves(uint112(1e24), uint112(1e24)); pool = address(p); }
        else if (s == 2) { MockV3Pool p = new MockV3Pool(address(A), address(B), 3000); p.setState(uint160(BPC.Q96), 1e21); pool = address(p); }
        else { MockAlgebraPool p = new MockAlgebraPool(address(A), address(B), 500); p.setState(uint160(BPC.Q96), 1e21); pool = address(p); }
        A.mint(pool, 1e24);
        B.mint(pool, 1e24);
    }

    /// Four real shapes - a V2 pair, a Solidly pair, a V3 pool, an Algebra pool - each declared
    /// as each of the four families. A pair declared concentrated, or a concentrated pool declared
    /// a pair, is refused; within a family the shape decides the kind, a concentrated pool no
    /// wired factory derives reads its fee live (row 0, priced at what it charges), and every
    /// admitted row is sealed at the bucket the one depth producer
    /// measures at the door.
    function test_EveryShapeUnderEveryDeclaredFamilyIsWrittenAsTheShapeAnswers() public {
        uint8[4] memory fam = [BPC.KIND_V2, BPC.KIND_SOLIDLY, BPC.KIND_V3, BPC.KIND_ALGEBRA];
        (address t0, address t1) = address(A) < address(B) ? (address(A), address(B)) : (address(B), address(A));
        for (uint256 s; s < 4; ++s) {
            for (uint256 d; d < 4; ++d) {
                address pool = _shape(s);
                if ((s >= 2) != (d >= 2)) {
                    vm.expectRevert(abi.encodeWithSelector(BlazePhoenixHub.HubE.selector, uint16(4)));
                    hub.seedPool(pool, fam[d], 30, address(0), address(A), address(B));
                    continue;
                }
                hub.seedPool(pool, fam[d], 30, address(0), address(A), address(B));
                uint256 slot = hub.getSlot(_key(pool));
                assertEq(BPC.decodeKind(slot), fam[s], "the row's family is not the one the shape answers");
                assertEq(BPC.decodeFee(slot), s >= 2 ? 0 : 30,
                    "the row's fee is not the one the shape reports");
                if (s == 2) assertEq(BPC.quoteV3Fee(pool, uint24(BPC.decodeFee(slot)), 0, false), 3000,
                    "a concentrated row must price at the fee its pool charges");
                assertEq(BPC.decodeBucket(slot),
                    BPC.depthBucket(BPC.registryDepth18(pool, fam[s], t0, t1, address(0), bytes32(0))),
                    "the row is not sealed at the depth measured at the door");
            }
        }
    }
}
