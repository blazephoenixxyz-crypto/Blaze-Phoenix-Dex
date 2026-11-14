// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  WHAT A QUOTE AND A SOLVE COST, PINNED.
//
//  The Quoter's quote doors and the Solver on its own, on the V2 worlds the quote
//  statistics already use:
//  - `QuoteWorld._world(seedRegistry)`: B is the one bridge, A -> B is one hop and
//    A -> B -> C two. Seeded, the A/B pair holds three fresh curated rows (AB1-AB3),
//    so `_registryFresh` skips the discovery sweep there; B/C holds one row and sweeps.
//    Empty, the registry holds nothing and the sweep finds the factory's pools alone
//    (AB1, BC1). The two worlds differ by the A/B candidates (three against one) as
//    well as by the sweep.
//  - `SolveWorld` (the census fixture of SolveBuildsEachPairOnce.t.sol) for the
//    Solver's scaling in candidate pools and in bridges.
//  `QuoterGasStatistics` logs previewPlan / previewAndEncode over forty amounts and
//  batchQuote at ten entries. This file pins those doors (and the others) and
//  batchQuote in N; it does not repeat that file's same-answer assert.
//
//  THE INSTRUMENT:
//  - Every budget is the measured snapshot itself: `vm.snapshotGasLastFrame`
//    right after the door call reads that call's own frame, so nothing of the
//    test's frame is in it, and writes it to snapshots/<group>.json. No ceiling
//    is set by hand. The gate is equality: with FORGE_SNAPSHOT_CHECK=true any
//    window that moves, up or down, fails the run while every assert still
//    passes. A change meant to move gas regenerates the files in the same commit.
//  - One group per test function, named after it: a partial run (`--match-test`,
//    as the mutation guard runs) rewrites the groups it ran, and only those.
//  - Both contracts run in isolation mode (`isolate = true` in foundry.toml,
//    asserted in setUp). A door that is not `view` (previewAndEncode*,
//    previewPlanExact, previewRouteExact) is then its own transaction and its
//    entry carries the intrinsic cost (21 000 + calldata): those entries end in
//    `_tx`. A `view` door is a STATICCALL: it carries none, and it finds every
//    account and slot cold again.
//  - The asserts are the fixture's own answers (it quotes, its hop count, the
//    floor it was given), never a gas figure.
//
//  forge test --match-path test/gas/QuoteSolveGas.t.sol
//  FORGE_SNAPSHOT_CHECK=true forge test --match-path test/gas/QuoteSolveGas.t.sol
// =============================================================================

import {QuoteWorld, BlazePhoenixQuoter} from "../QuoteWorld.sol";
import {SolveWorld} from "../SolveBuildsEachPairOnce.t.sol";
import {RoutePlan, Route, Hop} from "../../src/BlazePhoenixCore.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

