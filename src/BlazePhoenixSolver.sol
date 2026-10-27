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
import {BlazePhoenixMath, IHubMath} from "./BlazePhoenixMath.sol";

interface IHubR {
    function getActivePools(address tA, address tB) external view returns (PoolInfo[] memory);
    function discoverFor(address tA, address tB) external view returns (PoolInfo[] memory);
    function getPsi(address pool, address tA, address tB) external view returns (uint256);
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
    ///         but possible (cap < quote <= holdings) the capital stays —
    ///         cutting it there forced partial fills on pools that execute
    ///         fine (measured: a 43bps full fill halved) — and the promise is
    ///         the pool's own answer for the committed input, its book walked
    ///         read-only and held between the cap and the quote
    ///         (`_capacity`); a book that cannot be read keeps the cap. Every
    ///         topology ranks such a leg at the cap; the book is walked on the
    ///         winning topology's own build (`findBestRoutePlan`).
    uint16  internal constant MAX_CONC_DRAIN_BPS   = 3_000; // 30% of real holdings
    /// @dev `_capacity` modes: CUT, the first hop may cut its committed input; WALK, the
    ///      build asks the book of a capacity-held leg.
    uint256 private constant CUT  = 1;
    uint256 private constant WALK = 2;
    /// @notice ABSOLUTE ceiling on a route's MEASURED price impact. Above it the
    ///         Solver returns no route at all.
    /// @dev    The Iron-Law floor promises to retain 80% of a reference — but the
    ///         reference is the route's own quote, so a quote that has already
    ///         collapsed floors itself and the promise says nothing (I3: the bound
    ///         comes from the pool's curvature, NEVER from beta*quote). A pool with
    ///         a fair spot price and a dust-sized book prices a large order
    ///         truthfully, at ~99.9% impact, and every relative guard downstream
    ///         agrees with it. This is the one bound that is NOT relative to the
    ///         quote: past it, the route destroys more value than any floor can
    ///         return, and no honest fill operates there (a full-reserve order on
    ///         a healthy constant-product pair measures ~5,000 bps and stays).
    ///         HONEST LIMIT, stated where it is enforced: `_legImpactBps` measures
    ///         impact for the reserve and concentrated families and returns
    ///         `DEFAULT_IMPACT_BPS` for the V4 and stable arms, so this ceiling
    ///         binds exactly where impact is measured and is inert where it is
    ///         nominal. A guard keyed on a nominal number cannot fire; naming that
    ///         beats pretending the cover is uniform.
    uint16  internal constant MAX_ROUTE_IMPACT_BPS = 9_000; // 90% measured impact

    error SolverE(uint16 code);

    IHubR public immutable hub;
    /// The one Gate whose wrappers (kind 9) this planner seats (owner's decision 2026-10-22:
    /// gated venues at the automatic door). Zero = no Gate: Core.gatedOf gives no row for it.
    address public immutable gate;

    constructor(address hub_, address gate_) {
        require(hub_ != address(0), "Solver:hub0");
        // G2 (D10): the library this Solver delegatecalls is the one it was compiled against.
        // The linker sets its address (a PUSH20 at every call site: no storage, no setter), and
        // its code is pinned here, once, at deploy. A library with no state-changing function
        // carries no deploy-address guard, and it links no other library (the Core it uses is
        // all internal), so its deployed code is exactly `runtimeCode`: the pin covers the
        // Math's own code. A wrong or empty address, or any other build, refuses to deploy.
        if (address(BlazePhoenixMath).codehash != keccak256(type(BlazePhoenixMath).runtimeCode)) revert SolverE(6);
        hub = IHubR(hub_);
        gate = gate_;
    }

    // =========================================================================
    //  PUBLIC API
    // =========================================================================

    /// @notice Find the U-maximising route plan for an exact-input swap.
    /// @dev    Enumerates direct + via-bridge[0] + via-bridge[1] topologies
    ///         in parallel, returns max-U as `best` and second-best as `fallback`.
    // slither-disable-next-line incorrect-return
    function findBestRoutePlan(address tIn, address tOut, uint256 amountIn)
        external view returns (RoutePlan memory plan)
    {
        if (tIn == address(0) || tOut == address(0) || tIn == tOut || amountIn == 0)
            revert SolverE(4);

        Melhores memory m;
        // The bridges are read once; the slots above the counter are ALWAYS address(0) -
        // `addBridge` fills in sequence and `removeBridge` compacts and zeroes the leftover -
        // so no `bridgeCount()` is needed (that traversal was removed deliberately: -1,581 gas
        // per solve) and the guards in `_planTopology` test `!= address(0)`.
        //
        // THE THREE READS ARE THE HUB'S `MAX_BRIDGE_ROUTES`, WRITTEN HERE IN CODE. It is this
        // number - not MAX_BRIDGES - that decides across how many bridges we route, and the
        // difference between the two was a silent asymmetry: a bridge with admission rights and
        // +25% fitness that could never be a hop. See the Hub's MAX_BRIDGE_ROUTES note and
        // test/RoutableBridgeAsymmetry.t.sol, pinning both sides. Whoever adds a read here MUST
        // raise the constant over there - and vice versa: `hub.bridge(i)` past the Hub's array
        // reverts with Panic 0x32.
        address[4] memory bs = [hub.bridge(0), hub.bridge(1), hub.bridge(2), address(0)];
        // Every topology is judged on the route BUILT for it, and on one basis: a
        // capacity-held leg ranks at its cap (`_capacity`). `bk` remembers which one took
        // the lead.
        uint256 bk;
        if (msg.sender == address(this)) {
            // The rebuild of `_walkOnItsOwnBudget`: the build `bk` once more with WALK, ranked
            // against the leader's rank at the cap. Not above it: empty revert, the cap plan stands.
            uint256 u;
            assembly ("memory-safe") { bk := calldataload(0x64) u := calldataload(0x84) }
            m.bestU = u;
            m.walk = WALK;
            _planTopology(m, bk, bs, tIn, tOut, amountIn);
            if (m.bestU == u) revert();
            plan.best = m.bestR;
            return plan;
        }
        for (uint256 k; k < TOPOLOGIES; ) {
            uint256 u0 = m.bestU;
            _planTopology(m, k, bs, tIn, tOut, amountIn);
            if (m.bestU != u0) bk = k;
            unchecked { ++k; }
        }
        if (m.bestU == 0) revert SolverE(5);
        plan.fallbackRoute = m.secR;
        plan.hasFallback = m.secU > 0;

        plan.best = m.bestR;

        // THE CAPACITY WALK RUNS ON ONE TOPOLOGY PER SOLVE, the winner's, ON ITS OWN BUDGET.
        // When a capacity-held candidate of the leading build could pay more than what that
        // build chose (`_buildHop`'s `held`), the topology is built once more with WALK, so its
        // capacity-held candidates are ranked and promised what their own books pay. A walk
        // reads up to sixteen stretches cold, and what a stretch costs is the venue's choice
        // (GAS_CAP per read), so the rebuild runs in a static self-call on exactly WALK_GAS:
        // the plan depends on the state, never on the gas the caller brought. A rebuild that
        // completes and ranks above the build at the cap leads; otherwise the plan built at
        // the cap stands. The fallback stays the runner-up read above. A solve that cannot
        // hand the walk its whole budget stops with empty revert data (out of gas, RouterE(17)
        // at the automatic door) - never a different plan. The walk's assembly return is this
        // external function's own return (its last statement), so nothing is skipped.
        if (m.bestHeld) _walkOnItsOwnBudget(plan, bk, m.bestU);
    }

