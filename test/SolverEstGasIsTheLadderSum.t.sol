// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// THE `estGas` THE SOLVER PUBLISHES IS THE BASE PLUS THE PER-LEG LADDER.
//
// `BlazePhoenixSolver._estGas` (src/BlazePhoenixSolver.sol) builds the number that leaves
// in `route.estGas` (`_estGasTotal` for the multi-hop path): a fixed 30_000 per hop PLUS the
// per-kind ladder `BPC.kindGasBase` for every leg. The Quoter republishes it unchanged
// (`pv.estGas = route.estGas`). Before this file every `estGas` in test/ was a fixture input
// or a log line; no test compared the number with its formula or required it to grow with the
// number of legs.
//
// The number is informational: the Router never reads it, and no execution decision depends
// on it. This is coverage of a PUBLISHED figure, not of a funds path.

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixCore as BPC, RoutePlan, Route, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";

contract SolverEstGasIsTheLadderSumTest is Test {
    /// The fixed base of `_estGas` (src/BlazePhoenixSolver.sol).
    uint256 constant BASE = 30_000;

    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    MockERC20 tokenA;
    MockERC20 tokenB;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        solver = new BlazePhoenixSolver(address(hub));
        tokenA = new MockERC20("A", "A");
        tokenB = new MockERC20("B", "B");
    }

    function _seedV2(uint256 reserveA, uint256 reserveB) internal returns (MockV2Pair p) {
        return _seedV2On(hub, reserveA, reserveB);
    }

    /// The published formula, written ONCE: base per hop + ladder per leg. The Solver's number is
    /// compared with this sum, not with a constant copied from src/.
    function _ladderSum(Leg[] memory legs) internal pure returns (uint256 s) {
        s = BASE;
        for (uint256 i; i < legs.length; ++i) s += BPC.kindGasBase(legs[i].kind);
    }

    function _legs(RoutePlan memory p) internal pure returns (Leg[] memory) {
        assertEq(p.best.hops.length, 1, "premise: a direct route has exactly one hop");
        return p.best.hops[0].legs;
    }

    /// FALSIFIED BY: `g = 30_000` -> `g = 0` (the base dropped): the exact equality breaks.
    function test_EstGasIsTheBasePlusTheLadder_SingleLeg() public {
        _seedV2(100_000e18, 100_000e18);
        RoutePlan memory p = solver.findBestRoutePlan(address(tokenA), address(tokenB), 1_000e18);
        Leg[] memory legs = _legs(p);
        assertEq(legs.length, 1, "premise: one pool in the registry => one leg");

        assertEq(p.best.estGas, _ladderSum(legs), "estGas is not the base plus the per-leg ladder");
        assertGt(p.best.estGas, BASE, "premise: the ladder contributes (else this test is vacuous)");
    }

    /// A SPLIT route must cost more: the ladder is summed per leg, not once per route.
    /// FALSIFIED BY: counting only the last leg (`if (i + 1 == n) g += ...`): the single-leg test
    /// above stays green, and the difference asserted here drops to zero.
    function test_EstGasCountsEveryLeg_TwoLegPlanCostsExactlyOneMoreLeg() public {
        // A hub with ONE pool, the same pair, the same amounts.
        BlazePhoenixHub hubOne = new BlazePhoenixHub(address(this));
        hubOne.initialize(address(this), address(0));
        BlazePhoenixSolver solverOne = new BlazePhoenixSolver(address(hubOne));
        _seedV2On(hubOne, 1_000_000e18, 1_600_000e18);
        RoutePlan memory one = solverOne.findBestRoutePlan(address(tokenA), address(tokenB), 100_000e18);
        Leg[] memory legsOne = _legs(one);
        assertEq(legsOne.length, 1, "premise: one pool => one leg");

        // This hub with TWO pools at the same marginal rate: the split pays (the same fixture as
        // test/BlazePhoenixSolver.t.sol::test_Direct_SplitsProportionallyToDepth).
        _seedV2(1_000_000e18, 1_600_000e18);
        _seedV2(100_000e18, 160_000e18);
        RoutePlan memory two = solver.findBestRoutePlan(address(tokenA), address(tokenB), 100_000e18);
        Leg[] memory legsTwo = _legs(two);
        assertEq(legsTwo.length, 2, "premise: the route MUST split, or there is no second leg");

        assertEq(two.best.estGas, _ladderSum(legsTwo), "the split plan's estGas does not close the sum");
        assertEq(
            two.best.estGas - one.best.estGas,
            BPC.kindGasBase(legsTwo[1].kind),
            "one more leg must cost exactly that leg's ladder step"
        );
    }

    function _seedV2On(BlazePhoenixHub h, uint256 reserveA, uint256 reserveB)
        internal
        returns (MockV2Pair p)
    {
        p = new MockV2Pair(address(tokenA), address(tokenB));
        tokenA.mint(address(p), reserveA);
        tokenB.mint(address(p), reserveB);
        (address t0, ) = address(tokenA) < address(tokenB)
            ? (address(tokenA), address(tokenB))
            : (address(tokenB), address(tokenA));
        p.setReserves(
            uint112(address(tokenA) == t0 ? reserveA : reserveB),
            uint112(address(tokenA) == t0 ? reserveB : reserveA)
        );
        h.seedPool(address(p), BPC.KIND_V2, 30, address(0), address(tokenA), address(tokenB));
    }
}
