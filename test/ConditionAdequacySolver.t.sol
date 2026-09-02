// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  ConditionAdequacySolver — one test per sub-condition of BlazePhoenixSolver's
//  compound decisions that the MC/DC triage marked INERT or UNSURE.
//
//  Discipline: each test is built so that NEUTRALISING its target sub-condition
//  (replacing it with the identity of its connective: `true` inside &&, `false`
//  inside ||) flips the test's verdict. Wherever possible the oracle is an
//  EXACT equality computed from the same Core math the mocks execute, or an
//  exact SolverE code — never a bare expectRevert, never a bound both regimes
//  satisfy.
//
//  Line numbers in test names refer to src/BlazePhoenixSolver.sol at the
//  commit this file was written against.
//
//  NOT COVERABLE (verified structurally, not skipped): the `expectedOut == 0`
//  disjuncts at lines 406, 424, 471, 481 and 491. Every hop `_buildHop` or
//  `_singleLeg` can produce satisfies `expectedOut > 0 <=> legs.length > 0`
//  (legs are only emitted after outL > 0 / out_ > 0 checks, and totalOut sums
//  those legs), so the state where that disjunct alone decides — expectedOut
//  zero WITH legs — cannot be constructed; the sibling `legs.length == 0`
//  disjunct fires identically under neutralisation. Likewise `legIn == 0` at
//  line 1147: the phantom leg its neutralisation would emit (amountIn 0 on a
//  concentrated kind) makes `_legImpactBps` return BPS (impactV3Bps's
//  amountIn==0 arm), and the worst-leg ceilings at 1447/1498 then refuse any
//  route carrying it — the same empty-route outcome the live guard produces —
//  while in the min-split gate the dust-sized phantom single can never beat
//  the split. Redundant armour; no test can watch it from outside.
//
//  forge test --match-path test/ConditionAdequacySolver.t.sol -vv
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {
    BlazePhoenixCore as BPC,
    PoolInfo, Route, Hop, Leg, RoutePlan
} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";
import {MockV3Pool} from "./mocks/MockV3Pool.sol";
import {MockV2Factory} from "./mocks/MockV2Factory.sol";

abstract contract CABase is Test {
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    MockERC20 tokenA;
    MockERC20 tokenB;

    function _fresh() internal {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        solver = new BlazePhoenixSolver(address(hub));
        tokenA = new MockERC20("A", "A");
        tokenB = new MockERC20("B", "B");
    }

    /// Registered V2 pool. Mints exactly the reserves, so balanceOf == reserves.
    function _seedV2(address tX, address tY, uint256 rX, uint256 rY)
        internal returns (MockV2Pair p)
    {
        p = new MockV2Pair(tX, tY);
        MockERC20(tX).mint(address(p), rX);
        MockERC20(tY).mint(address(p), rY);
        (address t0, ) = tX < tY ? (tX, tY) : (tY, tX);
        p.setReserves(
            uint112(tX == t0 ? rX : rY),
            uint112(tX == t0 ? rY : rX)
        );
        hub.seedPool(address(p), BPC.KIND_V2, 30, address(0), tX, tY);
    }

    /// Registered V3 pool: state (sqrtP, L) decoupled from real holdings.
    function _seedV3(address tX, address tY, uint160 sqrtP, uint128 liq, uint256 holdingsOfY)
        internal returns (MockV3Pool p)
    {
        p = new MockV3Pool(tX, tY, 3000);
        p.setState(sqrtP, liq);
        if (holdingsOfY > 0) MockERC20(tY).mint(address(p), holdingsOfY);
        hub.seedPool(address(p), BPC.KIND_V3, 3000, address(0), tX, tY);
    }

    /// Unregistered pair with raw token0/token1 reserves — for factory discovery
    /// of pairs seedPool refuses (zero-address token).
    function _rawPair(address tX, address tY, uint112 r0, uint112 r1)
        internal returns (MockV2Pair p)
    {
        p = new MockV2Pair(tX, tY);
        p.setReserves(r0, r1);
    }

    function _noRoute() internal {
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixSolver.SolverE.selector, uint16(5)));
    }
}

