// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  THE V3 WALK HOLDS AT THE MOST LIQUIDITY A RANGE CAN CARRY, AND STOPS WHERE THE
//  BOOK ENDS.
//
//  `Core.v3PaysOnBudget` applies each crossed tick's liquidityNet saturating: a range
//  whose liquidity plus the net would pass uint128.max reads uint128.max, never the
//  low bits of the sum (an explicit uint128 cast does not revert, it truncates). And
//  at V4_MIN_TICK / V4_MAX_TICK the book has ended: what the walk reached is what the
//  pool pays, and an order past it is paid no more than the book holds.
//
//  Monotone against the caller: more liquidity past a crossed tick never pays less,
//  and a larger order past the end of the book is paid the same.
//
//  Matrix (gama x vetor x dimensao):
//    l + net = 2^128 - 2 + 2^127 - 1 (past uint128.max)  x  hostile liquidityNet  x  unit
//    order past the last tick (1e58 and 2e58)             x  one wide range to MAX  x  unit
//
//  Mutants in .github/scripts/mutants.py: "Core:2547" (the saturation dropped),
//  "Core:2550" (the stop at the price bound dropped).
//
//  forge test --match-path test/V3WalkEndsWhereTheBookEnds.t.sol -vv
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixCore as BPC} from "../src/BlazePhoenixCore.sol";
import {MockV3TickPool} from "./mocks/MockV3TickPool.sol";

contract V3WalkEndsWhereTheBookEndsTest is Test {
    uint24 constant FEE = 3000;
    uint128 constant H = uint128(uint256(int256(type(int128).max)));   // 2^127 - 1, one tick's most

    /// A book holding 2^128 - 2 on [-60, 600]; tick 60 answers a liquidityNet of `net60`.
    function _deep(int128 net60) internal returns (MockV3TickPool pool) {
        pool = new MockV3TickPool(address(0xA), address(0xB), FEE, 60);
        pool.initialize(0);
        pool.addPosition(-60, 600, H);
        pool.addPosition(-120, 660, H);
        pool.addPosition(60, 720, 1);      // initializes tick 60
        pool.lieAboutTheNet(60, net60);
        assertEq(pool.liquidity(), 2 * uint256(H), "premise: the range at 0 holds 2^128 - 2");
    }

    /// Crossing 60 upward adds 2^127 - 1 to 2^128 - 2: the walk reads uint128.max past it, so
    /// it pays at least what the same book pays with no net at 60.
    function test_ACrossingPastUint128MaxSaturates() public {
        // ~1.03e36 reaches 60 and ~1.04e37 reaches 600 [derived: L (1.0001^30 - 1) / 0.997 and
        // L (1.0001^300 - 1)]: 3e36 crosses 60 and stops below 600, on every reading of the net.
        uint256 amt = 3e36;
        (uint256 q, ) = BPC.v3PaysOnBudget(address(_deep(type(int128).max)), amt, false, type(uint256).max, BPC.V3_PAY_READS, true);
        (uint256 q0, ) = BPC.v3PaysOnBudget(address(_deep(0)), amt, false, type(uint256).max, BPC.V3_PAY_READS, true);
        assertGt(q0, 0, "premise: the book pays");
        assertGe(q, q0, "liquidity added past a crossed tick paid less: the sum wrapped");
    }

    /// One range of 2^127 - 1 from -884736 to the price bound (its upper tick nets nothing, a
    /// spacing of 16384 reaches 887272 in two steps): an order past what the range holds is
    /// paid what the walk reached at V4_MAX_TICK, and a larger one is paid the same.
    function test_AnOrderPastTheLastTickIsPaidWhatTheBookHolds() public {
        MockV3TickPool pool = new MockV3TickPool(address(0xA), address(0xB), FEE, 16384);
        pool.initialize(0);
        pool.addPosition(-884736, 884736, H);
        pool.lieAboutTheNet(884736, 0);
        // The range from tick 0 to 887272 takes ~3.1e57 of token1 [derived: H (1.0001^443636 - 1) / 0.997].
        (uint256 q1, ) = BPC.v3PaysOnBudget(address(pool), 1e58, false, type(uint256).max, BPC.V3_PAY_READS, true);
        (uint256 q2, ) = BPC.v3PaysOnBudget(address(pool), 2e58, false, type(uint256).max, BPC.V3_PAY_READS, true);
        assertGt(q1, 0, "premise: the book pays");
        assertLe(q1, H, "the walk paid more token0 than the range holds");
        assertEq(q2, q1, "an order past the end of the book was paid past the bound");
    }
}
