// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  THE QUOTE NEVER HANDS OUT A ROUTE THE ROUTER REFUSES (hops2, 2026-11-06).
//
//  Core's MAX_HOPS = 2 and MAX_LEGS_PER_HOP = 5 are the one producer of both ceilings (owner,
//  2026-11-06: "Ajusta as topologias a 2 hop", "2 hops e 10 legs"; 2026-11-03: never more than
//  5 legs a hop). The Router refuses a route past either with RouterE(3); the Solver builds
//  every topology on them (direct, and one bridge per slot: TOPOLOGIES = 1 + BRIDGE_SLOTS = 4).
//  This file asks the whole chain the same question on random markets:
//    - the plan answers exactly when the market has a path (direct, or tIn -> bridge -> tOut),
//      and refuses with SolverE(5) when it has none;
//    - every route the quote hands out, best and fallback, has 1..MAX_HOPS hops, 1..MAX_LEGS_PER_HOP
//      legs on every hop, at most MAX_HOPS x MAX_LEGS_PER_HOP legs in all, and ends in tOut;
//    - the preview's own counts agree with the route (hops, legs, topology = hops - 1);
//    - the preview calls the route executable, and the Router settles it, delivering tOut.
//  A pair offers up to seven venues - two past the leg ceiling - at prices within +-0.5% of
//  each other, so splitting pays and a planner that builds a hop wider than the Router takes
//  is caught here; three bridges give every bridge slot its own topology.
//
//  Matrix (gamma x vector x dimension, agentes.md:7-12):
//    gamma      venues per pair 0..7 (none, inside, at the ceiling, past it); depth 1e24..1e25
//               per venue; price +-0.5%; amount 1e18..3e23 (dust to ~30% of one venue);
//    vector     previewPlan (best, fallback, no-path refusal), previewRoute, swapExactIn;
//    dimension  topology 0 and the three bridge slots; hops 1..2; legs 1..5 per hop, 10 in all.
//  Mutants: Solver one hop past the ceiling (new Hop[](MAX_HOPS + 1)), and the direct and
//  bridge leg budgets one past MAX_LEGS_PER_HOP (.github/scripts/mutants.py).
//
//  History: until 2026-11-06 the planner also built three-hop routes over two bridges
//  (TOPOLOGIES = 13, MAX_HOPS = 3) with 4 legs a stage; no test asked the plan against both
//  Router ceilings at once.
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixQuoter} from "../src/BlazePhoenixQuoter.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {
    BlazePhoenixCore as BPC, Route, MAX_HOPS, MAX_LEGS_PER_HOP
} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";

contract PlanInsideTheCeilingsTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    BlazePhoenixQuoter quoter;
    BlazePhoenixRouter router;
    MockERC20 tIn;
    MockERC20 tOut;
    MockERC20[3] br;                 // one token per Hub bridge slot (MAX_BRIDGES = 3)

    address user = address(0xBEEF);
    uint256 constant MAX_VENUES = 7; // two past MAX_LEGS_PER_HOP

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        solver = new BlazePhoenixSolver(address(hub), address(0));
        quoter = new BlazePhoenixQuoter(address(hub), address(solver));
        router = new BlazePhoenixRouter(
            address(hub), address(solver), address(this), address(0xFEE1), address(0xFEE2)
        );
        hub.setRoles(address(router), address(solver), address(quoter));
        tIn = new MockERC20("I", "I");
        tOut = new MockERC20("O", "O");
        for (uint256 i; i < 3; ++i) {
            br[i] = new MockERC20("B", "B");
            hub.addBridge(address(br[i]));
        }
    }

    /// forge-config: default.fuzz.runs = 64
    /// forge-config: release.fuzz.runs = 64
    function testFuzz_EveryPlannedRouteIsInsideTheCeilingsAndSettles(uint256 seed, uint256 amt) public {
        amt = bound(amt, 1e18, 3e23);
        uint256 s = seed;
        // Venue counts: the direct pair, then tIn -> br[i] and br[i] -> tOut for each slot.
        uint256 nD = s % (MAX_VENUES + 1); s /= MAX_VENUES + 1;
        bool path = nD != 0;
        _venues(tIn, tOut, nD, uint256(keccak256(abi.encode(seed, "direct"))));
        for (uint256 i; i < 3; ++i) {
            uint256 nA = s % (MAX_VENUES + 1); s /= MAX_VENUES + 1;
            uint256 nB = s % (MAX_VENUES + 1); s /= MAX_VENUES + 1;
            _venues(tIn, br[i], nA, uint256(keccak256(abi.encode(seed, i, "in"))));
            _venues(br[i], tOut, nB, uint256(keccak256(abi.encode(seed, i, "out"))));
            if (nA != 0 && nB != 0) path = true;
        }

        try quoter.previewPlan(address(tIn), address(tOut), amt) returns (
            BlazePhoenixQuoter.Preview memory pv, Route memory fb, bool hasFb
        ) {
            assertTrue(path, "a route was quoted on a market with no path");
            assertTrue(pv.canExecute, "the quote's own preview refuses its best route");
            uint256 legs = _inside(pv.route, amt, "best");
            assertEq(pv.hops, pv.route.hops.length, "the preview miscounts the hops");
            assertEq(pv.legs, legs, "the preview miscounts the legs");
            assertEq(uint256(pv.topology), pv.route.hops.length - 1, "the topology is not hops - 1");
            if (hasFb) _inside(fb, amt, "fallback");
        } catch (bytes memory err) {
            assertFalse(path, "the plan refused a market that has a path");
            assertEq(err, abi.encodeWithSelector(BlazePhoenixSolver.SolverE.selector, uint16(5)),
                "a market with no path is refused by the plan's no-route error");
        }
    }

    /// Both ceilings, the preview and the Router on one quoted route; the swap is undone after.
    function _inside(Route memory r, uint256 amt, string memory which) private returns (uint256 legs) {
        assertGt(r.hops.length, 0, string.concat(which, ": a quoted route with no hops"));
        assertLe(r.hops.length, MAX_HOPS, string.concat(which, ": more hops than the Router takes"));
        for (uint256 h; h < r.hops.length; ++h) {
            assertGt(r.hops[h].legs.length, 0, string.concat(which, ": a hop with no legs"));
            assertLe(r.hops[h].legs.length, MAX_LEGS_PER_HOP,
                string.concat(which, ": a hop wider than the Router takes"));
            legs += r.hops[h].legs.length;
        }
        assertLe(legs, MAX_HOPS * MAX_LEGS_PER_HOP, string.concat(which, ": more legs than a route holds"));
        assertEq(r.hops[0].tokenIn, address(tIn), string.concat(which, ": the route does not start in tIn"));
        assertEq(r.hops[r.hops.length - 1].tokenOut, address(tOut),
            string.concat(which, ": the route does not end in tOut"));
        assertTrue(quoter.previewRoute(r, 1).canExecute, string.concat(which, ": the preview refuses a quoted route"));

        uint256 snap = vm.snapshotState();
        tIn.mint(user, amt);
        vm.startPrank(user);
        tIn.approve(address(router), amt);
        uint256 out = router.swapExactIn(r, amt, 1, user, block.timestamp + 1);
        vm.stopPrank();
        assertGt(out, 0, string.concat(which, ": the Router settles nothing"));
        assertEq(tOut.balanceOf(user), out, string.concat(which, ": the Router does not deliver tOut"));
        vm.revertToState(snap);
    }

    /// `n` V2 venues on a/b, seeded in the Hub: depth 1e24..1e25 of `a`, price within +-0.5%.
    function _venues(MockERC20 a, MockERC20 b, uint256 n, uint256 s) private {
        for (uint256 i; i < n; ++i) {
            uint256 ra = 1e24 * (1 + (s % 10));
            uint256 rb = ra * (995 + ((s >> 8) % 11)) / 1000;
            s = uint256(keccak256(abi.encode(s, i)));
            MockV2Pair p = new MockV2Pair(address(a), address(b));
            a.mint(address(p), ra);
            b.mint(address(p), rb);
            if (p.token0() == address(a)) p.setReserves(uint112(ra), uint112(rb));
            else p.setReserves(uint112(rb), uint112(ra));
            hub.seedPool(address(p), BPC.KIND_V2, 30, address(0), address(a), address(b));
        }
    }
}
