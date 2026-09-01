// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// ═════════════════════════════════════════════════════════════════════════════
//  FULL-STACK LOOP INVARIANT — the campaign that closes the registry cut.
//
//  The system's central feedback loop is:
//
//      swap executes ─→ Router calls Hub.recordSwap ─→ registry state shapes
//      discovery and ranking ─→ Solver plans the next route from that state
//      ─→ the next swap.
//
//  EVERY existing stateful campaign cuts this loop, silently and in the same
//  way. BlazePhoenixRouter.invariant.t.sol never calls hub.initialize or
//  hub.setRoles, so recordSwap's onlyRouter rejects the Router on every fuzzed
//  swap and the Router's `try {} catch {}` in _recordHits swallows it — the
//  registry stays empty for the entire campaign. RouterStatefulConservation-
//  FromV1 and RouterAdversarialInvariantFromV1 initialize but never setRoles:
//  same cut. HubInvariantFromV1 wires roles to its HANDLER and performs no
//  Router execution at all. And swapBestExactIn — the door through which the
//  Solver's plan actually meets the Router — appears in NO invariant handler
//  anywhere. So every conservation and holds-nothing green in this repo is
//  proven over a system whose registry never moves and whose planner is never
//  consulted.
//
//  This suite deploys the FULL stack, wires the roles for real, starts with an
//  EMPTY registry (deliberately: nothing is seeded, so any non-zero slot that
//  ever appears was written by recordSwap through the authorised Router — an
//  airtight witness that the loop closed), and drives two interleaved doors:
//    * manualSwap  — a hand-built single-leg V2 route through swapExactIn;
//    * plannedSwap — the Solver's own plan through swapBestExactIn.
//  Discovery bootstraps the planner (one factory-listed pool per pair); the
//  first executed swaps register pools; later plans read the registry those
//  swaps populated. Two of the A/B pools are NOT factory-listed, so the ONLY
//  way the planner can ever see them is the loop itself: a manual swap
//  registers them via recordSwap, and from then on getActivePools serves them
//  to the Solver. That dependency is what this campaign exercises and what
//  afterInvariant refuses to let go vacuous.
//
//  forge test --match-contract FullStackLoop -vv
// ═════════════════════════════════════════════════════════════════════════════

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {
    BlazePhoenixCore as BPC,
    PoolInfo, Route, Hop, Leg, RoutePlan
} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";
import {MockV2Factory} from "./mocks/MockV2Factory.sol";

