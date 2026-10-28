// SPDX-License-Identifier: BUSL-1.1
// =============================================================================
//  BlazePhoenix Protocol — BlazePhoenixMath
//  Version    : 2.0.0
//  Copyright  : (c) June 2026 – June 2030 BlazePhoenix Protocol
//  License    : Business Source License 1.1 (BUSL-1.1)
//               Change Date    : 2030-06-01
//               Change License : GPL-2.0-or-later
//
//  SINGLE RESPONSIBILITY
//      The arithmetic of one hop's choice: the band (where the market is), the
//      split weights (who deserves the order), the funnel cut and the seat of the
//      remainder (who takes it). It reasons over figures the Solver has already
//      measured, plus the three Hub reads the band's vote needs. Moved out of the
//      Solver unchanged except for its exits and the `hub` argument (D10, owner's
//      decision 2026-10-26), so the Solver keeps room under its size ceiling.
//
//  WHAT THIS LIBRARY GUARANTEES
//      M1  ONE CALL PER HOP. `select` is its only entry point: the Solver
//          delegatecalls it once per hop with two or more candidates, never once
//          per helper or per pool.
//      M2  WRITES NOTHING. Every function is `view` or `pure`. Inside the solve's
//          STATICCALL the delegatecall stays static (EIP-214). With no
//          state-changing function the runtime carries no deploy-address guard,
//          so its codehash is a constant the Solver pins at deploy.
//      M3  THE SAME ANSWER AS BEFORE. The code is the Solver's own, moved verbatim
//          except for its exits and the `hub` argument (a library cannot read the
//          Solver's immutables). The only new code is the map that tells the
//          Solver where each survivor came from. One answer has changed since, on
//          purpose: the band (MED, 2026-10-28) judges each venue's PRICE, and its
//          width is the fees and the quotes' error, not a number of bps.
// =============================================================================
pragma solidity 0.8.36;

import {BlazePhoenixCore as BPC, PoolInfo} from "./BlazePhoenixCore.sol";

/// @notice The three Hub reads the band's vote needs (`_mutedVotes`, `_heldShare`).
interface IHubMath {
    function getSlot(bytes32 key) external view returns (uint256);
    function keyOf(address pool, address tA, address tB) external pure returns (bytes32);
    function v4PoolManager() external view returns (address);
}

