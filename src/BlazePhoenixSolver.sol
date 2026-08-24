// SPDX-License-Identifier: BUSL-1.1
// =============================================================================
//  BlazePhoenix Protocol — BlazePhoenixSolver
//  Version    : 2.0.0
//  Copyright  : (c) June 2026 – June 2030 BlazePhoenix Protocol
//  License    : Business Source License 1.1 (BUSL-1.1)
//               Change Date    : 2030-06-01
//               Change License : GPL-2.0-or-later
//
//  SINGLE RESPONSIBILITY
//      Decide where the money goes. The Solver is the only place in the protocol
//      where a choice exists; everything else executes, verifies or remembers.
//
//  WHAT THIS CONTRACT GUARANTEES
//      S1  DECIDES 100% ON-CHAIN. There is no oracle, no off-chain signature, no
//          trust parameter. The route is born from the chain and is reproducible by
//          anyone who reads the same blocks — it costs more gas and the
//          result is faithful to real state, which is the trade-off the design picks.
//      S2  COMPARES ONLY WHAT IS COMPARABLE. Depths from different families
//          live in different units (pair reserves are linear; L is in
//          sqrt-scale). They are normalised within the FAMILY, never across families —
//          otherwise a concentrated pool anchors above an equally deep pair
//          pool by a sqrt-price factor.
//      S3  WRITES NOTHING. Everything here is `view`. A Solver bug costs a worse
//          route, never corrupted state.
//
//  WHAT THIS CONTRACT DELIBERATELY DOES NOT DO
//      It does not execute and has no spending power. And the route it returns is NOT
//      a promise: the Router re-measures everything it claims, because a route
//      may reach it by a path other than this one.
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
//      a)  direct        : tIn → tOut, one hop, up to MAX_LEGS_PER_STAGE=4 splits
//      b)  via bridge[0] : tIn → bridge[0] → tOut, 5 legs total
//      c)  via bridge[1] : tIn → bridge[1] → tOut, 5 legs total
//
//  Bridges are the connective tokens of the liquidity graph: exotic-to-exotic
//  swaps usually route through a bridge because that is where depth lives.
//  The Solver evaluates all three topologies and returns the best plus the
//  runner-up as `fallbackRoute`.
//
//  Budget: MAX_LEGS = 11 global, MAX_LEGS_PER_STAGE = 4 per hop -> 4/4+4/4+4+3.
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
    function isBridgeToken(address t) external view returns (bool);
    function v4PoolManager() external view returns (address);
    function v4EntryCount() external view returns (uint256);
}

// MINIMUM gain a split must have over the best single leg to justify
// itself, in PARTS PER MILLION (1 bps = 100 ppm).
//
// AT FILE LEVEL, and not inside the contract, because a TEST has to be
//      able to import it by name. While it lived as an `internal constant`,
//      `test/SplitThreshold.t.sol` replicated the gate and passed the threshold as
//      a LITERAL — restoring 20 bps in production left that test green. A test
//      that cannot read the constant it claims to protect does not protect it.
//      Measured cost of this change: +9 runtime bytes (the `public` version
//      cost +47).
//
// SCALED IN PPM because the value the owner wanted — 0.25 bps — is not
//      representable in whole bps. The dead zone MEASURED on Base is 0.030 bps
//      (3 ppm): the real cost of the extra leg's 320 B of calldata, at
//      105.5 gas/byte. 25 ppm is ~8x that.
//      History: 20 bps (667x the dead zone) -> 5 bps (167x) -> 0.25 bps (8x).
//      Neither of the first two had been calibrated against any measurement.
uint32 constant MIN_SPLIT_IMPROVEMENT_PPM = 25;

