// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  The encode doors ask the per-leg floor and the hop budget the Router measures (G7 base
//  midtail-3:4, 2026-11-14). Red at 59b7819: `_encode` asked only the delivery under the floor
//  the bytes carry, so a route whose sum cleared that floor came back executable while one of
//  its legs paid under LEG_FLOOR_BPS of its own attestation (`Router._execScaled`, RouterE(5)),
//  or while its legs together bled more than one average leg's slack (`Router._execute`'s hop
//  budget, RouterE(5)). Each fixture sits on exactly one question: the floor the bytes carry
//  (`effectiveMinOut`, Q-out)
//  is 1 wei, every other leg pays its attestation in full.
//  The routes are hand-built and handed to the door as the Solver's plan (a mocked
//  `findBestRoutePlan`); the oracle is the Router's execution of the returned bytes, never the
//  Quoter. Both fee calendars: tokenOut a bridge (the fee off the output) and not (the fee off
//  the input at hop 0, the order sized so the legs are funded at exactly their commitment).
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
import {MockV4TickManager} from "./mocks/MockV4TickManager.sol";
import {MockWETH9} from "./RouterV4NativeEth.t.sol";

contract EncodeDoorsAskTheRoutersFloorsTest is Test {
    uint256 constant BIG = 100e18;
    uint256 constant SMALL = 1e18;
    uint256 constant DEPTH = 1e24;
    uint256 constant COVERAGE_BPS = 5_000;

    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    BlazePhoenixRouter router;
    BlazePhoenixQuoter quoter;
    MockERC20 tA;
    MockERC20 tB;
    MockV2Pair[4] pairs;
    address recipient = makeAddr("recipient");

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        tA = new MockERC20("A", "A");
        tB = new MockERC20("B", "B");
        solver = new BlazePhoenixSolver(address(hub), address(0));
        router = new BlazePhoenixRouter(
            address(hub), address(solver), address(this), makeAddr("treasury1"), makeAddr("treasury2"));
        quoter = new BlazePhoenixQuoter(address(hub), address(solver));
        hub.setRoles(address(router), address(solver), address(this));
        for (uint256 i; i < 4; ++i) {
            // Distinct depths, so no two legs pay the same figure.
            MockV2Pair p = new MockV2Pair(address(tA), address(tB));
            uint256 d = DEPTH + i * 1e23;
            p.setReserves(uint112(d), uint112(d));
            tA.mint(address(p), d);
            tB.mint(address(p), d);
            hub.seedPool(address(p), BPC.KIND_V2, 30, address(0), address(tA), address(tB));
            pairs[i] = p;
        }
    }

    // ---------------------------------------------------------------- fixtures

    /// What pair `i` pays for `legIn`: the venue's own math, read from its reserves.
    function _pays(uint256 i, uint256 legIn) internal view returns (uint256) {
        (uint256 r0, uint256 r1,) = pairs[i].getReserves();
        bool zfo = pairs[i].token0() == address(tA);
        return BPC.outV2(legIn, zfo ? r0 : r1, zfo ? r1 : r0, 30);
    }

    function _route(uint256[] memory ins, uint256[] memory bounds, uint256 paid)
        internal view returns (Route memory r)
    {
        Leg[] memory legs = new Leg[](ins.length);
        uint256 legSum;
        uint256 boundSum;
        for (uint256 i; i < ins.length; ++i) {
            legs[i] = Leg({
                pool: address(pairs[i]), hooks: address(0), kind: BPC.KIND_V2,
                fee: 30, tickSpacing: 0, zeroForOne: pairs[i].token0() == address(tA),
                stable: false, amountIn: ins[i], expectedOut: bounds[i], auxId: bytes32(0)
            });
            legSum += ins[i];
            boundSum += bounds[i];
        }
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({tokenIn: address(tA), tokenOut: address(tB), amountIn: legSum, expectedOut: boundSum, legs: legs});
        r = Route({hops: hops, totalOut: paid, singleOut: 0, singleOutFloor: 1,
                   expectedImpactBps: 0, confidenceWad: 0, estGas: 0, hasSurplus: false, isV4Bundle: false});
    }

    /// The order that funds every leg at exactly its commitment: the legs' sum, plus the input
    /// fee the Router takes at hop 0 on the input calendar (on min(order, legs' sum), rounded up).
    function _order(uint256 legSum, bool feeOnOut) internal pure returns (uint256) {
        return feeOnOut ? legSum : legSum + BPC.mulDivUp(legSum, BPC.PROTOCOL_FEE_BPS, BPC.BPS);
    }

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
        // The oracle runs on the same route and floor whether or not the door encoded it. The
        // floor a refused door would have encoded is `pv.effectiveMinOut`, max(the caller's floor,
        // `singleOutFloor`): both are 1 here, so the call below is that call.
        if (!encoded) data = abi.encodeCall(router.swapExactIn, (r, order, 1, recipient, block.timestamp + 1));
        MockERC20(tIn).mint(address(this), order);
        MockERC20(tIn).approve(address(router), order);
        (settled, ret) = address(router).call(data);
    }

    function _assertRefusedAs5(bytes memory ret) internal pure {
        assertEq(bytes4(ret), BlazePhoenixRouter.RouterE.selector, "refused as RouterE");
        bytes memory t = new bytes(ret.length - 4);
        for (uint256 i; i < t.length; ++i) t[i] = ret[i + 4];
        assertEq(abi.decode(t, (uint256)), 5, "with code 5");
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
            _assertRefusedAs5(ret);
            assertFalse(encoded, string.concat("the door hands back bytes the Router refuses: ", what));
        }
        vm.revertToState(snap);
    }

    function _calendar(bool feeOnOut) internal {
        if (feeOnOut) hub.addBridge(address(tB));
        assertEq(hub.isBridgeToken(address(tB)), feeOnOut, "premise: the calendar");
    }

    // ---------------------------------------------------------------- T3: the per-leg floor

    /// @notice A small leg paid at its floor (`ceil(bound * LEG_FLOOR_BPS / BPS)`), one wei of
    ///         attestation over it, and one wei under it, beside 1-3 big legs paid in full: the
    ///         sum clears the bytes' floor and the hop budget, the small leg alone decides.
    function test_OneLegUnderItsOwnFloor_IsRefusedAtTheDoor_AsTheRouterRefusesIt() public {
        for (uint256 c; c < 2; ++c) {
            uint256 snap = vm.snapshotState();
            bool feeOnOut = c == 1;
            _calendar(feeOnOut);
            for (uint256 n = 2; n <= 4; ++n) _legFloorArms(n, feeOnOut);
            vm.revertToState(snap);
        }
    }

    function _legFloorArms(uint256 n, bool feeOnOut) internal {
        uint256[] memory ins = new uint256[](n);
        uint256[] memory bounds = new uint256[](n);
        uint256 paid;
        uint256 legSum;
        for (uint256 i; i < n; ++i) {
            ins[i] = i == 0 ? SMALL : BIG;
            bounds[i] = _pays(i, ins[i]);
            paid += bounds[i];
            legSum += ins[i];
        }
        uint256 p0 = bounds[0];
        // The largest attestation whose floor the small leg still meets: ceil(0.8 b) <= p0.
        uint256 bMax = BPC.mulDiv(p0, BPC.BPS, BPC.LEG_FLOOR_BPS);
        assertLe(BPC.mulDivUp(bMax, BPC.LEG_FLOOR_BPS, BPC.BPS), p0, "fixture: the floor at bMax is met");
        assertEq(BPC.mulDivUp(bMax, BPC.LEG_FLOOR_BPS, BPC.BPS), p0, "fixture: and met exactly (the `<` arm)");
        assertGt(BPC.mulDivUp(bMax + 1, BPC.LEG_FLOOR_BPS, BPC.BPS), p0, "fixture: one wei over is missed");
        uint256 order = _order(legSum, feeOnOut);
        string memory tag = string.concat("n=", vm.toString(n), feeOnOut ? " fee on output" : " fee on input");
        bounds[0] = bMax - 1;
        _arm(_route(ins, bounds, paid), order, true, string.concat(tag, ", one wei under the floor's edge"));
        bounds[0] = bMax;
        _arm(_route(ins, bounds, paid), order, true, string.concat(tag, ", the small leg pays its floor exactly"));
        bounds[0] = bMax + 1;
        _arm(_route(ins, bounds, paid), order, false, string.concat(tag, ", one wei of attestation over the edge"));
    }

    // ---------------------------------------------------------------- T4: the hop budget

    /// @notice Every leg above its own floor; the last, biggest, attested `d` over what it pays.
    ///         At the largest `d` the hop budget allows (`Σ got + (Σ bound / n_bounded) * 20 %
    ///         >= Σ bound`) the Router settles, one wei over it refuses. A leg that carries no
    ///         attestation and that the frame prices rests on the covered share of its quote: it
    ///         counts in `n` and in `Σ bound`. A leg that spends nothing is the one leg left out
    ///         of `n`; every leg's payment counts in `Σ got`.
    function test_TheHopBudget_IsAskedAtTheDoor_AsTheRouterAsksIt() public {
        for (uint256 c; c < 2; ++c) {
            uint256 snap = vm.snapshotState();
            bool feeOnOut = c == 1;
            _calendar(feeOnOut);
            for (uint256 n = 2; n <= 4; ++n) _hopBudgetArms(n, 0, feeOnOut);
            for (uint256 n = 3; n <= 4; ++n) _hopBudgetArms(n, 1, feeOnOut);
            for (uint256 n = 3; n <= 4; ++n) _hopBudgetArms(n, 2, feeOnOut);
            vm.revertToState(snap);
        }
    }

    function _hopBudgetArms(uint256 n, uint256 mode, bool feeOnOut) internal {
        (uint256[] memory ins, uint256[] memory bounds, uint256 got, uint256 legSum, uint256 d) = _budgetSeed(n, mode);
        uint256 last = bounds[n - 1];
        // The covered share of an odd quote rounds: the arm sees which way.
        if (mode == 1) assertEq(_pays(0, SMALL) % 2, 1, "fixture: the unattested leg's quote is odd");
        // Each leg still meets its own floor at d + 1: the hop budget alone decides.
        assertLe(BPC.mulDivUp(last + d + 1, BPC.LEG_FLOOR_BPS, BPC.BPS), last, "fixture: the last leg's floor holds");
        uint256 order = _order(legSum, feeOnOut);
        string memory tag = string.concat("n=", vm.toString(n),
            mode == 1 ? " (one leg unattested)" : mode == 2 ? " (one leg spends nothing)" : "",
            feeOnOut ? " fee on output" : " fee on input");
        bounds[n - 1] = last + d - 1;
        _arm(_route(ins, bounds, got), order, true, string.concat(tag, ", one wei inside the budget's edge"));
        bounds[n - 1] = last + d;
        _arm(_route(ins, bounds, got), order, true, string.concat(tag, ", at the budget's edge"));
        bounds[n - 1] = last + d + 1;
        _arm(_route(ins, bounds, got), order, false, string.concat(tag, ", one wei past it"));
    }

    /// The legs, their attestations, and the largest `d` the Router's budget allows over the last
    /// one. Mode 1: leg 0 carries no attestation and the frame prices it, so it rests on the
    /// covered share of its quote and counts in `n`. Mode 2: leg 0 spends nothing, the one leg
    /// the Router leaves out of `n`.
    function _budgetSeed(uint256 n, uint256 mode) internal view
        returns (uint256[] memory ins, uint256[] memory bounds, uint256 got, uint256 legSum, uint256 d)
    {
        ins = new uint256[](n);
        bounds = new uint256[](n);
        uint256 bounded;
        uint256 boundBase;
        for (uint256 i; i < n; ++i) {
            ins[i] = (mode != 0 && i == 0) ? (mode == 2 ? 0 : SMALL) : BIG + i * 1e18;
            uint256 p = ins[i] == 0 ? 0 : _pays(i, ins[i]);
            bounds[i] = (mode != 0 && i == 0) ? 0 : p;
            if (ins[i] != 0) {
                ++bounded;
                boundBase += bounds[i] != 0 ? p : BPC.mulDiv(p, COVERAGE_BPS, BPC.BPS);
            }
            got += p;
            legSum += ins[i];
        }
        // The real-valued root of got + s(B + d)/k = B + d (s = 1 - LEG_FLOOR), then one-wei steps.
        d = ((BPC.BPS - BPC.LEG_FLOOR_BPS) * boundBase + (got - boundBase) * bounded * BPC.BPS)
            / (bounded * BPC.BPS - (BPC.BPS - BPC.LEG_FLOOR_BPS));
        while (!_budgetHolds(got, boundBase + d, bounded)) --d;
        while (_budgetHolds(got, boundBase + d + 1, bounded)) ++d;
    }

    /// The hop budget as a fixture seed only (the arms pin it against the Router's execution).
    function _budgetHolds(uint256 got, uint256 boundSum, uint256 bounded) internal pure returns (bool) {
        return got + BPC.mulDiv(boundSum / bounded, BPC.BPS - BPC.LEG_FLOOR_BPS, BPC.BPS) >= boundSum;
    }

    // ---------------------------------------------------------------- T6, T6b: a V4 leg's walk
    //  Red at 5bcb81b. The Router measures a V4 leg in-frame (`_v4LegQuote`, the PoolManager read
    //  with the key execution builds) and rests the leg's bound on the covered share of that walk
    //  when the bytes attest less, as it does for a pair or a concentrated pool; the walk also
    //  enters the protocol floor's base in place of the attestation. The door's `_frameQuote`
    //  prices no V4 kind, so the door's bound for such a leg is its attestation alone.

    uint24 constant FEE4 = 3000;
    int24 constant TS4 = 60;
    uint128 constant V4_DEPTH = 1e22;
    uint128 constant V3_DEPTH = 1e24;
    MockV4TickManager mgr;

    /// One V4 pool on (tIn, tB), or on (ETH, tB) when `native`: one position wide enough that a
    /// SMALL fill stays inside it, the price at tick 0. The singleton is wired into the Hub once.
    function _v4Venue(address tIn, bool native) internal returns (bytes32 pid) {
        if (address(mgr) == address(0)) {
            mgr = new MockV4TickManager();
            hub.setV4Manager(address(mgr));
        }
        address c = native ? address(0) : tIn;
        (address c0, address c1) = c < address(tB) ? (c, address(tB)) : (address(tB), c);
        pid = BPC.computeV4PoolId(c0, c1, FEE4, TS4, address(0));
        mgr.initialize(pid, mgr.sqrtAt(0), 0, FEE4);
        mgr.addPosition(pid, -60000, 60000, TS4, V4_DEPTH);
        hub.addV4(c0, c1, FEE4, TS4, address(0));
        tB.mint(address(mgr), 1e24);
    }

    function _v4Leg(bytes32 pid, address tIn, bool native, uint256 amt, uint256 att)
        internal view returns (Leg memory)
    {
        address c = native ? address(0) : tIn;
        return Leg({
            pool: address(uint160(uint256(pid))), hooks: address(0),
            kind: native ? BPC.KIND_V4_NATIVE : BPC.KIND_V4, fee: FEE4, tickSpacing: TS4,
            zeroForOne: c < address(tB), stable: false, amountIn: amt, expectedOut: att,
            auxId: bytes32(uint256(uint160(address(tB))))
        });
    }

    /// The walk the Router measures for the V4 leg (a fixture input, never the oracle), and what
    /// the pool pays for it by the mock's own specification swap.
    function _v4Walk(Leg memory lg, bytes32 pid, uint256 amt) internal view returns (uint256 w, uint256 g) {
        w = BPC.v4LegOut(address(mgr), pid, amt, FEE4, TS4, lg.zeroForOne);
        (, g, , , ) = mgr.specSwap(pid, amt, FEE4, TS4, lg.zeroForOne);
        assertGt(w, 0, "fixture: the frame prices the V4 leg");
        assertApproxEqAbs(g, w, 4, "premise: the V4 leg pays its walk");
    }

    function _routeOf(Leg[] memory legs, address tIn, uint256 paid) internal view returns (Route memory r) {
        uint256 legSum;
        uint256 attSum;
        for (uint256 i; i < legs.length; ++i) {
            legSum += legs[i].amountIn;
            attSum += legs[i].expectedOut;
        }
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({tokenIn: tIn, tokenOut: address(tB), amountIn: legSum, expectedOut: attSum, legs: legs});
        r = Route({hops: hops, totalOut: paid, singleOut: 0, singleOutFloor: 1,
                   expectedImpactBps: 0, confidenceWad: 0, estGas: 0, hasSurplus: false, isV4Bundle: false});
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

    /// @notice T6. A V4 leg attested one wei under the covered share of its walk, beside a V2
    ///         leg attested `d` over what it pays: the Router's hop budget rests the V4 leg on its
    ///         walk's covered share. At the largest `d` the Router settles (found by bisection
    ///         on the Router's execution) the door encodes; one wei past it the door hands back
    ///         no bytes. Both fee calendars.
    function test_TheHopBudget_RestsAV4LegAttestedUnderHalfItsWalk_OnItsWalk_AsTheRouters() public {
        for (uint256 c; c < 2; ++c) {
            uint256 snap = vm.snapshotState();
            bool feeOnOut = c == 1;
            _calendar(feeOnOut);
            _v4BudgetArms(feeOnOut);
            vm.revertToState(snap);
        }
    }

    function _v4BudgetRoute(Leg memory v4, uint256 g4, uint256 p2, uint256 d) internal view returns (Route memory) {
        Leg[] memory legs = new Leg[](2);
        legs[0] = v4;
        legs[1] = Leg({
            pool: address(pairs[0]), hooks: address(0), kind: BPC.KIND_V2, fee: 30, tickSpacing: 0,
            zeroForOne: pairs[0].token0() == address(tA), stable: false,
            amountIn: BIG, expectedOut: p2 + d, auxId: bytes32(0)
        });
        return _routeOf(legs, address(tA), g4 + p2);
    }

    function _v4BudgetArms(bool feeOnOut) internal {
        bytes32 pid = _v4Venue(address(tA), false);
        Leg memory v4 = _v4Leg(pid, address(tA), false, SMALL, 0);
        (uint256 w, uint256 g4) = _v4Walk(v4, pid, SMALL);
        v4.expectedOut = BPC.mulDiv(w, BPC.MIN_QUOTE_COVERAGE_BPS, BPC.BPS) - 1;
        uint256 p2 = _pays(0, BIG);
        uint256 order = _order(SMALL + BIG, feeOnOut);
        // The edge, by bisection on the Router: lo settles, hi is refused.
        uint256 lo;
        uint256 hi = p2;
        assertTrue(_routerSettles(_v4BudgetRoute(v4, g4, p2, lo), order), "fixture: the Router settles at d = 0");
        assertFalse(_routerSettles(_v4BudgetRoute(v4, g4, p2, hi), order), "fixture: the Router refuses at d = p2");
        while (hi - lo > 1) {
            uint256 mid = (lo + hi) / 2;
            if (_routerSettles(_v4BudgetRoute(v4, g4, p2, mid), order)) lo = mid;
            else hi = mid;
        }
        // The V2 leg still meets its own floor one wei past the edge: the hop budget decides.
        assertLe(BPC.mulDivUp(p2 + lo + 1, BPC.LEG_FLOOR_BPS, BPC.BPS), p2, "fixture: the V2 leg's floor holds");
        string memory tag = string.concat("V4 attested under half its walk", feeOnOut ? ", fee on output" : ", fee on input");
        _arm(_v4BudgetRoute(v4, g4, p2, lo - 1), order, true, string.concat(tag, ", one wei inside the budget's edge"));
        _arm(_v4BudgetRoute(v4, g4, p2, lo), order, true, string.concat(tag, ", at the budget's edge"));
        _arm(_v4BudgetRoute(v4, g4, p2, lo + 1), order, false, string.concat(tag, ", one wei past it"));
    }

    /// @notice T6b. A V4 leg attested at W/2 - 1, W/2, W/2 + 1, 0.9 W and W of its walk W,
    ///         beside a V3 leg that pays what it attests and fills from a shallower liquidity than
    ///         the one the frame reads. The Router's protocol floor rests on the V4 leg's walk
    ///         whatever it attests; its edge, in units of the V3 pool's fill liquidity, is found
    ///         by bisection on the Router. One unit under the edge the door hands back no bytes;
    ///         at the edge and one unit over it the door encodes. ERC20 and native ETH.
    function test_AV4LegEntersTheFloorsBaseAtItsWalk() public {
        for (uint256 k; k < 2; ++k) {
            uint256 snap = vm.snapshotState();
            _v4BaseArms(k == 1);
            vm.revertToState(snap);
        }
    }

    struct BaseCase {
        address tIn;
        bytes32 pid;
        MockV3Pool v3;
        Leg v4;
        uint256 g4;
        uint256 order;
        string tag;
    }

    function _v4BaseArms(bool native) internal {
        BaseCase memory bc;
        bc.tIn = address(tA);
        if (native) {
            MockWETH9 weth = new MockWETH9();
            router.setWeth(address(weth));
            vm.deal(address(weth), 1e24);
            bc.tIn = address(weth);
            assertEq(hub.weth(), router.weth(), "premise: the door reads the Router's WETH");
        }
        bc.pid = _v4Venue(bc.tIn, native);
        bc.v3 = new MockV3Pool(bc.tIn, address(tB), 500);
        bc.v3.setState(uint160(BPC.Q96), V3_DEPTH);
        tB.mint(address(bc.v3), 1e30);
        hub.seedPool(address(bc.v3), BPC.KIND_V3, 500, address(0), bc.tIn, address(tB));
        bc.v4 = _v4Leg(bc.pid, bc.tIn, native, SMALL, 0);
        uint256 w;
        (w, bc.g4) = _v4Walk(bc.v4, bc.pid, SMALL);
        bc.order = _order(SMALL + BIG, false);
        uint256[5] memory atts = [w / 2 - 1, w / 2, w / 2 + 1, BPC.mulDiv(w, 9, 10), w];
        // One bisection, at the lowest attestation: the Router's base is the walk whatever the
        // leg attests, so every other attestation's arms are pinned by the Router at the same
        // edge (an attestation that moved it fails its arm's premise).
        bc.v4.expectedOut = atts[0];
        (uint128 lo, uint128 hi) = _v4BaseBisect(bc);
        for (uint256 i; i < atts.length; ++i) {
            bc.v4.expectedOut = atts[i];
            bc.tag = string.concat(native ? "native" : "ERC20", ", V4 attests ", vm.toString(atts[i]),
                " of a walk of ", vm.toString(w));
            _v4BaseEdge(bc, lo, hi);
        }
    }

    function _v3Leg(BaseCase memory bc, uint256 att) internal view returns (Leg memory) {
        return Leg({
            pool: address(bc.v3), hooks: address(0), kind: BPC.KIND_V3, fee: 500, tickSpacing: 1,
            zeroForOne: bc.v3.token0() == bc.tIn, stable: false,
            amountIn: BIG, expectedOut: att, auxId: bytes32(0)
        });
    }

    /// What the V3 leg pays at fill liquidity `l`: the mock fills by the Core's single-tick math.
    function _v3Pays(BaseCase memory bc, uint128 l) internal view returns (uint256) {
        return BPC.outV3(BIG, bc.v3.sqrtPriceX96(), l, 500, bc.v3.token0() == bc.tIn, 0);
    }

    /// The V3 leg filling from `l`, attesting what it pays; the V4 leg as `bc` attests it.
    function _v4BaseRoute(BaseCase memory bc, uint128 l) internal returns (Route memory) {
        bc.v3.setSwapLiquidity(l);
        uint256 p3 = _v3Pays(bc, l);
        Leg[] memory legs = new Leg[](2);
        legs[0] = bc.v4;
        legs[1] = _v3Leg(bc, p3);
        return _routeOf(legs, bc.tIn, bc.g4 + p3);
    }

    /// The smallest fill liquidity the Router settles (`hi`), one unit under it refused (`lo`).
    function _v4BaseBisect(BaseCase memory bc) internal returns (uint128 lo, uint128 hi) {
        lo = uint128(BIG);
        hi = V3_DEPTH;
        assertFalse(_routerSettles(_v4BaseRoute(bc, lo), bc.order), string.concat("fixture: refused at the low end, ", bc.tag));
        assertTrue(_routerSettles(_v4BaseRoute(bc, hi), bc.order), string.concat("fixture: settles at the frame's depth, ", bc.tag));
        while (hi - lo > 1) {
            uint128 mid = lo + (hi - lo) / 2;
            if (_routerSettles(_v4BaseRoute(bc, mid), bc.order)) hi = mid;
            else lo = mid;
        }
    }

    function _v4BaseEdge(BaseCase memory bc, uint128 lo, uint128 hi) internal {
        // Under the edge only the protocol floor is left to refuse: each leg meets its own floor
        // (bound = max(attestation, covered share of the frame's quote)) and the hop pays at
        // least its bounds.
        (uint256 q3, , ) = BPC.legQuoteImpact(_v3Leg(bc, 0), bc.tIn, address(tB), BIG);
        uint256 p3 = _v3Pays(bc, lo);
        uint256 cov3 = BPC.mulDiv(q3, BPC.MIN_QUOTE_COVERAGE_BPS, BPC.BPS);
        assertGe(p3, BPC.mulDivUp(p3 > cov3 ? p3 : cov3, BPC.LEG_FLOOR_BPS, BPC.BPS), "fixture: the V3 leg's floor holds");
        uint256 b4 = bc.v4.expectedOut;
        {
            uint256 w = BPC.v4LegOut(address(mgr), bc.pid, SMALL, FEE4, TS4, bc.v4.zeroForOne);
            uint256 cov4 = BPC.mulDiv(w, BPC.MIN_QUOTE_COVERAGE_BPS, BPC.BPS);
            if (b4 < cov4) b4 = cov4;
        }
        assertGe(bc.g4, BPC.mulDivUp(b4, BPC.LEG_FLOOR_BPS, BPC.BPS), "fixture: the V4 leg's floor holds");
        assertTrue(_budgetHolds(bc.g4 + p3, b4 + p3, 2), "fixture: the hop budget holds");
        _arm(_v4BaseRoute(bc, lo), bc.order, false, string.concat(bc.tag, ", one unit under the floor's edge"));
        _arm(_v4BaseRoute(bc, hi), bc.order, true, string.concat(bc.tag, ", at the floor's edge"));
        _arm(_v4BaseRoute(bc, hi + 1), bc.order, true, string.concat(bc.tag, ", one unit over it"));
    }
}