library BlazePhoenixMath {

    /// @notice THE BAND (MED, 2026-10-28). After the probe pass the hop's market is the
    ///         depth-weighted median of the venues' PRICES (`_depthWeightedMedian`), and a
    ///         venue stays in the split only where an honest market can put its price beside
    ///         that base's (`_inBand`).
    ///
    ///         WHY A MEDIAN AND NOT THE BEST: the best venue's figure may itself be forged (a
    ///         thin pool with a stale price pretending to offer the world). To move a median an
    ///         attacker has to move more than HALF of the depth mass, not one pool (the history
    ///         of that claim is in `_depthWeightedMedian`).
    ///
    ///         WHY PRICES, NOT RATES. A probe measures the rate AFTER the venue's fee. The band on
    ///         rates (+-5%, MEDIAN_FILTER_BPS until 2026-10-28) read a fee as a price: a pool
    ///         charging 10% at the honest price sat 10% under an honest 0.3% venue, became the
    ///         base with half the mass, and pushed the honest venue out over the top - the user
    ///         paid the 10% (test/MedianFeeCapture.t.sol). The band reads
    ///         p_i = r_i * 1e6 / (1e6 - f_i), f_i the fee the probe itself charged
    ///         (`BPC.universalProbe`).
    ///
    ///         THE WIDTH IS NO-ARBITRAGE, NOT A NUMBER OF BPS (owner's rule). Two honest venues at
    ///         rest leave no round trip to take, so their spots satisfy
    ///         (1-f_i)(1-f*) <= s_i / s* <= 1 / ((1-f_i)(1-f*)); a measured price sits within its
    ///         probe's bound e of its spot, s(1-e) <= p <= s / (1-e). With
    ///         k_i = (1-f_i)(1-f*)(1-e_i)(1-e*), every honest venue at rest has
    ///         k_i <= p_i / p* <= 1 / k_i. The band keeps row i iff
    ///             below:  p_i >= p* * k_i
    ///             above:  p_i * k_i * (1-f*) <= p*        (the base's fee counted twice)
    ///         and both hold for every honest venue at rest: the band never drops one.
    ///
    ///         WHY THE BASE'S FEE TWICE ABOVE. With k_i alone a base holding half the mass does not
    ///         need the honest price: parked on the no-arbitrage edge,
    ///         p* = p_h (1-f_h)(1-f*)(1-e_h)(1-e*), it leaves a round trip of only about e_h + e*
    ///         open, which on a deep book pays no arbitrageur's gas, drops the honest venue h over
    ///         the top, and charges the user 1 - (1-f*)^2 against h (19% at f* = 10%). Counted
    ///         twice, dropping h needs a round trip G between h and the base with
    ///         1 + G > 1 / (1-f*), and the user's loss against h, 1 - (1-f*)^2 / (1+G), stays under
    ///         1 - (1+G)^-3 <= 3G: hurting the user by L leaves at least L/3 open to whoever closes
    ///         it. Below, k_i alone loses nothing: a row dropped there has a measured rate under
    ///         the base's own, r_i < p* (1-f_i)^2 (1-f*)(1-e_i)(1-e*) <= r*.
    ///
    ///         A FEE NOBODY KNOWS (fee >= 1e6: a Gate wrapper). Its price is read as its rate, a
    ///         floor of the truth. Above it is judged with f_i = 0 (its rate already carries its
    ///         fee, so the bound above holds for it as written); below it is never judged. Its
    ///         mass does not vote while a row with a stated fee does (`_mutedVotes`), and a base
    ///         whose fee is unknown states no width: every live row is kept.
    ///
    ///         WHAT THIS COSTS, said where it is decided. (1) The band is as narrow as the fees:
    ///         where the venues charge 0.05%, an honest venue that lags the base by more than the
    ///         round trip is dropped until an arbitrageur closes the gap; the +-5% kept it.
    ///         (2) A venue at a fair price with a large fee is now IN the band, where the +-5% on
    ///         rates left it out. The split weighs by depth; its gate guarantees the best
    ///         surviving leg alone, not the split a narrower band would have made. (3) A fee near
    ///         100% leaves k_i near 0 and passes both edges; such a venue's rate is near 0, and
    ///         the gate weighs rates. (4) Not bounded: the arbitrageur's gas, and the quote shapes
    ///         `BPC.universalProbe` lists as limits.
    uint256 private constant PIPS     = 1_000_000;           // a fee's whole, in pips
    uint256 private constant FEE_MASK = 0xFFFFFF;            // `fe` bits 0-23: the probe's fee
    uint256 private constant NONE     = type(uint256).max;   // `_wMedian`: no row votes

    /// @notice THE ARITHMETIC OF ONE HOP, in one call (D10). It takes the probe pass the
    ///         Solver measured (`rates`, `depths`, `balsOut`, and `fe`, the fee and error bound
    ///         each probe carried, see THE BAND; index-aligned to `cands`) and
    ///         returns what `BlazePhoenixSolver._buildHop` used to compute in place: how many
    ///         candidates the band keeps (`nBand`), how many legs the funnel keeps (`n`), their
    ///         weights (`psis`, `sumPsi`) and `map`, where position i now holds the candidate
    ///         that stood at `map[i]`.
    /// @dev    WHY A MAP. The arrays reach this library as its own ABI copy, so the in-place
    ///         moves below (compaction, funnel cut, seat) never reach the caller's memory. Each
    ///         candidate is a distinct struct in that copy, so its memory address names it. The
    ///         map is read off those addresses after the moves, and the Solver replays it on its
    ///         own arrays: same order, same aliases, to the wei. The second pass of
    ///         `_planViaBridges` reads the permuted `cands` again.
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
            while (orig[k] != p) { unchecked { ++k; } }   // always found: every move copies a pointer already in the list
            map[j] = k;
            unchecked { ++j; }
        }
    }

    /// @dev The Solver's band, compaction, weights, funnel cut and seat (59ecf3f `_buildHop`),
    ///      verbatim except for its exits. Where the Solver returned an empty hop, this returns
    ///      `nBand = 0`. A band of one returns `nBand = 1`, and the Solver quotes the lone
    ///      survivor itself.
    function _select(
        uint256[] memory rates, uint256[] memory depths, uint256[] memory balsOut, uint256[] memory fe,
        PoolInfo[] memory cands, address tIn, IHubMath hub, uint256 budget
    ) private view returns (uint256 nBand, uint256 n, uint256 sumPsi, uint256[] memory psis) {
        n = cands.length;
        // Median + band, scoped so only the band's bitmask survives into the filter
        // (the sort machinery and the anchor die with the block — stack).
        uint256 kept;
        {
            // The band judges PRICES (MED, see THE BAND): each rate with the fee its probe
            // charged put back. The weights, the funnel cut, the seat and the split's gate
            // below still read the RATES, what the user is paid.
            uint256[] memory prices = _prices(rates, fe, n);
            // Median of the non-zero prices. ONE ORDER PER HOP (M11): `ord` lists the
            // live rows (price > 0; dead pools have no opinion on the price) by price,
            // ascending, ties in row order (a stable insertion sort of the indices),
            // so the per-index association in `prices`/`depths` survives for the band
            // filter below. Every weighted median of the hop walks this same order
            // with its own votes (`_wMedian`) instead of sorting the pairs again.
            uint256[] memory ord = _byPrice(prices, n);
            uint256 m = ord.length;
            if (m == 0) return (0, 0, 0, psis);   // all dead: nothing quotable

            // Band base: the CAPITAL ANCHOR when one exists (any candidate
            // holds a non-zero real tokenOut balance); plain median only as
            // fallback (e.g. V4, whose tokens live in the PoolManager
            // singleton, so per-pool balanceOf is 0 and no anchor forms).
            // The anchor is derived here by post-scanning the cached arrays
            // (first max wins, matching the historical in-loop tracker) so the
            // probe loop above carries no scalar accumulators.
            // V3 / BP-18: use the real capital anchor (largest tokenOut balance of
            // a token-custodying candidate — V4 is forced to 0 above, so this can
            // no longer be dust-forged on a pseudo-address) when one exists.
            // Otherwise (a V4-only set) anchor on the DEEPEST candidate by measured
            // liquidity rather than the plain median: a plain median is shifted for
            // FREE by >=5 stale fakes, whereas out-depthing the honest venue costs
            // real capital in the PoolManager. This RAISES the attack cost from free
            // to capital-at-risk; it does NOT make it impossible — active-tick L is
            // cheap to inflate with a one-spacing position, so a fully robust anchor
            // (L discounted by tick width, or a full-size-quote sanity check on the
            // band base) is deferred WITH the V2 tick-cap work.
            // T2 (Thomas): anchor on MEASURED DEPTH, never raw balanceOf. The old
            // capital anchor read balsOut[i] = balanceOf(tokenOut, pool), which a
            // plain donation (transfer to the pool) inflates WITHOUT moving the
            // reserve or price — and the donation is recoverable (V2 skim / V3 LP
            // claim), so it is not "capital at risk". That let an attacker win the
            // anchor with a donation, center the band on their bad rate, and filter
            // the honest deep pool OUT (~75% user loss, preview gamed identically).
            // depths[] is getReserves (V2/Solidly) / getLiquidity (V3), which a
            // donation cannot move; V4 depth is its measured liquidity, capped for
            // the vote by what its book holds (`_heldShare`). Falls back to the
            // median only when no candidate reports depth.
            uint256 base = _depthWeightedMedian(prices, fe, depths, n, cands, tIn, hub, ord);
            // No-vote guard (devil's-advocate): where no live row carries a vote (every
            // live depth 0, or every vote muted to nothing) the weighted median has no row
            // to answer, and the base falls back to the plain median's row, which is live.
            if (base == NONE) base = ord[m / 2];
            kept = _inBand(prices, fe, n, base);   // the band itself: one producer (S2 check too)
        }

        // Band filter reuses the cached probe rates — no second probe quote.
        // Survivors are compacted IN PLACE into cands/depths/balsOut (safe:
        // the write index never overtakes the read index), which keeps the
        // arrays index-aligned for the weight/allocation passes without
        // allocating six shadow arrays — leaner on memory AND on the stack
        // frame (the via-IR inliner folds _weights into this function).
        {
            // Scoped so nKept dies here — the via-IR inliner folds _weights
            // into this function and every surviving stack slot counts.
            uint256 nKept;
            for (uint256 i; i < n; ) {
                if (kept & (1 << i) != 0) {
                    if (nKept != i) {
                        cands[nKept]   = cands[i];
                        depths[nKept]  = depths[i];
                        // `rates` MUST travel with the rest. Until 2026-08-23 this
                        // block compacted cands/depths/balsOut and left rates
                        // behind — from here on `rates[i]` no longer belonged
                        // to `cands[i]`. It did not hurt while nobody read
                        // rates past this point; the split gate's double
                        // fallback started reading, and picked an arbitrary pool.
                        // MEASURED: -2.0% and -2.8% of output.
                        rates[nKept]   = rates[i];
                        balsOut[nKept] = balsOut[i];
                    }
                    unchecked { ++nKept; }
                }
                unchecked { ++i; }
            }
            // 0: no route; 1: the Solver quotes the lone survivor itself (`_singleLeg`).
            if (nKept < 2) return (nKept, nKept, 0, psis);
            n = nKept;
        }

        // =========================================================================
        //  STAGE 2 — DEPTH-WEIGHTED SPLIT (on filtered survivors)
        // =========================================================================
        // Allocate by REAL depth, normalised within each pool KIND. Psi is 1
        // for every never-swapped pool, which splits a trade evenly across a
        // 790-WETH pool and a 0.34-WETH dust pool — destroying ~20% of value
        // (measured for a WETH/USDC pair: 50/50 gave 1302 USDC vs 1638
        // when concentrated in the deep pool). depthWad reflects current
        // capacity, so weighting by it converges on the optimal allocation
        // (depth-weighted gave 1638, matching deep-only).
        //
        // FIXED 2026-08-21. This paragraph claimed that "depthWad is only comparable within
        // a UNIT FAMILY" and described two weighting modes: per-family normalisation, and a
        // fallback to the raw balance when the set crossed families.
        // THE PREMISE FELL with `depthFromL`: the conversion now yields TOKEN-denominated
        // depth in ALL families, and the CI guard says textually that it "must be
        // token-denominated TO BE COMPARABLE ACROSS FAMILIES". The repository had the two
        // opposite statements written at the same time — and it was on the wrong one that the
        // two modes were built.
        // Today there is ONE normalisation, against the GLOBAL maximum — which solves the same
        // problem better (a thin pool of a rare kind compares against ALL, not only against its
        // own family; the measured case was a thin V4 taking ~49% of 25k USDC and costing ~31%
        // vs fair). And the raw-balance fallback vanished with them: it was a `balanceOf` anchor,
        // which the T2 doctrine forbids because a donation inflates it at no cost to the donor.
        (psis, sumPsi) = _weights(cands, depths, balsOut, n);

        // ─── FUNNEL CUT (the funnel is every non-dust row, see Solver._dropDust) ───
        // The funnel probed more venues than the leg budget allows; commit to
        // the top-`budget` survivors by WEIGHT (not discovery order), so a deep
        // late-listed pool displaces thin early-listed ones. Extracted to keep
        // this function's stack shallow.
        // The cut PERMUTES: the survivors it drops stay at [budget, nBand), and the gate below
        // still measures them (see the gate).
        nBand = n;
        if (n > budget) (n, sumPsi) = _cutByWeight(cands, psis, balsOut, rates, budget, n);
        sumPsi = _seatTheSplit(cands, psis, balsOut, rates, n, sumPsi);
    }

    /// @dev WHO TAKES WHAT THE SHARES LEAVE OVER, decided before anything is allocated.
    ///      (1) A concentrated pool that holds none of the output token can pay nothing: the
    ///      capacity clamp would cut its share to zero after the fact, and the input it held
    ///      back had nowhere fair to go. Its weight is zeroed here instead, so the pools that
    ///      can pay split the order exactly as they would without it. A singleton-held pool is
    ///      untouched (its per-pool balance is zero by construction), and if every survivor is
    ///      such a book nothing is zeroed.
    ///      (2) THE REMAINDER IS SEATED BY DEPTH, NOT BY SCORE (INV-7; Seavia Resources, bug
    ///      bounty). The last leg takes the rounding and every wei a clamp frees, so whoever
    ///      sits last is paid more than its weight. The order reaching here is the funnel's,
    ///      which ranks on psi, so the seat is chosen here instead: the deepest survivor by
    ///      measured weight, ties to the lowest address. Swapped in lockstep with the same
    ///      three arrays the funnel cut moves.
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
        uint256 bi = last;
        for (uint256 i; i < last; ) {
            if (w[i] > w[bi] || (w[i] == w[bi] && cands[i].pool < cands[bi].pool)) bi = i;
            unchecked { ++i; }
        }
        if (bi != last) {
            (cands[bi], cands[last]) = (cands[last], cands[bi]);
            (w[bi], w[last])         = (w[last], w[bi]);
            (bals[bi], bals[last])   = (bals[last], bals[bi]);
            (rates[bi], rates[last]) = (rates[last], rates[bi]);
        }
        return sum;
    }

    /// @dev Selection-sort the top-`budget` survivors by weight to the front of
    ///      cands/psis/bals (swapped in lockstep so they stay index-aligned),
    ///      then return the trimmed count and the re-summed weight. Isolated
    ///      from _buildHop so its sort locals do not deepen that stack frame.
    function _cutByWeight(
        PoolInfo[] memory cands, uint256[] memory psis, uint256[] memory bals,
        uint256[] memory rates, uint256 budget, uint256 n
    ) private pure returns (uint256, uint256) {
        for (uint256 ki; ki < budget; ) {
            uint256 bi = ki;
            for (uint256 j = ki + 1; j < n; ) {
                // A weight tie is settled by the pool, never by the index: the index is the
                // psi order the candidates arrived in (INV-7). Better marginal rate first,
                // then the lower address, the same last resort `_seatTheSplit` uses.
                if (psis[j] > psis[bi] || (psis[j] == psis[bi] && (rates[j] > rates[bi]
                    || (rates[j] == rates[bi] && cands[j].pool < cands[bi].pool)))) bi = j;
                unchecked { ++j; }
            }
            if (bi != ki) {
                (cands[ki], cands[bi]) = (cands[bi], cands[ki]);
                (psis[ki], psis[bi])   = (psis[bi], psis[ki]);
                (bals[ki], bals[bi])   = (bals[bi], bals[ki]);
            // In LOCKSTEP with the other three. The funnel PERMUTES (no compaction),
            // so forgetting `rates` here misaligns it as much as forgetting it in
            // the band — and the band edit alone is not enough: verified.
            (rates[ki], rates[bi]) = (rates[bi], rates[ki]);
            }
            unchecked { ++ki; }
        }
        uint256 sumPsi;
        for (uint256 i; i < budget; ) { sumPsi += psis[i]; unchecked { ++i; } }
        return (budget, sumPsi);
    }

    /// @dev THE MASS A SINGLETON BOOK VOTES WITH IS THE SHARE OF ITS DEPTH IT HOLDS. A V4
    ///      depth is `depthFromL18(L, P)`: the virtual reserves of the current L as if it
    ///      spanned every price, which a range of a few ticks declares for a small fraction of
    ///      the tokens. Inside one stretch between initialized ticks the most the book pays is
    ///      its real reserve on the output side (Uniswap v3 whitepaper, 6.2): L*(sqrtP - sqrtPa)
    ///      of token1 going down, L*(1/sqrtP - 1/sqrtPb) of token0 going up, against the
    ///      virtual L*sqrtP and L/sqrtP. `v4WalkOut` with an unbounded input and no fee reaches
    ///      every target, so it returns that real output summed over the stretches it walks
    ///      (`held`), in the same raw unit as the virtual output side (`vOut`). The vote is the
    ///      depth scaled by held/vOut - the depth of a full-range book paying what this one
    ///      holds, so it stays in the unit every other family votes in. It only lowers a vote
    ///      (the walk stops early, never late) and binds where L is narrow; the ratio tends to
    ///      one as the walked stretches cover the book (at tickSpacing 60 the walk spans more
    ///      than 245,000 ticks). The other kinds are already capped by the tokens they hold
    ///      (`_buildHop`), and the allocation keeps `depths` unchanged: the scale is applied to
    ///      the median's own copy (`_depthWeightedMedian`).
    ///      S2: `bar` is the walk's ranking gate - `type(uint256).max` reads the sixteen-stretch
    ///      held (the vote as it always was), `0` the deep one (`_depthWeightedMedian`).
    function _heldShare(PoolInfo memory p, uint256 d, address tIn, uint256 bar, IHubMath hub)
        private view returns (uint256)
    {
        address mgr = hub.v4PoolManager();
        bool zfo = p.token0 == tIn;
        (address c0, address c1) = BPC.v4LegCurrencies(p.kind, p.token0, p.token1, true);
        bytes32 pid = BPC.computeV4PoolId(c0, c1, p.fee, p.tickSpacing, p.hooks);
        return BPC.v4HeldShare(mgr, pid, p.tickSpacing, zfo, d, bar);   // the scale itself: Core, inlined
    }

    /// @dev THE DEPTH-WEIGHTED MEDIAN of the prices (MED). It answers the base of the band as a
    ///      ROW, whose fee and error set the band's width (`_inBand`); NONE when no row votes.
    ///
    ///      WHAT IT REPLACES, AND WHY. The base was the rate of the SINGLE deepest pool
    ///      (`maxDepth`/`depthRate`). In robust statistics that is an estimator with ZERO
    ///      BREAKDOWN POINT: ONE forged sensor — the deepest pool — captures the entire base.
    ///      And the code itself confessed the weakness a few lines from here: "active-tick
    ///      L is cheap to inflate with a one-spacing position... does NOT make it impossible...
    ///      deferred".
    ///      Worse, there was a WRONG FACT WRITTEN DOWN: the band's comment (then on
    ///      `MEDIAN_FILTER_BPS`) justified
    ///      the safety with "to move the median, an attacker has to move more than half the
    ///      pools" — when the base had NOT been the median for a long time.
    ///
    ///      WHAT THIS RESTORES: exactly the property that comment claimed, and with the weights
    ///      that the T2 fix made unforgeable. To capture the base the attacker no longer needs
    ///      to out-depth ONE pool and now needs more than HALF the depth mass of the whole
    ///      set. Breakdown point: 0 -> 50%.
    ///
    ///      WHY SUMMING MASS IS LEGITIMATE: since `depthFromL`, depth is token-denominated in
    ///      ALL families (min(x0,x1) for concentrated, min(r0,r1) for pair), so the sum makes
    ///      sense. This was the premise missing before — and the same one that allowed removing
    ///      the per-family normalization of the weights.
    ///
    ///      DEGENERATES WELL: a pool that alone holds >50% of the mass returns its own row,
    ///      which is the old behaviour — and correct, because then it IS the market. With equal
    ///      weights, it is the plain median.
    ///
    ///      S2 (V4 fragmentation, reported by Seavia Resources): the held vote reads a sixteen-
    ///      stretch walk, and an outsider can cut it with one-wei positions on the ticks in its
    ///      path - the vote drops and the honest book falls out of the band. The cut votes are
    ///      therefore checked against the uncut ones: if the two bands keep the same pools, no
    ///      held figure can change the filter's outcome. Only when they differ is each cut vote
    ///      re-read with the deep walk (`V4_WALK_DEEP_STEPS`) and the median taken again.
    function _depthWeightedMedian(
        uint256[] memory prices, uint256[] memory fe, uint256[] memory depths, uint256 n,
        PoolInfo[] memory cands, address tIn, IHubMath hub, uint256[] memory ord
    ) private view returns (uint256 base)
    {
        uint256[] memory w = new uint256[](n);
        uint256 cut;     // bit i: candidate i's sixteen-stretch vote is under its depth
        uint256 first;   // the median under the sixteen-stretch votes
        uint256 mute = _mutedVotes(prices, fe, n, cands, hub);
        // Pass 0: the sixteen-stretch votes (the vote as it always was). Pass 1: the uncut
        // depths. Pass 2: the cut votes re-read deep. One call site each: the Solver is the
        // contract closest to EIP-170.
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

    /// @dev MASS THAT NOBODY VOUCHES FOR DOES NOT VOTE (bounty #85, Remember Me). Bit i set =
    ///      candidate i is live, pair- or concentrated-shaped, its row was written by whoever
    ///      swapped first (tier != 0) and no registered factory vouches for it (`active`, set in
    ///      `_topKPools`). Its depth is the contract's own word capped by what it holds, and what
    ///      it holds can be a recoverable donation: thirteen million parked on a synthetic pair
    ///      outvoted twelve million of honest mass and moved the band 6 % off fair. Muted, it
    ///      still quotes, still sits in the band if its rate is fair, and still executes; only
    ///      its mass stops choosing the base. V4 rows are not muted: their book lives in the
    ///      PoolManager, whose code nobody swaps. A set where nobody may vote keeps the vote it
    ///      always had (mask 0): a pair with no curated and no factory-born venue is no worse.
    ///      MED (2026-10-28): a row whose fee is unknown (fee >= 1e6, a Gate wrapper) is muted too
    ///      while a row with a stated fee still votes. Its price is read as its rate, under the
    ///      truth by a fee nobody knows, so its mass pulls the median to the cheap side, onto a
    ///      lagging venue that the honest one is then judged against. Where no stated row votes,
    ///      the blind rows keep the vote (and a blind base keeps every row, `_inBand`).
    function _mutedVotes(
        uint256[] memory prices, uint256[] memory fe, uint256 n, PoolInfo[] memory cands, IHubMath hub
    ) private view returns (uint256 mute) {
        uint256 voters;
        uint256 blind;    // bit i: row i is live and its fee is unknown
        uint256 stated;   // bit i: row i is live and its fee is stated
        for (uint256 i; i < n; ) {
            if (prices[i] > 0) {
                if ((fe[i] & FEE_MASK) >= PIPS) blind |= 1 << i;
                else stated |= 1 << i;
                PoolInfo memory p = cands[i];
                if (!p.active && BPC.kindHasAny(p.kind, BPC.A_RESERVES | BPC.A_CONC_POOL)
                    && BPC.decodeTier(hub.getSlot(hub.keyOf(p.pool, p.token0, p.token1))) != 0) mute |= 1 << i;
                else voters = 1;
            }
            unchecked { ++i; }
        }
        if (voters == 0) mute = 0;
        if ((stated & ~mute) != 0) mute |= blind;
    }

    /// @dev THE BAND around row `b`, the base (see THE BAND): bit i set = row i is live and its
    ///      price sits where an honest market at rest can put it beside the base's. `fe[i]` packs
    ///      the fee row i's probe charged, in pips (bits 0-23; 1e6 or more: unknown), and the
    ///      probe's error bound, in WAD (bits 24 up). b >= n (no base) keeps nothing. n < 256: the
    ///      funnel is bounded by the pair's table, sixteen registry slots, the wired rows' cells
    ///      and four wrappers. One producer for the filter in `_select` and for the S2 check
    ///      above. Every product rounds down, which only widens the band: rounding never drops an
    ///      honest row.
    function _inBand(uint256[] memory prices, uint256[] memory fe, uint256 n, uint256 b)
        private pure returns (uint256 set)
    {
        if (b >= n) return 0;
        uint256 pb = prices[b];
        uint256 fb = fe[b] & FEE_MASK;
        uint256 kb;   // (1-f*)(1-e*), WAD
        uint256 up;   // 1-f*, pips: the base's fee once more, above
        if (fb < PIPS) {
            kb = _keep(fb, fe[b] >> 24);
            up = PIPS - fb;
        }
        for (uint256 i; i < n; ) {
            uint256 p = prices[i];
            if (p > 0) {
                if (fb >= PIPS) set |= 1 << i;   // the base states no width: every live row
                else {
                    uint256 f = fe[i] & FEE_MASK;
                    uint256 k = _keep(f < PIPS ? f : 0, fe[i] >> 24) * kb / BPC.WAD;   // k_i
                    if (BPC.mulDiv(p, k * up / PIPS, BPC.WAD) <= pb
                        && (f >= PIPS || p >= BPC.mulDiv(pb, k, BPC.WAD))) set |= 1 << i;
                }
            }
            unchecked { ++i; }
        }
    }

    /// @dev (1 - f)(1 - e) in WAD, rounded down: f a fee in pips under 1e6, e a bound in WAD
    ///      (more than WAD reads as WAD: no bound, nothing kept by it).
    function _keep(uint256 f, uint256 e) private pure returns (uint256) {
        if (e > BPC.WAD) e = BPC.WAD;
        return (PIPS - f) * 1e12 * (BPC.WAD - e) / BPC.WAD;
    }

    /// @dev THE PRICES THE BAND JUDGES (MED): p_i = r_i * 1e6 / (1e6 - f_i), the probe's rate with
    ///      the fee it charged put back; p_i = r_i where that fee is unknown (1e6 or more), a floor
    ///      of the truth. A rate over max / 1e6 saturates at max instead of reverting the solve.
    ///      Dead rows stay 0.
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

    /// @dev The live rows (price > 0) ordered by price, ascending, ties in row order: a stable
    ///      insertion sort of the indices. The hop's one order (`_select`, M11).
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

    /// @dev The weighted median itself: the votes `w`, walked in the hop's order `ord` (live rows
    ///      by price, ties in row order; dead pools excluded, they have no opinion on the price).
    ///      Mass travels with its row: the walk reads row ord[i]'s vote and answers that ROW (its
    ///      price, fee and error make the band); NONE when no row votes.
    function _wMedian(uint256[] memory w, uint256[] memory ord) private pure returns (uint256) {
        uint256 m = ord.length;
        uint256 massa;
        for (uint256 i; i < m; ) { massa += w[ord[i]]; unchecked { ++i; } }
        if (m == 0 || massa == 0) return NONE;
        // Walk up to HALF the mass. `(massa + 1) / 2` instead of `acc * 2 >= massa` so that there
        // is no chance of overflow in the double of a sum of depths.
        uint256 metade = (massa + 1) / 2;
        uint256 acc;
        for (uint256 i; i < m; ) {
            acc += w[ord[i]];
            if (acc >= metade) return ord[i];
            unchecked { ++i; }
        }
        return ord[m - 1];
    }

    /// @dev Allocation weights for the band's survivors, normalized to [1..10000]:
    ///      each pool's MEASURED depth against the LARGEST depth in the set.
    ///
    ///      TWO THINGS WERE REMOVED FROM HERE ON 2026-08-21, and both for the SAME reason.
    ///
    ///      (1) THE CAPITAL MODE. When the set crossed families and all had balance, the weight
    ///          became `balanceOf(tokenOut, pool)`. That was an ANCHOR read from the raw balance
    ///          — exactly what the T2 fix doctrine forbids, written a few lines from here:
    ///          "anchor on MEASURED depth, NEVER on raw balanceOf, because a donation inflates it
    ///          WITHOUT moving the reserve or the price, and the donation is recoverable". T2 was
    ///          applied to the BAND's anchor and not to this weight, which decides the split
    ///          SHARE. This codebase's defect signature: a fix applied to ONE of two channels
    ///          that ask the SAME relative question ("which of these pools deserves more?").
    ///          (NOTE: the capacity cap also reads `balanceOf` and was NOT changed — there the
    ///          question is PHYSICAL, "can it pay this?", and a donation genuinely raises what the
    ///          pool pays. Reading the same quantity does not imply asking the same question.)
    ///
    ///      (2) THE PER-FAMILY NORMALIZATION. It existed because "depthWad is only comparable
    ///          within one family of units". That premise FELL with `depthFromL`: the conversion
    ///          now yields TOKEN-denominated depth in every family, and the CI guard itself
    ///          states verbatim that it "must be token-denominated TO BE COMPARABLE ACROSS
    ///          FAMILIES". The repository held the two opposite statements at the same time.
    ///          With globally comparable depths, normalizing against the GLOBAL maximum is
    ///          strictly more correct — and it solves better the problem the per-family
    ///          normalization solved (a thin pool of a rare kind does not win maximum weight for
    ///          being the only one of its kind: it now compares with ALL, not just its family).
    ///
    ///      What leaves with them: `_famOf`, the `maxByFam` array, the packed `st` predicate and
    ///      the branch. What stays is one normalization, with no modes.
    function _weights(
        PoolInfo[] memory cands, uint256[] memory depth, uint256[] memory bals, uint256 n
    ) private pure returns (uint256[] memory psis, uint256 sumPsi) {
        cands; bals;   // kept in the signature: the caller passes them in lockstep with psis
        psis = new uint256[](n);
        uint256 mx;
        for (uint256 i; i < n; ) {
            if (depth[i] > mx) mx = depth[i];
            unchecked { ++i; }
        }
        for (uint256 i; i < n; ) {
            // `mx == 0` only happens if NO candidate reported depth: then everyone gets weight 1
            // and the split is uniform, the only honest thing to do without a measurement.
            uint256 w = mx == 0 ? 1 : BPC.mulDiv(depth[i], 10_000, mx);
            if (w == 0) w = 1;   // non-zero but tiny depth does not vanish from the split
            psis[i] = w;
            sumPsi += w;
            unchecked { ++i; }
        }
    }
}