    /// @dev The gas the rebuild of `findBestRoutePlan` runs on. Fixed: the walk's outcome is a
    ///      function of the state alone (test/EntryBSolveBudget.t.sol R1). Sized so a
    ///      rebuild over every held book a build seats fits, on the grids of
    ///      test/CapacityWalkBudget.t.sol and on a live book
    ///      (test/fork/CapacityPromiseAsksTheVenue.t.sol).
    uint256 private constant WALK_GAS = 2_500_000;

    /// @dev The rebuild, as a static self-call of `findBestRoutePlan` carrying `bk` and the rank
    ///      `u` to beat past the three arguments (only the Solver itself is answered on them).
    ///      Its answer is spliced in as `plan.best` without decoding: the returned encoding is
    ///      [0x20][0x60][off fallback][0][best], and only the fallback blob and its flag are
    ///      ours. On any failure of the self-call the plan built at the cap is returned.
    function _walkOnItsOwnBudget(RoutePlan memory plan, uint256 bk, uint256 u) private view {
        bytes memory f = abi.encode(plan.fallbackRoute);
        bool hf = plan.hasFallback;
        assembly ("memory-safe") {
            let p := mload(0x40)
            calldatacopy(p, 0, 0x64)                    // this solve's own call: the one entry, its three words
            mstore(add(p, 0x64), bk)
            mstore(add(p, 0x84), u)
            // The whole WALK_GAS reaches the self-call or the solve stops (EIP-150 keeps 1/64).
            if lt(gas(), add(div(mul(WALK_GAS, 64), 63), 20000)) { revert(0, 0) }
            if staticcall(WALK_GAS, address(), p, 0xa4, 0, 0) {
                returndatacopy(p, 0x40, 0x20)
                let n := add(mload(p), 0x20)            // the bytes up to the end of `best`
                returndatacopy(p, 0, n)
                mstore(add(p, 0x60), hf)
                let l := sub(mload(f), 0x20)
                mcopy(add(p, n), add(f, 0x40), l)
                return(p, add(n, l))
            }
        }
    }

    /// @dev The topologies, in the order they are judged (a tie keeps the earlier one):
    ///      0 direct; 1-3 one bridge, tIn -> bs[k-1] -> tOut; 4-12 THREE HOPS over TWO
    ///      bridges, tIn -> bs[i] -> bs[j] -> tOut with i = (k-4)/3, j = (k-4)%3, i != j.
    ///      Bridge topologies only ADD candidates to the judgement: a direct route still wins
    ///      whenever it delivers more, because the comparison is by the output built and not
    ///      by topology depth.
    uint256 private constant TOPOLOGIES = 13;

    function _planTopology(
        Melhores memory m, uint256 k, address[4] memory bs, address tIn, address tOut, uint256 amountIn
    ) private view {
        if (k == 0) return _planDirect(m, tIn, tOut, amountIn);
        (uint256 i, uint256 j) = k < 4 ? (k - 1, 3) : ((k - 4) / 3, (k - 4) % 3);
        address x = bs[i];
        address y = bs[j];
        if (x == address(0) || x == tIn || x == tOut) return;
        if (j != 3 && (j == i || y == address(0) || y == tIn || y == tOut || y == x)) return;
        _planViaBridges(m, tIn, tOut, amountIn, x, y);
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
        uint256    walk;   // `_capacity` mode: WALK on the winner's own build
        bool       bestHeld;   // the leader's build left a capacity-held candidate unsettled
        uint256    lists;  // the solve's candidate lists, one per ordered pair (`_candsOf`)
    }

    /// @dev S2 (V4 fragmentation, reported by Seavia Resources): the judgement is by `u`, the
    ///      route's RANKING figure - `totalOut` plus `up`, what the deep walks resolved above the
    ///      sixteen-stretch promise (`_buildHop`; on a bridge route the rank carried stage by
    ///      stage, `_planViaBridges`). On an untruncated route the two are the same number.
    ///      `totalOut` stays the promise in the plan; `u` only orders. `held` travels with the
    ///      route it was built for (`_buildHop`).
    function _considera(Melhores memory m, Route memory r, uint256 up, bool held) private pure {
        uint256 u = r.totalOut;
        if (u == 0) return;   // an assembly that refused the route
        u += up;
        if (u > m.bestU) { m.secU = m.bestU; m.secR = m.bestR; m.bestU = u; m.bestR = r; m.bestHeld = held; }
        else if (u > m.secU) { m.secU = u; m.secR = r; }
    }

    // =========================================================================
    //  TOPOLOGY PLANNERS
    // =========================================================================

    function _planDirect(Melhores memory m, address tIn, address tOut, uint256 amountIn)
        private view
    {
        PoolInfo[] memory cands = _candsOf(m, tIn, tOut);
        if (cands.length == 0) return;
        // PER-HOP CEILING, not the global one: a direct route is ONE hop, and
        // the 4-legs-per-hop limit applies to it like to any other. It used to
        // use MAX_LEGS and could spend the entire budget on a single hop.
        (Hop memory hop, uint256 up, bool held) = _buildHop(tIn, tOut, amountIn, cands, MAX_LEGS_PER_STAGE, m.walk | CUT);
        if (hop.expectedOut == 0) return;
        // One assembly for every route, one hop or three: one producer of the impact and the floor.
        Hop[] memory hops = new Hop[](1);
        hops[0] = hop;
        Route memory route = _assembleRouteMulti(hops, tIn, tOut, amountIn, hop.expectedOut);
        _considera(m, route, up, held);
    }

