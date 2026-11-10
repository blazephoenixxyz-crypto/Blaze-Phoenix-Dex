// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// THE CLOCK ANCHOR AND THE PUBLISHED VOLUME OUT ARE DECIDED BY WHAT THE LEG DELIVERED.
//
// RED at af37bd6 (fin1111-rebase, which already carries the family-A dust seal d7152b9):
// `Router._recordHits` handed the registry `mulDiv(leg.expectedOut, hopScale, 1e18)` as the
// leg's output. `leg.expectedOut` is calldata. The per-leg floor accepts a fill down to 80% of
// that figure, so a fill just under the materiality bar, attested up to 25% above itself,
// reached `Core.tickDepth18` as a material trade and anchored the pool's clock (swap count,
// tau, last update): the dust seal asks "was this trade material?" and the Router answered
// with the plan. Reported as 3958 (Thomas van Oorschot) and 4028(b) (Sunfyre Kali).
//
// THE QUESTION HAS ONE PRODUCER: the Router's own measured balance delta for the leg, the
// `got` that `_execScaled` already reads and bounds by what the venue declares it paid
// (DEX-11). These tests pin that the registry receives THAT number, in both directions: an
// over-attested dust fill anchors nothing, and an under-attested material fill anchors.
//
// THE ORACLE IS NOT THE CODE UNDER TEST. Every expectation is rebuilt from token balances
// read before and after the swap: the bar is the pair's short side after the swap, shifted by
// MATERIAL_SHIFT, and the delivery is the pair's balance delta (less the token's own transfer
// tax where the output token has one). `Core.tickDepth18` is never asked.
//
// NOT VACUOUS: each refusal case asserts that the declared figure, scaled the way the old
// line scaled it, DOES clear the bar, so the case separates plan from measurement; each
// `Volume` log is asserted found; each delivery is asserted non-zero.
//
// DIMENSIONS COVERED: attestation above and below the delivery; the boundary to one wei of
// input; fee-on-transfer input; fee-on-transfer output; two legs in one hop (each leg its
// own delivery); two hops (the second hop's leg index); a fuzz over size x attestation.
// NOT COVERED HERE: a concentrated-pool leg and tokens with decimals other than 18 (the
// change is kind-agnostic and the decimal normalisation lives in Core, pinned elsewhere).

import {Test, Vm} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";

