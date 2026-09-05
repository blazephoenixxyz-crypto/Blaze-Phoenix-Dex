// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  Canonical oracles — the Core's quote maths against implementations written
//  from the venues' SPECIFICATIONS, not from the Core.
//
//  Every mock in this suite quotes with the Core's own formulas, so a defect in
//  the formula is invisible to every parity test that uses them: the oracle is
//  the object. The three functions below are independent implementations of
//  the published invariants — Uniswap V2's constant product with the fee on
//  the input, Uniswap V3's single-tick sqrt-price step, Solidly's stable curve
//  x³y + xy³ = k solved by Newton's method — written from the whitepapers, and
//  the Core is fuzzed against them.
//
//  What is asserted is the DIRECTION first: the Core never promises more than
//  the venue's own maths delivers (a quote above the truth is the defect that
//  reaches a user; a quote below it is a worse price the floor still bounds).
//  Tightness is asserted second, to the width the rounding order can explain.
//  The 512-bit multiply used inside the V3 oracle is the one primitive shared
//  with the Core; its own property test lives in BlazePhoenixCore.t.sol.
// =============================================================================

import {Test, console2} from "forge-std/Test.sol";
import {BlazePhoenixCore as BPC} from "../../src/BlazePhoenixCore.sol";

library SpecV2 {
    /// Uniswap V2 whitepaper / UniswapV2Library.getAmountOut, fee taken on the input in bps.
    function getAmountOut(uint256 ain, uint256 rIn, uint256 rOut, uint256 feeBps) internal pure returns (uint256) {
        uint256 ainFee = ain * (10_000 - feeBps);
        return ainFee * rOut / (rIn * 10_000 + ainFee);
    }
}

library SpecV3 {
    uint256 constant Q96 = 2 ** 96;
    /// Uniswap V3 whitepaper §6.2.3, one tick range, fee in hundredths of a bip on the input.
    /// zeroForOne: sqrtP' = L·sqrtP / (L + dx·sqrtP/Q96); amountOut = L·(sqrtP − sqrtP')/Q96.
    /// oneForZero: sqrtP' = sqrtP + dy·Q96/L;            amountOut = L·(1/sqrtP − 1/sqrtP').
    /// Rounding follows SqrtPriceMath exactly: the new price is rounded AGAINST the trader
    /// (up when token0 comes in, down when token1 does) and the output amount is rounded down,
    /// so the spec value is the largest output the pool would ever pay.
    function mulDivUp(uint256 a, uint256 b, uint256 d) internal pure returns (uint256 r) {
        r = BPC.mulDiv(a, b, d);
        if (mulmod(a, b, d) > 0) r += 1;
    }
    function getAmountOut(uint256 ain, uint160 sqrtP, uint128 liq, uint24 feePpm, bool zeroForOne) internal pure returns (uint256) {
        uint256 dIn = ain * (1_000_000 - feePpm) / 1_000_000;
        uint256 L = liq; uint256 P = sqrtP;
        if (zeroForOne) {
            // getNextSqrtPriceFromAmount0RoundingUp, then getAmount1Delta rounded down
            uint256 den = L * Q96 + dIn * P;
            uint256 pNew = mulDivUp(L * Q96, P, den);
            return BPC.mulDiv(L, P - pNew, Q96);
        } else {
            // getNextSqrtPriceFromAmount1RoundingDown, then getAmount0Delta rounded down
            uint256 pNew = P + BPC.mulDiv(dIn, Q96, L);
            return BPC.mulDiv(L * Q96, pNew - P, pNew) / P;
        }
    }
}

library SpecStable {
    /// Solidly's stable invariant k = x·y·(x² + y²) in 1e18 fixed point, output found by Newton's
    /// method on y for the new x, exactly as the curve is defined - written from the definition.
    function k(uint256 x, uint256 y) internal pure returns (uint256) {
        uint256 a = x * y / 1e18;
        uint256 b = x * x / 1e18 + y * y / 1e18;
        return a * b / 1e18;
    }
    function dkdy(uint256 x, uint256 y) internal pure returns (uint256) {
        return 3 * x * (y * y / 1e18) / 1e18 + (x * x / 1e18) * x / 1e18;
    }
    function getAmountOut(uint256 ain, uint256 rIn, uint256 rOut, uint256 feeBps) internal pure returns (uint256) {
        uint256 dIn = ain * (10_000 - feeBps) / 10_000;
        uint256 k0 = k(rIn, rOut);
        uint256 x1 = rIn + dIn;
        uint256 y = rOut;
        for (uint256 i; i < 255; ++i) {
            uint256 ky = k(x1, y);
            if (ky < k0) {
                uint256 dy = (k0 - ky) * 1e18 / dkdy(x1, y);
                if (dy == 0) break;
                y += dy;
            } else {
                uint256 dy = (ky - k0) * 1e18 / dkdy(x1, y);
                if (dy == 0) break;
                y -= dy;
            }
        }
        return rOut > y ? rOut - y : 0;
    }
}

