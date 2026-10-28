// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// MED (2026-10-28): THE BAND, read at the library (`BlazePhoenixMath.select`) on rows built by
// hand - what it keeps, given the rates, fees and error bounds the probes hand it. The routes
// that reach it are test/MedianFeeCapture.t.sol; the probe's error bound itself is
// test/MedianProbeErrorBound.t.sol. The derivations are in BlazePhoenixMath, THE BAND: a row's
// price is p = r / (1 - f) (`BlazePhoenixMath._prices`), and the band around the base row b
// keeps row i iff
//     p_i >= p_b * k_i               (from below; not asked where f_i is unknown)
//     p_i * k_i * (1 - f_b) <= p_b   (from above; the base's fee counted twice)
// with k_i = (1 - f_i)(1 - f_b)(1 - e_i)(1 - e_b) and e a probe's error bound.

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixMath, IHubMath} from "../src/BlazePhoenixMath.sol";
import {BlazePhoenixCore as BPC, PoolInfo} from "../src/BlazePhoenixCore.sol";

contract MedianBandMathTest is Test {
    uint256 constant PIPS = 1_000_000;
    uint256 constant WAD = 1e18;
    uint256 constant UNKNOWN = 0xFFFFFF;   // a Gate's fee (BPC.FEE_UNKNOWN)

    struct Row {
        uint256 rate;   // out per in, WAD (the Solver's `rates`)
        uint256 fee;    // pips; UNKNOWN: nobody knows it
        uint256 err;    // the probe's error bound, WAD
        uint256 mass;   // its depth, the vote
        bool blind;     // a Gate wrapper (KIND_EXTERNAL); else a pair (KIND_V2)
    }

    /// The rows `select` keeps (bit i = row i), every row active (vouched: no Hub read).
    function _kept(Row[] memory rows) internal view returns (uint256 set) {
        uint256 n = rows.length;
        uint256[] memory rates = new uint256[](n);
        uint256[] memory depths = new uint256[](n);
        uint256[] memory bals = new uint256[](n);
        uint256[] memory fe = new uint256[](n);
        PoolInfo[] memory c = new PoolInfo[](n);
        for (uint256 i; i < n; ++i) {
            rates[i] = rows[i].rate;
            depths[i] = rows[i].mass;
            bals[i] = rows[i].mass;
            fe[i] = rows[i].fee | rows[i].err << 24;
            c[i] = PoolInfo({
                active: true, stable: false, kind: rows[i].blind ? BPC.KIND_EXTERNAL : BPC.KIND_V2,
                fee: 0, tickSpacing: 0, token0: address(0xA), token1: address(0xB),
                pool: address(uint160(0x1000 + i)), hooks: address(0)
            });
        }
        (uint256 nBand, , , uint256[] memory map, ) =
            BlazePhoenixMath.select(rates, depths, bals, fe, c, address(0xA), IHubMath(address(0)), 8);
        for (uint256 j; j < nBand; ++j) set |= 1 << map[j];
    }

    function _row(uint256 rate, uint256 fee, uint256 err, uint256 mass, bool blind) internal pure returns (Row memory) {
        return Row(rate, fee, err, mass, blind);
    }

    /// The probe's reading of a true price `p` behind fee `f`, short of it by `d` (WAD): the rate,
    /// and an error bound covering `d` and the two floors the reading goes through (the rate's,
    /// worth 1 / (1 - f) of price, and the price's own).
    function _measure(uint256 p, uint256 f, uint256 d) internal pure returns (uint256 r, uint256 e) {
        r = BPC.mulDiv(p * (PIPS - f), WAD - d, PIPS * WAD);
        e = d + WAD * (PIPS / (PIPS - f) + 2) / p + 1;
    }

    // ─── the price, not the rate ────────────────────────────────────────────────────────────

    /// A 10% venue at 0.888 (one percent past the edge of rest, 0.997 * 0.9 = 0.8973) holds two
    /// thirds of the mass beside a 0.3% venue at 1. Both kept. Read on RATES with the same width
    /// the 0.3% venue falls out: 0.997 * 0.8973 * 0.9 = 0.80515 > 0.888 * 0.9 = 0.7992.
    function test_TheBandJudgesThePriceNotTheRate() public view {
        Row[] memory r = new Row[](2);
        r[0] = _row(997e15, 3000, 0, 1e18, false);
        r[1] = _row(7992e14, 100_000, 0, 2e18, false);
        assertEq(_kept(r), 3, "the 0.3% venue fell out beside a 10% base one percent past the edge");
    }

    // ─── an honest market at rest ───────────────────────────────────────────────────────────

    /// [derivado] Two venues the market leaves at rest (no arbitrage between them after both
    /// fees: p_b(1-f_b)(1-f_i) <= p_i <= p_b / ((1-f_b)(1-f_i))), each read short of its price by
    /// at most its own error bound: the band around either keeps the other. `where` puts row i at
    /// the low edge of rest, the high edge, or anywhere between.
    function testFuzz_AnHonestRowAtRestIsKept(
        uint256 pb, uint256 fb, uint256 fi, uint256 db, uint256 di, uint256 pos, uint8 where
    ) public view {
        pb = bound(pb, 1e15, 1e33);
        fb = bound(fb, 0, 990_000);
        fi = bound(fi, 0, 990_000);
        db = bound(db, 0, WAD / 2);
        di = bound(di, 0, WAD / 2);
        uint256 lo = (pb * (PIPS - fb) * (PIPS - fi) + PIPS * PIPS - 1) / (PIPS * PIPS);
        uint256 hi = pb * PIPS * PIPS / ((PIPS - fb) * (PIPS - fi));
        uint256 pi = where % 3 == 0 ? lo : where % 3 == 1 ? hi : lo + pos % (hi - lo + 1);
        (uint256 rb, uint256 eb) = _measure(pb, fb, db);
        (uint256 ri, uint256 ei) = _measure(pi, fi, di);
        Row[] memory r = new Row[](2);
        r[0] = _row(rb, fb, eb, 3e18, false);   // the base: three quarters of the mass
        r[1] = _row(ri, fi, ei, 1e18, false);
        assertEq(_kept(r), 3, "the band dropped a venue the market leaves at rest");
    }

    // ─── what a drop can cost ───────────────────────────────────────────────────────────────

    /// [derivado] Whatever the band drops, the user loses little by it. From below it drops only
    /// a row that pays less than the base. From above, a drop means the base sits past the edge
    /// of rest by G, 1 + G = p_i(1-f_i)(1-f_b) / p_b, with 1 + G > 1 / (1 - f_b), and the loss
    /// of routing at the base's rate, L = 1 - (1-f_b)^2 / (1+G) < 1 - (1+G)^-3 <= 3G: under three
    /// times the margin the base leaves to whoever arbitrages it. `g` sets how far past the edge
    /// the base sits, on either side of row i.
    function testFuzz_ADropCostsTheUserUnderThreeTimesTheArbitrageAtTheBase(
        uint256 pi, uint256 fb, uint256 fi, uint256 eb, uint256 ei, uint256 g, bool above
    ) public view {
        pi = bound(pi, 1e15, 1e24);
        fb = bound(fb, 0, 990_000);
        fi = bound(fi, 0, 990_000);
        eb = bound(eb, 0, WAD / 5);
        ei = bound(ei, 0, WAD / 5);
        g = bound(g, 0, WAD / 2);
        uint256 pb = above
            ? BPC.mulDiv(pi * (PIPS - fi) * (PIPS - fb), WAD, PIPS * PIPS * (WAD + g))
            : BPC.mulDiv(pi * PIPS * PIPS, WAD + g, (PIPS - fi) * (PIPS - fb) * WAD);
        uint256 rb = pb * (PIPS - fb) / PIPS;
        uint256 ri = pi * (PIPS - fi) / PIPS;
        Row[] memory r = new Row[](2);
        r[0] = _row(rb, fb, eb, 3e18, false);
        r[1] = _row(ri, fi, ei, 1e18, false);
        uint256 set = _kept(r);
        assertTrue(set & 1 != 0, "the base fell out of its own band");
        if (set & 2 != 0) return;
        // The prices the band judged.
        uint256 qb = rb * PIPS / (PIPS - fb);
        uint256 qi = ri * PIPS / (PIPS - fi);
        if (qi <= qb) {
            assertLt(ri, rb, "dropped from below a venue that pays more than the base");
            return;
        }
        uint256 bi = qi * (PIPS - fi);   // row i's rate as the band read it, x 1e6
        uint256 ab = qb * (PIPS - fb);   // the base's, x 1e6
        // (i) 1 + G > 1 / (1 - f_b):  bi (1e6 - f_b)^2 > qb 1e18.
        assertGt(bi * (PIPS - fb) * (PIPS - fb), qb * PIPS * PIPS * PIPS, "dropped from above inside the edge plus the base's fee");
        // (ii) L < 3G:  (bi - ab) qb 1e12 < 3 bi (bi (1e6 - f_b) - qb 1e12).
        if (bi > ab) {
            assertLt((bi - ab) * qb * PIPS * PIPS, 3 * bi * (bi * (PIPS - fb) - qb * PIPS * PIPS), "the drop cost the user 3G or more");
        }
    }

    /// The non-empty case of the bound: a 0.3% base 20% past the edge drops the 0.3% venue above
    /// it (G = 20%, L = 1 - 0.997^2 / 1.2 = 17.2% < 3G). The band costs a lagging venue its seat
    /// (THE BAND, cost (1)); the bound says what that can cost.
    function test_ABaseFarPastTheEdgeDropsTheRowAbove() public view {
        uint256 pb = uint256(997e15) * 997 / 1200;   // the base's price, 0.997^2 / 1.2, WAD
        Row[] memory r = new Row[](2);
        r[0] = _row(pb * 997 / 1000, 3000, 0, 3e18, false);
        r[1] = _row(997e15, 3000, 0, 1e18, false);
        assertEq(_kept(r), 1, "a base 20% past the edge kept the venue above it");
    }

    // ─── a fee nobody knows ─────────────────────────────────────────────────────────────────

    /// A Gate row's price is read as its rate (its fee is unknown), under the truth, so its mass
    /// would pull the base to the cheap side. While a stated row votes, it does not: the base is
    /// the 0.3% venues', the junk row at half the price falls out, the Gate row stays.
    /// Mutant [974] (the blind rows keep their vote): the Gate takes the base, a blind base keeps
    /// every row, and the junk row stays in.
    function test_ABlindRowDoesNotVoteWhileAStatedRowDoes() public view {
        Row[] memory r = new Row[](4);
        r[0] = _row(997e15, 3000, 0, 1e18, false);
        r[1] = _row(997e15, 3000, 0, 1e18, false);
        r[2] = _row(4985e14, 3000, 0, 1e17, false);   // price 0.5
        r[3] = _row(95e16, UNKNOWN, 0, 3e18, true);
        assertEq(_kept(r), 1 | 2 | 8, "the band around the stated base");
    }

    /// The band asks a Gate row nothing from below (its rate may be a fair price behind a large
    /// fee), and from above it asks the rate itself: what it pays may not exceed what the base
    /// sells for after the base's fee, whatever the Gate's own fee. A Gate row paying 0.6 stays;
    /// one paying 1.2 beside a base at 1 falls out.
    function test_AGateRowIsJudgedFromAboveOnly() public view {
        Row[] memory r = new Row[](3);
        r[0] = _row(997e15, 3000, 0, 3e18, false);
        r[1] = _row(6e17, UNKNOWN, 0, 1e18, true);
        r[2] = _row(12e17, UNKNOWN, 0, 1e18, true);
        assertEq(_kept(r), 1 | 2, "a Gate row judged from below, or not from above");
    }

    /// Where no stated row votes the blind rows choose the base, and a base whose fee nobody
    /// knows states no width: every live row stays (the dead one does not), and the split's gate
    /// decides by what each pays. Fail-open, written down (THE BAND, "a fee nobody knows").
    function test_ABlindBaseKeepsEveryLiveRow() public view {
        Row[] memory r = new Row[](4);
        r[0] = _row(1e18, UNKNOWN, 0, 1e18, true);
        r[1] = _row(9e17, UNKNOWN, 0, 1e18, true);
        r[2] = _row(5e17, UNKNOWN, 0, 1e18, true);
        r[3] = _row(0, UNKNOWN, 0, 1e18, true);
        assertEq(_kept(r), 1 | 2 | 4, "a blind base judged the rows on a width it does not have");
    }
}