contract ClockAnchorMeasuredDeliveryTest is Test {
    uint256 internal constant START_TS = 1_000_000;
    uint256 internal constant GAP = 1 hours;
    uint256 internal constant R_IN = 10_000_000e18;
    uint256 internal constant R_OUT = 1_000_000e18;
    uint24 internal constant POOL_FEE = 30;
    bytes32 internal constant VOLUME_SIG = keccak256("Volume(bytes32,uint256,uint256)");

    BlazePhoenixHub internal hub;
    BlazePhoenixRouter internal router;
    MockERC20 internal tA;
    MockERC20 internal tB;
    MockERC20 internal tC;
    MockV2Pair internal pair;
    bytes32 internal key;
    address internal user = address(0xBEEF);

    /// What one leg did, read from balances and from the registry row.
    struct Fill {
        uint256 slotBefore;
        uint256 slotAfter;
        uint256 poolIn;    // tokenIn the pair gained
        uint256 poolOut;   // tokenOut the pair lost
        uint256 shortSide; // the pair's short side after the swap
        uint256 volOut;    // Volume.amtOut published under the row's key
        bool volFound;
    }

    function setUp() public {
        tA = new MockERC20("A", "A");
        tB = new MockERC20("B", "B");
        tC = new MockERC20("C", "C");

        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        BlazePhoenixSolver solver = new BlazePhoenixSolver(address(hub), address(0));
        router = new BlazePhoenixRouter(
            address(hub), address(solver), address(this), address(0xFEE1), address(0xFEE2)
        );
        hub.setRoles(address(router), address(solver), address(this));

        vm.warp(START_TS);
        (pair, key) = _mkPair(tA, tB, R_IN, R_OUT);

        vm.prank(user);
        tA.approve(address(router), type(uint256).max);
    }

    // ───────────────────────── fixture ─────────────────────────

    function _mkPair(MockERC20 tin, MockERC20 tout, uint256 rIn, uint256 rOut)
        internal returns (MockV2Pair p, bytes32 k)
    {
        p = new MockV2Pair(address(tin), address(tout));
        if (p.token0() == address(tin)) p.setReserves(uint112(rIn), uint112(rOut));
        else p.setReserves(uint112(rOut), uint112(rIn));
        tin.mint(address(p), rIn);
        tout.mint(address(p), rOut);
        k = hub.seedPool(address(p), BPC.KIND_V2, POOL_FEE, address(0), address(tin), address(tout));
    }

    function _leg(MockV2Pair p, address tin, uint256 amtIn, uint256 exp) internal view returns (Leg memory) {
        return Leg({
            pool: address(p), hooks: address(0), kind: BPC.KIND_V2, fee: POOL_FEE,
            tickSpacing: 0, zeroForOne: p.token0() == tin, stable: false,
            amountIn: amtIn, expectedOut: exp, auxId: bytes32(0)
        });
    }

    function _hop(address tin, address tout, uint256 amtIn, uint256 exp, Leg[] memory legs)
        internal pure returns (Hop memory)
    {
        return Hop({tokenIn: tin, tokenOut: tout, amountIn: amtIn, expectedOut: exp, legs: legs});
    }

    function _route(Hop[] memory hops, uint256 out) internal pure returns (Route memory) {
        return Route({
            hops: hops, totalOut: out, singleOut: out, singleOutFloor: 0,
            expectedImpactBps: 0, confidenceWad: 0, estGas: 0,
            hasSurplus: false, isV4Bundle: false
        });
    }

    /// One hop, one leg on `pair`, attesting `exp` for `ask`.
    function _single(uint256 ask, uint256 exp) internal view returns (Route memory) {
        Leg[] memory legs = new Leg[](1);
        legs[0] = _leg(pair, address(tA), ask, exp);
        Hop[] memory hops = new Hop[](1);
        hops[0] = _hop(address(tA), address(tB), ask, exp, legs);
        return _route(hops, exp);
    }

    /// The V2 curve written out, so the premise is not the Core's helper.
    function _outV2(uint256 amtIn, uint256 rIn, uint256 rOut) internal pure returns (uint256) {
        uint256 inAfterFee = amtIn * (10_000 - POOL_FEE);
        return (inAfterFee * rOut) / (rIn * 10_000 + inAfterFee);
    }

    /// What the Router is left with after the protocol fee on the input.
    function _funded(uint256 ask) internal pure returns (uint256) {
        return ask - (ask * BPC.PROTOCOL_FEE_BPS + BPC.BPS - 1) / BPC.BPS;
    }

    function _volOut(Vm.Log[] memory logs, bytes32 k) internal view returns (bool found, uint256 amtOut) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(hub) && logs[i].topics.length == 2
                && logs[i].topics[0] == VOLUME_SIG && logs[i].topics[1] == k) {
                (, amtOut) = abi.decode(logs[i].data, (uint256, uint256));
                return (true, amtOut);
            }
        }
    }

    function _snapBefore(MockV2Pair p, bytes32 k, MockERC20 tin, MockERC20 tout)
        internal view returns (Fill memory f)
    {
        f.slotBefore = hub.getSlot(k);
        f.poolIn = tin.balanceOf(address(p));
        f.poolOut = tout.balanceOf(address(p));
    }

    function _snapAfter(Fill memory f, MockV2Pair p, bytes32 k, MockERC20 tin, MockERC20 tout,
                        Vm.Log[] memory logs) internal view
    {
        f.slotAfter = hub.getSlot(k);
        uint256 inNow = tin.balanceOf(address(p));
        uint256 outNow = tout.balanceOf(address(p));
        f.poolIn = inNow - f.poolIn;
        f.poolOut = f.poolOut - outNow;
        f.shortSide = inNow < outNow ? inNow : outNow;
        (f.volFound, f.volOut) = _volOut(logs, k);
    }

    /// Swap `ask` of A through `r` as the user, one hour after the last stamp.
    function _swap(Route memory r, uint256 ask) internal returns (Vm.Log[] memory logs) {
        tA.mint(user, ask);
        vm.warp(block.timestamp + GAP);
        vm.recordLogs();
        vm.prank(user);
        router.swapExactIn(r, ask, 1, user, block.timestamp + 1);
        logs = vm.getRecordedLogs();
    }

    function _swapSingle(uint256 ask, uint256 exp) internal returns (Fill memory f) {
        f = _snapBefore(pair, key, tA, tB);
        Vm.Log[] memory logs = _swap(_single(ask, exp), ask);
        _snapAfter(f, pair, key, tA, tB, logs);
    }

    /// The materiality bar rebuilt from balances: the pair's short side after the swap,
    /// shifted. Both tokens carry 18 decimals, so no normalisation enters.
    function _bar(Fill memory f) internal pure returns (uint256) {
        return f.shortSide >> BPC.MATERIAL_SHIFT;
    }

    function _assertAnchored(Fill memory f, string memory id) internal {
        assertEq(BPC.decodeLastUpdateTs(f.slotAfter), uint32(block.timestamp),
            string.concat(id, ": a material delivery must stamp the clock"));
        assertEq(BPC.decodeSwapCount(f.slotAfter), BPC.decodeSwapCount(f.slotBefore) + 1,
            string.concat(id, ": a material delivery must count once"));
    }

    function _assertNotAnchored(Fill memory f, string memory id) internal {
        assertEq(BPC.decodeLastUpdateTs(f.slotAfter), BPC.decodeLastUpdateTs(f.slotBefore),
            string.concat(id, ": a dust delivery moved the last update"));
        assertEq(BPC.decodeSwapCount(f.slotAfter), BPC.decodeSwapCount(f.slotBefore),
            string.concat(id, ": a dust delivery moved the swap count"));
        assertEq(BPC.decodeTau(f.slotAfter), BPC.decodeTau(f.slotBefore),
            string.concat(id, ": a dust delivery moved tau"));
    }

    /// Smallest `ask` whose honest fill on `pair` meets the bar, by bisection on the curve.
    function _smallestMaterialAsk() internal pure returns (uint256 lo) {
        lo = 1e18;
        uint256 hi = 1_000e18;
        while (lo < hi) {
            uint256 mid = (lo + hi) / 2;
            uint256 fin = _funded(mid);
            uint256 out = _outV2(fin, R_IN, R_OUT);
            uint256 a = R_IN + fin;
            uint256 b = R_OUT - out;
            if (out >= (a < b ? a : b) >> BPC.MATERIAL_SHIFT) hi = mid;
            else lo = mid + 1;
        }
    }

    // ───────────────────────── 3958 / 4028(b): the plan cannot anchor ─────────────────────────

    /// A fill below the bar, attested 24% above itself (inside the 80% leg floor), anchors
    /// nothing: the clock reads the delivery.
    function test_ClockAnchor_OverAttestedDustFillLeavesTheClock() public {
        uint256 ask = 150e18;
        uint256 exp = _outV2(ask, R_IN, R_OUT) * 124 / 100;
        Fill memory f = _swapSingle(ask, exp);

        assertGt(f.poolOut, 0, "precondition: the pair paid");
        assertLt(f.poolOut, _bar(f), "precondition: the delivery is below the bar");
        assertGe(exp * f.poolIn / ask, _bar(f), "precondition: the scaled declaration clears the bar");
        _assertNotAnchored(f, "3958");
    }

    /// Measurement wins in the other direction too: a material fill attested at 60% of
    /// itself anchors, although its declaration is below the bar.
    function test_ClockAnchor_UnderAttestedMaterialFillAnchors() public {
        uint256 ask = 185e18;
        uint256 exp = _outV2(ask, R_IN, R_OUT) * 60 / 100;
        Fill memory f = _swapSingle(ask, exp);

        assertGe(f.poolOut, _bar(f), "precondition: the delivery meets the bar");
        assertLt(exp * f.poolIn / ask, _bar(f), "precondition: the scaled declaration is below the bar");
        _assertAnchored(f, "under-attested");
    }

    /// The boundary is the delivery's, to one wei of input: the smallest ask that meets the
    /// bar anchors while attesting 15% BELOW its fill, and one wei less does not anchor
    /// while attesting 20% ABOVE its fill.
    function test_ClockAnchor_BoundaryIsTheDeliveryNotTheDeclaration() public {
        uint256 ask = _smallestMaterialAsk();
        uint256 snap = vm.snapshotState();

        Fill memory below = _swapSingle(ask - 1, _outV2(ask - 1, R_IN, R_OUT) * 120 / 100);
        assertLt(below.poolOut, _bar(below), "precondition: one wei less is below the bar");
        assertGe(_outV2(ask - 1, R_IN, R_OUT) * 120 / 100 * below.poolIn / (ask - 1), _bar(below),
            "precondition: its scaled declaration clears the bar");
        _assertNotAnchored(below, "boundary - 1");

        vm.revertToState(snap);
        Fill memory at = _swapSingle(ask, _outV2(ask, R_IN, R_OUT) * 85 / 100);
        assertGe(at.poolOut, _bar(at), "precondition: the smallest material ask meets the bar");
        assertLt(_outV2(ask, R_IN, R_OUT) * 85 / 100 * at.poolIn / ask, _bar(at),
            "precondition: its scaled declaration is below the bar");
        _assertAnchored(at, "boundary");
    }

    /// Fee-on-transfer INPUT: the pair receives 1% of what the Router pushed and pays dust,
    /// while the plan priced the untaxed amount. The clock reads the dust.
    function test_ClockAnchor_FotInputDustFillLeavesTheClock() public {
        uint256 ask = 150_000e18;
        uint256 exp = _outV2(_funded(ask), R_IN, R_OUT);
        tA.setFeeOnTransferBps(9_900);
        Fill memory f = _swapSingle(ask, exp);

        assertGt(f.poolOut, 0, "precondition: the pair paid");
        assertLt(f.poolOut, _bar(f), "precondition: the delivery is below the bar");
        // The old line scaled the declaration by what the Router held (1% of the ask), not by
        // what the pair received (1% of that again).
        assertGe(exp / 100 * 99 / 100, _bar(f), "precondition: the scaled declaration clears the bar");
        _assertNotAnchored(f, "3958 FoT input");
    }

    /// Fee-on-transfer OUTPUT: the pair pays a material gross amount and the Router receives
    /// 1% less, below the bar. The recorded output is what arrived, and it does not anchor.
    function test_ClockAnchor_FotOutputReadsWhatTheRouterReceived() public {
        uint256 ask = _smallestMaterialAsk();
        tB.setFeeOnTransferBps(100);
        Fill memory f = _swapSingle(ask, _outV2(ask, R_IN, R_OUT));

        uint256 received = f.poolOut - f.poolOut * 100 / 10_000;
        assertGe(f.poolOut, _bar(f), "precondition: the gross payment meets the bar");
        assertLt(received, _bar(f), "precondition: what arrived is below the bar");
        assertTrue(f.volFound, "precondition: a Volume event under the row's key");
        assertEq(f.volOut, received, "Volume.amtOut is not what the Router received");
        _assertNotAnchored(f, "FoT output");
    }

    // ───────────────────────── Volume.amtOut ─────────────────────────

    /// `Volume.amtOut` is the pair's measured output delta, to the wei, whatever was attested.
    function test_VolumeOut_EqualsTheMeasuredDeliveryUnderAnOverAttestation() public {
        uint256 ask = 150e18;
        Fill memory f = _swapSingle(ask, _outV2(ask, R_IN, R_OUT) * 124 / 100);
        assertGt(f.poolOut, 0, "precondition: the pair paid");
        assertTrue(f.volFound, "precondition: a Volume event under the row's key");
        assertEq(f.volOut, f.poolOut, "Volume.amtOut is not the measured delivery");
    }

    // ───────────────────────── each leg its own delivery ─────────────────────────

    /// Two legs in one hop on two pairs of the same depth: the first fills materially and
    /// honestly, the second fills dust attested 24% above itself. Each row gets ITS leg's
    /// delivery: the first anchors, the second does not.
    function test_ClockAnchor_TwoLegsEachRowReadsItsOwnDelivery() public {
        (MockV2Pair pairB, bytes32 keyB) = _mkPair(tA, tB, R_IN, R_OUT);
        uint256 a1 = 400e18;
        uint256 a2 = 150e18;
        uint256 e1 = _outV2(a1, R_IN, R_OUT);
        uint256 e2 = _outV2(a2, R_IN, R_OUT) * 124 / 100;

        Leg[] memory legs = new Leg[](2);
        legs[0] = _leg(pair, address(tA), a1, e1);
        legs[1] = _leg(pairB, address(tA), a2, e2);
        Hop[] memory hops = new Hop[](1);
        hops[0] = _hop(address(tA), address(tB), a1 + a2, e1 + e2, legs);

        Fill memory f1 = _snapBefore(pair, key, tA, tB);
        Fill memory f2 = _snapBefore(pairB, keyB, tA, tB);
        Vm.Log[] memory logs = _swap(_route(hops, e1 + e2), a1 + a2);
        _snapAfter(f1, pair, key, tA, tB, logs);
        _snapAfter(f2, pairB, keyB, tA, tB, logs);

        assertGe(f1.poolOut, _bar(f1), "precondition: leg 0 delivers above its bar");
        assertGt(f2.poolOut, 0, "precondition: leg 1 delivers");
        assertLt(f2.poolOut, _bar(f2), "precondition: leg 1 delivers below its bar");
        assertGe(e2 * f2.poolIn / a2, _bar(f2), "precondition: leg 1's scaled declaration clears the bar");

        _assertAnchored(f1, "leg 0");
        _assertNotAnchored(f2, "leg 1");
        assertTrue(f1.volFound && f2.volFound, "precondition: one Volume event per row");
        assertEq(f1.volOut, f1.poolOut, "leg 0: Volume.amtOut is not its own delivery");
        assertEq(f2.volOut, f2.poolOut, "leg 1: Volume.amtOut is not its own delivery");
    }

    /// Two hops, A -> B -> C. The first hop fills materially and honestly; the second pair is
    /// sized so the bridge amount fills it just below ITS bar, attested 24% above the fill.
    /// The second hop's row reads the second hop's delivery.
    function test_ClockAnchor_TwoHopsTheSecondRowReadsItsOwnDelivery() public {
        uint256 ask = 185e18;
        uint256 mid = _outV2(_funded(ask), R_IN, R_OUT);
        // Second pair: short side C = 0.95 x mid x 2^16 (so the bridge amount itself is
        // above the bar), B side sized so the fill lands near 85% of the bar.
        uint256 rC = mid * 95 / 100 << BPC.MATERIAL_SHIFT;
        uint256 rB = mid * 117 / 100 << BPC.MATERIAL_SHIFT;
        (MockV2Pair pBC, bytes32 keyBC) = _mkPair(tB, tC, rB, rC);
        uint256 e0 = _outV2(ask, R_IN, R_OUT);
        uint256 e1 = _outV2(mid, rB, rC) * 124 / 100;

        Leg[] memory l0 = new Leg[](1);
        l0[0] = _leg(pair, address(tA), ask, e0);
        Leg[] memory l1 = new Leg[](1);
        l1[0] = _leg(pBC, address(tB), mid, e1);
        Hop[] memory hops = new Hop[](2);
        hops[0] = _hop(address(tA), address(tB), ask, e0, l0);
        hops[1] = _hop(address(tB), address(tC), mid, e1, l1);

        Fill memory f0 = _snapBefore(pair, key, tA, tB);
        Fill memory f1 = _snapBefore(pBC, keyBC, tB, tC);
        Vm.Log[] memory logs = _swap(_route(hops, e1), ask);
        _snapAfter(f0, pair, key, tA, tB, logs);
        _snapAfter(f1, pBC, keyBC, tB, tC, logs);

        assertGe(f0.poolOut, _bar(f0), "precondition: hop 0 delivers above its bar");
        assertGt(f1.poolOut, 0, "precondition: hop 1 delivers");
        assertLt(f1.poolOut, _bar(f1), "precondition: hop 1 delivers below its bar");
        assertGe(f1.poolIn, _bar(f1), "precondition: hop 1's input is above its bar");
        assertGe(e1 * f1.poolIn / mid, _bar(f1), "precondition: hop 1's scaled declaration clears the bar");

        _assertAnchored(f0, "hop 0");
        _assertNotAnchored(f1, "hop 1");
        assertTrue(f0.volFound && f1.volFound, "precondition: one Volume event per row");
        assertEq(f0.volOut, f0.poolOut, "hop 0: Volume.amtOut is not its own delivery");
        assertEq(f1.volOut, f1.poolOut, "hop 1: Volume.amtOut is not its own delivery");
    }

    // ───────────────────────── range ─────────────────────────

    /// Over the range of sizes around the bar and of attestations the leg floor accepts, the
    /// clock anchors exactly when the measured delivery meets the bar rebuilt from balances,
    /// and the published output is the measured delivery.
    function testFuzz_ClockAnchor_FollowsTheMeasuredDelivery(uint256 ask, uint256 attBps) public {
        ask = bound(ask, 20e18, 600e18);
        attBps = bound(attBps, 6_000, 12_400);
        Fill memory f = _swapSingle(ask, _outV2(ask, R_IN, R_OUT) * attBps / 10_000);

        assertGt(f.poolOut, 0, "precondition: the pair paid");
        assertTrue(f.volFound, "precondition: a Volume event under the row's key");
        assertEq(f.volOut, f.poolOut, "Volume.amtOut is not the measured delivery");
        // The input side is ten times the output on this pair, so the output decides.
        assertGt(f.poolIn, 5 * f.poolOut, "precondition: the input side does not bind");
        if (f.poolOut >= _bar(f)) _assertAnchored(f, "fuzz material");
        else _assertNotAnchored(f, "fuzz dust");
    }
}
