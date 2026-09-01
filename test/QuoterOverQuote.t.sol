// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  QUOTER OVER-QUOTE — the linear rescale walks the TANGENT of a concave curve.
//
//  Intended path: test/QuoterOverQuote.t.sol
//
//  `previewPlanExact` re-prices the chosen route leg by leg. Three sites
//  rescale a STORED quote linearly instead of asking the pool:
//
//      Quoter.sol:497  V3/Algebra fallback    (reached when _simConc says 0)
//      Quoter.sol:518  V4 fallback            (reached when _simV4  says 0)
//      Quoter.sol:528  SOLIDLY — the template (reached for EVERY Solidly leg)
//
//          legOut = BPC.mulDiv(leg.expectedOut, legIn, base);  // base = leg.amountIn
//
//  AMM output is strictly CONCAVE in input. On x*y=k,
//
//      out(a) = a'*rO / (rI*BPS + a'),   a' = a*(BPS - fee)
//
//  so 2*out(P) > out(2P) for any rI, rO, P > 0: the chord lies UNDER the
//  curve, the tangent lies OVER it. Rescaling DOWN (legIn < base) therefore
//  understates and is the safe side; rescaling UP overstates. The exact pass
//  scales UP whenever a later hop receives more than the plan expected
//  (carry > plannedIn) — which is exactly the situation the exact pass exists
//  to discover; the HOP-0 CAP protects hop 0 only. At the reserves pinned
//  below the over-quote is ~470 bps; the external reporter measured up to
//  ~907 bps on a thinner pool.
//
//  WHY THE DIRECTION IS THE DANGEROUS ONE: integrators derive userMinOut from
//  this preview, and the Quoter's own header guarantees Q1 — never
//  overestimate: use the exact measurement where it exists, round DOWN where
//  it does not. For Solidly the exact measurement EXISTS and is not wired:
//  BPC.solidlyGetAmountOut (the pair's own bytecode; already the primary arm
//  of universalQuote's KIND_SOLIDLY branch). The refuter exists and is not
//  called — this codebase's named failure mode.
//
//  RED BEFORE THE FIX:
//      test_RED_SolidlyLeg_UpscaledQuoteExceedsPoolTruth   (site 528, primary)
//      test_RED_SolidlyLeg_NoAnswer_StillNeverExceedsTruth (site 528, no-answer arm)
//      test_RED_ConcFallback_NeverScalesAbovePlan          (site 497)
//      test_RED_V4Fallback_NeverScalesAbovePlan            (site 518)
//  The lemma and the two controls pass in BOTH eras: they pin the mechanism
//  and the safe (down-scale) direction so the fix cannot overshoot into
//  zeroing legs that today are quoted correctly.
//
//  forge test --match-contract QuoterOverQuote -vv
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixQuoter} from "../src/BlazePhoenixQuoter.sol";
import {
    BlazePhoenixCore as BPC,
    Route, Hop, Leg, RoutePlan
} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockSolidlyPair} from "./mocks/MockSolidlyPair.sol";

/// @notice Serves ONE canned plan, verbatim. previewPlanExact's first act is
///         `solver.findBestRoutePlan(...)`; feeding it a fixed plan lets the
///         test place carry > plannedIn on hop 1 deterministically — the
///         Solver-underestimates-hop-0 shape the reporter measured — without
///         seeding a whole solve. Stored as abi-encoded bytes because a
///         memory->storage copy of nested dynamic arrays does not compile.
contract PlanStubSolver {
    bytes internal blob;
    function setPlan(RoutePlan memory p) external { blob = abi.encode(p); }
    function findBestRoutePlan(address, address, uint256)
        external view returns (RoutePlan memory)
    {
        return abi.decode(blob, (RoutePlan));
    }
}

/// @notice A V3-shaped pool that refuses the dry-run with a string revert.
///         Error("SPL") encodes to 100 bytes, so _simConc's `length != 64`
///         guard maps it to 0 — the realistic way Quoter.sol:497 is reached
///         (zero-liquidity "SPL", locked or paused pools all revert with
///         strings, not with the Quoter's 64-byte delta payload).
contract RefusingV3Pool {
    function swap(address, bool, int256, uint160, bytes calldata)
        external pure returns (int256, int256)
    {
        revert("SPL");
    }
}