// =============================================================================
//  Lines 289/293/297 c1 (`bX != address(0)`), 326 c1 (`x != address(0)`),
//  329 c2 (`y != address(0)`).
//
//  The zero-guards look self-healing because no registry pair (t, 0) exists in
//  any mock world. Here one DOES: a mode-0 factory answers getPair(0, t), so a
//  neutralised zero-guard completes a route through the zero "bridge" and the
//  canonical no-route refusal disappears. Real code must still refuse.
// =============================================================================
contract CAZeroSlotArms is CABase {
    uint256 constant AMT = 1_000e18;

    /// Discoverable (address(0), t) books for both endpoints. No (A,B) pool.
    function _zeroBooks() internal {
        MockV2Factory f = new MockV2Factory();
        hub.addFactory(address(f), BPC.KIND_V2, 0, bytes32(0), new uint24[](0), new int24[](0));
        MockV2Pair pA0 = _rawPair(address(0), address(tokenA), uint112(1_000_000e18), uint112(1_000_000e18));
        MockV2Pair p0B = _rawPair(address(0), address(tokenB), uint112(1_000_000e18), uint112(1_000_000e18));
        f.setPair(address(0), address(tokenA), address(pA0));
        f.setPair(address(0), address(tokenB), address(p0B));
    }

    /// Slot 0 empty. Neutralised, _planViaBridge(..., address(0)) finds the
    /// (0,A) and (0,B) books and returns a live 2-hop route instead of SolverE(5).
    function test_L289c1_EmptySlot0MustNotBecomeABridge() public {
        _fresh();
        _zeroBooks();
        _noRoute();
        solver.findBestRoutePlan(address(tokenA), address(tokenB), AMT);
    }

    /// Same world, slot 1's own zero-guard.
    function test_L293c1_EmptySlot1MustNotBecomeABridge() public {
        _fresh();
        _zeroBooks();
        _noRoute();
        solver.findBestRoutePlan(address(tokenA), address(tokenB), AMT);
    }

    /// Same world, slot 2's own zero-guard.
    function test_L297c1_EmptySlot2MustNotBecomeABridge() public {
        _fresh();
        _zeroBooks();
        _noRoute();
        solver.findBestRoutePlan(address(tokenA), address(tokenB), AMT);
    }

    /// Two-bridge outer guard. One legit bridge BR with only the C-stage book
    /// (BR,B); the A and B stages of the phantom x=0 topology exist as (A,0)
    /// and (0,BR) discoverable books. Real: every topology dies -> SolverE(5).
    /// Neutralised x!=0: A -> 0 -> BR -> B completes.
    function test_L326c1_ZeroCannotBeTheFirstOfTwoBridges() public {
        _fresh();
        MockERC20 br = new MockERC20("BR", "BR");
        hub.addBridge(address(br));
        _seedV2(address(br), address(tokenB), 1_000_000e18, 1_000_000e18);
        MockV2Factory f = new MockV2Factory();
        hub.addFactory(address(f), BPC.KIND_V2, 0, bytes32(0), new uint24[](0), new int24[](0));
        MockV2Pair pA0 = _rawPair(address(0), address(tokenA), uint112(1_000_000e18), uint112(1_000_000e18));
        MockV2Pair p0BR = _rawPair(address(0), address(br), uint112(1_000_000e18), uint112(1_000_000e18));
        f.setPair(address(0), address(tokenA), address(pA0));
        f.setPair(address(0), address(br), address(p0BR));
        _noRoute();
        solver.findBestRoutePlan(address(tokenA), address(tokenB), AMT);
    }

    /// Two-bridge inner guard, y == empty slot. Bridge BR has a stage-A book
    /// (A,BR) but no (BR,B); the phantom y=0 continuation (BR,0) and (0,B)
    /// exists via discovery. Real: SolverE(5). Neutralised y!=0: A->BR->0->B.
    function test_L329c2_ZeroCannotBeTheSecondOfTwoBridges() public {
        _fresh();
        MockERC20 br = new MockERC20("BR", "BR");
        hub.addBridge(address(br));
        _seedV2(address(tokenA), address(br), 1_000_000e18, 1_000_000e18);
        MockV2Factory f = new MockV2Factory();
        hub.addFactory(address(f), BPC.KIND_V2, 0, bytes32(0), new uint24[](0), new int24[](0));
        MockV2Pair pBR0 = _rawPair(address(0), address(br), uint112(1_000_000e18), uint112(1_000_000e18));
        MockV2Pair p0B = _rawPair(address(0), address(tokenB), uint112(1_000_000e18), uint112(1_000_000e18));
        f.setPair(address(0), address(br), address(pBR0));
        f.setPair(address(0), address(tokenB), address(p0B));
        _noRoute();
        solver.findBestRoutePlan(address(tokenA), address(tokenB), AMT);
    }
}

