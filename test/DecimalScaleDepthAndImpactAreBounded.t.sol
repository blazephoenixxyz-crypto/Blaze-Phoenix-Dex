// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// Fuzz gap closure (docs/assurance/FUZZ_COVERAGE.md, 2026-11-13). The decimal scale (to18,
// shortSide18, maxSide18), the concentrated depth (depthFromL, depthFromL18), the V2 impact share
// (impactV2Bps) and the iron floor (ironFloorBpsShv) were GAP rows: no fuzzed test reached them.
// Every oracle here is written from the specification, not from the code under test, and half of
// every input is drawn from the extreme table: 0, 1, dust, max uint128, max uint256, decimals
// 0/6/8/18/19/24/77, sqrt prices at the tick edges, the thinnest and the deepest book.
// Not a fix: the red step is the mutant each test carries in .github/scripts/mutants.py.
// forge test --match-contract DecimalScaleDepthAndImpactAreBounded -vv
import {Test} from "forge-std/Test.sol";
import {BlazePhoenixCore as BPC} from "../src/BlazePhoenixCore.sol";

contract DecimalScaleDepthAndImpactAreBoundedTest is Test {
    uint256 constant BPS = 10_000;
    uint256 constant Q96 = 1 << 96;
    uint160 constant MIN_SQRT = 4295128739;
    uint160 constant MAX_SQRT = 1461446703485210103287273052203988822378723970342;
    // Core._decimalsOf answers 18 for any reading >= 78, so 77 is the widest decimals reached.
    uint8 constant MAX_DEC = 77;
    // The floor band of the specification: clean swaps start at 96 %, nothing goes under 80 %.
    uint256 constant FLOOR_BASE = 9_600;
    uint256 constant HARD_FLOOR = 8_000;

    // ---- extreme tables: an even selector picks an extreme, an odd one keeps the fuzzed value ----
    function _amt(uint256 raw, uint256 sel) internal pure returns (uint256) {
        uint256[8] memory x = [uint256(0), 1, 2, 1e3, type(uint128).max, uint256(type(uint128).max) + 1,
                               type(uint256).max - 1, type(uint256).max];
        return sel % 2 == 0 ? x[(sel >> 1) % 8] : raw;
    }

    function _amt128(uint256 raw, uint256 sel) internal pure returns (uint256) {
        uint256[6] memory x = [uint256(0), 1, 2, 1e3, type(uint128).max - 1, type(uint128).max];
        return sel % 2 == 0 ? x[(sel >> 1) % 6] : bound(raw, 0, type(uint128).max);
    }

    function _dec(uint256 raw, uint256 sel) internal pure returns (uint8) {
        uint8[7] memory d = [uint8(0), 6, 8, 18, 19, 24, 77];
        return sel % 2 == 0 ? d[(sel >> 1) % 7] : uint8(bound(raw, 0, MAX_DEC));
    }

    function _sqrt(uint256 raw, uint256 sel) internal pure returns (uint160) {
        uint160[5] memory s = [MIN_SQRT, MIN_SQRT + 1, uint160(Q96), MAX_SQRT - 1, MAX_SQRT];
        return sel % 2 == 0 ? s[(sel >> 1) % 5] : uint160(bound(raw, MIN_SQRT, MAX_SQRT));
    }

    /// The specification of the scale to 18 decimals: exact while it fits, saturated when not.
    function _scale(uint256 v, uint8 d) internal pure returns (uint256) {
        if (d >= 18) return v / 10 ** (uint256(d) - 18);
        uint256 f = 10 ** (18 - uint256(d));
        return v > type(uint256).max / f ? type(uint256).max : v * f;
    }

    /// to18 is the decimal scale, saturating instead of wrapping, and monotone in the amount.
    function testFuzz_To18IsTheScaleAndSaturatesNeverWraps(uint256 a, uint256 b, uint256 d, uint256 sel) public pure {
        a = _amt(a, sel);
        b = _amt(b, sel >> 8);
        uint8 dec = _dec(d, sel >> 16);
        assertEq(BPC.to18(a, dec), _scale(a, dec), "to18 is the decimal scale");
        if (a > b) (a, b) = (b, a);
        assertLe(BPC.to18(a, dec), BPC.to18(b, dec), "to18 is monotone in the amount");
    }

    /// shortSide18 is the smaller of the two scaled sides whatever their order; maxSide18 the larger.
    function testFuzz_ShortSideIsTheSmallerScaledSideInEitherOrder(uint256 a0, uint256 a1, uint256 d0, uint256 d1, uint256 sel)
        public pure
    {
        a0 = _amt(a0, sel);
        a1 = _amt(a1, sel >> 8);
        uint8 e0 = _dec(d0, sel >> 16);
        uint8 e1 = _dec(d1, sel >> 24);
        uint256 n0 = _scale(a0, e0);
        uint256 n1 = _scale(a1, e1);
        assertEq(BPC.shortSide18(a0, e0, a1, e1), n0 < n1 ? n0 : n1, "short side is the min");
        assertEq(BPC.shortSide18(a1, e1, a0, e0), n0 < n1 ? n0 : n1, "short side ignores the order");
        assertEq(BPC.maxSide18(a0, e0, a1, e1), n0 < n1 ? n1 : n0, "max side is the max");
    }

    /// The concentrated depth is min(L*Q96/sp, L*sp/Q96); the two floors multiply to at most L^2,
    /// so the depth never exceeds the liquidity, from the thinnest book to the deepest, at any tick.
    function testFuzz_DepthFromLNeverExceedsTheLiquidity(uint256 liq, uint256 sp, uint256 sel) public pure {
        uint128 l = uint128(_amt128(liq, sel));
        uint160 s = _sqrt(sp, sel >> 8);
        assertLe(BPC.depthFromL(l, s), l, "depth <= L at every price");
        assertEq(BPC.depthFromL(l, 0), 0, "no price, no depth");
    }

    /// At sqrt price k*Q96 the token0 side is floor(L/k) and the token1 side is L*k, each scaled by
    /// its OWN decimals: a depth that swapped the decimals between the sides answers another number.
    function testFuzz_DepthFromL18ScalesEachSideByItsOwnDecimals(uint256 liq, uint256 k, uint256 d0, uint256 d1, uint256 sel)
        public pure
    {
        uint128 l = uint128(_amt128(liq, sel));
        k = sel % 3 == 0 ? (sel % 2 == 0 ? 1 : type(uint32).max) : bound(k, 1, type(uint32).max);
        uint8 e0 = _dec(d0, sel >> 8);
        uint8 e1 = _dec(d1, sel >> 16);
        uint256 x0 = _scale(uint256(l) / k, e0);
        uint256 x1 = _scale(uint256(l) * k, e1);
        assertEq(BPC.depthFromL18(l, uint160(k * Q96), e0, e1), x0 < x1 ? x0 : x1, "each side keeps its decimals");
    }

    /// impactV2Bps is ceil(a * BPS / (r + a)): bounded by BPS, monotone in the size, a whole BPS on
    /// an empty reserve, and never a free zero for a positive input (rounding against the caller).
    function testFuzz_ImpactV2BpsIsTheRoundedUpShareOfTheReserve(uint256 a, uint256 r, uint256 bump, uint256 sel) public pure {
        a = _amt128(a, sel);
        r = _amt128(r, sel >> 8);
        uint256 got = BPC.impactV2Bps(a, r);
        uint256 want = r == 0 ? BPS : (a * BPS + (r + a) - 1) / (r + a);
        assertEq(got, want, "impact is the rounded-up share");
        assertLe(got, BPS, "impact <= BPS");
        if (a > 0) assertGe(got, 1, "a positive input never reads as zero impact");
        bump = bound(bump, 0, type(uint128).max - a);
        assertGe(BPC.impactV2Bps(a + bump, r), got, "impact is monotone in the size");
    }

    /// The iron floor stays inside [80 %, 96 %] and no extra risk on any coordinate raises it.
    function testFuzz_IronFloorStaysInItsBandAndNeverRisesWithRisk(uint256 imp, uint256 leg, uint256 sig, uint256 bump)
        public pure
    {
        imp = bound(imp, 0, 2 * BPS);
        leg = bound(leg, 0, 4 * BPS);
        sig = bound(sig, 0, 1e20);
        bump = bound(bump, 0, BPS);
        uint256 f = BPC.ironFloorBpsShv(imp, leg, sig);
        uint256 total = leg + (imp > BPS ? BPS : imp) + sig / 1e14;
        uint256 want = total >= FLOOR_BASE ? HARD_FLOOR : FLOOR_BASE - total;
        if (want < HARD_FLOOR) want = HARD_FLOOR;
        assertEq(f, want, "floor is the specification");
        assertGe(f, HARD_FLOOR, "never under the hard floor");
        assertLe(f, FLOOR_BASE, "never over the base");
        assertLe(BPC.ironFloorBpsShv(imp + bump, leg, sig), f, "impact never raises the floor");
        assertLe(BPC.ironFloorBpsShv(imp, leg + bump, sig), f, "legs never raise the floor");
        assertLe(BPC.ironFloorBpsShv(imp, leg, sig + bump * 1e14), f, "sigma never raises the floor");
    }

    /// The extreme table walked deterministically, so a run with few fuzz runs still visits it.
    function test_ExtremeTableHoldsEveryScaleAndDepthBound() public pure {
        for (uint256 i; i < 16; i++) {
            for (uint256 j; j < 14; j++) {
                uint256 a = _amt(0, i);
                uint8 d = _dec(0, j);
                assertEq(BPC.to18(a, d), _scale(a, d));
                uint128 l = uint128(_amt128(0, i % 12));
                assertLe(BPC.depthFromL(l, _sqrt(0, j % 10)), l);
            }
        }
    }
}
