// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  PIN-01 - "how many legs fit in a hop?" - ONE producer since 2026-11-06.
//
//  Core's file-level MAX_LEGS_PER_HOP = 5 is read by every place that asks it:
//    Router._execute        refuses a wider hop with RouterE(3);
//    Quoter._hookRefusedIn  previews such a route as not executable;
//    Solver                 builds every stage on it: the direct hop and both bridge stages.
//  Until 2026-11-06 the question had three producers that disagreed - the Router's 5, the
//  Solver's MAX_LEGS_PER_STAGE = 4 and its route-wide MAX_LEGS = 11 - and this file pinned
//  the relation stage <= perHop between two of them. With one producer that relation is the
//  identity; what is pinned now is the number at every door, and the route it makes with
//  MAX_HOPS: two hops of five, ten legs (owner, 2026-11-06: "2 hops e 10 legs"; 2026-11-03:
//  never 6 legs a hop). Ten is not a constant of its own - no code reads a route-wide count -
//  so it is pinned here as behaviour:
//   1. one hop: 5 legs preview as executable and settle; 6 preview as refused and are refused
//      with RouterE(3);
//   2. two hops: 5 + 5 = 10 legs preview as executable and settle; 4 + 6, the same ten legs
//      with one hop past the ceiling, preview as refused and are refused - the bound is per
//      hop, on every hop, and never a count of the route;
//   3. the Solver, offered six venues on every pair, builds a direct hop of exactly 5 legs and
//      a bridge route of exactly 5 + 5, and the Router settles both.
//  Every case asks the Quoter and the Router the same route, so a preview that endorses a
//  route the Router refuses (or the reverse) goes red here.
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixQuoter} from "../src/BlazePhoenixQuoter.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {
    BlazePhoenixCore as BPC, Route, Hop, Leg, MAX_HOPS, MAX_LEGS_PER_HOP
} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";