// =============================================================================
//  Lines 289/293/297 c2 (`bX != tIn`) and c3 (`bX != tOut`).
//
//  The endpoint-guards self-neutralise only while no (t,t) self-pair exists.
//  Registering one (seedPool accepts tA == tB) gives the endpoint-bridge arm a
//  live stage, and the phantom tIn->tIn->tOut (or tIn->tOut->tOut) route lands
//  in the accumulator as a fallback. The pin: with exactly one honest topology,
//  hasFallback MUST stay false.
// =============================================================================
contract CAEndpointBridgeArms is CABase {
    uint256 constant AMT = 1_000e18;

    function _directWorld() internal {
        _fresh();
        _seedV2(address(tokenA), address(tokenB), 1_000_000e18, 1_600_000e18);
    }

    function _selfPair(address t) internal returns (MockV2Pair) {
        // token0 == token1 == t; quotes like any 1:1 V2 book.
        MockV2Pair p = new MockV2Pair(t, t);
        MockERC20(t).mint(address(p), 2_000_000e18);
        p.setReserves(uint112(1_000_000e18), uint112(1_000_000e18));
        hub.seedPool(address(p), BPC.KIND_V2, 30, address(0), t, t);
        return p;
    }

    function _assertOnlyDirect() internal {
        RoutePlan memory plan = solver.findBestRoutePlan(address(tokenA), address(tokenB), AMT);
        assertEq(plan.best.hops.length, 1, "the direct route must win");
        assertFalse(plan.hasFallback,
            "one honest topology only: an endpoint-bridge arm produced a phantom fallback");
    }

    function test_L289c2_BridgeEqualToTokenInStaysDead() public {
        _directWorld();
        hub.addBridge(address(tokenA));      // slot 0 == tIn
        _selfPair(address(tokenA));          // gives the neutralised arm its stage A
        _assertOnlyDirect();
    }

    function test_L289c3_BridgeEqualToTokenOutStaysDead() public {
        _directWorld();
        hub.addBridge(address(tokenB));      // slot 0 == tOut
        _selfPair(address(tokenB));          // gives the neutralised arm its stage B
        _assertOnlyDirect();
    }

    function test_L293c2_Slot1BridgeEqualToTokenInStaysDead() public {
        _directWorld();
        MockERC20 dec = new MockERC20("DEC", "DEC");
        hub.addBridge(address(dec));         // slot 0: poolless decoy
        hub.addBridge(address(tokenA));      // slot 1 == tIn
        _selfPair(address(tokenA));
        _assertOnlyDirect();
    }

    function test_L293c3_Slot1BridgeEqualToTokenOutStaysDead() public {
        _directWorld();
        MockERC20 dec = new MockERC20("DEC", "DEC");
        hub.addBridge(address(dec));
        hub.addBridge(address(tokenB));      // slot 1 == tOut
        _selfPair(address(tokenB));
        _assertOnlyDirect();
    }

    function test_L297c2_Slot2BridgeEqualToTokenInStaysDead() public {
        _directWorld();
        MockERC20 d0 = new MockERC20("D0", "D0");
        MockERC20 d1 = new MockERC20("D1", "D1");
        hub.addBridge(address(d0));
        hub.addBridge(address(d1));
        hub.addBridge(address(tokenA));      // slot 2 == tIn
        _selfPair(address(tokenA));
        _assertOnlyDirect();
    }

    function test_L297c3_Slot2BridgeEqualToTokenOutStaysDead() public {
        _directWorld();
        MockERC20 d0 = new MockERC20("D0", "D0");
        MockERC20 d1 = new MockERC20("D1", "D1");
        hub.addBridge(address(d0));
        hub.addBridge(address(d1));
        hub.addBridge(address(tokenB));      // slot 2 == tOut
        _selfPair(address(tokenB));
        _assertOnlyDirect();
    }
}

// =============================================================================
//  Line 326 c2/c3 (`x != tIn` / `x != tOut`) and line 329 c3/c4
//  (`y != tIn` / `y != tOut`) — the two-bridge loop's endpoint guards.
//
//  Same observable as above: every stage of the forbidden 3-hop topology is
//  given a live book (self-pairs included), so only the guard under test keeps
//  the phantom route out of the accumulator. hasFallback pins it.
// =============================================================================
contract CATwoBridgeEndpoints is CABase {
    uint256 constant AMT = 1_000e18;

    function _selfPair(address t) internal returns (MockV2Pair) {
        MockV2Pair p = new MockV2Pair(t, t);
        MockERC20(t).mint(address(p), 2_000_000e18);
        p.setReserves(uint112(1_000_000e18), uint112(1_000_000e18));
        hub.seedPool(address(p), BPC.KIND_V2, 30, address(0), t, t);
        return p;
    }

    function _solveAndPin(uint256 expectHops) internal {
        RoutePlan memory plan = solver.findBestRoutePlan(address(tokenA), address(tokenB), AMT);
        assertEq(plan.best.hops.length, expectHops, "the honest topology must win");
        assertFalse(plan.hasFallback,
            "one honest topology only: an endpoint two-bridge arm produced a phantom fallback");
    }

    /// x == tIn. Honest route: A -> BR -> B. Phantom (neutralised): A->A->BR->B.
    function test_L326c2_FirstBridgeEqualToTokenInStaysDead() public {
        _fresh();
        MockERC20 br = new MockERC20("BR", "BR");
        hub.addBridge(address(tokenA));
        hub.addBridge(address(br));
        _seedV2(address(tokenA), address(br), 1_000_000e18, 1_000_000e18);
        _seedV2(address(br), address(tokenB), 1_000_000e18, 1_000_000e18);
        _selfPair(address(tokenA));
        _solveAndPin(2);
    }

    /// x == tOut. Honest route: direct. Phantom: A->B->BR->B.
    function test_L326c3_FirstBridgeEqualToTokenOutStaysDead() public {
        _fresh();
        MockERC20 br = new MockERC20("BR", "BR");
        hub.addBridge(address(tokenB));
        hub.addBridge(address(br));
        _seedV2(address(tokenA), address(tokenB), 1_000_000e18, 1_000_000e18);
        _seedV2(address(tokenB), address(br), 1_000_000e18, 1_000_000e18);
        _solveAndPin(1);
    }

    /// y == tIn. Honest route: direct. Phantom: A->BR->A->B.
    function test_L329c3_SecondBridgeEqualToTokenInStaysDead() public {
        _fresh();
        MockERC20 br = new MockERC20("BR", "BR");
        hub.addBridge(address(tokenA));
        hub.addBridge(address(br));
        _seedV2(address(tokenA), address(br), 1_000_000e18, 1_000_000e18);
        _seedV2(address(tokenA), address(tokenB), 1_000_000e18, 1_000_000e18);
        _solveAndPin(1);
    }

    /// y == tOut. Honest route: A -> BR -> B. Phantom: A->BR->B->B.
    function test_L329c4_SecondBridgeEqualToTokenOutStaysDead() public {
        _fresh();
        MockERC20 br = new MockERC20("BR", "BR");
        hub.addBridge(address(tokenB));
        hub.addBridge(address(br));
        _seedV2(address(tokenA), address(br), 1_000_000e18, 1_000_000e18);
        _seedV2(address(br), address(tokenB), 1_000_000e18, 1_000_000e18);
        _selfPair(address(tokenB));
        _solveAndPin(2);
    }
}

