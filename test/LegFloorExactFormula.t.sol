// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  LEG_FLOOR_BPS - the exact formula of the two floors, to the wei.
//
//    per leg (Router):  got < mulDivUp(bound, LEG_FLOOR_BPS, BPS)                 -> RouterE(5)
//    per hop (Router):  hopGot + mulDiv(hopAttested / hopQuoted, BPS - LEG_FLOOR_BPS, BPS)
//                         < hopAttested                                            -> RouterE(5)
//
//  1. The leg floor is a STRICT comparison against the CEIL of 80% of the bound: a
//     leg that delivers exactly ceil(0.8 * bound) settles, one wei less is refused.
//     The bound is chosen so 0.8 * bound is not an integer (the ceil is real).
//  2. The hop slack is ONE AVERAGE LEG (hopAttested / n), not the whole hop: on a hop
//     of n honest legs whose attestations sum to A, the hop settles at the largest A
//     with A - floor(floor(A / n) * 2000 / 10000) <= hopGot and is refused one wei
//     above. A slack sized on the whole hop (n times larger) or on 80% instead of 20%
//     (4 times larger) lets the wei above settle.
//  3. At n = 1 the hop floor collapses on the leg floor: b - floor(0.2b) == ceil(0.8b).
//  4. A leg that attests NOTHING (expectedOut == 0) is still floored by its in-frame
//     quote: bound = floor(qs * MIN_QUOTE_COVERAGE_BPS / BPS), so it must deliver
//     ceil(0.8 * floor(0.5 * qs)); one wei less is refused. The lying leg sits on hop 0
//     of a two-hop route, so the protocol floor of the final hop never speaks first.
//     With no quote either (bound 0) the leg floor cannot fire; the executor's own
//     zero-output refusal, RouterE(8), is what holds.
//
//  The fee is taken on the OUTPUT (the destination is a bridge coin), so each leg gets
//  its whole input and `got` is the full outV2 of an honest pool. Only the attestation
//  (`expectedOut`) is inflated: the vector is a route that over-promises.
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";
import {MockPayingPair} from "./mocks/MockPayingPair.sol";

