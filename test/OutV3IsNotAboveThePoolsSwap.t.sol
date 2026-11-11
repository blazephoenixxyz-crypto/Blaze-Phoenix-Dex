// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

// The single-range figure of a concentrated pool (`Core.outV3`) against the pool's own swap.
// RED at 33b5f94 (gas52-main-1106), the commit before the fix.
//
// `outV3` states its own law: exact for what fits inside the range and never above. In the
// token0 -> token1 direction it rounded the new price DOWN (`mulDiv(L, P, L + product)`), where
// the pool's swap (SqrtPriceMath.getNextSqrtPriceFromAmount0RoundingUp, the walk's `Core._nextSqrtFromInput`)
// rounds it UP. One unit of
// sqrt price is worth L / 2^96 of output, so the figure stood one wei above what the pool pays
// with about that probability (exact integers: 2 of 400,000 orders at L = 1e24 and price 1).
//
// What it cost: `Solver._paysWhatItWalks` hands a book back for the rebuild whenever the walk of
// its own book (`Core.v3PaysOnBudget`, the pool's arithmetic) pays under the promise. A flat,
// honest book lost its place for one wei of rounding, and the price that triggers it for a given
// order can be set by anyone with a swap.
//
// The case below is one of those orders. The expected output is the pool's own arithmetic in
// exact integers, not this repository's code:
//   a      = floor(150905615719094812618 * (1e6 - 500) / 1e6)
//   sqrtQ  = ceil((L * 2^96) * P / (L * 2^96 + a * P))            with P = 2^96, L = 1e24
//   out    = floor(L * (P - sqrtQ) / 2^96) = 150807416604020658248
// (`outV3` with the price rounded down answered 150807416604020658249.)
//
// The domain is one step of the pool's swap (no initialized tick and no bitmap-word boundary in
// the way). A swap that crosses a word is two steps in the pool, each with its own rounding, and
// one in the single-range figure: that difference is not this file's.

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixCore as BPC} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV3BookPool} from "./mocks/MockV3BookPool.sol";

contract OutV3IsNotAboveThePoolsSwapTest is Test {
    uint256 constant AIN  = 150905615719094812618;
    uint128 constant L    = 1e24;
    uint24  constant FEE  = 500;
    uint256 constant POOL_PAYS = 150807416604020658248;

    /// The figure itself, against the literal.
    function test_SingleRangeFigureIsWhatThePoolPays() public {
        assertEq(BPC.outV3(AIN, uint160(BPC.Q96), L, FEE, true, 0), POOL_PAYS, "outV3 is above the pool's swap");
    }

    /// The consumer's question: a flat book, walked as the Router walks it, keeps its promise
    /// to the wei (a fall here takes the book out of the rebuild).
    function test_AFlatBookKeepsItsPromiseToTheWei() public {
        MockV3BookPool p = new MockV3BookPool(address(new MockERC20("A", "A")), address(new MockERC20("B", "B")), FEE, 10);
        p.setState(uint160(BPC.Q96), L);
        uint256 promised = BPC.outV3(AIN, uint160(BPC.Q96), L, FEE, true, 0);
        (uint256 paid, ) = BPC.v3PaysOnBudget(address(p), AIN, true, promised, BPC.V3_PAY_READS);
        assertEq(paid, POOL_PAYS, "the walk is not the pool's arithmetic");
        assertEq(paid, promised, "the promise fell by a rounding");
    }

    /// The ranges: token0 in, the figure IS the walk of a flat book, to the wei, from dust to an
    /// eighth of the virtual reserve, at every fee; token1 in, never above it. The domain is the
    /// pool's first step: at spacing 10 a bitmap word ends 2,560 ticks under the price (sqrt
    /// price 0.8799, an input of 0.1365 L) and 2,550 above it (0.1359 L). Past a word the pool
    /// takes another step, with its own rounding, and the single-range figure does not.
    function testFuzz_TheFigureIsTheWalkOfAFlatBook(uint256 ain, uint128 liq, uint24 fee, bool zeroForOne) public {
        liq = uint128(bound(liq, 1e12, 1e30));
        fee = uint24(bound(fee, 0, 100_000));
        ain = bound(ain, 1, uint256(liq) / (zeroForOne ? 8 : 10));
        MockV3BookPool p = new MockV3BookPool(address(new MockERC20("A", "A")), address(new MockERC20("B", "B")), fee, 10);
        p.setState(uint160(BPC.Q96), liq);
        uint256 figure = BPC.outV3(ain, uint160(BPC.Q96), liq, fee, zeroForOne, 0);
        uint256 walked = BPC.v4WalkOut(address(p), bytes32(0), ain, 0, 0, zeroForOne);
        if (zeroForOne) assertEq(figure, walked, "token0 in: the figure is not the pool's swap");
        else assertLe(figure, walked, "token1 in: the figure is above the pool's swap");
    }

    /// One wei either side of the order that fell.
    function test_TheNeighboursOfTheOrderThatFell() public {
        MockV3BookPool p = new MockV3BookPool(address(new MockERC20("A", "A")), address(new MockERC20("B", "B")), FEE, 10);
        p.setState(uint160(BPC.Q96), L);
        for (uint256 a = AIN - 2; a <= AIN + 2; ++a) {
            assertEq(BPC.outV3(a, uint160(BPC.Q96), L, FEE, true, 0), BPC.v4WalkOut(address(p), bytes32(0), a, 0, 0, true), "a neighbour is off the walk");
        }
    }
}