contract Pin01LegCeilingTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    BlazePhoenixQuoter quoter;
    BlazePhoenixRouter router;
    MockERC20 ta;
    MockERC20 tb;
    MockERC20 tc;
    MockV2Pair[6] ab;               // six venues on ta/tb
    MockV2Pair[6] bc;               // six venues on tb/tc (hand-built second hops only: no bridge)

    address user = address(0xBEEF);
    uint112 constant RESERVE = uint112(10_000_000e18);
    uint256 constant AMT = 100_000e18;
    uint256 constant CLAIM = 1e18;  // a positive totalOut: the preview's netOut needs one, the Router reads none

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        solver = new BlazePhoenixSolver(address(hub), address(0));
        quoter = new BlazePhoenixQuoter(address(hub), address(solver));
        router = new BlazePhoenixRouter(
            address(hub), address(solver), address(this), address(0xFEE1), address(0xFEE2)
        );
        hub.setRoles(address(router), address(solver), address(quoter));

        ta = new MockERC20("A", "A");
        tb = new MockERC20("B", "B");
        tc = new MockERC20("C", "C");
        // Six venues on a pair, of unequal depth: one more than the ceiling, so the Solver's
        // budget really binds and a hand-built hop can be one leg past it.
        ab = _venues(ta, tb);
        bc = _venues(tb, tc);

        ta.mint(user, 10_000_000e18);
        vm.prank(user);
        ta.approve(address(router), type(uint256).max);
    }

    // ── 1. One hop: the ceiling from both sides ─────────────────────────────

    /// 5 legs in one hop - exactly MAX_LEGS_PER_HOP - preview as executable and settle.
    function test_FiveLegsInOneHop_PreviewExecutableAndSettles() public {
        Route memory r = _route(5, 0);   // built before the prank (it reads the pools)
        assertTrue(quoter.previewRoute(r, 1).canExecute, "the preview refuses a five-leg hop the Router takes");
        vm.prank(user);
        uint256 out = router.swapExactIn(r, AMT, 1, user, block.timestamp + 1);
        assertGt(out, 0, "a five-leg hop must settle");
        assertEq(ta.balanceOf(address(router)), 0, "the Router must hold nothing");
    }

    /// 6 legs in one hop - one past the ceiling - preview as refused and are refused with
    /// RouterE(3). The five-leg case above is the same construction one leg shorter.
    function test_SixLegsInOneHop_PreviewRefusedAndRefused() public {
        Route memory r = _route(6, 0);
        assertFalse(quoter.previewRoute(r, 1).canExecute, "the preview endorses a six-leg hop the Router refuses");
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, uint16(3)));
        router.swapExactIn(r, AMT, 1, user, block.timestamp + 1);
    }

    // ── 2. Two hops: ten legs, and the bound is per hop ─────────────────────

    /// 5 + 5 = MAX_HOPS x MAX_LEGS_PER_HOP = 10 legs: the widest route there is previews as
    /// executable and settles. A ceiling that counted the route's legs against the per-hop
    /// number would refuse the second hop here.
    function test_TenLegsOverTwoHops_PreviewExecutableAndSettles() public {
        Route memory r = _route(5, 5);
        assertEq(_legsOf(r), MAX_HOPS * MAX_LEGS_PER_HOP, "premise: the route holds the ten legs of the ceiling");
        assertTrue(quoter.previewRoute(r, 1).canExecute, "the preview refuses the ten-leg route the Router takes");
        vm.prank(user);
        uint256 out = router.swapExactIn(r, AMT, 1, user, block.timestamp + 1);
        assertGt(out, 0, "two hops of five legs must settle");
        assertEq(tc.balanceOf(user), out, "and deliver the second hop's output token");
    }

    /// 4 + 6: the same ten legs, with the SECOND hop one past the ceiling. Previewed as refused
    /// and refused with RouterE(3): every hop is asked, not only the first, and no count of
    /// the route stands in for the per-hop bound.
    function test_SixLegsOnTheSecondHop_PreviewRefusedAndRefused() public {
        Route memory r = _route(4, 6);
        assertEq(_legsOf(r), MAX_HOPS * MAX_LEGS_PER_HOP, "premise: ten legs, as many as the route above");
        assertFalse(quoter.previewRoute(r, 1).canExecute, "the preview endorses a second hop the Router refuses");
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, uint16(3)));
        router.swapExactIn(r, AMT, 1, user, block.timestamp + 1);
    }

    // ── 3. The Solver builds to the ceiling, and the Router takes it ────────

    /// Offered six venues on the pair, the Solver builds the direct hop with exactly
    /// MAX_LEGS_PER_HOP legs - not fewer (a budget under the ceiling leaves a venue out),
    /// not more (the Router would refuse it) - and the route settles.
    function test_Solver_DirectHopUsesTheWholeCeilingAndSettles() public {
        Route memory best = solver.findBestRoutePlan(address(ta), address(tb), AMT).best;
        assertEq(best.hops.length, 1, "premise: no bridge, the route is direct");
        assertEq(best.hops[0].legs.length, MAX_LEGS_PER_HOP, "the direct hop is not built to the ceiling");
        vm.prank(user);
        uint256 out = router.swapExactIn(best, AMT, 1, user, block.timestamp + 1);
        assertGt(out, 0, "the Solver's widest direct hop must settle");
    }

    /// The same on a bridge route: six venues on each stage and no direct pool, so the order
    /// can only go through the bridge. Each stage is built to the ceiling, 5 + 5 = 10 legs,
    /// and the Router settles the route the Solver built.
    function test_Solver_BridgeStagesUseTheWholeCeilingAndSettle() public {
        MockERC20 tx_ = new MockERC20("X", "X");
        MockERC20 ty = new MockERC20("Y", "Y");
        MockERC20 br = new MockERC20("BR", "BR");
        hub.addBridge(address(br));
        _venues(tx_, br);
        _venues(br, ty);

        Route memory best = solver.findBestRoutePlan(address(tx_), address(ty), AMT).best;
        assertEq(best.hops.length, MAX_HOPS, "premise: the order goes through the bridge");
        for (uint256 h; h < MAX_HOPS; ++h)
            assertEq(best.hops[h].legs.length, MAX_LEGS_PER_HOP, "a bridge stage is not built to the ceiling");

        tx_.mint(user, AMT);
        vm.startPrank(user);
        tx_.approve(address(router), AMT);
        uint256 out = router.swapExactIn(best, AMT, 1, user, block.timestamp + 1);
        vm.stopPrank();
        assertGt(out, 0, "the Solver's ten-leg bridge route must settle");
        assertEq(ty.balanceOf(user), out, "and deliver the route's output token");
    }

    // ── helpers ─────────────────────────────────────────────────────────────

    /// Six V2 venues on `a`/`b`, the i-th of depth RESERVE / (i + 1), seeded in the Hub.
    function _venues(MockERC20 a, MockERC20 b) private returns (MockV2Pair[6] memory ps) {
        for (uint256 i; i < 6; ++i) {
            MockV2Pair p = new MockV2Pair(address(a), address(b));
            uint112 r = uint112(uint256(RESERVE) / (i + 1));
            a.mint(address(p), r);
            b.mint(address(p), r);
            p.setReserves(r, r);
            hub.seedPool(address(p), BPC.KIND_V2, 30, address(0), address(a), address(b));
            ps[i] = p;
        }
    }

    /// A hop of `nLegs` legs on venues[0..nLegs-1], the nominal `amt` split evenly. Legs and hop
    /// declare no output: the Router rescales each hop by the balance it MEASURED arriving, so
    /// a declaration only has to be spendable, and a zero bound asks no per-leg floor.
    function _hop(MockV2Pair[6] memory venues, address tIn, address tOut, uint256 nLegs, uint256 amt)
        private view returns (Hop memory)
    {
        Leg[] memory legs = new Leg[](nLegs);
        uint256 part = amt / nLegs;
        for (uint256 i; i < nLegs; ++i) {
            MockV2Pair p = venues[i];
            legs[i] = Leg({
                pool: address(p), hooks: address(0), kind: BPC.KIND_V2, fee: 30, tickSpacing: 0,
                zeroForOne: p.token0() == tIn, stable: false,
                amountIn: i == nLegs - 1 ? amt - part * (nLegs - 1) : part, expectedOut: 0,
                auxId: bytes32(0)
            });
        }
        return Hop({tokenIn: tIn, tokenOut: tOut, amountIn: amt, expectedOut: 0, legs: legs});
    }

    /// ta -> tb with `first` legs and, when `second` is non-zero, tb -> tc with `second` legs.
    function _route(uint256 first, uint256 second) private view returns (Route memory r) {
        Hop[] memory hops = new Hop[](second == 0 ? 1 : 2);
        hops[0] = _hop(ab, address(ta), address(tb), first, AMT);
        if (second != 0) hops[1] = _hop(bc, address(tb), address(tc), second, AMT);
        r = Route({
            hops: hops, totalOut: CLAIM, singleOut: CLAIM, singleOutFloor: 0,
            expectedImpactBps: 0, confidenceWad: 0, estGas: 0, hasSurplus: false, isV4Bundle: false
        });
    }

    function _legsOf(Route memory r) private pure returns (uint256 n) {
        for (uint256 h; h < r.hops.length; ++h) n += r.hops[h].legs.length;
    }
}
