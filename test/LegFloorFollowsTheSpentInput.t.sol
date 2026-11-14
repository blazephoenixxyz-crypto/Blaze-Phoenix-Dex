// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  LEG_FLOOR_BPS - which legs share the hop budget, and what input the leg floor
//  is sized on.
//
//  No defect. Watcher tests for two questions the Router answers. Green at 877b482
//  (src unchanged); red only under mutants "126-B12 Router: a leg with no bound is
//  counted in the hop slack divisor ..." and "126-B12 Router: the attested bound is
//  not rescaled to the input the leg actually spent ...".
//
//    per leg (Router._execScaled):
//                       bound = floor(expectedOut * amt / leg.amountIn)       (pro-rata)
//                       got < mulDivUp(bound, LEG_FLOOR_BPS, BPS)             -> RouterE(5)
//    per hop (Router):  hopGot + mulDiv(hopBound / hopQuoted, BPS - LEG_FLOOR_BPS, BPS)
//                         < hopBound                                          -> RouterE(5)
//
//  1. n in the hop slack is `hopQuoted`, the legs that carry a bound - not the legs in
//     calldata. A leg scaled to zero input (declared amountIn 0) carries no bound and
//     is not counted: one live leg beside a dead one is held to its own leg floor,
//     exactly (the hop collapses at n = 1), and k live legs beside d dead ones share
//     the slack of k legs. Counting the dead legs would shrink the slack and refuse
//     an honest settlement.
//  2. The attested bound follows the input the leg ACTUALLY spent: a leg that got
//     m of its planned P is held to floor(E * m / P), not to E. Without the rescale an
//     honest leg fed 60% of its plan must deliver 80% of the whole plan.
//     Two vectors feed a leg less than its plan: a two-hop route whose hop 1 plans more
//     than hop 0 delivers (and the fee leaves on the bridge), and a caller who executes
//     a one-hop route below the plan it signed.
//
//  Oracle: the honest pool's delivery is MEASURED in a control settlement (balanceOf
//  deltas, inside a snapshot), and the boundaries are plain integer arithmetic on it.
//  Pools are honest MockV2Pair; only the attestation is inflated (a route that
//  over-promises), so the protocol floor of the final hop never speaks first.
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";

contract LegFloorFollowsTheSpentInputTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    BlazePhoenixRouter router;
    MockERC20 ta;
    MockERC20 tb;
    MockERC20 tc;

    address user = address(0xBEEF);
    uint112 constant R = uint112(1_000_000e18);
    uint24 constant FEE = 30;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        solver = new BlazePhoenixSolver(address(hub), address(0));
        router = new BlazePhoenixRouter(address(hub), address(solver), address(this), address(0xFEE1), address(0xFEE2));
        hub.setRoles(address(router), address(solver), address(this));
        ta = new MockERC20("A", "A");
        tb = new MockERC20("B", "B");
        tc = new MockERC20("C", "C");
        hub.addBridge(address(tb));
        ta.mint(user, type(uint128).max);
        vm.prank(user);
        ta.approve(address(router), type(uint256).max);
    }

    // ── 1. A dead leg is not counted in the hop slack ───────────────────────

    /// k = 1, d = 1: the live leg settles at the largest bound its own floor accepts,
    /// beta = floor(g * 10000 / 8000), and is refused one wei above. Counting the dead
    /// leg (n = 2) halves the slack and refuses beta.
    function test_ADeadLegBesideOneLiveLegLeavesTheLegFloorExact() public {
        uint256[3] memory amts = [uint256(1e15 + 1), 12_347e15, 1_000e18 + 7];
        for (uint256 i; i < amts.length; ++i) {
            for (uint256 s; s < 2; ++s) {
                uint256 snap = vm.snapshotState();
                _oneLiveLegBoundary(amts[i], s);
                vm.revertToState(snap);
            }
        }
    }

    function test_DeadLegsDoNotShrinkTheHopSlack_Grid() public {
        uint256[3] memory amts = [uint256(1e15 + 1), 12_347e15, 1_000e18 + 7];
        for (uint256 k = 1; k <= 4; ++k) {
            for (uint256 d = 1; d + k <= 5; ++d) {
                for (uint256 p; p < 3; ++p) {
                    uint256 snap = vm.snapshotState();
                    _deadLegsBoundary(k, d, _deadStart(k, p), amts[(k + d + p) % 3]);
                    vm.revertToState(snap);
                }
            }
        }
    }

    function testFuzz_DeadLegsDoNotShrinkTheHopSlack(uint8 kSeed, uint8 dSeed, uint256 amtSeed) public {
        uint256 k = bound(kSeed, 1, 4);
        uint256 d = 1 + (uint256(dSeed) % (5 - k)); // k + d <= MAX_LEGS_PER_HOP = 5
        uint256 p = (uint256(dSeed) / 5) % 3;
        _deadLegsBoundary(k, d, _deadStart(k, p), bound(amtSeed, 1e15, 10_000e18));
    }

    // ── 2. The leg floor follows the input actually spent ───────────────────

    /// ta -> tb (bridge) -> tc. Hop 1 plans P > m, the tb that reaches its pool. The
    /// leg is held to floor(E * m / P): settles at the largest E whose pro-rata the
    /// honest delivery g1 covers, refused one wei above.
    function test_ALegGivenLessInputIsHeldToTheProRataOfItsAttestation() public {
        uint256[2] memory amts = [uint256(12_347e15 + 1), 1_000e18 + 7];
        for (uint256 i; i < amts.length; ++i) {
            for (uint256 j; j < 3; ++j) {
                uint256 snap = vm.snapshotState();
                _underFedHopBoundary(amts[i], j);
                vm.revertToState(snap);
            }
        }
    }

    /// One hop, one leg planned at P, executed with a < P: the bound scales with a.
    function test_ARouteExecutedBelowItsPlanScalesTheFloorWithIt() public {
        uint256 plan = 1_000e18 + 7;
        uint256[3] memory ins = [plan / 2 + 1, 600e18 + 1, plan - 1];
        for (uint256 i; i < ins.length; ++i) {
            uint256 snap = vm.snapshotState();
            _belowPlanBoundary(plan, ins[i]);
            vm.revertToState(snap);
        }
    }

    // ── boundaries ──────────────────────────────────────────────────────────

    function _oneLiveLegBoundary(uint256 amt, uint256 s) private {
        MockV2Pair[] memory ps = _pools(2, tb);
        (uint256 g, uint256 paid) = _controlOneHop(ps, 1, s, amt);
        uint256 beta = (g * 10_000) / 8_000;
        assertGt(beta, g, "fixture: the route over-promises");
        assertLe((beta * 8_000 + 9_999) / 10_000, g, "oracle: beta settles on the leg floor");
        assertGt(((beta + 1) * 8_000 + 9_999) / 10_000, g, "oracle: beta + 1 is refused");
        // Counting the dead leg: slack on half the bound, and beta is refused.
        assertLt(g + ((beta / 2) * 2_000) / 10_000, beta, "fixture: n = 2 would refuse beta");

        uint256 snap = vm.snapshotState();
        uint256 b0 = tb.balanceOf(user);
        _swap(_mixedHop(ps, 1, s, amt, _one(beta)), amt);
        assertEq(tb.balanceOf(user) - b0, paid, "the user is paid what the honest leg made");
        vm.revertToState(snap);

        _refuse(_mixedHop(ps, 1, s, amt, _one(beta + 1)), amt);
    }

    /// k live legs of `amt`, d dead ones starting at index s. Oracle of the hop slack
    /// with n = k: the largest A with A - floor(floor(A / k) * 2000 / 10000) <= hopGot.
    function _deadLegsBoundary(uint256 k, uint256 d, uint256 s, uint256 amt) private {
        MockV2Pair[] memory ps = _pools(k + d, tb);
        (uint256 hopGot,) = _controlOneHop(ps, k, s, amt);
        uint256 a = hopGot;
        for (uint256 i; i < 64; ++i) {
            uint256 next = hopGot + ((a / k) * 2_000) / 10_000;
            if (next == a) break;
            a = next;
        }
        while ((a + 1) - (((a + 1) / k) * 2_000) / 10_000 <= hopGot) ++a;
        assertLe(a - ((a / k) * 2_000) / 10_000, hopGot, "oracle: A settles");
        assertGt((a + 1) - (((a + 1) / k) * 2_000) / 10_000, hopGot, "oracle: A + 1 is refused");
        assertGt(a, hopGot, "fixture: the route over-promises");
        assertGt(a - ((a / (k + d)) * 2_000) / 10_000, hopGot, "fixture: n = k + d would refuse A");

        uint256 snap = vm.snapshotState();
        _swap(_mixedHop(ps, k, s, amt, _split(a, k)), amt * k);
        vm.revertToState(snap);

        _refuse(_mixedHop(ps, k, s, amt, _split(a + 1, k)), amt * k);
    }

    function _underFedHopBoundary(uint256 amt, uint256 j) private {
        MockV2Pair p0 = _pools(1, tb)[0];
        MockV2Pair p1 = _pair(tb, tc);
        // Control: no attestation on either hop (the coverage arm only).
        uint256 g0;
        uint256 m;
        uint256 g1;
        uint256 paid;
        {
            uint256 snap = vm.snapshotState();
            uint256 p0b = tb.balanceOf(address(p0));
            uint256 p1b = tb.balanceOf(address(p1));
            uint256 p1c = tc.balanceOf(address(p1));
            _swap(_twoHop(p0, p1, amt, 0, amt, 0), amt);
            g0 = p0b - tb.balanceOf(address(p0));
            m = tb.balanceOf(address(p1)) - p1b;
            g1 = p1c - tc.balanceOf(address(p1));
            paid = tc.balanceOf(user);
            vm.revertToState(snap);
        }
        assertLt(m, g0, "fixture: the fee leaves on the bridge");
        uint256 plan = j == 0 ? (m * 5 + 2) / 3 + 1 : j == 1 ? 2 * m + 3 : 10 * m + 7;
        (uint256 e,) = _proRataBoundary(g1, m, plan);

        uint256 snap2 = vm.snapshotState();
        _swap(_twoHop(p0, p1, amt, g0, plan, e), amt);
        assertEq(tc.balanceOf(user), paid, "the user is paid what the honest legs made");
        vm.revertToState(snap2);

        _refuse(_twoHop(p0, p1, amt, g0, plan, e + 1), amt);
    }

    function _belowPlanBoundary(uint256 plan, uint256 a) private {
        MockV2Pair[] memory ps = _pools(1, tb);
        uint256 g;
        uint256 paid;
        {
            uint256 snap = vm.snapshotState();
            uint256 pa = ta.balanceOf(address(ps[0]));
            uint256 pb = tb.balanceOf(address(ps[0]));
            _swap(_planHop(ps[0], plan, 0), a);
            assertEq(ta.balanceOf(address(ps[0])) - pa, a, "fixture: the leg spends the input executed");
            g = pb - tb.balanceOf(address(ps[0]));
            paid = tb.balanceOf(user);
            vm.revertToState(snap);
        }
        (uint256 e,) = _proRataBoundary(g, a, plan);

        uint256 snap2 = vm.snapshotState();
        _swap(_planHop(ps[0], plan, e), a);
        assertEq(tb.balanceOf(user), paid, "the user is paid what the honest leg made");
        vm.revertToState(snap2);

        _refuse(_planHop(ps[0], plan, e + 1), a);
    }

    /// A leg that spent m of a plan P and delivered g: beta = floor(g * 10000 / 8000) is
    /// the largest bound its floor accepts, and E* = ceil((beta + 1) * P / m) - 1 the
    /// largest attestation whose pro-rata is beta.
    function _proRataBoundary(uint256 g, uint256 m, uint256 plan) private pure returns (uint256 e, uint256 beta) {
        beta = (g * 10_000) / 8_000;
        e = ((beta + 1) * plan + m - 1) / m - 1;
        assertGt(plan, m, "fixture: the leg is fed less than its plan");
        assertEq((e * m) / plan, beta, "oracle: the pro-rata of E* is beta");
        assertEq(((e + 1) * m) / plan, beta + 1, "oracle: the pro-rata of E* + 1 is beta + 1");
        assertTrue((e * m) % plan != 0, "fixture: the pro-rata truncates");
        assertGt(beta, (g * 5_000) / 10_000, "fixture: the attestation speaks, not the coverage arm");
        // Sized on the whole plan, the floor would refuse E*: this is what the rescale buys.
        assertGt((e * 8_000 + 9_999) / 10_000, g, "fixture: the unscaled floor would refuse E*");
    }

    // ── controls ────────────────────────────────────────────────────────────

    /// Settles the mixed hop with no attestation and measures what the live legs made
    /// (hopGot) and what the user was paid. Dead legs never reach their pool.
    function _controlOneHop(MockV2Pair[] memory ps, uint256 k, uint256 s, uint256 amt)
        private returns (uint256 hopGot, uint256 paid)
    {
        uint256 snap = vm.snapshotState();
        uint256[] memory before = new uint256[](ps.length);
        for (uint256 i; i < ps.length; ++i) before[i] = tb.balanceOf(address(ps[i]));
        _swap(_mixedHop(ps, k, s, amt, new uint256[](k)), amt * k);
        uint256 d = ps.length - k;
        for (uint256 i; i < ps.length; ++i) {
            if (i >= s && i < s + d) {
                assertEq(tb.balanceOf(address(ps[i])), before[i], "fixture: a dead leg never reaches its pool");
            } else {
                hopGot += before[i] - tb.balanceOf(address(ps[i]));
            }
        }
        paid = tb.balanceOf(user);
        vm.revertToState(snap);
    }

    // ── routes ──────────────────────────────────────────────────────────────

    /// Index where the d dead legs start: first, between live legs, last.
    function _deadStart(uint256 k, uint256 p) private pure returns (uint256) {
        return p == 0 ? 0 : p == 1 ? (k + 1) / 2 : k;
    }

    /// One hop ta -> tb over ps: k live legs of `amt` attesting `att`, and
    /// ps.length - k dead legs (amountIn 0, expectedOut 0) at indexes [s, s + d).
    function _mixedHop(MockV2Pair[] memory ps, uint256 k, uint256 s, uint256 amt, uint256[] memory att)
        private view returns (Route memory r)
    {
        uint256 d = ps.length - k;
        Leg[] memory legs = new Leg[](ps.length);
        uint256 total;
        uint256 live;
        for (uint256 i; i < ps.length; ++i) {
            bool dead = i >= s && i < s + d;
            uint256 e = dead ? 0 : att[live++];
            legs[i] = _leg(ps[i], ta, dead ? 0 : amt, e);
            total += e;
        }
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({tokenIn: address(ta), tokenOut: address(tb), amountIn: amt * k, expectedOut: total, legs: legs});
        r = _route(hops, total);
    }

    /// One hop ta -> tb, one leg planned at `plan`.
    function _planHop(MockV2Pair p, uint256 plan, uint256 att) private view returns (Route memory r) {
        Leg[] memory legs = new Leg[](1);
        legs[0] = _leg(p, ta, plan, att);
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({tokenIn: address(ta), tokenOut: address(tb), amountIn: plan, expectedOut: att, legs: legs});
        r = _route(hops, att);
    }

    /// ta -> tb (bridge) on p0, tb -> tc on p1 planned at `plan`.
    function _twoHop(MockV2Pair p0, MockV2Pair p1, uint256 amt, uint256 att0, uint256 plan, uint256 att1)
        private view returns (Route memory r)
    {
        Leg[] memory l0 = new Leg[](1);
        l0[0] = _leg(p0, ta, amt, att0);
        Leg[] memory l1 = new Leg[](1);
        l1[0] = _leg(p1, tb, plan, att1);
        Hop[] memory hops = new Hop[](2);
        hops[0] = Hop({tokenIn: address(ta), tokenOut: address(tb), amountIn: amt, expectedOut: att0, legs: l0});
        hops[1] = Hop({tokenIn: address(tb), tokenOut: address(tc), amountIn: plan, expectedOut: att1, legs: l1});
        r = _route(hops, att1);
    }

    function _leg(MockV2Pair p, MockERC20 tIn, uint256 amountIn, uint256 att) private view returns (Leg memory) {
        return Leg({
            pool: address(p), hooks: address(0), kind: BPC.KIND_V2, fee: FEE, tickSpacing: 0,
            zeroForOne: p.token0() == address(tIn), stable: false, amountIn: amountIn,
            expectedOut: att, auxId: bytes32(0)
        });
    }

    function _route(Hop[] memory hops, uint256 total) private pure returns (Route memory) {
        return Route({
            hops: hops, totalOut: total, singleOut: total, singleOutFloor: 0,
            expectedImpactBps: 0, confidenceWad: 0, estGas: 0, hasSurplus: false, isV4Bundle: false
        });
    }

    // ── helpers ─────────────────────────────────────────────────────────────

    /// Attestations of k legs summing to `a`, as even as the wei allows.
    function _split(uint256 a, uint256 k) private pure returns (uint256[] memory b) {
        b = new uint256[](k);
        for (uint256 i; i < k; ++i) b[i] = a / k + (i < a % k ? 1 : 0);
    }

    function _one(uint256 x) private pure returns (uint256[] memory b) {
        b = new uint256[](1);
        b[0] = x;
    }

    function _pools(uint256 n, MockERC20 out) private returns (MockV2Pair[] memory ps) {
        ps = new MockV2Pair[](n);
        for (uint256 i; i < n; ++i) ps[i] = _pair(ta, out);
    }

    function _pair(MockERC20 x, MockERC20 y) private returns (MockV2Pair p) {
        p = new MockV2Pair(address(x), address(y));
        x.mint(address(p), R);
        y.mint(address(p), R);
        p.setReserves(R, R);
        hub.seedPool(address(p), BPC.KIND_V2, FEE, address(0), address(x), address(y));
    }

    function _swap(Route memory r, uint256 amountIn) private {
        vm.prank(user);
        uint256 out = router.swapExactIn(r, amountIn, 1, user, block.timestamp + 1);
        assertGt(out, 0, "the route at the boundary must settle");
    }

    function _refuse(Route memory r, uint256 amountIn) private {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, uint16(5)));
        router.swapExactIn(r, amountIn, 1, user, block.timestamp + 1);
    }
}
