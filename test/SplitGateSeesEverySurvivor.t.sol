// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  A SPLIT MUST BEAT EVERY SINGLE LEG IT COULD HAVE TAKEN, NOT TWO OF THEM.
//
//  The min-split gate collapses a split that does not beat the best single leg
//  by MIN_SPLIT_IMPROVEMENT_PPM. It measured two candidates at full size: the
//  deepest survivor and the one with the best marginal rate. With three or more
//  survivors the best single leg at full size can be neither - a pool of middle
//  depth and middle price, which is exactly the pool a large order wants - and
//  a split that beat both representatives but not that pool was kept.
//
//  The oracle is the V2 closed form at full size, computed here for every pool;
//  no Solver figure decides what the best single leg is.
//
//  Reported by Brian Wahyu, ninth bounty wave.
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixCore as BPC, RoutePlan} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";

contract SplitGateSeesEverySurvivorTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    MockERC20 A;
    MockERC20 B;

    uint256 constant ORDER = 1e20;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        solver = new BlazePhoenixSolver(address(hub));
        A = new MockERC20("A", "A");
        B = new MockERC20("B", "B");
    }

    function _pool(uint256 rA, uint256 rB) internal returns (MockV2Pair p) {
        p = new MockV2Pair(address(A), address(B));
        A.mint(address(p), rA);
        B.mint(address(p), rB);
        (uint256 r0, uint256 r1) = address(A) < address(B) ? (rA, rB) : (rB, rA);
        p.setReserves(uint112(r0), uint112(r1));
        hub.seedPool(address(p), BPC.KIND_V2, 30, address(0), address(A), address(B));
    }

    /// Three pools inside the believability band (all within 5% of the deep pool's
    /// price, which anchors the depth-weighted median):
    ///   D - the deepest, at 0.985: the depth representative;
    ///   R - the best marginal rate, 1.030, but shallow: 10% of the order moves it;
    ///   X - middle depth, middle price, 1.010: the best single leg for this order.
    function test_TheGateComparesTheSplitWithEverySurvivorAtFullSize() public {
        uint256[3] memory rA = [uint256(1e24), 1e22, 1e21];
        uint256[3] memory rB = [uint256(985e21), 101e20, 103e19];
        uint256 bestSingle;
        uint256 bestIdx;
        for (uint256 i; i < 3; ++i) {
            _pool(rA[i], rB[i]);
            uint256 o = BPC.outV2(ORDER, rA[i], rB[i], 30);
            if (o > bestSingle) { bestSingle = o; bestIdx = i; }
        }
        assertEq(bestIdx, 1, "setup: the best single leg at full size must be the middle pool");

        RoutePlan memory plan = solver.findBestRoutePlan(address(A), address(B), ORDER);
        emit log_named_uint("plan totalOut      ", plan.best.totalOut);
        emit log_named_uint("best single (X)    ", bestSingle);
        assertGe(plan.best.totalOut, bestSingle,
            "the plan delivers less than a single pool it saw and never measured at full size");
    }

    /// The same guarantee across the dimension the report named: three to five survivors,
    /// between one and a hundred times the order deep. Whatever the plan does - one pool or a
    /// split - it never delivers less than the best single survivor, measured at full size.
    /// Survivors: the believability band keeps a pool within 5% of the depth-weighted median
    /// marginal rate, so prices within 1.5% of 1 (plus at most 1% of probe impact) keep every
    /// pool inside it; a wider spread lets the band exclude the best pool by design, and the
    /// guarantee is then over the ones it keeps.
    function testFuzz_ThePlanNeverDeliversLessThanItsBestSinglePool(uint8 nSeed, uint64 seed) public {
        uint256 n = 3 + uint256(nSeed) % 3;
        uint256 bestSingle;
        for (uint256 i; i < n; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            uint256 depth = ORDER + r % (ORDER * 99);
            uint256 rB = depth * (985 + (r >> 128) % 31) / 1000;
            _pool(depth, rB);
            uint256 o = BPC.outV2(ORDER, depth, rB, 30);
            if (o > bestSingle) bestSingle = o;
        }
        RoutePlan memory plan = solver.findBestRoutePlan(address(A), address(B), ORDER);
        assertGe(plan.best.totalOut, bestSingle,
            "the plan delivers less than a single pool it saw, at full size");
    }
}