// =============================================================================
//  The band machinery inside _buildHop: the rate-copy insertion sort (634),
//  the all-dead scan bound (644), the dead-pool band conjunct (704), and the
//  weighted-median pair sort (1056).
// =============================================================================
contract CABandMachinery is CABase {
    /// L634 c2 (`sortedRates[j-1] > key`). Neutralised (always-shift) the copy
    ///  ends REVERSED from candidate order. With candidates live/dead/live the
    ///  reversed array is [live, 0, live]: firstNonZero=0, medianIdx=1 lands ON
    ///  the zero, and the median==0 refusal kills a perfectly routable hop.
    ///  Real code sorts zeros to the front and routes.
    function test_L634c2_DeadPoolBetweenLiveOnesStillRoutes() public {
        _fresh();
        _seedV2(address(tokenA), address(tokenB), 100_000e18, 160_000e18); // live
        MockV2Pair dead = new MockV2Pair(address(tokenA), address(tokenB));
        hub.seedPool(address(dead), BPC.KIND_V2, 30, address(0), address(tokenA), address(tokenB));
        _seedV2(address(tokenA), address(tokenB), 100_000e18, 160_000e18); // live

        // Neutralised, this call reverts SolverE(5); the asserts then never run.
        RoutePlan memory plan = solver.findBestRoutePlan(address(tokenA), address(tokenB), 1_000e18);
        assertEq(plan.best.hops.length, 1);
        assertGt(plan.best.totalOut, 0, "two live books must yield a route despite the dead one");
    }

    /// L644 c1 (`firstNonZero < n`). With EVERY candidate dead the real code
    ///  stops the scan at n and refuses with SolverE(5). Neutralised (bound
    ///  forced true) the scan reads sortedRates[n] and dies with Panic 0x32 —
    ///  a different revert, so the exact-code expectation fails.
    function test_L644c1_AllDeadCandidatesRefuseWithCode5NotPanic() public {
        _fresh();
        MockV2Pair d1 = new MockV2Pair(address(tokenA), address(tokenB));
        MockV2Pair d2 = new MockV2Pair(address(tokenA), address(tokenB));
        hub.seedPool(address(d1), BPC.KIND_V2, 30, address(0), address(tokenA), address(tokenB));
        hub.seedPool(address(d2), BPC.KIND_V2, 30, address(0), address(tokenA), address(tokenB));
        _noRoute();
        solver.findBestRoutePlan(address(tokenA), address(tokenB), 1_000e18);
    }

    /// L704 c1 (`r > 0`). The only regime where this conjunct decides is a
    ///  1-wei-per-1e18 band base (lo floors to 0). Built here: the live book
    ///  quotes 3 wei for the 2e18 probe -> rate exactly 1 -> lo == 0. Real code
    ///  drops the dead candidate on `r > 0`, keeps ONE survivor, and commits
    ///  the FULL order through the single-leg path. Neutralised, the dead pool
    ///  passes the band (0 >= 0 && 0 <= 1), survives into the weighted split,
    ///  and steals a share slice the quote loop then discards — the committed
    ///  input drops below the order.
    function test_L704c1_DeadPoolCannotEnterAWeiRateBand() public {
        _fresh();
        // rate(probe 2e18) = floor(1.994e18 * 250 / 161.994e18) = 3 -> rate 1.
        MockV2Pair live = new MockV2Pair(address(tokenA), address(tokenB));
        tokenA.mint(address(live), 160e18);
        tokenB.mint(address(live), 250);
        (address t0, ) = address(tokenA) < address(tokenB)
            ? (address(tokenA), address(tokenB)) : (address(tokenB), address(tokenA));
        live.setReserves(
            uint112(address(tokenA) == t0 ? 160e18 : 250),
            uint112(address(tokenA) == t0 ? 250 : 160e18)
        );
        hub.seedPool(address(live), BPC.KIND_V2, 30, address(0), address(tokenA), address(tokenB));
        MockV2Pair dead = new MockV2Pair(address(tokenA), address(tokenB));
        hub.seedPool(address(dead), BPC.KIND_V2, 30, address(0), address(tokenA), address(tokenB));

        RoutePlan memory plan = solver.findBestRoutePlan(address(tokenA), address(tokenB), 200e18);
        assertEq(plan.best.hops[0].legs.length, 1);
        assertEq(plan.best.hops[0].legs[0].amountIn, 200e18,
            "single survivor must commit the whole order; a share went to the dead pool");
    }

    /// L1056 c2 (`r[j-1] > kr`). Neutralised, the (rate, mass) pairs end in
    ///  reverse candidate order and the half-mass walk crosses on a DIFFERENT
    ///  rate. Layout chosen so the two walks pick different pools outright:
    ///  sorted crosses on the fair 1.0 pool; reversed crosses on the 1.3 pool.
    ///  The band then admits exactly one candidate each way — route identity
    ///  and exact output pin the sorted walk.
    function test_L1056c2_WeightedMedianWalksTheSortedPairs() public {
        _fresh();
        MockV2Pair fair = _seedV2(address(tokenA), address(tokenB), 400_000e18, 400_000e18); // rate ~1.0, mass 400k
        _seedV2(address(tokenA), address(tokenB), 500_000e18, 650_000e18);                   // rate ~1.3, mass 500k
        _seedV2(address(tokenA), address(tokenB), 300_000e18, 210_000e18);                   // rate ~0.7, mass 210k

        RoutePlan memory plan = solver.findBestRoutePlan(address(tokenA), address(tokenB), 1_000e18);
        assertEq(plan.best.hops[0].legs.length, 1, "band must keep exactly the median-rate pool");
        assertEq(plan.best.hops[0].legs[0].pool, address(fair),
            "the depth-weighted median must anchor on the fair pool, not the reversed-walk one");
        assertEq(plan.best.totalOut, BPC.outV2(1_000e18, 400_000e18, 400_000e18, 30));
    }
}

