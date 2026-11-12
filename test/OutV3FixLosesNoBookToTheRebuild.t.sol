// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

// Differential, the rebuild's question: does the single-range figure of `Core.outV3`
// (token0 in) make an honest flat book "fall" (`Solver._paysWhatItWalks`: the walk of its own
// book, `Core.v3PaysOnBudget` on V3_PAY_READS, pays under the promise -> the book is handed back
// on `fl` and the rebuild runs without it)?
//
// Two figures over the same orders: `outV3` as it stands (the pool's own step, `Core._nextSqrtFromInput`,
// price rounded up)
// and the figure before b83503f (price rounded down through a floored product), replicated here.
// The walk is the oracle: it is the pool's step arithmetic, a different producer from the
// single-range figure. Orders sweep the price (ticks -300k..300k, off-tick prices), the
// liquidity (1e6..1e30), the four common fees and the input from one wei to a quarter of the
// virtual reserve (log-uniform), so swaps end in the first step and past several bitmap words.
//
// Pins: the figure as it stands never takes a book out of the rebuild that the old figure kept
// (`lostByFix == 0`), and inside the pool's first step it never takes one out at all.

import {Test, console2} from "forge-std/Test.sol";
import {BlazePhoenixCore as BPC} from "../src/BlazePhoenixCore.sol";

/// A V3-shaped flat book (no initialized tick) whose slot0 tick agrees with its price.
contract FlatBook {
    uint160 internal sp;
    int24 internal tk;
    uint128 public liquidity;
    uint24 public fee;
    int24 public tickSpacing;

    function set(uint160 s, int24 t, uint128 l, uint24 f, int24 ts) external {
        (sp, tk, liquidity, fee, tickSpacing) = (s, t, l, f, ts);
    }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (sp, tk, 0, 0, 0, 0, true);
    }

    function tickBitmap(int16) external pure returns (uint256) { return 0; }

    function ticks(int24) external pure returns (uint128, int128, uint256, uint256, int56, uint160, uint32, bool) {
        return (0, 0, 0, 0, 0, 0, 0, false);
    }
}

contract OutV3FixLosesNoBookToTheRebuildTest is Test {
    FlatBook internal book;

    struct Tally {
        uint256 n;
        uint256 savedByFix;   // old figure fell, the figure as it stands does not
        uint256 lostByFix;    // old figure kept the book, the figure as it stands falls
        uint256 fellBoth;
        uint256 firstStepFallsNew; // falls with the figure as it stands, inside the first step
        uint256 newAboveOld;
        uint256 newBelowOld;
        uint256 walkUnfinished; // the walk ran out of reads: the band, no fall either way
    }

    function setUp() public {
        book = new FlatBook();
    }

    /// The figure before b83503f, token0 in (Core.outV3 at 33b5f94).
    function _oldOutV3(uint256 ain, uint160 sqrtP, uint128 liq, uint24 fee) internal pure returns (uint256) {
        if (ain == 0 || liq == 0 || sqrtP == 0) return 0;
        uint256 a = (ain * (1_000_000 - fee)) / 1_000_000;
        uint256 L = uint256(liq);
        uint256 P = uint256(sqrtP);
        uint256 product = BPC.mulDiv(a, P, BPC.Q96);
        uint256 sqrtNew = BPC.mulDiv(L, P, L + product);
        if (sqrtNew >= P || sqrtNew == 0) return 0;
        return BPC.mulDiv(L, P - sqrtNew, BPC.Q96);
    }

    function _rand(uint256 seed, uint256 i, uint256 k) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(seed, i, k)));
    }

    function _sweep(uint256 seed, uint256 count) internal returns (Tally memory t) {
        uint24[4] memory fees = [uint24(100), 500, 3000, 10000];
        int24[4] memory spacings = [int24(1), 10, 60, 200];
        for (uint256 i; i < count; ++i) {
            uint256 f = _rand(seed, i, 0) % 4;
            int24 ts = spacings[f];
            int24 tick = int24(int256(_rand(seed, i, 1) % 600_001) - 300_000);
            uint160 lo = BPC.sqrtPriceAtTick(tick);
            uint160 hi = BPC.sqrtPriceAtTick(tick + 1);
            uint160 sp = lo + uint160(_rand(seed, i, 2) % (hi - lo));
            uint128 liq = uint128(10 ** (6 + _rand(seed, i, 3) % 25) + _rand(seed, i, 4) % 1e6);
            uint256 x0 = BPC.mulDiv(liq, BPC.Q96, sp); // virtual token0 reserve
            if (x0 < 8) continue;
            uint256 k = 2 + _rand(seed, i, 5) % 60;
            uint256 ain = (x0 >> k) + _rand(seed, i, 6) % ((x0 >> k) + 1);
            if (ain == 0) ain = 1;
            book.set(sp, tick, liq, fees[f], ts);

            uint256 oldF = _oldOutV3(ain, sp, liq, fees[f]);
            uint256 newF = BPC.outV3(ain, sp, liq, fees[f], true, 0);
            (uint256 paidOld, ) = BPC.v3PaysOnBudget(address(book), ain, true, oldF, BPC.V3_PAY_READS);
            (uint256 paidNew, uint256 left) = BPC.v3PaysOnBudget(address(book), ain, true, newF, BPC.V3_PAY_READS);
            bool fellOld = paidOld < oldF;
            bool fellNew = paidNew < newF;
            // First step: the walk spent 5 reads before the first stretch and one word.
            bool firstStep = left == BPC.V3_PAY_READS - 6;
            ++t.n;
            if (fellOld && !fellNew) ++t.savedByFix;
            if (!fellOld && fellNew) ++t.lostByFix;
            if (fellOld && fellNew) ++t.fellBoth;
            if (fellNew && firstStep) ++t.firstStepFallsNew;
            if (newF > oldF) ++t.newAboveOld;
            if (newF < oldF) ++t.newBelowOld;
            if (left == 0 && paidNew == newF) ++t.walkUnfinished;
        }
    }

    function _check(Tally memory t) internal pure {
        console2.log("orders", t.n);
        console2.log("savedByFix", t.savedByFix);
        console2.log("lostByFix", t.lostByFix);
        console2.log("fellBoth", t.fellBoth);
        console2.log("firstStepFallsNew", t.firstStepFallsNew);
        console2.log("newAboveOld", t.newAboveOld);
        console2.log("newBelowOld", t.newBelowOld);
        console2.log("walkUnfinished", t.walkUnfinished);
        assertEq(t.lostByFix, 0, "the figure takes out of the rebuild a book the old figure kept");
        assertEq(t.firstStepFallsNew, 0, "inside the pool's first step an honest flat book fell");
    }

    function test_SweepA_NoBookLostToTheRebuild() public { _check(_sweep(1, 1500)); }
    function test_SweepB_NoBookLostToTheRebuild() public { _check(_sweep(2, 1500)); }
    function test_SweepC_NoBookLostToTheRebuild() public { _check(_sweep(3, 1500)); }
    function test_SweepD_NoBookLostToTheRebuild() public { _check(_sweep(4, 1500)); }
}
