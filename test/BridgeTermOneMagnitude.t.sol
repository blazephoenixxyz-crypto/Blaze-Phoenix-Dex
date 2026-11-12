// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  THE BRIDGE TERM HAS ONE MAGNITUDE ON BOTH SIDES OF THE SEAT DOOR.
//
//  The term has two producers. `BPC.psi` adds it to the score of every
//  incumbent of a bridged pair. `Hub._canInsert` adds it to the score it
//  projects for a newcomer, before the quarter margin. They stay separate:
//  the Core scores a slot that exists, and the Hub projects a depth that has
//  no slot yet. This file pins them by parity instead of fusing them
//  (SHARED_QUANTITIES.md, row `2_500`).
//
//  dex-12 made the newcomer carry the term at all. Its guard removes the
//  term entirely, and a term of another magnitude still clears that
//  fixture's bar (8 + 8 x 20 % = 9 > 7 + 7/4). The worlds here put the bar at
//  the newcomer's projected score or one step under it, so the door turns
//  on the magnitude itself.
//
//  Oracle: the scores are written by hand. The term is +25 %. 2_500 / 10_000
//  is exactly 1/4, so the term is floor(f / 4) = f >> 2. That is a different
//  expression from the one under test, with the same value.
//
//  Matrix: the side that produces the term, the world, and the mutant it
//  kills. Each mutant is registered in .github/scripts/mutants.py and run
//  alone.
//    Core  bucket 15, 4 swaps: 131072 bare, 163840 bridged
//          kills any K != 2_500 in [0, 10_000]                       [MT6-3]
//    Core  any bucket, 1..6 swaps (fuzz): bridged = bare + bare >> 2
//    Hub   16 rows, count 26214 (vm.store): W = 26214 + 6553 = 32767,
//          so bar = 40958. Newcomer at bucket 15: 32768 + 8192 = 40960
//          > 40958, seated. K seats iff floor(3.2768 K) >= 8191, iff
//          K >= 2_500, so this kills every K <= 2_499.              [MT6-1]
//    Hub   16 rows, count 26215: W = 26215 + 6553 = 32768, so
//          bar = 40960. The newcomer's 40960 is not above it, refused.
//          K seats iff floor(3.2768 K) >= 8193, iff K >= 2_501, so this
//          kills every K >= 2_501.                                   [MT6-2]
//    Hub   16 rows, count 13 at bucket 1 and 51 at bucket 2 (vm.store):
//          kills K >= 2_813 and K <= 2_460
//  The two Hub rows with counts written by vm.store isolate the Hub. Their
//  precondition reads the incumbents' score through the Core, so a Core
//  mutant is caught there as an isolation failure, never credited to the Hub.
//
//  Green at cb1d7d9. Red at 912bfa4 (OutOfGas: fix-1102, d7152b9, counts only anchored
//  ticks that close an interval, and measures tau on each; the warm-up looped forever on
//  unanchored ticks, and a measured tau reads the count as a rate). Since: the ticks are
//  anchored, one tau apart, and the 13 and 51 rows are stored counts like 26214 and 26215.
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixCore as BPC} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";
import {Origin} from "./mocks/MockOriginFactory.sol";

contract BridgeTermOneMagnitudeTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    MockERC20 A;
    MockERC20 B;
    MockERC20 C;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        solver = new BlazePhoenixSolver(address(hub), address(0));
        // This contract stands in for the Router on `recordSwap`.
        hub.setRoles(address(this), address(solver), address(this));
        A = new MockERC20("A", "A");
        B = new MockERC20("B", "B");
        C = new MockERC20("C", "C");
        hub.addBridge(address(B)); // (A, B) is bridged; (A, C) is not
    }

    function _v2(MockERC20 x, MockERC20 y, uint256 r) internal returns (MockV2Pair p) {
        p = new MockV2Pair(address(x), address(y));
        x.mint(address(p), r);
        y.mint(address(p), r);
        p.setReserves(uint112(r), uint112(r));
    }

    function _key(address pool, MockERC20 y) internal view returns (bytes32) {
        return hub.keyOf(pool, address(A), address(y));
    }

    /// One anchored swap at the current second: since fix-1102 (d7152b9) the clock moves only
    /// on an anchored tick (`TICK_ANCHORED`, what the Router passes on a material leg) that
    /// closes a real interval, so a tick in the stamped second counts nothing.
    function _tick(address pool, MockERC20 y, uint256 depthWad) internal {
        hub.recordSwap(
            pool, BPC.KIND_V2, 30, address(0), address(A), address(y), 1, 1, depthWad | BPC.TICK_ANCHORED
        );
    }

    /// One trade per tau (6144 s, the step the clock assumes before it has measured one): each
    /// anchored interval confirms tau, h stays 24576 and the score reads the count itself
    /// (vitality is a rate, c x 24576 / h; f0e19a49) for c <= 7, where floor(c / 8) decays
    /// nothing. At a one-second cadence tau falls 1/8 per tick and 4 trades read 6. The clock is
    /// read through the cheatcode, never `block.timestamp`: this via_ir build hoists one
    /// TIMESTAMP out of the loop, so `vm.warp(block.timestamp + 1)` warped to the same second
    /// every round (trace at 912bfa4: 13 x `VM::warp(2)`) and only the first tick counted.
    uint256 constant TAU = BPC.VITALITY_DECAY_STEP_SECONDS / BPC.VITALITY_STEPS_PER_TAU;

    /// The bridged row and the bare row warmed to `n` in rounds, so both are read at age 0: a
    /// row warmed after the other would be read a full step later and halved.
    function _warmPair(address pb, address pc, uint256 depthWad, uint32 n) internal {
        for (uint32 k; k < n; ++k) {
            vm.warp(vm.getBlockTimestamp() + TAU);
            _tick(pb, B, depthWad);
            _tick(pc, C, depthWad);
        }
        assertEq(BPC.decodeSwapCount(hub.getSlot(_key(pb, B))), n, "isolation: the bridged count");
        assertEq(BPC.decodeSwapCount(hub.getSlot(_key(pc, C))), n, "isolation: the bare count");
    }

    /// A derived newcomer at `depthWad`, offered to the full pair by one swap.
    function _offer(uint256 depthWad) internal returns (address) {
        MockV2Pair p = _v2(A, B, depthWad);
        Origin.wire(hub, address(p), address(A), address(B), BPC.KIND_V2, 30);
        _tick(address(p), B, depthWad); // a row never stamped is counted without an interval
        return address(p);
    }

    /// Rewrites the swap count of a row (bits [191:160]) and nothing else. The storage word is
    /// the one `getSlot` reads, so no layout is assumed. A count of n is what n swaps recorded
    /// within one decay step leave; the store only skips the n calls.
    function _setCount(bytes32 key, uint256 n) internal {
        vm.record();
        uint256 s = hub.getSlot(key);
        (bytes32[] memory reads, ) = vm.accesses(address(hub));
        assertEq(reads.length, 1, "isolation: getSlot reads one word");
        assertEq(uint256(vm.load(address(hub), reads[0])), s, "isolation: the word read is the row");
        vm.store(address(hub), reads[0], bytes32((s & ~(uint256(0xFFFFFFFF) << 160)) | (n << 160)));
        assertEq(BPC.decodeSwapCount(hub.getSlot(key)), n, "isolation: the count was written");
    }

    /// Fills the bridged pair with 16 rows at `depthWad` (bucket `b`) whose count is `n`, and
    /// checks that each scores `w` through the Core before the Hub is asked anything. The
    /// stored count is the row's rate with tau unmeasured (0): since fix-1102 (d7152b9) every
    /// anchored interval measures tau and a row trading at any steady cadence settles between
    /// 8 and 15, so a count of 13 or 51 is a fixture of the rate, as 26214 and 26215 are.
    function _fillAtCount(uint256 depthWad, uint8 b, uint256 n, uint256 w) internal {
        for (uint256 i; i < 16; ++i) {
            MockV2Pair inc = _v2(A, B, depthWad);
            hub.seedPool(address(inc), BPC.KIND_V2, 30, address(0), address(A), address(B));
            bytes32 k = _key(address(inc), B);
            assertEq(BPC.decodeBucket(hub.getSlot(k)), b, "isolation: incumbent bucket");
            _setCount(k, n);
            assertEq(hub.getPsi(address(inc), address(A), address(B)), w, "isolation: incumbent score");
        }
    }

    /// Hub alone. Incumbents: count 26214, bucket 0, bridged: 26214 + 6553 = 32767, so the
    /// bar is 32767 + 8191 = 40958. Newcomer at bucket 15 (weight 32768): 32768 + 8192 = 40960
    /// > 40958. A Hub term of 2_499 or less projects 40956 or less and refuses it.
    function test_BridgeTerm_HubSeatsTheNewcomerTwoOverTheBar() public {
        _fillAtCount(5e15, 0, 26214, 32767);
        address p = _offer(5e30);
        assertEq(hub.getPool(_key(p, B)), p, "a newcomer two points over the bar was refused");
    }

    /// Hub alone. Incumbents: count 26215, bucket 0, bridged: 26215 + 6553 = 32768, so the
    /// bar is 32768 + 8192 = 40960. Newcomer at bucket 15: 40960, not above 40960. A Hub term
    /// of 2_501 or more projects 40963 or more and seats it.
    function test_BridgeTerm_HubRefusesTheNewcomerExactlyAtTheBar() public {
        _fillAtCount(5e15, 0, 26215, 32768);
        address p = _offer(5e30);
        assertEq(hub.getPool(_key(p, B)), address(0), "a newcomer exactly at the bar was seated");
    }

    /// Incumbents at bucket 1 (weight 2), 13 swaps: f = 26, psi = 26 + 6 = 32, bar = 32 + 8 = 40.
    /// Newcomer at bucket 5 (weight 32): 32 + 8 = 40, not above 40. A Hub term of 2_813 or more
    /// gives it 41 and seats it.
    function test_BridgeTerm_NewcomerExactlyAtTheBarIsRefused() public {
        _fillAtCount(5e16, 1, 13, 32);
        address p = _offer(5e20);
        assertEq(hub.getPool(_key(p, B)), address(0), "a newcomer exactly at the bar was seated");
    }

    /// Incumbents at bucket 2 (weight 4), 51 swaps: f = 204, psi = 204 + 51 = 255,
    /// bar = 255 + 63 = 318. Newcomer at bucket 8 (weight 256): 256 + 64 = 320 > 318.
    /// A Hub term of 2_460 or less gives it 318 or less and refuses it.
    function test_BridgeTerm_NewcomerOneStepOverTheBarIsSeated() public {
        _fillAtCount(5e17, 2, 51, 255);
        address p = _offer(5e23);
        assertEq(hub.getPool(_key(p, B)), p, "a newcomer two points over the bar was refused");
    }

    /// Bucket 15 (weight 32768), 4 swaps: f = 131072. Bridged: 131072 + 32768 = 163840;
    /// bare: 131072. floor(131072 x / 10_000) = 32768 only for x = 2_500 in [0, 10_000].
    function test_BridgeTerm_IncumbentScoreIsFiveQuarters() public {
        MockV2Pair pb = _v2(A, B, 5e30);
        hub.seedPool(address(pb), BPC.KIND_V2, 30, address(0), address(A), address(B));
        MockV2Pair pc = _v2(A, C, 5e30);
        hub.seedPool(address(pc), BPC.KIND_V2, 30, address(0), address(A), address(C));
        _warmPair(address(pb), address(pc), 5e30, 4);
        assertEq(hub.getPsi(address(pc), address(A), address(C)), 131072, "isolation: bare score");
        assertEq(hub.getPsi(address(pb), address(A), address(B)), 163840, "bridge term is not +25 %");
    }

    /// Any bucket and swap count: bridged score = bare score + (bare score >> 2).
    /// forge-config: default.fuzz.runs = 64
    /// forge-config: release.fuzz.runs = 64
    function testFuzz_BridgeTerm_IsAQuarterOfTheBareScore(uint256 bucket, uint256 swaps) public {
        bucket = bound(bucket, 0, 15);
        swaps = bound(swaps, 1, 6);
        uint256 depth = 5 * 10 ** (15 + bucket); // depthBucket = bucket
        MockV2Pair pb = _v2(A, B, depth);
        hub.seedPool(address(pb), BPC.KIND_V2, 30, address(0), address(A), address(B));
        MockV2Pair pc = _v2(A, C, depth);
        hub.seedPool(address(pc), BPC.KIND_V2, 30, address(0), address(A), address(C));
        _warmPair(address(pb), address(pc), depth, uint32(swaps));
        uint256 bare = hub.getPsi(address(pc), address(A), address(C));
        assertGt(bare, 0, "isolation: a live row scores");
        assertEq(hub.getPsi(address(pb), address(A), address(B)), bare + (bare >> 2), "bridge term");
    }
}
