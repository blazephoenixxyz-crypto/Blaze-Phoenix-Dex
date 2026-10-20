// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  H15 (fix-1019, matrix round E): the claimV4 JIT live window is a sandwich
//  bounded by userMinOut (Router:541-544, documented; verdict B: POR DESENHO).
//  Fixture: the oc-1018 d2 PoC base (h15-jit-live-window-capture-receiver),
//  its 13 tests stripped, names prefixed F19. No fix exists (F report: the
//  same-block mute is bypassed by one earlier tx), so both tests pin, both eras:
//    - live window, honest userMinOut (0.5 % under the pre-bundle fill) on the
//      automatic door: RouterE(5); the route fixed in calldata before the
//      bundle still settles above that minimum;
//    - live window, userMinOut = 1: the automatic door settles below the
//      honest fill (the protocol floors are relative to the manipulated
//      state). This is the residual the documentation states.
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg, PoolInfo, RoutePlan} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV3Pool} from "./mocks/MockV3Pool.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";
import {Origin} from "./mocks/MockOriginFactory.sol";

abstract contract F19H15Base is Test {
    BlazePhoenixHub    hub;
    BlazePhoenixSolver solver;
    BlazePhoenixRouter router;

    MockERC20 tokenA;
    MockERC20 tokenB;
    MockV3Pool pool;

    address user = address(0xBEEF);
    address constant T1 = address(0xFEE1);
    address constant T2 = address(0xFEE2);

    uint160 constant SQRT_P_1 = 79228162514264337593543950336; // price 1.0 = 2**96
    uint128 constant LIQ      = 1e21;     // depthFromL18 = 1e21 -> bucket 6
    uint256 constant HOLD     = 1e21;     // balances the pool really holds
    uint24  constant POOL_FEE = 3000;

    uint256 constant AMOUNT_IN = 1e6;     // output ~1e6, bucket 0

    bool zfo;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        solver = new BlazePhoenixSolver(address(hub));
        router = new BlazePhoenixRouter(address(hub), address(solver), address(this), T1, T2);
        hub.setRoles(address(router), address(solver), address(this));

        tokenA = new MockERC20("A", "A");
        tokenB = new MockERC20("B", "B");

        pool = new MockV3Pool(address(tokenA), address(tokenB), POOL_FEE);
        pool.setState(SQRT_P_1, LIQ);
        tokenA.mint(address(pool), HOLD);
        tokenB.mint(address(pool), HOLD);

        zfo = pool.token0() == address(tokenA);

        tokenA.mint(user, 1_000_000e18);
        vm.prank(user);
        tokenA.approve(address(router), type(uint256).max);
    }

    function _key() internal view returns (bytes32) {
        return hub.keyOf(address(pool), address(tokenA), address(tokenB));
    }

    function _route(uint256 expectedOut) internal view returns (Route memory r) {
        Leg[] memory legs = new Leg[](1);
        legs[0] = Leg({
            pool: address(pool),
            hooks: address(0),
            kind: BPC.KIND_V3,
            fee: POOL_FEE,
            tickSpacing: 0,
            zeroForOne: zfo,
            stable: false,
            amountIn: AMOUNT_IN,
            expectedOut: expectedOut,
            auxId: bytes32(0)
        });
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({
            tokenIn: address(tokenA),
            tokenOut: address(tokenB),
            amountIn: AMOUNT_IN,
            expectedOut: 0,
            legs: legs
        });
        r = Route({
            hops: hops,
            totalOut: 0,
            singleOut: 0,
            singleOutFloor: 0,
            expectedImpactBps: 0,
            confidenceWad: 0,
            estGas: 0,
            hasSurplus: false,
            isV4Bundle: false
        });
    }

    /// @dev The depth the registry's producer answers for this pool, from state.
    function _measuredDepth() internal view returns (uint256) {
        (address t0, address t1) = (pool.token0(), pool.token1());
        return BPC.registryDepth18(address(pool), BPC.KIND_V3, t0, t1, address(0), bytes32(0));
    }

    // ── (1) the sealed bucket is the measured one, not the declared one ──────

    // ── (2) the literal attack cannot run: the declared figure reverts first ─

    /// @dev The same single-leg V3 route as `_route`, over an arbitrary pool.
    function _routeAt(address p, uint256 expectedOut) internal view returns (Route memory r) {
        Leg[] memory legs = new Leg[](1);
        legs[0] = Leg({
            pool: p,
            hooks: address(0),
            kind: BPC.KIND_V3,
            fee: POOL_FEE,
            tickSpacing: 0,
            zeroForOne: zfo,
            stable: false,
            amountIn: AMOUNT_IN,
            expectedOut: expectedOut,
            auxId: bytes32(0)
        });
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({
            tokenIn: address(tokenA),
            tokenOut: address(tokenB),
            amountIn: AMOUNT_IN,
            expectedOut: 0,
            legs: legs
        });
        r = Route({
            hops: hops,
            totalOut: 0,
            singleOut: 0,
            singleOutFloor: 0,
            expectedImpactBps: 0,
            confidenceWad: 0,
            estGas: 0,
            hasSurplus: false,
            isV4Bundle: false
        });
    }

    // ── (3) H15 — a contract the attacker wrote enters the registry and a ─────
    //        later user's swap consumes its measured bucket as ranking input. ─
    //
    //  H15 claims `recordSwap` registers a leg's pool "without code or interface
    //  verification", so a hostile contract occupies a slot and anchors later
    //  routing. The gates recordSwap applies before `_register` (Hub:1745-1875)
    //  are: the pair proof `token0Of/token1Of == sorted pair` (Hub:1749), the
    //  shape proof `BPC.provenShape` (Hub:1868), and `_held`/`reservesHeld`
    //  (Hub:1873). A contract the attacker deploys can satisfy ALL THREE by
    //  construction — it answers token0()/token1() with the forged pair, answers
    //  no slot0() (so `provenShape` reads it as a pair, not concentrated), and
    //  physically holds the reserves it declares. It then takes a seat at the
    //  depth its OWN reserves measure (never a declared depth), and that bucket
    //  is what the Solver's `_topKPools` ranks for a later user.

    // ── (4) H15 negative — a pool that cannot be traded never enters, and the ─
    //        existing rank state does not move. ────────────────────────────────
    //
    //  The dangerous half of H15 is "if it reverts on swap, make the default
    //  routing for the pair revert". recordSwap runs only AFTER a leg executed
    //  (Router._recordHits, Router:2270), so a pool whose swap cannot complete
    //  never reaches recordSwap at all. Here the pool is shape-valid (it would
    //  pass every registration gate) but demands more input than the leg was
    //  given: the Router's own callback cap refuses it with RouterE(8), the tx
    //  unwinds, and the honest venue's row is byte-identical.

    // ══════════════════════════════════════════════════════════════════════
    //  (5) iter 3 — H17 differential: deep off-market attacker vs honest venue
    //
    //  H17 claims the Solver centres its price band on the pool with the largest
    //  balance (capital anchor), so a mispriced, well-funded, registered pool
    //  becomes the anchor, honest pools fall outside the band, and nearly all
    //  weight goes to it. The two defences the src now carries are:
    //    · Solver:1560 `reg[i].active = false` — a registry row is NOT vouched
    //      for unless the SAME discovery sweep found it; and
    //    · `_mutedVotes` (Solver:~1249) — a row that is `!active`, reserve- or
    //      concentred-shaped, and swap-written (tier != 0) has its MASS zeroed
    //      for the base vote: it still quotes, still executes, but it cannot
    //      choose the band. `_depthWeightedMedian` then reads w[i] = 0 for it.
    //
    //  We cannot read the private `active` bit from a test. We evidence it the
    //  only way a caller can: (a) the attacker is NOT returned by the public
    //  `discoverFor`, so the sweep cannot vouch for it; (b) its row tier != 0
    //  (recordSwap) while the honest seeded row's tier == 0; and (c) the band's
    //  observable product — the plan — is byte-identical with and without the
    //  attacker row present. If the attacker could vote, its 5e23 depth would
    //  be >50% of the mass, base would be its ~0.5 rate, and the honest ~1.0
    //  rate would fall outside the ±5% band: planB would collapse onto the
    //  attacker and outB would fall to ~outC. It does not.
    // ══════════════════════════════════════════════════════════════════════

    struct H17World {
        BlazePhoenixHub    hub;
        BlazePhoenixSolver solver;
        BlazePhoenixRouter router;
        MockERC20          a;
        MockERC20          b;
        MockV3Pool         honest;
        MockV2Pair         evil;
    }

    function _mkWorld() internal returns (H17World memory w) {
        w.hub = new BlazePhoenixHub(address(this));
        w.hub.initialize(address(this), address(0));
        w.solver = new BlazePhoenixSolver(address(w.hub));
        w.router = new BlazePhoenixRouter(address(w.hub), address(w.solver), address(this), T1, T2);
        w.hub.setRoles(address(w.router), address(w.solver), address(this));

        w.a = new MockERC20("A", "A");
        w.b = new MockERC20("B", "B");

        // HONEST venue: concentrated, priced at 1.0, depth ~1e21 (bucket 6).
        w.honest = new MockV3Pool(address(w.a), address(w.b), POOL_FEE);
        w.honest.setState(SQRT_P_1, LIQ);
        w.a.mint(address(w.honest), HOLD);
        w.b.mint(address(w.honest), HOLD);

        // ATTACKER venue: a pair the attacker deployed. DEEP (5e23 short side,
        // far above the honest bucket) but OFF-MARKET: the tokenOut reserve is
        // half the tokenIn reserve, so the honest ~1.0 rate is a ~0.5 rate here.
        // Reserves never exceed the tokens it holds (`reservesHeld`).
        w.evil = new MockV2Pair(address(w.a), address(w.b));
        uint112 hi = 1e24;
        uint112 lo = 5e23;
        if (w.evil.token0() == address(w.a)) w.evil.setReserves(hi, lo); else w.evil.setReserves(lo, hi);
        w.a.mint(address(w.evil), hi);
        w.b.mint(address(w.evil), hi);
    }

    function _seedHonest(H17World memory w) internal {
        w.hub.seedPool(address(w.honest), BPC.KIND_V3, POOL_FEE, address(0), address(w.a), address(w.b));
    }

    /// @dev Stand in for `Router._recordHits`: measure the depth the Router would
    ///      measure and call `recordSwap` with it, as Router-role. The row is
    ///      swap-written, so its tier is 2 (recordSwap) not 0 (seedPool).
    function _registerEvil(H17World memory w) internal {
        address t0 = w.evil.token0();
        address t1 = w.evil.token1();
        uint256 measured = BPC.registryDepth18(address(w.evil), BPC.KIND_V2, t0, t1, address(0), bytes32(0));
        w.hub.setRoles(address(this), address(w.solver), address(this));
        w.hub.recordSwap(address(w.evil), BPC.KIND_V2, 30, address(0), t0, t1, 1, 1, measured);
        w.hub.setRoles(address(w.router), address(w.solver), address(this));
    }

    function _fundUser(H17World memory w) internal {
        w.a.mint(user, 1_000_000e18);
        vm.prank(user);
        w.a.approve(address(w.router), type(uint256).max);
    }

    function _swap(H17World memory w) internal returns (uint256) {
        vm.prank(user);
        return w.router.swapBestExactIn(
            address(w.a), address(w.b), AMOUNT_IN, 1, user, block.timestamp + 1);
    }

    function _usesPool(Route memory r, address p) internal pure returns (bool) {
        for (uint256 i; i < r.hops.length; ++i) {
            for (uint256 j; j < r.hops[i].legs.length; ++j) {
                if (r.hops[i].legs[j].pool == p) return true;
            }
        }
        return false;
    }

    function _routeHash(Route memory r) internal pure returns (bytes32) {
        return keccak256(abi.encode(r));
    }

    function _discoveredHas(BlazePhoenixHub h, address a, address b, address p)
        internal view returns (bool)
    {
        PoolInfo[] memory hits = h.discoverFor(a, b);
        for (uint256 i; i < hits.length; ++i) { if (hits[i].pool == p) return true; }
        return false;
    }

    function _bucketOf(H17World memory w, address p, uint8 kind) internal view returns (uint8) {
        (address t0, address t1) = kind == BPC.KIND_V2
            ? (w.evil.token0(), w.evil.token1())
            : (w.honest.token0(), w.honest.token1());
        return BPC.depthBucket(BPC.registryDepth18(p, kind, t0, t1, address(0), bytes32(0)));
    }


    // ══════════════════════════════════════════════════════════════════════
    //  (6) iter 5 — H15 ADMISSION / EVICTION HALF: MAX_SLOTS, _canInsert, _register
    //
    //  WHERE THE GUARD LIVES. A newcomer reaches the bounded per-pair registry
    //  through exactly two permissionless doors, and BOTH call `_canInsert`
    //  first: `recordSwap` (Hub:1729) and `claimV4` (Hub:1016). `_canInsert`
    //  (Hub:1896) does nothing while the pair is short of `MAX_SLOTS = 16`
    //  (Hub:88, `if (ks.length < MAX_SLOTS) return true;`). When the pair is
    //  full it admits iff
    //      bucketWeight(newcomerBucket) > worstPsi + worstPsi / 4
    //  with `worstPsi` the MINIMUM `psi` of the 16 incumbents. `_register`
    //  (Hub:1983) then evicts exactly that minimum. Admission reads NO tier:
    //  a tier-2 (permissionless, `trusted == false`) row and a tier-0 (curated,
    //  `seedPool`/`addV4`) row are ranked by the same measured `bucketWeight`.
    //
    //  WHAT THIS REFUTES (H15's eviction half, "evict real venues" / "block"):
    //    · a row no deeper than the weakest incumbent is REFUSED, no state moves;
    //    · a deeper row is NEVER blocked, however many permissionless rows sit;
    //    · the evicted row is always the MINIMUM-psi incumbent, and a
    //      permissionless row displaces a curated tier-0 incumbent only when
    //      the incumbent is that minimum (the documented `bucketWeight`
    //      ranking), never because of its tier.
    // ══════════════════════════════════════════════════════════════════════

    uint256 constant SQUAT_DEPTH = 1e16; // 1e16 -> bucket 1 -> psi 2
    uint256 constant MID_DEPTH   = 1e20; // 1e20 -> bucket 5 -> psi 32
    uint256 constant DEEP_DEPTH  = 1e21; // 1e21 -> bucket 6 -> psi 64

    function _mkPair(H17World memory w, uint256 reserve) internal returns (MockV2Pair p) {
        p = new MockV2Pair(address(w.a), address(w.b));
        w.a.mint(address(p), reserve);
        w.b.mint(address(p), reserve);
        p.setReserves(uint112(reserve), uint112(reserve));
    }

    /// @dev Stand in for the Router on `recordSwap`: measure the depth the
    ///      Router would measure and pass it as the 9th argument.
    function _recordPair(H17World memory w, MockV2Pair p) internal {
        uint256 d = BPC.registryDepth18(
            address(p), BPC.KIND_V2, p.token0(), p.token1(), address(0), bytes32(0));
        // rizki-3107: a swap seats only a pool a wired factory derives. Each squatter is
        // born in its own permissionless V2 factory, as an attacker's pair would be.
        this.wireV2(w.hub, p);
        w.hub.setRoles(address(this), address(w.solver), address(this));
        w.hub.recordSwap(address(p), BPC.KIND_V2, 30, address(0),
                         p.token0(), p.token1(), 1, 1, d);
        w.hub.setRoles(address(w.router), address(w.solver), address(this));
    }

    /// @dev An external self-call, so the optimiser cannot inline it: inlined into
    ///      `_recordPair`, the wiring overflows `_liveWorld`'s stack by one slot. The Hub sees
    ///      this contract, its admin, as the caller either way.
    function wireV2(BlazePhoenixHub hub, MockV2Pair p) external {
        require(msg.sender == address(this), "self only");
        Origin.wire(hub, address(p), p.token0(), p.token1(), BPC.KIND_V2, 30);
    }

    function _kPair(H17World memory w, MockV2Pair p) internal view returns (bytes32) {
        return w.hub.keyOf(address(p), p.token0(), p.token1());
    }

    function _fillSquatters(H17World memory w, uint256 n, uint256 reserve)
        internal returns (MockV2Pair[] memory sq)
    {
        sq = new MockV2Pair[](n);
        for (uint256 i; i < n; ++i) {
            sq[i] = _mkPair(w, reserve);
            _recordPair(w, sq[i]);
        }
    }

    // ── (6a) full registry: the ranking refuses a no-deeper newcomer, admits a
    //         deeper one (evicting the minimum-psi incumbent), and never blocks
    //         a deeper venue regardless of how many permissionless rows sit. ──

    // ── (6b) the ONLY way a permissionless row displaces a curated incumbent:
    //         the incumbent is the minimum-psi row, exactly as the documented
    //         `bucketWeight` ranking says. Nothing protects tier 0 itself. ──

    // ══════════════════════════════════════════════════════════════════════
    //  (7) iter 6 — H15 VITALITY-INFLATION half. `_canInsert` (Hub:1945) compares
    //  a FIXED newcomer weight
    //      newcomerPsi = bucketWeight(depthBucket(newDepth))          (a power of two)
    //  against a `worstPsi` the incumbent rows can GROW WITHOUT BOUND, because
    //      psi = vitality x bucketWeight(bucket) x bonuses
    //  and `vitality` (= decayed `swapCount`, floored to 1 while live) is raised
    //  by the attacker's OWN routed swaps through the same permissionless door
    //  (`recordSwap` -> `tickSlot`, Core:2440). Every row the attacker seats is
    //  its own, so it controls the RHS of the admission predicate. A cluster of
    //  shallow bucket-1 squatters that ticks each row to swapCount 26 scores 52;
    //  the bucket-6 newcomer scores 64 and `64 > 52 + 52/4` is false, so the
    //  deeper venue is REFUSED. Raising swapCount instead to 13 108 scores
    //  `bucketWeight(15) = 32768 / 1.25`, refusing a venue of ANY depth. This is
    //  exactly the behaviour the comment at Hub:1902-1905 claims the full-fitness
    //  ranking removed ("an attacker can no longer keep a deep pool out merely by
    //  sending dust through 16 shallow slots to hold their vitality at 1"): the
    //  fix stopped vitality being pinned at 1, but left the adversary free to
    //  inflate it upward, and the RHS of the margin is the inflatable side.
    // ══════════════════════════════════════════════════════════════════════

    function _psiPair(H17World memory w, MockV2Pair p) internal view returns (uint256) {
        return w.hub.getPsi(address(p), p.token0(), p.token1());
    }

    /// @dev The minimum psi over every live row of the pair, read the way
    ///      `_canInsert`/`_register` read it (the pair's own fitness via getPsi).
    function _worstActive(H17World memory w) internal view returns (uint256 worst) {
        PoolInfo[] memory ps = w.hub.getActivePools(address(w.a), address(w.b));
        worst = type(uint256).max;
        for (uint256 i; i < ps.length; ++i) {
            uint256 p = w.hub.getPsi(ps[i].pool, address(w.a), address(w.b));
            if (p < worst) worst = p;
        }
    }

    /// @dev Tick a SEATED row `n` more times through the Router-only door. The
    ///      registering swap already left swapCount = 1 (Hub:1877), so the row
    ///      ends at `1 + n`. All within one block, so the decay age is 0,
    ///      `vitality == swapCount`, and `psi == swapCount x bucketWeight`.
    function _inflate(H17World memory w, MockV2Pair p, uint256 n) internal {
        uint256 d = BPC.registryDepth18(
            address(p), BPC.KIND_V2, p.token0(), p.token1(), address(0), bytes32(0));
        w.hub.setRoles(address(this), address(w.solver), address(this));
        for (uint256 i; i < n; ++i) {
            w.hub.recordSwap(address(p), BPC.KIND_V2, 30, address(0),
                             p.token0(), p.token1(), 1, 1, d);
        }
        w.hub.setRoles(address(w.router), address(w.solver), address(this));
    }

    /// @dev Ticks to raise a bucket-1 row (weight 2) from swapCount 1 to 26:
    ///      psi = 52, the smallest even score above `64 - 64/5`. 25 extra ticks.
    uint256 constant INFLATE_TO_52 = 25;


    // ══════════════════════════════════════════════════════════════════════
    //  (8) iter 7 — H15 VITALITY-INFLATION half, the OPEN LIMIT of iter 6:
    //      model UPKEEP vs DECAY. iter 6 measured the inflation ceiling with every
    //      tick in ONE block (decay age 0), so it never priced the time axis. Here
    //      the 16 bucket-1 squatters are inflated to swapCount 26 (psi 52) and then
    //      `vm.warp`ed by whole `VITALITY_DECAY_STEP_SECONDS` (Core:2257, 24_576 s)
    //      so `_decayedSwapCount` (Core:2305) actually shifts:
    //          psi = (swapCount >> (age/STEP)) x bucketWeight(2) x bonuses.
    //      The bucket-6 newcomer projects a FIXED weight 64 (`bucketWeight`), so
    //      only the incumbent side moves. Three facts:
    //        (a) one decay step halves the cluster: worstPsi 52 -> 26, and
    //            64 > 26 + 26/4 = 32 admits the newcomer, evicting a DECAYED row.
    //            (The decay, not a removal path, is what re-opened admission.)
    //        (b) holding the squat is NOT "one dust swap per row per step": a single
    //            tick per row restores only `13 + 1 = 14` (psi 28, still < 52); it
    //            takes 13 ticks per row per step (208 swaps/step for 16 rows) to
    //            push the shift back to 26. `tickSlot` counts from what REMAINS
    //            (Core:2443), so upkeep compounds with the decay rate.
    //        (c) decay is NOT a removal path. Past 31 steps a live row's `vitality`
    //            is a true 0 (Core:2277) yet it is still listed by `getActivePools`;
    //            the only displacement is the `_register` ranking (Hub:2003-2019)
    //            evicting the min-psi row when a newcomer clears `_canInsert`.
    // ══════════════════════════════════════════════════════════════════════

    uint256 constant DECAY_STEP = 24_576;
    /// @dev Fixed, explicit wall-clock base for each phase. Warp targets are
    ///      absolute (BASE_TS + k x DECAY_STEP), never `block.timestamp + ...`:
    ///      a phase must not inherit a stale environment read from an earlier warp.
    uint256 constant BASE_TS = 1_000_000;


    // ══════════════════════════════════════════════════════════════════════
    //  (8) iter 12 — H15 ADMISSION half through the UNCOVERED door `claimV4`
    //  (Hub:969 / entry at Hub:1016). Same `_canInsert` (Hub:1896) and
    //  `_register` (Hub:1983) ranking as `recordSwap`, but this door never
    //  names a depth: it derives the hookless poolId from (s0,s1,fee,ts,0),
    //  proves slot0 + liquidity through the configured PoolManager
    //  (BPC.v4SqrtAndLiq, Core:1725) and then MEASURES
    //  `depthTok = registryDepth18(..., KIND_V4, ...)` (Core:2387, A_CONC_SING
    //  arm). Nothing the caller supplies is used as depth. This test pins:
    //    · a bucket-0 (thin-liq) claim on a FULL pair is refused by the same
    //      strict margin `recordSwap` faces — no slot, no V4Entry, no eviction;
    //    · a deep claim is admitted with the MEASURED bucket persisted, and the
    //      row it evicts is the MINIMUM-psi incumbent;
    //    · a curated tier-0 venue is displaced only when it IS that minimum,
    //      exactly the documented ranking — admission never reads tier.
    //  Harness: F19V4StateManager holds the two extsload slots the proof reads
    //  (base = keccak256(abi.encode(pid, 6)) -> slot0, base+3 -> liquidity),
    //  the same layout as HardeningA4_ClaimV4Margin.
    // ══════════════════════════════════════════════════════════════════════

    function _mkClaimWorld() internal returns (H17World memory w, F19V4StateManager mgr) {
        w.hub = new BlazePhoenixHub(address(this));
        mgr = new F19V4StateManager();
        w.hub.initialize(address(this), address(mgr));
        w.hub.setRoles(address(this), address(this), address(this));
        w.a = new MockERC20("A", "A");
        w.b = new MockERC20("B", "B");
    }

    /// @dev Plant a live hookless V4 pool in the manager at the exact storage
    ///      layout BPC.v4SqrtAndLiq reads: sqrtPriceX96 = Q96 (price 1.0,
    ///      static fee, so the INV-20 gate passes) and the given liquidity.
    function _plantV4(H17World memory w, F19V4StateManager mgr, uint24 fee, int24 ts, uint128 liq)
        internal returns (address poolAddr, bytes32 key)
    {
        (address s0, address s1) = address(w.a) < address(w.b)
            ? (address(w.a), address(w.b))
            : (address(w.b), address(w.a));
        bytes32 pid = BPC.computeV4PoolId(s0, s1, fee, ts, address(0));
        bytes32 base = keccak256(abi.encode(pid, uint256(6)));
        mgr.setSlot(base, bytes32(uint256(BPC.Q96)));
        mgr.setSlot(bytes32(uint256(base) + 3), bytes32(uint256(liq)));
        poolAddr = address(uint160(uint256(pid)));
        key = w.hub.keyOf(poolAddr, s0, s1);
    }


    // ══════════════════════════════════════════════════════════════════════
    //  (8) H15 — `claimV4` reads the singleton's LIVE liquidity, so the depth
    //  that clears admission can be flash/JIT-inflated for the claim call and
    //  collapsed in the same transaction. The persisted bucket stays high, but
    //  every consumer that could ANCHOR a later swap re-measures the book live:
    //  the funnel's live-depth cap (`_capByLiveDepth`) and the median's vote
    //  weights (`depths` from `_quoteWithDepth`), not `$.slot[key]`. This test
    //  pins that the admission bar and the anchor bar are DIFFERENT reads.
    //    · JIT state: off-market V4 book with 1e24 liq -> claim admitted, the
    //      stored bucket is the JIT-liq bucket, the min-psi squatter is evicted;
    //    · while the JIT book is still live the honest venue is filtered out;
    //    · collapse liq to 1e14: the live re-measure collapses to bucket 0, the
    //      stored bucket is NOT rewritten, and the row keeps its high psi;
    //    · the later plan is byte-identical to the honest baseline and does not
    //      route through the collapsed row.
    // ══════════════════════════════════════════════════════════════════════

    /// @dev A pair-shaped squatter priced OFF-MARKET (marginal rate lo/hi) so
    ///      only the curated venue can sit in the honest band. Reserves never
    ///      exceed the tokens it holds (`_recordPair` measures, `reservesHeld`
    ///      passes).
    function _mkOffPair(H17World memory w, uint256 hi, uint256 lo)
        internal returns (MockV2Pair p)
    {
        p = new MockV2Pair(address(w.a), address(w.b));
        w.a.mint(address(p), hi);
        w.b.mint(address(p), hi);
        if (p.token0() == address(w.a)) p.setReserves(uint112(hi), uint112(lo));
        else p.setReserves(uint112(lo), uint112(hi));
    }

    function _fillOffSquatters(H17World memory w, uint256 n, uint256 hi, uint256 lo)
        internal returns (MockV2Pair[] memory sq)
    {
        sq = new MockV2Pair[](n);
        for (uint256 i; i < n; ++i) {
            sq[i] = _mkOffPair(w, hi, lo);   // depth min(hi,lo) = bucket 1 -> psi 2
            _recordPair(w, sq[i]);
        }
    }


    // ══════════════════════════════════════════════════════════════════════
    //  (9) H15 — the LIVE window. iter13 showed the JIT depth is not persisted
    //  as an anchor (the plan returns to honest once the book collapses). This
    //  test runs the user's swap IN the same block while the JIT book is still
    //  live, so the question is not "does the row persist" but "does the live
    //  mass capture the swap the honest venue would have carried".
    //    · baseline: honest tier-0 V3 (rate 1.0) carries the swap -> outHonest;
    //    · plant an off-market V4 book at price 0.5, liq 1e24, at once claim it
    //      (no vm.warp, no collapse) and re-plan + swap in the same block;
    //    · collapse liq to 1e14 in the same test: the plan hash must return to
    //      the honest baseline and the attacker row must capture nothing.
    // ══════════════════════════════════════════════════════════════════════

    function _trySwap(BlazePhoenixRouter rtr, address tIn, address tOut)
        internal returns (bool ok, uint256 out)
    {
        vm.prank(user);
        try rtr.swapBestExactIn(tIn, tOut, AMOUNT_IN, 1, user, block.timestamp + 1)
            returns (uint256 o)
        {
            return (true, o);
        } catch {
            return (false, 0);
        }
    }


    // ══════════════════════════════════════════════════════════════════════
    //  (10) H15 — WHO CAPTURES. iter14 showed the live JIT book moves the fill
    //  off the honest venue, and that the routed leg was an off-market V2
    //  squatter, not the attacker's V4 pid. This test names the capture receiver
    //  by swapping those squatters for F19RecordingV2Pair venues: on the pool the
    //  live plan actually selects it asserts (a) the routed leg is an
    //  attacker-owned venue, never the curated honest V3; (b) the user's whole
    //  input lands in that venue's reserve and the user's output is exactly what
    //  that venue disburses; (c) the shortfall vs the honest baseline is tokenB
    //  RETAINED across the venue's reserves, not a burned/dusted remainder.
    // ══════════════════════════════════════════════════════════════════════
    function _mkRecOffPair(H17World memory w, uint256 hi, uint256 lo)
        internal returns (F19RecordingV2Pair p)
    {
        p = new F19RecordingV2Pair(address(w.a), address(w.b));
        w.a.mint(address(p), hi);
        w.b.mint(address(p), hi);
        if (p.token0() == address(w.a)) p.setReserves(uint112(hi), uint112(lo));
        else p.setReserves(uint112(lo), uint112(hi));
    }

    function _recordRecPair(H17World memory w, F19RecordingV2Pair p) internal {
        uint256 d = BPC.registryDepth18(
            address(p), BPC.KIND_V2, p.token0(), p.token1(), address(0), bytes32(0));
        w.hub.setRoles(address(this), address(w.solver), address(this));
        w.hub.recordSwap(address(p), BPC.KIND_V2, 30, address(0),
                         p.token0(), p.token1(), 1, 1, d);
        w.hub.setRoles(address(w.router), address(w.solver), address(this));
    }

    function _fillRecOffSquatters(H17World memory w, uint256 n, uint256 hi, uint256 lo)
        internal returns (F19RecordingV2Pair[] memory sq)
    {
        sq = new F19RecordingV2Pair[](n);
        for (uint256 i; i < n; ++i) {
            sq[i] = _mkRecOffPair(w, hi, lo);
            _recordRecPair(w, sq[i]);
        }
    }

    function _recSqHas(F19RecordingV2Pair[] memory sq, address p) internal pure returns (bool) {
        for (uint256 i; i < sq.length; ++i) if (address(sq[i]) == p) return true;
        return false;
    }

    /// @dev The first leg of the plan that is one of the attacker's recording
    ///      venues, or address(0) if the plan does not route any of them.
    function _firstRecLeg(Route memory r, F19RecordingV2Pair[] memory sq)
        internal pure returns (address)
    {
        for (uint256 i; i < r.hops.length; ++i) {
            for (uint256 j; j < r.hops[i].legs.length; ++j) {
                if (_recSqHas(sq, r.hops[i].legs[j].pool)) return r.hops[i].legs[j].pool;
            }
        }
        return address(0);
    }

    /// @dev Before-values for the capture conservation check:
    ///      [0] venue tokenIn balance, [1] venue tokenOut balance,
    ///      [2] user tokenOut balance, [3] honest venue tokenOut balance,
    ///      [4] Router tokenOut balance, [5] tokenOut total supply,
    ///      [6] treasury1 tokenIn, [7] treasury2 tokenIn.
    function _captureBefore(H17World memory W, address routed, address curated, address rtr)
        internal view returns (uint256[8] memory v)
    {
        v[0] = W.a.balanceOf(routed);
        v[1] = W.b.balanceOf(routed);
        v[2] = W.b.balanceOf(user);
        v[3] = W.b.balanceOf(curated);
        v[4] = W.b.balanceOf(rtr);
        v[5] = W.b.totalSupply();
        v[6] = W.a.balanceOf(T1);
        v[7] = W.a.balanceOf(T2);
    }

    function _assertCapture(
        H17World memory W, address routed, address curated, address rtr,
        uint256[8] memory before, uint256 outHonest, uint256 outJit
    ) internal view {
        F19RecordingV2Pair rec = F19RecordingV2Pair(routed);
        // (a) the capture receiver is the attacker's own contract.
        assertEq(rec.swaps(), 1, "the routed attacker venue executed exactly one swap");
        assertEq(rec.lastTo(), rtr, "the attacker venue paid the Router");
        // (b) the attacker venue received the user's input (net of the protocol
        //     fee the Router takes on the hop) and disbursed exactly the user's
        //     output. Its tokenOut reserve therefore sits exactly the user's
        //     shortfall ABOVE the reserve an honest fill would have left:
        //         after = before - outJit
        //               = (before - outHonest) + shortfall.
        uint256 feeIn = (W.a.balanceOf(T1) - before[6]) + (W.a.balanceOf(T2) - before[7]);
        uint256 routedIn = AMOUNT_IN - feeIn;
        assertEq(W.a.balanceOf(routed) - before[0], routedIn,
            "the venue's received-token reserve rises by exactly the routed input");
        assertEq(W.a.balanceOf(routed) - before[0] + feeIn, AMOUNT_IN,
            "the user's input is fully accounted: venue + protocol fee");
        assertEq(rec.lastOut(), outJit, "the venue disbursed exactly the user's output");
        assertEq(before[1] - W.b.balanceOf(routed), outJit,
            "the venue's tokenOut reserve falls by exactly the user's output");
        assertEq(W.b.balanceOf(user) - before[2], outJit,
            "the user's output delta is exactly that disbursement");
        // (c) the shortfall is retained value in that venue, not burned/dusted.
        uint256 shortfall = outHonest - outJit;
        assertGt(shortfall, 0, "the live window cuts the user's output below honest");
        assertEq(W.b.balanceOf(routed), before[1] - outHonest + shortfall,
            "the venue's tokenOut reserve is the honest-fill reserve plus the shortfall");
        assertEq(W.b.balanceOf(curated), before[3],
            "the honest venue never touches tokenB in the live window");
        assertEq(W.b.balanceOf(rtr), before[4],
            "the Router retains no tokenB: nothing is stuck mid-route");
        assertEq(W.b.totalSupply(), before[5], "tokenB is not minted or burned");
        uint256 sumAfter = W.b.balanceOf(user) + W.b.balanceOf(routed)
            + W.b.balanceOf(curated) + W.b.balanceOf(rtr);
        assertEq(sumAfter, before[2] + before[1] + before[3] + before[4],
            "tokenB is conserved across user, attacker venue, honest venue and Router");
    }

}

