// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixCore as BPC} from "../src/BlazePhoenixCore.sol";

/// @title sqrtPriceAtTick against a slow reference computed at runtime from the definition
///
/// WHERE THE REFERENCE COMES FROM. The quantity under test is sqrt(1.0001^tick) * 2^96. The reference
/// below is written from that definition alone, with no tick table and no constant taken from any
/// other implementation; the only literals are 10000 (the denominator of 1.0001), 20000 (the first
/// Newton guess 1 - 1/20000) and powers of two that fix the fixed-point formats. It was written without
/// consulting any other TickMath code, and its structure is not a table walk:
///   1. a = 1.0001 = 1 + 1/10000, held in Q254: 2^254 + floor(2^254 / 10000).
///   2. y = 1/sqrt(a) by Newton's iteration for the inverse square root, which needs only
///      multiplications: y <- y + y * (1 - a*y^2) / 2, seven steps from the first-order guess
///      1 - 1/20000 (the quadratic convergence covers 256 bits in five; two are margin).
///      b = sqrt(a) = a * y.
///   3. sqrt(1.0001^t) = b^t for t >= 0 and y^(-t) for t < 0, by binary exponentiation on
///      normalised floating numbers (mantissa m in [2^255, 2^256), value m * 2^e). The product of two
///      mantissas is the 512-bit number hi*2^256 + lo; hi is recovered from the identity
///      a*b mod (2^256 - 1) = (hi + lo) mod (2^256 - 1), i.e. hi = mulmod(a, b, 2^256 - 1) - lo, with
///      a borrow when that subtraction wraps.
///   4. The Q96 figure is floor(m * 2^(e + 96)); e + 96 is negative over the whole tick domain, so the
///      floor is one right shift and the bits shifted out are the fraction below it.
///
/// PRECISION. Every step floors, so the reference carries a relative error below 2^-230 (the base is
/// exact to about 2^-252 and is raised to at most 887,272; the forty products add 40 * 2^-255). On a
/// Q96 figure of at most 2^160 that is an absolute error under 2^-70, so the floor is the exact floor
/// unless the true fraction lies within 2^-70 of an integer. The value is never an integer for t != 0
/// (10000^k has a factor 5^(4k) that 2^96 cannot cancel, and 10001 = 73 * 137 is not a square), so
/// for t != 0 the ceiling is floor + 1. The same reference, run in Python at 150 decimal digits over
/// the two edges, every power of two on both sides with its neighbours and 300 random ticks (429
/// points), floors to the same integer as the decimal evaluation at every point.
///
/// WHAT WAS MEASURED (every tick of the domain, -887,272..887,272, off-chain, the same reference
/// against a port of the Core; the tests below pin the facts on grids, strides and fuzz):
///   - strictly increasing at every consecutive pair;
///   - for every t <= 0 and for 0 < t < 132,822 the Core is exactly the ceiling of the definition:
///     its last step rounds the Q32 remainder up, and on that band the truncation of its
///     intermediate products never crosses an integer boundary;
///   - from t = 132,822 upward the truncated products carry through the inversion
///     2^256 / r and the Core drifts on both sides of the definition: of the 887,272 positive
///     ticks, 1,109,074 - 887,272 = 221,802 are still the exact ceiling, 659,873 are above it (by at
///     most one part in 2^64.0: worst at t = 887,234; 2^-64.9 at MAX_TICK), 164 are exactly
///     the floor, and 5,433 sit strictly under the definition, all of them between t = 262,144 (the
///     first, 2^18) and t = 469,505, by at most 191,887 units (t = 465,587; one part in 2^112).
///   The explicit bound asserted below is one unit of the last place plus one part in 2^63.
///
/// The tests. Four properties across ranges (the edges and their +-1 neighbours, every power of
/// two on both sides, the exact band, the stride of the whole domain), vectors (inside, one past
/// the domain, the ticks where the Core sits under the definition) and dimensions (unit grid,
/// bounded fuzz, whole-domain fuzz, each with its mutant in .github/scripts/mutants.py):
///   1. domain: both edges and their inside neighbours; one past each refused by its reason;
///   2. order: strictly increasing, by consecutive pairs on the grid and by fuzz;
///   3. rounding: the exact ceiling on the exact band, by grid and by fuzz;
///   4. round trip: tick -> Core -> reference inverse -> tick, by grid (with the three
///      under-ticks as witnesses) and by whole-domain fuzz;
///   5. error: within 1 ulp + 2^-63 relative, by whole-domain fuzz and by a stride sweep that
///      counts the points where the drift is visible (non-vacuity).
library SlowSqrtPrice {
    uint256 internal constant ONE_Q255 = 1 << 255;

    /// @dev a*b = hi*2^256 + lo.
    function mul512(uint256 a, uint256 b) internal pure returns (uint256 hi, uint256 lo) {
        unchecked {
            lo = a * b;
            uint256 mm = mulmod(a, b, type(uint256).max);
            hi = mm - lo - (mm < lo ? 1 : 0);
        }
    }

    /// @dev 1.0001 in Q254.
    function aQ254() internal pure returns (uint256) {
        return (uint256(1) << 254) + (uint256(1) << 254) / 10000;
    }

    /// @dev 1/sqrt(1.0001) in Q255, Newton's inverse square root (multiplications only).
    function invSqrtQ255() internal pure returns (uint256 y) {
        uint256 a = aQ254();
        y = ONE_Q255 - ONE_Q255 / 20000;
        for (uint256 i; i < 7; ++i) {
            (uint256 hi, uint256 lo) = mul512(y, y);
            uint256 y2 = (hi << 1) | (lo >> 255); // Q255
            (hi, lo) = mul512(a, y2);
            uint256 p = (hi << 2) | (lo >> 254); // a*y^2 in Q255
            if (p <= ONE_Q255) {
                (hi,) = mul512(y, ONE_Q255 - p); // y * (1 - a*y^2) / 2
                y += hi;
            } else {
                (hi,) = mul512(y, p - ONE_Q255);
                y -= hi;
            }
        }
    }

    /// @dev sqrt(1.0001) = a * (1/sqrt(a)), in Q254.
    function sqrtQ254() internal pure returns (uint256) {
        (uint256 hi, uint256 lo) = mul512(aQ254(), invSqrtQ255());
        return (hi << 1) | (lo >> 255);
    }

    /// @dev Product of two normalised floating numbers, renormalised.
    function fmul(uint256 m1, int256 e1, uint256 m2, int256 e2) internal pure returns (uint256, int256) {
        (uint256 hi, uint256 lo) = mul512(m1, m2);
        if (hi >> 255 != 0) return (hi, e1 + e2 + 256);
        return ((hi << 1) | (lo >> 255), e1 + e2 + 255);
    }

    /// @dev (m * 2^e)^n by binary exponentiation.
    function fpow(uint256 m, int256 e, uint256 n) internal pure returns (uint256 rm, int256 re) {
        rm = ONE_Q255;
        re = -255;
        while (n != 0) {
            if (n & 1 != 0) (rm, re) = fmul(rm, re, m, e);
            n >>= 1;
            if (n != 0) (m, e) = fmul(m, e, m, e);
        }
    }

    /// @return f floor(sqrt(1.0001^t) * 2^96)
    /// @return frac the 256-bit fraction below it (zero only at t == 0)
    function sqrtPriceQ96(int24 t) internal pure returns (uint256 f, uint256 frac) {
        uint256 m;
        int256 e;
        if (t >= 0) (m, e) = fpow(sqrtQ254() << 1, -255, uint256(int256(t)));
        else (m, e) = fpow(invSqrtQ255() << 1, -256, uint256(-int256(t)));
        int256 s = -(e + 96);
        require(s > 0 && s < 256, "ref: shift");
        f = m >> uint256(s);
        frac = m << (256 - uint256(s));
    }

    /// @dev The largest tick whose exact sqrt price floors at or below p: a binary search on the
    ///      reference, which the definition makes strictly increasing in t.
    function tickOf(uint256 p) internal pure returns (int24) {
        int256 lo = BPC.V4_MIN_TICK;
        int256 hi = BPC.V4_MAX_TICK;
        (uint256 fLo,) = sqrtPriceQ96(int24(lo));
        require(p >= fLo, "ref: under the domain");
        (uint256 fHi,) = sqrtPriceQ96(int24(hi));
        if (p >= fHi) return int24(hi);
        while (hi - lo > 1) {
            int256 mid = (lo + hi) >> 1;
            (uint256 fMid,) = sqrtPriceQ96(int24(mid));
            if (fMid <= p) lo = mid;
            else hi = mid;
        }
        return int24(lo);
    }
}

