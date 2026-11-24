// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// A STABLE AND A VOLATILE PAIR OF EQUAL RESERVES WEIGH THE SAME; THE PLAN IS HELD TO THE BEST
// SINGLE LEG AMONG THE ROWS THE FUNNEL KEEPS, NOT TO THE GRID OPTIMUM.
//
// The split weight of a row is its mass, the bought token it holds (`hopMass18`, MAT-02): a
// count of tokenOut, homogeneous of degree zero for the median, the funnel and the weights. A
// Solidly pair pays at most its tokenOut reserve whatever its curve, so a stable and a volatile
// pair of equal reserves declare the same mass and receive the same weight. How much each pays at
// a given size is a different question, answered by the pair's own `getAmountOut` (DELEGATED,
// `_solidlyAsk`). Two relations bound the plan, chosen by the measured mass and the Solver's own
// MIN_SPLIT_IMPROVEMENT_PPM:
//   - MR-R1 among the survivors: a split stays only if it beats every band survivor quoted alone
//     at full size, so the plan is never below the best single leg;
//   - MR-R1d for a row under the dust share (d_min * 1e6 < MIN_SPLIT_IMPROVEMENT_PPM * d_max): it
//     is dropped before it is quoted, so the plan is the deep pair alone, to the wei, and what that
//     costs is at most the dropped row's share of the order, amt * d_min / d_max
//     (test/RouteMetamorphicRelations.t.sol:154-165). A flat stable pair under the share can pay a
//     few wei more than the deep volatile pair at a size it could take: that is MR-R1d, not a
//     plan below MR-R1.
//
// PIN, green at 833c3b1 with no source change: there is no fix here, so there is no red commit.
// It goes red under the mutants registered for it in .github/scripts/mutants.py:
//   - Solver: the split gate never collapses a split (`if (legs.length >= 2)` -> `if (false)`);
//   - Core: the Solidly arm declares the sold token's reserve as its mass (`to18(rO` -> `to18(rI`);
//   - Solver: the funnel stops dropping a row under the dust share (`_dropDust`).
// A change that weighs a stable pair by its curve also turns the parity pin red: that is its job.
//
// Oracles: the mock pair's own `getAmountOut` read by the test, less the one wei the executor
// keeps as its rounding margin; `balanceOf` of the bought token for the mass.

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver, MIN_SPLIT_IMPROVEMENT_PPM} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixCore as BPC, RoutePlan, Route, QuoteCtx} from "../src/BlazePhoenixCore.sol";
import {PathologicalERC20} from "./mocks/PathologicalERC20.sol";
import {MockSolidlyPair} from "./mocks/MockSolidlyPair.sol";
import {Origin} from "./mocks/MockOriginFactory.sol";

