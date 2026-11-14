// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  A LIQUIDITY THAT WOULD PASS 2^128 SATURATES; IT NEVER WRAPS (C10, PR #124).
//
//  `Core.v3PaysOnBudget` applies a crossed tick's liquidityNet as `_v4Walk` does: upward it
//  adds, and a sum past type(uint128).max is held at type(uint128).max. The book is the
//  venue's word; a word that would overflow the liquidity is read at its ceiling, never cast
//  down to what is left over after 2^128, and never a revert.
//
//  The oracle is a second book, never the Core's arithmetic: the same positions, the same
//  price, and the crossed tick's net set to exactly type(uint128).max - l, so its sum reaches
//  the ceiling without passing it. A saturating walk and that exact walk see the same
//  liquidity after the crossing, so they answer the same figure and spend the same reads.
//  A cast that wraps leaves the first book about half the liquidity and a different figure.
//
//  The rank-times-order saturation of the same family (Core `oOrder`) is pinned already by
//  RouteQualityOrderSizeError.t.sol (test_ErrSaturatesWhenRankTimesOrderOverflows) and its
//  mutant; it is not repeated here.
//
//  A guard, green at bb4cdbb: its red is the mutant labelled `124-L2 Core:2547` in
//  .github/scripts/mutants.py (the saturation replaced by a uint128 cast).
//
//  forge test --match-path test/SaturationIsAWordNotARevert.t.sol -vv
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixCore as BPC} from "../src/BlazePhoenixCore.sol";
import {MockV3TickPool} from "./mocks/MockV3TickPool.sol";

contract SaturationIsAWordNotARevert is Test {
    uint24 constant FEE = 3000;
    int24 constant TS = 60;
    uint256 constant MAX128 = type(uint128).max;

    /// Liquidity l = 2^128 - 2 in range at tick 0, from two positions whose upper ticks are 60
    /// and 120. Both crossings on the way up answer int128.max: the first passes 2^128 by
    /// 2^127 - 3, the second would pass it again. The exact book answers 1 at tick 60 (the sum
    /// lands on the ceiling) and 0 at tick 120. The order crosses both ticks.
    function test_LiquidityNetSaturatesAtUint128() public {
        uint128 a = type(uint128).max / 2;   // 2^127 - 1
        uint128 b = type(uint128).max / 2;
        uint256 l = uint256(a) + b;
        MockV3TickPool sat = _book(a, b);
        sat.lieAboutTheNet(60, type(int128).max);
        sat.lieAboutTheNet(120, type(int128).max);
        MockV3TickPool exact = _book(a, b);
        exact.lieAboutTheNet(60, int128(int256(MAX128 - l)));
        exact.lieAboutTheNet(120, 0);

        uint256 amt = 4e36;
        (uint256 qs, uint256 ls) = BPC.v3PaysOnBudget(address(sat), amt, false, type(uint256).max, BPC.V3_PAY_READS);
        (uint256 qe, uint256 le) = BPC.v3PaysOnBudget(address(exact), amt, false, type(uint256).max, BPC.V3_PAY_READS);
        assertGt(qs, 0, "the saturated book pays");
        assertEq(qs, qe, "saturation reads the ceiling, as the book that lands on it");
        assertEq(ls, le, "same reads spent");
        // The order goes past both crossings: what the range [0, 120) takes at l, by the mock's
        // own tick prices, is less than the input after the fee.
        uint256 reach = l * (uint256(sat.sqrtAt(120)) - sat.sqrtAt(0)) >> 96;
        assertLt(reach, amt * (1e6 - FEE) / 1e6, "the order crosses ticks 60 and 120");
    }

    /// Any l in (2^127, 2^128 - 2] and any net that passes the ceiling at tick 60: the walk
    /// answers what the book whose net lands exactly on the ceiling answers.
    function testFuzz_LiquidityNetSaturatesAtUint128(uint128 a, uint128 b, uint128 n) public {
        a = uint128(bound(a, (uint256(1) << 126) + 1, uint256(uint128(type(int128).max))));
        b = uint128(bound(b, uint256(1) << 126, uint256(uint128(type(int128).max))));
        uint256 l = uint256(a) + b;
        uint256 net = bound(n, MAX128 - l + 1, uint256(uint128(type(int128).max)));
        MockV3TickPool sat = _book(a, b);
        sat.lieAboutTheNet(60, int128(int256(net)));
        MockV3TickPool exact = _book(a, b);
        exact.lieAboutTheNet(60, int128(int256(MAX128 - l)));

        uint256 amt = 3e36;
        (uint256 qs, uint256 ls) = BPC.v3PaysOnBudget(address(sat), amt, false, type(uint256).max, BPC.V3_PAY_READS);
        (uint256 qe, uint256 le) = BPC.v3PaysOnBudget(address(exact), amt, false, type(uint256).max, BPC.V3_PAY_READS);
        assertGt(qs, 0, "the saturated book pays");
        assertEq(qs, qe, "saturation reads the ceiling");
        assertEq(ls, le, "same reads spent");
    }

    /// A pool on two placeholder tokens at tick 0 (the walk reads the book, never a balance),
    /// with positions [-60, 60) of `a` and [-120, 120) of `b`.
    function _book(uint128 a, uint128 b) internal returns (MockV3TickPool pool) {
        pool = new MockV3TickPool(address(0xA), address(0xB), FEE, TS);
        pool.initialize(0);
        pool.addPosition(-60, 60, a);
        pool.addPosition(-120, 120, b);
    }
}
