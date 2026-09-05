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

    // ─── Extension (2026-09-05): the V3 and stable curves get the same four
    //     judges the constant product had, plus two relations across fees and
    //     directions no oracle written from the same formula can fake. ───

    /// One ulp of the square-root price is worth L / 2^96 wei of output (ASSURANCE §4k): the
    /// Core rounds the new price once and the two arms of outV3 round it in opposite
    /// directions, so every V3 relation below tolerates one ulp plus the floor divisions.
    function _ulp(uint128 liq) private pure returns (uint256) {
        return uint256(liq) / 2 ** 96 + 1;
    }

    function _v3dom(uint256 a, uint256 b, uint128 liq) private pure returns (uint256, uint256, uint128) {
        liq = uint128(bound(liq, 1e12, 1e30));
        a = bound(a, 1, uint256(liq) / 2);
        b = bound(b, 1, uint256(liq) / 2);
        return (a, b, liq);
    }

    /// MR2 (V3): a single-tick sqrt-price step is concave, so splitting an order
    /// across the same pool never gains.
    function testFuzz_MR2_OutV3_SplittingNeverGains(uint256 a, uint256 b, uint128 liq) public pure {
        (a, b, liq) = _v3dom(a, b, liq);
        uint256 whole = BPC.outV3(a + b, SQRT_P_1, liq, 3000, true, 0);
        uint256 parts = BPC.outV3(a, SQRT_P_1, liq, 3000, true, 0) + BPC.outV3(b, SQRT_P_1, liq, 3000, true, 0);
        // two floor divisions on the parts against one on the whole, plus one ulp
        assertLe(whole, parts + 2 + _ulp(liq), "MR2 (V3): splitting across the same pool gained");
    }

    /// MR4 (V3): at a fixed price the output is linear in liquidity, so scaling the
    /// order and the liquidity together scales the output — within k wei of rounding.
    function testFuzz_MR4_OutV3_ScaleEquivariance(uint256 a, uint128 liq, uint8 k8) public pure {
        uint256 k = bound(k8, 2, 200);
        liq = uint128(bound(liq, 1e12, 1e27));
        a = bound(a, 1, uint256(liq) / 2);
        uint256 small = BPC.outV3(a, SQRT_P_1, liq, 3000, true, 0);
        uint256 big = BPC.outV3(a * k, SQRT_P_1, uint128(uint256(liq) * k), 3000, true, 0);
        uint256 lhs = small * k;
        uint256 diff = lhs > big ? lhs - big : big - lhs;
        // the fee floor and the output floor each lose < 1 wei on the small side, scaled by k;
        // the big side loses < 1 wei; and one ulp at the scaled liquidity
        assertLe(diff, 2 * k + 1 + _ulp(uint128(uint256(liq) * k)), "MR4 (V3): scaling order and liquidity together did not scale the output");
    }

    /// MR5: a higher fee never pays more — on both curves.
    function testFuzz_MR5_FeeMonotone(uint256 a, uint256 rIn, uint256 rOut, uint128 liq, uint16 f1, uint16 f2) public pure {
        (a, rIn, rOut) = _dom(a, rIn, rOut);
        uint256 lo = bound(f1, 0, 999);
        uint256 hi = bound(f2, lo, 999);
        assertGe(BPC.outV2(a, rIn, rOut, lo), BPC.outV2(a, rIn, rOut, hi), "MR5 (V2): the higher fee paid more");
        liq = uint128(bound(liq, 1e12, 1e30));
        uint256 a3 = bound(a, 1, uint256(liq) / 2);
        uint24 lo3 = uint24(lo * 100);
        uint24 hi3 = uint24(hi * 100);
        assertGe(BPC.outV3(a3, SQRT_P_1, liq, lo3, true, 0), BPC.outV3(a3, SQRT_P_1, liq, hi3, true, 0), "MR5 (V3): the higher fee paid more");
    }

    /// MR6 (V3): at price 1.0 the two directions are the same trade, so the two
    /// arms of outV3 must agree to one ulp. MEASURED before the bound was written:
    /// at L = 8.5e37 and 1,374 wei in, the zeroForOne arm quoted 1,073,741,823 wei
    /// (exactly L / 2^96: the price moved one ulp, worth that much output) while the
    /// other arm quoted 0 (its price step rounded to nothing and it failed closed).
    /// Both are inside the §4k bound; the relation states it as a relation between
    /// the arms rather than against a spec, and the domain is real liquidity.
    function testFuzz_MR6_OutV3_DirectionSymmetryAtParity(uint256 a, uint128 liq) public pure {
        liq = uint128(bound(liq, 1e12, 1e30));
        a = bound(a, 1, uint256(liq) / 2);
        uint256 z = BPC.outV3(a, SQRT_P_1, liq, 3000, true, 0);
        uint256 o = BPC.outV3(a, SQRT_P_1, liq, 3000, false, 0);
        // each arm rounds ITS OWN price step once, in opposite directions (the
        // zeroForOne arm floors the new price, the other floors the step), so the
        // arms can sit one ulp on either side of the exact value: two ulps, plus
        // the two output floors. Measured 16 wei at L = 9.5e28 (ulp = 12).
        assertApproxEqAbs(z, o, 2 * _ulp(liq) + 2, "MR6 (V3): the two directions disagree at parity by more than two ulps");
    }

    // ─── Solidly stable curve (x^3 y + x y^3), the same four judges ───

    function _sdom(uint256 a, uint256 rIn, uint256 rOut) private pure returns (uint256, uint256, uint256) {
        rIn = bound(rIn, 1e20, 1e26);
        rOut = bound(rOut, rIn / 4, rIn * 4);
        a = bound(a, 1e15, rIn / 10);
        return (a, rIn, rOut);
    }

    function testFuzz_MR1_Stable_MonotoneInAmountIn(uint256 a, uint256 b, uint256 rIn, uint256 rOut) public pure {
        (a, rIn, rOut) = _sdom(a, rIn, rOut);
        b = bound(b, a, rIn / 10);
        assertLe(BPC.outSolidly(a, rIn, rOut, 5, true), BPC.outSolidly(b, rIn, rOut, 5, true), "MR1 (stable): more in, less out");
    }

    function testFuzz_MR2_Stable_SplittingNeverGains(uint256 a, uint256 b, uint256 rIn, uint256 rOut) public pure {
        (a, rIn, rOut) = _sdom(a, rIn, rOut);
        b = bound(b, 1e15, rIn / 10);
        uint256 whole = BPC.outSolidly(a + b, rIn, rOut, 5, true);
        uint256 parts = BPC.outSolidly(a, rIn, rOut, 5, true) + BPC.outSolidly(b, rIn, rOut, 5, true);
        assertLe(whole, parts + 2, "MR2 (stable): splitting across the same pool gained");
    }

    function testFuzz_MR3_Stable_NoRoundTripProfit(uint256 a, uint256 rIn, uint256 rOut) public pure {
        (a, rIn, rOut) = _sdom(a, rIn, rOut);
        uint256 out = BPC.outSolidly(a, rIn, rOut, 5, true);
        vm.assume(out > 0 && out < rOut);
        uint256 back = BPC.outSolidly(out, rOut - out, rIn + a, 5, true);
        assertLe(back, a, "MR3 (stable): a round trip inside one block made money");
    }

    function testFuzz_MR4_Stable_ScaleEquivariance(uint256 a, uint256 rIn, uint256 rOut, uint8 k8) public pure {
        uint256 k = bound(k8, 2, 50);
        rIn = bound(rIn, 1e20, 1e24);
        rOut = bound(rOut, rIn / 4, rIn * 4);
        a = bound(a, 1e15, rIn / 10);
        uint256 small = BPC.outSolidly(a, rIn, rOut, 5, true);
        uint256 big = BPC.outSolidly(a * k, rIn * k, rOut * k, 5, true);
        uint256 lhs = small * k;
        uint256 diff = lhs > big ? lhs - big : big - lhs;
        // Newton's iterate is not exactly homogeneous; the tolerance is k wei of
        // rounding plus one part in a million of the output.
        assertLe(diff, k + big / 1e6, "MR4 (stable): scaling the pool and the order did not scale the output");
    }

    /// MR7: the volatile Solidly arm IS the constant product — one producer, not two.
    function testFuzz_MR7_SolidlyVolatileIsV2(uint256 a, uint256 rIn, uint256 rOut) public pure {
        (a, rIn, rOut) = _dom(a, rIn, rOut);
        assertEq(BPC.outSolidly(a, rIn, rOut, 30, false), BPC.outV2(a, rIn, rOut, 30), "MR7: the volatile arm diverged from outV2");
    }
}