/// @dev External door so a refusal of the internal library function is observable with expectRevert.
contract SqrtPriceAtTickDoor {
    function sqrtPriceAtTick(int24 tick) external pure returns (uint160) {
        return BPC.sqrtPriceAtTick(tick);
    }
}

contract SqrtPriceAtTickSlowReferenceTest is Test {
    int24 internal constant MIN = BPC.V4_MIN_TICK;
    int24 internal constant MAX = BPC.V4_MAX_TICK;
    /// @dev Below this tick (and on the whole negative half) the Core is the exact ceiling of the
    ///      definition; measured first departure at 132,822, so 2^17 keeps a margin of 1,750 ticks.
    int24 internal constant EXACT_BAND_END = 131072;
    /// @dev |Core - floor(definition)| <= 1 + floor(definition) >> ERR_LOG2 over the whole domain;
    ///      measured worst 2^-64.01 (t = 887,234), so 63 keeps a factor of two.
    uint256 internal constant ERR_LOG2 = 63;
    /// @dev The Core sits strictly under the definition at 5,433 ticks, all inside this range
    ///      (measured on the whole domain; the first is 2^18, a grid tick), by at most one part in
    ///      2^100 (measured 2^-112).
    int24 internal constant UNDER_FIRST = 262144;
    int24 internal constant UNDER_LAST = 469505;
    uint256 internal constant UNDER_LOG2 = 100;

    SqrtPriceAtTickDoor internal door;

    function setUp() public {
        door = new SqrtPriceAtTickDoor();
    }

    function _core(int24 t) internal pure returns (uint256) {
        return BPC.sqrtPriceAtTick(t);
    }

    function _ref(int24 t) internal pure returns (uint256 f) {
        (f,) = SlowSqrtPrice.sqrtPriceQ96(t);
    }

    /// @dev The grid: both edges, zero, and every power of two on both sides, each with its
    ///      two neighbours; 6 + 20 * 2 * 3 = 126 ticks, clamped into the domain.
    function _grid() internal pure returns (int24[] memory g) {
        g = new int24[](126);
        uint256 n;
        g[n++] = MIN;
        g[n++] = MIN + 1;
        g[n++] = -1;
        g[n++] = 0;
        g[n++] = MAX - 1;
        g[n++] = MAX;
        for (uint256 i; i < 20; ++i) {
            int24 p = int24(int256(1 << i));
            for (int24 d = -1; d <= 1; ++d) {
                int24 t = p + d;
                if (t > MAX) t = MAX;
                g[n++] = t;
                g[n++] = -t;
            }
        }
    }

    function _assertWithinBound(int24 t) internal pure {
        uint256 c = _core(t);
        uint256 f = _ref(t);
        uint256 err = c > f ? c - f : f - c;
        assertLe(err, 1 + (f >> ERR_LOG2), "sqrtPriceAtTick: outside 1 ulp + 2^-63");
    }

    // ------------------------------------------------------------------ 1. domain

    /// @notice MIN_TICK and MAX_TICK and their inside neighbours are priced against the definition
    ///         (exact ceiling at the low edge, within the bound at the high edge, and the high edge
    ///         fits uint160 with its top bit set); one tick past each edge is refused by "BPC:tick".
    function test_SqrtPriceAtTick_Domain_BothEdgesAndTheirInsideNeighboursMatchTheReference_OnePastEachIsRefusedByItsReason()
        public
    {
        assertEq(_core(MIN), _ref(MIN) + 1, "MIN_TICK is the ceiling of the definition");
        assertEq(_core(MIN + 1), _ref(MIN + 1) + 1, "MIN_TICK + 1 is the ceiling of the definition");
        _assertWithinBound(MAX);
        _assertWithinBound(MAX - 1);
        assertGt(_core(MAX), _core(MAX - 1), "MAX_TICK is above its neighbour");
        assertLt(_core(MIN), _core(MIN + 1), "MIN_TICK is below its neighbour");
        assertEq(_core(0), 1 << 96, "tick zero is exactly 2^96");
        assertEq(_ref(0), 1 << 96, "the reference prices tick zero at exactly 2^96");
        assertGe(_core(MAX), 1 << 159, "MAX_TICK uses the full width of uint160");
        assertLt(_core(MIN), 1 << 33, "MIN_TICK is a 33-bit figure");

        vm.expectRevert(bytes("BPC:tick"));
        door.sqrtPriceAtTick(MAX + 1);
        vm.expectRevert(bytes("BPC:tick"));
        door.sqrtPriceAtTick(MIN - 1);
        // Positive control beside the refusal: the edges themselves answer through the same door.
        assertEq(door.sqrtPriceAtTick(MAX), _core(MAX));
        assertEq(door.sqrtPriceAtTick(MIN), _core(MIN));
    }

    // ------------------------------------------------------------------ 2. order

    /// @notice On every grid tick t, price(t - 1) < price(t) < price(t + 1): the function is strictly
    ///         increasing across every power of two on both sides and at both edges.
    function test_SqrtPriceAtTick_Grid_EveryConsecutivePairAroundThePowersOfTwoAndTheEdgesIsStrictlyIncreasing()
        public
        pure
    {
        int24[] memory g = _grid();
        for (uint256 i; i < g.length; ++i) {
            int24 t = g[i];
            uint256 c = _core(t);
            if (t > MIN) assertLt(_core(t - 1), c, "one tick down is not strictly lower");
            if (t < MAX) assertGt(_core(t + 1), c, "one tick up is not strictly higher");
        }
    }

    /// @notice Anywhere in the domain, one tick up is a strictly higher price.
    function testFuzz_SqrtPriceAtTick_OneTickUpIsAStrictlyHigherPriceAnywhereInTheDomain(int24 t) public pure {
        t = int24(bound(int256(t), int256(MIN), int256(MAX) - 1));
        assertGt(_core(t + 1), _core(t), "one tick up is not strictly higher");
    }

    // ------------------------------------------------------------------ 3. rounding

    /// @notice On the exact band (every negative tick and every positive tick below 2^17) the Core is
    ///         exactly the ceiling of the definition: floor + 1, since the value is never an integer
    ///         off tick zero. Grid: the negative half of the grid, and the positive grid ticks below
    ///         the band's end, plus the band's end itself and the measured first departure, 132,822,
    ///         where the Core is one unit above the ceiling.
    function test_SqrtPriceAtTick_Rounding_IsTheExactCeilingOfTheDefinitionOnTheNegativeGridAndBelowTheBandEnd()
        public
        pure
    {
        int24[] memory g = _grid();
        uint256 n;
        for (uint256 i; i < g.length; ++i) {
            int24 t = g[i];
            if (t == 0 || t >= EXACT_BAND_END) continue;
            assertEq(_core(t), _ref(t) + 1, "not the ceiling of the definition");
            ++n;
        }
        assertEq(n, 113, "grid ticks on the exact band");
        assertEq(_core(EXACT_BAND_END - 1), _ref(EXACT_BAND_END - 1) + 1, "band end - 1");
        assertEq(_core(EXACT_BAND_END), _ref(EXACT_BAND_END) + 1, "band end");
        assertEq(_core(132821), _ref(132821) + 1, "last tick before the first departure");
        assertEq(_core(132822), _ref(132822) + 2, "first departure: one unit above the ceiling");
    }

    /// @notice Fuzz over the exact band: the Core is the ceiling of the definition.
    function testFuzz_SqrtPriceAtTick_Rounding_InsideTheExactBandTheCoreIsTheCeilingOfTheDefinition(int24 t)
        public
        pure
    {
        t = int24(bound(int256(t), int256(MIN), int256(EXACT_BAND_END) - 1));
        if (t == 0) {
            assertEq(_core(0), 1 << 96);
            return;
        }
        assertEq(_core(t), _ref(t) + 1, "not the ceiling of the definition");
    }

    // ------------------------------------------------------------------ 4. round trip

    /// @notice tick -> Core -> reference inverse -> tick lands on the tick for every grid tick the
    ///         Core prices at or above the definition, and on the tick below for the one grid tick
    ///         where the Core sits under it (2^18, by at most one part in 2^100) - the witness that
    ///         the inverse is the definition's, not the Core's.
    function test_SqrtPriceAtTick_RoundTrip_TheReferenceInverseReturnsEveryGridTick_AndTheTickBelowAtTheUnderTick()
        public
        pure
    {
        int24[] memory g = _grid();
        uint256 under;
        for (uint256 i; i < g.length; ++i) {
            int24 t = g[i];
            uint256 c = _core(t);
            uint256 f = _ref(t);
            int24 back = SlowSqrtPrice.tickOf(c);
            if (c >= f) {
                assertEq(back, t, "round trip missed the grid tick");
            } else {
                ++under;
                assertEq(t, UNDER_FIRST, "the grid's under-tick is 2^18");
                assertLe(f - c, f >> UNDER_LOG2, "under the definition by more than 2^-100");
                assertEq(back, t - 1, "the inverse of an under-tick is the tick below");
                assertEq(SlowSqrtPrice.tickOf(_core(t - 1)), t - 1, "its lower neighbour round-trips");
                assertEq(SlowSqrtPrice.tickOf(_core(t + 1)), t + 1, "its upper neighbour round-trips");
            }
        }
        assertEq(under, 1, "one grid tick under the definition");
        // One unit either side of a priced tick, on the exact band: the Core is the ceiling, so one
        // unit less is the floor of the definition and still the tick, two units less is the tick
        // below, one unit more stays on the tick.
        int24[4] memory probes = [int24(-5), 5, MIN + 2, EXACT_BAND_END - 2];
        for (uint256 i; i < 4; ++i) {
            int24 t = probes[i];
            uint256 c = _core(t);
            assertEq(SlowSqrtPrice.tickOf(c - 1), t, "one unit under the ceiling is the floor, still the tick");
            assertEq(SlowSqrtPrice.tickOf(c - 2), t - 1, "two units under the ceiling is the tick below");
            assertEq(SlowSqrtPrice.tickOf(c + 1), t, "one unit over the ceiling is still the tick");
        }
    }

    /// @notice Whole-domain fuzz: the reference inverse returns the tick, or the one below where the
    ///         Core sits under the definition (only inside the measured range of under-ticks), and
    ///         never the one above; on the exact band, the tick.
    function testFuzz_SqrtPriceAtTick_RoundTrip_TheReferenceInverseReturnsTheTickOrTheOneBelowNeverTheOneAbove(int24 t)
        public
        pure
    {
        t = int24(bound(int256(t), int256(MIN), int256(MAX)));
        int24 back = SlowSqrtPrice.tickOf(_core(t));
        if (t < EXACT_BAND_END) {
            assertEq(back, t, "round trip on the exact band");
        } else {
            if (back != t) {
                assertEq(back, t - 1, "round trip off by more than the under-drift");
                assertLt(_core(t), _ref(t), "the tick below only where the Core is under the definition");
                assertTrue(t >= UNDER_FIRST && t <= UNDER_LAST, "an under-tick outside the measured range");
            }
        }
    }

    // ------------------------------------------------------------------ 5. error in ulps

    /// @notice Whole-domain fuzz: |Core - floor(definition)| <= 1 + floor(definition) / 2^63.
    function testFuzz_SqrtPriceAtTick_Ulps_TheCoreIsWithinOneUnitOfTheLastPlacePlusOnePartInTwoToTheSixtyThree(int24 t)
        public
        pure
    {
        t = int24(bound(int256(t), int256(MIN), int256(MAX)));
        _assertWithinBound(t);
    }

    /// @notice A stride over the whole domain (every 997th tick from MIN_TICK, 1,780 points, plus MAX_TICK):
    ///         every point is within the bound, every consecutive pair of points is increasing, and
    ///         the stride reaches the regime where the drift is visible - at least a hundred points
    ///         with the error above one unit, all at positive ticks past the exact band, and the
    ///         largest excess over one unit stays under 2^-64 of the value (ERR_LOG2 keeps a margin).
    function test_SqrtPriceAtTick_Ulps_AStrideOfTheWholeDomainStaysUnderTheBoundAndReachesTheDriftRegime()
        public
        pure
    {
        uint256 points;
        uint256 drifted;
        uint256 worstExcessQ80; // (err - 1) * 2^80 / f, so 2^16 is one part in 2^64
        uint256 prev;
        for (int256 t = MIN; t <= MAX; t += 997) {
            int24 tick = int24(t);
            uint256 c = _core(tick);
            uint256 f = _ref(tick);
            uint256 err = c > f ? c - f : f - c;
            assertLe(err, 1 + (f >> ERR_LOG2), "stride point outside the bound");
            if (err > 1) {
                ++drifted;
                assertGe(tick, EXACT_BAND_END, "drift inside the exact band");
                uint256 excess = ((err - 1) << 80) / f;
                if (excess > worstExcessQ80) worstExcessQ80 = excess;
            } else if (tick != 0 && tick < EXACT_BAND_END) {
                assertEq(c, f + 1, "a point on the exact band is the ceiling");
            }
            if (points != 0) assertGt(c, prev, "stride points not increasing");
            prev = c;
            ++points;
        }
        // The last stride point is below MAX_TICK; the edge itself closes the sweep.
        assertGt(_core(MAX), prev, "MAX_TICK above the last stride point");
        _assertWithinBound(MAX);
        assertEq(points, 1780, "stride points");
        assertGe(drifted, 100, "the stride did not reach the drift regime");
        assertLt(worstExcessQ80, 1 << 16, "excess over one unit reached 2^-64 of the value");
        assertGt(worstExcessQ80, 1 << 14, "the stride did not see the measured drift (2^-66 or worse)");
    }
}
