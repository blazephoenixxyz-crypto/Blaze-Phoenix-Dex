// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  THE PROMISE OF AN ALGEBRA INTEGRAL LEG IS WHAT ITS BOOK PAYS, TICKS CROSSED.
//
//  `Core.v3PaysOnBudget` is the one producer of a concentrated leg's promise and of
//  the Router's in-frame quote. Until this change it read the book through `slot0()`
//  and `tickBitmap(int16)`: an Algebra Integral pool answers neither, so the walk
//  handed back `f`, the single-range figure, and an order that crossed initialized
//  ticks into thinner liquidity was promised the depth of the range it started in
//  (measured on Base, test/fork/AlgebraListPromiseIsWhatThePoolPays.t.sol).
//
//  The pool keeps its initialized ticks as a linked list: `prevTickGlobal()` /
//  `nextTickGlobal()` around the price, then word 2 (prevTick) and word 3 (nextTick)
//  of `ticks(t)`, beside the liquidityDelta in word 1. The walk now follows it: one
//  read for the boundary, one read per tick crossed, no bitmap word.
//
//  The oracle is MockV3TickPool.specSwap, a second implementation of the swap, never
//  the Core under test. MockAlgebraListPool is the Algebra face of that same book:
//  1e21 on [-60, 60], 1e20 on [-120, -60] and [60, 120], 5e19 on [-180, -120] and
//  [120, 180]. An order past ~3.02e18 crosses one tick, past ~3.32e18 two, and the
//  book ends near 3.459e18.
//
//  Red at 6387350, all seven: the walk answered `f` after three reads. What that tree
//  cannot turn red is "a list that does not answer, or lies, is the band": the band
//  was its answer to every such pool. Those assertions are asked with `f` above
//  anything the book pays, so a walk cannot pass for the band, and they are red
//  against the fix without its guards (mutants "Core list walk: ..." in
//  .github/scripts/mutants.py, one per test).
//
//  forge test --match-path test/AlgebraListWalkPaysWhatTheBookPays.t.sol -vv
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixCore as BPC} from "../src/BlazePhoenixCore.sol";
import {MockV3TickPool} from "./mocks/MockV3TickPool.sol";
import {MockAlgebraListPool} from "./mocks/MockAlgebraListPool.sol";

