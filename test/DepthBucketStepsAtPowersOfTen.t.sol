// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  The depth bucket steps at every power of ten — and `ilog10` is the log that
//  decides where it steps.
//
//  `Core.depthBucket` (src/BlazePhoenixCore.sol:2098) is `0` below 1e15 and then
//  `min(15, ilog10(depthWad / 1e15))`, and `Core.ilog10` (:390) is the integer
//  log10 the whole thing rests on. The bucket is not decoration: `bucketWeight`
//  (:2105) turns it into the `1 << b` scale of a row's psi, which is the fitness
//  the funnel ranks by — so a step shipped one decade off is a wrong ranking for
//  every pool whose depth sits on that decade, and the registry's own depth write
//  (`RegistryDoorsMeasureWhatTheyWrite.t.sol`) walks the same function.
//
//  Measured on this tree @754d651: `ilog10` is named by **0** files under `test/`
//  and by **0** entries of `.github/scripts/mutants.py`; `depthBucket` is named by
//  three test files, and all three (DepthBucketDecimals.t.sol) assert its
//  *decimals-blindness* — none of them walks a power-of-ten boundary or the clamp.
//  So the boundary structure below had no instrument watching it.
//
//  What makes each test fail:
//    * a comparison changed from `>=` to `>` (or the `1e15` floor moved) — the
//      exact boundary assertions flip;
//    * a missing or duplicated arm inside `ilog10` — the 10^k / 10^k−1 / 10^k+1
//      triples disagree with the test's own loop oracle;
//    * the `b > 15 ? 15` clamp removed — the deep cases stop being 15;
//    * a `depthBucket` that erases the `d < 1e15 -> 0` arm — the sub-scale case
//      stops being 0 next to a control that shows a scale-sized depth is not 0.
//
//  Oracle discipline: every expected value comes from a textbook integer log10
//  implemented here, or from a power of ten built by hand — never from the code
//  under test.
//
//  forge test --match-contract DepthBucketStepsAtPowersOfTen -vv

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixCore as BPC} from "../src/BlazePhoenixCore.sol";

contract DepthBucketStepsAtPowersOfTenTest is Test {
    /// WAD depth of one whole unit in the 1e15-scaled units `depthBucket` takes.
    uint256 constant SCALE = 1e15;

    /// Textbook integer log10, written here as the independent oracle.
    function _oracle(uint256 x) internal pure returns (uint256 k) {
        while (x >= 10) {
            x /= 10;
            k += 1;
        }
    }

    function _b(uint256 x, uint256 lo, uint256 hi) internal pure returns (uint256) {
        if (hi <= lo) return lo;
        return lo + (x % (hi - lo + 1));
    }

    // ─── ilog10, against the loop oracle ─────────────────────────────────────

    /// `ilog10(x)` is the largest k with 10^k ≤ x, across the whole domain the
    /// docstring claims ("inputs up to 1e77"), fuzzed.
    function testFuzz_Ilog10IsTheLargestExponentNotAbove(uint256 x) public pure {
        x = _b(x, 1, 1e77);
        uint256 k = BPC.ilog10(x);
        assertLe(10 ** k, x, "ilog10 returned an exponent above x");
        if (k < 77) {
            assertGt(10 ** (k + 1), x, "ilog10 returned an exponent below x");
        }
    }

    /// Every decade's three edges, by hand: 10^k−1, 10^k, 10^k+1 for k = 0..77.
    /// `type(uint256).max` (78 digits) is the top of the domain and answers 77.
    function test_EveryDecadeEdgeIsExact() public pure {
        uint256 p = 1;
        for (uint256 k = 0; k <= 77; ++k) {
            assertEq(BPC.ilog10(p), k, "ilog10(10^k) != k");
            if (k > 0) {
                assertEq(BPC.ilog10(p - 1), k - 1, "ilog10(10^k - 1) != k-1");
            }
            if (k < 77) {
                assertEq(BPC.ilog10(p + 1), k, "ilog10(10^k + 1) != k");
            }
            if (k < 77) p *= 10;
        }
        assertEq(BPC.ilog10(0), 0, "ilog10(0) must be 0, not a revert");
        assertEq(BPC.ilog10(type(uint256).max), 77, "ilog10(max) must be 77");
    }

    // ─── depthBucket, at the thresholds and at the clamp ─────────────────────

    /// The bucket is `k` at exactly 10^k × 1e15 and `k−1` one wei below it, for
    /// every k the bucket can report plus the first one it must clamp.
    function test_EachPowerOfTenScaleIsItsOwnBucket() public pure {
        uint256 p = SCALE;
        for (uint256 k = 0; k <= 16; ++k) {
            uint8 want = k > 15 ? 15 : uint8(k);
            assertEq(BPC.depthBucket(p), want, "bucket at 10^k * 1e15");
            if (k > 0) {
                assertEq(BPC.depthBucket(p - 1), uint8(k - 1), "bucket one wei below 10^k * 1e15");
            }
            if (k < 16) p *= 10;
        }
    }

    /// Below the scale every depth is bucket 0, and one wei at the scale is bucket
    /// 0 too — beside a positive control one decade up, so a zero here cannot come
    /// from a dead fixture.
    function test_BelowTheScaleIsBucketZeroBesideADecadeControl() public pure {
        assertEq(BPC.depthBucket(0), 0, "a zero depth is bucket 0");
        assertEq(BPC.depthBucket(SCALE - 1), 0, "one wei below the scale is bucket 0");
        assertEq(BPC.depthBucket(SCALE), 0, "the scale itself is bucket 0");
        assertEq(BPC.depthBucket(10 * SCALE), 1, "one decade up is bucket 1");
    }

    /// The clamp: everything at or above 1e16 × 1e15 is bucket 15, including the
    /// largest uint256.
    function test_TheBucketsClampAtFifteen() public pure {
        assertEq(BPC.depthBucket(1e16 * SCALE), 15, "1e16 scale units must clamp to 15");
        assertEq(BPC.depthBucket(1e31), 15, "1e31 must clamp to 15");
        assertEq(BPC.depthBucket(type(uint256).max), 15, "the largest depth must clamp to 15");
    }

    /// Monotone in depth, fuzzed against the loop oracle — the property a ranking
    /// key must have, and the one an off-by-one threshold breaks pairwise.
    function testFuzz_TheBucketNeverFallsAsDepthRises(uint256 d1, uint256 d2) public pure {
        d1 = _b(d1, 1, 1e40);
        d2 = _b(d2, 1, 1e40);
        (uint256 lo, uint256 hi) = d1 < d2 ? (d1, d2) : (d2, d1);
        uint8 blo = BPC.depthBucket(lo);
        uint8 bhi = BPC.depthBucket(hi);
        assertLe(blo, bhi, "the bucket fell as depth rose");
        uint256 want = lo < SCALE ? 0 : _oracle(lo / SCALE);
        if (want > 15) want = 15;
        assertEq(uint256(blo), want, "bucket != min(15, floor(log10(d/1e15)))");
    }

    /// The bucket decides the psi scale as `1 << b` (Core:2105) — the coupling that
    /// makes the boundary above load-bearing. One control: bucket 0 is weight 1.
    function test_TheBucketIsThePsiScale() public pure {
        assertEq(BPC.bucketWeight(0), 1, "bucket 0 must weigh 1");
        assertEq(BPC.bucketWeight(15), 32_768, "bucket 15 must weigh 32768");
        assertEq(
            BPC.bucketWeight(BPC.depthBucket(1e18)),
            uint256(1) << BPC.depthBucket(1e18),
            "the weight must be exactly one shifted by the bucket"
        );
    }
}