    /// @notice BRIDGE ROUTES: tIn -> bA -> tOut, or THREE HOPS over TWO bridges
    ///         (tIn -> bA -> bB -> tOut) when `bB` is set. One planner for both.
    ///
    /// @dev WHY THREE HOPS EXIST, and why they do not make routes longer by default.
    ///      `_considera` judges the route BUILT and measured for each topology. A 3-hop route
    ///      only wins if it delivers more, and a direct route still wins whenever it is the
    ///      best. Adding the topology does NOT lengthen routes: it adds a candidate to the
    ///      judgement that already exists.
    ///
    ///      THE COST FALLS WHERE IT DOES NOT MATTER. It is three more `_buildHop` per bridge
    ///      pair, and that is paid in the SOLVE - which at entry point A runs over `eth_call`,
    ///      for free. At entry point B it is paid in gas, so this topology only pays off where
    ///      data dominates. See the corpus (the four entry points).
    ///
    ///      STAGES ARE SEPARATE HOPS. The Router executes each stage, measures the balance it
    ///      really produced and rescales the next stage's legs to it, so a stage always spends
    ///      exactly what the one before produced, never a stale quoted figure.
    ///
    ///      LEG BUDGET. `MAX_LEGS` in total, `MAX_LEGS_PER_STAGE` per stage, and every stage
    ///      leaves at least one leg for each stage after it. Stage A may cut on the input (it
    ///      executes as it was built); the later stages may NOT - the Router rescales them
    ///      against the REAL balance of the stage before, and a cut leg would be scaled
    ///      straight back up, past its cut promise and into a per-leg floor revert (observed:
    ///      a 2-hop route that filled at 74bps floor-rejected once its stage-B leg was cut).
    ///
    ///      S2 (V4 fragmentation) ON THE EARLIER STAGES. Each stage is built on the PROMISE of
    ///      the stage before, which dust can cut. `r` carries the RANK along the path instead:
    ///      when a stage's deep walk resolved above its promise, the next stage is quoted again
    ///      on that rank, for the judgement only. A stage's rank is the larger of its two lower
    ///      bounds (its own deep walk on the promise, and the quote on the rank before), so it
    ///      never exceeds what the stage delivers on what the stage before really produced. The
    ///      legs, the promise and the floor stay as built.
    function _planViaBridges(
        Melhores memory m, address tIn, address tOut, uint256 amountIn, address bA, address bB
    ) private view {
        uint256 n = bB == address(0) ? 2 : 3;
        address[4] memory path = [tIn, bA, bB, tOut];
        if (n == 2) path[2] = tOut;
        Hop[] memory hops = new Hop[](n);
        uint256 used;           // legs spent by the stages built so far
        uint256 p = amountIn;   // the PROMISE carried into the stage
        uint256 r;              // its RANK (0 into stage A: the input is exact there)
        bool held;              // any pass of any stage left a capacity-held candidate unsettled
        for (uint256 i; i < n; ) {
            uint256 room = MAX_LEGS + i + 1 - n;   // one leg left for every stage after this one
            if (used >= room) return;
            uint256 budget = room - used;
            if (budget > MAX_LEGS_PER_STAGE) budget = MAX_LEGS_PER_STAGE;
            PoolInfo[] memory cands = _candsOf(m, path[i], path[i + 1]);
            if (cands.length == 0) return;
            // Pass 0 builds the stage on the promise. Pass 1 runs only when the stage before
            // ranked above its promise: it quotes this stage again on that rank, for the
            // judgement alone. The stage's rank is the larger of the two lower bounds.
            uint256 rk;
            for (uint256 k; ; ) {
                (Hop memory h, uint256 up, bool hh) = _buildHop(path[i], path[i + 1], k == 0 ? p : r, cands, uint8(budget), i == 0 ? m.walk | CUT : m.walk);
                if (hh) held = true;
                if (k == 0) {
                    if (h.expectedOut == 0 || h.legs.length == 0) return;
                    hops[i] = h;
                    used += h.legs.length;
                }
                up += h.expectedOut;
                if (up > rk) rk = up;
                if (k != 0 || r <= p) break;
                k = 1;
            }
            r = rk;
            p = hops[i].expectedOut;
            unchecked { ++i; }
        }
        if (used > MAX_LEGS) return;
        Route memory route = _assembleRouteMulti(hops, tIn, tOut, amountIn, p);
        _considera(m, route, r - p, held);
    }

    // =========================================================================
    //  HOP CONSTRUCTION — depth-weighted allocation
    // =========================================================================

    /// @dev `held`: a capacity-held candidate ranked at its cap could still change what this
    ///      hop chose - a leg of the split held at the cap, or a held single whose quote is
    ///      above what the gate asks of it. Such a build is settled by the walk
    ///      (`findBestRoutePlan`).
    function _buildHop(
        address tIn, address tOut, uint256 amountIn,
        PoolInfo[] memory cands, uint8 budget, uint256 mode
    ) private view returns (Hop memory hop, uint256 up, bool held) {
        uint256 n = cands.length;
        if (n == 0) return (hop, 0, false);
        // No blind pre-trim: every candidate is probed (rate + depth + real
        // holdings), and the cut to `budget` happens after weighting — see the
        // FUNNEL CUT below. Discovery order can no longer starve a deep venue.
        // A lone candidate is quoted once, before the hoisted read below: 0, 0 lets that quote
        // read the decimals itself.
        if (n == 1) { uint256 f; (hop, up, , f) = _singleLeg(tIn, tOut, amountIn, cands[0], mode, 0, 0, 0); return (hop, up, f != 0); }

        // =========================================================================
        //  STAGE 1 — MARGINAL-RATE MEDIAN FILTER  (single probe pass)
        //
        //  We quote each candidate with a PROBE size (= amountIn / 100) that
        //  is small enough that each pool's marginal rate is essentially its
        //  spot price (negligible impact). Then we compute the median of
        //  those marginal rates and filter pools whose marginal rate
        //  deviates from the base by more than MEDIAN_FILTER_BPS (±5%, in BlazePhoenixMath).
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
        // once per pair, for every quote of the hop: the probes, the split's
        // legs and the gate's full-size singles (test/DecimalsReadOncePerHop.t.sol).
        // Encoded +1 (see QuoteCtx.decIn1): 0 would mean "not filled" and there
        // are tokens with genuinely 0 decimals.
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
        // TODAY's anchor is `BlazePhoenixMath._depthWeightedMedian(rates, depths, n)`, and it uses
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
            // S2: the probe rate is a RANKING figure, so it reads the deep rank (bar 0), not the
            // sixteen-stretch promise that dust inside the probe's reach can cut.
            (, uint256 d, uint256 o, ) = _quoteWithDepth(cands[i], tIn, probe, dIn1_, dOt1_, 0);
            if (o > 0) {
                rates[i]  = BPC.mulDiv(o, 1e18, probe);
                depths[i] = d == 0 ? 1 : d;   // matches the legacy "if (d==0) d=1"
                // V3/BP-18 (CRITICAL, devil's-advocate): a V4 pool's address is a
                // codeless truncated poolId whose balanceOf ANYONE can fund with
                // 1 wei — reading the capital anchor from it lets a dust transfer
                // forge maxBal>0 and steer the band. V4 custodies tokens in the
                // PoolManager singleton, so its true per-pool balance is 0: force
                // it, sourcing the capital anchor only from real token-custodying
                // kinds (also keeps BlazePhoenixMath._weights' "V4 reports balance 0" honest).
                balsOut[i] = BPC.kindHasAny(cands[i].kind, BPC.A_CONC_SING)
                    ? 0
                    : BPC.balanceOf(tOut, cands[i].pool);
                // MASS THAT COSTS NOTHING IS NOT MASS (PROV-01). For pair-shaped
                // kinds the depth above is the pool's own `getReserves`, and a
                // synthetic pair declares any number: against three funded honest
                // pools of 400k each, a pair holding ONE token of each side and
                // declaring 3e30 took the whole route at half the fair price
                // (test/FrozenAtWriteProbes.t.sol). Cap the declared depth by what
                // the pool physically holds of tokenOut. On an honest pair the cap
                // is inert — reserves never exceed balances (sync copies balances
                // into reserves; a donation only raises the balance) — and a
                // donation cannot lift it above the reserves, so this is NOT the
                // anchor T2 removed: it can only shrink a claim, never grow one.
                // `balsOut` is the quantity already read for the capacity ceiling,
                // so the cap costs no extra call.
                //
                // THE CONCENTRATED FAMILY TOO (ninth wave, Binod Bk). There the
                // depth is `depthFromL18(liquidity(), slot0())` - the contract's own
                // word about itself - and a V3-shaped contract holding nothing that
                // declared 1e33 took the whole order from a pool holding 1,000,000
                // a side, then set the floor its own fill was judged against. The
                // cap binds on honest concentrated pools as well, because their
                // virtual depth exceeds what they hold (3.327e18 against 1.600e18
                // measured at the capacity clamp below): they now weigh by the mass
                // they hold, the rule the registry writer already applies. A
                // donation can lift a concentrated pool's capped weight at most back
                // to its declared depth - the weight it carried before this cap - so
                // it buys no share the declaration did not already claim.
                if (BPC.kindHasAny(cands[i].kind, BPC.A_RESERVES | BPC.A_CONC_POOL)) {
                    uint256 physical = BPC.to18(balsOut[i], dOt1_ - 1);
                    if (physical < depths[i]) depths[i] = physical == 0 ? 1 : physical;
                }
            }
            unchecked { ++i; }
        }