contract AlgebraListWalkPaysWhatTheBookPaysTest is Test {
    uint24 constant FEE = 3000;
    uint256 constant NO_CAP = type(uint256).max;

    MockV3TickPool book;
    MockAlgebraListPool list;

    function setUp() public {
        book = new MockV3TickPool(address(0xA), address(0xB), FEE, 60);
        book.initialize(0);
        book.addPosition(-60, 60, 1e21);
        book.addPosition(-120, -60, 1e20);
        book.addPosition(60, 120, 1e20);
        book.addPosition(-180, -120, 5e19);
        book.addPosition(120, 180, 5e19);
        int24[] memory s = new int24[](6);
        (s[0], s[1], s[2], s[3], s[4], s[5]) = (-180, -120, -60, 60, 120, 180);
        list = new MockAlgebraListPool(book, s);
    }

    /// From dust to the end of the book, in both directions: the walk of the list pays what
    /// the pool's swap pays, to the wei.
    function testFuzz_TheListWalkPaysWhatTheSpecSwapPays(uint256 amt, bool zfo) public view {
        amt = bound(amt, 1, 3.45e18);
        (uint256 pays, ) = _spec(amt, zfo);
        (uint256 q, ) = BPC.v3PaysOnBudget(address(list), amt, zfo, NO_CAP, BPC.V3_PAY_READS);
        assertEq(q, pays, "the list walk pays other than the pool");
    }

    /// One and two ticks crossed, down and up: the promise is the pool's figure, under the
    /// single-range figure the leg was promised before.
    function test_AnOrderThatCrossesTicksIsPromisedWhatThePoolPays() public view {
        for (uint256 k; k < 4; ++k) {
            bool zfo = k < 2;
            uint256 amt = k % 2 == 0 ? 3.15e18 : 3.4e18;
            (uint256 pays, int24 tickEnd) = _spec(amt, zfo);
            int24 depth = (zfo ? -tickEnd - 1 : tickEnd) / 60;
            assertEq(depth, k % 2 == 0 ? int24(1) : int24(2), "premise: the order crosses one tick, then two");
            uint256 f = BPC.outV3(amt, BPC.sqrtPriceAtTick(0), 1e21, FEE, zfo, 0);
            assertGt(f, pays, "premise: the single-range figure is above what the pool pays");
            (uint256 q, ) = BPC.v3PaysOnBudget(address(list), amt, zfo, f, BPC.V3_PAY_READS);
            assertEq(q, pays, "the promise of a leg that crosses ticks is not the pool's figure");
        }
    }

    /// One book, two shapes: the V3 face (slot0, tickBitmap) and the Algebra face (globalState,
    /// the list) of the same book are promised the same figure.
    function test_OneBookTwoShapesOnePromise() public view {
        for (uint256 k; k < 4; ++k) {
            bool zfo = k < 2;
            uint256 amt = k % 2 == 0 ? 3.15e18 : 3.4e18;
            (uint256 qV3, ) = BPC.v3PaysOnBudget(address(book), amt, zfo, NO_CAP, BPC.V3_PAY_READS);
            (uint256 qList, ) = BPC.v3PaysOnBudget(address(list), amt, zfo, NO_CAP, BPC.V3_PAY_READS);
            assertEq(qList, qV3, "the two shapes of one book are promised different figures");
        }
    }

    /// The list costs one read per tick crossed: five reads before the first stretch (fee,
    /// spacing, slot0 unanswered, globalState, liquidity), one for the boundary, one per
    /// crossing. The bitmap shape spends two per crossing and one more for the last word.
    function test_TheListCostsOneReadPerTickCrossed() public view {
        (, uint256 left0) = BPC.v3PaysOnBudget(address(list), 1e18, false, NO_CAP, BPC.V3_PAY_READS);
        (, uint256 left1) = BPC.v3PaysOnBudget(address(list), 3.15e18, false, NO_CAP, BPC.V3_PAY_READS);
        (, uint256 left2) = BPC.v3PaysOnBudget(address(list), 3.4e18, false, NO_CAP, BPC.V3_PAY_READS);
        (, uint256 leftV3) = BPC.v3PaysOnBudget(address(book), 3.4e18, false, NO_CAP, BPC.V3_PAY_READS);
        assertEq(left0, BPC.V3_PAY_READS - 6, "no crossing: six reads");
        assertEq(left1, BPC.V3_PAY_READS - 7, "one crossing: one read more");
        assertEq(left2, BPC.V3_PAY_READS - 8, "two crossings: two reads more");
        assertEq(leftV3, BPC.V3_PAY_READS - 10, "control: the bitmap shape spends ten on the same order");
    }

    /// The reads spent before the order: the rest is priced on the last range read (G3), and
    /// the answer never passes `f`.
    function test_AListWalkCutByItsReadsNeverAnswersAboveTheSingleRange() public view {
        uint256 amt = 3.4e18;
        (uint256 pays, ) = _spec(amt, false);
        uint256 f = BPC.outV3(amt, BPC.sqrtPriceAtTick(0), 1e21, FEE, false, 0);
        (uint256 q, uint256 left) = BPC.v3PaysOnBudget(address(list), amt, false, f, 7);
        assertLt(q, f, "the tick the walk crossed is not counted");
        assertEq(left, 0, "premise: seven reads end at the first crossing");
        assertGe(q, pays, "control: the rest is priced on the 1e20 range, deeper than the 5e19 past it");
    }

    /// A pool that answers globalState() but keeps no list (Algebra 1.9 shaped) is not walked:
    /// the band, `f`. An unanswered boundary is not tick 0. `f` is asked above anything the
    /// book pays: under a small `f` a walk would be capped to it and pass for the band.
    function test_APoolWithNoListIsTheBand() public {
        list.tellThisLie(1);
        (uint256 q, uint256 left) = BPC.v3PaysOnBudget(address(list), 3.4e18, true, NO_CAP, BPC.V3_PAY_READS);
        assertEq(q, NO_CAP, "a pool with no list is promised other than the band");
        (q, ) = BPC.v3PaysOnBudget(address(list), 3.4e18, false, NO_CAP, BPC.V3_PAY_READS);
        assertEq(q, NO_CAP, "a pool with no list is promised other than the band, going up");
        assertEq(left, BPC.V3_PAY_READS - 6, "the reads it was asked are spent");
    }

    /// A hostile list is the band, never a revert: a boundary behind the price, and a tick
    /// that points past the tick bounds.
    function test_AListThatLiesIsTheBandNotARevert() public {
        for (uint8 l = 2; l < 4; ++l) {
            list.tellThisLie(l);
            (uint256 down, ) = BPC.v3PaysOnBudget(address(list), 3.4e18, true, NO_CAP, BPC.V3_PAY_READS);
            (uint256 up, ) = BPC.v3PaysOnBudget(address(list), 3.4e18, false, NO_CAP, BPC.V3_PAY_READS);
            assertEq(down, NO_CAP, "a lying list is promised other than the band, going down");
            assertEq(up, NO_CAP, "a lying list is promised other than the band, going up");
        }
        list.tellThisLie(0);
        (uint256 honest, ) = BPC.v3PaysOnBudget(address(list), 3.4e18, true, NO_CAP, BPC.V3_PAY_READS);
        (uint256 pays, ) = _spec(3.4e18, true);
        assertEq(honest, pays, "control: the same list, honest, is walked");
    }

    function _spec(uint256 amt, bool zfo) internal view returns (uint256 pays, int24 tickEnd) {
        uint256 used;
        (used, pays, , tickEnd, ) =
            book.specSwap(amt, zfo, zfo ? BPC.MIN_SQRT_PRICE_PLUS_ONE : BPC.MAX_SQRT_PRICE_MINUS_ONE);
        assertEq(used, amt, "premise: the pool takes the whole order");
    }
}