/// @notice Handler driving the two doors of the loop. Both actions are wrapped
///         in try/catch: a revert (slippage band, no route between the chosen
///         tokens, a floor) is a normal, expected outcome and must not corrupt
///         state — the invariants below check exactly that. The fuzzer
///         interleaves the two selectors across each run (see the
///         targetSelector filter in setUp), so hand-built executions and
///         planned executions alternate over the same evolving registry.
contract FullStackLoopHandler is Test {
    BlazePhoenixHub public hub;
    BlazePhoenixRouter public router;
    BlazePhoenixSolver public solver;
    MockERC20[] public tokens;
    MockV2Pair[] public pools;
    address public immutable recipient;

    // ─── Conservation ghost ────────────────────────────────────────────
    // Everything ever minted into the test universe, per token. Seeded at
    // construction from each mock's totalSupply (the pool liquidity minted in
    // setUp), then bumped on every mint this handler performs. The suite's
    // conservation invariant compares this against the sum over the CLOSED
    // set of legitimate holders.
    mapping(address => uint256) public ghost_minted;

    // ─── Loop counters, one per rung ───────────────────────────────────
    uint256 public manualCalls;
    uint256 public manualSettles;
    uint256 public plannedCalls;
    uint256 public plannedPlans;      // Solver returned a plan
    uint256 public plannedSettles;    // ...and the Router executed it
    uint256 public plannedRefusals;   // Solver or Router refused — the explicit-refusal arm
    // recordSwap landings, measured from OUTSIDE the Router's swallow-all
    // catch: a leg's registry slot observed to change across a settled swap.
    // The Router gives no other observable (the `try hub.recordSwap {} catch {}`
    // in _recordHits reports nothing), and this campaign starts with an EMPTY,
    // never-seeded registry — so the first landing per pool is a 0 → non-zero
    // registration only recordSwap-through-the-authorised-Router can produce.
    uint256 public recordSwapLandings;
    // Set if a Solver plan SETTLED while containing a leg whose pool neither
    // the registry (getPool under the hop-pair key) nor discovery (discoverFor
    // over the same pair) attests. The Solver builds candidates exclusively
    // from getActivePools ∪ discoverFor (_topKPools), so this firing means a
    // plan reached execution against a pool the Hub never vouched for.
    bool public ghost_unattestedPlanSettled;

    // The 6 ordered (tokenIn, tokenOut) combinations over the 3-token universe,
    // enumerated once so the planned door can pick one by hashed seed.
    address[] internal pinsIn;
    address[] internal pinsOut;

    constructor(
        BlazePhoenixHub _hub, BlazePhoenixRouter _router, BlazePhoenixSolver _solver,
        MockERC20[] memory _tokens, MockV2Pair[] memory _pools, address _recipient
    ) {
        hub = _hub; router = _router; solver = _solver; recipient = _recipient;
        for (uint256 i; i < _tokens.length; ++i) {
            tokens.push(_tokens[i]);
            // Snapshot every unit already minted before the campaign starts
            // (the pool liquidity). MockERC20 only creates supply via mint(),
            // so totalSupply is exactly the ghost's correct opening balance.
            ghost_minted[address(_tokens[i])] = _tokens[i].totalSupply();
        }
        for (uint256 i; i < _pools.length; ++i) pools.push(_pools[i]);
        for (uint256 i; i < _tokens.length; ++i) {
            for (uint256 j; j < _tokens.length; ++j) {
                if (i == j) continue;
                pinsIn.push(address(_tokens[i]));
                pinsOut.push(address(_tokens[j]));
            }
        }
    }

    function tokensLength() external view returns (uint256) { return tokens.length; }
    function poolsLength() external view returns (uint256) { return pools.length; }

    // ─── Door 1: hand-built route through swapExactIn ──────────────────

    function manualSwap(uint256 poolSeed, uint256 amtSeed, uint256 minOutSeed, bool reverse) external {
        manualCalls++;
        // HASH THE SEED BEFORE INDEXING. forge's fuzz dictionary is heavily
        // weighted toward boundary values (0, 1, type(uint256).max), so a bare
        // `seed % n` lands on the same pool for most of a run — the two
        // non-factory-listed A/B pools would then never be touched and the
        // loop's "registration makes a pool visible to the planner" arm would
        // go unexercised. Hashing flattens the distribution.
        MockV2Pair pool = pools[uint256(keccak256(abi.encode(poolSeed))) % pools.length];
        address t0 = pool.token0();
        address t1 = pool.token1();
        (address tIn, address tOut) = reverse ? (t1, t0) : (t0, t1);

        uint256 amountIn = bound(amtSeed, 1e15, 500e18);
        MockERC20(tIn).mint(address(this), amountIn);
        ghost_minted[tIn] += amountIn;
        MockERC20(tIn).approve(address(router), amountIn);

        (uint112 r0, uint112 r1, ) = pool.getReserves();
        uint256 rIn = tIn == t0 ? r0 : r1;
        uint256 rOut = tIn == t0 ? r1 : r0;
        uint256 quoted = BPC.outV2(amountIn, rIn, rOut, 30);
        if (quoted == 0) return;

        Leg[] memory legs = new Leg[](1);
        legs[0] = Leg({
            pool: address(pool), hooks: address(0), kind: BPC.KIND_V2, fee: 30,
            tickSpacing: 0, zeroForOne: tIn == t0, stable: false,
            amountIn: amountIn, expectedOut: quoted, auxId: bytes32(0)
        });
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({tokenIn: tIn, tokenOut: tOut, amountIn: amountIn, expectedOut: quoted, legs: legs});
        Route memory route = Route({
            hops: hops, totalOut: quoted, singleOut: quoted, singleOutFloor: 0,
            expectedImpactBps: 0, confidenceWad: 0, estGas: 0,
            hasSurplus: false, isV4Bundle: false
        });

        // BP-04: userMinOut must be a real bound in [1, quoted]. Draws in the
        // narrow post-fee band exercise the user-slippage refusal; the rest
        // settle. Both are normal outcomes.
        uint256 minOut = bound(minOutSeed, 1, quoted);

        // Snapshot the leg's registry slot so the recordSwap landing is
        // measured, not assumed: the Router swallows the recordSwap outcome.
        bytes32 key = hub.keyOf(address(pool), tIn, tOut);
        uint256 slotBefore = hub.getSlot(key);

        try router.swapExactIn(route, amountIn, minOut, recipient, block.timestamp + 1) returns (uint256) {
            manualSettles++;
            // 0 → non-zero is a registration only the authorised Router can
            // have produced (nothing here ever calls seedPool/addV4); a
            // changed non-zero slot is a tick (swap-count bits move even
            // within one block). Either way, recordSwap LANDED.
            if (hub.getSlot(key) != slotBefore) recordSwapLandings++;
        } catch {
            // Expected: slippage band, floors. Nothing to record — the
            // invariants confirm no state was corrupted by the attempt.
        }
    }

    // ─── Door 2: Solver-planned route through swapBestExactIn ──────────

    function plannedSwap(uint256 pairSeed, uint256 amtSeed) external {
        plannedCalls++;
        uint256 pi = uint256(keccak256(abi.encode(pairSeed))) % pinsIn.length; // hashed: see manualSwap
        address tIn = pinsIn[pi];
        address tOut = pinsOut[pi];
        uint256 amountIn = bound(amtSeed, 1e15, 500e18);

        // Ask the planning door FIRST, standalone, so the plan can be
        // inspected before execution. findBestRoutePlan is a view, and no
        // state changes between this call and the re-solve inside
        // swapBestExactIn below (same block, same registry), so the inspected
        // plan IS the executed plan.
        RoutePlan memory plan;
        try solver.findBestRoutePlan(tIn, tOut, amountIn) returns (RoutePlan memory p) {
            plan = p;
            plannedPlans++;
        } catch {
            // SolverE(5) "no route" for the pair with no venue and no bridge
            // path, SolverE(4) for degenerate inputs — the explicit-refusal
            // arm of the invariant: refusing IS a correct answer.
            plannedRefusals++;
            return;
        }

        bool attested = _planAttested(plan.best);

        // Snapshot every planned leg's registry slot (multi-hop plans touch
        // one pair per hop) so a landing on ANY leg is observable.
        uint256 nLegs;
        for (uint256 h; h < plan.best.hops.length; ++h) nLegs += plan.best.hops[h].legs.length;
        bytes32[] memory keys = new bytes32[](nLegs);
        uint256[] memory slotsBefore = new uint256[](nLegs);
        {
            uint256 k;
            for (uint256 h; h < plan.best.hops.length; ++h) {
                Hop memory hop = plan.best.hops[h];
                for (uint256 l; l < hop.legs.length; ++l) {
                    keys[k] = hub.keyOf(hop.legs[l].pool, hop.tokenIn, hop.tokenOut);
                    slotsBefore[k] = hub.getSlot(keys[k]);
                    ++k;
                }
            }
        }

        MockERC20(tIn).mint(address(this), amountIn);
        ghost_minted[tIn] += amountIn;
        MockERC20(tIn).approve(address(router), amountIn);

        // userMinOut = 1: minimal but valid under BP-04. The slippage-band
        // search belongs to the manual door, where a local quote exists to
        // bound against; this door's job is the plan→execute seam, and the
        // Router still enforces its own floors and the plan's singleOutFloor
        // regardless of how permissive the user bound is.
        try router.swapBestExactIn(tIn, tOut, amountIn, 1, recipient, block.timestamp + 1) returns (uint256) {
            plannedSettles++;
            if (!attested) ghost_unattestedPlanSettled = true;
            for (uint256 k; k < nLegs; ++k) {
                if (hub.getSlot(keys[k]) != slotsBefore[k]) { recordSwapLandings++; break; }
            }
        } catch {
            // The Router refusing a plan it cannot execute is the OTHER
            // correct outcome the invariant names.
            plannedRefusals++;
        }
    }

    /// @dev A plan is attested when every leg's pool is vouched for by the Hub
    ///      for that hop's pair: either registered (getPool under the keyOf of
    ///      pool + hop tokens resolves to the pool) or served by discovery
    ///      (discoverFor over the same pair lists it). These are exactly the
    ///      two sources _topKPools unions, so an unattested leg means the plan
    ///      settles against a pool the registry does not stand behind.
    function _planAttested(Route memory r) internal view returns (bool) {
        for (uint256 h; h < r.hops.length; ++h) {
            Hop memory hop = r.hops[h];
            PoolInfo[] memory dis = hub.discoverFor(hop.tokenIn, hop.tokenOut);
            for (uint256 l; l < hop.legs.length; ++l) {
                address p = hop.legs[l].pool;
                if (hub.getPool(hub.keyOf(p, hop.tokenIn, hop.tokenOut)) == p) continue;
                bool found;
                for (uint256 d; d < dis.length; ++d) {
                    if (dis[d].pool == p) { found = true; break; }
                }
                if (!found) return false;
            }
        }
        return true;
    }
}