contract QuoterOverQuoteTest is Test {
    BlazePhoenixHub    hub;
    PlanStubSolver     stub;
    BlazePhoenixQuoter quoter;

    MockERC20 tokenA;
    MockERC20 tokenB;
    MockERC20 tokenC;
    MockSolidlyPair pairAB;
    MockSolidlyPair pairBC;
    RefusingV3Pool  deadPool;

    // Pinned from BPC (blind-constant law: this file must break if the
    // taxonomy moves under it).
    uint8  constant KIND_SOLIDLY = BPC.KIND_SOLIDLY; // 5 — lands in the else
    uint8  constant KIND_V3      = BPC.KIND_V3;      // 1 — A_CONC_POOL arm
    uint8  constant KIND_V4      = BPC.KIND_V4;      // 4 — A_CONC_SING arm
    uint256 constant BPS         = BPC.BPS;          // 10_000

    // Pool geometry. The first hop is deep so its own quote is honest; the
    // second is THIN, where the tangent-vs-curve gap is fat (~470 bps at 2x).
    uint112 constant R_AB    = 1_000_000e18;
    uint112 constant R_BC    = 1_000e18;
    uint256 constant X_IN    = 100e18;
    uint24  constant SOL_FEE = 30;   // BPS-scaled; matches MockSolidlyPair.feeBps

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        // v4PoolManager stays address(0): _simV4 must answer 0 so the V4
        // fallback site (Quoter.sol:518) is the code that runs.
        hub.initialize(address(this), address(0));
        stub   = new PlanStubSolver();
        quoter = new BlazePhoenixQuoter(address(hub), address(stub));

        tokenA = new MockERC20("A", "A");
        tokenB = new MockERC20("B", "B");
        tokenC = new MockERC20("C", "C");

        pairAB = new MockSolidlyPair(address(tokenA), address(tokenB), false);
        pairAB.setReserves(R_AB, R_AB);
        pairBC = new MockSolidlyPair(address(tokenB), address(tokenC), false);
        pairBC.setReserves(R_BC, R_BC);

        deadPool = new RefusingV3Pool();
    }

    // ─── plan builders ───────────────────────────────────────────────────────

    function _leg(
        address pool, uint8 kind, bool zfo,
        uint256 amountIn, uint256 expectedOut, bytes32 auxId
    ) internal pure returns (Leg memory) {
        return Leg({
            pool:        pool,
            hooks:       address(0),
            kind:        kind,
            fee:         SOL_FEE,
            tickSpacing: 0,
            zeroForOne:  zfo,
            stable:      false,
            amountIn:    amountIn,
            expectedOut: expectedOut,
            auxId:       auxId
        });
    }

    function _wrap(Hop[] memory hops, uint256 claimOut)
        internal pure returns (RoutePlan memory p)
    {
        p.best = Route({
            hops:              hops,
            totalOut:          claimOut,
            singleOut:         claimOut,
            singleOutFloor:    BPC.mulDiv(claimOut, 9_600, BPS),
            expectedImpactBps: 0,
            confidenceWad:     0,
            estGas:            0,
            hasSurplus:        false,
            isV4Bundle:        false
        });
        // fallbackRoute stays empty, hasFallback false.
    }

    /// @dev Two hops A->B->C. Hop 0 is HONEST (plan expects exactly what the
    ///      pool pays for X_IN). Hop 1 is planned at `p1In` with the CURVE
    ///      truth at that size — also honest AT ITS OWN SIZE. The defect is
    ///      not a lying plan: it is the exact pass discovering hop 0 delivers
    ///      `trueOut0` and then rescaling hop 1's honest point by
    ///      trueOut0/p1In along the tangent. `hop1` selects the venue kind
    ///      sitting on hop 1 so the same shape drives all three sites.
    function _twoHopPlan(uint256 p1In, uint8 hop1Kind, address hop1Pool, uint256 hop1Claim)
        internal view returns (RoutePlan memory)
    {
        uint256 out0 = pairAB.getAmountOut(X_IN, address(tokenA));

        Leg[] memory l0 = new Leg[](1);
        l0[0] = _leg(
            address(pairAB), KIND_SOLIDLY,
            address(tokenA) == pairAB.token0(),
            X_IN, out0, bytes32(0));

        Leg[] memory l1 = new Leg[](1);
        l1[0] = _leg(
            hop1Pool, hop1Kind,
            hop1Kind == KIND_SOLIDLY
                ? address(tokenB) == pairBC.token0()
                : true,
            p1In, hop1Claim,
            hop1Kind == KIND_V4
                ? bytes32(uint256(uint160(address(tokenC))))  // tokenOut travels in auxId
                : bytes32(0));

        Hop[] memory hops = new Hop[](2);
        hops[0] = Hop({
            tokenIn: address(tokenA), tokenOut: address(tokenB),
            amountIn: X_IN, expectedOut: out0, legs: l0
        });
        hops[1] = Hop({
            tokenIn: address(tokenB), tokenOut: address(tokenC),
            amountIn: p1In, expectedOut: hop1Claim, legs: l1
        });
        return _wrap(hops, hop1Claim);
    }

    /// @dev Curve truth on the thin pool at `ain` — MockSolidlyPair's own
    ///      quote formula (BPC.outSolidly), readable even when the pair hides
    ///      getAmountOut(). Equal reserves, so direction does not matter.
    ///      `view`, not `pure`: outSolidly is a PUBLIC library function, so
    ///      the call is a delegatecall and a pure context cannot make it.
    function _bcCurve(uint256 ain) internal view returns (uint256) {
        return BPC.outSolidly(ain, R_BC, R_BC, SOL_FEE, false);
    }

    // ─── the mechanism, stated plainly ───────────────────────────────────────

    /// Strict concavity of x*y=k: doubling the input strictly less than
    /// doubles the output. This is the whole defect — a linear rescale from P
    /// to 2P quotes 2*out(P), and the pool will only pay out(2P).
    function test_Lemma_StrictConcavity_TwiceSmallBeatsDouble() public view {
        uint256 trueOut0 = pairAB.getAmountOut(X_IN, address(tokenA));
        uint256 P = trueOut0 / 2;
        uint256 small = pairBC.getAmountOut(P, address(tokenB));
        uint256 big   = pairBC.getAmountOut(2 * P, address(tokenB));
        assertGt(2 * small, big,
            "x*y=k must be strictly concave: 2*out(P) > out(2P)");
    }

    // ─── RED: site 528, the Solidly template ─────────────────────────────────

    /// The plan commits HALF of what hop 0 really delivers; the exact pass
    /// rescales hop 1 UP by ~2x. Before the fix the Solidly arm walks the
    /// tangent and promises ~2*out(P) where the pool pays out(2P) — an
    /// over-quote of ~470 bps here. The pool's own getAmountOut at the leg's
    /// own recorded input is the refuter.
    function test_RED_SolidlyLeg_UpscaledQuoteExceedsPoolTruth() public {
        uint256 trueOut0 = pairAB.getAmountOut(X_IN, address(tokenA));
        uint256 P = trueOut0 / 2;
        stub.setPlan(_twoHopPlan(P, KIND_SOLIDLY, address(pairBC), _bcCurve(P)));

        (Route memory r, uint256 exactOut) =
            quoter.previewPlanExact(address(tokenA), address(tokenC), X_IN);

        uint256 legIn  = r.hops[1].legs[0].amountIn;    // written back by the pass
        uint256 quoted = r.hops[1].legs[0].expectedOut;

        // The up-scale really engaged — the test cannot silently degenerate.
        assertGt(legIn, P, "carry > plannedIn must have rescaled hop 1 UP");

        // THE CLAIM (Q1): a preview must never promise more than the pool
        // pays at the very input the preview itself recorded.
        uint256 poolTruth = pairBC.getAmountOut(legIn, address(tokenB));
        assertLe(quoted, poolTruth,
            "previewPlanExact promised MORE than the pool's own getAmountOut at the same input");

        // Coherence: hop figure and total publish the same number.
        assertEq(r.hops[1].expectedOut, quoted, "single-leg hop must publish the leg figure");
        assertEq(exactOut, quoted, "exactOut must be the final hop's output");
    }

    /// A fork WITHOUT getAmountOut (the mock hides it). The conservative
    /// answer for a preview is the replicated curve rounded DOWN — never the
    /// tangent (before the fix), and never a blanket zero either: reserves
    /// are readable, so the leg is priceable, just lower.
    function test_RED_SolidlyLeg_NoAnswer_StillNeverExceedsTruth() public {
        pairBC.setHideGetAmountOut(true);
        uint256 trueOut0 = pairAB.getAmountOut(X_IN, address(tokenA));
        uint256 P = trueOut0 / 2;
        stub.setPlan(_twoHopPlan(P, KIND_SOLIDLY, address(pairBC), _bcCurve(P)));

        (Route memory r, ) =
            quoter.previewPlanExact(address(tokenA), address(tokenC), X_IN);

        uint256 legIn  = r.hops[1].legs[0].amountIn;
        uint256 quoted = r.hops[1].legs[0].expectedOut;

        assertLe(quoted, _bcCurve(legIn),
            "with getAmountOut absent the preview must sit AT or UNDER the curve, never on the tangent");
        assertGt(quoted, 0,
            "a pool with readable reserves must still quote - refusing everything is the other ditch");
    }

    // ─── RED: sites 497 and 518, the sibling fallbacks ───────────────────────

    /// Site 497. The pool REFUSED the dry-run (string revert, the realistic
    /// production shape), so the only known point is the plan's claim at the
    /// plan's size. Concavity forbids extrapolating that point upward: the
    /// quote may keep the claim, never exceed it.
    function test_RED_ConcFallback_NeverScalesAbovePlan() public {
        uint256 trueOut0 = pairAB.getAmountOut(X_IN, address(tokenA));
        uint256 P     = trueOut0 / 2;
        uint256 claim = _bcCurve(P);   // any plausible plan-time claim at P
        stub.setPlan(_twoHopPlan(P, KIND_V3, address(deadPool), claim));

        (Route memory r, ) =
            quoter.previewPlanExact(address(tokenA), address(tokenC), X_IN);

        uint256 legIn  = r.hops[1].legs[0].amountIn;
        uint256 quoted = r.hops[1].legs[0].expectedOut;

        assertGt(legIn, P, "the up-scale must have engaged");
        assertLe(quoted, claim,
            "a leg whose pool refused the dry-run must never be scaled ABOVE the plan's own claim");
    }

    /// Site 518. Same claim for the V4 arm: with no PoolManager wired,
    /// _simV4 answers 0 by policy and the stored-quote fallback runs.
    function test_RED_V4Fallback_NeverScalesAbovePlan() public {
        uint256 trueOut0 = pairAB.getAmountOut(X_IN, address(tokenA));
        uint256 P     = trueOut0 / 2;
        uint256 claim = _bcCurve(P);
        stub.setPlan(_twoHopPlan(P, KIND_V4, address(0xD00D), claim));

        (Route memory r, ) =
            quoter.previewPlanExact(address(tokenA), address(tokenC), X_IN);

        uint256 legIn  = r.hops[1].legs[0].amountIn;
        uint256 quoted = r.hops[1].legs[0].expectedOut;

        assertGt(legIn, P, "the up-scale must have engaged");
        assertLe(quoted, claim,
            "a V4 leg the singleton cannot price must never be scaled ABOVE the plan's own claim");
    }

    // ─── controls: the SAFE direction must survive the fix ───────────────────

    /// Down-scaling a refused leg is the chord of a concave curve — it
    /// understates and is correct today. The fix must leave it byte-identical:
    /// clamping the tangent must not zero (or otherwise move) the chord.
    function test_Control_DownscaledFallback_KeepsTheFlooredChord() public {
        uint256 trueOut0   = pairAB.getAmountOut(X_IN, address(tokenA));
        uint256 plannedBig = trueOut0 * 2;         // plan OVERestimated hop 0
        uint256 claim      = _bcCurve(plannedBig);
        stub.setPlan(_twoHopPlan(plannedBig, KIND_V3, address(deadPool), claim));

        (Route memory r, ) =
            quoter.previewPlanExact(address(tokenA), address(tokenC), X_IN);

        uint256 legIn = r.hops[1].legs[0].amountIn;
        assertLt(legIn, plannedBig, "the down-scale must have engaged");
        assertEq(r.hops[1].legs[0].expectedOut,
            BPC.mulDiv(claim, legIn, plannedBig),
            "down-scaling must stay the floored linear chord - the fix must not touch the safe direction");
    }

    /// A down-scaled SOLIDLY leg is bounded on both sides in either era:
    /// at least the chord (what today's linear arm yields, and a floor the
    /// fix may only raise), at most the pool's truth (Q1). Before the fix
    /// the quote sits ON the chord; after, ON the truth.
    function test_Control_DownscaledSolidly_BetweenChordAndTruth() public {
        uint256 trueOut0   = pairAB.getAmountOut(X_IN, address(tokenA));
        uint256 plannedBig = trueOut0 * 2;
        uint256 claim      = _bcCurve(plannedBig);
        stub.setPlan(_twoHopPlan(plannedBig, KIND_SOLIDLY, address(pairBC), claim));

        (Route memory r, ) =
            quoter.previewPlanExact(address(tokenA), address(tokenC), X_IN);

        uint256 legIn  = r.hops[1].legs[0].amountIn;
        uint256 quoted = r.hops[1].legs[0].expectedOut;

        assertLt(legIn, plannedBig, "the down-scale must have engaged");
        assertGe(quoted, BPC.mulDiv(claim, legIn, plannedBig),
            "a down-scaled Solidly quote must never fall below the chord");
        assertLe(quoted, pairBC.getAmountOut(legIn, address(tokenB)),
            "and must never exceed the pool's own answer");
    }
}
