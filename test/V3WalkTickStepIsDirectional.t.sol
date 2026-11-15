// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  THE V3 WALK STEPS PAST A CROSSED TICK IN THE DIRECTION IT TRADES.
//
//  `Core.v3PaysOnBudget` walks a concentrated book range by range. After it crosses
//  an initialized tick `nt`, the next search starts at `nt - 1` going down
//  (zeroForOne) and at `nt` going up: the search going down is inclusive, so starting
//  at `nt` would find the tick just crossed, apply its liquidityNet a second time and
//  stall on the same price until the reads run out.
//
//  The oracle is MockV3TickPool.specSwap, a second implementation of the swap, never
//  the Core under test. The book: 1e21 on [-60, 60], 1e19 on [-120, -60] and on
//  [60, 120]; an order of up to 3.02e18 stays inside it in both directions, and one
//  past ~3.0135e18 (fee included) crosses -60 or 60.
//
//  Mutant "Core:2551" in .github/scripts/mutants.py (`tick = nt` going down too).
//
//  forge test --match-path test/V3WalkTickStepIsDirectional.t.sol -vv
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixCore as BPC} from "../src/BlazePhoenixCore.sol";
import {MockV3TickPool} from "./mocks/MockV3TickPool.sol";

contract V3WalkTickStepIsDirectionalTest is Test {
    uint24 constant FEE = 3000;

    /// The walk pays what the pool pays, in both directions, crossing a tick or not.
    function testFuzz_TheWalkPaysWhatTheSpecSwapPays(uint256 amt, bool zfo) public {
        amt = bound(amt, 1e15, 3.02e18);
        MockV3TickPool pool = _book();
        (uint256 q, uint256 pays, int24 tickEnd) = _walk(pool, amt, zfo);
        assertGt(pays, 0, "premise: the book pays");
        assertTrue(tickEnd >= -120 && tickEnd <= 120, "premise: the order stays inside the book");
        assertApproxEqRel(q, pays, 1e12, "the walk pays other than the pool");
    }

    /// An order going down past -60 is priced on the 1e19 below it, once: the tick it
    /// crossed is not read again.
    function test_ZeroForOneCrossesBelowTheTick() public {
        uint256 amt = 3.03e18;
        (uint256 q, uint256 pays, int24 tickEnd) = _walk(_book(), amt, true);
        assertTrue(tickEnd < -60 && tickEnd >= -120, "premise: the order crosses -60 and stops above -120");
        assertApproxEqRel(q, pays, 1e12, "the range below the crossed tick is priced once, on its own liquidity");

        // Control: with no liquidityNet at -60 the walk keeps 1e21 past it and pays more.
        MockV3TickPool liar = _book();
        liar.lieAboutTheNet(-60, 0);
        (uint256 q2, ) = BPC.v3PaysOnBudget(address(liar), amt, true, type(uint256).max, BPC.V3_PAY_READS);
        assertGt(q2, q, "control: the net at -60 is what thins the range below it");
    }

    function _book() internal returns (MockV3TickPool pool) {
        pool = new MockV3TickPool(address(0xA), address(0xB), FEE, 60);
        pool.initialize(0);
        pool.addPosition(-60, 60, 1e21);
        pool.addPosition(-120, -60, 1e19);
        pool.addPosition(60, 120, 1e19);
    }

    function _walk(MockV3TickPool pool, uint256 amt, bool zfo)
        internal view returns (uint256 q, uint256 pays, int24 tickEnd)
    {
        (q, ) = BPC.v3PaysOnBudget(address(pool), amt, zfo, type(uint256).max, BPC.V3_PAY_READS);
        uint256 used;
        (used, pays, , tickEnd, ) = pool.specSwap(
            amt, zfo, zfo ? BPC.MIN_SQRT_PRICE_PLUS_ONE : BPC.MAX_SQRT_PRICE_MINUS_ONE
        );
        assertEq(used, amt, "premise: the pool takes the whole order");
    }
}
