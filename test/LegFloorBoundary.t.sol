// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  LEG_FLOOR_BPS - the per-leg floor, isolated from the hop guard.
//
//    per leg (Router, `_execScaled`):  got < mulDivUp(bound, LEG_FLOOR_BPS, BPS) -> RouterE(5)
//    per hop (Router, Layer 1):        hopGot + mulDiv(hopAttested / hopQuoted, BPS - LEG_FLOOR_BPS, BPS) < hopAttested
//
//  For ONE hop of ONE leg the two are mathematically the same condition
//  (ceil(0.8b) == b - floor(0.2b)), so a `mulDivUp -> mulDiv` mutant on the leg guard is
//  INVISIBLE there: the hop guard covers it. Only a hop of two or more legs, with an
//  inflated leg compensated by another, tells them apart - which is what this file
//  measures:
//   1. the constant's value (8,000) and direction;
//   2. the 1-wei boundary on a one-leg hop (ceil);
//   3. ISOLATION: a two-leg hop whose thin leg attests floor(1.25 * got) + 1 trips the
//      leg guard and not the hop guard -> RouterE(5). Under the mutant it would settle.
//
//  The fee is taken on the OUTPUT (the destination is a bridge coin), so the leg gets
//  the whole input and `got` is the full outV2 - no input fee shifts the bound.
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";

