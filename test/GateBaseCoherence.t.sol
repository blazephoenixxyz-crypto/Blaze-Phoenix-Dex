// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  GATE <-> BASE CONTRACTS COHERENCE (coherence audit, 2026-10-23).
//  Red at 1b4f2d4: test_Coherence_A_SameMassSameDepthOnBothDoors,
//  test_Coherence_A_DeeperAnchorHoldsAtAnyPrice and
//  test_Coherence_D_MixedLastHopKeepsTheGateLegUnderTheFloor.
//
//  A. The depth18 of one mass on the two doors. A native reserve pair reads its
//     SHORT side (Core.shortSide18 through registryDepth18 / universalQuote).
//     At 1b4f2d4 a Gate wrapper read the venue's LONG side: the adapters
//     declared ExtAdapterBase._depth18 = maxSide18 and Gate.vitalOf capped the
//     word by heldMass18 = maxSide18. The Solver mixes both in one bucket (psi),
//     one weighted median (band) and one weight vector (split), so at a price
//     ratio far from 1 the wrapper outvoted a native pair holding the same
//     tokens by that ratio. Now both are the short side: the adapters declare
//     it (test/adapters/*_Depth18_IsThePoolsShortSide*) and vitalOf caps any
//     word by the short side of what the venue holds (tested here, with mock
//     adapters, so the cap is watched whatever an adapter declares).
//  D. The protocol floor's base on a mixed last hop. A Gate leg is attested
//     but has no in-frame quote; beside a priced V2 leg the base was the V2
//     leg's quote alone (Router: hopBase = hopQuote when hopQuote != 0), so the
//     Gate leg fell out of the floor it is under when alone. Now every unpriced
//     leg enters the base with its attested figure.
//
//  Oracle: token balances, Core's own producers on the native side, and the
//  same route's Gate leg alone (the control). Cheatcodes: vm.warp (adapter
//  timelock, inside the base helpers), vm.prank (the user).
// =============================================================================

import {BlazePhoenixGateTest} from "./BlazePhoenixGate.t.sol";
import {BlazePhoenixGateWrapper} from "../src/BlazePhoenixGate.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, RoutePlan, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockGateVenue} from "./mocks/MockGateAdapters.sol";