/// @dev Minimal V4 PoolManager state mock: exactly the single-slot extsload
///      reads claimV4's on-chain proof (BPC.v4SqrtAndLiq) and the Solver's V4
///      quote perform.
contract F19V4StateManager {
    mapping(bytes32 => bytes32) public slots;
    function setSlot(bytes32 s, bytes32 v) external { slots[s] = v; }
    function extsload(bytes32 s) external view returns (bytes32) { return slots[s]; }
    /// @dev Write the singleton's live pool state: slot0 (sqrtP + tick) at base,
    ///      liquidity at base+3.
    function setPool(bytes32 pid, uint160 sqrtP, int24 tick, uint128 liq) external {
        bytes32 base = keccak256(abi.encode(pid, uint256(6)));
        slots[base] = bytes32(uint256(sqrtP) | (uint256(uint24(tick)) << 160));
        slots[bytes32(uint256(base) + 3)] = bytes32(uint256(liq));
    }
    /// @dev Collapse only the live liquidity, leaving slot0 untouched.
    function setLiq(bytes32 pid, uint128 liq) external {
        bytes32 base = keccak256(abi.encode(pid, uint256(6)));
        slots[bytes32(uint256(base) + 3)] = bytes32(uint256(liq));
    }
}

interface IF19Erc20Rec {
    function transfer(address to, uint256 amt) external returns (bool);
    function balanceOf(address who) external view returns (uint256);
}

