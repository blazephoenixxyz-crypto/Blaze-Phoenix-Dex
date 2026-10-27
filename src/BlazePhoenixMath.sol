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
//          Solver where each survivor came from.
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

    /// @notice Band filter for the split allocation. After quoting each candidate, the market
    ///         baseline is computed and pools whose rate departs from it by more than
    ///         MEDIAN_FILTER_BPS are excluded.
    ///
    ///         WHY A MEDIAN AND NOT THE BEST: the best pool's rate may itself be
    ///         manipulated (a low-liquidity pool with a stale price pretending to offer the
    ///         world). To move a median, an attacker has to move more than HALF — and one
    ///         pool is not enough.
    ///
    ///         CORRECTION NOTE (2026-08-21). This paragraph said exactly this and had been FALSE
    ///         for a long time: the baseline had become the rate of the SINGLE deepest pool, an
    ///         estimator with a ZERO BREAKDOWN POINT — one forged sensor captured it whole. The
    ///         written justification and the real estimator had diverged, and the most reassuring
    ///         prose was the one describing the defence that no longer existed.
    ///         Today the baseline is the DEPTH-WEIGHTED MEDIAN (see `_depthWeightedMedian`),
    ///         which restores the property this paragraph claims — and improves it: the majority is
    ///         counted in DEPTH MASS and not in pool count, so not even half a dozen dust
    ///         pools get a vote. Breakdown point: 0 -> 50% of the mass.
    ///
    ///         BAND OF 500 bps (±5%) — owner's decision, 2026-08-21, widened from 400.
    ///         The goal is not to EXCLUDE a genuinely better pool: the band is symmetric, so
    ///         widening admits both those up to 5% above the baseline and those 5% below.
    ///         It stays tight enough for what it was made for: Solidly-stable curves on
    ///         LST/WETH pairs typically land 20-40% out, and those are still excluded.
    ///
    ///         WHAT THIS COSTS, said where it is decided: a 5% worse pool also gets in, and since
    ///         the weights are by DEPTH, a deep pool that is 5% worse can take a large share.
    ///         If one day only the good side is wanted, the band must stop being symmetric — and
    ///         that is a change of PREDICATE and not of number, so it is not done by shortcut.
    uint16  internal constant MEDIAN_FILTER_BPS    = 500;   // ±5% (owner's decision, 2026-08-21)

    /// @notice THE ARITHMETIC OF ONE HOP, in one call (D10). It takes the probe pass the
    ///         Solver measured (`rates`, `depths`, `balsOut`, index-aligned to `cands`) and
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
        uint256[] memory rates, uint256[] memory depths, uint256[] memory balsOut,
        PoolInfo[] memory cands, address tIn, IHubMath hub, uint256 budget
    ) public view returns (
        uint256 nBand, uint256 n, uint256 sumPsi, uint256[] memory map, uint256[] memory psis
    ) {
        uint256 len = cands.length;
        uint256[] memory orig = new uint256[](len);
        assembly ("memory-safe") { mcopy(add(orig, 0x20), add(cands, 0x20), shl(5, len)) }
        (nBand, n, sumPsi, psis) = _select(rates, depths, balsOut, cands, tIn, hub, budget);
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
        uint256[] memory rates, uint256[] memory depths, uint256[] memory balsOut,
        PoolInfo[] memory cands, address tIn, IHubMath hub, uint256 budget
    ) private view returns (uint256 nBand, uint256 n, uint256 sumPsi, uint256[] memory psis) {
        n = cands.length;
        // Median + band, scoped so only the band's bitmask survives into the filter
        // (the sort machinery and the anchor die with the block — stack).
        uint256 kept;
        {
            // Median of the non-zero rates. We sort a COPY of `rates` (insertion
            // sort — n ≤ 8 so cost is negligible) so the per-index association in
            // `rates`/`depths` survives for the band filter below. Zero entries
            // (dead pools) bubble to the bottom of the copy and are skipped.
            uint256[] memory sortedRates = new uint256[](n);
            for (uint256 i; i < n; ) { sortedRates[i] = rates[i]; unchecked { ++i; } }
            for (uint256 i = 1; i < n; ) {
                uint256 key = sortedRates[i];
                uint256 j = i;
                while (j > 0 && sortedRates[j - 1] > key) {
                    sortedRates[j] = sortedRates[j - 1];
                    unchecked { --j; }
                }
                sortedRates[j] = key;
                unchecked { ++i; }
            }
            // sortedRates is now ascending; zeros (dead pools) sit at the
            // front. Count them here — all-zero means nothing quotable.
            uint256 firstNonZero;
            while (firstNonZero < n && sortedRates[firstNonZero] == 0) {
                unchecked { ++firstNonZero; }
            }
            if (firstNonZero == n) return (0, 0, 0, psis);
            uint256 medianIdx = firstNonZero + ((n - firstNonZero) / 2);
            if (medianIdx >= n) medianIdx = n - 1;  // guard: never index past end
            uint256 median = sortedRates[medianIdx];
            if (median == 0) return (0, 0, 0, psis);

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
            uint256 base = _depthWeightedMedian(rates, depths, n, cands, tIn, hub);
            // Zero-base guard (devil's-advocate): a live candidate can have
            // rates[i]==0 (mulDiv floor on a tiny raw price) yet depths[i]>=1, so a
            // depth/capital anchor could set base=0 and collapse the band to
            // hi=lo=0, killing an otherwise routable hop. median is guaranteed
            // non-zero here (the median==0 early-return above), so fall back to it.
            if (base == 0) base = median;
            kept = _inBand(rates, n, base);   // the band itself: one producer (S2 check too)
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

        // ─── FUNNEL CUT (see MAX_CANDIDATES) ───
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
        return BPC.v4HeldShare(mgr, pid, p.tickSpacing, zfo, d, bar);   // the scale itself: Core (size)
    }

    /// @dev THE DEPTH-WEIGHTED MEDIAN of the rates. It is the base of the band.
    ///
    ///      WHAT IT REPLACES, AND WHY. The base was the rate of the SINGLE deepest pool
    ///      (`maxDepth`/`depthRate`). In robust statistics that is an estimator with ZERO
    ///      BREAKDOWN POINT: ONE forged sensor — the deepest pool — captures the entire base.
    ///      And the code itself confessed the weakness a few lines from here: "active-tick
    ///      L is cheap to inflate with a one-spacing position... does NOT make it impossible...
    ///      deferred".
    ///      Worse, there was a WRONG FACT WRITTEN DOWN: the `MEDIAN_FILTER_BPS` comment justified
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
    ///      DEGENERATES WELL: a pool that alone holds >50% of the mass returns its own rate,
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
        uint256[] memory rates, uint256[] memory depths, uint256 n, PoolInfo[] memory cands, address tIn,
        IHubMath hub
    ) private view returns (uint256 base)
    {
        uint256[] memory w = new uint256[](n);
        uint256 cut;     // bit i: candidate i's sixteen-stretch vote is under its depth
        uint256 first;   // the median under the sixteen-stretch votes
        uint256 mute = _mutedVotes(rates, n, cands, hub);
        // Pass 0: the sixteen-stretch votes (the vote as it always was). Pass 1: the uncut
        // depths. Pass 2: the cut votes re-read deep. One call site each: the Solver is the
        // contract closest to EIP-170.
        for (uint256 pass; ; ) {
            for (uint256 i; i < n; ) {
                uint256 d = depths[i];
                if (pass == 0
                    ? rates[i] > 0 && d > 1 && BPC.kindHas(cands[i].kind, BPC.A_CONC_SING)
                    : pass == 2 && cut & (1 << i) != 0)
                {
                    uint256 h = _heldShare(cands[i], d, tIn, pass == 0 ? type(uint256).max : 0, hub);
                    if (h < d) cut |= 1 << i;
                    d = h;
                }
                w[i] = mute & (1 << i) != 0 ? 0 : d;
                unchecked { ++i; }
            }
            base = _wMedian(rates, w, n);
            if (pass == 0) {
                if (cut == 0) return base;
                first = base;
            } else if (pass == 1) {
                if (_inBand(rates, n, base) == _inBand(rates, n, first)) return first;
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
    function _mutedVotes(uint256[] memory rates, uint256 n, PoolInfo[] memory cands, IHubMath hub)
        private view returns (uint256 mute)
    {
        uint256 voters;
        for (uint256 i; i < n; ) {
            if (rates[i] > 0) {
                PoolInfo memory p = cands[i];
                if (!p.active && BPC.kindHasAny(p.kind, BPC.A_RESERVES | BPC.A_CONC_POOL)
                    && BPC.decodeTier(hub.getSlot(hub.keyOf(p.pool, p.token0, p.token1))) != 0) mute |= 1 << i;
                else voters = 1;
            }
            unchecked { ++i; }
        }
        if (voters == 0) mute = 0;
    }

    /// @dev The band around `base` (+-MEDIAN_FILTER_BPS): bit i set = candidate i's rate is live
    ///      and inside it (n <= MAX_CANDIDATES = 8). One producer for the filter in `_select`
    ///      and for the S2 check above.
    function _inBand(uint256[] memory rates, uint256 n, uint256 base) private pure returns (uint256 set) {
        uint256 hi = BPC.mulDiv(base, BPC.BPS + MEDIAN_FILTER_BPS, BPC.BPS);
        uint256 lo = BPC.mulDiv(base, BPC.BPS - MEDIAN_FILTER_BPS, BPC.BPS);
        for (uint256 i; i < n; ) {
            uint256 r = rates[i];
            if (r > 0 && r >= lo && r <= hi) set |= 1 << i;
            unchecked { ++i; }
        }
    }

    /// @dev The weighted median itself: rates with their votes `w`, dead pools excluded.
    function _wMedian(uint256[] memory rates, uint256[] memory w, uint256 n) private pure returns (uint256) {
        uint256[] memory r = new uint256[](n);
        uint256[] memory d = new uint256[](n);
        uint256 m;
        uint256 massa;
        for (uint256 i; i < n; ) {
            // Dead pools (rate 0) do not vote: they have no opinion on the price.
            if (rates[i] > 0) {
                r[m] = rates[i];
                d[m] = w[i];
                massa += w[i];
                unchecked { ++m; }
            }
            unchecked { ++i; }
        }
        if (m == 0 || massa == 0) return 0;
        // Insertion sort of the PAIRS by rate — n <= 8, negligible cost. Sorting the pairs is what
        // sets this apart from sorting rates alone: mass has to travel with its rate.
        for (uint256 i = 1; i < m; ) {
            uint256 kr = r[i];
            uint256 kd = d[i];
            uint256 j = i;
            while (j > 0 && r[j - 1] > kr) {
                r[j] = r[j - 1];
                d[j] = d[j - 1];
                unchecked { --j; }
            }
            r[j] = kr;
            d[j] = kd;
            unchecked { ++i; }
        }
        // Walk up to HALF the mass. `(massa + 1) / 2` instead of `acc * 2 >= massa` so that there
        // is no chance of overflow in the double of a sum of depths.
        uint256 metade = (massa + 1) / 2;
        uint256 acc;
        for (uint256 i; i < m; ) {
            acc += d[i];
            if (acc >= metade) return r[i];
            unchecked { ++i; }
        }
        return r[m - 1];
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
