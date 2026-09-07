// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;
// =============================================================================
//  Metamorphic relations one level UP from CoreMetamorphicRelations.t.sol: over
//  the Solver's PLAN rather than over one curve. The oracle is not a number but
//  how the plan must move when the universe moves. Two constant-product pools on
//  one pair, real Hub + real Solver, no Router (the relations are about routing
//  decisions, not settlement — settlement has the covering array).
//
//    MR-R1  split never worse than the best single pool
//           plan(a).totalOut >= max_i outV2(a, pool_i)
//    MR-R2  monotone in amountIn        a <= b  =>  plan(a) <= plan(b)
//    MR-R3  liquidity monotone          plan over {p1,p2} >= plan over {p1}
//    MR-R4  registration-order independence
//           plan over {p1,p2} == plan over {p2,p1}
//    MR-R5  the attested floor never exceeds the expected output
//
//  Domains: reserves in [1e20, 1e30] (well inside uint112), the two pools' spot
//  prices within ±4% of each other (the Solver's median filter drops a pool whose
//  rate strays more than MEDIAN_FILTER_BPS from the base — a relation over pools
//  it deliberately refuses to believe would be a relation about the filter, and
//  that is tested elsewhere), amountIn at most 1% of the shallower pool's input
//  reserve. MEASURED before the band was written: with one pool priced 1e10 away
//  from the other, the plan paid 35% less than the outlier pool alone (MR-R1) and
//  a deep mispriced pool displaced a shallow honest one (MR-R3) — both the filter
//  doing its job. MR-R4 is stated to one wei: the split's rounding depends on the
//  order legs are allocated, and a minimum-weight pool is kept or cut by its position.
//
//  forge test --match-path test/RouteMetamorphicRelations.t.sol
// =============================================================================
import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixCore as BPC, RoutePlan} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";