contract GateBaseCoherenceTest is BlazePhoenixGateTest {
    /// A Gate venue holding (b0, b1), priced at b1/b0 by payBps (the mock's rule is linear).
    function _asymVenue(uint256 b0, uint256 b1, uint256 payBps) internal returns (MockGateVenue v) {
        v = new MockGateVenue(address(t0), address(t1));
        reg.add(address(v));
        t0.mint(address(v), b0);
        t1.mint(address(v), b1);
        v.sync();
        v.setPayBps(payBps);
    }

    /// A curated V2 pair holding (r0, r1).
    function _pairAt(uint256 r0, uint256 r1) internal returns (MockV2Pair pair) {
        pair = new MockV2Pair(address(t0), address(t1));
        pair.setReserves(uint112(r0), uint112(r1));
        t0.mint(address(pair), r0);
        t1.mint(address(pair), r1);
        hub.seedPool(address(pair), BPC.KIND_V2, 30, address(0), address(t0), address(t1));
    }

    // ─── A: one mass, one depth on both doors ───

    /// Quantity: depth18 of the same two holdings (1M t0, 1k t1) read as a native V2 pair and
    /// as a Gate wrapper whose adapter declares the LONG side (what ExtAdapterBase._depth18
    /// answered at 1b4f2d4). Expected: the same depth18 - vitalOf caps any word by the short
    /// side of what the venue holds, the native door's own formula.
    /// RED at 1b4f2d4: the wrapper read 1e24 (bucket 9), the pair 1e21 (bucket 6).
    function test_Coherence_A_SameMassSameDepthOnBothDoors() public {
        uint256 b0 = 1_000_000e18;
        uint256 b1 = 1_000e18;
        MockGateVenue v = _asymVenue(b0, b1, 10);
        _accept(FAM, address(adapter));
        BlazePhoenixGateWrapper w =
            BlazePhoenixGateWrapper(gate.create(address(t0), address(t1), KEY, abi.encode(address(v))));
        adapter.setDeclaredDepth(b0);   // the long side, a word above the short side held
        _admit();
        MockV2Pair pair = _pairAt(b0, b1);
        (, uint256 dGate, ) = gate.vitalOf(address(w));
        uint256 dNative = BPC.registryDepth18(address(pair), BPC.KIND_V2, address(t0), address(t1), address(0), bytes32(0));
        assertEq(dNative, b1, "setup: the native door reads the short side");
        assertEq(BPC.depthBucket(dGate), BPC.depthBucket(dNative), "same mass, same depth bucket on both doors");
        assertEq(dGate, dNative, "same mass, same depth18 on both doors");
    }

    /// Quantity: where an overquoting adapter's lie stops when the price is not 1:1. The same
    /// setting as test_GatedAuto_ADeeperCuratedAnchorKeepsTheLieOutOfTheBand (adapter quotes
    /// twice what it trades; curated pair holds THREE times the venue's mass on EACH side),
    /// at a 1000:1 price. Expected: the pair anchors the band, the lie is out, the door settles.
    /// RED at 1b4f2d4: the wrapper voted the long side (1e24) against the pair's short side
    /// (3e21), centred the band on the lie, was planned, and the best door reverted RouterE(5).
    /// Since MED (2026-10-28) the wrapper does not vote while the pair's stated fee does
    /// (BlazePhoenixMath._mutedVotes), so its depth's side no longer reaches the band here; the
    /// side is watched where it is produced (test_Coherence_A_SameMassSameDepthOnBothDoors).
    function test_Coherence_A_DeeperAnchorHoldsAtAnyPrice() public {
        MockGateVenue v = _asymVenue(1_000_000e18, 1_000e18, 10);   // honest price 1000:1
        _accept(HFAM, address(hostile));
        BlazePhoenixGateWrapper w =
            BlazePhoenixGateWrapper(gate.create(address(t0), address(t1), HKEY, abi.encode(address(v))));
        hostile.setMode(hostile.OVERQUOTE());
        hostile.setDeclaredDepth(type(uint128).max);   // capped by the short side held
        (BlazePhoenixSolver solver, BlazePhoenixRouter router) = _autoDoor();
        MockV2Pair pair = _pairAt(3_000_000e18, 3_000e18);
        uint256 amt = 1_000e18;
        RoutePlan memory p = solver.findBestRoutePlan(address(t0), address(t1), amt);
        assertFalse(_plans(p, address(w)), "the lie is out of the band");
        assertTrue(_plans(p, address(pair)), "the pair is planned");
        assertGt(_best(router, amt), 0, "the best door settles");
    }

    /// Control: the same 1000:1 setting with the adapter declaring the SHORT side itself (what
    /// ExtAdapterBase._depth18 answers now). Green at 1b4f2d4 too: the red above is the
    /// depth's side alone, not the harness.
    function test_Coherence_A_Control_ShortSideWordHoldsTheAnchor() public {
        MockGateVenue v = _asymVenue(1_000_000e18, 1_000e18, 10);
        _accept(HFAM, address(hostile));
        BlazePhoenixGateWrapper w =
            BlazePhoenixGateWrapper(gate.create(address(t0), address(t1), HKEY, abi.encode(address(v))));
        hostile.setMode(hostile.OVERQUOTE());
        hostile.setDeclaredDepth(BPC.shortSide18(1_000_000e18, 18, 1_000e18, 18));
        (BlazePhoenixSolver solver, BlazePhoenixRouter router) = _autoDoor();
        MockV2Pair pair = _pairAt(3_000_000e18, 3_000e18);
        uint256 amt = 1_000e18;
        RoutePlan memory p = solver.findBestRoutePlan(address(t0), address(t1), amt);
        assertFalse(_plans(p, address(w)), "the lie is out of the band");
        assertTrue(_plans(p, address(pair)), "the pair is planned");
        assertGt(_best(router, amt), 0, "the best door settles");
    }

    /// Control: the test above at a 1:1 price (long side == short side): green at 1b4f2d4, so
    /// the red is the price ratio, not the harness.
    function test_Coherence_A_Control_DeeperAnchorHoldsAtParity() public {
        MockGateVenue v = _asymVenue(1_000_000e18, 1_000_000e18, 9_970);
        _accept(HFAM, address(hostile));
        BlazePhoenixGateWrapper w =
            BlazePhoenixGateWrapper(gate.create(address(t0), address(t1), HKEY, abi.encode(address(v))));
        hostile.setMode(hostile.OVERQUOTE());
        hostile.setDeclaredDepth(type(uint128).max);
        (BlazePhoenixSolver solver, BlazePhoenixRouter router) = _autoDoor();
        MockV2Pair pair = _pairAt(3_000_000e18, 3_000_000e18);
        uint256 amt = 1_000e18;
        RoutePlan memory p = solver.findBestRoutePlan(address(t0), address(t1), amt);
        assertFalse(_plans(p, address(w)), "the lie is out of the band");
        assertTrue(_plans(p, address(pair)), "the pair is planned");
        assertGt(_best(router, amt), 0, "the best door settles");
    }

    // ─── a Gate leg beside a native leg, and as an intermediate hop ───

    function _v2out(uint256 a, uint256 rIn, uint256 rOut) internal pure returns (uint256) {
        return a * 9_970 * rOut / (rIn * 10_000 + a * 9_970);
    }

    function _leg(address pool, uint8 kind, uint24 fee, bool z, uint256 a, uint256 e)
        internal pure returns (Leg memory)
    {
        return Leg({pool: pool, hooks: address(0), kind: kind, fee: fee, tickSpacing: 0,
            zeroForOne: z, stable: false, amountIn: a, expectedOut: e, auxId: bytes32(0)});
    }

    function _routerWired() internal returns (BlazePhoenixRouter r) {
        r = _router();
        hub.setRoles(address(r), address(this), address(this));
    }

    function _count(address pool, address a, address b) internal view returns (uint256) {
        return BPC.decodeSwapCount(hub.getSlot(hub.keyOf(pool, a, b)));
    }

    /// Quantity: one split hop t0->t1, half on a Gate wrapper and half on a curated V2 pair.
    /// Each leg executes once, so each door records exactly one swap in its own slot (the
    /// wrapper's vitalSlot, the Hub's slot of the pair), the user gets what the Router measured,
    /// and Router, wrapper and adapter end at 0.
    function test_Coherence_SplitHopEachDoorRecordsOnce() public {
        BlazePhoenixGateWrapper w = _wrapper();
        BlazePhoenixRouter router = _routerWired();
        MockV2Pair pair = _pairAt(1_000_000e18, 1_000_000e18);
        uint256 amt = 1_000e18;
        uint256 a = amt / 2;
        Leg[] memory l = new Leg[](2);
        l[0] = _leg(address(w), BPC.KIND_EXTERNAL, KEY, true, a, venue.quoteSell(a));
        l[1] = _leg(address(pair), BPC.KIND_V2, 30, true, a, _v2out(a, 1_000_000e18, 1_000_000e18) * 999 / 1000);
        uint256 exp = l[0].expectedOut + l[1].expectedOut;
        Hop[] memory hs = new Hop[](1);
        hs[0] = Hop({tokenIn: address(t0), tokenOut: address(t1), amountIn: amt, expectedOut: exp, legs: l});
        Route memory r = Route({hops: hs, totalOut: exp, singleOut: 0, singleOutFloor: 0, expectedImpactBps: 0,
            confidenceWad: 0, estGas: 0, hasSurplus: false, isV4Bundle: false});
        address u = _user(router, amt);
        uint256 c0 = _count(address(pair), address(t0), address(t1));
        vm.prank(u);
        uint256 out = router.swapExactIn(r, amt, 1, u, block.timestamp + 1);
        assertEq(t1.balanceOf(u), out, "the user receives what the Router measured");
        assertEq(t0.balanceOf(address(router)) + t1.balanceOf(address(router)), 0, "Router at 0");
        assertEq(t0.balanceOf(address(w)) + t1.balanceOf(address(w)), 0, "wrapper at 0");
        assertEq(t0.balanceOf(address(adapter)) + t1.balanceOf(address(adapter)), 0, "adapter at 0");
        assertEq(BPC.decodeSwapCount(w.vitalSlot()), 1, "the Gate leg: one swap in the wrapper's slot");
        assertEq(_count(address(pair), address(t0), address(t1)), c0 + 1, "the native leg: one swap in the Hub's slot");
    }

    /// Quantity: a Gate wrapper as the INTERMEDIATE hop (t0 -> t1 on the wrapper, t1 -> t2 on a
    /// curated V2 pair). The second hop spends what the first delivered; every party ends at 0
    /// in all three tokens; each door records one swap.
    function test_Coherence_GateAsIntermediateHop() public {
        BlazePhoenixGateWrapper w = _wrapper();
        BlazePhoenixRouter router = _routerWired();
        MockERC20 t2 = new MockERC20("C", "C");
        (address p0, address p1) = address(t1) < address(t2) ? (address(t1), address(t2)) : (address(t2), address(t1));
        MockV2Pair pair = new MockV2Pair(p0, p1);
        pair.setReserves(uint112(1_000_000e18), uint112(1_000_000e18));
        t1.mint(address(pair), 1_000_000e18);
        t2.mint(address(pair), 1_000_000e18);
        hub.seedPool(address(pair), BPC.KIND_V2, 30, address(0), address(t1), address(t2));
        uint256 amt = 1_000e18;
        uint256 e0 = venue.quoteSell(amt);
        uint256 e1 = _v2out(e0, 1_000_000e18, 1_000_000e18) * 999 / 1000;
        Hop[] memory hs = new Hop[](2);
        Leg[] memory l0 = new Leg[](1);
        l0[0] = _leg(address(w), BPC.KIND_EXTERNAL, KEY, true, amt, e0);
        Leg[] memory l1 = new Leg[](1);
        l1[0] = _leg(address(pair), BPC.KIND_V2, 30, address(t1) < address(t2), e0, e1);
        hs[0] = Hop({tokenIn: address(t0), tokenOut: address(t1), amountIn: amt, expectedOut: e0, legs: l0});
        hs[1] = Hop({tokenIn: address(t1), tokenOut: address(t2), amountIn: e0, expectedOut: e1, legs: l1});
        Route memory r = Route({hops: hs, totalOut: e1, singleOut: 0, singleOutFloor: 0, expectedImpactBps: 0,
            confidenceWad: 0, estGas: 0, hasSurplus: false, isV4Bundle: false});
        address u = _user(router, amt);
        uint256 c0 = _count(address(pair), address(t1), address(t2));
        vm.prank(u);
        uint256 out = router.swapExactIn(r, amt, 1, u, block.timestamp + 1);
        assertEq(t2.balanceOf(u), out, "the user receives what the Router measured");
        assertEq(t0.balanceOf(address(router)) + t1.balanceOf(address(router)) + t2.balanceOf(address(router)), 0,
            "Router at 0 in all three tokens");
        assertEq(t0.balanceOf(address(w)) + t1.balanceOf(address(w)), 0, "wrapper at 0");
        assertEq(BPC.decodeSwapCount(w.vitalSlot()), 1, "the Gate hop: one swap in the wrapper's slot");
        assertEq(_count(address(pair), address(t1), address(t2)), c0 + 1, "the native hop: one swap in the Hub's slot");
    }

    /// Quantity: a blind Gate leg (no attestation, no quote in the frame) as an intermediate hop
    /// is refused (RouterE(5)): nothing would bound what the next hop spends.
    function test_Coherence_BlindGateLegRefusedMidRoute() public {
        BlazePhoenixGateWrapper w = _wrapper();
        BlazePhoenixRouter router = _routerWired();
        MockERC20 t2 = new MockERC20("C", "C");
        (address p0, address p1) = address(t1) < address(t2) ? (address(t1), address(t2)) : (address(t2), address(t1));
        MockV2Pair pair = new MockV2Pair(p0, p1);
        pair.setReserves(uint112(1_000_000e18), uint112(1_000_000e18));
        t1.mint(address(pair), 1_000_000e18);
        t2.mint(address(pair), 1_000_000e18);
        hub.seedPool(address(pair), BPC.KIND_V2, 30, address(0), address(t1), address(t2));
        uint256 amt = 1_000e18;
        uint256 e0 = venue.quoteSell(amt);
        Hop[] memory hs = new Hop[](2);
        Leg[] memory l0 = new Leg[](1);
        l0[0] = _leg(address(w), BPC.KIND_EXTERNAL, KEY, true, amt, 0);
        Leg[] memory l1 = new Leg[](1);
        l1[0] = _leg(address(pair), BPC.KIND_V2, 30, address(t1) < address(t2), e0, 0);
        hs[0] = Hop({tokenIn: address(t0), tokenOut: address(t1), amountIn: amt, expectedOut: 0, legs: l0});
        hs[1] = Hop({tokenIn: address(t1), tokenOut: address(t2), amountIn: e0, expectedOut: 0, legs: l1});
        Route memory r = Route({hops: hs, totalOut: 0, singleOut: 0, singleOutFloor: 0, expectedImpactBps: 0,
            confidenceWad: 0, estGas: 0, hasSurplus: false, isV4Bundle: false});
        address u = _user(router, amt);
        vm.prank(u);
        vm.expectRevert(_rerr(5));
        router.swapExactIn(r, amt, 1, u, block.timestamp + 1);
    }

    // ─── D: the protocol floor's base (`finalHopQuote`) on a mixed last hop ───

    /// A last hop t0->t1: a Gate leg attested at the venue's quote, after a V2 leg when one is
    /// given. The priced leg runs FIRST, so a base that folds an unpriced leg only while nothing
    /// was priced yet (the pre-fix rule, leg by leg: mutant [757]) is seen.
    function _lastHop(BlazePhoenixGateWrapper w, MockV2Pair pair, uint256 a, uint256 g)
        internal view returns (Route memory r, uint256 amt)
    {
        uint256 n = address(pair) == address(0) ? 1 : 2;
        Leg[] memory l = new Leg[](n);
        l[n - 1] = _leg(address(w), BPC.KIND_EXTERNAL, KEY, true, a, g);
        uint256 exp = g;
        if (n == 2) {
            uint256 e = _v2out(a, 1_000_000e18, 1_000_000e18) * 999 / 1000;
            l[0] = _leg(address(pair), BPC.KIND_V2, 30, true, a, e);
            exp += e;
        }
        amt = a * n;
        Hop[] memory hs = new Hop[](1);
        hs[0] = Hop({tokenIn: address(t0), tokenOut: address(t1), amountIn: amt, expectedOut: exp, legs: l});
        r = Route({hops: hs, totalOut: exp, singleOut: 0, singleOutFloor: 0, expectedImpactBps: 0,
            confidenceWad: 0, estGas: 0, hasSurplus: false, isV4Bundle: false});
    }

    /// Quantity: the protocol floor over a Gate leg that delivers 82 % of its attestation (above
    /// the 80 % per-leg floor, inside Layer 1's slack). Alone on the last hop the floor is
    /// anchored on its attestation and refuses it (control below). Beside a quoted V2 leg the
    /// base must still carry the Gate leg's attestation, so the same under-delivery is refused.
    /// RED at 1b4f2d4: the base was the V2 leg's quote alone (hopBase = hopQuote when
    /// hopQuote != 0), and the mixed hop settled.
    function test_Coherence_D_MixedLastHopKeepsTheGateLegUnderTheFloor() public {
        BlazePhoenixGateWrapper w = _wrapper();
        BlazePhoenixRouter router = _routerWired();
        MockV2Pair pair = _pairAt(1_000_000e18, 1_000_000e18);
        uint256 a = 500e18;
        uint256 g = venue.quoteSell(a);
        venue.setPayBps(venue.payBps() * 82 / 100);
        (Route memory r, uint256 amt) = _lastHop(w, pair, a, g);
        address u = _user(router, amt);
        vm.prank(u);
        vm.expectRevert(_rerr(5));
        router.swapExactIn(r, amt, 1, u, block.timestamp + 1);
    }

    /// Control: the same Gate leg alone on the last hop is refused by the protocol floor.
    function test_Coherence_D_Control_GateAloneIsUnderTheFloor() public {
        BlazePhoenixGateWrapper w = _wrapper();
        BlazePhoenixRouter router = _routerWired();
        uint256 a = 500e18;
        uint256 g = venue.quoteSell(a);
        venue.setPayBps(venue.payBps() * 82 / 100);
        (Route memory r, uint256 amt) = _lastHop(w, MockV2Pair(address(0)), a, g);
        address u = _user(router, amt);
        vm.prank(u);
        vm.expectRevert(_rerr(5));
        router.swapExactIn(r, amt, 1, u, block.timestamp + 1);
    }

    /// Control: the same mixed last hop with a venue that pays what it attested settles, and
    /// the user receives at least both legs' declared figures less the protocol fee: the larger base
    /// refuses only the under-delivery, not the honest mix.
    function test_Coherence_D_Control_HonestMixedLastHopSettles() public {
        BlazePhoenixGateWrapper w = _wrapper();
        BlazePhoenixRouter router = _routerWired();
        MockV2Pair pair = _pairAt(1_000_000e18, 1_000_000e18);
        uint256 a = 500e18;
        uint256 g = venue.quoteSell(a);
        (Route memory r, uint256 amt) = _lastHop(w, pair, a, g);
        address u = _user(router, amt);
        vm.prank(u);
        uint256 out = router.swapExactIn(r, amt, 1, u, block.timestamp + 1);
        assertEq(t1.balanceOf(u), out, "the user receives what the Router measured");
        uint256 base = r.totalOut; // the Gate leg's attestation plus the V2 leg's declared figure
        assertGe(out, base - BPC.mulDivUp(base, BPC.PROTOCOL_FEE_BPS, BPC.BPS),
            "both legs delivered at least what they declared, less the protocol fee on the output");
    }
}