        // THE HOP'S ARITHMETIC LIVES IN `BlazePhoenixMath` (D10, owner's decision 2026-10-26).
        // The median and the band, the compaction of the survivors, the weights, the funnel cut
        // and the seat of the remainder were moved there unchanged except for their exits and
        // the `hub` argument, so this contract keeps room under its size ceiling. ONE
        // delegatecall per hop, static inside the solve's
        // staticcall (EIP-214). The library works on its own ABI copy of the arrays and answers
        // with `map`: position i now holds the candidate that stood at map[i]. The hop replays
        // the map on its own arrays, so `cands` is permuted in place exactly as before (the
        // second pass of `_planViaBridges` reads it again).
        uint256 nBand;
        uint256 sumPsi;
        uint256[] memory psis;
        {
            uint256 nKept;
            uint256[] memory map;
            uint256 top;
            assembly ("memory-safe") { top := mload(0x40) }
            (nKept, n, sumPsi, map, psis) =
                BlazePhoenixMath.select(rates, depths, balsOut, cands, tIn, IHubMath(address(hub)), budget);
            // G3: the answer must be exactly the canonical encoding of what was decoded. The ABI
            // decoder accepts a longer returndata, so the length is checked against the encoding
            // of the decoded values themselves.
            uint256 rds;
            assembly ("memory-safe") { rds := returndatasize() }
            if (rds != abi.encode(nKept, n, sumPsi, map, psis).length) revert SolverE(7);
            PoolInfo[] memory c0 = new PoolInfo[](cands.length);
            uint256[] memory b0 = new uint256[](cands.length);
            for (uint256 i; i < cands.length; ) { c0[i] = cands[i]; b0[i] = balsOut[i]; unchecked { ++i; } }
            for (uint256 i; i < cands.length; ) { cands[i] = c0[map[i]]; balsOut[i] = b0[map[i]]; unchecked { ++i; } }
            // Past the replay only `psis` is live: the call's buffers, `map` and the copies are
            // not. `psis` moves down to where this block began and the rest is released, so the
            // boundary does not grow the solve's memory hop after hop.
            assembly ("memory-safe") {
                let l := shl(5, add(mload(psis), 1))
                mcopy(top, psis, l)
                psis := top
                mstore(0x40, add(top, l))
            }
            if (nKept == 0) return (hop, 0, false);
            if (nKept == 1) { uint256 f; (hop, up, , f) = _singleLeg(tIn, tOut, amountIn, cands[0], mode, 0, dIn1_, dOt1_); return (hop, up, f != 0); }
            nBand = nKept;
        }
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
            // S2: bar 0 resolves a truncated V4 walk; `rL - outL` is what it found above the
            // promise, summed into the hop's rank (`up`) at once - only a V4 leg has any, and a
            // V4 leg is dropped below only when `outL` is zero. `outL` stays the promise.
            (uint256 outL, uint256 rL, ) = _quote(cands[i], tIn, share, 0, dIn1_, dOt1_);
            if (outL != 0) up += rL - outL;
            // A reserve-shaped pool can never pay more than it holds (out < reserveOut <=
            // balance on an honest pair), so a promise above its tokenOut holdings comes
            // from forged reserves: the leg is dropped (balsOut is already read above).
            if (BPC.kindHas(cands[i].kind, BPC.A_RESERVES) && outL > balsOut[i]) outL = 0;
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
            //
            // ZERO HOLDINGS ARE ZERO CAPACITY. This clamp used to skip a book
            // holding none of tokenOut, on the V4 reasoning that a pool's own
            // balance can be zero while the singleton pays. V4 never reaches this
            // branch - it is A_CONC_SING, and its `balsOut` is forced to zero above
            // - and a V3/Algebra pool custodies its own tokens: holding none, it
            // can pay none. Skipping the clamp handed a V3-shaped contract with no
            // capital its whole declared promise (ninth wave, Binod Bk). A zero
            // cap now drops the leg, and the freed input flows on like any cut.
            // The two tiers are `_capacity`'s, shared with the single-leg path. A cut
            // share frees input that flows to the LAST leg via the remainder mechanism
            // (re-clamped there if that leg is also phantom-thin), and whatever no
            // surviving venue can absorb stays unrouted — the Router's residual sweep
            // returns it to the caller.
            if (BPC.kindHas(cands[i].kind, BPC.A_CONC_POOL)) {
                uint256 keep;
                uint256 f;
                (keep, outL, f) = _capacity(cands[i], tIn, share, outL, balsOut[i], mode);
                if (f != 0) held = true;
                allocated -= share - keep;
                share = keep;
                if (share == 0 || outL == 0) { unchecked { ++i; } continue; }
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
        if (legCount == 0) return (hop, 0, false);

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
        // unless it beats the best survivor's single-leg full-size quote
        // by >= MIN_SPLIT_IMPROVEMENT_PPM (ppm), collapse to that single leg. Kills
        // micro-splits whose marginal output gain is smaller than the real
        // gas cost of the extra legs. The single leg it must beat is the best
        // survivor at full size (post FUNNEL CUT), one full-size quote each.
        if (legCount >= 2) {
            // `cands[0]` is the highest WEIGHT, that is the DEEPEST - never the best priced -
            // and `argmax(rates)` favours SHALLOW pools, because the rates come from a small
            // probe and are MARGINAL prices. Neither heuristic names the best single leg at
            // full size, so neither is asked: every survivor is quoted at full size below.
            // `n`, NOT `cands.length`. The survivors are compacted IN
            // PLACE (see the compaction block above) but the memory array
            // keeps its ORIGINAL length: positions >= n are junk from
            // candidates the median band REJECTED or the funnel CUT.
            // Walking `cands.length` resurrected them as the fallback single
            // leg, voiding both filters - caught by
            // test_UmaPoolFundaNaoCapturaABanda, which exists exactly to
            // stop a deep badly-priced pool from entering the route.
            // EVERY SURVIVOR, NOT TWO REPRESENTATIVES (ninth wave, Brian Wahyu). The deepest
            // and the best marginal rate are two heuristics for "the best single leg at full
            // size", and with three or more survivors that leg can be neither: a pool of middle
            // depth and middle price. Measured: a split that beat both representatives kept an
            // order 1.48% below the middle pool alone (test/SplitGateSeesEverySurvivor.t.sol).
            // EVERY SURVIVOR OF THE BAND, NOT ONLY OF THE CUT (AnonSecure, bug bounty; found
            // independently by our own economic review). The cut keeps the top `budget` by WEIGHT,
            // which is depth; for a small order the best single leg is the best PRICED pool, which
            // need not be deep, so MR-R1 ("split never worse than the best single pool") holds only
            // if the gate measures every pool the band let through. The dropped survivors sit at
            // [budget, nBand) - the cut permutes, it does not compact - so they are still here.
            // S2 (Seavia Resources): the singles are compared by RANK, not by the sixteen-stretch
            // promise - a fragmented book must not lose on a figure an outsider can cut. Each rival
            // walks deep only while it could still beat the best so far (`bar = sR`). The
            // collapse needs the judgement SETTLED: `hMax`, the highest ceiling among the singles
            // (the chosen one included), must not exceed the chosen rank - no single can still
            // beat it, and it is itself exact. A quote still truncated after the deep walk thus
            // keeps the split (the honest pool kept by weight) instead of collapsing on a guess;
            // a book that simply ends (a mirror pool with dust and nothing beyond) has a low
            // ceiling and settles. Untruncated, `hMax == sR` and `up == 0`: the old gate exactly.
            // One call site for every single, the first included (its bar is the empty `sR`, 0).
            Hop memory single;
            uint256 sR;
            uint256 hMax;
            uint256 hF;   // the highest quote among the capacity-held singles ranked at the cap
            for (uint256 i; i < nBand; ) {
                (Hop memory alt, uint256 aR, uint256 aH, uint256 aF) = _singleLeg(tIn, tOut, amountIn, cands[i], mode, sR, dIn1_, dOt1_);
                aR += alt.expectedOut;
                aH += alt.expectedOut;
                if (aH > hMax) hMax = aH;
                if (aF > hF) hF = aF;
                if (aR > sR) { single = alt; sR = aR; }   // an empty single ranks 0
                unchecked { ++i; }
            }
            if (
                hMax <= sR &&   // no single chosen: sR == 0 and the bound below fails
                totalOut + up < BPC.mulDiv(
                    sR, 1_000_000 + MIN_SPLIT_IMPROVEMENT_PPM, 1_000_000
                )
            ) {
                if (hF > sR) held = true;
                return (single, sR - single.expectedOut, held);
            }
            // A held single whose own book could pay more than the split leaves this choice
            // unsettled at the cap, as a held leg of the split does. (One that could pay at
            // most the split would only take the hop for its gas, paying less.)
            if (hF > totalOut + up) held = true;
        }
        hop = Hop({
            tokenIn: tIn, tokenOut: tOut,
            amountIn: committedIn, expectedOut: totalOut, legs: legs
        });
    }