contract BlazePhoenixSolver {

    string  public constant VERSION                = "2.0.0";

    /// @notice Maximum legs across the entire route, regardless of topology.
    /// @notice GLOBAL leg ceiling for a route, summing every hop.
    ///         11 since 2026-08-22 (was 5), by the owner's decision.
    ///
    ///         THE 11 IS NOT ARBITRARY, and needs no special case: combined
    ///         with the per-hop ceiling of 4, it yields exactly the asked distribution
    ///           direct  :            min(4, 11)        = 4
    ///           2 hops  : 4 +        min(11-4, 4)      = 4 + 4  =  8
    ///           3 hops  : 4 + 4 +    min(11-8, 4)      = 4+4+3  = 11
    ///         The last hop of a three-hop route gets 3 because the global ceiling
    ///         squeezes it — not because someone wrote it in code. One constant
    ///         doing the work of three.
    ///
    ///         THEY ARE TWO DIFFERENT QUESTIONS and that is why they are two constants:
    ///           "how many legs fit in a hop?"        -> MAX_LEGS_PER_STAGE
    ///           "how many legs fit in a ROUTE?"      -> MAX_LEGS
    ///         Collapsing them would let a direct route spend the whole budget
    ///         on a single hop, which violates the per-hop ceiling.
    uint8   internal constant MAX_LEGS             = 11;

    /// @notice Stage-A budget for bridge routes.  Stage B gets MAX_LEGS - A_used.
    /// @notice PER-HOP leg ceiling, in any topology — including the direct
    ///         route. 4 since 2026-08-22 (was 3, and the direct route did not even
    ///         respect it: it used the global ceiling).
    uint8   internal constant MAX_LEGS_PER_STAGE   = 4;

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


    /// @notice MINIMUM gain a split must have over the best single leg
    ///         to justify itself, in PARTS PER MILLION (1 bps = 100 ppm).
    ///
    /// @dev SCALED IN PPM AND NOT IN BPS, and the reason is that the value the owner
    ///      wanted — 0.25 bps — is not representable in whole bps. The dead zone
    ///      MEASURED on Base is 0.030 bps (3 ppm): the real cost of the 320 B of
    ///      calldata of the extra leg, at 105.5 gas/byte. 25 ppm is ~8x that,
    ///      which is margin enough not to split on noise and small
    ///      enough not to throw away real gain.
    ///
    ///      HISTORY OF THIS NUMBER, because it teaches: it was 20 bps (667x the dead
    ///      zone), became 5 bps (167x) and is now 0.25 bps (8x). Neither of the
    ///      first two versions had been calibrated against any measurement.
    ///
    ///      IT IS PER CHAIN, one day: 320 B cost $0.003 on Base and ~$257 on Scroll.
    ///      The ChainProfile exists to carry that; until then, this value serves
    ///      the cheap L2s, which is where the product lives.

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
    ///         bounded formulas (V2 / Solidly) cannot
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
        Route memory viaB3;
        // The `bridgeCount()` that used to be here was REDUNDANT. The slots above the counter are
        // ALWAYS address(0) — `addBridge` fills in sequence and `removeBridge` compacts and
        // zeroes the leftover — and both guards already tested `!= address(0)`. It was a traversal of
        // boundary crossing per solve to answer a question the read value itself already answers.
        //
        // THE HONEST BALANCE: with >= 2 bridges configured (the production case) it is 3 crossings
        // dropping to 2. With an EMPTY registry it goes from 1 to 2 — worse, but a registry with
        // no bridges is a misconfiguration, not a regime worth optimising.
        //
        // AND THE TWO UNROLLED READS ARE THE HUB'S `MAX_BRIDGE_ROUTES`, WRITTEN HERE IN
        // CODE. It is this number — not MAX_BRIDGES — that decides across how many bridges we
        // route, and the difference between the two was a silent asymmetry: the third bridge had
        // admission rights and +25% fitness without ever being able to be a hop. See the
        // Hub's MAX_BRIDGE_ROUTES note and test/RoutableBridgeAsymmetry.t.sol, pinning both sides.
        // OWNER DECISION 2026-08-21: MAX_BRIDGES went down from 3 to 2 and the third
        // arm (`b2`/`viaB3`) was REMOVED from here in the same commit. The two things MUST
        // move together: `hub.bridge(2)` over an `address[2]` reverts with Panic 0x32.
        // Measured before the cut (Base fork, 9 factories, USDC->LINK): the 3rd bridge cost
        // +760,125 gas per cold solve, +32.5%. Whoever adds a `b2` here MUST raise
        // the constant over there — and vice versa.
        address b0 = hub.bridge(0);
        if (b0 != address(0) && b0 != tIn && b0 != tOut) {
            viaB1 = _planViaBridge(tIn, tOut, amountIn, b0);
        }
        address b1 = hub.bridge(1);
        if (b1 != address(0) && b1 != tIn && b1 != tOut) {
            viaB2 = _planViaBridge(tIn, tOut, amountIn, b1);
        }
        address b2 = hub.bridge(2);
        if (b2 != address(0) && b2 != tIn && b2 != tOut) {
            viaB3 = _planViaBridge(tIn, tOut, amountIn, b2);
        }

        Route memory best;
        Route memory second;
        uint256 bestU;
        uint256 secondU;

        Melhores memory m;
        _considera(m, direct);
        _considera(m, viaB1);
        _considera(m, viaB2);
        _considera(m, viaB3);
        // THREE HOPS over TWO bridges: tIn -> bX -> bY -> tOut.
        //
        // NO `bridgeCount()`: the three values are already in hand (b0/b1/b2,
        // read above) and the positions above the counter are ALWAYS address(0)
        // — `addBridge` fills in sequence and `removeBridge` compacts. Restoring
        // the call would undo yesterday's deliberate removal (-1,581 gas per
        // solve) to answer a question that the values already read do
        // answer. The `!= address(0)` guards do the rest.
        //
        // This only ADDS candidates to the judgement: a direct route still
        // wins whenever it delivers more, because the comparison is by `totalOut`
        // and not by topology depth.
        address[3] memory bs = [b0, b1, b2];
        for (uint256 i; i < 3; ) {
            address x = bs[i];
            if (x != address(0) && x != tIn && x != tOut) {
                for (uint256 j; j < 3; ) {
                    address y = bs[j];
                    if (j != i && y != address(0) && y != tIn && y != tOut && y != x) {
                        _considera(m, _planViaTwoBridges(tIn, tOut, amountIn, x, y));
                    }
                    unchecked { ++j; }
                }
            }
            unchecked { ++i; }
        }
        bestU = m.bestU; secondU = m.secU; best = m.bestR; second = m.secR;
        if (bestU == 0) revert SolverE(5);

        plan.best = best;
        plan.fallbackRoute = second;
        plan.hasFallback = (secondU > 0);
    }

    /// @dev The SINGLE producer of the "which route is best" judgement, and the criterion is
    ///      `totalOut` — the output actually BUILT and measured for each topology, not a proxy.
    ///      That is why every configured bridge is expanded and handed in here instead of being
    ///      pre-filtered by registry depth: a proxy pre-filter would be a SECOND producer of the
    ///      same judgement, and the worse of the two — it could discard exactly the route this
    ///      one would pick. Depth already does its job where it should, one level below, ordering
    ///      candidates WITHIN each hop (`_topKPools`, `_buildHop`).
    /// @dev ACCUMULATOR, not a parameter list. It was `_rank(a,b,c,d)` — and the
    ///      parameter count WAS MAX_BRIDGE_ROUTES written in code, which
    ///      created the phantom bridge when the two diverged (the corpus, §4).
    ///      With the two-bridge topologies there are up to 10 candidates; a
    ///      10-parameter signature would encode the same constant in an arity again.
    ///
    ///      The accumulator erases the possibility: whoever adds a topology
    ///      calls `_considera` one more time and there is no arity to
    ///      forget to raise. It remains the SINGLE PRODUCER of the "which
    ///      route is best" judgement, and still decides by `totalOut` — the
    ///      output built and measured, never a proxy.
    ///      The parameter count here IS MAX_BRIDGE_ROUTES written in code: if
    ///      they diverge again, the asymmetry the corpus documented in §4 is born —
    ///      a bridge with admission rights and fitness that can never be a hop.
    ///      test/RoutableBridgeAsymmetry.t.sol pins both sides.
    struct Melhores {
        uint256    bestU;
        uint256    secU;
        Route      bestR;
        Route      secR;
    }

    function _considera(Melhores memory m, Route memory r) private pure {
        uint256 u = r.totalOut;
        if (u == 0) return;
        if (u > m.bestU) { m.secU = m.bestU; m.secR = m.bestR; m.bestU = u; m.bestR = r; }
        else if (u > m.secU) { m.secU = u; m.secR = r; }
    }

    // =========================================================================
    //  TOPOLOGY PLANNERS
    // =========================================================================

    function _planDirect(address tIn, address tOut, uint256 amountIn)
        private view returns (Route memory route)
    {
        PoolInfo[] memory cands = _topKPools(tIn, tOut, MAX_CANDIDATES);
        if (cands.length == 0) return route;
        // PER-HOP CEILING, not the global one: a direct route is ONE hop, and
        // the 4-legs-per-hop limit applies to it like to any other. It used to
        // use MAX_LEGS and could spend the entire budget on a single hop.
        Hop memory hop = _buildHop(tIn, tOut, amountIn, cands, MAX_LEGS_PER_STAGE, true);
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
        if (budgetB > MAX_LEGS_PER_STAGE) budgetB = MAX_LEGS_PER_STAGE;
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

    /// @notice THREE HOPS over TWO bridges: tIn -> bA -> bB -> tOut.
    ///
    /// @dev WHY IT EXISTS, and why it does not make routes longer by default.
    ///      `_rank` compares `totalOut` — the output BUILT and measured for each
    ///      topology. A 3-hop route only wins if it delivers more, and a direct
    ///      route still wins whenever it is the best. Adding this topology does
    ///      NOT lengthen routes: it adds a candidate to the judgement that already
    ///      exists.
    ///
    ///      THE COST FALLS WHERE IT DOES NOT MATTER. It is three more `_buildHop`
    ///      per bridge pair, and that is paid in the SOLVE — which at entry point A
    ///      runs over `eth_call`, for free. At entry point B it is paid in gas, so
    ///      this topology only pays off where data dominates. See the corpus (the four entry points).
    ///
    ///      LEG BUDGET. `MAX_LEGS = 5` in total. Stage A may cut on the input
    ///      (it executes as it was built); B and C may NOT — the Router
    ///      rescales them against the REAL measured balance of the prior stage, and a
    ///      cut leg would be scaled straight back up, past its
    ///      promise and into a per-leg floor revert. Each downstream stage
    ///      reserves at least one leg for the ones that follow.
    function _planViaTwoBridges(
        address tIn, address tOut, uint256 amountIn, address bA, address bB
    ) private view returns (Route memory route) {
        // Stage A: tIn -> bA. Reserves 2 legs (one for B, one for C).
        PoolInfo[] memory candsA = _topKPools(tIn, bA, MAX_CANDIDATES);
        if (candsA.length == 0) return route;
        uint8 budgetA = MAX_LEGS_PER_STAGE;
        if (budgetA > MAX_LEGS - 2) budgetA = uint8(MAX_LEGS - 2);   // reserve 1 for B and 1 for C
        Hop memory hopA = _buildHop(tIn, bA, amountIn, candsA, budgetA, true);
        if (hopA.expectedOut == 0 || hopA.legs.length == 0) return route;

        // Stage B: bA -> bB. Reserves 1 leg for C.
        uint256 usadas = hopA.legs.length;
        if (usadas + 2 > MAX_LEGS) return route;
        PoolInfo[] memory candsB = _topKPools(bA, bB, MAX_CANDIDATES);
        if (candsB.length == 0) return route;
        uint8 budB = uint8(MAX_LEGS - usadas - 1);                    // reserve 1 for C
        if (budB > MAX_LEGS_PER_STAGE) budB = MAX_LEGS_PER_STAGE;
        Hop memory hopB = _buildHop(bA, bB, hopA.expectedOut, candsB, budB, false);
        if (hopB.expectedOut == 0 || hopB.legs.length == 0) return route;

        // Stage C: bB -> tOut, with whatever is left over.
        usadas += hopB.legs.length;
        if (usadas >= MAX_LEGS) return route;
        PoolInfo[] memory candsC = _topKPools(bB, tOut, MAX_CANDIDATES);
        if (candsC.length == 0) return route;
        uint8 budC = uint8(MAX_LEGS - usadas);
        if (budC > MAX_LEGS_PER_STAGE) budC = MAX_LEGS_PER_STAGE;
        Hop memory hopC = _buildHop(bB, tOut, hopB.expectedOut, candsC, budC, false);
        if (hopC.expectedOut == 0 || hopC.legs.length == 0) return route;
        if (usadas + hopC.legs.length > MAX_LEGS) return route;

        Hop[] memory hops = new Hop[](3);
        hops[0] = hopA;
        hops[1] = hopB;
        hops[2] = hopC;
        return _assembleRouteMulti(hops, tIn, tOut, amountIn, hopC.expectedOut);
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
        //  deviates from the base by more than MEDIAN_FILTER_BPS (±5%).
        //
        //  GAS: the probe-size quote is computed exactly ONCE per candidate
        //  here, capturing BOTH the marginal rate AND the depth in the same
        //  call (_quoteWithDepth). Previously this identical probe quote was
        //  recomputed three times — once for the median, once for the band
        //  filter, once for the depth pass — each re-reading the pool's
        //  state (V3 sqrtP+liquidity, V2 reserves, or a V4 singleton
        //  extsload) although nothing it reads can change within a single
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
        // DECIMALS HOISTING. Every candidate in this loop is a pool of the
        // SAME pair, so they hold the SAME two tokens — only orientation changes.
        // Reading `decimals()` in there cost 2,339 gas PER CANDIDATE (measured;
        // EIP-2929 does not make it free because USDC is a proxy). Here it is
        // once per pair. Encoded +1 (see QuoteCtx.decIn1): 0 would mean "not
        // filled" and there are tokens with genuinely 0 decimals.
        uint8 dIn1_ = BPC.decimalsOf(tIn) + 1;
        uint8 dOt1_ = BPC.decimalsOf(tOut) + 1;
        // CAPITAL ANCHOR. Truth votes with capital, not with existence: dust
        // pools with stale prices can form a fake majority and vote the
        // honest deep pool out of a plain median (for example: two dead
        // SushiV3 pools agreeing on a stale ~910 rate excluded the 401k-USDC
        // pool quoting the true 1633 as an "outlier").
        //
        // ATTENTION TO WHOEVER READS THIS TOP-DOWN: it was written here, for a long
        // time, that the band anchor was "the pool with the largest REAL tokenOut
        // balance", and that `balanceOf` was unforgeable without capital. THAT ARGUMENT
        // IS REFUTED and the design it defended was REMOVED — the refutation is written
        // out in full in the T2 fix, some dozens of lines below (search "T2 (Thomas)"):
        // a plain DONATION (transferring to the pool) inflates `balanceOf` without
        // moving the reserve or the price, and it is recoverable (V2 skim, V3 LP claim)
        // — so it is not "capital at risk". An attacker won the anchor with a donation,
        // centred the band on their bad rate and filtered the honest deep pool OUT.
        //
        // TODAY's anchor is `_depthWeightedMedian(rates, depths, n)`, and it uses
        // `depths`: getReserves (V2/Solidly), getLiquidity (V3), measured liquidity (V4)
        // — quantities a donation does not move. It does NOT use this loop's `balsOut`.
        //
        // `balsOut` is still read here for ANOTHER reason, and only for it: it is the
        // capacity ceiling of the allocation step, which only runs for the kinds that
        // concentrate in the pool (A_CONC_POOL). It is not an anchor and must not be one again.
        // NOTE: the loop keeps NO scalar accumulators (no validity counter, no
        // running anchor) — dead pools leave rates[i] at zero and the median
        // block below derives the zero count AND the anchor by post-scanning
        // the cached arrays. Keeps this loop's via-IR frame minimal: only the
        // arrays, probe and the index stay live across iterations.
        uint256[] memory balsOut = new uint256[](n);
        for (uint256 i; i < n; ) {
            (uint256 o, uint256 d) = _quoteWithDepth(cands[i], tIn, probe, dIn1_, dOt1_);
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
                balsOut[i] = BPC.kindHasAny(cands[i].kind, BPC.A_CONC_SING)
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
            // T2 (Thomas): anchor on MEASURED DEPTH, never raw balanceOf. The old
            // capital anchor read balsOut[i] = balanceOf(tokenOut, pool), which a
            // plain donation (transfer to the pool) inflates WITHOUT moving the
            // reserve or price — and the donation is recoverable (V2 skim / V3 LP
            // claim), so it is not "capital at risk". That let an attacker win the
            // anchor with a donation, center the band on their bad rate, and filter
            // the honest deep pool OUT (~75% user loss, preview gamed identically).
            // depths[] is getReserves (V2/Solidly) / getLiquidity (V3), which a
            // donation cannot move; V4 depth is its measured liquidity. Falls back
            // to the median only when no candidate reports depth.
            uint256 base = _depthWeightedMedian(rates, depths, n);
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
        (uint256[] memory psis, uint256 sumPsi) = _weights(cands, depths, balsOut, n);

        // ─── FUNNEL CUT (see MAX_CANDIDATES) ───
        // The funnel probed more venues than the leg budget allows; commit to
        // the top-`budget` survivors by WEIGHT (not discovery order), so a deep
        // late-listed pool displaces thin early-listed ones. Extracted to keep
        // this function's stack shallow.
        if (n > budget) (n, sumPsi) = _cutByWeight(cands, psis, balsOut, rates, budget, n);
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
            // A single-tick concentrated quote is capped at a fraction of the pool's REAL
            // tokenOut holdings, so a thin pool cannot inflate totalOut above what it can
            // PHYSICALLY pay. A zero balance (accounting held in the V4 singleton) leaves
            // the quote untouched.
            //
            // WHY `balanceOf` HERE AND NOT MEASURED DEPTH — because the T2 doctrine does NOT
            // apply to this site, though it reads the same function. An audit proposed swapping
            // in `depths[i]` invoking T2 ("never raw balanceOf"), and the swap was TRIED AND
            // MEASURED: for a V3 pool, `depthFromL` gives the VIRTUAL reserve derived from L,
            // which can be far LARGER than the physical holdings — 3.327e18 against 1.600e18 in
            // the test case. The cap got LOOSER, the opposite of the intent.
            //
            // The distinction this teaches, good for the next site that reads balanceOf:
            //   · the BAND ANCHOR asks a RELATIVE question ("which of these pools is the good
            //     one?"). A donation skews the comparison at no cost to the donor — T2 applies,
            //     and the anchor uses measured depth.
            //   · this CAP asks a PHYSICAL question ("can this pool pay this?"). A donation
            //     raises the cap AND raises what the pool can really pay, and the donated tokens
            //     are CONSUMED paying the user. It is not an attack, it is a subsidy.
            // Reading the same quantity does not mean asking the same question.
            if (BPC.kindHas(cands[i].kind, BPC.A_CONC_POOL)
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
                auxId:       BPC.kindHasAny(cands[i].kind, BPC.A_CONC_SING)
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

        // REMOVED: the per-leg conservatism haircut (it was `legCount * 5 bps`
        // above 3 legs), by the owner's decision on 2026-08-22.
        //
        // THE REASON IS MEASURED, not aesthetic. Quote-vs-execution fidelity in
        // the same block was measured over 9 Base pairs: worst case **-2 bps**.
        // The haircut took 5 bps PER LEG — 27x the observed error, and up to 55
        // bps on an 11-leg route. By the asymmetry that governs this file,
        // underestimating is not neutral: ranking is lost, and therefore routes
        // that should win. It was the same pattern as the split gate, which
        // sat 200-667x above the real break-even and was cut from 20 to 5.
        //
        // What still protects execution stands on its own and does not need it:
        // the per-leg floor, the Layer 1 aggregate floor, and the mandatory
        // `userMinOut` — those are checked against REALIZED output, not
        // against an estimate shrunk a priori.
        //
        // The counter-argument, on the record: the -2 bps were measured in a
        // CALM window (the price moved 0.05 bps over 3 blocks). The haircut
        // also covered adversarial divergence, which that measurement does not
        // exercise. If conservatism is ever restored, the right place is the
        // floor (which is checked) and not the estimate (which only ranks).
        // MIN-SPLIT IMPROVEMENT GATE. A multi-leg split must EARN its legs:
        // unless it beats the top-weight survivor's single-leg full-size quote
        // by >= MIN_SPLIT_IMPROVEMENT_PPM (ppm), collapse to that single leg. Kills
        // micro-splits whose marginal output gain is smaller than the real
        // gas cost of the extra legs. cands[0] is the top-weight survivor
        // (post FUNNEL CUT); one extra full-size quote in the view path only.
        if (legCount >= 2) {
            // TWO FALLBACK CANDIDATES, not one. `cands[0]` is the highest
            // WEIGHT, that is the DEEPEST — never the best priced. Comparing
            // the split only against it means a better single leg could
            // exist and never be considered.
            //
            // But `argmax(rates)` alone is no good either, for a subtle
            // reason: the `rates` come from a SMALL probe, so they are
            // MARGINAL prices, and a marginal price favours SHALLOW pools —
            // great on the first token, awful on the whole amount. Depth is
            // precisely the proxy for "can take the full size".
            //
            // The two heuristics measure different things and neither wins.
            // BOTH are evaluated at real size and the best one stays: it
            // costs ONE extra quote in the view path, and it cannot lose to
            // the old behaviour because that is one of the two candidates.
            // `n`, NOT `cands.length`. The survivors are compacted IN
            // PLACE (see the compaction block above) but the memory array
            // keeps its ORIGINAL length: positions >= n are junk from
            // candidates the median band REJECTED or the funnel CUT.
            // Walking `cands.length` resurrected them as the fallback single
            // leg, voiding both filters — caught by
            // test_UmaPoolFundaNaoCapturaABanda, which exists exactly to
            // stop a deep badly-priced pool from entering the route.
            uint256 melhorTaxa;
            for (uint256 i = 1; i < n; ) {
                if (rates[i] > rates[melhorTaxa]) melhorTaxa = i;
                unchecked { ++i; }
            }
            Hop memory single = _singleLeg(tIn, tOut, amountIn, cands[0], allowCut);
            if (melhorTaxa != 0) {
                Hop memory alt = _singleLeg(tIn, tOut, amountIn, cands[melhorTaxa], allowCut);
                if (alt.legs.length != 0 && alt.expectedOut > single.expectedOut) single = alt;
            }
            if (
                single.legs.length != 0 && single.expectedOut > 0 &&
                totalOut < BPC.mulDiv(
                    single.expectedOut, 1_000_000 + MIN_SPLIT_IMPROVEMENT_PPM, 1_000_000
                )
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
        uint256[] memory rates, uint256 budget, uint256 n
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

    /// @dev CANONICAL ORDER (Layer 2), on the PLANNING side. STABLE partition of the legs of
    ///      a hop: hookless to the front, relative order PRESERVED inside each group.
    ///
    ///      WHY IT EXISTS. The Router requires hookless BEFORE hooked inside a hop and reverts
    ///      RouterE(3) otherwise — a hook gains EVM control during the swap and can touch the
    ///      pool of a leg of the SAME route that has not executed yet. The Solver ordered by
    ///      WEIGHT, so a deeper hooked pool came first and the route it built itself reverted
    ///      in execution. Self-DoS on the canonical entry point.
    ///
    ///      WHY HERE AND NOT IN THE RANKING CRITERION, which is where it seemed to belong.
    ///      `_buildHop` is chronically one slot from the via_ir stack limit — `_cutByWeight`
    ///      itself had already been extracted for that reason, and the compiler inlines it back
    ///      in there, so any local added to the comparator counts against that frame and blows
    ///      it. I tried three shapes before this one and all three blew it.
    ///      The material constraint ended up pointing at the most honest site: leg order is a
    ///      property of the ROUTE, not of the POOL selection criterion. Here it operates on the
    ///      already-built hop, and it reads exactly like the rule the Router checks.
    ///
    ///      STABILITY IS NOT AESTHETIC: the order inside each group came from weight, and a
    ///      plain swap would destroy it. And all this function can change is the ORDER — the
    ///      multiset {(pool, amountIn)} stays intact, because each leg travels whole.
    function _orderLegs(Hop memory hop) private pure {
        Leg[] memory legs = hop.legs;
        uint256 k = legs.length;
        uint256 w;
        for (uint256 i; i < k; ) {
            if (legs[i].hooks == address(0)) {
                if (i != w) {
                    Leg memory tmp = legs[i];
                    for (uint256 j = i; j > w; ) {
                        legs[j] = legs[j - 1];
                        unchecked { --j; }
                    }
                    legs[w] = tmp;
                }
                unchecked { ++w; }
            }
            unchecked { ++i; }
        }
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
    function _depthWeightedMedian(uint256[] memory rates, uint256[] memory depths, uint256 n)
        private pure returns (uint256)
    {
        uint256[] memory r = new uint256[](n);
        uint256[] memory d = new uint256[](n);
        uint256 m;
        uint256 massa;
        for (uint256 i; i < n; ) {
            // Dead pools (rate 0) do not vote: they have no opinion on the price.
            if (rates[i] > 0) {
                r[m] = rates[i];
                d[m] = depths[i];
                massa += depths[i];
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
        if (BPC.kindHas(cand.kind, BPC.A_CONC_POOL)) {
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
            auxId: BPC.kindHasAny(cand.kind, BPC.A_CONC_SING)
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

    /// @param dIn1 decimals of `tIn` +1, `dOt1` those of the other token +1 (0 =
    ///        not filled -> the Core reads them). HOISTING: every candidate of a
    ///        pair has the SAME two tokens, only the orientation changes, so
    ///        these two values are computed ONCE per pair instead of once per
    ///        candidate. Measured: 2,339 gas per repeated read, and
    ///        EIP-2929 does not make it free (USDC is a proxy with delegatecall
    ///        inside). With 16 candidates: +2.2% -> +0.7% of the solve.
    function _quoteWithDepth(
        PoolInfo memory cand, address tIn, uint256 amt, uint8 dIn1, uint8 dOt1
    ) private view returns (uint256 out, uint256 depth) {
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
            v4Manager:   BPC.kindHasAny(cand.kind, BPC.A_CONC_SING)
                ? hub.v4PoolManager() : address(0),
            // NO TERNARY, and the reason matters. The first version wrote
            // `zfo ? dIn1 : dIn1` — both branches equal, a no-op pretending
            // a decision had been made. There is none: `zfo` says whether tIn
            // is the POOL's token0, but the context's `tokenIn` is always the
            // pair's tIn. So decIn1 is always tIn's and decOther1 the other's.
            decIn1:      dIn1,
            decOther1:   dOt1
        });
        (out, depth) = BPC.universalQuote(c, amt);
    }

    /// @dev Depth-free quote. Delegates to `_quoteWithDepth` and drops the depth rather than
    ///      rebuilding an identical QuoteCtx and calling `universalQuote` a second time.
    ///
    ///      CORRECTION NOTE: this paragraph said that `BPC.universalQuote` is `internal`. It is
    ///      `public` (see Core) — so each call site does NOT inline a copy, it DELEGATECALLs the
    ///      already-deployed library. The bytecode argument below applied to an earlier world;
    ///      today the reason not to duplicate the call site is a different one, and it holds all
    ///      the same: two sites are two channels to diverge.
    ///      This matters for BYTECODE, not just tidiness: if it were `internal`, each call site
    ///      carried its own INLINED copy of the
    ///      multi-venue quote engine (V2, V3, Solidly, V4). Two call sites meant two
    ///      copies inside this contract. The Solver is the largest contract in the protocol and
    ///      the one closest to the EIP-170 ceiling, so a duplicated call site is a duplicated
    ///      quote engine. R5, "one implementation per published quantity" — deduplication is a
    ///      size measure here, not a style preference.
    function _quote(PoolInfo memory cand, address tIn, uint256 amt)
        private view returns (uint256 out)
    {
        (out, ) = _quoteWithDepth(cand, tIn, amt, 0, 0);   // single path: hoisting not worth it
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
        uint256 rn = reg.length;
        uint256 dn = dis.length;
        PoolInfo[] memory merged = new PoolInfo[](rn + dn);
        uint256 n;
        // ─── HOOK ADMISSIBILITY ───
        // The Router refuses at EXECUTION any leg whose hook alters deltas (RouterE(9)), and the
        // Solver did not know that rule existed: the Hub's `getActivePools` filters by
        // `isHookLive` but NOT by this. The result was a self-DoS on the canonical entry point —
        // `swapBestExactIn` assembled in-frame a route the Router itself rejected, and the pair
        // was left with no entry point and nobody knew why.
        //
        // THE HOUSE RULE, EXPLICIT: the Router's check is NOT deleted to make the two agree.
        // It is what keeps the system fail-closed until THIS exists, and the disagreement between
        // the two is the DIAGNOSIS. Add knowledge to the Solver; do not take any from the Router.
        //
        // IT LIVES HERE AND NOT IN `getActivePools` because this is a ROUTING decision. The
        // `getActivePools` is a shared READ channel; filtering there took the pool out of view for
        // ALL consumers, including anyone who only wants to inspect the registry.
        //
        // AND IT LIVES INSIDE THESE TWO LOOPS, not in a step of its own afterwards, for a material
        // constraint: under via_ir this function is inlined into the same frame as `_buildHop`,
        // chronically one slot from the limit — a single new counter blew it. Here it reuses
        // the `n` that already exists.
        //
        // ZERO COST in calls: `hookAltersDeltas` reads bits of the hook address itself.
        for (uint256 i; i < rn; ) {
            if (!BPC.hookAltersDeltas(reg[i].hooks)) { merged[n] = reg[i]; unchecked { ++n; } }
            unchecked { ++i; }
        }
        for (uint256 i; i < dn; ) {
            bool dup;
            for (uint256 j; j < rn; ) { if (dis[i].pool == reg[j].pool) { dup = true; break; } unchecked { ++j; } }
            if (!dup && !BPC.hookAltersDeltas(dis[i].hooks)) { merged[n] = dis[i]; unchecked { ++n; } }
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
        _orderLegs(hop);
        Hop[] memory hops = new Hop[](1);
        hops[0] = hop;
        uint256 legs = hop.legs.length;

        uint256 totalImpactBps;
        for (uint256 i; i < legs; ) {
            uint256 d;
            if (BPC.kindHas(hop.legs[i].kind, BPC.A_RESERVES)) {
                (uint256 r0, uint256 r1) = BPC.getReserves(hop.legs[i].pool);
                uint256 rIn = hop.legs[i].zeroForOne ? r0 : r1;
                d = BPC.impactV2Bps(hop.legs[i].amountIn, rIn);
            } else if (BPC.kindHas(hop.legs[i].kind, BPC.A_CONC_POOL)) {
                uint128 liq  = BPC.getLiquidity(hop.legs[i].pool);
                // INV-20 on impact: the EFFECTIVE fee, not the declared one. For
                // Algebra the Hub's rule R2 (Hub:511-512) forces the registry
                // fee to be the sentinel 0 — passing it raw to impactV3Bps
                // priced the leg with NO fee at all, understated the impact and
                // published a `singleOutFloor` TIGHTER than the one that
                // execution faces. Since the Router can only TIGHTEN the floor
                // with the plan's (Router:1203), an honest fill died in RouterE(5).
                // The other two channels that price Algebra already measured
                // (Core.universalQuote and Router._hopScaleImpactAndQuote): this
                // was the sibling still to be fixed.
                // ZERO COST IN STATICCALLS: v3StateAndDynFee already does the slot0()
                // that getSqrtPriceX96 did, and returns the live fee for free.
                (uint160 sp, uint24 dynFee, bool dyn) = BPC.v3StateAndDynFee(hop.legs[i].pool);
                d = BPC.impactV3Bps(
                        hop.legs[i].amountIn, sp, liq,
                        BPC.quoteV3Fee(hop.legs[i].pool, uint24(hop.legs[i].fee), dynFee, dyn),
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
        for (uint256 i; i < hops.length; ) { _orderLegs(hops[i]); unchecked { ++i; } }
        uint256 totalImpactBps;
        uint256 totalLegs;
        for (uint256 h; h < hops.length; ) {
            uint256 legs = hops[h].legs.length;
            uint256 hopImpact;
            for (uint256 i; i < legs; ) {
                uint256 d;
                Leg memory L = hops[h].legs[i];
                if (BPC.kindHas(L.kind, BPC.A_RESERVES)) {
                    (uint256 r0, uint256 r1) = BPC.getReserves(L.pool);
                    uint256 rIn = L.zeroForOne ? r0 : r1;
                    d = BPC.impactV2Bps(L.amountIn, rIn);
                } else if (BPC.kindHas(L.kind, BPC.A_CONC_POOL)) {
                    uint128 liq2 = BPC.getLiquidity(L.pool);
                    // See the twin note in _assembleRoute: EFFECTIVE fee, and
                    // v3StateAndDynFee replaces getSqrtPriceX96 without costing
                    // one extra staticcall.
                    (uint160 sp2, uint24 dynFee2, bool dyn2) = BPC.v3StateAndDynFee(L.pool);
                    d = BPC.impactV3Bps(
                            L.amountIn, sp2, liq2,
                            BPC.quoteV3Fee(L.pool, uint24(L.fee), dynFee2, dyn2),
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
            // SUMS ALL HOPS. It was pinned to `hops[0] + hops[1]` — with a
            // 3-hop route it dropped the third one SILENTLY, and estGas is the
            // number the UI shows the user before they sign.
            estGas:            _estGasTotal(hops),
            hasSurplus:        finalOut > floorOut,
            isV4Bundle:        false
        });
    }

    function _estGasTotal(Hop[] memory hops) private pure returns (uint256 g) {
        uint256 n = hops.length;
        for (uint256 i; i < n; ) { g += _estGas(hops[i]); unchecked { ++i; } }
    }

    function _estGas(Hop memory hop) private pure returns (uint256 g) {
        g = 30_000;
        uint256 n = hop.legs.length;
        for (uint256 i; i < n; ) {
            // The ladder lives in THETA_GAS (8 bits per kind, units of 5,000) and is read ONLY
            // here — hence a word separate from THETA_ATTR, which the Router, the Hub and the
            // Quoter carry. Native V4 pays the same unlock plus the JIT unwrap/wrap (~35k
            // estimated for WETH withdraw+deposit on warm slots; re-measure on the dry run).
            g += BPC.kindGasBase(hop.legs[i].kind);
            unchecked { ++i; }
        }
    }
}
