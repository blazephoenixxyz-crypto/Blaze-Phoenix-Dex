// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  The encode door asks the protocol floor the Router asks, on whole routes (piso-1116).
//  Red at 5bcb81b: `_walk(ask)` asks the per-leg floor and the hop budget, but no question
//  about `finalHopQuote * floorBps` (`Router._execute`, RouterE(5)). The Router's base is the
//  LAST hop's frame quote, in tokenOut; its impact is averaged over EVERY leg of the route, so a
//  steep hop 0 loosens the floor a sound last hop is held to. A route whose legs each meet their
//  own floor and budget, but whose output sits under that floor, came back from the door as
//  executable bytes the Router refuses.
//  The routes are hand-built and handed to the door as the Solver's plan (a mocked
//  `findBestRoutePlan`, mocked AFTER the route is built); the oracle is the Router's execution of
//  the bytes the door returns, never the Quoter. Edges are found by bisection on the Router, in
//  units of the V3 pool's fill liquidity (`MockV3Pool.swapLiquidity`): no floor constant of the
//  Router is restated here.
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixQuoter} from "../src/BlazePhoenixQuoter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg, RoutePlan} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";
import {MockV3Pool} from "./mocks/MockV3Pool.sol";

contract EncodeDoorsAskTheProtocolFloorRoutesTest is Test {
    uint256 constant BIG = 100e18;
    uint256 constant V2_DEPTH = 1e24;
    uint256 constant STEEP_DEPTH = 1e21;
    uint128 constant V3_DEPTH = 1e24;
    uint24 constant V3_FEE = 500;

    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    BlazePhoenixRouter router;
    BlazePhoenixQuoter quoter;
    MockERC20 tA;
    MockERC20 tB;
    MockERC20 tC;
    address recipient = makeAddr("recipient");

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        tA = new MockERC20("A", "A");
        tB = new MockERC20("B", "B");
        tC = new MockERC20("C", "C");
        solver = new BlazePhoenixSolver(address(hub), address(0));
        router = new BlazePhoenixRouter(
            address(hub), address(solver), address(this), makeAddr("treasury1"), makeAddr("treasury2"));
        quoter = new BlazePhoenixQuoter(address(hub), address(solver));
        hub.setRoles(address(router), address(solver), address(this));
    }

    // ---------------------------------------------------------------- venues and legs

    function _v2(address x, address y, uint256 r) internal returns (MockV2Pair p) {
        p = new MockV2Pair(x, y);
        p.setReserves(uint112(r), uint112(r));
        MockERC20(x).mint(address(p), r);
        MockERC20(y).mint(address(p), r);
        hub.seedPool(address(p), BPC.KIND_V2, 30, address(0), x, y);
    }

    /// A V3 pool on (x, tB) at price 1; the frame reads `l`, the fill liquidity is set per route.
    function _v3(address x, uint128 l) internal returns (MockV3Pool v) {
        v = new MockV3Pool(x, address(tB), V3_FEE);
        v.setState(uint160(BPC.Q96), l);
        tB.mint(address(v), 1e40);
        hub.seedPool(address(v), BPC.KIND_V3, V3_FEE, address(0), x, address(tB));
    }

    /// What pair `p` pays for `a` of `x`: the venue's own math, read from its reserves.
    function _v2Pays(MockV2Pair p, address x, uint256 a) internal view returns (uint256) {
        (uint256 r0, uint256 r1,) = p.getReserves();
        bool zfo = p.token0() == x;
        return BPC.outV2(a, zfo ? r0 : r1, zfo ? r1 : r0, 30);
    }

    /// What pool `v` pays for `a` of `x` at fill liquidity `l`: the mock fills by the Core's
    /// single-tick math.
    function _v3Pays(MockV3Pool v, address x, uint256 a, uint128 l) internal view returns (uint256) {
        return BPC.outV3(a, v.sqrtPriceX96(), l, V3_FEE, v.token0() == x, 0);
    }

    function _v2Leg(MockV2Pair p, address x, uint256 a, uint256 att) internal view returns (Leg memory) {
        return Leg({
            pool: address(p), hooks: address(0), kind: BPC.KIND_V2, fee: 30, tickSpacing: 0,
            zeroForOne: p.token0() == x, stable: false, amountIn: a, expectedOut: att, auxId: bytes32(0)
        });
    }

    function _v3Leg(MockV3Pool v, address x, uint256 a, uint256 att) internal view returns (Leg memory) {
        return Leg({
            pool: address(v), hooks: address(0), kind: BPC.KIND_V3, fee: V3_FEE, tickSpacing: 1,
            zeroForOne: v.token0() == x, stable: false, amountIn: a, expectedOut: att, auxId: bytes32(0)
        });
    }

    function _hop(address x, address y, Leg[] memory legs) internal pure returns (Hop memory h) {
        uint256 a;
        uint256 o;
        for (uint256 i; i < legs.length; ++i) {
            a += legs[i].amountIn;
            o += legs[i].expectedOut;
        }
        h = Hop({tokenIn: x, tokenOut: y, amountIn: a, expectedOut: o, legs: legs});
    }

    function _routeOf(Hop[] memory hops, uint256 paid) internal pure returns (Route memory) {
        return Route({hops: hops, totalOut: paid, singleOut: 0, singleOutFloor: 1,
                      expectedImpactBps: 0, confidenceWad: 0, estGas: 0, hasSurplus: false, isV4Bundle: false});
    }

    /// What a hop that pays the fee on its input spends of `c`: the fee rounded up.
    function _net(uint256 c) internal pure returns (uint256) {
        return c - BPC.mulDivUp(c, BPC.PROTOCOL_FEE_BPS, BPC.BPS);
    }

    // ---------------------------------------------------------------- the oracle

    /// The door, handed `r` as the Solver's plan, then the Router on the bytes it returns.
    /// `settled` is the oracle; `encoded` is what the door said.
    function _doorThenRouter(Route memory r, uint256 order)
        internal returns (bool encoded, bool settled, bytes memory ret)
    {
        RoutePlan memory plan;
        plan.best = r;
        address tIn = r.hops[0].tokenIn;
        vm.mockCall(address(solver), abi.encodeWithSelector(solver.findBestRoutePlan.selector), abi.encode(plan));
        (BlazePhoenixQuoter.Preview memory pv, bytes memory data) = quoter.previewAndEncodeWithMinOut(
            tIn, r.hops[r.hops.length - 1].tokenOut, order, 1, recipient, block.timestamp + 1);
        vm.clearMockedCalls();
        encoded = data.length != 0;
        assertEq(pv.canExecute, encoded, "canExecute and bytes agree");
        // A refused door's would-be bytes: the same route, at `pv.effectiveMinOut` (max of the
        // caller's floor 1 and `singleOutFloor`).
        if (!encoded) {
            data = abi.encodeCall(router.swapExactIn, (r, order, pv.effectiveMinOut, recipient, block.timestamp + 1));
        }
        MockERC20(tIn).mint(address(this), order);
        MockERC20(tIn).approve(address(router), order);
        (settled, ret) = address(router).call(data);
    }

    function _code(bytes memory ret) internal pure returns (uint256) {
        assertEq(bytes4(ret), BlazePhoenixRouter.RouterE.selector, "refused as RouterE");
        bytes memory t = new bytes(ret.length - 4);
        for (uint256 i; i < t.length; ++i) t[i] = ret[i + 4];
        return abi.decode(t, (uint256));
    }

    /// One arm: the Router's verdict is pinned (`settles`), and the door agrees with it.
    function _arm(Route memory r, uint256 order, bool settles, string memory what) internal {
        uint256 snap = vm.snapshotState();
        (bool encoded, bool settled, bytes memory ret) = _doorThenRouter(r, order);
        if (settles) {
            assertTrue(settled, string.concat("premise of the oracle, the Router settles: ", what));
            assertTrue(encoded, string.concat("the door refuses bytes the Router settles: ", what));
        } else {
            assertFalse(settled, string.concat("premise of the oracle, the Router refuses: ", what));
            assertEq(_code(ret), 5, string.concat("refused with code 5: ", what));
            assertFalse(encoded, string.concat("the door encodes bytes the Router refuses: ", what));
        }
        vm.revertToState(snap);
    }

    /// The Router alone on `r` (the bisection's oracle), state rolled back.
    function _routerSettles(Route memory r, uint256 order) internal returns (bool ok) {
        uint256 snap = vm.snapshotState();
        MockERC20 tin = MockERC20(r.hops[0].tokenIn);
        tin.mint(address(this), order);
        tin.approve(address(router), order);
        (ok, ) = address(router).call(
            abi.encodeCall(router.swapExactIn, (r, order, 1, recipient, block.timestamp + 1)));
        vm.revertToState(snap);
    }

    // ---------------------------------------------------------------- T5: two hops

    struct TwoHop {
        MockV2Pair p0;
        MockV3Pool v3;
        uint256 paid0;
        uint256 in1;
        uint256 order;
        string tag;
    }

    /// @notice T5. tA -> tC -> tB: hop 0 one V2 leg that pays what it attests (deep, or steep:
    ///         ~10 % of its reserve), hop 1 one V3 leg that pays what it attests and fills from a
    ///         shallower liquidity than the frame reads. The Router's floor rests on hop 1's frame
    ///         quote alone, loosened by the impact of both hops; its edge, in units of hop 1's fill
    ///         liquidity, is found by bisection on the Router. One unit under the edge the door
    ///         hands back no bytes; at the edge and one unit over it the door encodes. Both
    ///         calendars a two-hop route has: tC a bridge (the fee anchored on hop 1's input) and
    ///         no bridge (exhaustion: every hop pays on its input).
    function test_TwoHops_TheBaseIsTheLastHopsQuote_TheImpactIsTheRoutes() public {
        for (uint256 c; c < 2; ++c) {
            uint256[2] memory edge;
            uint256[2] memory in1;
            for (uint256 k; k < 2; ++k) {
                uint256 snap = vm.snapshotState();
                (edge[k], in1[k]) = _twoHopArms(c == 1, k == 1);
                vm.revertToState(snap);
            }
            // Per unit of hop 1's input, the steep hop 0 moves the edge down: the Router's impact
            // is the route's, so this fixture discriminates a door that measures only hop 1.
            assertLt(edge[1] * in1[0], edge[0] * in1[1], "premise: hop 0's impact loosens the Router's floor");
        }
    }

    function _twoHopArms(bool anchored, bool steep) internal returns (uint256, uint256) {
        if (anchored) hub.addBridge(address(tC));
        assertEq(hub.isBridgeToken(address(tC)), anchored, "premise: the calendar");
        TwoHop memory t;
        t.p0 = _v2(address(tA), address(tC), steep ? STEEP_DEPTH : V2_DEPTH);
        t.v3 = _v3(address(tC), V3_DEPTH);
        t.paid0 = _v2Pays(t.p0, address(tA), BIG);
        // Hop 1 pays the fee on its input in both calendars; hop 0 only on exhaustion, where
        // the order carries it so hop 0's leg is funded at exactly its commitment.
        t.in1 = _net(t.paid0);
        t.order = anchored ? BIG : BIG + BPC.mulDivUp(BIG, BPC.PROTOCOL_FEE_BPS, BPC.BPS);
        t.tag = string.concat(anchored ? "tC a bridge" : "no bridge", steep ? ", steep hop 0" : ", deep hop 0");
        uint128 lo = uint128(t.in1);
        uint128 hi = V3_DEPTH;
        assertFalse(_routerSettles(_twoHopRoute(t, lo), t.order), string.concat("fixture: refused at the low end, ", t.tag));
        assertTrue(_routerSettles(_twoHopRoute(t, hi), t.order), string.concat("fixture: settles at the frame's depth, ", t.tag));
        while (hi - lo > 1) {
            uint128 mid = lo + (hi - lo) / 2;
            if (_routerSettles(_twoHopRoute(t, mid), t.order)) hi = mid;
            else lo = mid;
        }
        // Under the edge only the protocol floor is left to refuse: each leg pays what it
        // attests, and the V3 leg's bound (max of its attestation and the covered share of its
        // frame quote) is still its attestation.
        {
            (uint256 q3, , ) = BPC.legQuoteImpact(_v3Leg(t.v3, address(tC), t.in1, 0), address(tC), address(tB), t.in1);
            uint256 p3 = _v3Pays(t.v3, address(tC), t.in1, lo);
            assertGe(p3, BPC.mulDiv(q3, BPC.MIN_QUOTE_COVERAGE_BPS, BPC.BPS), "fixture: the V3 leg's bound is its attestation");
        }
        _arm(_twoHopRoute(t, lo), t.order, false, string.concat(t.tag, ", one unit under the floor's edge"));
        _arm(_twoHopRoute(t, hi), t.order, true, string.concat(t.tag, ", at the floor's edge"));
        _arm(_twoHopRoute(t, hi + 1), t.order, true, string.concat(t.tag, ", one unit over it"));
        return (hi, t.in1);
    }

    function _twoHopRoute(TwoHop memory t, uint128 l) internal returns (Route memory) {
        t.v3.setSwapLiquidity(l);
        uint256 p3 = _v3Pays(t.v3, address(tC), t.in1, l);
        Hop[] memory hops = new Hop[](2);
        Leg[] memory l0 = new Leg[](1);
        l0[0] = _v2Leg(t.p0, address(tA), BIG, t.paid0);
        hops[0] = _hop(address(tA), address(tC), l0);
        Leg[] memory l1 = new Leg[](1);
        l1[0] = _v3Leg(t.v3, address(tC), t.in1, p3);
        hops[1] = _hop(address(tC), address(tB), l1);
        return _routeOf(hops, p3);
    }

    // ---------------------------------------------------------------- T9: the fuzz

    struct Draw {
        uint256 amt;
        uint256 x;
        uint256 a3;
        uint128 depth;
        uint128 fill;
        uint256 att;
        bool twoHops;
        bool bridged;
        bool exactFloor;
        uint256 order;
        uint256 p2;
        uint256 p3;
        MockV2Pair p0;
        MockV2Pair v2;
        MockV3Pool v3;
    }

    /// @notice T9. Encoded means settled: whatever bytes the door hands back, the Router settles.
    ///         The last hop splits between a deep V2 pair and a V3 pool whose frame depth is drawn
    ///         against its share (1/1024x to 1024x) and whose fill liquidity is 70-100 % of it.
    ///         Order from dust (1e3) to 1e27; the V3 leg attests what it pays, 1 wei, or the
    ///         frame's quote; `singleOutFloor` is 1 or exactly what the Router delivers (a dry run);
    ///         1 hop (tB a bridge or not) and 2 hops (tC a bridge or not).
    function testFuzz_EncodedMeansSettled_UnderTheProtocolFloor(
        uint256 amtSeed, uint256 depthSeed, uint256 fillBps, uint256 splitBps, uint256 attMode,
        bool exactFloor, bool twoHops, bool bridged
    ) public {
        Draw memory d;
        {
            uint256 e = bound(amtSeed % 1000, 3, 26);
            d.amt = (1 + (amtSeed / 1000) % 10) * 10 ** e;
        }
        d.twoHops = twoHops;
        d.bridged = bridged;
        d.exactFloor = exactFloor;
        address x = twoHops ? address(tC) : address(tA);
        if (bridged) hub.addBridge(twoHops ? address(tC) : address(tB));
        // The last hop's input: the order on 1 hop; hop 0's output net of hop 1's input fee on 2.
        if (twoHops) {
            d.p0 = _v2(address(tA), address(tC), _deep(d.amt));
            d.x = _net(_v2Pays(d.p0, address(tA), d.amt));
        } else {
            d.x = d.amt;
        }
        // Hop 0 pays the fee on its input only when no hop's input is a bridge and the route is
        // not a direct one into a bridge: then the order carries it, so hop 0 is funded in full.
        d.order = bridged ? d.amt : d.amt + BPC.mulDivUp(d.amt, BPC.PROTOCOL_FEE_BPS, BPC.BPS);
        d.a3 = d.x * bound(splitBps, 1, 9_999) / BPC.BPS;
        if (d.a3 == 0) d.a3 = 1;
        {
            uint256 dep = (d.a3 << bound(depthSeed, 0, 20)) >> 10;
            d.depth = uint128(dep == 0 ? 1 : dep);
            uint256 f = uint256(d.depth) * bound(fillBps, 7_000, 10_000) / BPC.BPS;
            d.fill = uint128(f == 0 ? 1 : f);
        }
        d.v2 = _v2(x, address(tB), _deep(d.x));
        d.v3 = _v3(x, d.depth);
        d.v3.setSwapLiquidity(d.fill);
        Route memory r = _fuzzRoute(d, x, attMode % 3);
        // A mock venue reverts a fill that pays nothing, whatever the door said: such a draw
        // asks the mock, not the floor.
        vm.assume(d.p2 != 0 && d.p3 != 0);
        if (exactFloor) r.singleOutFloor = _dryRunGross(d, r);
        (bool encoded, bool settled, bytes memory ret) = _doorThenRouter(r, d.order);
        if (encoded && !settled) {
            assertTrue(false, string.concat(
                "the door encodes bytes the Router refuses: ", vm.toString(ret),
                ", order ", vm.toString(d.amt), ", V3 share ", vm.toString(d.a3), " of ", vm.toString(d.x),
                ", depth ", vm.toString(uint256(d.depth)), ", fill ", vm.toString(uint256(d.fill)),
                ", attests ", vm.toString(d.att)));
        }
    }

    function _deep(uint256 a) internal pure returns (uint256 r) {
        r = a << 20;
        if (r > 1 << 111) r = 1 << 111;
    }

    function _fuzzRoute(Draw memory d, address x, uint256 mode) internal view returns (Route memory) {
        uint256 a2 = d.x - d.a3;
        d.p2 = _v2Pays(d.v2, x, a2);
        d.p3 = _v3Pays(d.v3, x, d.a3, d.fill);
        if (mode == 0) d.att = d.p3;
        else if (mode == 1) d.att = 1;
        else (d.att, , ) = BPC.legQuoteImpact(_v3Leg(d.v3, x, d.a3, 0), x, address(tB), d.a3);
        Leg[] memory last = new Leg[](2);
        last[0] = _v2Leg(d.v2, x, a2, d.p2);
        last[1] = _v3Leg(d.v3, x, d.a3, d.att);
        Hop[] memory hops = new Hop[](d.twoHops ? 2 : 1);
        if (d.twoHops) {
            Leg[] memory first = new Leg[](1);
            first[0] = _v2Leg(d.p0, address(tA), d.amt, _v2Pays(d.p0, address(tA), d.amt));
            hops[0] = _hop(address(tA), address(tC), first);
        }
        hops[hops.length - 1] = _hop(x, address(tB), last);
        return _routeOf(hops, d.p2 + d.p3);
    }

    /// The Router's gross output on `r` at floor 1 (what the last hop's venues paid out), or 1 if
    /// it refuses the route even there. State rolled back.
    function _dryRunGross(Draw memory d, Route memory r) internal returns (uint256 g) {
        uint256 snap = vm.snapshotState();
        uint256 before = tB.balanceOf(address(d.v2)) + tB.balanceOf(address(d.v3));
        MockERC20 tin = MockERC20(r.hops[0].tokenIn);
        tin.mint(address(this), d.order);
        tin.approve(address(router), d.order);
        (bool ok, ) = address(router).call(
            abi.encodeCall(router.swapExactIn, (r, d.order, 1, recipient, block.timestamp + 1)));
        g = ok ? before - tB.balanceOf(address(d.v2)) - tB.balanceOf(address(d.v3)) : 1;
        vm.revertToState(snap);
    }
}
