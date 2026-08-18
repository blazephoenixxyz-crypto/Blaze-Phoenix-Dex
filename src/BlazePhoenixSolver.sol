// SPDX-License-Identifier: BUSL-1.1
// =============================================================================
//  BlazePhoenix Protocol — BlazePhoenixSolver
//  Version    : 2.0.0
//  Copyright  : (c) June 2026 – June 2030 BlazePhoenix Protocol
//  License    : Business Source License 1.1 (BUSL-1.1)
//               Change Date    : 2030-06-01
//               Change License : GPL-2.0-or-later
//
//  The Solver selects the output-maximising route for an exact-input swap.
//  For each candidate route it computes the total output, discards routes
//  whose net receive falls below the output floor (driven by impact, leg
//  count and sigma), and returns the best feasible route. Within a hop the
//  input is split across pools weighted by their depth (fitness score), so
//  deeper pools take a larger share.
//
//  Topology choice is exhaustive over three candidates:
//
//      a)  direct        : tIn → tOut, one hop, up to MAX_LEGS=5 splits
//      b)  via bridge[0] : tIn → bridge[0] → tOut, 5 legs total
//      c)  via bridge[1] : tIn → bridge[1] → tOut, 5 legs total
//
//  Bridges are the connective tokens of the liquidity graph: exotic-to-exotic
//  swaps usually route through a bridge because that is where depth lives.
//  The Solver evaluates all three topologies and returns the best plus the
//  runner-up as `fallbackRoute`.
//
//  Budget: MAX_LEGS = 5 globally. Bridge routes split it between the two
//  stages dynamically (typically 3 legs to the bridge, 2 from it).
// =============================================================================
pragma solidity 0.8.36;

import {
    BlazePhoenixCore as BPC,
    PoolInfo, Route, Hop, Leg, RoutePlan, QuoteCtx
} from "./BlazePhoenixCore.sol";

interface IHubR {
    function getActivePools(address tA, address tB) external view returns (PoolInfo[] memory);
    function discoverFor(address tA, address tB) external view returns (PoolInfo[] memory);
    function getPsi(bytes32 key) external view returns (uint256);
    function psisOf(address[] calldata pools, address[] calldata tAs, address[] calldata tBs)
        external view returns (uint256[] memory);
    function getSlot(bytes32 key) external view returns (uint256);
    function keyOf(address pool, address tA, address tB) external pure returns (bytes32);
    function bridge(uint8 i) external view returns (address);
    function bridgeCount() external view returns (uint8);
    function isBridgeToken(address t) external view returns (bool);
    function v4PoolManager() external view returns (address);
    function v4EntryCount() external view returns (uint256);
}