// =============================================================================
//  The capacity clamp's kind/balance conjuncts on the SPLIT path (line 799)
//  and the possible-regime cut guard (line 803 c2).
// =============================================================================
contract CAClampKinds is CABase {
    /// L799 c1 (`kindHas(A_CONC_POOL)`). Neutralised, the clamp reaches V2
    ///  legs. The binding regime — a split leg quoting past 30% of the pool's
    ///  tokenOut balance — is built here: two identical books splitting 150k
    ///  quote ~68.4k against a 48k cap each. Real code leaves reserve-family
    ///  promises untouched; the exact totalOut is the referent the wrong-kind
    ///  clamp cuts to 2 x 48k.
    function test_L799c1_ReserveFamilySplitLegsAreNeverCapacityClamped() public {
        _fresh();
        _seedV2(address(tokenA), address(tokenB), 100_000e18, 160_000e18);
        _seedV2(address(tokenA), address(tokenB), 100_000e18, 160_000e18);

        RoutePlan memory plan = solver.findBestRoutePlan(address(tokenA), address(tokenB), 150_000e18);
        assertEq(plan.best.hops[0].legs.length, 2, "equal books must split");
        uint256 legOut = BPC.outV2(75_000e18, 100_000e18, 160_000e18, 30);
        assertEq(plan.best.totalOut, 2 * legOut,
            "V2 promises must be the raw curve output; a 30%-of-balance cap bit them");
    }

    /// L799 c2 (`balsOut[i] > 0`). Neutralised, a concentrated split leg whose
    ///  pool holds ZERO tokenOut enters the clamp with cap = 0: the input cut
    ///  fires (quote > 0 = "balance"), keep collapses to 0 and the leg is
    ///  silently dropped. Real code skips the clamp for zero-balance books
    ///  (the V4 doctrine) and keeps the leg with its raw promise.
    function test_L799c2_ZeroBalanceConcLegKeepsItsRawPromise() public {
        _fresh();
        bool zfo = address(tokenA) < address(tokenB);
        uint128 L = uint128(1e21);
        _seedV3(address(tokenA), address(tokenB), uint160(BPC.Q96), L, 1_000e18); // funded twin
        _seedV3(address(tokenA), address(tokenB), uint160(BPC.Q96), L, 0);        // zero-balance twin

        RoutePlan memory plan = solver.findBestRoutePlan(address(tokenA), address(tokenB), 100e18);
        assertEq(plan.best.hops[0].legs.length, 2,
            "both twins must carry a leg; the zero-balance one was clamped to nothing");
        uint256 legOut = BPC.outV3(50e18, uint160(BPC.Q96), L, 3000, zfo, 0);
        assertEq(plan.best.totalOut, 2 * legOut);
    }

    /// L803 c2 (`outL > balsOut[i]`). Neutralised, the input-side cut fires on
    ///  an AGGRESSIVE-BUT-POSSIBLE leg (cap < quote <= holdings) — re-halving a
    ///  healthy fill, the exact regression the two-tier doctrine forbids. Real
    ///  code caps only the promise and commits the full share, so the hop's
    ///  committed input equals the order exactly (the phantom first leg's cut
    ///  cascades into the last leg, which absorbs it in full).
    function test_L803c2_PossibleRegimeSplitLegCommitsItsFullShare() public {
        _fresh();
        uint256 ORDER = 1_000e18;
        // cands[0]: deep-L phantom (dust holdings) — keeps the min-split gate's
        // single-leg fallback tiny so the split survives.
        _seedV3(address(tokenA), address(tokenB), uint160(BPC.Q96), uint128(1e26), 1e18);
        // last leg: possible regime — holdings 2x the order, cap 600e18 < quote.
        _seedV3(address(tokenA), address(tokenB), uint160(BPC.Q96), uint128(5e25), 2_000e18);

        RoutePlan memory plan = solver.findBestRoutePlan(address(tokenA), address(tokenB), ORDER);
        assertEq(plan.best.hops.length, 1);
        assertEq(plan.best.hops[0].amountIn, ORDER,
            "aggressive-but-possible legs commit in full; the input cut re-fired on a healthy fill");
    }
}

