// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  BELOW ONE WHOLE POINT THE BRIDGE TERM IS ZERO ON BOTH SIDES OF THE SEAT DOOR.
//
//  `BridgeTermOneMagnitude.t.sol` pins the magnitude of the term (2_500) on its
//  two producers, `BPC.psi` (incumbents) and `Hub._canInsert` (the newcomer).
//  Every newcomer there projects from a weight divisible by 4 (32768, 256, 32;
//  8 in the dex-12 guard), where weight x 2_500 / 10_000 is a whole number. So
//  those worlds read the magnitude and never the rounding.
//
//  The two producers can disagree on rounding only where a quarter is not a
//  whole point: a newcomer at bucket 0 (weight 1, a quarter is 0.25) or at
//  bucket 1 (weight 2, a quarter is 0.5). Both sides floor it to 0 today. This
//  is the dust regime of the door: a newcomer that only EQUALS the weakest
//  incumbent takes no seat. A Hub term rounded up would hand that newcomer one
//  point its rivals were never given, and it would evict its equal.
//
//  Oracle: the scores are written by hand (1, 2, 5; the table 1, 2, 3, 5, 6, 7, 8
//  is f + floor(f / 4) for f = 1..7). The verdict is the door's own (a seat or
//  none); each refusal has a control seated by the same door in the same world.
//
//  Matrix: the side, the world, and the mutant it kills.
//    Hub   16 rows at bucket 0, one swap: score 1, bar 1. Newcomer at bucket 0
//          projects 1, not above 1: refused. Control: bucket 1 projects 2: seated.
//          Kills the Hub term rounded up (1 + 1 = 2 > 1).
//    Hub   16 rows at bucket 1, one swap: score 2, bar 2. Newcomer at bucket 1
//          projects 2: refused. Control: bucket 2 projects 4 + 1 = 5: seated.
//          Kills the Hub term rounded up and rounded half up (2 + 1 = 3 > 2).
//    Core  bucket 0, 1..7 swaps, bridged: 1, 2, 3, 5, 6, 7, 8.
//          Kills the Core term rounded up (f = 1 reads 2) and half up (f = 2 reads 3).
//    Both  the seated control scores, through the Core, what the Hub projected.
//
//  Green at cb1d7d9 and on this branch (no fix: the two producers agree). Red at 912bfa4
//  (OutOfGas: fix-1102, d7152b9, counts only anchored ticks that close an interval; the
//  warm-up looped forever on unanchored ticks); the ticks are anchored and spaced since.
//  Red under (mutants.py, each run alone, 2026-11-10): MT6-11 the Hub term
//  rounded up (the bucket-0 and the bucket-1 refusals), MT6-12 the Hub term
//  rounded half up (the bucket-1 refusal), MT6-13 the Core term rounded up (all
//  five). MT6-11 and MT6-12 leave BridgeTermOneMagnitude.t.sol green, 6 of 6.
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixCore as BPC} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";
import {Origin} from "./mocks/MockOriginFactory.sol";

contract BridgeTermBelowOnePointTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    MockERC20 A;
    MockERC20 B;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        solver = new BlazePhoenixSolver(address(hub), address(0));
        // This contract stands in for the Router on `recordSwap`.
        hub.setRoles(address(this), address(solver), address(this));
        A = new MockERC20("A", "A");
        B = new MockERC20("B", "B");
        hub.addBridge(address(B)); // (A, B) is bridged
    }

    function _v2(uint256 r) internal returns (MockV2Pair p) {
        p = new MockV2Pair(address(A), address(B));
        A.mint(address(p), r);
        B.mint(address(p), r);
        p.setReserves(uint112(r), uint112(r));
    }

    function _key(address pool) internal view returns (bytes32) {
        return hub.keyOf(pool, address(A), address(B));
    }

    function _psi(address pool) internal view returns (uint256) {
        return hub.getPsi(pool, address(A), address(B));
    }

    /// One anchored swap, one tau after the last: since fix-1102 (d7152b9) the clock moves only
    /// on an anchored tick (`TICK_ANCHORED`, what the Router passes on a material leg) that
    /// closes a real interval, and measures tau on it. One trade per tau (6144 s, the step the
    /// clock assumes before it has measured one) confirms tau, so h stays 24576 and the score,
    /// a rate (c x 24576 / h, f0e19a49), reads the count itself for c <= 7, where floor(c / 8)
    /// decays nothing. At a one-second cadence tau falls 1/8 per tick and 3 trades read 4. The
    /// clock is read through the cheatcode, never `block.timestamp`: this via_ir build hoists
    /// one TIMESTAMP out of the loop, so `vm.warp(block.timestamp + 1)` warped to the same
    /// second every tick (trace at 912bfa4: 13 x `VM::warp(2)`) and the warm-up never reached n.
    uint256 constant TAU = BPC.VITALITY_DECAY_STEP_SECONDS / BPC.VITALITY_STEPS_PER_TAU;

    function _tick(address pool, uint256 depthWad) internal {
        vm.warp(vm.getBlockTimestamp() + TAU);
        hub.recordSwap(
            pool, BPC.KIND_V2, 30, address(0), address(A), address(B), 1, 1, depthWad | BPC.TICK_ANCHORED
        );
    }

    /// Swaps recorded until the row's count reaches `n`, each at the given measured depth.
    function _warm(address pool, uint256 depthWad, uint32 n) internal {
        while (BPC.decodeSwapCount(hub.getSlot(_key(pool))) < n) _tick(pool, depthWad);
    }

    /// Fills the bridged pair with MAX_SLOTS (16) incumbents of one swap at `depthWad`, and
    /// checks that each scores `w` through the Core before the Hub is asked anything.
    function _fill(uint256 depthWad, uint256 w) internal {
        for (uint256 i; i < 16; ++i) {
            MockV2Pair inc = _v2(depthWad);
            hub.seedPool(address(inc), BPC.KIND_V2, 30, address(0), address(A), address(B));
            _warm(address(inc), depthWad, 1);
            assertEq(_psi(address(inc)), w, "isolation: incumbent score");
        }
    }

    /// A derived newcomer at `depthWad`, offered to the full pair by one swap.
    function _offer(uint256 depthWad) internal returns (address) {
        MockV2Pair p = _v2(depthWad);
        Origin.wire(hub, address(p), address(A), address(B), BPC.KIND_V2, 30);
        // Anchored: a row never stamped is counted without closing an interval (fix-1102).
        hub.recordSwap(
            address(p), BPC.KIND_V2, 30, address(0), address(A), address(B), 1, 1, depthWad | BPC.TICK_ANCHORED
        );
        return address(p);
    }

    /// Hub. Incumbents at bucket 0, one swap, bridged: 1 + 0 = 1, bar = 1 + 0 = 1. Newcomer at
    /// bucket 0: 1 + 0 = 1, not above 1. A Hub term rounded up projects 2 and seats it.
    function test_BridgeTerm_BelowOnePoint_NewcomerAtBucketZeroEqualsTheBarAndIsRefused() public {
        _fill(5e15, 1);
        address p = _offer(5e15);
        assertEq(hub.getPool(_key(p)), address(0), "a bucket-0 newcomer equal to the weakest row was seated");
    }

    /// The control of both bucket-0 and score-1 worlds: the same 16 rows, newcomer at bucket 1
    /// (weight 2): 2 + 0 = 2 > 1. Seated, and the row scores what the door projected.
    function test_BridgeTerm_BelowOnePoint_Control_BucketOneOverScoreOneIsSeated() public {
        _fill(5e15, 1);
        address p = _offer(5e16);
        assertEq(hub.getPool(_key(p)), p, "control: a newcomer one point over the bar was refused");
        assertEq(_psi(p), 2, "parity: the seated row does not score what the door projected");
    }

    /// Hub. Incumbents at bucket 1, one swap, bridged: 2 + 0 = 2, bar = 2 + 0 = 2. Newcomer at
    /// bucket 1: 2 + 0 = 2, not above 2. A Hub term rounded up, or half up, projects 3 and seats it.
    function test_BridgeTerm_BelowOnePoint_NewcomerAtBucketOneEqualsTheBarAndIsRefused() public {
        _fill(5e16, 2);
        address p = _offer(5e16);
        assertEq(hub.getPool(_key(p)), address(0), "a bucket-1 newcomer equal to the weakest row was seated");
    }

    /// The control of the score-2 world: newcomer at bucket 2 (weight 4): 4 + 1 = 5 > 2. Seated,
    /// and the row scores what the door projected.
    function test_BridgeTerm_BelowOnePoint_Control_BucketTwoOverScoreTwoIsSeated() public {
        _fill(5e16, 2);
        address p = _offer(5e17);
        assertEq(hub.getPool(_key(p)), p, "control: a newcomer three points over the bar was refused");
        assertEq(_psi(p), 5, "parity: the seated row does not score what the door projected");
    }

    /// Core. Bucket 0 (weight 1), 1..7 swaps, bridged: f + floor(f / 4) = 1, 2, 3, 5, 6, 7, 8.
    /// The term is 0 until f reaches 4 whole points.
    function test_BridgeTerm_BelowOnePoint_IncumbentTermIsZeroUnderFourPoints() public {
        uint8[7] memory want = [1, 2, 3, 5, 6, 7, 8];
        MockV2Pair pb = _v2(5e15);
        hub.seedPool(address(pb), BPC.KIND_V2, 30, address(0), address(A), address(B));
        for (uint32 n = 1; n <= 7; ++n) {
            _warm(address(pb), 5e15, n);
            assertEq(BPC.decodeSwapCount(hub.getSlot(_key(address(pb)))), n, "isolation: the count");
            assertEq(_psi(address(pb)), want[n - 1], "bridge term below four points");
        }
    }
}
