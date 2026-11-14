// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// THE LAST LEG TAKES THE REMAINDER, AND THE REMAINDER CANNOT BE NEGATIVE (Solver `_split`).
//
// Every leg but the last takes floor(A * psi_i / S); the last takes A - allocated. `S` (`sumPsi`,
// the SHARED_QUANTITIES row this file pins) is the sum of psis[0..n) for the whole life of the
// split: Math `_weights` sums the n rows, `_cutByWeight` re-sums the budget, `_seatTheSplit` zeroes
// a row that cannot pay and subtracts it, and the Solver's `_placed` takes psis[j] out with the row
// it drops. So the floors sum to at most A, and to A only when psi_{n-1} == 0, where every form
// gives the last leg 0. The old guard `allocated >= amountIn ? 0 : amountIn - allocated` could not
// fire; the subtraction is now plain and checked, so the impossible case reverts instead of
// silently reading 0.
//
// What this file pins: a split hop spends EXACTLY the caller's input, no wei lost to the floors
// and none invented. The oracle is the caller's own number, not the Solver's: `committedIn`
// (hop.amountIn) is the Solver's sum of its legs, so it is checked against the input too.
//
// Mutant (red here): the remainder short by one,
// `share = amountIn - allocated - 1` -> the legs sum to A - 1.
//
// Matrix: range = order from 1e6 wei (one leg) to 600k e18 against 700k e18 of depth, depths
// fuzzed per pool; vector = three honest V2 rows at one price, unequal depths so psi has a
// rounding remainder; dimension = unit (split, single-pool control) + fuzz, 1 hop, ERC20.

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixCore as BPC, RoutePlan, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";
import {Origin} from "./mocks/MockOriginFactory.sol";

contract SplitRemainderIsTheLastLegTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    MockERC20 tA;
    MockERC20 tB;

    // Large on purpose: against 700k of depth the split beats every single pool, so `_split` runs.
    uint256 constant ORDER = 300_000e18;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0xBEEF));
        solver = new BlazePhoenixSolver(address(hub), address(0));
        hub.setRoles(address(this), address(solver), address(this));
        tA = new MockERC20("A", "A");
        tB = new MockERC20("B", "B");
    }

    /// One honest V2 row at the fair price 1:1 with `d` of each token, wired and listed so it votes.
    function _pool(uint112 d) private returns (MockV2Pair p) {
        p = new MockV2Pair(address(tA), address(tB));
        tA.mint(address(p), d);
        tB.mint(address(p), d);
        p.setReserves(d, d);
        Origin.wire(hub, address(p), address(tA), address(tB), BPC.KIND_V2, 30);
        for (uint256 i; i < 4; i++) {
            hub.recordSwap(address(p), BPC.KIND_V2, 30, address(0), address(tA), address(tB), 1e18, 1e18, d);
        }
    }

    /// Σ legs[i].amountIn of the first hop, with each leg checked to carry input.
    function _legSum(RoutePlan memory p) private pure returns (uint256 sum, uint256 nLegs) {
        Leg[] memory legs = p.best.hops[0].legs;
        nLegs = legs.length;
        for (uint256 i; i < nLegs; i++) {
            assertGt(legs[i].amountIn, 0, "every leg carries input");
            sum += legs[i].amountIn;
        }
    }

    function test_TheSplitLegsSpendExactlyTheInput() public {
        _pool(100_000e18);
        _pool(200_000e18);
        _pool(400_000e18);
        RoutePlan memory p = solver.findBestRoutePlan(address(tA), address(tB), ORDER);
        assertEq(p.best.hops.length, 1, "pre-condition: one direct hop");
        (uint256 sum, uint256 nLegs) = _legSum(p);
        // Without a split the remainder line never runs and the test would prove nothing.
        assertGe(nLegs, 2, "pre-condition: the order must split");
        assertEq(sum, ORDER, "the legs spend exactly the caller's input");
        assertEq(p.best.hops[0].amountIn, ORDER, "the hop commits exactly the caller's input");
    }

    /// Control: a lone pool takes the whole input on the single-leg path (no `_split`), so the
    /// oracle above is not something only the split can satisfy.
    function test_ALonePoolTakesTheWholeInput_Control() public {
        _pool(400_000e18);
        RoutePlan memory p = solver.findBestRoutePlan(address(tA), address(tB), ORDER);
        assertEq(p.best.hops.length, 1, "pre-condition: one direct hop");
        (uint256 sum, uint256 nLegs) = _legSum(p);
        assertEq(nLegs, 1, "pre-condition: one pool, one leg");
        assertEq(sum, ORDER, "the lone leg spends the caller's input");
        assertEq(p.best.hops[0].amountIn, ORDER, "the hop commits the caller's input");
    }

    /// Any order from 1e6 wei (every floor share still buys a non-zero V2 output) to 600k e18, on
    /// three depths: split or single leg, the legs spend exactly the input.
    function testFuzz_TheSharesSumToTheInput(uint256 amountIn, uint256 d0, uint256 d1, uint256 d2) public {
        _pool(uint112(bound(d0, 50_000e18, 500_000e18)));
        _pool(uint112(bound(d1, 50_000e18, 500_000e18)));
        _pool(uint112(bound(d2, 50_000e18, 500_000e18)));
        amountIn = bound(amountIn, 1e6, 600_000e18);
        RoutePlan memory p = solver.findBestRoutePlan(address(tA), address(tB), amountIn);
        assertEq(p.best.hops.length, 1, "pre-condition: one direct hop");
        (uint256 sum, ) = _legSum(p);
        assertEq(sum, amountIn, "the legs spend exactly the caller's input");
        assertEq(p.best.hops[0].amountIn, amountIn, "the hop commits exactly the caller's input");
    }
}