// =============================================================================
//  allowCut == false on bridge stages: line 803 c1 (split) and 1144 c1
//  (single leg). The documented incident — a stage-B leg input-cut, then
//  rescaled by the Router past its promise into a floor revert — has its
//  planner half pinned here: stage B must commit EVERYTHING stage A delivers.
// =============================================================================
contract CABridgeStageClamps is CABase {
    MockERC20 br;

    function _bridgeWorld() internal {
        _fresh();
        br = new MockERC20("BR", "BR");
        hub.addBridge(address(br));
        _seedV2(address(tokenA), address(br), 1_000_000e18, 1_000_000e18); // stage A
    }

    /// L803 c1 (`allowCut`). Stage-B SPLIT with phantom concentrated legs.
    ///  Real code (allowCut=false) caps promises only: committed == delivered.
    ///  Neutralised, both phantom legs are input-cut and the freed capital of
    ///  the LAST leg leaves the hop entirely — committed collapses to dust.
    function test_L803c1_BridgeStageSplitNeverInputCuts() public {
        _bridgeWorld();
        // (BR, B): phantom-deep first (gate saver), thin-healthy middle, phantom last.
        _seedV3(address(br), address(tokenB), uint160(BPC.Q96), uint128(1e26), 1e18);
        _seedV3(address(br), address(tokenB), uint160(BPC.Q96), uint128(1e21), 1_000_000e18);
        _seedV3(address(br), address(tokenB), uint160(BPC.Q96), uint128(9_999e22), 1e18);

        RoutePlan memory plan = solver.findBestRoutePlan(address(tokenA), address(tokenB), 1_000e18);
        assertEq(plan.best.hops.length, 2);
        assertEq(plan.best.hops[1].legs.length, 3, "all three stage-B legs must survive");
        assertEq(plan.best.hops[1].amountIn, plan.best.hops[0].expectedOut,
            "stage B must commit exactly what stage A delivers; an input cut leaked capital");
    }

    /// L1144 c1 (`allowCut` in _singleLeg). Single-candidate stage B on a
    ///  phantom book: real code keeps the full input and caps the promise.
    ///  Neutralised, the committed input is cut to promise-ratio dust — the
    ///  exact reversion of the 74bps floor-reject incident.
    function test_L1144c1_BridgeStageSingleLegNeverInputCuts() public {
        _bridgeWorld();
        _seedV3(address(br), address(tokenB), uint160(BPC.Q96), uint128(1e26), 1e18);

        RoutePlan memory plan = solver.findBestRoutePlan(address(tokenA), address(tokenB), 1_000e18);
        assertEq(plan.best.hops.length, 2);
        assertEq(plan.best.hops[1].legs.length, 1);
        assertEq(plan.best.hops[1].amountIn, plan.best.hops[0].expectedOut,
            "stage B single leg must commit the full stage-A delivery");
    }
}

// =============================================================================
//  Line 918 c2 (`alt.expectedOut > single.expectedOut`) — the min-split gate's
//  double fallback must adopt the alt single only when it is strictly BETTER.
// =============================================================================
contract CASplitGateAlt is CABase {
    /// Geometry: deep fair pool D (cands[0]), shallow better-priced S (best
    ///  marginal rate, WORSE at full size), and mid pool T dragging the split
    ///  below D's single. Real: gate collapses onto D exactly. Neutralised,
    ///  the worse alt S replaces D, the collapse threshold drops below the
    ///  split's total, and the 3-leg split is returned instead.
    function test_L918c2_WorseAltSingleMustNotLowerTheCollapseBar() public {
        _fresh();
        MockV2Pair D = _seedV2(address(tokenA), address(tokenB), 1_000_000e18, 1_000_000e18);
        _seedV2(address(tokenA), address(tokenB), 10_000e18, 10_200e18);   // S: rate 1.017, thin
        _seedV2(address(tokenA), address(tokenB), 300_000e18, 292_000e18); // T: rate 0.970, mid
        RoutePlan memory plan = solver.findBestRoutePlan(address(tokenA), address(tokenB), 1_000e18);
        assertEq(plan.best.hops[0].legs.length, 1, "the micro-split must collapse");
        assertEq(plan.best.hops[0].legs[0].pool, address(D),
            "collapse must land on the deep single, not the worse best-rate pool");
        assertEq(plan.best.totalOut, BPC.outV2(1_000e18, 1_000_000e18, 1_000_000e18, 30));
    }
}

