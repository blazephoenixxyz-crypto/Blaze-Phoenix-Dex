// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  THE PER-LEG FLOOR IS MONOTONE IN THE ATTESTATION.
//
//  _execScaled's coverage gate lifted a leg's bound to the in-frame quote qs
//  only when the attestation was below MIN_QUOTE_COVERAGE_BPS of it, so the
//  bound was g(a) = qs for a < qs/2 and a otherwise: a step. Attesting just
//  under half the measurement was held to 80% of qs; attesting just over half,
//  to 80% of the attestation, ~40% of qs (mohaseenbasha, bug bounty). Red at
//  f909422. The bound is now max(a, qs/2): attesting more never lowers the
//  floor, and the lowest floor a caller can reach is the one attesting at the
//  threshold already reached.
//
//  Quantity: the leg's floor bound in _execScaled, observed as settle/refuse.
//  Oracle: the pool's own swap arithmetic; never the Router's gate code.
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV3Pool} from "./mocks/MockV3Pool.sol";

contract LegFloorMonotoneInAttestationTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixRouter router;
    MockERC20 tA;
    MockERC20 tB;
    MockERC20 tC;
    MockV3Pool pAB; // honest liquidity(), thin swap liquidity: delivers ~45% of its quote
    MockV3Pool pBC;
    address user = address(0xBEEF);
    uint160 constant Q96 = uint160(uint256(1) << 96);
    uint128 constant LIQ = uint128(1e27);
    uint256 constant AMT = 1_000e18;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        tA = new MockERC20("A", "A");
        tB = new MockERC20("B", "B");
        tC = new MockERC20("C", "C");
        router = new BlazePhoenixRouter(address(hub), address(0xD0D0), address(this), address(0xFEE1), address(0xFEE2));
        pAB = new MockV3Pool(address(tA), address(tB), 3000);
        pAB.setState(Q96, LIQ);
        pAB.setSwapLiquidity(uint128(818e18));
        pBC = new MockV3Pool(address(tB), address(tC), 3000);
        pBC.setState(Q96, LIQ);
        tB.mint(address(pAB), 1_000_000e18);
        tC.mint(address(pBC), 1_000_000e18);
        tA.mint(user, 10 * AMT);
        vm.prank(user);
        tA.approve(address(router), type(uint256).max);
    }

    function _leg(MockV3Pool p, address tIn, uint256 amt, uint256 exp) private view returns (Leg memory) {
        return Leg({pool: address(p), hooks: address(0), kind: BPC.KIND_V3, fee: 3000, tickSpacing: 0,
            zeroForOne: p.token0() == tIn, stable: false, amountIn: amt, expectedOut: exp, auxId: bytes32(0)});
    }

    function _route(uint256 shareBps) private view returns (Route memory r) {
        uint256 q0 = BPC.outV3(AMT, Q96, LIQ, 3000, pAB.token0() == address(tA), 0);
        uint256 att = BPC.mulDiv(q0, shareBps, BPC.BPS);
        Leg[] memory l0 = new Leg[](1);
        l0[0] = _leg(pAB, address(tA), AMT, att);
        Leg[] memory l1 = new Leg[](1);
        l1[0] = _leg(pBC, address(tB), att, 0);
        Hop[] memory hs = new Hop[](2);
        hs[0] = Hop({tokenIn: address(tA), tokenOut: address(tB), amountIn: AMT, expectedOut: att, legs: l0});
        hs[1] = Hop({tokenIn: address(tB), tokenOut: address(tC), amountIn: att, expectedOut: 0, legs: l1});
        r = Route({hops: hs, totalOut: 0, singleOut: 0, singleOutFloor: 0, expectedImpactBps: 0,
            confidenceWad: 0, estGas: 0, hasSurplus: false, isV4Bundle: false});
    }

    function _settles(uint256 shareBps) private returns (bool ok) {
        uint256 snap = vm.snapshotState();
        Route memory r = _route(shareBps);
        vm.prank(user);
        try router.swapExactIn(r, AMT, 1, user, block.timestamp + 1) returns (uint256) { ok = true; } catch {}
        vm.revertToState(snap);
    }

    /// RED at f909422: attesting 52% of the measurement settles, attesting 49% is refused.
    function test_LegFloor_LowerAttestation_NeverRefusedWhereAHigherOneSettles() public {
        bool hi = _settles(5_200);
        bool lo = _settles(4_900);
        assertTrue(!hi || lo, "leg floor: a weaker claim was held to a stricter floor");
    }

    /// Attacker mode: no attestation, however low, buys a delivery under the threshold's
    /// floor. This pool delivers ~29% of its in-frame quote, below 80% of half of it.
    function test_LegFloor_DeliveryUnderTheThreshold_RefusedAtEveryAttestation() public {
        pAB.setSwapLiquidity(uint128(400e18));
        assertFalse(_settles(100), "a 1% attestation must not buy a sub-threshold delivery");
        assertFalse(_settles(5_000), "nor one at the threshold");
        assertFalse(_settles(10_000), "nor the honest one");
    }

    /// The neighbour at or above the threshold keeps its floor: an honest attestation is
    /// still held to 80% of itself, and a pool delivering ~45% of it is refused.
    function test_LegFloor_HonestAttestation_KeepsItsFloor() public {
        assertFalse(_settles(10_000), "an honest attestation is held to its own floor");
        pAB.setSwapLiquidity(LIQ);
        assertTrue(_settles(10_000), "and a pool that delivers its quote settles");
    }

    function testFuzz_LegFloor_MonotoneInAttestation(uint16 a, uint16 b) public {
        uint256 lo = bound(a, 1_000, 10_000);
        uint256 hi = bound(b, lo, 10_000);
        assertTrue(!_settles(hi) || _settles(lo), "leg floor: a weaker claim was held to a stricter floor");
    }
}
