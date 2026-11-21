// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  The encode doors ask the protocol floor the Router refuses on (2026-11-16). After the
//  per-leg floor and the hop budget, the Router refuses a route whose gross output, before the
//  output fee, rests under its floor share of the last hop's in-frame quote (`finalHopQuote`
//  times the route's floor bps, rounded up), RouterE(5). `_walk(ask)` asks the per-leg floor
//  and the hop budget and stops there: a leg whose venue pays under that share of its in-frame
//  quote, with an attestation that matches what it pays, clears the door and the Router refuses
//  the bytes. The in-frame quote reads the pool's `liquidity()` (single-tick model); the mock
//  fills from a shallower `swapLiquidity`, the shape of a fill that crosses into thin ticks.
//  Oracle: the Router's execution of the door's bytes, or of the call the door would have
//  encoded (`swapExactIn(pv.route, order, pv.effectiveMinOut, ...)`), never the Quoter. No
//  floor constant is restated here: every edge is found by bisection over the Router.
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixQuoter} from "../src/BlazePhoenixQuoter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg, RoutePlan} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV3Pool} from "./mocks/MockV3Pool.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";

contract EncodeDoorsAskTheProtocolFloorTest is Test {
    uint256 constant SMALL = 1e18;
    uint128 constant DEEP_L = 1e30;

    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    BlazePhoenixRouter router;
    BlazePhoenixQuoter quoter;
    MockERC20 tA;
    MockERC20 tB;
    MockERC20 tC;
    address recipient = makeAddr("recipient");

    // The plan the next `_build` assembles (set by each test before it asks).
    MockERC20 cfgIn;              // hop 0 tokenIn
    MockV3Pool[] cfgP0;           // hop 0 V3 legs (cfgIn -> tB)
    uint256[] cfgA0;              // their amounts
    MockV2Pair cfgV2;             // optional V2 leg of hop 0 (cfgIn -> tB), paying its quote
    uint256 cfgV2Amt;
    MockV3Pool[] cfgP1;           // hop 1 V3 legs (tB -> tC); empty: one hop
    uint256[] cfgW1;              // their weights of hop 0's output
    MockV3Pool cfgKnob;           // the leg the knob moves
    bool cfgKnobIsAttestation;    // false: knob = swapLiquidity; true: attestation = cfgTop - knob
    uint256 cfgTop;
    bool cfgExactFloor;           // singleOutFloor = the floor the Solver attests, else 1
    MockV3Pool cfgBlind;          // a leg left unattested (expectedOut 0): blind where the frame prices none
    uint256 cfgDeclared;          // the declared figure of the last hop, when that hop holds `cfgBlind`

    uint24[4] fees = [uint24(100), 500, 3000, 10000];

    // Door/Router disagreements, collected so every sub-case's premises run before the verdict.
    uint256 disagreements;
    string disagreed;

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
        cfgIn = tA;
    }

    // ------------------------------------------------------------------ fixtures

    function _v3(MockERC20 a, MockERC20 b, uint24 fee, uint128 l) internal returns (MockV3Pool p) {
        p = new MockV3Pool(address(a), address(b), fee);
        p.setState(uint160(BPC.Q96), l);
        a.mint(address(p), 1 << 125);
        b.mint(address(p), 1 << 125);
        hub.seedPool(address(p), BPC.KIND_V3, fee, address(0), address(a), address(b));
    }

    function _v2(MockERC20 a, MockERC20 b, uint256 r) internal returns (MockV2Pair p) {
        p = new MockV2Pair(address(a), address(b));
        a.mint(address(p), r);
        b.mint(address(p), r);
        p.setReserves(uint112(r), uint112(r));
        hub.seedPool(address(p), BPC.KIND_V2, 30, address(0), address(a), address(b));
    }

    function _reset() internal {
        delete cfgP0;
        delete cfgA0;
        delete cfgP1;
        delete cfgW1;
        cfgV2 = MockV2Pair(address(0));
        cfgV2Amt = 0;
        cfgKnob = MockV3Pool(address(0));
        cfgKnobIsAttestation = false;
        cfgTop = 0;
        cfgExactFloor = false;
        cfgIn = tA;
        cfgBlind = MockV3Pool(address(0));
        cfgDeclared = 0;
    }

    function _legV3(MockV3Pool p, address tIn, uint256 amt, uint256 exp) internal view returns (Leg memory) {
        return Leg({
            pool: address(p), hooks: address(0), kind: BPC.KIND_V3, fee: p.fee(), tickSpacing: 1,
            zeroForOne: p.token0() == tIn, stable: false, amountIn: amt, expectedOut: exp, auxId: bytes32(0)
        });
    }

    function _legV2(MockV2Pair p, address tIn, uint256 amt, uint256 exp) internal view returns (Leg memory) {
        return Leg({
            pool: address(p), hooks: address(0), kind: BPC.KIND_V2, fee: 30, tickSpacing: 0,
            zeroForOne: p.token0() == tIn, stable: false, amountIn: amt, expectedOut: exp, auxId: bytes32(0)
        });
    }

    /// What `p` pays for `amt`, from the liquidity it fills with.
    function _paysV3(MockV3Pool p, address tIn, uint256 amt) internal view returns (uint256) {
        uint128 l = p.swapLiquidity() != 0 ? p.swapLiquidity() : p.liquidity();
        return BPC.outV3(amt, p.sqrtPriceX96(), l, p.fee(), p.token0() == tIn, 0);
    }

    /// What `p` would pay for `amt` from the liquidity it quotes (the band), the fixture's ruler.
    function _bandV3(MockV3Pool p, address tIn, uint256 amt) internal view returns (uint256) {
        return BPC.outV3(amt, p.sqrtPriceX96(), p.liquidity(), p.fee(), p.token0() == tIn, 0);
    }

    function _paysV2(MockV2Pair p, address tIn, uint256 amt) internal view returns (uint256) {
        (uint112 r0, uint112 r1, ) = p.getReserves();
        bool z = p.token0() == tIn;
        return BPC.outV2(amt, z ? r0 : r1, z ? r1 : r0, 30);
    }

    function _attest(MockV3Pool p, address tIn, uint256 amt, uint256 knob) internal view returns (uint256) {
        if (cfgKnobIsAttestation && p == cfgKnob) return cfgTop - knob;
        return _paysV3(p, tIn, amt);
    }

    /// The plan the config names, with every attestation what its venue pays (except the
    /// attestation knob), fee calendar from the hub, the order funding hop 0 at its commitment.
    function _build(uint256 knob) internal returns (Route memory r, address tOut, uint256 order) {
        if (!cfgKnobIsAttestation && address(cfgKnob) != address(0)) cfgKnob.setSwapLiquidity(uint128(knob));
        address tIn = address(cfgIn);
        uint256 n0 = cfgP0.length + (address(cfgV2) != address(0) ? 1 : 0);
        Leg[] memory legs = new Leg[](n0);
        uint256 sumIn;
        uint256 sumOut;
        for (uint256 i; i < cfgP0.length; ++i) {
            legs[i] = _legV3(cfgP0[i], tIn, cfgA0[i], _attest(cfgP0[i], tIn, cfgA0[i], knob));
            sumIn += cfgA0[i];
            sumOut += legs[i].expectedOut;
        }
        if (address(cfgV2) != address(0)) {
            legs[n0 - 1] = _legV2(cfgV2, tIn, cfgV2Amt, _paysV2(cfgV2, tIn, cfgV2Amt));
            sumIn += cfgV2Amt;
            sumOut += legs[n0 - 1].expectedOut;
        }
        Hop[] memory hops = new Hop[](cfgP1.length == 0 ? 1 : 2);
        hops[0] = Hop({tokenIn: tIn, tokenOut: address(tB), amountIn: sumIn, expectedOut: sumOut, legs: legs});
        uint256 fin = sumOut;
        tOut = address(tB);
        if (cfgP1.length != 0) {
            Leg[] memory l1 = new Leg[](cfgP1.length);
            uint256 wSum;
            for (uint256 i; i < cfgW1.length; ++i) wSum += cfgW1[i];
            uint256 in1;
            uint256 out1;
            for (uint256 i; i < cfgP1.length; ++i) {
                uint256 amt = i + 1 == cfgP1.length ? sumOut - in1 : sumOut * cfgW1[i] / wSum;
                l1[i] = _legV3(cfgP1[i], address(tB), amt, _attest(cfgP1[i], address(tB), amt, knob));
                in1 += amt;
                out1 += l1[i].expectedOut;
            }
            hops[1] = Hop({tokenIn: address(tB), tokenOut: address(tC), amountIn: in1, expectedOut: out1, legs: l1});
            fin = out1;
            tOut = address(tC);
        }
        if (address(cfgBlind) != address(0)) _blindIn(hops);
        r = Route({hops: hops, totalOut: fin, singleOut: 0, singleOutFloor: cfgExactFloor ? this._solversFloor(hops, tOut, fin) : 1,
            expectedImpactBps: 0, confidenceWad: 0, estGas: 0, hasSurplus: false, isV4Bundle: false});
        bool onOut = hops.length == 1 && hub.isBridgeToken(tOut);
        order = onOut ? sumIn : sumIn + BPC.mulDivUp(sumIn, BPC.PROTOCOL_FEE_BPS, BPC.BPS);
    }

    /// `cfgBlind`'s leg left unattested; the last hop, when it holds it, declared at `cfgDeclared`.
    function _blindIn(Hop[] memory hops) internal view {
        for (uint256 h; h < hops.length; ++h) {
            for (uint256 l; l < hops[h].legs.length; ++l) {
                if (hops[h].legs[l].pool != address(cfgBlind)) continue;
                hops[h].legs[l].expectedOut = 0;
                if (h + 1 == hops.length) hops[h].expectedOut = cfgDeclared;
            }
        }
    }

    /// The `singleOutFloor` the Solver attests on `hops` (Solver:1761-1793 and 1812-1821), and not
    /// the plan's whole output: the Solver never promises that, it promises the protocol floor's
    /// share, `BPC.ironFloorBpsShv` of its own impact ruler (`_legImpactBps`, Solver:1683-1699,
    /// share-weighted over the route's legs) and of the legs' concentration, on the final output
    /// net of the input-side fees (`BPC.netOfInputFees`, none when one hop lands in a bridge),
    /// rounded up. A promise the Solver cannot attest would test the door against a plan no
    /// Solver hands it. It does not bind: the door rescales it onto its own walk, about the
    /// Solver's rate times `walkOut`, under the carry the walk delivers, so the protocol floor
    /// decides every edge here. This arm checks that the Solver's promise moves no edge; it
    /// does not pin the rescale (`Quoter` floorExact): a mutant that inflates it is refused by
    /// the door and by the Router on the door's route alike (M27, a recorded survivor).
    function _solversFloor(Hop[] memory hops, address tOut, uint256 fin) external view returns (uint256) {
        uint256 floorBps = _solversFloorBps(hops);
        uint256 base = fin;
        if (!(hops.length == 1 && hub.isBridgeToken(tOut))) {
            uint256 feeHop = type(uint256).max;
            for (uint256 h; h < hops.length; ++h) {
                if (hub.isBridgeToken(hops[h].tokenIn)) { feeHop = h; break; }
            }
            base = BPC.netOfInputFees(hops, fin, feeHop, false);
        }
        return BPC.mulDivUp(base, floorBps, BPC.BPS);
    }

    /// The Solver's floor rate on `hops`: its impact ruler share-weighted over the route's legs,
    /// and the legs' concentration, through `BPC.ironFloorBpsShv`.
    function _solversFloorBps(Hop[] memory hops) internal view returns (uint256) {
        uint256 weightedAcc;
        uint256 totalLegs;
        uint256 legShv;
        for (uint256 h; h < hops.length; ++h) {
            Leg[] memory ls = hops[h].legs;
            uint256 hopIn = hops[h].amountIn;
            uint256 sA;
            uint256 sA2;
            for (uint256 i; i < ls.length; ++i) {
                uint256 li = _solversLegImpact(ls[i]);
                uint256 a = ls[i].amountIn;
                weightedAcc += hopIn == 0 ? li : BPC.mulDiv(li * ls.length, a, hopIn);
                sA += a;
                sA2 += a * a;
            }
            totalLegs += ls.length;
            legShv += BPC.legShaveBps(sA, sA2);
        }
        return BPC.ironFloorBpsShv(totalLegs > 0 ? weightedAcc / totalLegs : 0, legShv, 0);
    }

    /// The Solver's impact ruler for one leg (Solver:1683-1699), on the same reads.
    function _solversLegImpact(Leg memory l) internal view returns (uint256) {
        if (BPC.kindHas(l.kind, BPC.A_RESERVES)) {
            (uint256 r0, uint256 r1) = BPC.getReserves(l.pool);
            return BPC.impactV2Bps(l.amountIn, l.zeroForOne ? r0 : r1);
        }
        if (BPC.kindHas(l.kind, BPC.A_CONC_POOL)) {
            (uint160 sp, uint24 dynFee, bool dyn) = BPC.v3StateAndDynFee(l.pool);
            return BPC.impactV3Bps(l.amountIn, sp, BPC.getLiquidity(l.pool),
                BPC.quoteV3Fee(l.pool, l.fee, dynFee, dyn), l.zeroForOne);
        }
        return BPC.DEFAULT_IMPACT_BPS;
    }

    /// The door handed `r` as the Solver's plan, then the Router on the bytes it returned, or on
    /// the call it would have encoded. State is restored after the Router ran.
    function _run(Route memory r, address tOut, uint256 order)
        internal returns (bool encoded, bool settled, bytes memory ret)
    {
        uint256 snap = vm.snapshotState();
        RoutePlan memory plan;
        plan.best = r;
        address tIn = r.hops[0].tokenIn;
        vm.mockCall(address(solver), abi.encodeWithSelector(solver.findBestRoutePlan.selector), abi.encode(plan));
        (BlazePhoenixQuoter.Preview memory pv, bytes memory data) =
            quoter.previewAndEncodeWithMinOut(tIn, tOut, order, 1, recipient, block.timestamp + 1);
        vm.clearMockedCalls();
        encoded = data.length != 0;
        assertEq(pv.canExecute, encoded, "canExecute and bytes agree");
        if (!encoded) {
            Route memory pr = pv.route.hops.length != 0 ? pv.route : r;
            uint256 minOut = pv.effectiveMinOut != 0 ? pv.effectiveMinOut : (r.singleOutFloor > 1 ? r.singleOutFloor : 1);
            data = abi.encodeCall(router.swapExactIn, (pr, order, minOut, recipient, block.timestamp + 1));
        }
        MockERC20(tIn).mint(address(this), order);
        MockERC20(tIn).approve(address(router), order);
        (settled, ret) = address(router).call(data);
        vm.revertToState(snap);
    }

    function _at(uint256 knob) internal returns (bool encoded, bool settled, bytes memory ret) {
        (Route memory r, address tOut, uint256 order) = _build(knob);
        return _run(r, tOut, order);
    }

    function _assertRouterE(bytes memory ret, uint256 code, string memory tag) internal pure {
        assertGe(ret.length, 36, string.concat(tag, ": refused with a RouterE word"));
        assertEq(bytes4(ret), BlazePhoenixRouter.RouterE.selector, string.concat(tag, ": refused as RouterE"));
        bytes memory t = new bytes(ret.length - 4);
        for (uint256 i; i < t.length; ++i) t[i] = ret[i + 4];
        assertEq(abi.decode(t, (uint256)), code, string.concat(tag, ": with its code"));
    }

    /// The Router's edge on the knob: the least knob it settles at, `lo` refused and `hi` settled.
    function _routerEdge(uint256 lo, uint256 hi, string memory tag) internal returns (uint256) {
        (, bool sLo, bytes memory rLo) = _at(lo);
        assertFalse(sLo, string.concat(tag, ": premise, the Router refuses at the low end"));
        _assertRouterE(rLo, 5, string.concat(tag, " low end"));
        (, bool sHi, bytes memory rHi) = _at(hi);
        assertTrue(sHi, string.concat(tag, ": premise, the Router settles at the high end: ", vm.toString(rHi)));
        while (hi - lo > 1) {
            uint256 mid = lo + (hi - lo) / 2;
            (, bool s, ) = _at(mid);
            if (s) hi = mid;
            else lo = mid;
        }
        emit log_named_uint(string.concat(tag, " Router edge"), hi);
        return hi;
    }

    /// At edge-1, edge and edge+1 the door encodes exactly where the Router settles.
    function _doorAgreesAround(uint256 e, string memory tag) internal {
        for (uint256 k = e - 1; k <= e + 1; ++k) {
            (bool encoded, bool settled, bytes memory ret) = _at(k);
            string memory at = string.concat(tag, k < e ? " edge-1" : (k == e ? " edge" : " edge+1"));
            assertEq(settled, k >= e, string.concat(at, ": premise, the edge is the Router's"));
            if (!settled) _assertRouterE(ret, 5, at);
            _agree(encoded, settled, at);
        }
    }

    function _agree(bool encoded, bool settled, string memory at) internal {
        if (encoded == settled) return;
        ++disagreements;
        disagreed = string.concat(disagreed, " [", at, encoded ? ": encoded, Router refuses]" : ": not encoded, Router settles]");
    }

    function _assertNoDisagreement() internal view {
        assertEq(disagreements, 0, string.concat("the door encodes exactly where the Router settles:", disagreed));
    }

    function _edgeCase(uint256 lo, uint256 hi, string memory tag) internal {
        _doorAgreesAround(_routerEdge(lo, hi, tag), tag);
    }

    /// Impact of `out` for `amt` at price 1 against the spot net of the venue fee, in bps (the
    /// fixture's own ruler, from the venue math, never the floor's).
    function _impV3(MockV3Pool p, uint256 amt) internal view returns (uint256) {
        uint256 out = _bandV3(p, address(tA), amt);
        uint256 spot = amt * (1e6 - p.fee()) / 1e6;
        return out >= spot ? 0 : BPC.BPS - out * BPC.BPS / spot;
    }

    function _impV2(MockV2Pair p, uint256 amt) internal view returns (uint256) {
        uint256 out = _paysV2(p, address(tA), amt);
        uint256 spot = amt * (BPC.BPS - 30) / BPC.BPS;
        return out >= spot ? 0 : BPC.BPS - out * BPC.BPS / spot;
    }

    function _single(MockV3Pool p, uint256 amt) internal {
        _reset();
        cfgP0.push(p);
        cfgA0.push(amt);
        cfgKnob = p;
    }

    // ------------------------------------------------------------------ T1, T1c

    /// Red at 5bcb81b: one V3 leg paying 9500, 9000, 8501 and 8113 bps of its band quote, its
    /// attestation what it pays, `singleOutFloor = 1`, `userMinOut = 1`, fee on the input. The
    /// per-leg floor and the hop budget pass; the Router refuses on the protocol floor and the
    /// door encoded each of them (probe R3, 2026-11-14 and 2026-11-16).
    function test_UnderTheProtocolFloor_TheDoorsBytesSettleOrAreNotEncoded() public {
        MockV3Pool gap = _v3(tA, tB, 500, DEEP_L);
        _single(gap, SMALL);
        uint128[4] memory ls = [uint128(19e18), 9e18, 5.67e18, 4.3e18];
        uint256[4] memory want = [uint256(9500), 9000, 8501, 8113];
        uint256 band = _bandV3(gap, address(tA), SMALL);
        for (uint256 i; i < ls.length; ++i) {
            gap.setSwapLiquidity(ls[i]);
            uint256 paidBps = _paysV3(gap, address(tA), SMALL) * BPC.BPS / band;
            string memory tag = string.concat("paid bps ", vm.toString(paidBps));
            assertApproxEqAbs(paidBps, want[i], 1, string.concat(tag, ": premise, the regime"));
            (bool encoded, bool settled, bytes memory ret) = _at(ls[i]);
            assertFalse(settled, string.concat(tag, ": premise of the oracle, the Router refuses"));
            _assertRouterE(ret, 5, tag);
            _agree(encoded, settled, tag);
        }
        _assertNoDisagreement();
    }

    /// Control, green at 5bcb81b (red under M17, a door that asks the whole quote): the same leg
    /// paying 9900 bps of its band quote is encoded and settled.
    function test_Control_OverTheProtocolFloor_TheBytesSettle() public {
        MockV3Pool gap = _v3(tA, tB, 500, DEEP_L);
        _single(gap, SMALL);
        gap.setSwapLiquidity(99e18);
        uint256 paidBps = _paysV3(gap, address(tA), SMALL) * BPC.BPS / _bandV3(gap, address(tA), SMALL);
        assertApproxEqAbs(paidBps, 9900, 1, "premise, the regime");
        (bool encoded, bool settled, bytes memory ret) = _at(99e18);
        assertTrue(settled, string.concat("settled: ", vm.toString(ret)));
        assertTrue(encoded, "encoded");
    }

    // ------------------------------------------------------------------ T2

    /// Red at 5bcb81b: at the Router's own edge on the protocol floor, found by bisection over
    /// the leg's `swapLiquidity` (edge-1 refused, edge settled), the door encodes exactly where
    /// the Router settles, to the wei of the fill. Odd order size so the floor's rounding counts;
    /// both fee calendars (fee on the input; a direct route into a bridge, fee on the output) and
    /// both promises (`singleOutFloor` 1, and the floor the Solver attests, `_solversFloor`).
    function test_AtTheProtocolFloorsEdge_DoorAndRouterAgreeToTheWei() public {
        MockV3Pool gap = _v3(tA, tB, 500, DEEP_L);
        for (uint256 c; c < 2; ++c) {
            if (c == 1) hub.addBridge(address(tB));
            assertEq(hub.isBridgeToken(address(tB)), c == 1, "premise: the calendar");
            // Both promises on both calendars: the Solver sizes its floor for each (gross on
            // the output calendar, net of the input fee on the other, Solver:1812-1821). The
            // Solver's floor sits under the carry, so the edge is the protocol floor's on both.
            for (uint256 f; f < 2; ++f) {
                _single(gap, SMALL + 7);
                cfgExactFloor = f == 1;
                string memory tag = string.concat(c == 1 ? "fee on output" : "fee on input",
                    f == 1 ? ", the Solver's floor" : ", singleOutFloor 1");
                _edgeCase(4.3e18, 99e18, tag);
            }
        }
        _assertNoDisagreement();
    }

    // ------------------------------------------------------------------ T3

    /// Red at 5bcb81b: the floor the door asks loosens with the impact the Router measures, no
    /// more and no less. Regimes: impact ~0 at dust (1e3 wei) and at the top of the range (a
    /// 2**111 reserve pair beside a 2**120 liquidity pool), ~200 bps, and past the floor's clamp
    /// (~2500 bps); one V3 leg alone, and a V3 leg beside a V2 leg that carries the impact. Each
    /// edge is the Router's, by bisection over the V3 leg's fill.
    function test_TheFloorLoosensWithTheMeasuredImpact_AsTheRouters() public {
        // V3 alone, impact from the band.
        MockV3Pool p200 = _v3(tA, tB, 500, uint128(49 * SMALL));
        MockV3Pool pClamp = _v3(tA, tB, 3000, uint128(3 * SMALL));
        MockV3Pool pDust = _v3(tA, tB, 100, DEEP_L);
        uint256 i200 = _impV3(p200, SMALL);
        uint256 iClamp = _impV3(pClamp, SMALL);
        assertTrue(i200 > 100 && i200 < 400, "premise: ~200 bps of impact");
        assertGt(iClamp, 2000, "premise: impact past the clamp");
        // At 1e3 wei one wei of output is 10 bps: "~0" up to the wei rounding of dust.
        assertLt(_impV3(pDust, 1e3), 50, "premise: dust, impact ~0 up to its rounding");
        _single(p200, SMALL);
        _edgeCase(SMALL, 49 * SMALL, "V3 impact ~200");
        _single(pClamp, SMALL);
        _edgeCase(SMALL, 3 * SMALL, "V3 impact past the clamp");
        _single(pDust, 1e3);
        _edgeCase(1e3, DEEP_L, "V3 dust");

        // V2 carries the impact, V3 beside it pays under its band.
        MockV3Pool gap = _v3(tA, tB, 500, DEEP_L);
        MockV2Pair v200 = _v2(tA, tB, 50 * SMALL);
        MockV2Pair vClamp = _v2(tA, tB, 4 * SMALL);
        assertTrue(_impV2(v200, SMALL) > 100 && _impV2(v200, SMALL) < 400, "premise: V2 ~200 bps");
        assertGt(_impV2(vClamp, SMALL), 1700, "premise: V2 past the clamp");
        _single(gap, SMALL);
        (cfgV2, cfgV2Amt) = (v200, SMALL);
        _edgeCase(SMALL, DEEP_L, "V2 ~200 + V3");
        _single(gap, SMALL);
        (cfgV2, cfgV2Amt) = (vClamp, SMALL);
        _edgeCase(SMALL / 10, DEEP_L, "V2 past the clamp + V3");

        // Top of the range.
        MockV3Pool top = _v3(tA, tB, 10000, uint128(1 << 120));
        MockV2Pair vTop = _v2(tA, tB, 1 << 111);
        _single(top, 1 << 107);
        (cfgV2, cfgV2Amt) = (vTop, 1 << 107);
        _edgeCase(1 << 107, 1 << 120, "top: 2**111 pair + 2**120 pool");
        _assertNoDisagreement();
    }

    /// Red at 5bcb81b (a draw in the band the door encodes and the Router refuses): over one V3
    /// leg's impact (liquidity 2x to 1000x the order) and its fill (50 % to 100 % of the band
    /// liquidity), the door encodes exactly where the Router settles.
    function testFuzz_TheFloorLoosensWithTheMeasuredImpact_AsTheRouters(uint256 ratio, uint256 fillBps) public {
        ratio = bound(ratio, 2, 1000);
        fillBps = bound(fillBps, 5000, 10000);
        MockV3Pool p = _v3(tA, tB, 500, uint128(ratio * SMALL));
        _single(p, SMALL);
        uint256 knob = ratio * SMALL * fillBps / BPC.BPS;
        (bool encoded, bool settled, bytes memory ret) = _at(knob);
        if (!settled) _assertRouterE(ret, 5, "fuzz");
        assertEq(encoded, settled, "the door encodes exactly where the Router settles");
    }

    // ------------------------------------------------------------------ T4

    /// Red at 5bcb81b: the door's floor carries the Router's leg-concentration shave, measured on
    /// the bytes' leg amounts. Splits: 2 and 3 equal legs, 99:1, and a 1e3 wei dust leg (10 wei
    /// pays 0 on this pool); one hop, and two hops of two equal legs each (the
    /// shave sums per hop). The Router's edge by bisection over one leg's fill.
    function test_TheLegShaveIsTheRoutersConcentration() public {
        MockV3Pool[4] memory ab;
        for (uint256 i; i < 4; ++i) ab[i] = _v3(tA, tB, fees[i], DEEP_L);
        MockV3Pool bc0 = _v3(tB, tC, 500, DEEP_L);
        MockV3Pool bc1 = _v3(tB, tC, 3000, DEEP_L);

        _reset();
        cfgP0.push(ab[0]); cfgA0.push(SMALL); cfgP0.push(ab[1]); cfgA0.push(SMALL);
        cfgKnob = ab[0];
        _edgeCase(SMALL, DEEP_L, "2 equal legs");

        _reset();
        for (uint256 i; i < 3; ++i) { cfgP0.push(ab[i]); cfgA0.push(SMALL); }
        cfgKnob = ab[0];
        _edgeCase(SMALL, DEEP_L, "3 equal legs");

        _reset();
        cfgP0.push(ab[0]); cfgA0.push(99 * SMALL); cfgP0.push(ab[1]); cfgA0.push(SMALL);
        cfgKnob = ab[0];
        _edgeCase(99 * SMALL, DEEP_L, "99:1");

        _reset();
        cfgP0.push(ab[0]); cfgA0.push(SMALL); cfgP0.push(ab[1]); cfgA0.push(1e3);
        assertGt(_paysV3(ab[1], address(tA), 1e3), 0, "premise: the dust leg pays");
        cfgKnob = ab[0];
        _edgeCase(SMALL, DEEP_L, "1e18 : 1e3 wei");

        _reset();
        cfgP0.push(ab[0]); cfgA0.push(SMALL); cfgP0.push(ab[1]); cfgA0.push(SMALL);
        cfgP1.push(bc0); cfgW1.push(1); cfgP1.push(bc1); cfgW1.push(1);
        cfgKnob = bc0;
        _edgeCase(SMALL, DEEP_L, "2 hops, 2 equal legs each");
        _assertNoDisagreement();
    }

    // ------------------------------------------------------------------ T7

    /// Red at 5bcb81b (NM-002 shape): a V3 leg the frame cannot price (`liquidity() == 0` at its
    /// tick) enters the floor's base at its bound. It fills from `swapLiquidity` and pays 90 % of
    /// its attestation, beside a priced V2 leg; the Router refuses, the door must not encode. Then
    /// the Router's edge on the attestation, by bisection, and the door's parity around it.
    function test_ALegTheFrameCannotPriceEntersTheBaseAtItsBound() public {
        MockV3Pool blind = _v3(tA, tB, 500, 0);
        blind.setSwapLiquidity(DEEP_L);
        MockV2Pair v = _v2(tA, tB, 1e24);
        _reset();
        cfgP0.push(blind);
        cfgA0.push(SMALL);
        (cfgV2, cfgV2Amt) = (v, SMALL / 10);
        cfgKnob = blind;
        cfgKnobIsAttestation = true;
        uint256 paid = _paysV3(blind, address(tA), SMALL);
        assertGt(paid, 0, "premise: the blind leg fills");
        cfgTop = paid * 10 / 9;
        (bool encoded, bool settled, bytes memory ret) = _at(0);
        assertFalse(settled, "premise of the oracle: the Router refuses a leg paying 90 % of its bound");
        _assertRouterE(ret, 5, "90 % of the bound");
        _agree(encoded, settled, "90 % of the bound");
        _edgeCase(0, cfgTop - paid, "attestation edge");
        _assertNoDisagreement();
    }

    // ------------------------------------------------------------------ T8

    /// Green at 5bcb81b (measured 2026-11-16): the door's V2 arm already quotes a pair that
    /// declares reserves above what it holds as dead, so it does not encode one; the Router
    /// refuses it as RouterE(8). Pins the `held` answer the shared frame will carry.
    function test_ADeadPairIsNotEncoded() public {
        MockV2Pair dead = new MockV2Pair(address(tA), address(tB));
        tA.mint(address(dead), 1e24);
        tB.mint(address(dead), 1e23);
        dead.setReserves(uint112(1e24), uint112(1e24));
        hub.seedPool(address(dead), BPC.KIND_V2, 30, address(0), address(tA), address(tB));
        _reset();
        (cfgV2, cfgV2Amt) = (dead, SMALL);
        (bool encoded, bool settled, bytes memory ret) = _at(0);
        assertFalse(settled, "premise of the oracle: the Router refuses the dead pair");
        _assertRouterE(ret, 8, "dead pair");
        assertFalse(encoded, "the door encoded a dead pair");
    }

    // ------------------------------------------------------------------ T14

    /// Control, green at 5bcb81b (red under a door that refuses what the Router settles, M17): a
    /// V2 leg whose input token is taxed (1 % and 10 %) is settled by the Router, which shrinks
    /// its floor by the tax it sees; the door, which sees no tax on either side of its
    /// comparison, still encodes it.
    function test_Control_ATaxedInputPairRouteStillEncodes() public {
        uint16[2] memory taxes = [uint16(100), 1000];
        for (uint256 i; i < 2; ++i) {
            MockERC20 fot = new MockERC20("FOT", "FOT");
            MockV2Pair p = _v2(fot, tB, 1e24);
            fot.setFeeOnTransferBps(taxes[i]);
            _reset();
            cfgIn = fot;
            (cfgV2, cfgV2Amt) = (p, 1e21);
            string memory tag = string.concat("tax bps ", vm.toString(taxes[i]));
            (bool encoded, bool settled, bytes memory ret) = _at(0);
            assertTrue(settled, string.concat(tag, ": premise, the Router settles: ", vm.toString(ret)));
            assertTrue(encoded, string.concat(tag, ": the door refused a route the Router settles"));
        }
    }


    // ------------------------------------------------------------------ Blind hop (Router:1360-1362, 1430-1440)

    /// The Router on `data`, funded with `order` of `tIn`, state restored after.
    function _send(bytes memory data, address tIn, uint256 order) internal returns (bool settled, bytes memory ret) {
        uint256 snap = vm.snapshotState();
        MockERC20(tIn).mint(address(this), order);
        MockERC20(tIn).approve(address(router), order);
        (settled, ret) = address(router).call(data);
        vm.revertToState(snap);
    }

    /// The Router on the plan the config names, as the caller hands it, no door between
    /// (`userMinOut = 1`), its last hop declared at `d` when that hop holds the blind leg.
    function _rawAt(uint256 d) internal returns (bool, bytes memory) {
        cfgDeclared = d;
        (Route memory r, , uint256 order) = _build(0);
        return _send(abi.encodeCall(router.swapExactIn, (r, order, 1, recipient, block.timestamp + 1)), r.hops[0].tokenIn, order);
    }

    /// The door on the same plan, its bytes run on the Router.
    function _doorAt(uint256 d) internal returns (bool encoded, bool settled, bytes memory ret) {
        cfgDeclared = d;
        return _at(0);
    }

    /// A V3 pool the frame cannot price (`liquidity() == 0` at its tick, T7's) filling from `fill`.
    function _blindPool(MockERC20 a, MockERC20 b, uint128 fill) internal returns (MockV3Pool p) {
        p = _v3(a, b, 500, 0);
        p.setSwapLiquidity(fill);
    }

    /// One hop whose only leg, `amt` into `p`, arrives blind: what it pays.
    function _blindHop(MockV3Pool p, uint256 amt) internal returns (uint256 paid) {
        _reset();
        cfgP0.push(p);
        cfgA0.push(amt);
        cfgBlind = p;
        paid = _paysV3(p, address(tA), amt);
        assertGt(paid, 0, "premise: the blind leg fills");
    }

    /// HB1. Red at e731dfc: a last hop whose only leg arrives blind (unattested, and the frame
    /// prices none), its declared figure above what it pays. The Router anchors the protocol
    /// floor on the larger of the hop's base and its declared figure (Router:1430-1432): declared
    /// at twice the fill it refuses (RouterE(5)), declared at the fill it settles, so the refusal
    /// is the anchor's. The door read no declared figure: its base was 0, it asked no floor and
    /// it encoded what the Router refuses. Then the Router's edge on the declared figure, by
    /// bisection (edge settled, edge+1 refused), and the door on both sides of it. Fills of 1e30
    /// and 1e24 liquidity, orders of 1e15, 1e18 and 1e21 wei.
    function test_ABlindLastHopDeclaredAboveTheFill_IsNotEncoded() public {
        uint128[2] memory fills = [uint128(DEEP_L), 1e24];
        uint256[3] memory amts = [uint256(1e15), SMALL, 1e21];
        for (uint256 j; j < fills.length; ++j) {
            MockV3Pool p = _blindPool(tA, tB, fills[j]);
            for (uint256 i; i < amts.length; ++i) {
                uint256 paid = _blindHop(p, amts[i]);
                string memory tag = string.concat("fill L ", vm.toString(uint256(fills[j])), ", order ", vm.toString(amts[i]));
                (bool settled, bytes memory ret) = _rawAt(2 * paid);
                assertFalse(settled, string.concat(tag, ": premise, the Router refuses the hop declared at 2x"));
                _assertRouterE(ret, 5, string.concat(tag, " declared at 2x"));
                (settled, ret) = _rawAt(paid);
                assertTrue(settled, string.concat(tag, ": premise, the Router settles it declared at the fill: ", vm.toString(ret)));
                (bool encoded, , ) = _doorAt(2 * paid);
                _agree(encoded, false, string.concat(tag, " declared at 2x"));
                (uint256 lo, uint256 hi) = (paid, 2 * paid);
                while (hi - lo > 1) {
                    uint256 mid = lo + (hi - lo) / 2;
                    (settled, ) = _rawAt(mid);
                    if (settled) lo = mid;
                    else hi = mid;
                }
                emit log_named_uint(string.concat(tag, " Router edge on the declared figure"), lo);
                (encoded, , ) = _doorAt(lo);
                _agree(encoded, true, string.concat(tag, " declared at the edge"));
                (encoded, , ) = _doorAt(hi);
                _agree(encoded, false, string.concat(tag, " declared at edge+1"));
            }
        }
        _assertNoDisagreement();
    }

    /// HB2. Control, green at e731dfc (red under a door that refuses every blind last hop): the
    /// same hops declared at the fill and at 0 are settled by the Router and encoded by the door.
    function test_ABlindLastHopDeclaredAtTheFill_IsEncodedAndSettles() public {
        uint128[2] memory fills = [uint128(DEEP_L), 1e24];
        uint256[3] memory amts = [uint256(1e15), SMALL, 1e21];
        for (uint256 j; j < fills.length; ++j) {
            MockV3Pool p = _blindPool(tA, tB, fills[j]);
            for (uint256 i; i < amts.length; ++i) {
                uint256 paid = _blindHop(p, amts[i]);
                for (uint256 k; k < 2; ++k) {
                    string memory tag = string.concat("fill L ", vm.toString(uint256(fills[j])), ", order ",
                        vm.toString(amts[i]), k == 0 ? ", declared 0" : ", declared at the fill");
                    (bool encoded, bool settled, bytes memory ret) = _doorAt(k == 0 ? 0 : paid);
                    assertTrue(settled, string.concat(tag, ": settled: ", vm.toString(ret)));
                    assertTrue(encoded, string.concat(tag, ": encoded"));
                }
            }
        }
    }

    /// HB3. Red at e731dfc: a blind leg off the last hop (hop 0 of two). The Router refuses it
    /// outright (Router:1360-1361, RouterE(5)): the floor's base is the last hop's, so nothing
    /// would bound it. The door asked the last hop's floor alone and encoded it. Control: the
    /// same leg attested is encoded and settled.
    function test_ABlindLegOffTheLastHop_IsNotEncoded() public {
        MockV3Pool deep = _v3(tB, tC, 500, DEEP_L);
        uint128[2] memory fills = [uint128(DEEP_L), 1e24];
        for (uint256 j; j < fills.length; ++j) {
            _blindHop(_blindPool(tA, tB, fills[j]), SMALL);
            cfgP1.push(deep);
            cfgW1.push(1);
            string memory tag = string.concat("blind on hop 0, fill L ", vm.toString(uint256(fills[j])));
            (bool settled, bytes memory ret) = _rawAt(0);
            assertFalse(settled, string.concat(tag, ": premise, the Router refuses"));
            _assertRouterE(ret, 5, tag);
            (bool encoded, , ) = _doorAt(0);
            assertFalse(encoded, string.concat(tag, ": encoded, the Router refuses"));
            cfgBlind = MockV3Pool(address(0));
            (encoded, settled, ret) = _doorAt(0);
            assertTrue(settled, string.concat(tag, ", attested: premise, the Router settles: ", vm.toString(ret)));
            assertTrue(encoded, string.concat(tag, ", attested: encoded"));
        }
    }

    /// HB4. Red at e731dfc on the band+1 arm (the Router anchored on the declared figure, the door
    /// did not); red under a door whose declared figure replaces the base instead of raising it
    /// (M32) on the 1-wei arm. T1's priced leg (its fill the knob) beside a blind leg of 1/100 its size,
    /// the hop declared at 1 wei and at the fixture's band quote of the priced leg -1 and +1. At
    /// the Router's edge on the priced leg's fill, by bisection, the door encodes exactly where
    /// the Router settles.
    function test_OnAMixedBlindHopTheDeclaredFigureOnlyRaisesTheBase() public {
        MockV3Pool gap = _v3(tA, tB, 500, DEEP_L);
        MockV3Pool p = _blindPool(tA, tB, DEEP_L);
        uint256 band = _bandV3(gap, address(tA), SMALL);
        uint256[3] memory ds = [uint256(1), band - 1, band + 1];
        for (uint256 i; i < ds.length; ++i) {
            _single(gap, SMALL);
            cfgP0.push(p);
            cfgA0.push(SMALL / 100);
            cfgBlind = p;
            cfgDeclared = ds[i];
            _edgeCase(4.3e18, 99e18, string.concat("mixed hop, declared ", vm.toString(ds[i])));
        }
        _assertNoDisagreement();
    }

    /// HB5. Green at e731dfc (red under a blind predicate that forgets the leg's funding, M33): a
    /// leg the frame cannot price, unattested and funded with 0, beside a priced leg, the hop
    /// declared at twice what it pays. The Router spends nothing on that leg and sees no blind
    /// hop (`scaledAmt != 0`, Router:1360): it settles, and the door encodes.
    function test_AZeroFundedLegIsNotBlind() public {
        MockV3Pool deep = _v3(tA, tB, 500, DEEP_L);
        MockV3Pool p = _blindPool(tA, tB, DEEP_L);
        _reset();
        cfgP0.push(deep);
        cfgA0.push(SMALL);
        cfgP0.push(p);
        cfgA0.push(0);
        cfgBlind = p;
        (bool encoded, bool settled, bytes memory ret) = _doorAt(2 * _paysV3(deep, address(tA), SMALL));
        assertTrue(settled, string.concat("premise, the Router settles: ", vm.toString(ret)));
        assertTrue(encoded, "the door refused a hop the Router sees no blind leg in");
    }

    /// HB6. Fuzz, red at e731dfc where the draw lands above the Router's anchor: one hop, two
    /// hops blind on the last, two hops blind on the first; the fill, the order (1e15 to 1e21
    /// wei) and the declared figure (0 to 4x what the blind hop pays) drawn. The door never
    /// encodes what the Router refuses.
    /// forge-config: default.fuzz.runs = 64
    function testFuzz_TheDoorNeverEncodesWhatTheRouterRefuses_BlindHop(uint256 d, uint256 amt, uint8 shape, bool deep)
        public
    {
        amt = bound(amt, 1e15, 1e21);
        shape %= 3;
        uint128 fill = deep ? DEEP_L : 1e24;
        uint256 paid;
        if (shape == 1) {
            MockV3Pool p0 = _v3(tA, tB, 500, DEEP_L);
            MockV3Pool p1 = _blindPool(tB, tC, fill);
            _reset();
            cfgP0.push(p0);
            cfgA0.push(amt);
            cfgP1.push(p1);
            cfgW1.push(1);
            cfgBlind = p1;
            paid = _paysV3(p1, address(tB), _paysV3(p0, address(tA), amt));
        } else {
            paid = _blindHop(_blindPool(tA, tB, fill), amt);
            if (shape == 2) {
                cfgP1.push(_v3(tB, tC, 500, DEEP_L));
                cfgW1.push(1);
            }
        }
        (bool encoded, bool settled, ) = _doorAt(bound(d, 0, 4 * paid));
        assertFalse(encoded && !settled, "encoded, the Router refuses");
    }
}
