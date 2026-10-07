// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// `depthFromL18` with `sp != 0` and UNEQUAL decimals - a combination no other test
// exercises: DepthUnitParity calls it with sp == 0, ConcentratedMassCap with (18, 18).
// What this pins is the composition `registryDepth18` builds from decimalsOf(t0) and
// decimalsOf(t1) to feed its V4 and V3 arms. The class has history: decimal
// normalisation is where a defect already escaped once (the eighth site cured on
// 2026-08-21).

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixCore as BPC} from "../src/BlazePhoenixCore.sol";

contract DepthFromL18UnequalDecimalsTest is Test {
    uint160 constant Q96 = uint160(uint256(1) << 96);

    /// (18, 6), the USDC/WETH shape: the physically shallow side is chosen AFTER
    /// normalisation, never the side with fewer raw units.
    function test_UnequalDecimals_PicksTheShallowPhysicalSide() public pure {
        // The USDC/WETH pool 0x6c561B44 on Base (DepthBucketDecimals.t.sol).
        uint128 liq = 33_015_326_848_947_965_378;
        uint160 sp  = 3_427_971_880_739_905_985_761_831; // token0 = WETH (18), token1 = USDC (6)

        uint256 x0 = uint256(liq) * uint256(Q96) / uint256(sp); // WETH units
        uint256 x1 = uint256(liq) * uint256(sp) / uint256(Q96); // USDC units
        uint256 rawMin = x0 < x1 ? x0 : x1;                     // the min biased by units

        uint256 d = BPC.depthFromL18(liq, sp, 18, 6);

        // The normalised short side is WETH (~7.6e23); the RAW min would pick USDC (~1.4e15).
        assertGt(d, rawMin * 1_000_000, "the raw min must sit orders of magnitude below");
        assertApproxEqRel(d, BPC.to18(x0, 18), 1e16, "depth must be the normalised WETH side");
        // And the bucket moves, so this is not rounding.
        assertGt(BPC.depthBucket(d), BPC.depthBucket(rawMin), "the bucket must change");
    }

    /// INVARIANT: depth is a PHYSICAL quantity. Relabelling the two sides' decimals
    /// (d0 -> d0 + k, d1 -> d1 - k) with the price compensated (sp -> sp / 10^k) cannot
    /// move it. A normaliser that touches only one side fails here.
    function test_DecimalRelabelingIsDepthInvariant() public pure {
        uint128 liq = 1e20;
        uint160 sp  = uint160(uint256(Q96) * 2); // price 4

        // (6, 18) -> (12, 12), sp divided by 1e6
        uint256 a = BPC.depthFromL18(liq, sp, 6, 18);
        uint256 b = BPC.depthFromL18(liq, uint160(uint256(sp) / 1e6), 12, 12);
        assertApproxEqRel(a, b, 1e12, "relabelling +k does not preserve the depth");

        // (18, 6) -> (12, 12), sp multiplied by 1e6
        uint256 c = BPC.depthFromL18(liq, sp, 18, 6);
        uint256 e = BPC.depthFromL18(liq, uint160(uint256(sp) * 1e6), 12, 12);
        assertApproxEqRel(c, e, 1e12, "relabelling -k does not preserve the depth");
    }
}
