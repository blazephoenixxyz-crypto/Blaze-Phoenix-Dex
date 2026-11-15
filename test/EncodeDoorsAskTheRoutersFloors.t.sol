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
        vm.mockCall(address(solver), abi.encodeWithSelector(solver.findBestRoutePlan.selector), abi.encode(plan));
        (BlazePhoenixQuoter.Preview memory pv, bytes memory data) =
            quoter.previewAndEncodeWithMinOut(address(tA), address(tB), order, 1, recipient, block.timestamp + 1);
        vm.clearMockedCalls();
        encoded = data.length != 0;
        assertEq(pv.canExecute, encoded, "canExecute and bytes agree");
        // The oracle runs on the same route and floor whether or not the door encoded it. The
        // floor a refused door would have encoded is `pv.effectiveMinOut`, max(the caller's floor,
        // `singleOutFloor`): both are 1 here, so the call below is that call.
        if (!encoded) data = abi.encodeCall(router.swapExactIn, (r, order, 1, recipient, block.timestamp + 1));
        tA.mint(address(this), order);
        tA.approve(address(router), order);
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
}
