// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;
// GENERATED for diagnosis (route quality, USDC->DAI 10k): src/BlazePhoenixMath.sol at db3c028 with
// its comments stripped, the library made a contract, the IHubMath interface imported from src,
// three member reads through _venue (same word), and two log calls per band. Every
// other line is the source verbatim: the recorder replays the real select beside this copy
// and logs whether both answer the same.

import {BlazePhoenixCore as BPC, PoolInfo} from "../../src/BlazePhoenixCore.sol";
import {IHubMath} from "../../src/BlazePhoenixMath.sol";
import {console2} from "forge-std/console2.sol";

contract RouteQualityMathTap {
    uint256 private constant PIPS     = 1_000_000;
    uint256 private constant FEE_MASK = 0xFFFFFF;
    uint256 private constant NONE     = type(uint256).max;
    function select(
        uint256[] memory rates, uint256[] memory depths, uint256[] memory balsOut, uint256[] memory fe,
        PoolInfo[] memory cands, address tIn, IHubMath hub, uint256 budget
    ) public view returns (
        uint256 nBand, uint256 n, uint256 sumPsi, uint256[] memory map, uint256[] memory psis
    ) {
        uint256 len = cands.length;
        uint256[] memory orig = new uint256[](len);
        assembly ("memory-safe") { mcopy(add(orig, 0x20), add(cands, 0x20), shl(5, len)) }
        (nBand, n, sumPsi, psis) = _select(rates, depths, balsOut, fe, cands, tIn, hub, budget);
        map = new uint256[](len);
        for (uint256 j; j < len; ) {
            uint256 p;
            assembly ("memory-safe") { p := mload(add(cands, shl(5, add(j, 1)))) }
            uint256 k;
            while (orig[k] != p) { unchecked { ++k; } }
            map[j] = k;
            unchecked { ++j; }
        }
    }
    function _select(
        uint256[] memory rates, uint256[] memory depths, uint256[] memory balsOut, uint256[] memory fe,
        PoolInfo[] memory cands, address tIn, IHubMath hub, uint256 budget
    ) private view returns (uint256 nBand, uint256 n, uint256 sumPsi, uint256[] memory psis) {
        n = cands.length;
        uint256 kept;
        {
            uint256[] memory prices = _prices(rates, fe, n);
            uint256[] memory ord = _byPrice(prices, n);
            uint256 m = ord.length;
            if (m == 0) return (0, 0, 0, psis);
            uint256 base = _depthWeightedMedian(prices, fe, depths, n, cands, tIn, hub, ord);
            if (base == NONE) base = ord[m / 2];
            kept = _inBand(prices, fe, n, base);
            _tapBand(prices, base, kept);
        }
        {
            uint256 nKept;
            for (uint256 i; i < n; ) {
                if (kept & (1 << i) != 0) {
                    if (nKept != i) {
                        cands[nKept]   = cands[i];
                        depths[nKept]  = depths[i];
                        rates[nKept]   = rates[i];
                        balsOut[nKept] = balsOut[i];
                    }
                    unchecked { ++nKept; }
                }
                unchecked { ++i; }
            }
            if (nKept < 2) return (nKept, nKept, 0, psis);
            n = nKept;
        }
        (psis, sumPsi) = _weights(cands, depths, balsOut, n);
        nBand = n;
        if (n > budget) (n, sumPsi) = _cutByWeight(cands, psis, balsOut, rates, budget, n);
        sumPsi = _seatTheSplit(cands, psis, balsOut, rates, n, sumPsi);
    }
    function _seatTheSplit(
        PoolInfo[] memory cands, uint256[] memory w, uint256[] memory bals,
        uint256[] memory rates, uint256 n, uint256 sum
    ) private pure returns (uint256) {
        uint256 cannotPay;
        for (uint256 i; i < n; ) {
            if (bals[i] == 0 && BPC.kindHas(cands[i].kind, BPC.A_CONC_POOL)) cannotPay += w[i];
            unchecked { ++i; }
        }
        if (cannotPay != 0 && cannotPay < sum) {
            for (uint256 i; i < n; ) {
                if (bals[i] == 0 && BPC.kindHas(cands[i].kind, BPC.A_CONC_POOL)) w[i] = 0;
                unchecked { ++i; }
            }
            sum -= cannotPay;
        }
        if (n < 2) return sum;
        uint256 last = n - 1;
        uint256 bi = seatOf(cands, w, n);
        if (bi != last) {
            (cands[bi], cands[last]) = (cands[last], cands[bi]);
            (w[bi], w[last])         = (w[last], w[bi]);
            (bals[bi], bals[last])   = (bals[last], bals[bi]);
            (rates[bi], rates[last]) = (rates[last], rates[bi]);
        }
        return sum;
    }
    function seatOf(PoolInfo[] memory cands, uint256[] memory w, uint256 m) internal pure returns (uint256 bi) {
        uint256 last = m - 1;
        bi = last;
        for (uint256 i; i < last; ) {
            if (w[i] > w[bi] || (w[i] == w[bi] && _venue(cands[i]) < _venue(cands[bi]))) bi = i;
            unchecked { ++i; }
        }
    }
    function _cutByWeight(
        PoolInfo[] memory cands, uint256[] memory psis, uint256[] memory bals,
        uint256[] memory rates, uint256 budget, uint256 n
    ) private pure returns (uint256, uint256) {
        for (uint256 ki; ki < budget; ) {
            uint256 bi = ki;
            for (uint256 j = ki + 1; j < n; ) {
                if (psis[j] > psis[bi] || (psis[j] == psis[bi] && (rates[j] > rates[bi]
                    || (rates[j] == rates[bi] && _venue(cands[j]) < _venue(cands[bi]))))) bi = j;
                unchecked { ++j; }
            }
            if (bi != ki) {
                (cands[ki], cands[bi]) = (cands[bi], cands[ki]);
                (psis[ki], psis[bi])   = (psis[bi], psis[ki]);
                (bals[ki], bals[bi])   = (bals[bi], bals[ki]);
            (rates[ki], rates[bi]) = (rates[bi], rates[ki]);
            }
            unchecked { ++ki; }
        }
        uint256 sumPsi;
        for (uint256 i; i < budget; ) { sumPsi += psis[i]; unchecked { ++i; } }
        return (budget, sumPsi);
    }
    function _heldShare(PoolInfo memory p, uint256 d, address tIn, uint256 bar, IHubMath hub)
        private view returns (uint256)
    {
        address mgr = hub.v4PoolManager();
        bool zfo = p.token0 == tIn;
        (address c0, address c1) = BPC.v4LegCurrencies(p.kind, p.token0, p.token1, true);
        bytes32 pid = BPC.computeV4PoolId(c0, c1, p.fee, p.tickSpacing, p.hooks);
        return BPC.v4HeldShare(mgr, pid, p.tickSpacing, zfo, d, bar);
    }
    function _depthWeightedMedian(
        uint256[] memory prices, uint256[] memory fe, uint256[] memory depths, uint256 n,
        PoolInfo[] memory cands, address tIn, IHubMath hub, uint256[] memory ord
    ) private view returns (uint256 base)
    {
        uint256[] memory w = new uint256[](n);
        uint256 cut;
        uint256 first;
        uint256 mute = _mutedVotes(prices, fe, n, cands, hub);
        for (uint256 pass; ; ) {
            for (uint256 i; i < n; ) {
                uint256 d = depths[i];
                if (pass == 0
                    ? prices[i] > 0 && d > 1 && BPC.kindHas(cands[i].kind, BPC.A_CONC_SING)
                    : pass == 2 && cut & (1 << i) != 0)
                {
                    uint256 h = _heldShare(cands[i], d, tIn, pass == 0 ? type(uint256).max : 0, hub);
                    if (h < d) cut |= 1 << i;
                    d = h;
                }
                w[i] = mute & (1 << i) != 0 ? 0 : d;
                unchecked { ++i; }
            }
            base = _wMedian(w, ord);
            _tapPass(pass, w, base, cut, mute, _inBand(prices, fe, n, base));
            if (pass == 0) {
                if (cut == 0) return base;
                first = base;
            } else if (pass == 1) {
                if (_inBand(prices, fe, n, base) == _inBand(prices, fe, n, first)) return first;
            } else {
                return base;
            }
            unchecked { ++pass; }
        }
    }
    function _mutedVotes(
        uint256[] memory prices, uint256[] memory fe, uint256 n, PoolInfo[] memory cands, IHubMath hub
    ) private view returns (uint256 mute) {
        uint256 voters;
        uint256 blind;
        uint256 stated;
        for (uint256 i; i < n; ) {
            if (prices[i] > 0) {
                if ((fe[i] & FEE_MASK) >= PIPS) blind |= 1 << i;
                else stated |= 1 << i;
                PoolInfo memory p = cands[i];
                if (!p.active && BPC.kindHasAny(p.kind, BPC.A_RESERVES | BPC.A_CONC_POOL)
                    && BPC.decodeTier(hub.getSlot(BPC.pairKey(_venue(p), p.token0, p.token1))) != 0) mute |= 1 << i;
                else voters = 1;
            }
            unchecked { ++i; }
        }
        if (voters == 0) mute = 0;
        if ((stated & ~mute) != 0) mute |= blind;
    }
    function _inBand(uint256[] memory prices, uint256[] memory fe, uint256 n, uint256 b)
        private pure returns (uint256 set)
    {
        if (b >= n) return 0;
        uint256 pb = prices[b];
        uint256 fb = fe[b] & FEE_MASK;
        uint256 kb;
        uint256 up;
        if (fb < PIPS) {
            kb = _keep(fb, fe[b] >> 24);
            up = PIPS - fb;
        }
        for (uint256 i; i < n; ) {
            uint256 p = prices[i];
            if (p > 0) {
                if (fb >= PIPS) set |= 1 << i;
                else {
                    uint256 f = fe[i] & FEE_MASK;
                    uint256 k = _keep(f < PIPS ? f : 0, fe[i] >> 24) * kb / BPC.WAD;
                    if (BPC.mulDiv(p, k * up / PIPS, BPC.WAD) <= pb
                        && (f >= PIPS || p >= BPC.mulDiv(pb, k, BPC.WAD))) set |= 1 << i;
                }
            }
            unchecked { ++i; }
        }
    }
    function _keep(uint256 f, uint256 e) private pure returns (uint256) {
        if (e > BPC.WAD) e = BPC.WAD;
        return (PIPS - f) * 1e12 * (BPC.WAD - e) / BPC.WAD;
    }
    function _prices(uint256[] memory rates, uint256[] memory fe, uint256 n)
        private pure returns (uint256[] memory p)
    {
        p = new uint256[](n);
        for (uint256 i; i < n; ) {
            uint256 r = rates[i];
            uint256 f = fe[i] & FEE_MASK;
            p[i] = f >= PIPS ? r : r > type(uint256).max / PIPS ? type(uint256).max : r * PIPS / (PIPS - f);
            unchecked { ++i; }
        }
    }
    function _byPrice(uint256[] memory prices, uint256 n) private pure returns (uint256[] memory ord) {
        ord = new uint256[](n);
        uint256 m;
        for (uint256 i; i < n; ) {
            uint256 kr = prices[i];
            if (kr > 0) {
                uint256 j = m;
                while (j > 0 && prices[ord[j - 1]] > kr) {
                    ord[j] = ord[j - 1];
                    unchecked { --j; }
                }
                ord[j] = i;
                unchecked { ++m; }
            }
            unchecked { ++i; }
        }
        assembly ("memory-safe") { mstore(ord, m) }
    }
    function _wMedian(uint256[] memory w, uint256[] memory ord) private pure returns (uint256) {
        uint256 m = ord.length;
        uint256 massa;
        for (uint256 i; i < m; ) { massa += w[ord[i]]; unchecked { ++i; } }
        if (m == 0 || massa == 0) return NONE;
        uint256 metade = (massa + 1) / 2;
        uint256 acc;
        for (uint256 i; i < m; ) {
            acc += w[ord[i]];
            if (acc >= metade) return ord[i];
            unchecked { ++i; }
        }
        return ord[m - 1];
    }
    function _weights(
        PoolInfo[] memory cands, uint256[] memory depth, uint256[] memory bals, uint256 n
    ) private pure returns (uint256[] memory psis, uint256 sumPsi) {
        cands; bals;
        psis = new uint256[](n);
        uint256 mx;
        for (uint256 i; i < n; ) {
            if (depth[i] > mx) mx = depth[i];
            unchecked { ++i; }
        }
        for (uint256 i; i < n; ) {
            uint256 w = mx == 0 ? 1 : BPC.mulDiv(depth[i], 10_000, mx);
            if (w == 0) w = 1;
            psis[i] = w;
            sumPsi += w;
            unchecked { ++i; }
        }
    }

    function _venue(PoolInfo memory c) private pure returns (address a) {
        assembly ("memory-safe") { a := mload(add(c, 0xe0)) }
    }

    function _tapPass(uint256 pass, uint256[] memory w, uint256 base, uint256 cut, uint256 mute, uint256 band)
        private pure
    {
        console2.log("RQ tap pass / base / cut bits / mute bits:", pass, base, cut);
        console2.log("RQ tap pass", pass, "mute bits", mute);
        console2.log("RQ tap pass", pass, "band bits around this base", band);
        for (uint256 i; i < w.length; ++i) console2.log("RQ tap   w row / vote:", i, w[i]);
    }

    function _tapBand(uint256[] memory prices, uint256 base, uint256 kept) private pure {
        for (uint256 i; i < prices.length; ++i) console2.log("RQ tap   price row / price:", i, prices[i]);
        console2.log("RQ tap final base / kept bits:", base, kept);
    }
}