// =============================================================================
//  _topKPools: the discovery dedup (1295 c1) and the fitness selection's three
//  conjuncts (1340), driven through the only regime where order is fatal —
//  more candidates than MAX_CANDIDATES(8), where the guillotine falls BEFORE
//  anything is quoted.
// =============================================================================
contract CATopK is CABase {
    /// L1295 c1 (`!dup`). A pool both registered and discoverable must enter
    ///  the funnel ONCE. Neutralised, its two copies split the order 50/50 and
    ///  the planner double-counts one book's liquidity: two legs, higher
    ///  phantom total. Real: one leg, full order, exact curve output.
    function test_L1295c1_RegisteredAndDiscoveredCopyIsOneCandidate() public {
        _fresh();
        MockV2Pair p = _seedV2(address(tokenA), address(tokenB), 100_000e18, 100_000e18);
        MockV2Factory f = new MockV2Factory();
        hub.addFactory(address(f), BPC.KIND_V2, 0, bytes32(0), new uint24[](0), new int24[](0));
        f.setPair(address(tokenA), address(tokenB), address(p));

        RoutePlan memory plan = solver.findBestRoutePlan(address(tokenA), address(tokenB), 20_000e18);
        assertEq(plan.best.hops[0].legs.length, 1, "the same pool entered the split twice");
        assertEq(plan.best.totalOut, BPC.outV2(20_000e18, 100_000e18, 100_000e18, 30));
    }

    function _dust(uint256 n) internal returns (MockV2Pair last) {
        for (uint256 i; i < n; ++i) {
            last = _seedV2(address(tokenA), address(tokenB), 2_000e18, 2_000e18);
        }
    }

    function _sawPool(RoutePlan memory plan, address pool) internal pure returns (bool saw) {
        Leg[] memory legs = plan.best.hops[0].legs;
        for (uint256 i; i < legs.length; ++i) if (legs[i].pool == pool) saw = true;
    }

    /// L1340 c1 (`ps[j] > ps[bestI]`). Nine candidates: eight junk-priced pools
    ///  registered first, the deep fair pool NINTH with real fitness (recorded
    ///  swaps). Real: fitness pulls it into the top-8, the band centers on it,
    ///  everything else is filtered — exact single-leg route. Neutralised, the
    ///  selection degrades to registration order (the fee tie-arm cannot fire:
    ///  the psis are UNEQUAL) and the guillotine cuts the only good book
    ///  before it is ever quoted.
    function test_L1340c1_FitnessMustBeatListOrderAtTheGuillotine() public {
        _fresh();
        hub.setRoles(address(this), address(solver), address(this));
        for (uint256 i; i < 8; ++i) {
            _seedV2(address(tokenA), address(tokenB), 100_000e18, 50_000e18); // rate ~0.5 junk
        }
        MockV2Pair deep = new MockV2Pair(address(tokenA), address(tokenB));
        tokenA.mint(address(deep), 1_000_000e18);
        tokenB.mint(address(deep), 1_000_000e18);
        deep.setReserves(uint112(1_000_000e18), uint112(1_000_000e18));
        for (uint256 i; i < 8; ++i) {
            hub.recordSwap(address(deep), BPC.KIND_V2, 30, address(0),
                address(tokenA), address(tokenB), 1e18, 1e18, 1_000_000e18);
        }

        RoutePlan memory plan = solver.findBestRoutePlan(address(tokenA), address(tokenB), 1_000e18);
        assertEq(plan.best.hops[0].legs.length, 1);
        assertEq(plan.best.hops[0].legs[0].pool, address(deep),
            "the high-fitness book was guillotined by list order");
        assertEq(plan.best.totalOut, BPC.outV2(1_000e18, 1_000_000e18, 1_000_000e18, 30));
    }

    /// L1340 c2 (`ps[j] == ps[bestI]`). The fee tie-break may fire ONLY at
    ///  equal fitness. Nine candidates: the deep pool plus seven thin books,
    ///  every one SEEDED (fee 30) then ticked once with identical volume and
    ///  depthWad — the same slot arithmetic, so psi is EXACTLY equal (8) for
    ///  all eight. A psi-1 junk book with the LOWEST fee is registered last.
    ///  (Seeding before ticking matters: recordSwap's cold-insert path
    ///  re-derives the fee via getV3Fee and would register the pool at fee 0,
    ///  handing it the cheapest-venue crown and hiding the mutation.)
    ///  Real: the junk pool never outranks psi 8; top-8 = the eight ticked
    ///  books, deep included. Neutralised, `fee < fee` fires at UNEQUAL psi:
    ///  the cheap junk book steals the first slot, its displaced victim — the
    ///  deep pool, swapped to the back — falls to the guillotine, and the
    ///  route loses the only real book.
    function test_L1340c2_FeeTieBreakOnlyAtEqualFitness() public {
        _fresh();
        hub.setRoles(address(this), address(solver), address(this));
        MockV2Pair deep = _seedV2(address(tokenA), address(tokenB), 1_000_000e18, 1_000_000e18);
        hub.recordSwap(address(deep), BPC.KIND_V2, 30, address(0),
            address(tokenA), address(tokenB), 1e18, 1e18, 1e18);
        for (uint256 i; i < 7; ++i) {
            MockV2Pair g = _seedV2(address(tokenA), address(tokenB), 2_000e18, 2_000e18);
            hub.recordSwap(address(g), BPC.KIND_V2, 30, address(0),
                address(tokenA), address(tokenB), 1e18, 1e18, 1e18);
        }
        // psi-1 (seeded, never ticked) fair-priced book with the lowest fee.
        MockV2Pair junk = new MockV2Pair(address(tokenA), address(tokenB));
        tokenA.mint(address(junk), 5_000e18);
        tokenB.mint(address(junk), 5_000e18);
        junk.setReserves(uint112(5_000e18), uint112(5_000e18));
        hub.seedPool(address(junk), BPC.KIND_V2, 5, address(0), address(tokenA), address(tokenB));

        RoutePlan memory plan = solver.findBestRoutePlan(address(tokenA), address(tokenB), 1_000e18);
        assertTrue(_sawPool(plan, address(deep)),
            "a lower-fee psi-1 pool displaced the deep book from the funnel");
    }

    /// L1340 c3 (`fee < fee`). At genuinely equal fitness AND equal fees the
    ///  tie must NOT swap (first listed wins). Neutralised (always-swap), the
    ///  selection rotates and the guillotine victim moves from the 9th book to
    ///  the 8th — where the deep pool sits. Its absence from the route is the
    ///  observable.
    function test_L1340c3_EqualFeeTieMustNotRotateTheGuillotine() public {
        _fresh();
        _dust(7);                                                            // a0..a6
        MockV2Pair deep = _seedV2(address(tokenA), address(tokenB), 1_000_000e18, 1_000_000e18); // a7
        _dust(1);                                                            // a8

        RoutePlan memory plan = solver.findBestRoutePlan(address(tokenA), address(tokenB), 1_000e18);
        assertTrue(_sawPool(plan, address(deep)),
            "an equal-fee tie rotated the deep book out through the guillotine");
    }
}

