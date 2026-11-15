// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  WITNESS CELL C11: the route at its ceiling, 2 hops x 5 legs = 10 legs.
//
//  Core's MAX_HOPS = 2 and MAX_LEGS_PER_HOP = 5 bound a route to 10 legs (owner, 2026-11-06:
//  "2 hops e 10 legs"). PlanInsideTheCeilings asks every planned route to stay inside both
//  ceilings on random markets; nothing pinned one deterministic market where the plan REACHES
//  them. This cell does: tIn = A, tOut = C, bridges X1, X2, B in the Hub's three slots and
//  pools only on the third (B), five V2 venues on A/B and five on B/C at prices within 0.5%,
//  no A/C pair. The only path is A -> B -> C and splitting pays on both hops.
//
//  Oracles (never the Solver's own figures beyond the route it hands out):
//    - shape: 2 hops, A -> B -> C, LEGS_HOP0 = 5 and LEGS_HOP1 = 5 legs, 10 in all
//      (= MAX_HOPS x MAX_LEGS_PER_HOP), each hop's legs on five distinct venues of its pair;
//    - hop 0's legs commit exactly the amount in;
//    - settlement, measured on balances: no fee in A (the fee calendar charges the first hop
//      whose input is a bridge), the fee in B is ceil(B out of the five A/B venues * 28 / 1e4),
//      split T1 + T2, the five B/C venues receive that B less the fee and less the share
//      dust swept back to the user (the floor of each scaled hop-1 leg, at most LEGS_HOP1 - 1
//      wei; 2 measured), the Router keeps no B,
//      and the user receives exactly the C the five B/C venues paid out.
//
//  Matrix (gamma x vector x dimension, agentes.md:7-12):
//    gamma      venues per pair at the ceiling (5); depth 1.0e24..1.4e24; amount 1e23 (~10%
//               of one venue, so a fifth leg still pays);
//    vector     findBestRoutePlan best route, previewPlan counts, swapExactIn settlement;
//    dimension  unit; 2 hops; 10 legs; topology = the third bridge slot; ERC20.
//  Meta-mutant (.github/scripts/mutants.py): LEGS_HOP1 = 5 -> 4 (a 9-leg cell) turns the
//  per-hop and the 10-leg assertions red.
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixQuoter} from "../src/BlazePhoenixQuoter.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, MAX_HOPS, MAX_LEGS_PER_HOP} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";

contract WitnessCellTenLegsTwoHopsTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    BlazePhoenixQuoter quoter;
    BlazePhoenixRouter router;
    MockERC20 tokenA;
    MockERC20 x1;
    MockERC20 x2;
    MockERC20 bridge;
    MockERC20 tokenC;
    MockV2Pair[5] ab;
    MockV2Pair[5] bc;

    address constant USER = address(0xBEEF);
    address constant T1 = address(0xFEE1);
    address constant T2 = address(0xFEE2);

    uint256 constant LEGS_HOP0 = 5;
    uint256 constant LEGS_HOP1 = 5;
    uint256 constant AMOUNT_IN = 1e23;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        solver = new BlazePhoenixSolver(address(hub), address(0));
        quoter = new BlazePhoenixQuoter(address(hub), address(solver));
        router = new BlazePhoenixRouter(address(hub), address(solver), address(this), T1, T2);
        hub.setRoles(address(router), address(solver), address(quoter));

        tokenA = new MockERC20("A", "A");
        x1 = new MockERC20("X1", "X1");
        x2 = new MockERC20("X2", "X2");
        bridge = new MockERC20("B", "B");
        tokenC = new MockERC20("C", "C");
        // Three slots; only the third has pools.
        hub.addBridge(address(x1));
        hub.addBridge(address(x2));
        hub.addBridge(address(bridge));

        for (uint256 i; i < 5; ++i) {
            ab[i] = _venue(tokenA, bridge, (10 + i) * 1e23, 998 + i);
            bc[i] = _venue(bridge, tokenC, (14 - i) * 1e23, 1002 - i);
        }

        tokenA.mint(USER, AMOUNT_IN);
        vm.prank(USER);
        tokenA.approve(address(router), type(uint256).max);
    }

    /// One V2 venue on a/b: `ra` of a, `ra * permille / 1000` of b, seeded in the Hub.
    function _venue(MockERC20 a, MockERC20 b, uint256 ra, uint256 permille) private returns (MockV2Pair p) {
        uint256 rb = ra * permille / 1000;
        p = new MockV2Pair(address(a), address(b));
        a.mint(address(p), ra);
        b.mint(address(p), rb);
        if (p.token0() == address(a)) p.setReserves(uint112(ra), uint112(rb));
        else p.setReserves(uint112(rb), uint112(ra));
        hub.seedPool(address(p), BPC.KIND_V2, 30, address(0), address(a), address(b));
    }

    function _plan() private view returns (Route memory r) {
        r = solver.findBestRoutePlan(address(tokenA), address(tokenC), AMOUNT_IN).best;
    }

    /// Every leg of hop `h` sits on a distinct venue of `pools`, and all five are used.
    function _legsCoverTheVenues(Route memory r, uint256 h, MockV2Pair[5] storage pools) private view {
        bool[5] memory seen;
        for (uint256 i; i < r.hops[h].legs.length; ++i) {
            address p = r.hops[h].legs[i].pool;
            bool found;
            for (uint256 j; j < 5; ++j) {
                if (p == address(pools[j])) {
                    assertFalse(seen[j], "two legs of one hop on the same venue");
                    seen[j] = true;
                    found = true;
                }
            }
            assertTrue(found, "a leg on a venue outside the hop's pair");
        }
    }

    // ─── the shape: the plan reaches both ceilings ───────────────────────────

    function test_ThePlanIsTwoHopsOfFiveLegsTenInAll() public view {
        Route memory r = _plan();
        assertEq(r.hops.length, MAX_HOPS, "two hops: the hop ceiling");
        assertEq(r.hops[0].tokenIn, address(tokenA), "starts in A");
        assertEq(r.hops[0].tokenOut, address(bridge), "through the third bridge slot, B");
        assertEq(r.hops[1].tokenIn, address(bridge), "the second hop starts in B");
        assertEq(r.hops[1].tokenOut, address(tokenC), "ends in C");
        assertEq(r.hops[0].legs.length, LEGS_HOP0, "hop 0 is five legs wide");
        assertEq(r.hops[1].legs.length, LEGS_HOP1, "hop 1 is five legs wide");
        assertEq(r.hops[0].legs.length + r.hops[1].legs.length, 10, "ten legs: the route ceiling");
        assertEq(LEGS_HOP0 + LEGS_HOP1, uint256(MAX_HOPS) * MAX_LEGS_PER_HOP, "the cell is MAX_HOPS x MAX_LEGS_PER_HOP");
        _legsCoverTheVenues(r, 0, ab);
        _legsCoverTheVenues(r, 1, bc);

        uint256 committed;
        for (uint256 i; i < r.hops[0].legs.length; ++i) committed += r.hops[0].legs[i].amountIn;
        assertEq(committed, AMOUNT_IN, "hop 0's legs commit exactly the amount in");
    }

    /// The preview counts the same cell.
    function test_ThePreviewCountsTheSameCell() public view {
        (BlazePhoenixQuoter.Preview memory pv,,) = quoter.previewPlan(address(tokenA), address(tokenC), AMOUNT_IN);
        assertTrue(pv.canExecute, "the preview refuses the cell");
        assertEq(pv.hops, 2, "the preview counts two hops");
        assertEq(pv.legs, LEGS_HOP0 + LEGS_HOP1, "the preview counts ten legs");
        assertEq(pv.bridgeUsed, address(bridge), "the preview names the third slot's bridge");
    }

    // ─── the settlement, measured on balances ────────────────────────────────

    function test_TheCellSettlesWithTheFeeOnTheBridgeHop() public {
        Route memory r = _plan();
        uint256[5] memory abB;
        uint256[5] memory bcB;
        uint256[5] memory bcC;
        for (uint256 i; i < 5; ++i) {
            abB[i] = bridge.balanceOf(address(ab[i]));
            bcB[i] = bridge.balanceOf(address(bc[i]));
            bcC[i] = tokenC.balanceOf(address(bc[i]));
        }

        vm.prank(USER);
        uint256 delivered = router.swapExactIn(r, AMOUNT_IN, 1, USER, block.timestamp + 1);

        uint256 bOut;
        uint256 bIn;
        uint256 cOut;
        for (uint256 i; i < 5; ++i) {
            bOut += abB[i] - bridge.balanceOf(address(ab[i]));
            bIn += bridge.balanceOf(address(bc[i])) - bcB[i];
            cOut += bcC[i] - tokenC.balanceOf(address(bc[i]));
        }
        uint256 fee = (bOut * BPC.PROTOCOL_FEE_BPS + BPC.BPS - 1) / BPC.BPS;

        assertEq(tokenA.balanceOf(T1) + tokenA.balanceOf(T2), 0, "no fee in A: the bridge hop carries it");
        assertEq(bridge.balanceOf(T1) + bridge.balanceOf(T2), fee, "the fee in B is ceil(B out * 28 / 1e4)");
        // Conservation of B: what the A/B venues paid out is the fee, what the B/C venues took
        // and what came back to the user. Each hop-1 leg is the plan's share scaled by
        // mulDiv(leg.amountIn, net, planned) - a floor - and only the last leg is clamped to the
        // balance, never topped up, so under one wei per leg is left over: at most
        // LEGS_HOP1 - 1 (Router:1347-1351). The Router keeps none of it; it is swept back to the
        // user (payer and recipient are one address here). Measured: 2 wei.
        uint256 dust = bridge.balanceOf(USER);
        assertEq(bridge.balanceOf(address(router)), 0, "the Router keeps no B");
        assertEq(bIn + dust, bOut - fee, "B is conserved: fee + B/C inputs + the share dust returned");
        assertLe(dust, LEGS_HOP1 - 1, "under one wei of B per hop-1 leg comes back");
        assertEq(delivered, cOut, "the Router reports what the five B/C venues paid out");
        assertEq(tokenC.balanceOf(USER), cOut, "the user receives exactly that C");
        assertEq(tokenA.balanceOf(USER), 0, "the whole amount in was taken");
    }
}
