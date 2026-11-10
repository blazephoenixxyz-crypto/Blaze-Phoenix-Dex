// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  A SOLVE BUILDS EACH PAIR'S CANDIDATE LIST ONCE.
//
//  A build (`_topKPools`: the registry read, its freshness gate, the discovery
//  sweep, the fitness batch) is a function of the state and the ordered pair, and
//  the solve is a static call, so a second build of a pair can only return the
//  list the first one returned. `_candsOf` keeps one list per ordered pair for
//  each frame of the solve: the judgement, and the rebuild of its leader (a static
//  self-call, which starts with no list). 5.1 census on Base: AERO>AAVE built
//  eleven lists over seven pairs; -17.7 % of the swap's gas once kept.
//
//  1. The census of the judgement (red before the fix): `Hub.getActivePools`, the
//     first read of every build and made by no other step of the solve, is asked
//     once per ordered pair. Three bridges and a pool on every pair: the direct
//     route and three two-hop routes, seven pairs, seven reads.
//  2. The census of the rebuild: the leader's pair is read when the book that fell
//     is taken off its list and each time the leader is built again. It is built
//     once.
//  3. Every read starts from the list as built. `_buildHop` compacts the array it
//     is handed in place (the band filter drops a pool off the base's price), so a
//     list handed out twice reaches the next build with the dropped pool gone.
//     Here the leader seats a book that sits its rebuild out. With the book the
//     band stands on the book's price and drops the two pairs priced below it;
//     without it the band stands on those two, the list's last seat included. The
//     rebuild's route is the route of the same world without the book, leg for leg.
//
//  History: the fixtures drew three-hop routes (thirteen topologies, thirteen
//  pairs; a pair read by a two-hop and by a three-hop route) until a route's
//  ceiling came down to MAX_HOPS = 2 on 2026-11-06. No two topologies of one
//  judgement share a pair since then: the pair read again is the rebuild's, and
//  cases 2 and 3 are stated there since 2026-11-10.
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixCore as BPC, RoutePlan, Hop} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";
import {MockV3TickPool} from "./mocks/MockV3TickPool.sol";

abstract contract SolveWorld is Test {
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    MockERC20 tA;
    MockERC20 tB;
    MockERC20 b0;
    MockERC20 b1;
    MockERC20 b2;

    uint256 constant AMT = 1_000e18;

    function _world() internal {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0xBEEF));
        solver = new BlazePhoenixSolver(address(hub), address(0));
        hub.setRoles(address(this), address(solver), address(this));
        tA = new MockERC20("A", "A");
        tB = new MockERC20("B", "B");
        b0 = new MockERC20("B0", "B0");
        b1 = new MockERC20("B1", "B1");
        b2 = new MockERC20("B2", "B2");
    }

    /// The census of one solve: how often `Hub.getActivePools` was asked for an ordered pair, in
    /// each frame of the solve (the judgement is frame 0, each rebuild a frame of its own).
    /// `walks` rebuilds, `lists` (frame, pair) entries, `reads` reads in all, `most` the reads of
    /// the entry read most.
    function _census(address tIn, address tOut, uint256 amt)
        internal returns (uint256 walks, uint256 lists, uint256 reads, uint256 most)
    {
        vm.startStateDiffRecording();
        RoutePlan memory plan = solver.findBestRoutePlan(tIn, tOut, amt);
        VmSafe.AccountAccess[] memory recs = vm.stopAndReturnStateDiff();
        assertGt(plan.best.totalOut, 0, "fixture: there is a plan");

        bytes32[] memory seen = new bytes32[](recs.length);
        uint256[] memory times = new uint256[](recs.length);
        uint64 inner;
        for (uint256 r; r < recs.length; ++r) {
            VmSafe.AccountAccess memory a = recs[r];
            if (a.kind == VmSafe.AccountAccessKind.Resume) continue;
            if (a.accessor == address(solver) && a.account == address(solver)) { ++walks; inner = a.depth; continue; }
            if (a.account != address(hub) || a.data.length < 68) continue;
            if (bytes4(a.data) != BlazePhoenixHub.getActivePools.selector) continue;
            ++reads;
            bytes memory d = a.data;
            bytes32 pair;
            assembly { pair := keccak256(add(d, 36), 64) }
            bytes32 key = keccak256(abi.encode(walks != 0 && a.depth > inner ? walks : 0, pair));
            uint256 w;
            while (w < lists && seen[w] != key) ++w;
            if (w == lists) { seen[lists] = key; ++lists; }
            if (++times[w] > most) most = times[w];
        }
        emit log_named_uint("rebuilds", walks);
        emit log_named_uint("getActivePools reads", reads);
        emit log_named_uint("lists (frame, ordered pair)", lists);
    }

    /// A V2 pool holding `rx` of x and `ry` of y, whichever sorts first.
    function _pool(MockERC20 x, MockERC20 y, uint256 rx, uint256 ry, uint24 fee) internal returns (address) {
        MockV2Pair p = new MockV2Pair(address(x), address(y));
        x.mint(address(p), rx);
        y.mint(address(p), ry);
        if (address(x) < address(y)) p.setReserves(uint112(rx), uint112(ry));
        else p.setReserves(uint112(ry), uint112(rx));
        hub.seedPool(address(p), BPC.KIND_V2, fee, address(0), address(x), address(y));
        return address(p);
    }
}

