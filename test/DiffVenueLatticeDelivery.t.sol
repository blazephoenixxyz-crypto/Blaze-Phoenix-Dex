// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  Metamorphic relations of the SOLVE door over a lattice of venues, measured by what the user
//  receives (balance delta), never by what a plan says. atq-1111, front "dif".
//
//  test/RouteMetamorphicRelations.t.sol states MR-R1..R5 on the Solver's plan, over two V2 pools
//  and one hop. Here the same family is asked of the executed swap, over four venues of three
//  kinds (V2, V3, Solidly), both directions, five order sizes from dust to a fifth of the
//  deepest venue, and over one hop against two.
//
//  The reference of every relation is the same Router run on a smaller world (one venue alone,
//  one topology alone): no figure here comes from the code that picked the route.
//
//  Mutants: [ATQ-dif-16] .. [ATQ-dif-19] in .github/scripts/mutants.py.
//
//  forge test --match-path test/DiffVenueLatticeDelivery.t.sol
// =============================================================================
import {DiffWorld, MockERC20} from "./DiffWorld.sol";

contract DiffVenueLatticeDeliveryTest is DiffWorld {
    function setUp() public {
        _stack();
    }

    /// MR-R1 by execution: whatever the route is, it pays at least what the best of its own
    /// venues pays when it is the only venue of the pair. 11 worlds of two to four venues, two
    /// directions, five sizes.
    function test_Lattice_TheRouteNeverDeliversLessThanItsBestSingleVenueAlone() public {
        uint256[5][2][16] memory d = _latticeTable();
        uint256[5] memory a = _grid();
        uint256 points;
        for (uint256 mask = 3; mask < 16; ++mask) {
            if (mask & (mask - 1) == 0) continue;   // one venue is its own reference
            for (uint256 dir; dir < 2; ++dir) {
                for (uint256 i; i < 5; ++i) {
                    uint256 best;
                    for (uint256 bit = 1; bit < 16; bit <<= 1) {
                        if (mask & bit != 0 && d[bit][dir][i] > best) best = d[bit][dir][i];
                    }
                    assertGe(d[mask][dir][i], best, _at("the route paid less than one of its own venues alone", mask, dir, a[i]));
                    ++points;
                }
            }
        }
        assertEq(points, 110, "the lattice was not walked whole");
    }

    /// The premise of MR-R1, from the lattice's own figures and never from the Solver: every
    /// two venues' spots differ by less than the round trip between them at 0.3% a side, so
    /// neither is an open arbitrage against the other and the band keeps both. A venue outside
    /// it is dropped by design (src/BlazePhoenixMath.sol, WHAT THIS COSTS, 1), and MR-R1 would
    /// then be a relation about the filter.
    function test_Lattice_EveryTwoVenuesLeaveNoRoundTripOpen() public pure {
        uint256 keep = 997 * 997;   // (1 - 0.003)^2, per 1e6
        for (uint256 i = 1; i < 16; i <<= 1) {
            (, uint256 xi, uint256 yi) = _latticeVenue(i);
            for (uint256 j = 1; j < 16; j <<= 1) {
                (, uint256 xj, uint256 yj) = _latticeVenue(j);
                // s_i / s_j >= (1 - f)^2, with s = y / x: yi * xj * 1e6 >= yj * xi * keep
                assertGe(yi * xj / 1e18 * 1e6, yj * xi / 1e18 * keep, "two venues of the lattice leave a round trip open");
            }
        }
    }

    /// MR-R1 is not vacuous. Two deep venues quote the same marginal price, and each one's
    /// output is strictly concave in its input, so some split pays strictly more than either
    /// corner: the route must be one of those, not the better corner.
    function test_Split_TwoDeepVenuesAtOnePriceDeliverStrictlyMoreThanEitherAlone() public {
        uint256[3] memory a = [uint256(1_000e18), 30_000e18, 200_000e18];
        Pair memory v2 = _latticePair(1);
        Pair memory v3 = _latticePair(2);
        Pair memory both = _latticePair(3);
        for (uint256 dir; dir < 2; ++dir) {
            for (uint256 i; i < 3; ++i) {
                uint256 one = _sell(v2, dir, a[i]).delivered;
                uint256 other = _sell(v3, dir, a[i]).delivered;
                assertGt(one, 0, "the V2 venue alone delivered nothing");
                assertGt(other, 0, "the V3 venue alone delivered nothing");
                assertGt(
                    _sell(both, dir, a[i]).delivered,
                    one > other ? one : other,
                    _at("two venues at one price paid no more than the better one alone", 3, dir, a[i])
                );
            }
        }
    }

    /// One order of the hop grid in the three worlds. Returns 1 where the direct venue is the
    /// better way alone, 2 where the bridge path is, 0 on a tie.
    function _hopPoint(Pair memory direct, Pair memory bridged, Pair memory joint, uint256 dir, uint256 amt)
        internal returns (uint256 which)
    {
        Shot memory sd = _sell(direct, dir, amt);
        Shot memory sb = _sell(bridged, dir, amt);
        Shot memory su = _sell(joint, dir, amt);
        assertTrue(sd.ok && sb.ok && su.ok, _at("a world of the hop grid refused its order", 3, dir, amt));
        assertEq(
            su.delivered,
            sd.delivered > sb.delivered ? sd.delivered : sb.delivered,
            _at("both topologies together did not pay what the better one pays alone", 3, dir, amt)
        );
        if (sd.delivered > sb.delivered) which = 1;
        if (sb.delivered > sd.delivered) which = 2;
    }

    /// One hop against two. The topologies are alternatives, never mixed in one route, so the
    /// pair reachable both ways must pay exactly what the better way pays when it is the only
    /// one: the direct venue for the small orders, the bridge path for the large ones.
    function test_Hops_TheUnionDeliversExactlyWhatTheBetterTopologyDeliversAlone() public {
        uint256[5] memory a = _grid();
        Pair memory direct = _hopPair(1);
        Pair memory bridged = _hopPair(2);
        Pair memory joint = _hopPair(3);
        uint256[3] memory wins;
        for (uint256 dir; dir < 2; ++dir) {
            for (uint256 i; i < 5; ++i) {
                ++wins[_hopPoint(direct, bridged, joint, dir, a[i])];
            }
        }
        assertGt(wins[1], 0, "the grid never made the direct venue the better way");
        assertGt(wins[2], 0, "the grid never made the bridge path the better way");
    }
}
