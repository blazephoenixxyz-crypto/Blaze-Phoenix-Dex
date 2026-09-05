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

    function testFuzz_MRR1_SplitNeverWorseThanBestSinglePool(uint256 a, uint256 r1, uint256 r2, uint256 r3, uint256 r4) public {
        Pool[] memory ps = _two(r1, r2, r3, r4);
        a = _amt(a, ps);
        BlazePhoenixSolver s = _universe(ps);
        uint256 best = BPC.outV2(a, ps[0].rA, ps[0].rB, 30);
        uint256 other = BPC.outV2(a, ps[1].rA, ps[1].rB, 30);
        if (other > best) best = other;
        assertGe(_plan(s, a).best.totalOut, best, "MR-R1: the plan pays less than the best single pool would");
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
