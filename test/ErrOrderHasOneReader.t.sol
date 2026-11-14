// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// ROUTEQ: `BPC.universalProbe` returns errOrder, the bound at the hop's size, WITHOUT a clamp at
// WAD. It needs none because the system reads min(errOrder, WAD): the Solver packs errOrder into
// `fe` bits 88 up, the one reader of those bits is `Math._inBand`'s `kbLo = _keep(fb, fe[b] >> 88)`
// (pinned by .github/scripts/err_order_reader_guard.py), and `_keep` reads a bound past WAD as WAD.
// A value past 2^168 is cut by the packing, but only on a base whose rate is zero, where the lower
// edge `p >= pb * k` holds for every k. These are the two properties the deleted clamp leaned on,
// tested on the live library over the whole uint256 range.
// Mutant: `_keep` without `if (e > BPC.WAD) e = BPC.WAD;` -> red (underflow past WAD, and the
// band no longer equals the band of the clamped words).

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixMath} from "../src/BlazePhoenixMath.sol";

contract ErrOrderHasOneReaderTest is Test {
    uint256 constant PIPS = 1_000_000;
    uint256 constant WAD = 1e18;
    uint256 constant LOW88 = (uint256(1) << 88) - 1;

    function _min(uint256 e) private pure returns (uint256) {
        return e > WAD ? WAD : e;
    }

    // The edges of the range the deleted clamp guarded, and past the packing's 168 bits.
    function _edges() private pure returns (uint256[8] memory e) {
        e = [uint256(0), 1, WAD - 1, WAD, WAD + 1, uint256(1) << 168, (uint256(1) << 168) + 1, type(uint256).max];
    }

    /// `_keep(f, e) == _keep(f, min(e, WAD))` at the edges, and nothing kept from WAD on.
    function test_Keep_ReadsABoundPastWadAsWad_AtTheEdges() public pure {
        uint256[8] memory e = _edges();
        uint24[4] memory fs = [uint24(0), 1, 3000, uint24(PIPS - 1)];
        for (uint256 j; j < fs.length; ++j) {
            for (uint256 k; k < e.length; ++k) {
                uint256 got = BlazePhoenixMath._keep(fs[j], e[k]);
                assertEq(got, BlazePhoenixMath._keep(fs[j], _min(e[k])), "keep(f, e) == keep(f, min(e, WAD))");
                // hand oracle: (1 - f)(1 - e) in WAD, rounded down; zero once e reaches WAD
                uint256 want = e[k] >= WAD ? 0 : (PIPS - fs[j]) * 1e12 * (WAD - e[k]) / WAD;
                assertEq(got, want, "keep at the edge");
            }
        }
    }

    /// The same property over the whole range of e and every stated fee.
    function testFuzz_Keep_ReadsABoundPastWadAsWad(uint256 f, uint256 e) public pure {
        f = bound(f, 0, PIPS - 1);
        uint256 got = BlazePhoenixMath._keep(f, e);
        assertEq(got, BlazePhoenixMath._keep(f, _min(e)), "keep(f, e) == keep(f, min(e, WAD))");
        if (e >= WAD) assertEq(got, 0, "a bound of WAD or more keeps nothing");
        assertLe(got, (PIPS - f) * 1e12, "keep never exceeds 1 - f");
    }

    function _rows(uint256[4] memory p, uint256[4] memory w) private pure
        returns (uint256[] memory prices, uint256[] memory fe)
    {
        prices = new uint256[](4);
        fe = new uint256[](4);
        for (uint256 i; i < 4; ++i) {
            prices[i] = p[i];
            fe[i] = w[i];
        }
    }

    /// The band of the raw words equals the band with every row's bits 88 up replaced by
    /// min(eo, WAD): the reader sees only the clamped bound. Any fee, bound, price and base.
    function testFuzz_InBand_SameBandAsTheClampedOrderBound(uint256[4] memory p, uint256[4] memory w, uint256 b)
        public pure
    {
        b = bound(b, 0, 4);   // 4 = no base: keeps nothing
        (uint256[] memory prices, uint256[] memory fe) = _rows(p, w);
        uint256 raw = BlazePhoenixMath._inBand(prices, fe, 4, b);
        for (uint256 i; i < 4; ++i) fe[i] = (fe[i] & LOW88) | _min(fe[i] >> 88) << 88;
        assertEq(raw, BlazePhoenixMath._inBand(prices, fe, 4, b), "band(raw eo) == band(min(eo, WAD))");
    }

    /// The edges of eo on the base, each against the clamped word.
    function test_InBand_SameBandAsTheClampedOrderBound_AtTheEdges() public pure {
        uint256[8] memory e = _edges();
        // a base at 1.0 with a 0.3 % fee and a 1 % bound; rows below, at and above it
        uint256[4] memory p = [uint256(0.5e18), 0.98e18, 1e18, 1.002e18];
        for (uint256 k; k < e.length; ++k) {
            uint256 eo = e[k] << 88 >> 88;   // what the Solver's packing keeps of it
            uint256 base = 3000 | uint256(0.01e18) << 24;
            uint256[4] memory w = [base, base, base | eo << 88, base];
            (uint256[] memory prices, uint256[] memory fe) = _rows(p, w);
            uint256 raw = BlazePhoenixMath._inBand(prices, fe, 4, 2);
            fe[2] = base | _min(eo) << 88;
            assertEq(raw, BlazePhoenixMath._inBand(prices, fe, 4, 2), "edge: band(raw eo) == band(min(eo, WAD))");
        }
    }

    /// A base whose rate is zero: the lower edge holds for every row, so the base's bits 88 up
    /// (whatever the packing cut them to) never change the band.
    function testFuzz_InBand_ABaseWithoutAPriceIgnoresItsOrderBound(
        uint256[4] memory p, uint256[4] memory w, uint256 b, uint256 other
    ) public pure {
        b = bound(b, 0, 3);
        p[b] = 0;
        (uint256[] memory prices, uint256[] memory fe) = _rows(p, w);
        uint256 raw = BlazePhoenixMath._inBand(prices, fe, 4, b);
        fe[b] = (fe[b] & LOW88) | (other << 88);
        assertEq(raw, BlazePhoenixMath._inBand(prices, fe, 4, b), "pb = 0: eo is never read");
    }
}
