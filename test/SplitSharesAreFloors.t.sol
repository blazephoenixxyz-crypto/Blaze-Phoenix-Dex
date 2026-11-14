// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// THE SHARES OF A SPLIT ARE FLOORS, NOT CEILINGS (Solver `_split`).
//
// Every leg but the last takes floor(A * psi_i / S); the last takes A - allocated. With ceilings
// the legs would STILL sum to A (the last leg takes whatever is left), so the oracle of
// test/SplitRemainderIsTheLastLeg.t.sol (sum of legs == A) cannot see the rounding direction.
// Two consequences of the floor can:
//   1. On n venues of equal depth (equal psis) no leg gets less than floor(A / n): the floors give
//      the remainder to the last leg; ceilings take it from the last leg, which falls to
//      floor(A / n) - 1 when A mod 3 == 1 (n = 3).
//   2. (Not pinned: on dust, A = 1 wei and n = 3, ceilings would allocate 2 wei before the last
//      leg and underflow; but a 1-wei order finds no route at all, SolverE(5), even at 1:1000,
//      so that path is unreachable from `findBestRoutePlan`. Measured 2026-11-14.)
//
// Mutant (red here: the unit test, and the fuzz on a mod 3 == 1): Solver:1034
// `share = BPC.mulDiv(amountIn, psis[i], sumPsi)` -> `BPC.mulDivUp(amountIn, psis[i], sumPsi)`.
//
// Matrix: range = 300k e18 + 1 (A mod 3 == 1) and fuzzed 100k-600k e18 against 3 x 400k e18 of depth;
// vector = three honest V2 rows at one price, equal depths (equal psis); dimension = unit + fuzz,
// 1 hop, ERC20.

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixCore as BPC, RoutePlan, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";
import {Origin} from "./mocks/MockOriginFactory.sol";

contract SplitSharesAreFloorsTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    MockERC20 tA;
    MockERC20 tB;

    uint256 constant DEPTH = 400_000e18;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0xBEEF));
        solver = new BlazePhoenixSolver(address(hub), address(0));
        hub.setRoles(address(this), address(solver), address(this));
        tA = new MockERC20("A", "A");
        tB = new MockERC20("B", "B");
    }

    /// One honest V2 row holding `dIn` of A and `dOut` of B, wired and listed at its own price.
    function _pool(uint112 dIn, uint112 dOut) private {
        MockV2Pair p = new MockV2Pair(address(tA), address(tB));
        tA.mint(address(p), dIn);
        tB.mint(address(p), dOut);
        p.setReserves(dIn, dOut);
        Origin.wire(hub, address(p), address(tA), address(tB), BPC.KIND_V2, 30);
        for (uint256 i; i < 4; i++) {
            hub.recordSwap(address(p), BPC.KIND_V2, 30, address(0), address(tA), address(tB), 1e18,
                uint256(dOut) * 1e18 / dIn, dIn);
        }
    }

    function _threeEqual(uint112 dIn, uint112 dOut) private {
        _pool(dIn, dOut);
        _pool(dIn, dOut);
        _pool(dIn, dOut);
    }

    /// Sum and minimum of the first hop's leg inputs.
    function _legs(RoutePlan memory p) private pure returns (uint256 sum, uint256 minIn, uint256 nLegs) {
        Leg[] memory legs = p.best.hops[0].legs;
        nLegs = legs.length;
        minIn = type(uint256).max;
        for (uint256 i; i < nLegs; i++) {
            sum += legs[i].amountIn;
            if (legs[i].amountIn < minIn) minIn = legs[i].amountIn;
        }
    }

    function test_EqualVenuesGiveNoLegLessThanItsFloorShare() public {
        _threeEqual(uint112(DEPTH), uint112(DEPTH));
        uint256 a = 300_000e18 + 1; // a mod 3 == 1: ceilings would take 2 wei from the last leg
        RoutePlan memory p = solver.findBestRoutePlan(address(tA), address(tB), a);
        assertEq(p.best.hops.length, 1, "pre-condition: one direct hop");
        (uint256 sum, uint256 minIn, uint256 nLegs) = _legs(p);
        assertEq(nLegs, 3, "pre-condition: the order splits over the three venues");
        assertEq(sum, a, "the legs spend exactly the caller's input");
        assertGe(minIn, a / 3, "no leg gets less than its floor share");
    }

    /// Fuzz of the same floor bound over the order size: red under ceilings whenever a mod 3 == 1.
    function testFuzz_EqualVenuesFloorShare(uint256 a) public {
        _threeEqual(uint112(DEPTH), uint112(DEPTH));
        a = bound(a, 100_000e18, 600_000e18);
        RoutePlan memory p = solver.findBestRoutePlan(address(tA), address(tB), a);
        (uint256 sum, uint256 minIn, uint256 nLegs) = _legs(p);
        assertEq(sum, a, "the legs spend exactly the caller's input");
        if (nLegs == 3) assertGe(minIn, a / 3, "no leg gets less than its floor share");
    }
}