contract BlazePhoenixSolver {

    string  public constant VERSION                = "2.0.0";

    /// @notice Maximum legs across the entire route, regardless of topology.
    uint8   internal constant MAX_LEGS             = 5;

    /// @notice Stage-A budget for bridge routes.  Stage B gets MAX_LEGS - A_used.
    uint8   internal constant MAX_LEGS_PER_STAGE   = 3;

    /// @notice Candidates PROBED from the Hub per pair. Deliberately wider
    ///         than the leg budget (MAX_LEGS): the probe funnel sees more
    ///         venues than it will use, and the weight-ranked cut down to the
    ///         leg budget happens AFTER the marginal-rate probe and capital
    ///         anchor — so a deep pool listed behind several thin equal-psi
    ///         venues (e.g. a Solidly stable pool sitting behind four V3 fee
    ///         tiers in discovery order) is seen, weighted, and can displace
    ///         them instead of being starved out by list order.
    uint8   internal constant MAX_CANDIDATES       = 8;

    /// @notice Skip the full CREATE2 discovery sweep when the pair already has at
    ///         least this many registered venues active within DISCOVERY_TTL_SECONDS.
    uint8   internal constant MIN_FRESH_VENUES     = 3;

    /// @notice Re-discovery freshness window in WALL-CLOCK SECONDS. Fully chain-
    ///         agnostic and uniform: `block.timestamp` means the same real time on
    ///         every chain, so no per-chain (block-cadence) calibration is needed.
    ///         It is a GAS/COVERAGE knob, never a safety parameter — the on-chain
    ///         floor protects every fill regardless of how stale the registry is.
    uint256 internal constant DISCOVERY_TTL_SECONDS = 3_600; // ~1 hour, every chain

    /// @notice Per-leg conservatism BPS for routes with ≥3 legs.
    uint16  internal constant LEG_SAFETY_BPS       = 5;

    /// @notice A split is accepted only if it beats the single-best leg's
    ///         full-size quote by at least this margin. Each extra leg costs
    ///         real execution gas (~30k measured), and the allocator otherwise
    ///         contains no gas term at all — this bps threshold is the honest,
    ///         oracle-free proxy for that cost (comparing gas in the native
    ///         token against output in tokenOut would need a price, and the
    ///         protocol is deliberately oracle-free). Planning-view only:
    ///         execution floors and userMinOut are untouched.
    uint16  internal constant MIN_SPLIT_IMPROVEMENT_BPS = 20;

    /// @notice Capacity clamp for concentrated (single-tick-quoted) legs, in
    ///         BPS of the pool's REAL tokenOut balance. The single-tick V3 /
    ///         Algebra formula models the current liquidity as if it spanned
    ///         every price, so on a thin pool it can promise far more tokenOut
    ///         than the pool has ever held (observed 117x on a thin USDC/DAI
    ///         V3 pool: 494k quoted from a pool whose whole book paid 4.2k).
    ///         A pool cannot pay out what it does not hold: the attested
    ///         quote is clamped to this fraction of the pool's measured
    ///         tokenOut balance — the same unforgeable capital signal as the
    ///         anchor filter, extended from filtering to capacity. Reserve-
    ///         bounded formulas (V2 / Solidly / Curve ask-the-pool) cannot
    ///         over-promise and are untouched; a zero balance (V4 singleton
    ///         accounting) skips the clamp.
    ///
    ///         Two-tier: when the quote exceeds the pool's WHOLE holdings the
    ///         promise is physically impossible, and the clamp binds CAPITAL,
    ///         not just the promise — the leg's committed input is cut in the
    ///         same ratio, the freed input cascades to the remaining legs, and
    ///         anything no venue can absorb stays unrouted (the Router sweeps
    ///         it back to the caller). Promise-only clamping left the full
    ///         share walking a thin pool's tick ladder at a collapsing
    ///         marginal price, invisibly to the floors because they derive
    ///         from the already-crushed promise. When the fill is aggressive
    ///         but possible (cap < quote <= holdings) only the promise is
    ///         capped — cutting capital there forced partial fills on pools
    ///         that execute fine (measured: a 43bps full fill halved).
    uint16  internal constant MAX_CONC_DRAIN_BPS   = 3_000; // 30% of real holdings

    /// @notice Median-rate filter for split allocation. After quoting each
    ///         candidate with the full amountIn, the median rate is computed
    ///         across the survivors. Pools whose rate deviates from the
    ///         median by more than MEDIAN_FILTER_BPS are excluded from the
    ///         depth-weighted split.
    ///
    ///         Why median, not best?  The best pool's rate may itself be
    ///         manipulated (e.g., a low-liquidity pool with a stale price
    ///         pretending to offer the world).  Median is robust: to move
    ///         the median, an attacker must move more than half the pools
    ///         simultaneously, which is economically infeasible across
    ///         different DEX kinds (V2 / V3 / Solidly / CL) with separate
    ///         liquidity sets.
    ///
    ///         400 bps (4%) band: tight enough to exclude mis-priced pools
    ///         (Solidly-stable curves on LST/WETH pairs are typically 20-40%
    ///         off the true rate), loose enough to admit healthy pools whose
    ///         price impact for the trade slightly differs from a near-zero
    ///         marginal-rate reading. Widened from the original ±2% per the
    ///         sealed 2026-08-03 design decision (see vault note "010 -
    ///         Invariantes, Mediana 4% & Padrões Estocásticos").
    uint16  internal constant MEDIAN_FILTER_BPS    = 400;   // ±4%

    error SolverE(uint16 code);

    IHubR public immutable hub;

    constructor(address hub_) {
        require(hub_ != address(0), "Solver:hub0");
        hub = IHubR(hub_);
    }

    // =========================================================================
    //  PUBLIC API
    // =========================================================================

    /// @notice Find the U-maximising route plan for an exact-input swap.
    /// @dev    Enumerates direct + via-bridge[0] + via-bridge[1] topologies
    ///         in parallel, returns max-U as `best` and second-best as `fallback`.
    function findBestRoutePlan(address tIn, address tOut, uint256 amountIn)
        external view returns (RoutePlan memory plan)
    {
        if (tIn == address(0) || tOut == address(0) || tIn == tOut || amountIn == 0)
            revert SolverE(4);

        Route memory direct = _planDirect(tIn, tOut, amountIn);
        Route memory viaB1;
        Route memory viaB2;
        uint8 bc = hub.bridgeCount();
        if (bc > 0) {
            address b0 = hub.bridge(0);
            if (b0 != address(0) && b0 != tIn && b0 != tOut) {
                viaB1 = _planViaBridge(tIn, tOut, amountIn, b0);
            }
        }
        if (bc > 1) {
            address b1 = hub.bridge(1);
            if (b1 != address(0) && b1 != tIn && b1 != tOut) {
                viaB2 = _planViaBridge(tIn, tOut, amountIn, b1);
            }
        }

        Route memory best;
        Route memory second;
        uint256 bestU;
        uint256 secondU;

        (bestU, secondU, best, second) = _rank(direct, viaB1, viaB2);
        if (bestU == 0) revert SolverE(5);

        plan.best = best;
        plan.fallbackRoute = second;
        plan.hasFallback = (secondU > 0);
    }

    function _rank(Route memory a, Route memory b, Route memory c)
        private pure returns (uint256 bestU, uint256 secU, Route memory bestR, Route memory secR)
    {
        if (a.totalOut > 0) { bestU = a.totalOut; bestR = a; }
        if (b.totalOut > bestU) { secU = bestU; secR = bestR; bestU = b.totalOut; bestR = b; }
        else if (b.totalOut > secU) { secU = b.totalOut; secR = b; }
        if (c.totalOut > bestU) { secU = bestU; secR = bestR; bestU = c.totalOut; bestR = c; }
        else if (c.totalOut > secU) { secU = c.totalOut; secR = c; }
    }

    // =========================================================================
    //  TOPOLOGY PLANNERS
    // =========================================================================

    function _planDirect(address tIn, address tOut, uint256 amountIn)
        private view returns (Route memory route)
    {
        PoolInfo[] memory cands = _topKPools(tIn, tOut, MAX_CANDIDATES);
        if (cands.length == 0) return route;
        Hop memory hop = _buildHop(tIn, tOut, amountIn, cands, MAX_LEGS, true);
        if (hop.expectedOut == 0) return route;
        return _assembleRoute(hop);
    }

    function _planViaBridge(
        address tIn, address tOut, uint256 amountIn, address bridge_
    ) private view returns (Route memory route) {
        // Stage A: tIn → bridge, budget = MAX_LEGS_PER_STAGE. The funnel probes
        // the full candidate width; _buildHop cuts to the stage budget by weight.
        PoolInfo[] memory candsA = _topKPools(tIn, bridge_, MAX_CANDIDATES);
        if (candsA.length == 0) return route;
        Hop memory hopA = _buildHop(tIn, bridge_, amountIn, candsA, MAX_LEGS_PER_STAGE, true);
        if (hopA.expectedOut == 0 || hopA.legs.length == 0) return route;

        // Stage B: bridge → tOut, budget = MAX_LEGS - legs(A)
        uint256 legsA = hopA.legs.length;
        if (legsA >= MAX_LEGS) return route;   // stage A used the whole budget
        uint8 budgetB = uint8(MAX_LEGS - legsA);
        if (budgetB == 0) return route;
        PoolInfo[] memory candsB = _topKPools(bridge_, tOut, MAX_CANDIDATES);
        if (candsB.length == 0) return route;
        // Stage B may NOT input-cut: the Router rescales its legs against the
        // REAL bridge balance produced by stage A (scale = realIn / sum of
        // quoted leg inputs), so a cut leg would be scaled straight back up —
        // past its cut promise and into a per-leg floor revert (observed: a
        // 2-hop route that filled at 74bps floor-rejected once its stage-B
        // leg was cut). Stage B keeps the promise-only clamp; the input-side
        // cut protects hop 0 / single-hop, where amounts execute as built.
        Hop memory hopB = _buildHop(bridge_, tOut, hopA.expectedOut, candsB, budgetB, false);
        if (hopB.expectedOut == 0 || hopB.legs.length == 0) return route;

        // Two-hop route: stage A (tIn→bridge) and stage B (bridge→tOut)
        // are kept as SEPARATE hops. The Router executes hop A, measures
        // the actual bridge balance received, then rescales hop B's legs
        // proportionally to the real bridge amount. This makes the route
        // robust to stage-A slippage: stage B always spends exactly what
        // stage A produced, never a stale quoted figure.
        uint256 totalLegs = hopA.legs.length + hopB.legs.length;
        if (totalLegs > MAX_LEGS) return route;

        Hop[] memory hops = new Hop[](2);
        hops[0] = hopA;
        hops[1] = hopB;

        return _assembleRouteMulti(hops, tIn, tOut, amountIn, hopB.expectedOut);
    }

    // =========================================================================
    //  HOP CONSTRUCTION — depth-weighted allocation
    // =========================================================================

    function _buildHop(
        address tIn, address tOut, uint256 amountIn,
        PoolInfo[] memory cands, uint8 budget, bool allowCut
    ) private view returns (Hop memory hop) {
        uint256 n = cands.length;
        if (n == 0) return hop;
        // No blind pre-trim: every candidate is probed (rate + depth + real
        // holdings), and the cut to `budget` happens after weighting — see the
        // FUNNEL CUT below. Discovery order can no longer starve a deep venue.
        if (n == 1) return _singleLeg(tIn, tOut, amountIn, cands[0], allowCut);

        // =========================================================================
        //  STAGE 1 — MARGINAL-RATE MEDIAN FILTER  (single probe pass)
        //
        //  We quote each candidate with a PROBE size (= amountIn / 100) that
        //  is small enough that each pool's marginal rate is essentially its
        //  spot price (negligible impact). Then we compute the median of
        //  those marginal rates and filter pools whose marginal rate
        //  deviates from the median by more than MEDIAN_FILTER_BPS (±2%).
        //
        //  GAS: the probe-size quote is computed exactly ONCE per candidate
        //  here, capturing BOTH the marginal rate AND the depth in the same
        //  call (_quoteWithDepth). Previously this identical probe quote was
        //  recomputed three times — once for the median, once for the band
        //  filter, once for the depth pass — each re-reading the pool's
        //  state (V3 sqrtP+liquidity, V2 reserves, or a full Curve coins()
        //  index scan) although nothing it reads can change within a single
        //  view call. rates[i] and depths[i] stay index-aligned to cands[i]
        //  (we sort a COPY for the median), so the band filter and the depth
        //  pass reuse the cached values with zero extra staticcalls. Only the
        //  final per-leg allocation re-quotes, because it uses a different
        //  (share) input size and so is genuinely a new computation.
        //
        //  Why marginal, not full-input: full-input rates conflate two
        //  signals — pool quality AND pool depth — because a small pool
        //  absorbing a large input shows a "bad" full-input rate but its
        //  spot price may be fine. Filtering on full-input rates throws
        //  away healthy small pools when the trade is large, leaving the
        //  depth split with only 1 leg — exactly the failure mode this
        //  avoids.
        //
        //  Marginal rates cleanly separate the two:
        //    • A stale-priced LST stable-curve pool has a wrong marginal
        //      rate regardless of trade size → filtered.
        //    • A small but healthy pool has a correct marginal rate; its
        //      poor full-input output reflects depth, not pricing → kept.
        //      The subsequent depth split then allocates correctly by depth,
        //      and a small pool naturally receives proportionally less.
        //
        //  This is the correct division of labour: filter on QUALITY (rate)
        //  with a tight band, then allocate by CAPACITY (depth).
        // =========================================================================
        uint256 probe = amountIn / 100;
        if (probe == 0) probe = amountIn;  // tiny trades — full size is the probe

        // Per-candidate caches, index-aligned to `cands`. Filled by the single
        // probe pass and reused by the band filter and the depth weighting.
        uint256[] memory rates  = new uint256[](n);
        uint256[] memory depths = new uint256[](n);
        // CAPITAL ANCHOR. Truth votes with capital, not with existence: dust
        // pools with stale prices can form a fake majority and vote the
        // honest deep pool out of a plain median (for example: two dead
        // SushiV3 pools agreeing on a stale ~910 rate excluded the 401k-USDC
        // pool quoting the true 1633 as an "outlier"). The pool with the
        // largest REAL tokenOut balance is where arbitrage keeps the price
        // true; faking this anchor requires depositing more real capital
        // than the genuine deep pool — at which point the attacker IS the
        // deep pool and arbitrage corrects it. balanceOf is one staticcall
        // and unforgeable without capital (unlike concentrated L, which is
        // free to inflate with a hair-thin position).
        // Per-candidate real tokenOut holdings, reused by the capacity clamp in
        // the allocation pass (no extra staticcall — read here for the anchor).
        // NOTE: the loop keeps NO scalar accumulators (no validity counter, no
        // running anchor) — dead pools leave rates[i] at zero and the median
        // block below derives the zero count AND the anchor by post-scanning
        // the cached arrays. Keeps this loop's via-IR frame minimal: only the
        // arrays, probe and the index stay live across iterations.
        uint256[] memory balsOut = new uint256[](n);
        for (uint256 i; i < n; ) {
            (uint256 o, uint256 d) = _quoteWithDepth(cands[i], tIn, probe);
            if (o > 0) {
                rates[i]  = BPC.mulDiv(o, 1e18, probe);
                depths[i] = d == 0 ? 1 : d;   // matches the legacy "if (d==0) d=1"
                // V3/BP-18 (CRITICAL, devil's-advocate): a V4 pool's address is a
                // codeless truncated poolId whose balanceOf ANYONE can fund with
                // 1 wei — reading the capital anchor from it lets a dust transfer
                // forge maxBal>0 and steer the band. V4 custodies tokens in the
                // PoolManager singleton, so its true per-pool balance is 0: force
                // it, sourcing the capital anchor only from real token-custodying
                // kinds (also keeps _weights' "V4 reports balance 0" honest).
                balsOut[i] = (cands[i].kind == BPC.KIND_V4 || cands[i].kind == BPC.KIND_V4_NATIVE)
                    ? 0
                    : BPC.balanceOf(tOut, cands[i].pool);
            }
            unchecked { ++i; }
        }

        // Median + band bounds, scoped so only hi/lo survive into the filter
        // (the sort machinery and the anchor die with the block — stack).
        uint256 hi;
        uint256 lo;
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
            if (firstNonZero == n) return hop;
            uint256 medianIdx = firstNonZero + ((n - firstNonZero) / 2);
            if (medianIdx >= n) medianIdx = n - 1;  // guard: never index past end
            uint256 median = sortedRates[medianIdx];
            if (median == 0) return hop;

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
            uint256 maxBal;
            uint256 anchorRate;
            uint256 maxDepth;
            uint256 depthRate;
            for (uint256 i; i < n; ) {
                if (balsOut[i] > maxBal) { maxBal = balsOut[i]; anchorRate = rates[i]; }
                if (depths[i]  > maxDepth) { maxDepth = depths[i]; depthRate = rates[i]; }
                unchecked { ++i; }
            }
            uint256 base = maxBal > 0
                ? anchorRate
                : (maxDepth > 0 ? depthRate : median);
            // Zero-base guard (devil's-advocate): a live candidate can have
            // rates[i]==0 (mulDiv floor on a tiny raw price) yet depths[i]>=1, so a
            // depth/capital anchor could set base=0 and collapse the band to
            // hi=lo=0, killing an otherwise routable hop. median is guaranteed
            // non-zero here (the median==0 early-return above), so fall back to it.
            if (base == 0) base = median;
            hi = BPC.mulDiv(base, BPC.BPS + MEDIAN_FILTER_BPS, BPC.BPS);
            lo = BPC.mulDiv(base, BPC.BPS - MEDIAN_FILTER_BPS, BPC.BPS);
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
                uint256 r = rates[i];
                if (r > 0 && r >= lo && r <= hi) {
                    if (nKept != i) {
                        cands[nKept]   = cands[i];
                        depths[nKept]  = depths[i];
                        balsOut[nKept] = balsOut[i];
                    }
                    unchecked { ++nKept; }
                }
                unchecked { ++i; }
            }
            if (nKept == 0) return hop;
            if (nKept == 1) return _singleLeg(tIn, tOut, amountIn, cands[0], allowCut);
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
        // (depth-weighted gave 1638, matching deep-only). depthWad is only
        // comparable within a UNIT FAMILY — concentrated liquidity L (V3 /
        // Algebra / V4) vs pair reserves (V2 / Solidly) vs pool-quoted out
        // (Curve) — so depths normalise against the max of their family, not
        // their kind: a thin V4 can no longer claim max weight merely for
        // being the only V4 (measured: a thin Base V4 pool drew ~49% of a
        // 25k USDC trade and cost ~31% vs fair). When the survivor set spans
        // multiple families AND every survivor holds a real tokenOut balance,
        // weighting switches to that balance outright — the only cross-family
        // comparable, unforgeable-without-capital measure (see _weights).
        (uint256[] memory psis, uint256 sumPsi) = _weights(cands, depths, balsOut, n);

        // ─── FUNNEL CUT (see MAX_CANDIDATES) ───
        // The funnel probed more venues than the leg budget allows; commit to
        // the top-`budget` survivors by WEIGHT (not discovery order), so a deep
        // late-listed pool displaces thin early-listed ones. Extracted to keep
        // this function's stack shallow.
        if (n > budget) (n, sumPsi) = _cutByWeight(cands, psis, balsOut, budget, n);
        Leg[] memory tmpLegs = new Leg[](n);
        uint256 legCount;
        uint256 totalOut;
        uint256 allocated;
        for (uint256 i; i < n; ) {
            uint256 share;
            if (i == n - 1) {
                // Last leg takes the remainder. Guard against rounding
                // overshoot in the preceding mulDiv allocations: if the
                // accumulated total already meets or exceeds amountIn,
                // this leg gets nothing rather than underflowing.
                share = allocated >= amountIn ? 0 : amountIn - allocated;
            } else {
                share = BPC.mulDiv(amountIn, psis[i], sumPsi);
            }
            allocated += share;
            if (share == 0) { unchecked { ++i; } continue; }
            uint256 outL = _quote(cands[i], tIn, share);
            if (outL == 0) { unchecked { ++i; } continue; }
            // ─── Capacity clamp (see MAX_CONC_DRAIN_BPS) ───
            // Concentrated single-tick quotes are clamped to a fraction of the
            // pool's REAL tokenOut holdings, so a thin pool can never inflate
            // totalOut past what it could physically pay. Zero balance (V4
            // singleton accounting) leaves the quote untouched.
            if ((cands[i].kind == BPC.KIND_V3 || cands[i].kind == BPC.KIND_ALGEBRA)
                && balsOut[i] > 0)
            {
                uint256 cap = BPC.mulDiv(balsOut[i], MAX_CONC_DRAIN_BPS, BPC.BPS);
                if (allowCut && outL > balsOut[i]) {
                    // ─── Input-side clamp: capital follows the promise ───
                    // The quote exceeds the pool's WHOLE holdings — physically
                    // impossible, the promise is phantom (measured on a Base
                    // stable pair: 89% of a 10k order sent into a pool holding
                    // 6.2k of tokenOut — a 27% one-way loss walking its tick
                    // ladder and 7M gas crossing it, masked as "surplus"
                    // because the floors derive from the crushed promise). Cut
                    // the committed input in the promise's ratio; the freed
                    // input flows to the LAST leg via the remainder mechanism
                    // (re-clamped there if that leg is also phantom-thin), and
                    // whatever no surviving venue can absorb stays unrouted —
                    // the Router's residual sweep returns it to the caller.
                    // Fills that are aggressive but PHYSICALLY POSSIBLE
                    // (cap < quote <= holdings) keep their full share and only
                    // the promise is capped: cutting those forced partial
                    // fills on healthy pools (measured: a 43bps full fill
                    // degraded to a half-filled order).
                    uint256 keep = BPC.mulDiv(share, cap, outL);
                    allocated -= share - keep;
                    share = keep;
                    outL = cap;
                    if (share == 0) { unchecked { ++i; } continue; }
                } else if (outL > cap) {
                    outL = cap;
                }
                if (outL == 0) { unchecked { ++i; } continue; }
            }
            tmpLegs[legCount] = Leg({
                pool:        cands[i].pool,
                hooks:       cands[i].hooks,
                kind:        cands[i].kind,
                fee:         cands[i].fee,
                tickSpacing: cands[i].tickSpacing,
                zeroForOne:  cands[i].token0 == tIn,
                stable:      cands[i].stable,
                amountIn:    share,
                expectedOut: outL,
                auxId:       (cands[i].kind == BPC.KIND_STABLE || cands[i].kind == BPC.KIND_CURVE_CRYPTO || cands[i].kind == BPC.KIND_V4 || cands[i].kind == BPC.KIND_V4_NATIVE)
                    ? bytes32(uint256(uint160(cands[i].token0 == tIn ? cands[i].token1 : cands[i].token0)))
                    : bytes32(0)
            });
            totalOut += outL;
            unchecked { ++legCount; ++i; }
        }
        if (legCount == 0) return hop;

        Leg[] memory legs = new Leg[](legCount);
        // Σ of the COMMITTED (post-clamp) leg inputs — the honest hop.amountIn.
        // Accumulated in the copy loop that already runs, so no extra pass and
        // no hot-loop local (issue #1): when a phantom cut freed capital that no
        // surviving venue could reabsorb, this is < the caller's amountIn and the
        // Router's residual sweep returns the difference.
        uint256 committedIn;
        for (uint256 i; i < legCount; ) { legs[i] = tmpLegs[i]; committedIn += tmpLegs[i].amountIn; unchecked { ++i; } }

        // Multi-leg conservatism (≥3 legs): shave each expectedOut by legCount × 5 BPS.
        if (legCount >= 3) {
            uint256 shave = legCount * LEG_SAFETY_BPS;
            if (shave > BPC.BPS) shave = BPC.BPS;
            totalOut = 0;
            for (uint256 i; i < legCount; ) {
                legs[i].expectedOut = BPC.mulDiv(legs[i].expectedOut, BPC.BPS - shave, BPC.BPS);
                totalOut += legs[i].expectedOut;
                unchecked { ++i; }
            }
        }
        // MIN-SPLIT IMPROVEMENT GATE. A multi-leg split must EARN its legs:
        // unless it beats the top-weight survivor's single-leg full-size quote
        // by >= MIN_SPLIT_IMPROVEMENT_BPS, collapse to that single leg. Kills
        // micro-splits whose marginal output gain is smaller than the real
        // gas cost of the extra legs. cands[0] is the top-weight survivor
        // (post FUNNEL CUT); one extra full-size quote in the view path only.
        if (legCount >= 2) {
            Hop memory single = _singleLeg(tIn, tOut, amountIn, cands[0], allowCut);
            if (
                single.legs.length != 0 && single.expectedOut > 0 &&
                totalOut < BPC.mulDiv(single.expectedOut, BPC.BPS + MIN_SPLIT_IMPROVEMENT_BPS, BPC.BPS)
            ) {
                return single;
            }
        }
        hop = Hop({
            tokenIn: tIn, tokenOut: tOut,
            amountIn: committedIn, expectedOut: totalOut, legs: legs
        });
    }

    /// @dev Selection-sort the top-`budget` survivors by weight to the front of
    ///      cands/psis/bals (swapped in lockstep so they stay index-aligned),
    ///      then return the trimmed count and the re-summed weight. Isolated
    ///      from _buildHop so its sort locals do not deepen that stack frame.
    function _cutByWeight(
        PoolInfo[] memory cands, uint256[] memory psis, uint256[] memory bals,
        uint256 budget, uint256 n
    ) private pure returns (uint256, uint256) {
        for (uint256 ki; ki < budget; ) {
            uint256 bi = ki;
            for (uint256 j = ki + 1; j < n; ) {
                if (psis[j] > psis[bi]) bi = j;
                unchecked { ++j; }
            }
            if (bi != ki) {
                (cands[ki], cands[bi]) = (cands[bi], cands[ki]);
                (psis[ki], psis[bi])   = (psis[bi], psis[ki]);
                (bals[ki], bals[bi])   = (bals[bi], bals[ki]);
            }
            unchecked { ++ki; }
        }
        uint256 sumPsi;
        for (uint256 i; i < budget; ) { sumPsi += psis[i]; unchecked { ++i; } }
        return (budget, sumPsi);
    }

    /// @dev Unit family of a pool kind. Depth figures are only comparable when
    ///      they share a unit: concentrated liquidity L (V3 / Algebra / V4),
    ///      pair reserves (V2 / Solidly / Balancer), pool-quoted output
    ///      (Curve stable / crypto).
    function _famOf(uint8 kind) private pure returns (uint256) {
        if (kind == BPC.KIND_V3 || kind == BPC.KIND_ALGEBRA
            || kind == BPC.KIND_V4 || kind == BPC.KIND_V4_NATIVE) return 0;
        if (kind == BPC.KIND_STABLE || kind == BPC.KIND_CURVE_CRYPTO) return 2;
        return 1;
    }

    /// @dev Allocation weights for the band survivors, normalised to
    ///      [1..10000]. Two modes:
    ///
    ///      CAPITAL — when the set spans multiple unit families AND every
    ///      survivor holds a real tokenOut balance, weight by that balance:
    ///      it is the only measure comparable across families and cannot be
    ///      faked without depositing real capital (the anchor doctrine,
    ///      extended from filtering to allocation). V4 reports balance 0
    ///      (singleton accounting), which keeps any V4-containing set on the
    ///      depth path below.
    ///
    ///      FAMILY-DEPTH — otherwise, each pool's cached probe depth is
    ///      normalised against the max depth of its own unit family. Within a
    ///      family the units agree, so a thin pool of a rare kind can no
    ///      longer claim max weight merely for being alone in its kind.
    function _weights(
        PoolInfo[] memory cands, uint256[] memory depth, uint256[] memory bals, uint256 n
    ) private pure returns (uint256[] memory psis, uint256 sumPsi) {
        psis = new uint256[](n);
        // Single scan: family maxima (for the depth path) AND the capital-mode
        // predicate AND maxBal — the common single-family case costs exactly
        // two passes over n, matching the historical two-loop cost (the gas
        // bench holds newGas <= oldGas). The predicate packs into one word
        // (bit0 = mixed families, bit1 = zero balance seen) so the scan
        // carries one live slot instead of two booleans: this function is
        // inlined into _buildHop by the via-IR pipeline, where every stack
        // slot counts.
        uint256[] memory maxByFam = new uint256[](3);
        uint256 st;
        uint256 maxBal;
        uint256 fam0 = _famOf(cands[0].kind);
        for (uint256 i; i < n; ) {
            uint256 f = _famOf(cands[i].kind);
            if (f != fam0) st |= 1;
            if (depth[i] > maxByFam[f]) maxByFam[f] = depth[i];
            uint256 b = bals[i];
            if (b == 0) st |= 2;
            if (b > maxBal) maxBal = b;
            unchecked { ++i; }
        }
        // st == 1  ⇔  mixed families AND every survivor funded → capital mode.
        for (uint256 i; i < n; ) {
            uint256 w;
            if (st == 1) {
                w = BPC.mulDiv(bals[i], 10000, maxBal);
            } else {
                uint256 mx = maxByFam[_famOf(cands[i].kind)];
                w = mx == 0 ? 1 : BPC.mulDiv(depth[i], 10000, mx);
            }
            if (w == 0) w = 1;
            psis[i] = w;
            sumPsi += w;
            unchecked { ++i; }
        }
    }

    function _singleLeg(
        address tIn, address tOut, uint256 amountIn, PoolInfo memory cand, bool allowCut
    ) private view returns (Hop memory hop) {
        uint256 out_ = _quote(cand, tIn, amountIn);
        if (out_ == 0) return hop;
        // Capacity clamp — same two-tier doctrine as the split path (see
        // MAX_CONC_DRAIN_BPS). Quote > the pool's WHOLE holdings: physically
        // impossible, so the committed input is cut in the promise's ratio and
        // the route executes a small honest fill (the Router sweeps the
        // uncommitted remainder back to the caller) instead of walking the
        // pool's tick ladder at a collapsing marginal price. Aggressive but
        // possible (cap < quote <= holdings): full commit, promise capped.
        uint256 legIn = amountIn;
        if (cand.kind == BPC.KIND_V3 || cand.kind == BPC.KIND_ALGEBRA) {
            uint256 balOut = BPC.balanceOf(tOut, cand.pool);
            if (balOut > 0) {
                uint256 cap = BPC.mulDiv(balOut, MAX_CONC_DRAIN_BPS, BPC.BPS);
                if (allowCut && out_ > balOut) {
                    legIn = BPC.mulDiv(amountIn, cap, out_);
                    out_ = cap;
                    if (legIn == 0 || out_ == 0) return hop;
                } else if (out_ > cap) {
                    out_ = cap;
                }
            }
        }
        Leg[] memory legs = new Leg[](1);
        legs[0] = Leg({
            pool: cand.pool, hooks: cand.hooks, kind: cand.kind,
            fee: cand.fee, tickSpacing: cand.tickSpacing,
            zeroForOne: cand.token0 == tIn, stable: cand.stable,
            amountIn: legIn, expectedOut: out_,
            auxId: (cand.kind == BPC.KIND_STABLE || cand.kind == BPC.KIND_CURVE_CRYPTO || cand.kind == BPC.KIND_V4 || cand.kind == BPC.KIND_V4_NATIVE)
                ? bytes32(uint256(uint160(cand.token0 == tIn ? cand.token1 : cand.token0)))
                : bytes32(0)
        });
        hop = Hop({
            tokenIn: tIn, tokenOut: tOut,
            // Report the COMMITTED input (post-clamp legIn), not the caller's
            // original order, so hop.amountIn can never disagree with the leg it
            // actually carries. The Router derives the spend cap from Σ leg.amountIn
            // regardless, but an honest hop.amountIn keeps previewPlan and every
            // off-chain reader truthful — issue #1 (NetGakarot).
            amountIn: legIn, expectedOut: out_, legs: legs
        });
    }

    function _quoteWithDepth(PoolInfo memory cand, address tIn, uint256 amt)
        private view returns (uint256 out, uint256 depth)
    {
        bool zfo = cand.token0 == tIn;
        address qIn = tIn;
        address other = zfo ? cand.token1 : cand.token0;
        if (cand.kind == BPC.KIND_V4_NATIVE) {
            // Native V4: PoolInfo carries the pair in WETH-canonical form
            // with token0 = the wrapped-native side (the registry's
            // orientation contract — see Hub._readPoolInfo). The pool's REAL
            // currency0 is address(0): substitute it on whichever side is
            // token0 before the quote sorts the pair, so universalQuote
            // derives the native poolId (address(0) sorts first by
            // construction). zeroForOne needs no branch: token0 == tIn
            // already means "input is currency0" under this orientation.
            if (zfo) qIn = address(0); else other = address(0);
        }
        QuoteCtx memory c = QuoteCtx({
            kind:        cand.kind,
            pool:        cand.pool,
            zeroForOne:  zfo,
            fee:         cand.fee,
            tickSpacing: cand.tickSpacing,
            stable:      cand.stable,
            tokenIn:     qIn,
            tokenOther:  other,
            hooks:       cand.hooks,
            v4Manager:   (cand.kind == BPC.KIND_V4 || cand.kind == BPC.KIND_V4_NATIVE)
                ? hub.v4PoolManager() : address(0)
        });
        (out, depth) = BPC.universalQuote(c, amt);
    }

    /// @dev Depth-free quote. Delegates to `_quoteWithDepth` and drops the depth rather than
    ///      rebuilding an identical QuoteCtx and calling `universalQuote` a second time.
    ///
    ///      This matters for BYTECODE, not just tidiness: `BPC.universalQuote` is an `internal`
    ///      library function, so every call site gets its own INLINED copy of the whole
    ///      multi-venue quote engine (V2, V3, Solidly, Curve, V4). Two call sites meant two
    ///      copies inside this contract. The Solver is the largest contract in the protocol and
    ///      the one closest to the EIP-170 ceiling, so a duplicated call site is a duplicated
    ///      quote engine. R5, "one implementation per published quantity" — deduplication is a
    ///      size measure here, not a style preference.
    function _quote(PoolInfo memory cand, address tIn, uint256 amt)
        private view returns (uint256 out)
    {
        (out, ) = _quoteWithDepth(cand, tIn, amt);
    }

    // =========================================================================
    //  CANDIDATE SELECTION  (lazy discovery + top-K by fitness)
    // =========================================================================

    function _topKPools(address tA, address tB, uint8 keep)
        private view returns (PoolInfo[] memory out)
    {
        // Combine registered pools with discovered ones — never let one suppress
        // the other. Previously "if empty then discover" meant that once any pool
        // was registered for a pair, discovery stopped, so the most-used pairs saw
        // the fewest venues. Union both and dedup by pool address.
        PoolInfo[] memory reg = hub.getActivePools(tA, tB);
        // Gas path: trust a healthy, recently-ticked registry and SKIP the full
        // CREATE2 discovery sweep. New / thin / quiet pairs (registry not fresh)
        // still run discovery so freshly-deployed pools are picked up. Trade-off:
        // an actively-traded pair won't see a brand-new venue until it goes quiet
        // for DISCOVERY_TTL_SECONDS — tune the constants for coverage vs gas. This
        // re-introduces, behind a freshness gate, the "prefer registered" shortcut
        // that was previously removed for permanently suppressing discovery.
        PoolInfo[] memory dis;
        if (!_registryFresh(reg)) dis = hub.discoverFor(tA, tB);
        // V4 discovery: deployer-blind and allowlist-free. Every V4 pool is
        // keccak256(PoolKey) in the one PoolManager, so we DERIVE the canonical
        // hookless ids and keep the ones that exist — one extsload sweep, no admin
        // list. Singleton pools all share pool == manager, so they must be deduped
        // by (fee, tickSpacing, hooks), never by address, or they collapse to one.
        PoolInfo[] memory v4 = BPC.discoverV4(hub.v4PoolManager(), tA, tB);
        uint256 rn = reg.length;
        uint256 dn = dis.length;
        uint256 vn = v4.length;
        PoolInfo[] memory merged = new PoolInfo[](rn + dn + vn);
        uint256 n;
        for (uint256 i; i < rn; ) { merged[n] = reg[i]; unchecked { ++n; ++i; } }
        for (uint256 i; i < dn; ) {
            bool dup;
            for (uint256 j; j < rn; ) { if (dis[i].pool == reg[j].pool) { dup = true; break; } unchecked { ++j; } }
            if (!dup) { merged[n] = dis[i]; unchecked { ++n; } }
            unchecked { ++i; }
        }
        for (uint256 i; i < vn; ) {
            bool dup;
            for (uint256 j; j < n; ) {
                if (merged[j].kind == BPC.KIND_V4
                    && merged[j].fee == v4[i].fee
                    && merged[j].tickSpacing == v4[i].tickSpacing
                    && merged[j].hooks == v4[i].hooks) { dup = true; break; }
                unchecked { ++j; }
            }
            if (!dup) { merged[n] = v4[i]; unchecked { ++n; } }
            unchecked { ++i; }
        }
        if (n == 0) return new PoolInfo[](0);
        PoolInfo[] memory active = new PoolInfo[](n);
        for (uint256 i; i < n; ) { active[i] = merged[i]; unchecked { ++i; } }

        // Compute fitness for each and select top-K with selection sort.
        // ONE batched external call for the whole candidate set (previously
        // keyOf + getPsi per candidate = 2n calls): pure view-path saving.
        uint256[] memory ps;
        {
            address[] memory pls = new address[](n);
            address[] memory t0s = new address[](n);
            address[] memory t1s = new address[](n);
            for (uint256 i; i < n; ) {
                pls[i] = active[i].pool;
                t0s[i] = active[i].token0;
                t1s[i] = active[i].token1;
                unchecked { ++i; }
            }
            ps = hub.psisOf(pls, t0s, t1s);
        }
        for (uint256 i; i < n; ) { if (ps[i] == 0) ps[i] = 1; unchecked { ++i; } }
        uint256 k = n < keep ? n : keep;
        out = new PoolInfo[](k);
        for (uint256 ki; ki < k; ) {
            uint256 bestI = ki;
            for (uint256 j = ki + 1; j < n; ) {
                if (ps[j] > ps[bestI]) bestI = j;
                unchecked { ++j; }
            }
            if (bestI != ki) {
                (active[ki], active[bestI]) = (active[bestI], active[ki]);
                (ps[ki],     ps[bestI])     = (ps[bestI],     ps[ki]);
            }
            out[ki] = active[ki];
            unchecked { ++ki; }
        }
    }

    /// @notice True when the pair's registered set is rich and recent enough to
    ///         trust without a fresh discovery sweep: at least MIN_FRESH_VENUES
    ///         registered pools saw activity within DISCOVERY_TTL_SECONDS (wall
    ///         clock). A pool never ticked (lastUpdateTs == 0) counts as stale, so
    ///         genuinely new pairs always fall through to discovery.
    function _registryFresh(PoolInfo[] memory reg) private view returns (bool) {
        uint256 rn = reg.length;
        if (rn < MIN_FRESH_VENUES) return false;
        uint256 fresh;
        for (uint256 i; i < rn; ) {
            uint256 s = hub.getSlot(hub.keyOf(reg[i].pool, reg[i].token0, reg[i].token1));
            uint256 last = uint256(BPC.decodeLastUpdateTs(s));
            if (last != 0 && block.timestamp - last <= DISCOVERY_TTL_SECONDS) {
                unchecked { ++fresh; }
                // Early exit: once enough fresh venues are found, the
                // remaining Hub staticcalls cannot change the answer.
                if (fresh >= MIN_FRESH_VENUES) return true;
            }
            unchecked { ++i; }
        }
        return false;
    }

    // =========================================================================
    //  FLOOR APPLICATION — assemble Route with the output floor
    // =========================================================================

    function _assembleRoute(Hop memory hop) private view returns (Route memory route) {
        Hop[] memory hops = new Hop[](1);
        hops[0] = hop;
        uint256 legs = hop.legs.length;

        uint256 totalImpactBps;
        for (uint256 i; i < legs; ) {
            uint256 d;
            if (hop.legs[i].kind == BPC.KIND_V2 ||
                hop.legs[i].kind == BPC.KIND_SOLIDLY ||
                hop.legs[i].kind == BPC.KIND_BALANCER_V2)
            {
                (uint256 r0, uint256 r1) = BPC.getReserves(hop.legs[i].pool);
                uint256 rIn = hop.legs[i].zeroForOne ? r0 : r1;
                d = BPC.impactV2Bps(hop.legs[i].amountIn, rIn);
            } else if (hop.legs[i].kind == BPC.KIND_V3 || hop.legs[i].kind == BPC.KIND_ALGEBRA) {
                uint128 liq  = BPC.getLiquidity(hop.legs[i].pool);
                uint160 sp   = BPC.getSqrtPriceX96(hop.legs[i].pool);
                d = BPC.impactV3Bps(
                        hop.legs[i].amountIn, sp, liq,
                        uint24(hop.legs[i].fee),
                        hop.legs[i].zeroForOne
                    );
            } else {
                d = 50; // conservative default for stable / V4 paths
            }
            totalImpactBps += d;
            unchecked { ++i; }
        }
        if (legs > 0) totalImpactBps = totalImpactBps / legs;

        uint256 floorBps = BPC.ironFloorBps(totalImpactBps, legs, 0);
        uint256 floorOut = BPC.mulDiv(hop.expectedOut, floorBps, BPC.BPS);

        route = Route({
            hops:              hops,
            totalOut:          hop.expectedOut,
            singleOut:         hop.expectedOut,
            singleOutFloor:    floorOut,
            expectedImpactBps: totalImpactBps,
            confidenceWad:     0,
            estGas:            _estGas(hop),
            hasSurplus:        hop.expectedOut > floorOut,
            isV4Bundle:        false
        });
    }

    /// @notice Assemble a multi-hop (bridge) route. Aggregates impact across
    ///         both stages and derives the output floor from the FINAL
    ///         output. Hops stay separate so the Router can rescale stage B
    ///         against the real bridge balance produced by stage A.
    function _assembleRouteMulti(
        Hop[] memory hops, address tIn, address tOut,
        uint256 amountIn, uint256 finalOut
    ) private view returns (Route memory route) {
        tIn; tOut; amountIn;   // retained for signature clarity
        uint256 totalImpactBps;
        uint256 totalLegs;
        for (uint256 h; h < hops.length; ) {
            uint256 legs = hops[h].legs.length;
            uint256 hopImpact;
            for (uint256 i; i < legs; ) {
                uint256 d;
                Leg memory L = hops[h].legs[i];
                if (L.kind == BPC.KIND_V2 ||
                    L.kind == BPC.KIND_SOLIDLY ||
                    L.kind == BPC.KIND_BALANCER_V2)
                {
                    (uint256 r0, uint256 r1) = BPC.getReserves(L.pool);
                    uint256 rIn = L.zeroForOne ? r0 : r1;
                    d = BPC.impactV2Bps(L.amountIn, rIn);
                } else if (L.kind == BPC.KIND_V3 || L.kind == BPC.KIND_ALGEBRA) {
                    uint128 liq2 = BPC.getLiquidity(L.pool);
                    uint160 sp2  = BPC.getSqrtPriceX96(L.pool);
                    d = BPC.impactV3Bps(
                            L.amountIn, sp2, liq2,
                            uint24(L.fee),
                            L.zeroForOne
                        );
                } else {
                    d = 50;
                }
                hopImpact += d;
                unchecked { ++i; }
            }
            if (legs > 0) hopImpact = hopImpact / legs;
            totalImpactBps += hopImpact;  // linear sum: safe over-estimate
            totalLegs += legs;
            unchecked { ++h; }
        }

        uint256 floorBps = BPC.ironFloorBps(totalImpactBps, totalLegs, 0);
        uint256 floorOut = BPC.mulDiv(finalOut, floorBps, BPC.BPS);

        route = Route({
            hops:              hops,
            totalOut:          finalOut,
            singleOut:         finalOut,
            singleOutFloor:    floorOut,
            expectedImpactBps: totalImpactBps,
            confidenceWad:     0,
            estGas:            _estGas(hops[0]) + _estGas(hops[1]),
            hasSurplus:        finalOut > floorOut,
            isV4Bundle:        false
        });
    }

    function _estGas(Hop memory hop) private pure returns (uint256 g) {
        g = 30_000;
        uint256 n = hop.legs.length;
        for (uint256 i; i < n; ) {
            uint8 k = hop.legs[i].kind;
            uint256 base = 90_000;
            if (k == BPC.KIND_V3 || k == BPC.KIND_ALGEBRA) base = 110_000;
            else if (k == BPC.KIND_STABLE || k == BPC.KIND_CURVE_CRYPTO) base = 140_000;
            // Native V4 pays the same unlock plus the JIT unwrap/wrap
            // (~35k estimated for WETH withdraw+deposit on warm slots;
            // re-measure at the testnet rehearsal).
            else if (k == BPC.KIND_V4) base = 180_000;
            else if (k == BPC.KIND_V4_NATIVE) base = 215_000;
            g += base;
            unchecked { ++i; }
        }
    }
}
