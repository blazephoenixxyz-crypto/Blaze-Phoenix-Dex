// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// THE BAND (`BlazePhoenixMath._inBand`) at the edge of a row's stated fee. A fee of 1e6 pips or
// more is unknown: the row's price is then a floor of the truth (`_prices` puts no fee back), so
// the band judges it from above only, with its own fee read as 0, and never asks the lower edge.
// One pip under, the fee is stated: the row is judged from both sides with its own (1 - f_i).
// Base row 0: price 1e18, fee 3000 pips, e = e_o = 0, so the base keeps (1 - 0.003) on each edge.
// Oracle: the hand arithmetic in each case, not the library.
// Mutants (.github/scripts/mutants.py):
//   «Math:537» `f < PIPS ? f : 0` -> `f <= PIPS ? f : 0` (an unknown fee is kept as stated,
//     the row keeps nothing, so it passes the upper edge at any price) -> red;
//   «Math:539» `f >= PIPS ||` -> `f > PIPS ||` (a fee of exactly 1e6 is asked the lower
//     edge it cannot answer) -> red;
//   «Math:166» the all-dead exit of `_select` dropped (a hop whose rows all read 0 is
//     sorted, based and weighed with no row to read) -> red.

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixMath as BPM, IHubMath} from "../src/BlazePhoenixMath.sol";
import {BlazePhoenixCore as BPC, PoolInfo} from "../src/BlazePhoenixCore.sol";

contract SelectBandEdgesTest is Test {
    uint256 constant PIPS = 1_000_000;
    uint256 constant WAD = 1e18;
    uint256 constant BASE_PRICE = 1e18;
    uint256 constant BASE_FEE = 3000;

    function _band(uint256[] memory prices, uint256[] memory fees) private pure returns (uint256) {
        // e = e_o = 0 on every row: `fe` is the fee alone (bits 0-23)
        return BPM._inBand(prices, fees, prices.length, 0);
    }

    /// Five rows beside the base. r1 (0.6, fee 1e6) sits far under the base, where no stated fee
    /// could reach: kept, the lower edge is not asked. r2 (1.2, fee 1e6) sits over it: the upper
    /// edge reads its fee as 0, 1.2 * 0.997 * 0.997 > 1, out. r3 (1e-7, fee 1e6 - 1) is judged
    /// from below with k_i = 1e-6: it needs 1e18 * 1e-6 * 0.997 = 9.97e11 and has 1e11, out.
    /// r4 (1.2, fee 1e6 - 1) keeps 1e-6 of itself, under the base from above: kept.
    function test_ARowFeeOfExactlyOneMillionPipsIsJudgedFromAboveOnly() public pure {
        uint256[] memory p = new uint256[](5);
        uint256[] memory f = new uint256[](5);
        (p[0], f[0]) = (BASE_PRICE, BASE_FEE);
        (p[1], f[1]) = (6e17, PIPS);
        (p[2], f[2]) = (12e17, PIPS);
        (p[3], f[3]) = (1e11, PIPS - 1);
        (p[4], f[4]) = (12e17, PIPS - 1);
        assertEq(_band(p, f), 1 | 2 | 16, "fee 1e6: above only; fee 1e6 - 1: both edges");
    }

    /// Any unknown fee (1e6 up to the 24-bit field's top), any price: kept iff the price, with the
    /// base's (1 - 0.003)^2 and nothing of its own, does not pass the base. Hand oracle: the base
    /// keeps 997e15 * 997000 / 1e6 = 994009e12 in WAD.
    function testFuzz_AnUnknownFeeRowIsJudgedFromAboveOnly(uint256 price, uint256 fee) public pure {
        price = bound(price, 1, 1e30);
        fee = bound(fee, PIPS, 0xFFFFFF);
        uint256[] memory p = new uint256[](2);
        uint256[] memory f = new uint256[](2);
        (p[0], f[0]) = (BASE_PRICE, BASE_FEE);
        (p[1], f[1]) = (price, fee);
        bool kept = price * 994009e12 / WAD <= BASE_PRICE;
        assertEq(_band(p, f), kept ? 3 : 1, "unknown fee: the upper edge alone decides");
    }

    /// A hop whose rows all read 0 (every probe dead, depth and balance held or not) has nothing
    /// to quote: `select` returns an empty band and an empty hop, it does not revert. One to
    /// three rows, V2 and Solidly, with and without mass.
    function test_AHopWhoseRowsAllReadZeroSelectsNothing() public view {
        for (uint256 len = 1; len <= 3; ++len) {
            for (uint256 massOn; massOn < 2; ++massOn) {
                uint256[] memory rates = new uint256[](len);
                uint256[] memory depths = new uint256[](len);
                uint256[] memory bals = new uint256[](len);
                uint256[] memory fe = new uint256[](len);
                PoolInfo[] memory c = new PoolInfo[](len);
                for (uint256 i; i < len; ++i) {
                    depths[i] = massOn * 1e18;
                    bals[i] = massOn * 1e18;
                    fe[i] = BASE_FEE;
                    c[i] = PoolInfo({
                        active: true, stable: false, kind: i == 2 ? BPC.KIND_SOLIDLY : BPC.KIND_V2,
                        fee: 0, tickSpacing: 0, token0: address(0xA), token1: address(0xB),
                        pool: address(uint160(0x1000 + i)), hooks: address(0)
                    });
                }
                (uint256 nBand, uint256 n, uint256 sumPsi,,) =
                    BPM.select(rates, depths, bals, fe, c, address(0xA), IHubMath(address(0)), 8);
                assertEq(nBand, 0, "no live row: an empty band");
                assertEq(n, 0, "no live row: an empty hop");
                assertEq(sumPsi, 0, "no live row: no weight");
            }
        }
    }
}