contract QuoteModeGasTest is QuoteWorld {
    /// The order: a tenth of the A side of the shallowest A/B pool (AB1 holds 100_000e18 A),
    /// deep enough that the plan splits the hop (asserted where a window depends on it).
    uint256 constant AMT = 100_000e18 / 10;

    function setUp() public {
        assertTrue(vm.isIsolateMode(), "the windows need isolate: each top-level call is its own transaction");
    }

    // -------------------------------------------------------------------------
    //  previewPlan: the registry switch (view)
    // -------------------------------------------------------------------------

    /// One hop, A -> B, in both worlds. Seeded, the A/B registry is fresh and the sweep is
    /// skipped; empty, the sweep finds AB1 alone. Seeded, the plan also has AB2 and AB3 to
    /// split over, so the two windows differ by the split as well as by the sweep.
    function test_Gas_PreviewPlan_OneHop_EmptyVsSeeded() public {
        _emptyVsSeeded("test_Gas_PreviewPlan_OneHop_EmptyVsSeeded", false);
    }

    /// Two hops, A -> B -> C, in both worlds. Seeded, A/B skips the sweep and B/C, one row
    /// under MIN_FRESH_VENUES, is not fresh and sweeps; empty, every pair sweeps.
    function test_Gas_PreviewPlan_TwoHops_EmptyVsSeeded() public {
        _emptyVsSeeded("test_Gas_PreviewPlan_TwoHops_EmptyVsSeeded", true);
    }

    function _emptyVsSeeded(string memory g, bool twoHops) private {
        uint256 hops = twoHops ? 2 : 1;
        _world(false);
        BlazePhoenixQuoter.Preview memory e = _previewWindow(g, "empty", twoHops);
        _world(true);
        BlazePhoenixQuoter.Preview memory s = _previewWindow(g, "seeded", twoHops);
        assertEq(e.hops, hops, "fixture: the empty world plans the expected hops");
        assertEq(s.hops, hops, "fixture: the seeded world plans the expected hops");
    }

    function _previewWindow(string memory g, string memory name, bool twoHops)
        private returns (BlazePhoenixQuoter.Preview memory pv)
    {
        address tOut = twoHops ? address(C) : address(B);
        (pv, , ) = quoter.previewPlan(address(A), tOut, AMT);
        vm.snapshotGasLastFrame(g, name);
        assertTrue(pv.canExecute, "fixture: the world quotes the pair");
    }

    // -------------------------------------------------------------------------
    //  previewAndEncode (not view): the preview, then `_encode` asks `_fundedOut`
    // -------------------------------------------------------------------------

    function test_Gas_PreviewAndEncode_OneAndTwoHops() public {
        string memory g = "test_Gas_PreviewAndEncode_OneAndTwoHops";
        _world(true);
        _encodeWindow(g, "oneHop_tx", address(B), 1);
        _encodeWindow(g, "twoHops_tx", address(C), 2);
    }

    function _encodeWindow(string memory g, string memory name, address tOut, uint256 hops) private {
        (BlazePhoenixQuoter.Preview memory pv, bytes memory call) =
            quoter.previewAndEncode(address(A), tOut, AMT, user, block.timestamp);
        vm.snapshotGasLastFrame(g, name);
        assertTrue(pv.canExecute && call.length > 0, "fixture: the door encodes the swap");
        assertEq(pv.hops, hops, "fixture: the encoded route has the expected hops");
    }

    // -------------------------------------------------------------------------
    //  The floor doors: a floor the route meets, and one wei above it
    // -------------------------------------------------------------------------

    /// `_pack` refuses a floor above netOut before it walks the route's shape
    /// (`_hookRefusedIn` reads each leg's pool), so the two windows differ by that walk.
    function test_Gas_PreviewPlanWithMinOut_OneHop() public {
        string memory g = "test_Gas_PreviewPlanWithMinOut_OneHop";
        _world(true);
        BlazePhoenixQuoter.Preview memory pv = _plan(address(B));
        (BlazePhoenixQuoter.Preview memory met, , ) =
            quoter.previewPlanWithMinOut(address(A), address(B), AMT, pv.netOut);
        vm.snapshotGasLastFrame(g, "floorMet");
        (BlazePhoenixQuoter.Preview memory above, , ) =
            quoter.previewPlanWithMinOut(address(A), address(B), AMT, pv.netOut + 1);
        vm.snapshotGasLastFrame(g, "floorAbove");
        assertTrue(met.canExecute, "fixture: a floor at the plan's own netOut is met");
        assertFalse(above.canExecute, "fixture: a floor one wei above the plan's netOut is refused");
        // netOut >= ironFloor (the plan executes), so netOut + 1 is the floor that binds.
        assertEq(above.effectiveMinOut, pv.netOut + 1, "fixture: the caller's floor binds");
    }

    /// `_encode` asks `_fundedOut` only while the preview can execute, so a refused floor
    /// skips it and encodes no bytes. Here `_fundedOut` is one fee-calendar question: a
    /// direct route into the bridge pays on its output.
    function test_Gas_PreviewAndEncodeWithMinOut_OneHop() public {
        string memory g = "test_Gas_PreviewAndEncodeWithMinOut_OneHop";
        _world(true);
        BlazePhoenixQuoter.Preview memory pv = _plan(address(B));
        (BlazePhoenixQuoter.Preview memory met, bytes memory callMet) =
            quoter.previewAndEncodeWithMinOut(address(A), address(B), AMT, pv.netOut, user, block.timestamp);
        vm.snapshotGasLastFrame(g, "floorMet_tx");
        (BlazePhoenixQuoter.Preview memory above, bytes memory callAbove) =
            quoter.previewAndEncodeWithMinOut(address(A), address(B), AMT, pv.netOut + 1, user, block.timestamp);
        vm.snapshotGasLastFrame(g, "floorAbove_tx");
        assertTrue(met.canExecute && callMet.length > 0, "fixture: a floor at netOut is encoded");
        assertTrue(!above.canExecute && callAbove.length == 0, "fixture: a floor above netOut encodes nothing");
    }

    // -------------------------------------------------------------------------
    //  previewRoute (view): `_pack` alone, no Solver
    // -------------------------------------------------------------------------

    /// A single hop never asks the fee calendar (`_pack`: only at two hops or more).
    function test_Gas_PreviewRoute_OneHop() public {
        string memory g = "test_Gas_PreviewRoute_OneHop";
        _world(true);
        BlazePhoenixQuoter.Preview memory pv = _plan(address(B));
        BlazePhoenixQuoter.Preview memory again = quoter.previewRoute(pv.route, 0);
        vm.snapshotGasLastFrame(g, "oneHop");
        assertTrue(again.canExecute, "fixture: the plan's own route previews executable");
        assertEq(again.netOut, pv.netOut, "fixture: the plan's own route packs the plan's preview");
    }

    // -------------------------------------------------------------------------
    //  The exact doors (not view): the dry-run re-pricing
    // -------------------------------------------------------------------------

    /// `_exact` asks the fee calendar only at two hops or more, prices every leg, then
    /// `_fundedOut`, `_hookRefusedIn` and `_poolTwiceInAHop`.
    function test_Gas_PreviewPlanExact_OneAndTwoHops() public {
        string memory g = "test_Gas_PreviewPlanExact_OneAndTwoHops";
        _world(true);
        _exactWindow(g, "oneHop_tx", address(B), 1);
        _exactWindow(g, "twoHops_tx", address(C), 2);
    }

    function _exactWindow(string memory g, string memory name, address tOut, uint256 hops) private {
        (Route memory r, uint256 exactOut) = quoter.previewPlanExact(address(A), tOut, AMT);
        vm.snapshotGasLastFrame(g, name);
        assertGt(exactOut, 0, "fixture: the exact door prices the plan");
        assertEq(r.hops.length, hops, "fixture: the exact route has the expected hops");
    }

    /// The same re-pricing on the plan's own route, handed in: no Solver. The hop is split,
    /// so `_poolTwiceInAHop` compares legs (each unordered pair once).
    function test_Gas_PreviewRouteExact_OneHop() public {
        string memory g = "test_Gas_PreviewRouteExact_OneHop";
        _world(true);
        BlazePhoenixQuoter.Preview memory pv = _plan(address(B));
        assertGt(pv.route.hops[0].legs.length, 1, "fixture: the plan splits the hop");
        (, uint256 exactOut) = quoter.previewRouteExact(pv.route, AMT);
        vm.snapshotGasLastFrame(g, "oneHop_tx");
        assertGt(exactOut, 0, "fixture: the exact door prices the route");
    }

    // -------------------------------------------------------------------------
    //  batchQuote (view) in N: one solve and one `_pack` per entry
    // -------------------------------------------------------------------------

    function test_Gas_BatchQuote_N1_N2_N4_N8() public {
        string memory g = "test_Gas_BatchQuote_N1_N2_N4_N8";
        _world(true);
        uint256 out1;
        for (uint256 n = 1; n <= 8; n *= 2) {
            BlazePhoenixQuoter.BatchEntry[] memory e = new BlazePhoenixQuoter.BatchEntry[](n);
            for (uint256 i; i < n; ++i) {
                e[i] = BlazePhoenixQuoter.BatchEntry({tIn: address(A), tOut: address(B), amountIn: AMT, userMinOut: 0});
            }
            string memory name = string.concat("n", vm.toString(n));
            BlazePhoenixQuoter.Preview[] memory pvs = quoter.batchQuote(e);
            vm.snapshotGasLastFrame(g, name);
            if (n == 1) out1 = pvs[0].grossOut;
            for (uint256 i; i < n; ++i) {
                assertTrue(pvs[i].canExecute, "fixture: every entry quotes");
                // n = 1 sets out1; from n = 2 on, every entry answers what that one did.
                if (n > 1) assertEq(pvs[i].grossOut, out1, "fixture: identical entries, identical answers");
            }
        }
    }

    // -------------------------------------------------------------------------
    //  feeCalendarOf and the bridge views (view)
    // -------------------------------------------------------------------------

    /// `BPC.feeCalendar` asks the Hub one bridge question per hop up to the first bridged
    /// input, and asks about `tokenOut` only for a single hop.
    function test_Gas_FeeCalendarOf_And_BridgeViews() public {
        string memory g = "test_Gas_FeeCalendarOf_And_BridgeViews";
        _world(true);
        Hop[] memory one = _plan(address(B)).route.hops;
        Hop[] memory two = _plan(address(C)).route.hops;
        (uint256 h1, bool o1) = quoter.feeCalendarOf(one, address(B));
        vm.snapshotGasLastFrame(g, "feeCalendarOf_oneHop");
        (uint256 h2, bool o2) = quoter.feeCalendarOf(two, address(C));
        vm.snapshotGasLastFrame(g, "feeCalendarOf_twoHops");
        address first = quoter.bridgeAt(0);
        vm.snapshotGasLastFrame(g, "bridgeAt");
        uint8 count = quoter.bridgesCount();
        vm.snapshotGasLastFrame(g, "bridgesCount");
        bool isB = quoter.isBridge(address(B));
        vm.snapshotGasLastFrame(g, "isBridge");
        // The fixture's answers: B is the one bridge.
        assertEq(h1, type(uint256).max, "fixture: A -> B has no bridged input");
        assertTrue(o1, "fixture: a direct route into a bridge pays on its output");
        assertEq(h2, 1, "fixture: A -> B -> C anchors on hop 1, whose input is B");
        assertFalse(o2, "fixture: a two-hop route never pays on its output");
        assertEq(first, address(B), "fixture: bridge 0 is B");
        assertEq(count, 1, "fixture: one bridge");
        assertTrue(isB, "fixture: B is a bridge");
    }

    function _plan(address tOut) private view returns (BlazePhoenixQuoter.Preview memory pv) {
        (pv, , ) = quoter.previewPlan(address(A), tOut, AMT);
        assertTrue(pv.canExecute, "fixture: the pair quotes");
    }
}