// =============================================================================
//  Line 1365 c1 (`last != 0`) — a never-ticked pool must count as STALE.
// =============================================================================
contract CARegistryFreshness is CABase {
    /// Built at block.timestamp == 0 so every registered slot carries
    ///  lastUpdateTs == 0 — the "never ticked" state no other test constructs.
    ///  Real: three never-ticked venues are NOT fresh, discovery runs, and the
    ///  vastly deeper factory book takes the route. Neutralised (`last != 0`
    ///  dropped), 0 <= TTL reads as fresh, discovery is skipped, and the
    ///  discovered book cannot appear.
    function test_L1365c1_NeverTickedRegistryMustStillDiscover() public {
        vm.warp(0);
        _fresh();
        _seedV2(address(tokenA), address(tokenB), 100_000e18, 100_000e18);
        _seedV2(address(tokenA), address(tokenB), 100_000e18, 100_000e18);
        _seedV2(address(tokenA), address(tokenB), 100_000e18, 100_000e18);

        MockV2Factory f = new MockV2Factory();
        hub.addFactory(address(f), BPC.KIND_V2, 0, bytes32(0), new uint24[](0), new int24[](0));
        MockV2Pair better = new MockV2Pair(address(tokenA), address(tokenB));
        tokenA.mint(address(better), 10_000_000e18);
        tokenB.mint(address(better), 100_000_000e18);
        (address t0, ) = address(tokenA) < address(tokenB)
            ? (address(tokenA), address(tokenB)) : (address(tokenB), address(tokenA));
        better.setReserves(
            uint112(address(tokenA) == t0 ? 10_000_000e18 : 100_000_000e18),
            uint112(address(tokenA) == t0 ? 100_000_000e18 : 10_000_000e18)
        );
        f.setPair(address(tokenA), address(tokenB), address(better));

        RoutePlan memory plan = solver.findBestRoutePlan(address(tokenA), address(tokenB), 1_000e18);
        Leg[] memory legs = plan.best.hops[0].legs;
        bool sawBetter;
        for (uint256 i; i < legs.length; ++i) if (legs[i].pool == address(better)) sawBetter = true;
        assertTrue(sawBetter,
            "never-ticked slots read as fresh: discovery was skipped and the real book missed");
    }
}

// =============================================================================
//  Line 1498 — the multi-hop impact ceiling's two arms. No existing test
//  builds a bridge route that reaches either arm.
// =============================================================================
contract CAMultiHopCeiling is CABase {
    MockERC20 br;

    /// L1498 c1 (`maxLegImpactBps >= MAX`). A destroyer leg DILUTED inside its
    ///  own hop: stage A splits across two deep-L phantom books (input-cut to
    ///  dust, ~30bps each) and a small-L destroyer that takes the cascaded
    ///  remainder at ~9860bps measured impact. Per-hop means stay ~3.3k, total
    ///  ~3.4k < 9000 — only the worst-leg arm refuses. Neutralised, the route
    ///  surfaces and the exact SolverE(5) expectation fails.
    function test_L1498c1_WorstLegArmAloneRefusesTheDilutedDestroyer() public {
        _fresh();
        br = new MockERC20("BR", "BR");
        hub.addBridge(address(br));
        bool aFirst = address(tokenA) < address(br);
        // Spot 1.69 in the trade direction: the destroyer's probe rate lands
        // back inside the band (~0.99) while its full-size fill measures ~9860.
        uint160 spD = aFirst
            ? uint160(BPC.Q96 * 13 / 10)
            : uint160(BPC.Q96 * 10 / 13);
        _seedV3(address(tokenA), address(br), uint160(BPC.Q96), uint128(1e26), 100e18);
        _seedV3(address(tokenA), address(br), uint160(BPC.Q96), uint128(1e26), 100e18);
        _seedV3(address(tokenA), address(br), spD, uint128(1_847e18), 0); // destroyer, no holdings
        _seedV2(address(br), address(tokenB), 1_000_000e18, 1_000_000e18); // cheap stage B

        _noRoute();
        solver.findBestRoutePlan(address(tokenA), address(tokenB), 100_000e18);
    }

    /// L1498 c2 (`totalImpactBps >= MAX`). Two single-leg hops at exactly
    ///  5000bps each (impactV2Bps rounds up): no leg reaches the 9000
    ///  worst-leg arm, but the summed per-hop means do. Real code refuses;
    ///  neutralised, the aggregate arm is gone, the max arm alone passes, and
    ///  the route surfaces.
    function test_L1498c2_AggregateArmAloneRefusesTwoHalfImpactHops() public {
        _fresh();
        br = new MockERC20("BR", "BR");
        hub.addBridge(address(br));
        _seedV2(address(tokenA), address(br), 100_000e18, 100_000e18); // order == reserves: 5000bps
        _seedV2(address(br), address(tokenB), 49_925e18, 49_925e18);   // ~5000bps on the delivery

        _noRoute();
        solver.findBestRoutePlan(address(tokenA), address(tokenB), 100_000e18);
    }
}