    /// @dev THE FUNNEL RANKS ON WHAT A POOL HOLDS NOW (Seavia Resources, bug bounty). A row's
    ///      depth bucket is measured at a registry door inside a transaction its caller
    ///      controls and persisted, so the cache records an instant. When the funnel has to cut,
    ///      each row's bucket is capped by what the registry's one depth producer
    ///      (`Core.registryDepth18`) reads now: psi is vitality times 2^bucket, so lowering the
    ///      bucket from `b` to `lb` divides the rank by 2^(b - lb). A seat in the funnel costs
    ///      mass kept in the pool, which is mass a trade can take. Read here rather than in the
    ///      Hub: the ranking is the Solver's, and `PoolInfo` already names every V4 key field.
    ///
    ///      IT ALSO NAMES THE DEEPEST ROW (bounty #82, Ronksok Gaming; root in mohaseenbasha
    ///      dex-12). The cap above only LOWERS a score; it cannot stop a score that is honest
    ///      about depth and cheap about activity. psi multiplies the swap count, which costs one
    ///      dust swap per unit, by 2^bucket, where a whole DECADE of mass buys one doubling: eight
    ///      pools holding 1/100 of the honest venue's mass out-rank it after a handful of dust
    ///      swaps each, take all eight seats, and the honest venue is cut before it is quoted.
    ///      No cap on the count closes that (at cap c >= 2 a pool one decade shallower still
    ///      wins), so the funnel instead guarantees one seat to the row holding the most mass
    ///      NOW, measured by the same producer, and `_seatDeepest` gives it that seat. Every row
    ///      is measured here, not only the bucketed ones: a discovered row has no slot, and it
    ///      is exactly the one the score cannot see.
    function _capByLiveDepth(PoolInfo[] memory rows, uint256[] memory ps, uint256 n)
        private view returns (PoolInfo memory deepest)
    {
        address mgr;
        uint256 most;
        for (uint256 i; i < n; ) {
            PoolInfo memory p = rows[i];
            bytes32 pid;
            if (BPC.kindHas(p.kind, BPC.A_CONC_SING)) {
                if (mgr == address(0)) mgr = hub.v4PoolManager();
                (address c0, address c1) = BPC.v4LegCurrencies(p.kind, p.token0, p.token1, true);
                pid = BPC.computeV4PoolId(c0, c1, p.fee, p.tickSpacing, p.hooks);
            }
            uint256 d = BPC.registryDepth18(p.pool, p.kind, p.token0, p.token1, mgr, pid);
            // Strict: an equal mass does not displace the earlier row, so the choice is a
            // function of the measured set and the merge order only.
            if (d > most) { most = d; deepest = p; }
            uint8 b = BPC.decodeBucket(hub.getSlot(hub.keyOf(p.pool, p.token0, p.token1)));
            if (b != 0) {
                uint8 lb = BPC.depthBucket(d);
                if (lb < b) ps[i] >>= (b - lb);
            }
            unchecked { ++i; }
        }
    }