/// @dev Same shape as MockV2Pair, but every swap RECORDS the tokenOut it
///      disburses and the balance of the received side at the moment of the
///      call, so a routed leg can be named as "this venue, which received X and
///      paid out Y". `getReserves()` still answers the DECLARED reserves, exactly
///      like MockV2Pair, so the Router's quote and the registry depth are
///      unchanged by the recording (`heldBy` reads real balances separately).
contract F19RecordingV2Pair {
    address public token0;
    address public token1;
    uint112 public reserve0;
    uint112 public reserve1;

    uint256 public swaps;
    uint256 public lastInBalance;
    uint256 public lastOut;
    address public lastTo;

    constructor(address _token0, address _token1) {
        (token0, token1) = _token0 < _token1 ? (_token0, _token1) : (_token1, _token0);
    }

    function setReserves(uint112 r0, uint112 r1) external { reserve0 = r0; reserve1 = r1; }

    function getReserves() external view returns (uint112, uint112, uint32) {
        return (reserve0, reserve1, uint32(block.timestamp));
    }

    function holdings() external view returns (uint256 h0, uint256 h1) {
        h0 = IF19Erc20Rec(token0).balanceOf(address(this));
        h1 = IF19Erc20Rec(token1).balanceOf(address(this));
    }

    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata) external {
        swaps += 1;
        lastTo = to;
        // The Router pays tokenIn BEFORE swap(): the received side is the one not
        // being disbursed. Its balance here already includes the input.
        lastInBalance = amount0Out > 0
            ? IF19Erc20Rec(token1).balanceOf(address(this))
            : IF19Erc20Rec(token0).balanceOf(address(this));
        lastOut = amount0Out + amount1Out;
        if (amount0Out > 0) IF19Erc20Rec(token0).transfer(to, amount0Out);
        if (amount1Out > 0) IF19Erc20Rec(token1).transfer(to, amount1Out);
        reserve0 = uint112(IF19Erc20Rec(token0).balanceOf(address(this)));
        reserve1 = uint112(IF19Erc20Rec(token1).balanceOf(address(this)));
    }
}

