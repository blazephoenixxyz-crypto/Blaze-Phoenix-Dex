// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  WHAT A POOL'S ANSWER CAN COST THE PLANNER IS BOUNDED WHERE IT IS READ.
//
//  The planner quotes every registered candidate of a pair in one call, so the
//  guarantee "one pool cannot take the pair's planning down" belongs to the
//  reads, not to each caller: every read the quote path makes of a pool is
//  gas-capped (GAS_CAP) and copies a fixed number of words, and a word read as
//  an address must be clean. The Solidly pair's getAmountOut and the fee behind
//  its factory() were the two reads written as high-level calls; they ask
//  through `Core._askWord` now. A pool that turns hostile after it was admitted
//  - a proxy upgrade - meets all three bounds. The dirty-word case is the ninth
//  wave's mohaseenbasha #15; the gas and the size cases are the same reads'
//  other two bounds, found by following that report's root rather than its
//  symptom.
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixCore as BPC, RoutePlan} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";
import {MockSolidlyPair} from "./mocks/MockSolidlyPair.sol";

/// @dev A Solidly pair that answers honestly until the test turns it. Then one of its
///      answers - getAmountOut, factory(), or its factory's getFee - burns every unit of
///      gas it is given, or answers a megabyte.
contract TurningPair is MockSolidlyPair {
    uint8 public mode;
    address public fac;
    constructor(address a, address b) MockSolidlyPair(a, b, false) {}
    function turn(uint8 m, address f) external { mode = m; fac = f; }
    function getAmountOut(uint256 amountIn, address tokenIn) public view override returns (uint256) {
        if (mode == 1) { assembly { for {} 1 {} {} } }
        if (mode == 2) { assembly { return(0, 0x100000) } }
        if (mode >= 3) return 0;
        return super.getAmountOut(amountIn, tokenIn);
    }
    function factory() external view returns (address) {
        if (mode == 3) { assembly { for {} 1 {} {} } }
        if (mode == 4) { assembly { return(0, 0x100000) } }
        return fac;
    }
}

/// @dev A factory whose getFee burns every unit of gas it is given, or answers a megabyte.
contract TurningFactory {
    bool public bomb;
    constructor(bool b) { bomb = b; }
    function getFee(address, bool) external view returns (uint256) {
        if (bomb) { assembly { return(0, 0x100000) } }
        assembly { for {} 1 {} {} }
        return 0;
    }
}

contract APoolsAnswerIsBoundedByTheReaderTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    MockERC20 A;
    MockERC20 B;
    TurningPair turned;

    /// The budget a node gives one eth_call by default; the plan must fit in it.
    uint256 constant CALL_GAS = 50_000_000;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        solver = new BlazePhoenixSolver(address(hub));
        A = new MockERC20("A", "A");
        B = new MockERC20("B", "B");
        (address t0, address t1) = address(A) < address(B) ? (address(A), address(B)) : (address(B), address(A));

        MockV2Pair honest = new MockV2Pair(t0, t1);
        MockERC20(t0).mint(address(honest), 1e24);
        MockERC20(t1).mint(address(honest), 1e24);
        honest.setReserves(uint112(1e24), uint112(1e24));
        hub.seedPool(address(honest), BPC.KIND_V2, 30, address(0), t0, t1);

        // Admitted while honest, and deeper-looking than the honest venue.
        turned = new TurningPair(t0, t1);
        MockERC20(t0).mint(address(turned), 11e23);
        MockERC20(t1).mint(address(turned), 11e23);
        turned.setReserves(uint112(11e23), uint112(11e23));
        hub.seedPool(address(turned), BPC.KIND_SOLIDLY, 30, address(0), t0, t1);
    }

    function _pairIsStillPlanned(string memory what) internal {
        try solver.findBestRoutePlan{gas: CALL_GAS}(address(A), address(B), 1e21) returns (RoutePlan memory plan) {
            assertGt(plan.best.totalOut, 0, "the pair was planned to nothing");
        } catch {
            assertTrue(false, what);
        }
    }

    function test_AGetAmountOutThatBurnsItsGasCannotTakeThePairDown() public {
        turned.turn(1, address(0));
        _pairIsStillPlanned("a getAmountOut that burns its gas took the pair's planning down");
    }

    function test_AGetAmountOutThatAnswersAMegabyteCannotTakeThePairDown() public {
        turned.turn(2, address(0));
        _pairIsStillPlanned("a getAmountOut that answers a megabyte took the pair's planning down");
    }

    function test_AFactoryAnswerThatBurnsItsGasCannotTakeThePairDown() public {
        turned.turn(3, address(0));
        _pairIsStillPlanned("a factory() that burns its gas took the pair's planning down");
    }

    function test_AFactoryAnswerOfAMegabyteCannotTakeThePairDown() public {
        turned.turn(4, address(0));
        _pairIsStillPlanned("a factory() that answers a megabyte took the pair's planning down");
    }

    function test_AFeeAnswerThatBurnsItsGasCannotTakeThePairDown() public {
        turned.turn(5, address(new TurningFactory(false)));
        _pairIsStillPlanned("a getFee that burns its gas took the pair's planning down");
    }

    function test_AFeeAnswerOfAMegabyteCannotTakeThePairDown() public {
        turned.turn(5, address(new TurningFactory(true)));
        _pairIsStillPlanned("a getFee that answers a megabyte took the pair's planning down");
    }

    /// The control: the same pair, honest, plans within the same budget - so a red above is
    /// the answer's cost, not the budget.
    function test_Control_TheHonestPairPlansWithinTheBudget() public {
        _pairIsStillPlanned("the honest pair does not plan within the budget");
    }
}