contract LegFloorExactFormulaTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    BlazePhoenixRouter router;
    MockERC20 ta;
    MockERC20 tb;

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
        hub.addBridge(address(tb));
        ta.mint(user, type(uint128).max);
        vm.prank(user);
        ta.approve(address(router), type(uint256).max);
    }

    // ── 1. The leg floor: strict, against the ceil ──────────────────────────

    function test_LegFloorIsCeilOnTheProRataBound() public {
        assertEq(BPC.LEG_FLOOR_BPS, 8_000, "LEG_FLOOR_BPS is the number under test");
        // Pick the first plan size whose bound floor(1.25 * got) has a fractional 80%.
        uint256 amt = 1_000e18;
        uint256 got;
        uint256 bound;
        for (uint256 i; i < 50; ++i) {
            got = BPC.outV2(amt, uint256(R), uint256(R), BPC.effV2Fee(FEE));
            bound = (got * 10) / 8;
            if (bound % 5 != 0 && (bound * 8_000 + 9_999) / 10_000 == got) break;
            amt += 1e15 + 7;
        }
        assertTrue(bound % 5 != 0, "fixture: 0.8 * bound must not be an integer");
        assertEq((bound * 8_000 + 9_999) / 10_000, got, "fixture: the ceil of 80% of the bound is got");
        assertLt((bound * 8_000) / 10_000, got, "fixture: the floor would sit one wei lower");

        // At the ceil: settles.
        uint256 snap = vm.snapshotState();
        _swap(_hop(_pools(1), amt, _one(bound)), amt);
        vm.revertToState(snap);
        // One wei of attestation more moves the ceil to got + 1: refused.
        Route memory r = _hop(_pools(1), amt, _one(bound + 1));
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, uint16(5)));
        router.swapExactIn(r, amt, 1, user, block.timestamp + 1);
    }

    // ── 2. The hop slack is one average leg ─────────────────────────────────

    function testFuzz_HopFloorSlackIsOneAverageLeg(uint8 nSeed, uint256 amtSeed) public {
        uint256 n = bound(nSeed, 2, 5); // MAX_LEGS_PER_HOP = 5
        uint256 amt = bound(amtSeed, 1e15, 10_000e18);
        _hopBoundary(n, amt);
    }

    function test_HopFloorSlackIsOneAverageLeg_Grid() public {
        uint256[4] memory ns = [uint256(2), 3, 4, 5];
        uint256[3] memory amts = [uint256(1e15 + 1), 12_347e15, 1_000e18 + 7];
        for (uint256 i; i < ns.length; ++i) {
            for (uint256 j; j < amts.length; ++j) {
                uint256 snap = vm.snapshotState();
                _hopBoundary(ns[i], amts[j]);
                vm.revertToState(snap);
            }
        }
    }

    // ── 3. At n = 1 the hop floor collapses on the leg floor ────────────────

    function testFuzz_HopCollapsesToLegFloorAtN1(uint256 att) public pure {
        att = bound(att, 1, type(uint128).max);
        uint256 hopMin = att - BPC.mulDiv(att, BPC.BPS - BPC.LEG_FLOOR_BPS, BPC.BPS);
        assertEq(hopMin, BPC.mulDivUp(att, BPC.LEG_FLOOR_BPS, BPC.BPS), "b - floor(0.2b) == ceil(0.8b)");
    }

    // ── 4. A zero attestation is floored by the measured quote ──────────────

    function test_ZeroAttestationIsFlooredAtTheCoverageOfTheQuote() public {
        uint256[3] memory amts = [uint256(1e9 + 3), 12_347e15 + 1, 250_000e18 + 7];
        for (uint256 i; i < amts.length; ++i) {
            uint256 snap = vm.snapshotState();
            _coverageBoundary(amts[i]);
            vm.revertToState(snap);
        }
    }

    function testFuzz_ZeroAttestationIsFlooredAtTheCoverageOfTheQuote(uint256 amtSeed) public {
        _coverageBoundary(bound(amtSeed, 1e9, 500_000e18));
    }

    /// bound 0 AND quote 0 (the pool's out reserve reads zero): the leg floor has nothing
    /// to floor. The executor refuses the zero output before the pool is called, with
    /// RouterE(8) - not the blind-hop RouterE(5) that would follow on a non-final hop.
    function test_ZeroBoundLegIsRefusedByTheExecutorNotTheFloor() public {
        (MockPayingPair liar, MockERC20 tc, MockV2Pair honest) = _twoHopPools();
        liar.setReserves(liar.token0() == address(ta) ? R : 0, liar.token0() == address(ta) ? 0 : R);
        liar.setPay(0);
        uint256 amt = 1_000e18;
        Route memory r = _twoHop(liar, honest, tc, amt, 1);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, uint16(8)));
        router.swapExactIn(r, amt, 1, user, block.timestamp + 1);
    }

    // ── helpers ─────────────────────────────────────────────────────────────

    /// n honest legs of `amt` each; attestations summing to A. Settles at the largest A
    /// with A - slack(A) <= hopGot, refused at A + 1.
    function _hopBoundary(uint256 n, uint256 amt) private {
        uint256 g = BPC.outV2(amt, uint256(R), uint256(R), BPC.effV2Fee(FEE));
        uint256 hopGot = g * n;
        // Independent oracle: plain integer arithmetic, slack on one average leg.
        // Fixed point a = hopGot + slack(a) (contraction 1/(5n)), then the last wei of plateau.
        uint256 a = hopGot;
        for (uint256 k; k < 64; ++k) {
            uint256 next = hopGot + ((a / n) * 2_000) / 10_000;
            if (next == a) break;
            a = next;
        }
        while ((a + 1) - (((a + 1) / n) * 2_000) / 10_000 <= hopGot) ++a;
        assertLe(a - ((a / n) * 2_000) / 10_000, hopGot, "oracle: A settles");
        assertGt((a + 1) - (((a + 1) / n) * 2_000) / 10_000, hopGot, "oracle: A + 1 is refused");
        assertGt(a, hopGot, "fixture: the route over-promises");

        MockV2Pair[] memory ps = _pools(n);
        uint256 snap = vm.snapshotState();
        _swap(_hop(ps, amt, _split(a, n)), amt * n);
        vm.revertToState(snap);

        Route memory r = _hop(ps, amt, _split(a + 1, n));
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, uint16(5)));
        router.swapExactIn(r, amt * n, 1, user, block.timestamp + 1);
    }

    /// Attestations of n legs summing to `a`, as even as the wei allows; each stays far
    /// inside its own leg floor (0.8 * (g + g/5n + 1) < g), so only the hop guard speaks.
    function _split(uint256 a, uint256 n) private pure returns (uint256[] memory b) {
        b = new uint256[](n);
        for (uint256 i; i < n; ++i) b[i] = a / n + (i < a % n ? 1 : 0);
    }

    function _one(uint256 x) private pure returns (uint256[] memory b) {
        b = new uint256[](1);
        b[0] = x;
    }

    function _pools(uint256 n) private returns (MockV2Pair[] memory ps) {
        ps = new MockV2Pair[](n);
        for (uint256 i; i < n; ++i) {
            MockV2Pair p = new MockV2Pair(address(ta), address(tb));
            ta.mint(address(p), R);
            tb.mint(address(p), R);
            p.setReserves(R, R);
            hub.seedPool(address(p), BPC.KIND_V2, FEE, address(0), address(ta), address(tb));
            ps[i] = p;
        }
    }

    function _hop(MockV2Pair[] memory ps, uint256 amt, uint256[] memory att)
        private view returns (Route memory r)
    {
        Leg[] memory legs = new Leg[](ps.length);
        uint256 total;
        for (uint256 i; i < ps.length; ++i) {
            legs[i] = Leg({
                pool: address(ps[i]), hooks: address(0), kind: BPC.KIND_V2, fee: FEE, tickSpacing: 0,
                zeroForOne: ps[i].token0() == address(ta), stable: false, amountIn: amt,
                expectedOut: att[i], auxId: bytes32(0)
            });
            total += att[i];
        }
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({tokenIn: address(ta), tokenOut: address(tb), amountIn: amt * ps.length, expectedOut: total, legs: legs});
        r = Route({
            hops: hops, totalOut: total, singleOut: total, singleOutFloor: 0,
            expectedImpactBps: 0, confidenceWad: 0, estGas: 0, hasSurplus: false, isV4Bundle: false
        });
    }

    /// Hop 0 leg attests 0 and pays exactly its coverage floor: settles; one wei less: RouterE(5).
    function _coverageBoundary(uint256 amt) private {
        (MockPayingPair liar, MockERC20 tc, MockV2Pair honest) = _twoHopPools();
        liar.setReserves(R, R);
        uint256 g = BPC.outV2(amt, uint256(R), uint256(R), BPC.effV2Fee(FEE));
        // Independent oracle: plain integer arithmetic, 50% coverage then the ceil of 80%.
        uint256 covered = (g * 5_000) / 10_000;
        uint256 floorOut = (covered * 8_000 + 9_999) / 10_000;
        assertGt(floorOut, 1, "fixture: the floor is above one wei");
        assertLt(floorOut, g, "fixture: the floor is below what an honest pool pays");

        uint256 snap = vm.snapshotState();
        liar.setPay(floorOut);
        _swap(_twoHop(liar, honest, tc, amt, g), amt);
        vm.revertToState(snap);

        liar.setPay(floorOut - 1);
        Route memory r = _twoHop(liar, honest, tc, amt, g);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, uint16(5)));
        router.swapExactIn(r, amt, 1, user, block.timestamp + 1);
    }

    /// ta -> tb (bridge) on the lying pair, tb -> tc on an honest one.
    function _twoHopPools() private returns (MockPayingPair liar, MockERC20 tc, MockV2Pair honest) {
        tc = new MockERC20("C", "C");
        liar = new MockPayingPair(address(ta), address(tb));
        ta.mint(address(liar), R);
        tb.mint(address(liar), R);
        hub.seedPool(address(liar), BPC.KIND_V2, FEE, address(0), address(ta), address(tb));
        honest = new MockV2Pair(address(tb), address(tc));
        tb.mint(address(honest), R);
        tc.mint(address(honest), R);
        honest.setReserves(R, R);
        hub.seedPool(address(honest), BPC.KIND_V2, FEE, address(0), address(tb), address(tc));
    }

    function _twoHop(MockPayingPair liar, MockV2Pair honest, MockERC20 tc, uint256 amt, uint256 mid)
        private view returns (Route memory r)
    {
        Leg[] memory l0 = new Leg[](1);
        l0[0] = Leg({
            pool: address(liar), hooks: address(0), kind: BPC.KIND_V2, fee: FEE, tickSpacing: 0,
            zeroForOne: liar.token0() == address(ta), stable: false, amountIn: amt,
            expectedOut: 0, auxId: bytes32(0)
        });
        Leg[] memory l1 = new Leg[](1);
        l1[0] = Leg({
            pool: address(honest), hooks: address(0), kind: BPC.KIND_V2, fee: FEE, tickSpacing: 0,
            zeroForOne: honest.token0() == address(tb), stable: false, amountIn: mid,
            expectedOut: 0, auxId: bytes32(0)
        });
        Hop[] memory hops = new Hop[](2);
        hops[0] = Hop({tokenIn: address(ta), tokenOut: address(tb), amountIn: amt, expectedOut: 0, legs: l0});
        hops[1] = Hop({tokenIn: address(tb), tokenOut: address(tc), amountIn: mid, expectedOut: 0, legs: l1});
        r = Route({
            hops: hops, totalOut: 0, singleOut: 0, singleOutFloor: 0,
            expectedImpactBps: 0, confidenceWad: 0, estGas: 0, hasSurplus: false, isV4Bundle: false
        });
    }

    function _swap(Route memory r, uint256 amountIn) private {
        vm.prank(user);
        uint256 out = router.swapExactIn(r, amountIn, 1, user, block.timestamp + 1);
        assertGt(out, 0, "the route at the boundary must settle");
    }
}