    /// @dev THE DEEPEST MEASURED ROW IS ALWAYS QUOTED (bounty #82). If the score order left it
    ///      outside the funnel, it takes the LAST seat — the row the score ranked weakest of
    ///      those kept — and nothing else moves. If it is already seated, or the funnel did not
    ///      cut (`deep.pool == 0`), the funnel is exactly what the score chose. A seat is a
    ///      chance to be QUOTED, not a share: `_buildHop` still prices every seated row, so an
    ///      honest venue seated here wins the order only by paying more. To take this seat an
    ///      attacker must hold more mass than the deepest venue, in a pool whose price a trade
    ///      (or an arbitrageur) can then take.
    function _seatDeepest(PoolInfo[] memory out, PoolInfo memory deep) private pure {
        uint256 k = out.length;
        if (k == 0 || deep.pool == address(0)) return;
        for (uint256 i; i < k; ) {
            if (out[i].pool == deep.pool) return;
            unchecked { ++i; }
        }
        out[k - 1] = deep;
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
    ///      it. I tried three shapes before this one and all three blew it. (Since D10,
    ///      2026-10-26, `_cutByWeight` and the rest of the hop's arithmetic live in
    ///      `BlazePhoenixMath`; the reasoning below still holds.)
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

    /// @dev The capacity clamp of a concentrated leg (MAX_CONC_DRAIN_BPS), one rule for the
    ///      split and the single-leg path: `quote` for `amountIn`, against `held` of tokenOut.
    ///      Returns the input committed, its promise and, for a leg ranked at the cap without
    ///      WALK, the quote its book may still pay up to (zero otherwise: `_buildHop`'s `held`).
    ///      `mode`: CUT on the first hop, WALK on the winning topology's own build
    ///      (`findBestRoutePlan`).
    ///      PHANTOM (quote > the pool's WHOLE holdings), on every hop: physically impossible
    ///      (measured on a Base stable pair: 89% of a 10k order sent into a pool holding 6.2k
    ///      of tokenOut — a 27% one-way loss walking its tick ladder and 7M gas crossing it,
    ///      masked as "surplus" because the floors derive from the crushed promise). The
    ///      promise is the cap; on the first hop (CUT) the committed input is cut in the
    ///      promise's ratio too. A later hop keeps its input, because the Router rescales it
    ///      to what the stage before produced.
    ///      Aggressive but PHYSICALLY POSSIBLE (cap < quote <= holdings): the leg keeps its
    ///      whole input — cutting it forced partial fills on healthy pools (measured: a 43bps
    ///      full fill degraded to a half-filled order) — and every topology ranks it at the
    ///      cap. With WALK it is promised the pool's own answer for that input: its book
    ///      walked read-only by `Core.v4WalkOut` (a zero poolId walks a V3-shaped pool through
    ///      its own getters, at its own fee and spacing), held between the cap and the
    ///      single-tick quote. So no promise passes the pool's holdings, on any hop (the cap
    ///      below them, or P <= quote <= held), and a book that does not answer keeps the cap. The walk
    ///      reads every stretch it crosses cold, so it runs on one topology per solve, never per
    ///      ranked candidate (SOLVE_GAS; test/CapacityWalkBudget.t.sol).
    function _capacity(PoolInfo memory c, address tIn, uint256 amountIn, uint256 quote, uint256 held, uint256 mode)
        private view returns (uint256, uint256, uint256)
    {
        uint256 cap = BPC.mulDiv(held, MAX_CONC_DRAIN_BPS, BPC.BPS);
        if (quote > held) return (mode & CUT == 0 ? amountIn : BPC.mulDiv(amountIn, cap, quote), cap, 0);
        if (quote <= cap) return (amountIn, quote, 0);
        if (mode & WALK == 0) return (amountIn, cap, quote);
        uint256 w = BPC.v4WalkOut(c.pool, bytes32(0), amountIn, 0, 0, c.token0 == tIn);
        return (amountIn, w < cap ? cap : (w > quote ? quote : w), 0);
    }

    function _singleLeg(
        address tIn, address tOut, uint256 amountIn, PoolInfo memory cand, uint256 mode, uint256 bar,
        uint8 dIn1, uint8 dOt1
    ) private view returns (Hop memory hop, uint256 up, uint256 hi, uint256 f) {
        // S2: `up` is the rank above the promise and `hi` the ceiling above it (deep V4 walk,
        // gated by `bar`, `v4WalkRank`; both zero elsewhere). They only order, never promise.
        // `f` is `_capacity`'s third answer: the quote of a leg ranked at its cap.
        // `dIn1`, `dOt1`: the hop's hoisted decimals, as in `_quoteWithDepth`.
        uint256 out_;
        (out_, up, hi) = _quote(cand, tIn, amountIn, bar, dIn1, dOt1);
        up -= out_;
        hi -= out_;
        if (out_ == 0) return (hop, 0, 0, 0);
        // Same rule as the split path: a reserve-shaped promise above the pool's tokenOut
        // holdings comes from forged reserves, so the candidate is dropped, not clamped
        // (bounty #43, babayagaleet).
        if (BPC.kindHas(cand.kind, BPC.A_RESERVES) && out_ > BPC.balanceOf(tOut, cand.pool)) return (hop, 0, 0, 0);
        // Capacity clamp — same two-tier doctrine as the split path (see
        // MAX_CONC_DRAIN_BPS). Quote > the pool's WHOLE holdings: physically
        // impossible, so the committed input is cut in the promise's ratio and
        // the route executes a small honest fill (the Router sweeps the
        // uncommitted remainder back to the caller) instead of walking the
        // pool's tick ladder at a collapsing marginal price. Aggressive but
        // possible (cap < quote <= holdings): full commit, the promise the pool's
        // own book for it, never below the cap (`_capacity`).
        // Zero holdings are zero capacity here as on the split path, and for the
        // same reason: this is the second consumer of the same question, and the
        // split gate collapses a route onto the best single leg, so a skip here
        // alone was enough to hand an empty book the whole order.
        uint256 legIn = amountIn;
        if (BPC.kindHas(cand.kind, BPC.A_CONC_POOL)) {
            (legIn, out_, f) = _capacity(cand, tIn, amountIn, out_, BPC.balanceOf(tOut, cand.pool), mode);
            if (legIn == 0 || out_ == 0) return (hop, 0, 0, 0);
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
        PoolInfo memory cand, address tIn, uint256 amt, uint8 dIn1, uint8 dOt1, uint256 bar
    ) private view returns (uint256 out, uint256 depth, uint256 rank, uint256 hi) {
        bool zfo = cand.token0 == tIn;
        // Native V4: PoolInfo carries the pair in WETH-canonical form with token0 = the
        // wrapped-native side (the registry's orientation contract - see Hub._readPoolInfo).
        // The pool's REAL currency0 is address(0): BPC.v4LegCurrencies puts it on whichever
        // side is token0 before the quote sorts the pair, so universalQuote derives the native
        // poolId. zeroForOne needs no branch: token0 == tIn already means "input is
        // currency0" under this orientation. Every other kind passes through untouched.
        (address qIn, address other) = BPC.v4LegCurrencies(cand.kind, tIn, zfo ? cand.token1 : cand.token0, zfo);
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
            // A Gate wrapper (kind 9) is priced by Core.gateQuote against this Hub's admission.
            hub:         address(hub),
            // NO TERNARY, and the reason matters. The first version wrote
            // `zfo ? dIn1 : dIn1` — both branches equal, a no-op pretending
            // a decision had been made. There is none: `zfo` says whether tIn
            // is the POOL's token0, but the context's `tokenIn` is always the
            // pair's tIn. So decIn1 is always tIn's and decOther1 the other's.
            decIn1:      dIn1,
            decOther1:   dOt1
        });
        (out, depth, rank, hi) = BPC.universalQuoteRank(c, amt, bar);
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
    ///      `dIn1`, `dOt1` as in `_quoteWithDepth`: the decimals the hop already read. They feed
    ///      only the depth this function drops, so they change no figure; passing them spares
    ///      the Core two `decimals()` reads per call (0, 0: the Core reads them).
    function _quote(PoolInfo memory cand, address tIn, uint256 amt, uint256 bar, uint8 dIn1, uint8 dOt1)
        private view returns (uint256 out, uint256 rank, uint256 hi)
    {
        (out, , rank, hi) = _quoteWithDepth(cand, tIn, amt, dIn1, dOt1, bar);
    }

    // =========================================================================
    //  CANDIDATE SELECTION  (lazy discovery + top-K by fitness)
    // =========================================================================

    /// @dev ONE LIST PER ORDERED PAIR PER SOLVE. `_topKPools` is a function of the state and the
    ///      pair alone, and the solve is a static call, so the state cannot move between two
    ///      topologies: a pair they share (tIn -> bA opens topology 1 and every three-hop route
    ///      over bA; bB -> tOut closes topology 1 + j and every one that ends on bB) is built
    ///      once, and each later topology reads the list as it was built. Memory, not transient
    ///      storage: TSTORE is refused in a static frame (EIP-1153).
    ///      EACH READ GETS ITS OWN COPY of the array: `_buildHop` compacts and reorders the
    ///      array it is handed, in place, and the next topology must start from the list as
    ///      built. The rows are shared: nothing downstream writes a PoolInfo field (only
    ///      `_topKPools` does, on its own rows, before it returns).
    ///      `m.lists` heads a chain of [next, tA, tB, list] in memory; 0 is none.
    function _candsOf(Melhores memory m, address tA, address tB) private view returns (PoolInfo[] memory c) {
        uint256 a = uint160(tA);
        uint256 b = uint160(tB);
        uint256 e = m.lists;
        assembly ("memory-safe") {
            for {} e { e := mload(e) } {
                if and(eq(mload(add(e, 0x20)), a), eq(mload(add(e, 0x40)), b)) { c := mload(add(e, 0x60)) break }
            }
        }
        if (e == 0) {
            c = _topKPools(tA, tB, MAX_CANDIDATES);
            e = m.lists;
            assembly ("memory-safe") {
                let n := mload(0x40)
                mstore(n, e)
                mstore(add(n, 0x20), a)
                mstore(add(n, 0x40), b)
                mstore(add(n, 0x60), c)
                mstore(0x40, add(n, 0x80))
                e := n
            }
            m.lists = e;
        }
        assembly ("memory-safe") {
            let l := shl(5, add(mload(c), 1))
            let d := mload(0x40)
            mcopy(d, c, l)
            mstore(0x40, add(d, l))
            c := d
        }
    }

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
        //
        // THE GATE'S WRAPPERS ENTER EVERY MERGE (P3b), as discovery rows: Core.discoverWithGate
        // appends the immutable Gate's live wrappers whether or not the sweep runs. They do NOT
        // vote `_registryFresh` (it reads `reg` only), so they cannot switch discovery off.
        PoolInfo[] memory dis = BPC.discoverWithGate(address(hub), gate, tA, tB, !_registryFresh(reg));
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
        //
        // WHO MAY VOTE (bounty #85, Remember Me). From here on, inside the Solver, a candidate's
        // `active` bit means "a registered factory vouches for this pool": the Hub answers
        // `true` for every row it returns and nothing downstream read the bit. A discovery hit
        // keeps it; a registry row loses it unless the same sweep found the same pool.
        // `BlazePhoenixMath._depthWeightedMedian` reads it to decide whose mass may vote the band.
        for (uint256 i; i < rn; ) {
            reg[i].active = false;
            if (!BPC.hookAltersDeltas(reg[i].hooks)) { merged[n] = reg[i]; unchecked { ++n; } }
            unchecked { ++i; }
        }
        for (uint256 i; i < dn; ) {
            bool dup;
            for (uint256 j; j < rn; ) { if (dis[i].pool == reg[j].pool) { dup = true; reg[j].active = true; break; } unchecked { ++j; } }
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
        PoolInfo memory deep;   // set only when the funnel cuts; see _seatDeepest
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
            // More rows than the funnel keeps: the ranking decides who is cut, so every
            // cached depth is capped by what the pool holds now.
            if (n > keep) deep = _capByLiveDepth(active, ps, n);
        }
        for (uint256 i; i < n; ) {
            // A wrapper has no Hub row (psi 0 there): the Gate's vitalOf scores it (P2).
            if (active[i].kind == BPC.KIND_EXTERNAL) ps[i] = BPC.gatePsi(gate, active[i].pool);
            if (ps[i] == 0) ps[i] = 1;
            unchecked { ++i; }
        }
        uint256 k = n < keep ? n : keep;
        out = new PoolInfo[](k);
        for (uint256 ki; ki < k; ) {
            uint256 bestI = ki;
            for (uint256 j = ki + 1; j < n; ) {
                // TIE-BREAK BY FEE, ASCENDING — measured, not cosmetic. In a
                // COLD registry psi is 0 for every candidate (floored to 1
                // above), the sort degenerates to DISCOVERY ORDER, and the
                // top-K guillotine falls before anything is QUOTED: on OP the
                // Velo CL spacing-100 pool (fee ~5 bps, the best single leg by
                // output) sat past position 8 and the funnel never saw it —
                // 20 bps on the table at 1k, 16 bps on Base at 100k (matrix,
                // 2026-08-24). At equal fitness, admitting the CHEAPER venue
                // to the quote round is strictly better than address order;
                // the quotes in _buildHop still make every real decision. A
                // warm registry is untouched: real psi differs and the
                // tie-break never fires. (CL/Algebra rows carry the fee=0
                // sentinel, which sorts them first at cold start — harmless:
                // discovery only emits pools that EXIST, and the quote round
                // judges them like everyone else.)
                if (ps[j] > ps[bestI]
                    || (ps[j] == ps[bestI] && active[j].fee < active[bestI].fee)) bestI = j;
                unchecked { ++j; }
            }
            if (bestI != ki) {
                (active[ki], active[bestI]) = (active[bestI], active[ki]);
                (ps[ki],     ps[bestI])     = (ps[bestI],     ps[ki]);
            }
            out[ki] = active[ki];
            unchecked { ++ki; }
        }
        _seatDeepest(out, deep);
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
            // Only CURATED rows (tier 0, seedPool by an operator) can vouch
            // for coverage. A permissionless row (tier 2: recordSwap, claimV4)
            // is written by whoever swapped first, so counting it let three
            // self-registered dust pairs, kept fresh by three dust swaps an
            // hour, switch discovery OFF for the pair and hide every honest
            // venue that had never been registered — the registry then held
            // only what the attacker wrote, and the band was theirs. The
            // permissionless row stays a CANDIDATE (merged below); it no
            // longer chooses the path (review 2026-09-02).
            if (BPC.decodeTier(s) != 0) { unchecked { ++i; } continue; }
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

    /// @dev THE ONLY copy of "one leg's impact in bps" — extracted from twin
    ///      blocks in `_assembleRoute` and `_assembleRouteMulti` whose only
    ///      difference was local variable names. Twins are this codebase's
    ///      defect signature: the INV-20 fee fix below had to be applied to
    ///      BOTH, and the second one's comment already pointed at the first.
    ///
    ///      INV-20 on impact: the EFFECTIVE fee, not the declared one. For
    ///      Algebra the Hub's rule R2 forces the registry fee to the 0
    ///      sentinel — passing it raw to impactV3Bps priced the leg with NO
    ///      fee, understated the impact and published a `singleOutFloor`
    ///      TIGHTER than the one execution faces; an honest fill died in
    ///      RouterE(5). `quoteV3Fee` also resolves the CL case (fee lives on
    ///      the pool). ZERO COST IN STATICCALLS for V3/Algebra:
    ///      v3StateAndDynFee does the slot0() the price already required.
    function _legImpactBps(Leg memory L) private view returns (uint256 d) {
        if (BPC.kindHas(L.kind, BPC.A_RESERVES)) {
            (uint256 r0, uint256 r1) = BPC.getReserves(L.pool);
            uint256 rIn = L.zeroForOne ? r0 : r1;
            d = BPC.impactV2Bps(L.amountIn, rIn);
        } else if (BPC.kindHas(L.kind, BPC.A_CONC_POOL)) {
            uint128 liq = BPC.getLiquidity(L.pool);
            (uint160 sp, uint24 dynFee, bool dyn) = BPC.v3StateAndDynFee(L.pool);
            d = BPC.impactV3Bps(
                    L.amountIn, sp, liq,
                    BPC.quoteV3Fee(L.pool, uint24(L.fee), dynFee, dyn),
                    L.zeroForOne
                );
        } else {
            d = BPC.DEFAULT_IMPACT_BPS; // stable / V4 paths: the model does not cover them
        }
    }


    /// @notice Assemble a route of one hop (direct) or more (bridges). Aggregates impact across
    ///         the stages and derives the output floor from the FINAL
    ///         output. Hops stay separate so the Router can rescale stage B
    ///         against the real bridge balance produced by stage A.
    function _assembleRouteMulti(
        Hop[] memory hops, address tIn, address tOut,
        uint256 amountIn, uint256 finalOut
    ) private view returns (Route memory route) {
        tIn; tOut; amountIn;   // retained for signature clarity
        for (uint256 i; i < hops.length; ) { _orderLegs(hops[i]); unchecked { ++i; } }
        // LAYER 2 IS ROUTE-WIDE (review 2026-09-02). The Router refuses a
        // hookless leg after a hooked one anywhere in the route, not only
        // within a hop: a hook in hop 0 runs third-party code while every leg
        // of the later hops is still unmeasured, which is the exact state the
        // ordering rule exists to make unreachable. So a hooked leg may only
        // sit in the LAST hop. A topology that puts one earlier is not
        // re-ordered here (hops must chain); it is simply not offered, and
        // `_rank` picks another.
        for (uint256 h; h + 1 < hops.length; ) {
            Leg[] memory hl = hops[h].legs;
            for (uint256 i; i < hl.length; ) {
                if (hl[i].hooks != address(0)) return route;
                unchecked { ++i; }
            }
            unchecked { ++h; }
        }
        // R-B: TWO CONSUMERS, TWO REDUCTIONS. One number used to serve both the
        // ceiling and the floor, and they want opposite things.
        //
        // The CEILING asks "does any leg destroy the order?" — a question about
        // the WORST leg. Averaging answered a different question and hid the
        // destroyer: one leg at 9_500 bps beside a single cheap leg averages to
        // under the 9_000 ceiling and passes. The name said "absolute"; the
        // `/legs` divisor made it dilutable by adding legs.
        //
        // The FLOOR keeps the MEAN, deliberately. ironFloorBps SUBTRACTS impact,
        // so a bigger number means a LOWER floor: feeding it the max would let a
        // single dust leg collapse the floor to its hard clamp, which is the
        // padding attack made trivial rather than closed. The mean is weighted by
        // each leg's share of its hop since 437d537, with the Router's own arithmetic.
        // The ceiling gates on the worst LEG anywhere in the route.
        //
        // TWO FIGURES, DELIBERATELY (review 2026-09-02, the pass after PR #25):
        //  * the GATE keeps the per-hop mean summed across hops — a deliberate
        //    over-estimate that refuses a compounding route early;
        //  * the FLOOR is the Router's own number: each leg's impact weighted
        //    by its share of the hop (`_wImp`), accumulated over the whole
        //    route and divided by the route's TOTAL leg count (`_execute`).
        //    PR #25 gave the single-hop twin exactly that arithmetic and left
        //    a comment here saying this arm "can only be looser than the
        //    Router's, never tighter". False whenever a hop concentrates its
        //    input in its high-impact leg: 97% of a hop at 100 bps beside
        //    three dust legs at 0 is 25 per hop unweighted (50 for the
        //    route) and 97 for the Router — the attestation was TIGHTER, and
        //    an honest fill died on RouterE(5) against the plan the protocol
        //    itself published. Pinned end-to-end by
        //    test/FloorParitySolverRouter.t.sol (two hops, both split).
        uint256 gateImpactBps;
        uint256 weightedAcc;
        uint256 totalLegs;
        uint256 maxLegImpactBps;
        uint256 legShv;      // concentration-based, summed per hop - the Router's own arithmetic
        for (uint256 h; h < hops.length; ) {
            uint256 legs = hops[h].legs.length;
            uint256 hopIn = hops[h].amountIn;
            uint256 hopImpact;
            uint256 sA;
            uint256 sA2;
            for (uint256 i; i < legs; ) {
                uint256 li = _legImpactBps(hops[h].legs[i]);
                uint256 a  = hops[h].legs[i].amountIn;
                hopImpact += li;
                weightedAcc += hopIn == 0 ? li : BPC.mulDiv(li * legs, a, hopIn);
                if (li > maxLegImpactBps) maxLegImpactBps = li;
                sA += a;
                sA2 += a * a;
                unchecked { ++i; }
            }
            if (legs > 0) hopImpact = hopImpact / legs;
            gateImpactBps += hopImpact;  // linear sum: safe over-estimate, for the gate only
            totalLegs += legs;
            legShv += BPC.legShaveBps(sA, sA2);
            unchecked { ++h; }
        }

        // A destroyer leg is refused wherever it sits, and the compounded
        // per-hop figure still gates too — whichever binds first.
        if (maxLegImpactBps >= MAX_ROUTE_IMPACT_BPS || gateImpactBps >= MAX_ROUTE_IMPACT_BPS) return route;

        uint256 totalImpactBps = totalLegs > 0 ? weightedAcc / totalLegs : 0;
        uint256 floorBps = BPC.ironFloorBpsShv(totalImpactBps, legShv, 0);
        // R-C: a protective threshold rounds UP, as the Router's does - the other half of
        // the same-number parity.
        //
        // ONE FIGURE along the chain too: every hop's legs are quoted by the walk, so each
        // later hop was sized on what the hop before it can pay, and the route's figure is
        // the floor's base (the promise layer and its pro-rata chain, #74, are identities
        // since the walk and are gone with the single-tick model).
        uint256 floorOut = BPC.mulDivUp(finalOut, floorBps, BPC.BPS);

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
