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
//  `Core.provenShape` for the family and the fee, and `Core.registryDepth18` - the
//  measurement `_recordHits` hands the registry after every swap - for the depth.
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

contract SeedDoorMeasuresWhatItWritesTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    MockERC20 A;
    MockERC20 B;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        solver = new BlazePhoenixSolver(address(hub));
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

    function test_TheOperatorDoorWritesTheFeeTheShapeReports() public {
        MockV3Pool p = new MockV3Pool(address(A), address(B), 3000);
        p.setState(uint160(BPC.Q96), 1e21);
        hub.seedPool(address(p), BPC.KIND_V3, 500, address(0), address(A), address(B));
        assertEq(BPC.decodeFee(hub.getSlot(_key(address(p)))), 3000,
            "the registry kept the declared fee, not the one the pool reports");
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
        hub.recordSwap(address(newcomer), BPC.KIND_V2, 30, address(0), address(A), address(B), 1, 1, 5e18);
        assertEq(hub.getPool(_key(address(newcomer))), address(newcomer),
            "the newcomer was refused by a bridge term only its rivals were scored with");
    }
}
