// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  A V3 WALK THE READS CUT PRICES THE REST ON THE LAST RANGE IT READ (G3, PR #123 review).
//
//  `Core.v3PaysOnBudget` walks a concentrated book on V3_PAY_READS reads. Until G3 a walk the
//  reads cut answered `f`, the single-range figure from the price and liquidity before the
//  first tick, even after it had crossed ticks where the book thins: the promise, and the
//  Router's in-frame quote its floor is made of, asked for more than the pool pays, and the
//  route was refused at its floor (RouterE(5); 4229, 8-10 ETH WETH->USDS on a Base fork).
//  Now a cut walk answers min(walked + outV3(rest, price reached, last liquidity read), f):
//  every crossed tick counts, no read is added, and it never answers above `f`.
//
//  The oracle is MockV3TickPool.specSwap, a second implementation of the swap (its own tick
//  prices, one compressed tick at a time), never the Core under test. Each book below is
//  built so the cut is where its comment says, counted from the reads: five before the first
//  stretch, then one bitmap word per stretch and one tick per crossing, twelve in all.
//
//  Red at cd32feb by derivation, not yet run (the cut answered `f`, so q == f): the sparse and
//  the dense tests. The
//  thickening test is a guard, green at cd32feb too: its red is mutant [g3-3], the cap
//  removed. Mutants [g3-1]-[g3-4] in .github/scripts/mutants.py.
//
//  forge test --match-path test/V3WalkCutPricesTheRest.t.sol -vv
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixCore as BPC} from "../src/BlazePhoenixCore.sol";
import {MockV3TickPool} from "./mocks/MockV3TickPool.sol";

contract V3WalkCutPricesTheRest is Test {
    uint24 constant FEE = 3000;

    /// Spacing 1, the price at tick 0. A thick range [-10, 10) and a thin one over the whole
    /// line: the order spends the thick range and goes on far into the thin book. Reads: five,
    /// then the word at 0 (a stretch of no length), the word [-256, -1] (to -10), the crossing
    /// at -10, and the words to -256, -512, -768, -1024: twelve, and the cut at the next word.
    function test_ASparseBookCutAtTheReadsIsPromisedWhatItPays() public {
        MockV3TickPool pool = _pool(1);
        pool.addPosition(-887272, 887272, 1e18);
        pool.addPosition(-10, 10, 1e21);
        uint256 amt = 7e17;
        (uint256 q, uint256 left, uint256 f, uint256 pays) = _walk(pool, amt, -1024);
        assertEq(left, 0, "premise: the walk spends every read");
        assertLt(pays, f, "premise: the book thins past the ticks the walk crossed");
        assertLt(q, f, "a cut walk answers the band");
        // walked and spec agree but for rounding (wei); the band is ~5% above what the pool pays
        assertApproxEqRel(q, pays, 1e12, "a cut walk promises other than what the pool pays");
    }

    /// Spacing 60, the price at tick 0. A thick range [-60, 60) and a range on every spacing
    /// below it, [-3600, 0): every stretch ends on an initialized tick. Reads: five, then the
    /// word at 0 and its crossing (no length), the stretch to -60 and its crossing (the thick
    /// range ends there), to -120 and its crossing, to -180 with no read left for its
    /// crossing: twelve, and the cut at -180.
    function test_ADenseBookCutAtACrossingIsPromisedWhatItPays() public {
        MockV3TickPool pool = _pool(60);
        pool.addPosition(-60, 60, 1e21);
        for (int24 k = -60; k < 0; ++k) pool.addPosition(k * 60, (k + 1) * 60, 1e19);
        uint256 amt = 3.5e18;
        (uint256 q, uint256 left, uint256 f, uint256 pays) = _walk(pool, amt, -240);
        assertEq(left, 0, "premise: the walk spends every read");
        assertLt(pays, f, "premise: the book thins past the ticks the walk crossed");
        assertLt(q, f, "a walk cut at a crossing answers the band");
        assertApproxEqRel(q, pays, 1e12, "a walk cut at a crossing promises other than what the pool pays");
    }

    /// Spacing 1, the price at tick 0. A thin range over the whole line and a thick one from
    /// -300 down: the walk crosses into the thick range at -300 and the reads cut it at -1024,
    /// where the rest on the thick range would pay far more than the band, priced on the thin
    /// head. A promise only falls: the cut walk answers the band.
    function test_ABookThatThickensPastTheCutIsPromisedNoMoreThanTheBand() public {
        MockV3TickPool pool = _pool(1);
        pool.addPosition(-887272, 887272, 1e17);
        pool.addPosition(-200000, -300, 1e19);
        uint256 amt = 1e18;
        (uint256 q, uint256 left, uint256 f, uint256 pays) = _walk(pool, amt, -1024);
        assertEq(left, 0, "premise: the walk spends every read");
        assertGt(pays, f, "premise: the book thickens past the head");
        assertEq(q, f, "a cut walk promises above the band");
    }

    /// A pool on two placeholder tokens at tick 0 (the walk reads the book, never a balance).
    function _pool(int24 ts) internal returns (MockV3TickPool pool) {
        pool = new MockV3TickPool(address(0xA), address(0xB), FEE, ts);
        pool.initialize(0);
    }

    /// The walk on the whole read budget against `f`, the single-range figure from the pool's
    /// own price and liquidity, and what the pool pays; the order is spent whole and ends below
    /// `cutBelow`, past where the reads cut the walk.
    function _walk(MockV3TickPool pool, uint256 amt, int24 cutBelow)
        internal view returns (uint256 q, uint256 left, uint256 f, uint256 pays)
    {
        (uint160 sp0, , , , , , ) = pool.slot0();
        f = BPC.outV3(amt, sp0, pool.liquidity(), FEE, true, 0);
        (q, left) = BPC.v3PaysOnBudget(address(pool), amt, true, f, BPC.V3_PAY_READS);
        uint256 used;
        int24 tickEnd;
        (used, pays, , tickEnd, ) = pool.specSwap(amt, true, BPC.MIN_SQRT_PRICE_PLUS_ONE);
        assertEq(used, amt, "premise: the pool takes the whole order");
        assertLt(tickEnd, cutBelow, "premise: the order goes past where the reads cut the walk");
    }
}
