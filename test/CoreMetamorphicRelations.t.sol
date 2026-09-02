// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  Metamorphic relations over the Core's AMM math (review 2026-09-02).
//
//  A metamorphic relation is a second judge: instead of "outV2(x) == literal",
//  it asks how the output must MOVE when the input moves, which no oracle
//  computed from the same formula can fake. Four relations, each a property
//  the curves are supposed to have and the router relies on:
//    MR1  monotone in amountIn        (a <= b  =>  out(a) <= out(b))
//    MR2  concave: splitting an order across the SAME pool never gains
//         (out(a + b) <= out(a) + out(b))
//    MR3  no round-trip profit inside one transaction
//         (swap a -> out, then out -> back on the updated reserves: back <= a)
//    MR4  scale equivariance (k*out(a, r) - out(k*a, k*r) is at most k wei)
//  Domains are bounded to uint112 reserves and amounts below the reserves,
//  the region the router ever prices.
//
//  forge test --match-path test/CoreMetamorphicRelations.t.sol
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixCore as BPC} from "../src/BlazePhoenixCore.sol";

contract CoreMetamorphicRelationsTest is Test {
    uint160 constant SQRT_P_1 = 79228162514264337593543950336; // price 1.0

    function _dom(uint256 a, uint256 rIn, uint256 rOut) private pure returns (uint256, uint256, uint256) {
        rIn  = bound(rIn,  1e6, type(uint112).max);
        rOut = bound(rOut, 1e6, type(uint112).max);
        a    = bound(a, 1, rIn);
        return (a, rIn, rOut);
    }

    function testFuzz_MR1_OutV2_MonotoneInAmountIn(uint256 a, uint256 b, uint256 rIn, uint256 rOut) public pure {
        (a, rIn, rOut) = _dom(a, rIn, rOut);
        b = bound(b, a, rIn);
        assertLe(BPC.outV2(a, rIn, rOut, 30), BPC.outV2(b, rIn, rOut, 30), "MR1: more in, no less out");
    }

    function testFuzz_MR2_OutV2_SplittingNeverGains(uint256 a, uint256 b, uint256 rIn, uint256 rOut) public pure {
        (a, rIn, rOut) = _dom(a, rIn, rOut);
        b = bound(b, 1, rIn);
        uint256 whole = BPC.outV2(a + b, rIn, rOut, 30);
        uint256 split = BPC.outV2(a, rIn, rOut, 30) + BPC.outV2(b, rIn, rOut, 30);
        // Rounding budget: each of the two split terms floors away < 1 wei, so
        // the measured split can sit up to 2 wei UNDER the exact one that the
        // concavity bound is about. The first run found the 1-wei case
        // (2938 > 2937); the relation is exact up to that budget.
        assertLe(whole, split + 2, "MR2: one order across one pool never beats the split of itself (2 wei rounding)");
    }

    function testFuzz_MR3_OutV2_NoRoundTripProfit(uint256 a, uint256 rIn, uint256 rOut) public pure {
        (a, rIn, rOut) = _dom(a, rIn, rOut);
        uint256 out = BPC.outV2(a, rIn, rOut, 30);
        vm.assume(out > 0 && out < rOut);
        uint256 back = BPC.outV2(out, rOut - out, rIn + a, 30);
        assertLe(back, a, "MR3: a round trip inside one block cannot create value");
    }

    function testFuzz_MR4_OutV2_ScaleEquivariance(uint256 a, uint256 rIn, uint256 rOut, uint256 k) public pure {
        (a, rIn, rOut) = _dom(a, rIn, rOut);
        k = bound(k, 2, 1_000);
        vm.assume(rIn * k <= type(uint112).max && rOut * k <= type(uint112).max);
        uint256 small = BPC.outV2(a, rIn, rOut, 30);
        uint256 big   = BPC.outV2(a * k, rIn * k, rOut * k, 30);
        // Rounding budget: small = floor(x) loses < 1 wei, so small * k can sit
        // up to k wei under k * x, while big = floor(k * x) sits at most 1 wei
        // under it. Hence big is within [small * k - 1, small * k + k]. The
        // first run found big - small * k = 148 with k in [2, 1000].
        assertLe(big, small * k + k, "MR4: scaling up yields at most k wei over k times the small trade (rounding)");
        assertGe(big + 1, small * k, "MR4: ... and at most 1 wei under it");
    }

    function testFuzz_MR1_OutV3_MonotoneInAmountIn(uint256 a, uint256 b, uint128 liq) public pure {
        liq = uint128(bound(liq, 1e12, type(uint128).max / 4));
        a = bound(a, 1, uint256(liq));
        b = bound(b, a, uint256(liq));
        assertLe(
            BPC.outV3(a, SQRT_P_1, liq, 3000, true, 0),
            BPC.outV3(b, SQRT_P_1, liq, 3000, true, 0),
            "MR1 (V3): more in, no less out"
        );
    }
}