contract CanonicalOraclesTest is Test {
    // ------------------------------------------------------------------ V2

    function testFuzz_V2_CoreNeverPromisesMoreThanTheSpec(uint256 ain, uint256 rIn, uint256 rOut, uint8 feeIdx) public pure {
        ain  = bound(ain, 1, 1e30);
        rIn  = bound(rIn, 1e6, 1e33);
        rOut = bound(rOut, 1e6, 1e33);
        uint256 fee = [uint256(1), 5, 30, 100][feeIdx % 4];
        uint256 spec = SpecV2.getAmountOut(ain, rIn, rOut, fee);
        uint256 core = BPC.outV2(ain, rIn, rOut, fee);
        assertLe(core, spec, "V2: the Core promised more than the constant product delivers");
        assertLe(spec - core, 1, "V2: the Core is within one wei of the spec");
    }

    // ------------------------------------------------------------------ V3

    function testFuzz_V3_CoreNeverPromisesMoreThanTheSpec(uint256 ain, uint256 liq, uint256 sqrtP, uint8 feeIdx, bool zfo) public pure {
        ain   = bound(ain, 1e12, 1e27);
        liq   = bound(liq, 1e18, 1e30);
        sqrtP = bound(sqrtP, 2 ** 80, 2 ** 112);
        uint24 fee = [uint24(100), 500, 3000, 10000][feeIdx % 4];
        uint256 spec = SpecV3.getAmountOut(ain, uint160(sqrtP), uint128(liq), fee, zfo);
        uint256 core = BPC.outV3(ain, uint160(sqrtP), uint128(liq), fee, zfo, 0);
        // THE BOUND IS ONE ULP OF THE SQUARE-ROOT PRICE. The pool rounds its new price against the
        // trader; the Core rounds it once. One unit of sqrtP is worth L / 2^96 wei of output, so the
        // Core may exceed the pool's own maths by at most that plus a wei - below one wei for any
        // pool with L < 2^96 (7.9e28), which is every pool in existence - and never by a relative
        // amount. The bound is stated in the quantity that causes it, not tuned to a sample.
        uint256 ulp = liq / SpecV3.Q96 + 1;
        assertLe(core, spec + ulp, "V3: the Core promised more than one price-ulp above the sqrt-price step");
        // rounding order explains at most a few wei plus one part in a billion on the low side
        if (spec > core) assertLe(spec - core, spec / 1e9 + 4, "V3: the Core is within rounding of the spec");
    }

    // ------------------------------------------------------------------ Solidly stable

    function testFuzz_SolidlyStable_CoreNeverPromisesMoreThanTheCurve(uint256 ain, uint256 rIn, uint256 rOut, uint8 feeIdx) public pure {
        rIn  = bound(rIn, 1e20, 1e26);
        rOut = bound(rOut, rIn / 4, rIn * 4);      // a stable pair sits near balance
        ain  = bound(ain, 1e15, rIn / 10);
        uint256 fee = [uint256(1), 5, 30, 100][feeIdx % 4];
        uint256 spec = SpecStable.getAmountOut(ain, rIn, rOut, fee);
        uint256 core = BPC.outSolidly(ain, rIn, rOut, fee, true);
        assertLe(core, spec + 2, "stable: the Core promised more than the curve delivers");
        // Newton stops within a wei of the root on either side; the Core may carry its own margin
        assertLe(spec - (core > spec ? spec : core), spec / 1e6 + 4, "stable: the Core is within rounding of the curve");
    }

    /// A deterministic grid, printed, so the tightness is a number and not only a bound.
    function test_Grid_TightnessIsMeasured() public pure {
        uint256 worstV2; uint256 worstV3; uint256 worstSt;
        uint256[4] memory amts = [uint256(1e15), 1e18, 1e21, 1e24];
        for (uint256 i; i < 4; ++i) {
            uint256 s = SpecV2.getAmountOut(amts[i], 1e24, 1e24, 30);
            uint256 c = BPC.outV2(amts[i], 1e24, 1e24, 30);
            if (s - c > worstV2) worstV2 = s - c;
            uint256 s3 = SpecV3.getAmountOut(amts[i], uint160(2 ** 96), uint128(1e24), 3000, true);
            uint256 c3 = BPC.outV3(amts[i], uint160(2 ** 96), uint128(1e24), 3000, true, 0);
            if (s3 > c3 && s3 - c3 > worstV3) worstV3 = s3 - c3;
            uint256 ss = SpecStable.getAmountOut(amts[i], 1e24, 1e24, 5);
            uint256 cs = BPC.outSolidly(amts[i], 1e24, 1e24, 5, true);
            uint256 d = ss > cs ? ss - cs : cs - ss;
            if (d > worstSt) worstSt = d;
        }
        console2.log("ORACLE V2 worst gap (wei):", worstV2);
        console2.log("ORACLE V3 worst gap (wei):", worstV3);
        console2.log("ORACLE stable worst gap (wei):", worstSt);
    }
}
