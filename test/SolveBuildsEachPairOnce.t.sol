// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  A SOLVE BUILDS EACH PAIR'S CANDIDATE LIST ONCE.
//
//  The thirteen topologies share pairs: tIn -> bA opens topology 1 + A and the
//  two three-hop routes that start on bA, bB -> tOut closes topology 1 + B and
//  the two that end on bB. A build (`_topKPools`: the registry read, its
//  freshness gate, the discovery sweep, the fitness batch) is a function of the
//  state and the ordered pair, and the solve is a static call, so a second build
//  of a pair can only return the list the first one returned. `_candsOf` keeps
//  one list per ordered pair for the solve (5.1 census on Base: AERO>AAVE built
//  eleven lists over seven pairs; -17.7 % of the swap's gas once kept).
//
//  1. The census (red before the fix): `Hub.getActivePools`, the first read of
//     every build and made by no other step of the solve, is asked once per
//     ordered pair. Three bridges and a pool on every pair, so all thirteen
//     topologies build every stage: thirteen pairs, thirteen reads (before:
//     twenty-five).
//  2. Every topology starts from the list as built. `_buildHop` compacts the
//     array it is handed in place (the band filter drops a pool off the median),
//     so a list handed out twice reaches the next topology with a survivor in
//     the dropped pool's seat and the dropped pool gone. Here the pair tIn -> b0
//     opens topology 1 (the runner-up, `fallbackRoute`) and topology 4 (the
//     best, tIn -> b0 -> b1 -> tOut), both on the whole input: their first hops
//     must be the same hop, leg for leg.
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixCore as BPC, RoutePlan, Hop} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";

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
            for (uint256 j = i + 1; j < 3; ++j) _pool(bs[i], bs[j], 1_000_000e18, 1_000_000e18, 30);
        }
    }

    function test_EachOrderedPairIsBuiltOnce() public {
        vm.startStateDiffRecording();
        RoutePlan memory plan = solver.findBestRoutePlan(address(tA), address(tB), AMT);
        VmSafe.AccountAccess[] memory recs = vm.stopAndReturnStateDiff();
        assertGt(plan.best.totalOut, 0, "fixture: there is a plan");

        bytes32[] memory seen = new bytes32[](recs.length);
        uint256[] memory times = new uint256[](recs.length);
        uint256 pairs;
        uint256 reads;
        uint256 walks;
        for (uint256 r; r < recs.length; ++r) {
            VmSafe.AccountAccess memory a = recs[r];
            if (a.accessor == address(solver) && a.account == address(solver)) ++walks;
            if (a.account != address(hub) || a.data.length < 68) continue;
            if (bytes4(a.data) != BlazePhoenixHub.getActivePools.selector) continue;
            ++reads;
            bytes memory d = a.data;
            bytes32 key;
            assembly { key := keccak256(add(d, 36), 64) }
            uint256 w;
            while (w < pairs && seen[w] != key) ++w;
            if (w == pairs) { seen[pairs] = key; ++pairs; }
            ++times[w];
        }
        emit log_named_uint("getActivePools reads", reads);
        emit log_named_uint("ordered pairs", pairs);
        assertEq(walks, 0, "fixture: no capacity walk (V2 only), the census is the solve's own");
        assertEq(pairs, 13, "fixture: every topology builds every stage (13 ordered pairs)");
        for (uint256 w; w < pairs; ++w) assertEq(times[w], 1, "an ordered pair's candidate list was built twice");
        assertEq(reads, 13, "thirteen builds, one per ordered pair");
    }
}

contract EachTopologyStartsFromTheListAsBuiltTest is SolveWorld {
    address p0;
    address pBad;
    address p2;

    function setUp() public {
        _world();
        hub.addBridge(address(b0));
        hub.addBridge(address(b1));
        // tIn -> b0: three pools at one fee, seated by depth, the off-price one in the middle seat.
        p0 = _pool(tA, b0, 2_000_000e18, 2_000_000e18, 30);
        pBad = _pool(tA, b0, 1_500_000e18, 1_200_000e18, 30);   // 20 % below the others: off the band
        p2 = _pool(tA, b0, 1_000_000e18, 1_000_000e18, 30);
        _pool(b0, tB, 20_000e18, 20_000e18, 30);              // topology 1 closes on a thin pool
        _pool(b0, b1, 10_000_000e18, 10_000_000e18, 5);       // topology 4 closes on two deep ones
        _pool(b1, tB, 10_000_000e18, 10_000_000e18, 5);
        _pool(tA, tB, 2e18, 2e18, 30);                         // the direct route cannot win
    }

    function test_TheSharedPairBuildsTheSameHopInBothTopologies() public view {
        // The premise: the funnel seats them as registered (fitness never rises down the list,
        // one fee, and the selection sort keeps the earlier row on a tie).
        address[] memory pls = new address[](3);
        address[] memory t0s = new address[](3);
        address[] memory t1s = new address[](3);
        (address t0, address t1) = address(tA) < address(b0) ? (address(tA), address(b0)) : (address(b0), address(tA));
        (pls[0], pls[1], pls[2]) = (p0, pBad, p2);
        for (uint256 i; i < 3; ++i) (t0s[i], t1s[i]) = (t0, t1);
        uint256[] memory ps = hub.psisOf(pls, t0s, t1s);
        assertTrue(ps[0] >= ps[1] && ps[1] >= ps[2], "fixture: the funnel would reseat the three pools");

        RoutePlan memory plan = solver.findBestRoutePlan(address(tA), address(tB), AMT);
        assertEq(plan.best.hops.length, 3, "fixture: the best route is tIn -> b0 -> b1 -> tOut");
        assertEq(plan.best.hops[1].tokenOut, address(b1), "fixture: the best route crosses b1");
        assertTrue(plan.hasFallback, "fixture: there is a runner-up");
        assertEq(plan.fallbackRoute.hops.length, 2, "fixture: the runner-up is tIn -> b0 -> tOut");

        Hop memory a = plan.fallbackRoute.hops[0];   // topology 1: the list as built
        Hop memory b = plan.best.hops[0];            // topology 4: the same pair, read again
        assertEq(a.legs.length, 2, "fixture: the band dropped the off-price pool");
        for (uint256 i; i < a.legs.length; ++i) assertTrue(a.legs[i].pool != pBad, "fixture: the off-price pool took a leg");
        assertEq(b.tokenOut, a.tokenOut, "the two first hops end on different tokens");
        assertEq(b.amountIn, a.amountIn, "the two first hops spend different inputs");
        assertEq(b.legs.length, a.legs.length, "the second read of the pair did not start from the list as built");
        for (uint256 i; i < a.legs.length; ++i) {
            assertEq(b.legs[i].pool, a.legs[i].pool, "a leg moved to another pool");
            assertEq(b.legs[i].amountIn, a.legs[i].amountIn, "a leg's share moved");
            assertEq(b.legs[i].expectedOut, a.legs[i].expectedOut, "a leg's promise moved");
        }
        assertEq(b.expectedOut, a.expectedOut, "the two first hops promise different outputs");
    }
}