contract Fix1019JitLiveWindowTest is F19H15Base {
    struct LW {
        BlazePhoenixSolver sol;
        BlazePhoenixRouter rtr;
        RoutePlan planHonest;
        uint256 outHonest;
    }

    function _liveWorld() internal returns (H17World memory W, LW memory L) {
        F19V4StateManager mgr;
        (W, mgr) = _mkClaimWorld();
        W.hub.addBridge(address(W.a));
        L.sol = new BlazePhoenixSolver(address(W.hub));
        L.rtr = new BlazePhoenixRouter(address(W.hub), address(L.sol), address(this), T1, T2);
        W.solver = L.sol;
        W.router = L.rtr;
        W.hub.setRoles(address(L.rtr), address(L.sol), address(this));
        _fillOffSquatters(W, 15, 2e16, 1e16);
        MockV3Pool curated = new MockV3Pool(address(W.a), address(W.b), POOL_FEE);
        curated.setState(SQRT_P_1, LIQ);
        W.a.mint(address(curated), HOLD);
        W.b.mint(address(curated), HOLD);
        W.hub.seedPool(address(curated), BPC.KIND_V3, POOL_FEE, address(0), address(W.a), address(W.b));
        W.a.mint(user, 1_000_000e18);
        vm.prank(user);
        W.a.approve(address(L.rtr), type(uint256).max);

        // The honest quote, before the attacker's bundle: what the planner shows.
        L.planHonest = L.sol.findBestRoutePlan(address(W.a), address(W.b), AMOUNT_IN);
        uint256 snap = vm.snapshotState();
        vm.prank(user);
        L.outHonest = L.rtr.swapBestExactIn(address(W.a), address(W.b), AMOUNT_IN, 1, user, block.timestamp + 1);
        vm.revertToState(snap);

        // Same block, front-run: plant the JIT book and claim it.
        _plantV4(W, mgr, 3000, 60, uint128(1e24));
        (address s0, address s1) = BPC.sortTokens(address(W.a), address(W.b));
        bytes32 pid = BPC.computeV4PoolId(s0, s1, 3000, 60, address(0));
        mgr.setPool(pid, BPC.sqrtPriceAtTick(-6932), -6932, uint128(1e24));
        W.hub.claimV4(address(W.a), address(W.b), 3000, 60);
    }

    /// Pin, both eras. Red iff userMinOut stops reaching settlement on either door, or the
    /// fixed route starts reading the live anchor.
    function test_H15_LiveWindow_HonestUserMinOut_RevertsOnBestDoor_FixedRouteSettles() public {
        (H17World memory W, LW memory L) = _liveWorld();
        uint256 minOut = L.outHonest * 9_950 / 10_000;
        address a = address(W.a);
        address b = address(W.b);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, uint16(5)));
        L.rtr.swapBestExactIn(a, b, AMOUNT_IN, minOut, user, block.timestamp + 1);

        Route memory fixedRoute = L.planHonest.best;
        vm.prank(user);
        uint256 outFixed = L.rtr.swapExactIn(fixedRoute, AMOUNT_IN, minOut, user, block.timestamp + 1);
        assertGe(outFixed, minOut, "the route fixed before the bundle still delivers the honest minimum");
    }

    /// Pin, both eras: the documented residual. With userMinOut = 1 the automatic door
    /// settles below the honest fill inside the live window. Red iff the live anchor stops
    /// steering (a hardening of the V4 vote or of claimV4) - then re-measure, do not delete.
    function test_H15_LiveWindow_UserMinOutOne_BestDoorSettlesBelowHonest() public {
        (H17World memory W, LW memory L) = _liveWorld();
        address a = address(W.a);
        address b = address(W.b);
        vm.prank(user);
        uint256 got = L.rtr.swapBestExactIn(a, b, AMOUNT_IN, 1, user, block.timestamp + 1);
        assertLt(got * 10_000, L.outHonest * 9_950, "the live window takes more than a 0.5 % slack");
        assertGt(got, 0, "and still settles: only userMinOut would have stopped it");
    }
}