contract LegFloorBoundaryTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    BlazePhoenixRouter router;
    MockERC20 ta;
    MockERC20 tb;
    MockV2Pair poolA;
    MockV2Pair poolB;

    address user = address(0xBEEF);
    uint112 constant R = uint112(1_000_000e18);
    uint24 constant FEE = 30;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        solver = new BlazePhoenixSolver(address(hub));
        router = new BlazePhoenixRouter(address(hub), address(solver), address(this), address(0xFEE1), address(0xFEE2));
        hub.setRoles(address(router), address(solver), address(this));

        ta = new MockERC20("A", "A");
        tb = new MockERC20("B", "B");
        poolA = _pool();
        poolB = _pool();
        // Fee on the OUTPUT: the destination is a bridge coin, so the leg receives the WHOLE
        // input and the guard's `got` is the full outV2. The fee is cut after the floor.
        hub.addBridge(address(tb));

        ta.mint(user, 1_000_000e18);
        vm.prank(user);
        ta.approve(address(router), type(uint256).max);
    }

    function _pool() private returns (MockV2Pair p) {
        p = new MockV2Pair(address(ta), address(tb));
        ta.mint(address(p), R);
        tb.mint(address(p), R);
        p.setReserves(R, R);
        hub.seedPool(address(p), BPC.KIND_V2, FEE, address(0), address(ta), address(tb));
    }

    // ── 1. A constante ──────────────────────────────────────────────────────

    function test_Constant_LegFloorIsEightyPercent() public pure {
        assertEq(BPC.LEG_FLOOR_BPS, 8_000, "LEG_FLOOR_BPS is no longer 80%");
    }

    // ── 2. The 1-wei boundary, one-leg hop ──────────────────────────────────

    function test_Floor_AtTheEightyPercentBoundary_Passes() public {
        uint256 got = BPC.outV2(1_000e18, uint256(R), uint256(R), BPC.effV2Fee(FEE));
        uint256 bound = (got * 10) / 8;   // floor(1.25·got): limiar == got
        Route memory r = _oneLeg(poolA, 1_000e18, bound, got);
        vm.prank(user);
        uint256 out = router.swapExactIn(r, 1_000e18, 1, user, block.timestamp + 1);
        assertGt(out, 0, "at the 80% boundary the leg must settle");
    }

    function test_Floor_OneWeiBelowTheEightyPercentBoundary_Reverts() public {
        uint256 got = BPC.outV2(1_000e18, uint256(R), uint256(R), BPC.effV2Fee(FEE));
        uint256 bound = (got * 10) / 8 + 1;   // ceil(80%·bound) == got+1
        Route memory r = _oneLeg(poolA, 1_000e18, bound, got);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, 5));
        router.swapExactIn(r, 1_000e18, 1, user, block.timestamp + 1);
    }

    function test_Floor_LegPayingMoreThanItsBoundNeverReverts() public {
        uint256 got = BPC.outV2(1_000e18, uint256(R), uint256(R), BPC.effV2Fee(FEE));
        uint256 bound = got / 2;
        Route memory r = _oneLeg(poolA, 1_000e18, bound, got);
        vm.prank(user);
        uint256 out = router.swapExactIn(r, 1_000e18, 1, user, block.timestamp + 1);
        assertGt(out, 0, "a leg that beats its promise cannot be refused");
    }

    // ── 3. ISOLATING the leg guard in a two-leg hop ─────────────────────────

    /// Control (non-vacuity): with the thin bound at floor(1.25 * got) the two-leg hop
    /// settles - the boundary exists and the fixture is valid.
    function test_MultiLeg_AtTheBoundary_Passes() public {
        (uint256 a, uint256 b) = (100e18, 1_000e18);
        uint256 gotA = BPC.outV2(a, uint256(R), uint256(R), BPC.effV2Fee(FEE));
        uint256 gotB = BPC.outV2(b, uint256(R), uint256(R), BPC.effV2Fee(FEE));
        Route memory r = _twoLeg(a, b, (gotA * 10) / 8, gotB);
        vm.prank(user);
        uint256 out = router.swapExactIn(r, a + b, 1, user, block.timestamp + 1);
        assertGt(out, 0, "the two-leg hop at the boundary must settle");
    }

    /// The thin leg attests floor(1.25 * gotA) + 1: the PER-LEG guard (mulDivUp) trips;
    /// the HOP guard does not, because the deep leg compensates the aggregate. Under the
    /// `mulDivUp -> mulDiv` mutant the leg passes and the swap does not revert, so this
    /// `expectRevert` goes red.
    function test_MultiLeg_PerLegGuardRoundsUp_IsolatesFromHopGuard() public {
        (uint256 a, uint256 b) = (100e18, 1_000e18);
        uint256 gotA = BPC.outV2(a, uint256(R), uint256(R), BPC.effV2Fee(FEE));
        uint256 gotB = BPC.outV2(b, uint256(R), uint256(R), BPC.effV2Fee(FEE));
        Route memory r = _twoLeg(a, b, (gotA * 10) / 8 + 1, gotB);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, 5));
        router.swapExactIn(r, a + b, 1, user, block.timestamp + 1);
    }

    // ── auxiliares ──────────────────────────────────────────────────────────

    function _leg(MockV2Pair p, uint256 amt, uint256 bound) private view returns (Leg memory) {
        bool zfo = p.token0() == address(ta);
        return Leg({
            pool: address(p), hooks: address(0), kind: BPC.KIND_V2, fee: FEE, tickSpacing: 0,
            zeroForOne: zfo, stable: false, amountIn: amt, expectedOut: bound, auxId: bytes32(0)
        });
    }

    function _oneLeg(MockV2Pair p, uint256 amt, uint256 legBound, uint256 hopOut)
        private view returns (Route memory r)
    {
        Leg[] memory legs = new Leg[](1);
        legs[0] = _leg(p, amt, legBound);
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({tokenIn: address(ta), tokenOut: address(tb), amountIn: amt, expectedOut: hopOut, legs: legs});
        r = _route(hops, hopOut);
    }

    function _twoLeg(uint256 a, uint256 b, uint256 boundA, uint256 boundB)
        private view returns (Route memory r)
    {
        Leg[] memory legs = new Leg[](2);
        legs[0] = _leg(poolA, a, boundA);
        legs[1] = _leg(poolB, b, boundB);
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({
            tokenIn: address(ta), tokenOut: address(tb), amountIn: a + b,
            expectedOut: boundA + boundB, legs: legs
        });
        r = _route(hops, boundA + boundB);
    }

    function _route(Hop[] memory hops, uint256 total) private pure returns (Route memory r) {
        r = Route({
            hops: hops, totalOut: total, singleOut: total, singleOutFloor: 0,
            expectedImpactBps: 0, confidenceWad: 0, estGas: 0, hasSurplus: false, isV4Bundle: false
        });
    }
}
