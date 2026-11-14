// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// Red at f9cca7a (fin1111-massa; atq-1111 MUT-3, the map's observable uid 3989). A book at the
// honest fee and two honest venues route an order above their summed depths. A venue behind a
// 90% fee is then listed: the band admits it (it judges the price with the fee put back), the
// exhausted honest venues leave it a leg that pays in gross, and the route's ceiling on a leg's
// measured impact (MAX_ROUTE_IMPACT_BPS, which a V3 leg's fee is a floor of at any size)
// refused the whole route: SolverE(5) for an order that had one. Fixed in the funnel: a row
// whose fee alone reaches that ceiling is not quoted, the same number asking the same question
// at the row's birth; the order keeps the route it had.

import {BlazePhoenixQuoter} from "../src/BlazePhoenixQuoter.sol";
import {SplitPlaceFixture} from "./SplitPlaceFixture.sol";

contract DestroyerLegAtBirthTest is SplitPlaceFixture {
    /// Books of 120..300, 90% venues of 20..90 liquidity, orders at 110..150% of the summed
    /// depth: every point keeps a route and pays what it paid without the 90% venue or more.
    function test_AVenueBehindNinetyPercentLeavesTheOrderWithARoute() public {
        _market();
        if (address(tA) < address(tB)) (tA, tB) = (tB, tA);
        hub.addBridge(address(tB));
        uint256[4] memory hx = [uint256(120e18), 150e18, 200e18, 300e18];
        uint128[3] memory lc = [uint128(20e18), 50e18, 90e18];
        uint256[3] memory pc = [uint256(110), 120, 150];
        uint256 points;
        uint256 unrouted;
        for (uint256 i; i < 4; ++i) {
            for (uint256 j; j < 3; ++j) {
                for (uint256 k; k < 3; ++k) {
                    uint256 snap = vm.snapshotState();
                    _venueOn(tA, tB, HONEST_FEE, HONEST_L, 9 * uint256(HONEST_L));
                    _venueOn(tA, tB, HONEST_FEE, HONEST_L, 9 * uint256(HONEST_L));
                    _book(HONEST_FEE, hx[i]);
                    uint256 amt = (2 * uint256(HONEST_L) + hx[i] + lc[j]) * pc[k] / 100;
                    uint256 without = _preview(amt).grossOut;
                    assertGt(without, 0, "precondition: the order has no route before the 90% venue is listed");
                    _venueOn(tA, tB, 900_000, lc[j], 9 * uint256(lc[j]));
                    vm.roll(block.number + 1);
                    ++points;
                    try quoter.previewAndEncode(address(tA), address(tB), amt, recipient, block.timestamp) returns (
                        BlazePhoenixQuoter.Preview memory pv, bytes memory
                    ) {
                        assertGe(pv.grossOut, without, "the order pays less with the 90% venue listed than without it");
                    } catch (bytes memory why) {
                        ++unrouted;
                        emit log_named_uint("NO ROUTE: the book holds", hx[i]);
                        emit log_named_uint("    liquidity of the 90% venue", lc[j]);
                        emit log_named_uint("    order", amt);
                        emit log_named_uint("    gross out without the 90% venue", without);
                        emit log_named_bytes("    answer with it", why);
                    }
                    vm.revertToState(snap);
                }
            }
        }
        emit log_named_uint("points", points);
        emit log_named_uint("points with no route", unrouted);
        assertEq(unrouted, 0, "a venue behind a 90% fee left a routed order with no route (points logged above)");
    }
}