contract FullStackLoopInvariantTest is StdInvariant, Test {
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    BlazePhoenixRouter router;
    MockV2Factory factory;
    FullStackLoopHandler handler;

    MockERC20[] tokens;   // [A, B, C]
    MockV2Pair[] pools;   // [AB1, AB2, AB3, BC1]

    address recipient = address(0xD00D);
    address treasury1 = address(0xFEE1);
    address treasury2 = address(0xFEE2);

    // Mirror of BlazePhoenixHub.MAX_SLOTS (internal there). With only four
    // honest venues in this universe the bound is slack locally — the
    // fill-and-evict search lives in HubInvariantFromV1, whose handler stands
    // up 24 stubs on one pair. This suite asserts the bound over a registry
    // populated by REAL executions, which no other campaign produces at all.
    uint256 constant MAX_SLOTS = 16;

    function setUp() public {
        // ─── Full stack, ROLES ACTUALLY WIRED ──────────────────────────
        // This is the wire every other Router campaign left loose: without
        // BOTH initialize and setRoles naming the Router, recordSwap's
        // onlyRouter rejects it and _recordHits' catch hides the rejection.
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        solver = new BlazePhoenixSolver(address(hub));
        router = new BlazePhoenixRouter(address(hub), address(solver), address(this), treasury1, treasury2);
        hub.setRoles(address(router), address(solver), address(this));

        // ─── Token + pool universe ─────────────────────────────────────
        MockERC20 A = new MockERC20("A", "A");
        MockERC20 B = new MockERC20("B", "B");
        MockERC20 C = new MockERC20("C", "C");
        tokens.push(A); tokens.push(B); tokens.push(C);

        // Three A/B pools at the SAME rate (1 : 1.6) and different depths, so
        // once the loop registers them the Solver's median-rate filter keeps
        // all three and depth-weighted splits become reachable. One B/C pool
        // completes the bridge topology A → B → C.
        pools.push(_makePool(A, B, 100_000e18, 160_000e18)); // AB1 — factory-listed
        pools.push(_makePool(A, B, 200_000e18, 320_000e18)); // AB2 — loop-only (see below)
        pools.push(_makePool(A, B, 400_000e18, 640_000e18)); // AB3 — loop-only
        pools.push(_makePool(B, C, 150_000e18, 150_000e18)); // BC1 — factory-listed

        // ─── Discovery has something to find ───────────────────────────
        // Mode 0 (factory-call, getPair) needs no initHash. One pool per pair
        // is factory-listed; AB2/AB3 are deliberately NOT — the only channel
        // through which the planner can ever see them is a manual swap
        // registering them via recordSwap. That asymmetry is the loop made
        // observable: registry state (not static wiring) shapes later plans.
        factory = new MockV2Factory();
        hub.addFactory(address(factory), BPC.KIND_V2, 0, bytes32(0), new uint24[](0), new int24[](0));
        factory.setPair(address(A), address(B), address(pools[0]));
        factory.setPair(address(B), address(C), address(pools[3]));

        // B bridges A ↔ C, so the planned door also exercises two-hop routes
        // (there is no direct A/C venue anywhere).
        hub.addBridge(address(B));

        // ─── DELIBERATELY NO seedPool ──────────────────────────────────
        // The registry starts EMPTY. Every non-zero slot the campaign ever
        // observes was therefore written by recordSwap through the authorised
        // Router — the airtight witness afterInvariant's rung 2 relies on.

        handler = new FullStackLoopHandler(hub, router, solver, tokens, pools, recipient);
        targetContract(address(handler));
        // SPEND THE CALL BUDGET ON THE TWO DOORS, NOT ON forge-std. The
        // handler inherits Test → StdInvariant, which carries a dozen public
        // functions of its own; without a selector filter only a fraction of
        // each run's calls would reach the loop.
        bytes4[] memory sels = new bytes4[](2);
        sels[0] = FullStackLoopHandler.manualSwap.selector;
        sels[1] = FullStackLoopHandler.plannedSwap.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: sels}));
    }

    /// @dev Real balances == reserves, so the mock pair (which pays out of its
    ///      actual balance and re-syncs reserves afterward) behaves like a
    ///      real constant-product pool for the whole campaign. The liquidity
    ///      minted here is captured by the handler's ghost at construction.
    function _makePool(MockERC20 x, MockERC20 y, uint256 depthX, uint256 depthY)
        internal returns (MockV2Pair p)
    {
        p = new MockV2Pair(address(x), address(y));
        x.mint(address(p), depthX);
        y.mint(address(p), depthY);
        (address t0, ) = address(x) < address(y)
            ? (address(x), address(y)) : (address(y), address(x));
        p.setReserves(
            uint112(t0 == address(x) ? depthX : depthY),
            uint112(t0 == address(x) ? depthY : depthX)
        );
    }

    // ═════════════════════════════════════════════════════════════════════
    //  Invariants
    // ═════════════════════════════════════════════════════════════════════

    /// @notice LEDGER CONSERVATION over the whole interleaved sequence: for
    ///         each token, the sum over the closed set of legitimate holders
    ///         (handler-as-swapper, recipient, Router, treasuries, pools)
    ///         equals everything ever minted. The Hub, the Solver and the
    ///         factory are DELIBERATELY excluded from the sum — none of them
    ///         may ever hold a token, so value leaking to any of them (or to
    ///         any address outside this set) breaks the equality instead of
    ///         hiding inside it. Creation breaks it in the other direction.
    function invariant_TokenConservation() public view {
        for (uint256 i; i < tokens.length; ++i) {
            MockERC20 t = tokens[i];
            uint256 sum = t.balanceOf(address(handler))
                + t.balanceOf(recipient)
                + t.balanceOf(address(router))
                + t.balanceOf(treasury1)
                + t.balanceOf(treasury2);
            for (uint256 j; j < pools.length; ++j) sum += t.balanceOf(address(pools[j]));
            assertEq(sum, handler.ghost_minted(address(t)),
                "a token was created or destroyed (or leaked outside the closed holder set)");
        }
    }

    /// @notice The Router must never retain a balance of any token at rest,
    ///         across hand-built AND planned executions interleaved — the
    ///         planned door crosses the selfExecutePrePulled bridge, a path no
    ///         holds-nothing invariant has ever covered.
    function invariant_RouterHoldsNothing() public view {
        for (uint256 i; i < tokens.length; ++i) {
            assertEq(tokens[i].balanceOf(address(router)), 0,
                "Router retained a residual token balance at rest");
        }
    }

    /// @notice No pair the loop touches may ever exceed MAX_SLOTS active
    ///         registry entries — asserted here over slots written by REAL
    ///         routed executions (every other campaign's registry never moves,
    ///         so this bound had never been checked on the recordSwap path).
    function invariant_RegistryNeverExceedsMaxSlots() public view {
        for (uint256 i; i < tokens.length; ++i) {
            for (uint256 j = i + 1; j < tokens.length; ++j) {
                assertLe(hub.getActivePools(address(tokens[i]), address(tokens[j])).length, MAX_SLOTS,
                    "a pair exceeded MAX_SLOTS active registry entries");
            }
        }
    }

    /// @notice Every active registry entry must resolve to a pool that exists:
    ///         non-zero AND carrying code. The code check is the sharp half —
    ///         recordSwap's pair-proof exists precisely so a fabricated,
    ///         codeless address can never enter the registry, and an entry
    ///         without code would send the Solver quoting into the void.
    function invariant_ActiveEntriesResolveToRealPools() public view {
        for (uint256 i; i < tokens.length; ++i) {
            for (uint256 j = i + 1; j < tokens.length; ++j) {
                PoolInfo[] memory ps = hub.getActivePools(address(tokens[i]), address(tokens[j]));
                for (uint256 k; k < ps.length; ++k) {
                    assertTrue(ps[k].pool != address(0), "active registry entry resolves to address(0)");
                    assertTrue(ps[k].pool.code.length != 0, "active registry entry resolves to a codeless pool");
                }
            }
        }
    }

    /// @notice A plan the Solver returns is either executed or explicitly
    ///         refused by the Router — and a plan that SETTLES may only touch
    ///         pools the Hub attests (registered under the hop-pair key, or
    ///         served by discovery for that pair). The refusal arm is
    ///         structurally guaranteed (every planned call ends in a return or
    ///         a caught revert); this assertion carries the half that is not:
    ///         no settlement against a pool the registry does not stand behind.
    function invariant_SettledPlansOnlyTouchAttestedPools() public view {
        assertFalse(handler.ghost_unattestedPlanSettled(),
            "a Solver plan settled against a pool neither the registry nor discovery attests");
    }

    // ═════════════════════════════════════════════════════════════════════
    //  NON-VACUITY OF THE LOOP ITSELF — the property nothing else checks.
    //  Each rung has its own message so a failure names the link that broke.
    // ═════════════════════════════════════════════════════════════════════

    function afterInvariant() public view {
        // Rung 1 — swaps settled. Gated on the budget actually being spent
        // (the repo's configured [invariant] runs/depth of 50x50 comfortably
        // clears 10 calls; a short custom run stays quiet instead of lying).
        if (handler.manualCalls() >= 10) {
            assertGt(handler.manualSettles(), 0,
                "LOOP RUNG 1 BROKE: the hand-built door never settled a swap (entry-guard regression?)");
        }

        // Rung 2 — THE CUT THIS SUITE EXISTS TO CLOSE. If any swap settled,
        // recordSwap must have landed at least once: the registry started
        // empty and unseeded, every pool here honestly answers the pair-proof,
        // and the first settled swap per pool has a whole pair of free slots —
        // there is no honest reason for zero landings except the Router not
        // being authorised (the exact silent state every previous campaign
        // fuzzed in). Unconditional on the budget: ONE settled swap suffices.
        if (handler.manualSettles() + handler.plannedSettles() > 0) {
            assertGt(handler.recordSwapLandings(), 0,
                "LOOP RUNG 2 BROKE: swaps settled but recordSwap never moved the registry (roles cut - onlyRouter rejecting the Router?)");
        }

        // Rungs 3 and 4 — the Solver door was exercised: plans were returned,
        // and at least one planned route settled through swapBestExactIn.
        // Same budget gate as rung 1; four of the six ordered pairs plan
        // directly off deterministic discovery, so ten calls cannot honestly
        // produce zero of either.
        if (handler.plannedCalls() >= 10) {
            assertGt(handler.plannedPlans(), 0,
                "LOOP RUNG 3 BROKE: the Solver never returned a plan (discovery or planning dead)");
            assertGt(handler.plannedSettles(), 0,
                "LOOP RUNG 4 BROKE: plans were returned but no planned route ever settled through swapBestExactIn");
        }
    }
}