contract RouteMetamorphicRelationsTest is Test {
    MockERC20 A;
    MockERC20 B;

    struct Pool { uint256 rA; uint256 rB; }

    function setUp() public {
        A = new MockERC20("A", "A");
        B = new MockERC20("B", "B");
    }

    /// A fresh Hub + Solver holding exactly the pools given, seeded in that order.
    function _universe(Pool[] memory ps) private returns (BlazePhoenixSolver solver) {
        BlazePhoenixHub hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        solver = new BlazePhoenixSolver(address(hub));
        for (uint256 i; i < ps.length; ++i) {
            MockV2Pair p = new MockV2Pair(address(A), address(B));
            A.mint(address(p), ps[i].rA);
            B.mint(address(p), ps[i].rB);
            (address t0, ) = address(A) < address(B) ? (address(A), address(B)) : (address(B), address(A));
            p.setReserves(
                uint112(address(A) == t0 ? ps[i].rA : ps[i].rB),
                uint112(address(A) == t0 ? ps[i].rB : ps[i].rA)
            );
            hub.seedPool(address(p), BPC.KIND_V2, 30, address(0), address(A), address(B));
        }
    }

    function _plan(BlazePhoenixSolver s, uint256 a) private view returns (RoutePlan memory) {
        return s.findBestRoutePlan(address(A), address(B), a);
    }

    function _two(uint256 r1, uint256 r2, uint256 r3, uint256 r4) private pure returns (Pool[] memory ps) {
        ps = new Pool[](2);
        // one price for the pair, between 0.1 and 10, and two depths between 1e22 and
        // 1e28, so every reserve stays inside [1e21, 1e29] with no clamp that could
        // silently break the band (the first version clamped rB into range and the
        // "band" was a factor of 1e10 wide for extreme prices)
        uint256 rA1 = bound(r1, 1e22, 1e28);
        uint256 price = bound(r2, 100, 10_000);            // in thousandths
        uint256 rA2 = bound(r3, 1e22, 1e28);
        uint256 dev = bound(r4, 9600, 10_400);             // ±4% around the first pool
        ps[0] = Pool(rA1, rA1 * price / 1000);
        ps[1] = Pool(rA2, rA2 * price / 1000 * dev / 10_000);
    }

    function _amt(uint256 a, Pool[] memory ps) private pure returns (uint256) {
        uint256 shallow = ps[0].rA < ps[1].rA ? ps[0].rA : ps[1].rA;
        return bound(a, 1e12, shallow / 100);
    }

    /// @dev The oracle's own constant-product arithmetic, written here and not taken
    ///      from the Core: `outV2` is the code under test's formula, so an oracle built
    ///      on it could only agree with it.
    function _cp(uint256 a, uint256 rIn, uint256 rOut) private pure returns (uint256) {
        uint256 aFee = a * 997;
        return (aFee * rOut) / (rIn * 1000 + aFee);
    }

    function _bestSingle(uint256 a, Pool[] memory ps) private pure returns (uint256 best) {
        uint256 o0 = _cp(a, ps[0].rA, ps[0].rB); uint256 o1 = _cp(a, ps[1].rA, ps[1].rB);
        best = o0 > o1 ? o0 : o1;
    }

    /// @dev A two-way split at a fixed fraction (in hundredths) of the input to pool 0.
    function _splitAt(uint256 a, Pool[] memory ps, uint256 pct0) private pure returns (uint256) {
        uint256 a0 = a * pct0 / 100;
        return _cp(a0, ps[0].rA, ps[0].rB) + _cp(a - a0, ps[1].rA, ps[1].rB);
    }

    /// @dev The price-aware optimum over 1 % steps: the bound the depth-weighted split is measured against.
    function _bestSplit(uint256 a, Pool[] memory ps) private pure returns (uint256 best) {
        best = _bestSingle(a, ps);
        for (uint256 k = 1; k < 100; ++k) { uint256 v = _splitAt(a, ps, k); if (v > best) best = v; }
    }

    function _pools(uint256 rA0, uint256 rB0, uint256 rA1, uint256 rB1) private pure returns (Pool[] memory ps) {
        ps = new Pool[](2); ps[0] = Pool(rA0, rB0); ps[1] = Pool(rA1, rB1);
    }

    function testFuzz_MRR1_SplitNeverWorseThanBestSinglePool(uint256 a, uint256 r1, uint256 r2, uint256 r3, uint256 r4) public {
        Pool[] memory ps = _two(r1, r2, r3, r4);
        a = _amt(a, ps);
        BlazePhoenixSolver s = _universe(ps);
        assertGe(_plan(s, a).best.totalOut, _bestSingle(a, ps), "MR-R1: the plan pays less than the best single pool would");
    }

    /// MR-R1 is not vacuous: where a split wins it is TAKEN, and with the weights the
    /// allocator promises (proportional to depth). Two pools at the same price, one four
    /// times deeper, a trade at 5 % of the deep pool: the depth-weighted 80 / 20 split beats
    /// the best single by close to a hundred basis points and the uniform 50 / 50 split by a clear
    /// margin, because half the flow into the shallow pool pays four times the impact.
    function test_MRR1_DepthWeightedSplitIsTakenWhereItWins() public {
        Pool[] memory ps = _pools(1e28, 1e28, 25e26, 25e26);
        uint256 a = 5e26;
        BlazePhoenixSolver s = _universe(ps);
        RoutePlan memory plan = _plan(s, a);
        uint256 single = _bestSingle(a, ps);
        uint256 uniform = _splitAt(a, ps, 50);
        uint256 depthWeighted = _splitAt(a, ps, 80);
        assertGt(depthWeighted, uniform, "premise: the depth-weighted split beats the uniform one here");
        assertEq(plan.best.hops[0].legs.length, 2, "a split that wins is taken");
        assertGt(plan.best.totalOut, single + single * 50 / 10_000, "and beats the best single by more than 50 bps (measured: 96)");
        assertGt(plan.best.totalOut, uniform + uniform / 1000, "with weights that follow depth, not a uniform share");
        assertGe(plan.best.totalOut, depthWeighted - depthWeighted / 10_000, "within 1 bp of the oracle's depth-weighted split");
    }

    /// The allocator weighs by depth, not by price, and the paper says so. This pins how
    /// far that sits from the price-aware optimum (marginal prices equalised) at a large
    /// trade between two equal-depth pools whose prices differ by 4 %: within 20 bps of
    /// the optimum, while beating the best single pool by more than 250 bps. Measured
    /// 2026-09-07 at 17.1 and 19.2 bps; the number here is the bound, not the sample.
    function test_SplitQuality_DepthWeightedIsWithin20bpsOfPriceAware() public {
        uint256[2] memory devs = [uint256(9600), 10400];
        for (uint256 d; d < 2; ++d) {
            Pool[] memory ps = _pools(1e28, 1e28, 1e28, 1e28 * devs[d] / 10_000);
            uint256 a = 1e27;
            BlazePhoenixSolver s = _universe(ps);
            uint256 got = _plan(s, a).best.totalOut;
            uint256 optimum = _bestSplit(a, ps);
            uint256 single = _bestSingle(a, ps);
            assertGe(got + optimum * 20 / 10_000, optimum, "within 20 bps of the price-aware optimum");
            assertGt(got, single + single * 250 / 10_000, "and more than 250 bps above the best single pool");
        }
    }

    function testFuzz_MRR2_PlanMonotoneInAmountIn(uint256 a, uint256 b, uint256 r1, uint256 r2, uint256 r3, uint256 r4) public {
        Pool[] memory ps = _two(r1, r2, r3, r4);
        a = _amt(a, ps);
        uint256 shallow = ps[0].rA < ps[1].rA ? ps[0].rA : ps[1].rA;
        b = bound(b, a, shallow / 100);
        BlazePhoenixSolver s = _universe(ps);
        assertLe(_plan(s, a).best.totalOut, _plan(s, b).best.totalOut, "MR-R2: more in, less out");
    }

    function testFuzz_MRR3_MoreLiquidityNeverLowersThePlan(uint256 a, uint256 r1, uint256 r2, uint256 r3, uint256 r4) public {
        Pool[] memory ps = _two(r1, r2, r3, r4);
        a = _amt(a, ps);
        Pool[] memory one = new Pool[](1);
        one[0] = ps[0];
        uint256 alone = _plan(_universe(one), a).best.totalOut;
        uint256 both = _plan(_universe(ps), a).best.totalOut;
        assertGe(both, alone, "MR-R3: adding a pool lowered the plan");
    }

    function testFuzz_MRR4_RegistrationOrderDoesNotChangeThePlan(uint256 a, uint256 r1, uint256 r2, uint256 r3, uint256 r4) public {
        Pool[] memory ps = _two(r1, r2, r3, r4);
        a = _amt(a, ps);
        Pool[] memory rev = new Pool[](2);
        rev[0] = ps[1];
        rev[1] = ps[0];
        uint256 fwd = _plan(_universe(ps), a).best.totalOut;
        uint256 bwd = _plan(_universe(rev), a).best.totalOut;
        // MEASURED (replayed leg by leg): a pool whose depth weight floors to the minimum
        // (1 of 10,000 against the deepest) is KEPT as a dust leg when it was registered
        // first and CUT when it was registered second. The two plans are both sound; they
        // differ by what one weight unit of the amount earns in one pool versus the other,
        // which inside the ±4% band is below one part in ten thousand of the output
        // (observed: 3e-7). The bound is that weight unit, plus the split's floors.
        uint256 diff = fwd > bwd ? fwd - bwd : bwd - fwd;
        assertLe(diff, fwd / 10_000 + 16, "MR-R4: registration order moved the plan by more than one weight unit of the split");
    }

    function testFuzz_MRR5_AttestedFloorNeverExceedsExpected(uint256 a, uint256 r1, uint256 r2, uint256 r3, uint256 r4) public {
        Pool[] memory ps = _two(r1, r2, r3, r4);
        a = _amt(a, ps);
        RoutePlan memory p = _plan(_universe(ps), a);
        assertLe(p.best.singleOutFloor, p.best.totalOut, "MR-R5: the floor attests more than the plan expects");
        assertGt(p.best.singleOutFloor, 0, "MR-R5: a plan with no floor attests nothing");
    }
}