contract SolverAloneGasTest is SolveWorld {
    /// The census fixture's depth, on every pool (SolveBuildsEachPairOnce.t.sol).
    uint256 constant DEPTH = 1_000_000e18;

    function setUp() public {
        assertTrue(vm.isIsolateMode(), "the windows need isolate: each top-level call is its own transaction");
        _world();
    }

    /// tA -> tB on 1, 2, 4 and 8 equal pools, no bridge. Under MIN_FRESH_VENUES curated rows
    /// the registry is not fresh and the Hub is asked for its sweep (`discoverFor`; this world
    /// adds no factory); from there `_registryFresh` reads one slot per row and stops once
    /// MIN_FRESH_VENUES are fresh. Every row is merged, scored in one `psisOf` batch and sorted.
    function test_Gas_FindBestRoutePlan_PerCandidatePools_1_2_4_8() public {
        string memory g = "test_Gas_FindBestRoutePlan_PerCandidatePools_1_2_4_8";
        uint256 have;
        for (uint256 n = 1; n <= 8; n *= 2) {
            for (; have < n; ++have) _pool(tA, tB, DEPTH, DEPTH, 30);
            RoutePlan memory plan = _solveWindow(g, string.concat("pools", vm.toString(n)));
            assertEq(plan.best.hops.length, 1, "fixture: no bridge, one hop");
        }
    }

    /// tA -> tB with 1, 2 and 3 bridges, a pool on every pair. At three bridges this is the
    /// pool set of the census in SolveBuildsEachPairOnce.t.sol (thirteen topologies, thirteen
    /// ordered pairs), where `_candsOf` is shown to build each ordered pair once.
    function test_Gas_FindBestRoutePlan_PerBridges_1_2_3() public {
        string memory g = "test_Gas_FindBestRoutePlan_PerBridges_1_2_3";
        MockERC20[3] memory bs = [b0, b1, b2];
        _pool(tA, tB, DEPTH, DEPTH, 30);
        for (uint256 i; i < 3; ++i) {
            hub.addBridge(address(bs[i]));
            _pool(tA, bs[i], DEPTH, DEPTH, 30);
            _pool(bs[i], tB, DEPTH, DEPTH, 30);
            for (uint256 j; j < i; ++j) _pool(bs[j], bs[i], DEPTH, DEPTH, 30);
            _solveWindow(g, string.concat("bridges", vm.toString(i + 1)));
        }
    }

    function _solveWindow(string memory g, string memory name) private returns (RoutePlan memory plan) {
        plan = solver.findBestRoutePlan(address(tA), address(tB), AMT);
        vm.snapshotGasLastFrame(g, name);
        assertGt(plan.best.totalOut, 0, "fixture: there is a plan");
    }
}