contract SolveBuildsEachPairOnceTest is SolveWorld {
    function setUp() public {
        _world();
        hub.addBridge(address(b0));
        hub.addBridge(address(b1));
        hub.addBridge(address(b2));
        MockERC20[3] memory bs = [b0, b1, b2];
        _pool(tA, tB, 1_000_000e18, 1_000_000e18, 30);
        for (uint256 i; i < 3; ++i) {
            _pool(tA, bs[i], 1_000_000e18, 1_000_000e18, 30);
            _pool(bs[i], tB, 1_000_000e18, 1_000_000e18, 30);
        }
    }

    function test_EachOrderedPairIsBuiltOnce() public {
        (uint256 walks, uint256 lists, uint256 reads, uint256 most) = _census(address(tA), address(tB), AMT);
        assertEq(walks, 0, "fixture: no rebuild (V2 only), the census is the judgement's own");
        assertEq(lists, 7, "fixture: every topology builds every stage (7 ordered pairs)");
        assertEq(most, 1, "an ordered pair's candidate list was built twice");
        assertEq(reads, 7, "seven builds, one per ordered pair");
    }
}

contract TheRebuildStartsFromTheListAsBuiltTest is SolveWorld {
    MockV3TickPool book;
    address thin;
    address deep;
    address last;

    uint256 constant ORDER = 1e18;     // leaves the book's range around the price

    function setUp() public {
        _world();
        thin = _pool(tA, tB, 0.2e18, 0.2e18, 30);    // on the book's price
        deep = _pool(tA, tB, 1.25e18, 1e18, 30);   // 20 % below it: off the band the book stands on
        last = _pool(tA, tB, 0.125e18, 0.1e18, 30); // at the deep pair's price, in the list's last seat
    }

    /// The book: a thick range ending one tick ahead of the order and a thin one beyond it, so the
    /// band promises what the walk does not pay and the book falls; it holds little of its output,
    /// so its promise is held at the cap.
    function _seedBook() internal {
        bool zfo = address(tA) < address(tB);
        book = new MockV3TickPool(address(tA), address(tB), 3000, 60);
        book.initialize(zfo ? int24(1) : int24(59));
        book.addPosition(0, 60, 1e19);
        book.addPosition(-887220, 887220, 1e17);
        tA.mint(address(book), 1e21);
        tB.mint(address(book), 2e18);
        hub.seedPool(address(book), BPC.KIND_V3, 3000, address(0), address(tA), address(tB));
    }

    function test_TheRebuildBuildsItsPairOnce() public {
        _seedBook();
        (uint256 walks, uint256 lists, uint256 reads, uint256 most) = _census(address(tA), address(tB), ORDER);
        assertEq(walks, 1, "fixture: the leader is rebuilt");
        assertEq(lists, 2, "fixture: the one pair, in the judgement and in the rebuild");
        assertEq(most, 1, "an ordered pair's candidate list was built twice in one frame");
        assertEq(reads, 2, "two builds, one per frame");
    }

    function test_TheRebuildStartsFromTheListAsBuilt() public {
        RoutePlan memory alone = solver.findBestRoutePlan(address(tA), address(tB), ORDER);
        assertEq(alone.best.hops.length, 1, "fixture: the route is direct");
        Hop memory a = alone.best.hops[0];
        // The seats: fitness never rises down the list and the selection sort keeps the earlier
        // row on a tie, so the small pair at the deep one's price, registered last, sits last.
        address[] memory pls = new address[](3);
        address[] memory t0s = new address[](3);
        address[] memory t1s = new address[](3);
        (address t0, address t1) = address(tA) < address(tB) ? (address(tA), address(tB)) : (address(tB), address(tA));
        (pls[0], pls[1], pls[2]) = (deep, thin, last);
        for (uint256 i; i < 3; ++i) (t0s[i], t1s[i]) = (t0, t1);
        uint256[] memory ps = hub.psisOf(pls, t0s, t1s);
        assertTrue(ps[0] >= ps[1] && ps[1] >= ps[2], "fixture: the funnel would reseat the three pairs");
        // Without the book the band stands on the deep pair: the thin one is off it, and the two
        // at its price take a leg each, the list's last seat included.
        assertEq(a.legs.length, 2, "a read of the list lost a row");
        bool onDeep;
        bool onLast;
        for (uint256 i; i < 2; ++i) {
            if (a.legs[i].pool == deep) onDeep = true;
            if (a.legs[i].pool == last) onLast = true;
        }
        assertTrue(onDeep, "fixture: without the book the deep pair takes a leg");
        assertTrue(onLast, "the list's last pool took no leg");

        _seedBook();
        (uint256 walks, , , ) = _census(address(tA), address(tB), ORDER);
        assertEq(walks, 1, "fixture: the book leads and is rebuilt");
        RoutePlan memory plan = solver.findBestRoutePlan(address(tA), address(tB), ORDER);
        assertEq(plan.best.hops.length, 1, "the rebuild's route is not direct");
        Hop memory b = plan.best.hops[0];
        assertEq(b.legs.length, a.legs.length, "the rebuild did not start from the list as built");
        for (uint256 i; i < a.legs.length; ++i) {
            assertEq(b.legs[i].pool, a.legs[i].pool, "a leg moved to another pool");
            assertEq(b.legs[i].amountIn, a.legs[i].amountIn, "a leg's share moved");
            assertEq(b.legs[i].expectedOut, a.legs[i].expectedOut, "a leg's promise moved");
        }
        assertEq(b.amountIn, a.amountIn, "the two hops spend different inputs");
        assertEq(b.expectedOut, a.expectedOut, "the two hops promise different outputs");
        assertEq(plan.best.totalOut, alone.best.totalOut, "the two routes promise different outputs");
    }
}