contract SplitStableVsVolatileTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    PathologicalERC20 a;   // token0, sold
    PathologicalERC20 b;   // token1, bought

    function setUp() public {
        vm.roll(3000);
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        solver = new BlazePhoenixSolver(address(hub), address(0));
    }

    // ---- fixtures ---------------------------------------------------------------------------

    function _tokens(uint8 dA, uint8 dB) internal {
        a = new PathologicalERC20("A", "A", dA);
        do { b = new PathologicalERC20("B", "B", dB); } while (address(b) < address(a));
    }

    function _pair(bool stable_, uint256 rA, uint256 rB) internal returns (MockSolidlyPair p) {
        p = new MockSolidlyPair(address(a), address(b), stable_);
        Origin.wire(hub, address(p), address(a), address(b), BPC.KIND_SOLIDLY, 30, stable_);
        a.mint(address(p), rA);
        b.mint(address(p), rB);
        p.setReserves(uint112(rA), uint112(rB));
        hub.seedPool(address(p), BPC.KIND_SOLIDLY, 30, address(0), address(a), address(b));
    }

    /// The executor's ask of one pair at full size: its own figure less one wei, 0 when it
    /// answers 0 or 1.
    function _ask(MockSolidlyPair p, uint256 amt) internal view returns (uint256 o) {
        o = p.getAmountOut(amt, address(a));
        o = o > 1 ? o - 1 : 0;
    }

    /// The plan for `amt` of A into B is never below the best single leg, and commits the order.
    function _neverBelowBestSingle(MockSolidlyPair st, MockSolidlyPair vo, uint256 amt, string memory cell)
        internal
        view
    {
        uint256 best = _ask(st, amt);
        uint256 v = _ask(vo, amt);
        if (v > best) best = v;
        if (best == 0) return; // no leg pays anything at this size: nothing to hold the plan to
        Route memory r;
        try solver.findBestRoutePlan(address(a), address(b), amt) returns (RoutePlan memory p) {
            r = p.best;
        } catch (bytes memory err) {
            // No plan at all (dust the band prices dead) is a typed refusal, not a plan below
            // the best single leg; any other failure is.
            assertEq(err, abi.encodeWithSelector(BlazePhoenixSolver.SolverE.selector, uint16(5)),
                string.concat(cell, ": no plan is refused as SolverE(5)"));
            return;
        }
        assertEq(r.hops.length, 1, string.concat(cell, ": one hop"));
        uint256 committedIn;
        uint256 sumOut;
        for (uint256 i; i < r.hops[0].legs.length; ++i) {
            address pool = r.hops[0].legs[i].pool;
            assertTrue(pool == address(st) || pool == address(vo), string.concat(cell, ": a listed pair"));
            committedIn += r.hops[0].legs[i].amountIn;
            sumOut += r.hops[0].legs[i].expectedOut;
        }
        assertEq(committedIn, amt, string.concat(cell, ": the plan commits the whole order"));
        assertGe(r.totalOut, best, string.concat(cell, ": the plan is never below the best single leg"));
        assertGe(sumOut, best, string.concat(cell, ": the legs' promises are never below the best single leg"));
    }

    /// The plan against the best single leg, in the regime the measured masses choose. Under
    /// the dust share (MR-R1d) the shallow pair is not quoted: the plan is the deep pair alone,
    /// to the wei, and it pays at most the shallow pair's share of the order less than the best
    /// single leg. Otherwise both pairs are survivors and MR-R1 holds the plan to the better one.
    function _heldToTheBestSingle(MockSolidlyPair st, MockSolidlyPair vo, uint256 amt, string memory cell)
        internal
        view
    {
        uint256 dSt = BPC.to18(b.balanceOf(address(st)), b.decimals());
        uint256 dVo = BPC.to18(b.balanceOf(address(vo)), b.decimals());
        (MockSolidlyPair deep, uint256 dMax, uint256 dMin) = dSt >= dVo ? (st, dSt, dVo) : (vo, dVo, dSt);
        if (dMin * 1e6 >= uint256(MIN_SPLIT_IMPROVEMENT_PPM) * dMax) {
            _neverBelowBestSingle(st, vo, amt, cell);
            return;
        }
        uint256 best = _ask(st, amt);
        uint256 v = _ask(vo, amt);
        if (v > best) best = v;
        Route memory r = solver.findBestRoutePlan(address(a), address(b), amt).best;
        assertEq(r.hops.length, 1, string.concat(cell, ": one hop"));
        assertEq(r.hops[0].legs.length, 1, string.concat(cell, ": dust share: one leg"));
        assertEq(r.hops[0].legs[0].pool, address(deep), string.concat(cell, ": dust share: the deep pair alone"));
        assertEq(r.hops[0].legs[0].amountIn, amt, string.concat(cell, ": the plan commits the whole order"));
        assertEq(r.totalOut, _ask(deep, amt), string.concat(cell, ": dust share: the deep pair's ask, to the wei"));
        if (best > r.totalOut) {
            assertLe((best - r.totalOut) * dMax, amt * dMin,
                string.concat(cell, ": dropping the dust row cost more than its share of the order"));
        }
    }

    function _mass(MockSolidlyPair p, bool stable_) internal view returns (uint256 mass) {
        QuoteCtx memory c;
        c.kind = BPC.KIND_SOLIDLY;
        c.pool = address(p);
        c.zeroForOne = true;
        c.fee = 30;
        c.stable = stable_;
        c.tokenIn = address(a);
        c.tokenOther = address(b);
        c.hub = address(hub);
        c.decIn1 = a.decimals() + 1;
        c.decOther1 = b.decimals() + 1;
        (mass, , , , ) = BPC.universalProbe(c, 10 ** a.decimals(), 0, true, 0);
    }

    // ---- the plan against the best single leg ----------------------------------------------

    /// Equal reserves, 1,000 of each side; sizes from one unit to 80 % of the reserves (the
    /// split kept at 800 and collapsed to the stable pair at 400, measured on the grid). 18/18
    /// only: the mock's stable `getAmountOut` assumes equal decimals, so at 6/18 it answers a
    /// figure that is not a stable pair's and the two pairs no longer agree on the price.
    function test_Split_AStableAndAVolatilePairOfEqualReserves_PlanIsNeverBelowTheBestSingleLeg() public {
        _tokens(18, 18);
        MockSolidlyPair st = _pair(true, 1000e18, 1000e18);
        MockSolidlyPair vo = _pair(false, 1000e18, 1000e18);
        vm.roll(block.number + 1);
        _neverBelowBestSingle(st, vo, 1, "dust");
        _neverBelowBestSingle(st, vo, 1e18, "1 unit");
        _neverBelowBestSingle(st, vo, 400e18, "400");
        _neverBelowBestSingle(st, vo, 800e18, "800");
    }

    /// A deep stable pair beside a shallow volatile one, and a stable pair far from its
    /// equilibrium (skewed 1:20) beside a balanced volatile one.
    function test_Split_DeepStableBesideShallowVolatile_PlanIsNeverBelowTheBestSingleLeg() public {
        _tokens(18, 18);
        MockSolidlyPair st = _pair(true, 10_000e18, 10_000e18);
        MockSolidlyPair vo = _pair(false, 100e18, 100e18);
        vm.roll(block.number + 1);
        _neverBelowBestSingle(st, vo, 1e18, "1 unit");
        _neverBelowBestSingle(st, vo, 800e18, "800");
    }

    function test_Split_SkewedStableBesideBalancedVolatile_PlanIsNeverBelowTheBestSingleLeg() public {
        _tokens(18, 18);
        MockSolidlyPair st = _pair(true, 2_000e18, 100e18);
        MockSolidlyPair vo = _pair(false, 1_000e18, 1_000e18);
        vm.roll(block.number + 1);
        _neverBelowBestSingle(st, vo, 1e18, "1 unit");
        _neverBelowBestSingle(st, vo, 50e18, "50");
    }

    /// A chain without the pair's `getAmountOut`: both pairs are asked through the replicated
    /// curve less 200 bps. The oracle is the pair's own figure read before it is hidden, taken
    /// at 9,800 / 10,000, so the plan is held at least to that.
    function test_Split_NoGetAmountOut_PlanIsNeverBelowTheBestReplicatedSingleLeg() public {
        _tokens(18, 18);
        MockSolidlyPair st = _pair(true, 1000e18, 1000e18);
        MockSolidlyPair vo = _pair(false, 1000e18, 1000e18);
        uint256 amt = 400e18;
        uint256 best = st.getAmountOut(amt, address(a));
        uint256 v = vo.getAmountOut(amt, address(a));
        if (v > best) best = v;
        best = best * 9_800 / 10_000 - 1;
        st.setHideGetAmountOut(true);
        vo.setHideGetAmountOut(true);
        vm.roll(block.number + 1);
        Route memory r = solver.findBestRoutePlan(address(a), address(b), amt).best;
        assertGe(r.totalOut, best, "replicated: the plan is never below the best single leg");
    }

    /// The counterexample the fuzz found (args decoded through forge-std's `bound`): a stable
    /// pair of 5.92e24 beside a volatile pair of 4.24e29, a share of 13.96 ppm, under the 25 ppm
    /// dust share. The stable pair is dropped unquoted; the plan is the volatile pair alone, and
    /// the 1,597,487 wei it pays below the stable pair is the volatile pair's impact at this size,
    /// far inside MR-R1d's bound. Then the same pairs from 1e12 wei to the deep pair's reserve.
    function test_Split_AStablePairUnderTheDustShare_PlanIsTheDeepPairAlone() public {
        _tokens(18, 18);
        MockSolidlyPair st = _pair(true, 5920498847061133360725536, 5920498847061133360725536);
        MockSolidlyPair vo = _pair(false, 424043418135846136921813263492, 424043418135846136921813263492);
        vm.roll(block.number + 1);
        uint256 amt = 825522361991675764;
        assertLt(uint256(5920498847061133360725536) * 1e6,
            uint256(MIN_SPLIT_IMPROVEMENT_PPM) * 424043418135846136921813263492, "oracle: the stable pair is under the dust share");
        assertEq(_ask(st, amt), 823045794905700734, "oracle: the stable pair's ask");
        assertEq(_ask(vo, amt), 823045794904103247, "oracle: the volatile pair's ask");
        Route memory r = solver.findBestRoutePlan(address(a), address(b), amt).best;
        assertEq(r.hops.length, 1, "one hop");
        assertEq(r.hops[0].legs.length, 1, "one leg");
        assertEq(r.hops[0].legs[0].pool, address(vo), "the deep volatile pair alone");
        assertEq(r.totalOut, 823045794904103247, "the volatile pair's ask, to the wei");
        _heldToTheBestSingle(st, vo, 1e12, "dust share, 1e12");
        _heldToTheBestSingle(st, vo, 1e18, "dust share, 1 unit");
        _heldToTheBestSingle(st, vo, 800e18, "dust share, 800");
        _heldToTheBestSingle(st, vo, 424043418135846136921813263492, "dust share, the deep reserve");
    }

    /// The dust share's edge, +-1 wei of the deep pair: at d_min * 1e6 == 25 * d_max the stable
    /// pair is kept and the plan is held to it (MR-R1); one wei deeper it is dust (MR-R1d); one
    /// wei shallower it is kept.
    function test_Split_TheDustShareEdge_PlusMinusOneWei_ChoosesTheRelation() public {
        uint256 rS = 1e24;
        uint256 rV = rS * 1e6 / MIN_SPLIT_IMPROVEMENT_PPM;
        assertEq(rS * 1e6, uint256(MIN_SPLIT_IMPROVEMENT_PPM) * rV, "oracle: the edge is exact");
        for (uint256 k; k < 3; ++k) {
            _tokens(18, 18);
            MockSolidlyPair st = _pair(true, rS, rS);
            MockSolidlyPair vo = _pair(false, rV + k - 1, rV + k - 1);
            vm.roll(block.number + 1);
            string memory cell = k == 0 ? "edge - 1 wei" : k == 1 ? "edge" : "edge + 1 wei";
            assertEq(rS * 1e6 < uint256(MIN_SPLIT_IMPROVEMENT_PPM) * (rV + k - 1), k == 2,
                string.concat(cell, ": oracle: only one wei deeper is dust"));
            _heldToTheBestSingle(st, vo, 1e18, cell);
        }
    }

    /// From a small order to one the size of the deeper pair, equal and unequal reserves, both
    /// pairs at their equilibrium, in the two regimes the measured masses choose: under the dust
    /// share the plan is the deep pair alone, to the wei, within MR-R1d's bound; above it MR-R1
    /// holds the plan to the best SURVIVOR of the band, so the oracle (the better of both pairs)
    /// is the right one only while the two agree on the price: a pair off its equilibrium is
    /// priced away from the depth-weighted median, and whether it stays is the band's question,
    /// not the split's (the skewed cell above is one fixed point).
    function testFuzz_Split_StableBesideVolatile_NeverBelowBestSingle(uint256 amt, uint256 rStable, uint256 rVol)
        public
    {
        _tokens(18, 18);
        rStable = bound(rStable, 1e18, 1e30);
        rVol = bound(rVol, 1e18, 1e30);
        MockSolidlyPair st = _pair(true, rStable, rStable);
        MockSolidlyPair vo = _pair(false, rVol, rVol);
        // From 1e12 wei: below it the capacity cut may commit less than the order (the rest is
        // returned), and a plan for part of the order is not comparable with a full-size single.
        amt = bound(amt, 1e12, rStable > rVol ? rStable : rVol);
        vm.roll(block.number + 1);
        _heldToTheBestSingle(st, vo, amt, "fuzz");
    }

    // ---- the mass: a parity pin, not a fusion ----------------------------------------------

    /// The mass the probe declares for a stable pair equals the volatile pair's at the same
    /// reserves, and both equal the bought token the pair holds (18 decimals).
    function _massParity(uint8 dA, uint8 dB) internal {
        _tokens(dA, dB);
        uint256 rA = 300 * 10 ** dA;
        uint256 rB = 7_000 * 10 ** dB;
        MockSolidlyPair st = _pair(true, rA, rB);
        MockSolidlyPair vo = _pair(false, rA, rB);
        uint256 held = BPC.to18(b.balanceOf(address(st)), dB);
        assertEq(held, 7_000e18, "oracle: the pair holds 7,000 B");
        assertEq(_mass(st, true), held, "a stable pair declares the bought token it holds");
        assertEq(_mass(vo, false), held, "a volatile pair declares the bought token it holds");
    }

    function test_Mass_AStablePairDeclaresTheTokenOutItHolds_LikeAVolatilePair() public {
        _massParity(18, 18);
    }

    function test_Mass_AStablePairDeclaresTheTokenOutItHolds_LikeAVolatilePair_6_18() public {
        _massParity(6, 18);
    }
}
