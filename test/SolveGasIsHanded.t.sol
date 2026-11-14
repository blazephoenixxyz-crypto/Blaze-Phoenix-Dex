// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  THE SEARCH OF ENTRY B IS HANDED SOLVE_GAS, DECLARED BACK AS A VALUE (INV-S6)
//
//  Entry B (`Router.swapBestExactIn`) runs the search on a fixed budget,
//  SOLVE_GAS (Router, 14,700,000), whatever gas the caller attaches. Mutant [384]
//  (the budget raised to 30,000,000) was held by a gas figure only:
//  test_EntryB_OverBudgetRevertsCleanUnderTheTxCap bounds the gas the refusal
//  spent. A bound on gas spent moves with every repricing and every optimisation
//  of the path it measures; the budget itself does not.
//
//  Here the budget is an answer. A Solver that answers every search by reverting
//  with the gas it was handed, `Handed(gasleft())`, and the Router passes every
//  revert with data through unchanged (`_solve`), so the caller reads the figure.
//  Through the cap it stays under SOLVE_GAS however much the caller attaches;
//  uncapped it is 63/64 of what the caller attached.
//
//  Oracle: SOLVE_GAS written here by hand from the Router's constant, and the
//  Solver's own declaration; never a gas measurement of the code under test.
//  Green at cb1d7d9; red under [morf-1i] (.github/scripts/mutants.py).
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";

/// Answers every search by reverting with the gas it was handed.
contract SolveGasEchoSolver {
    error Handed(uint256 gas);

    function findBestRoutePlan(address, address, uint256) external view returns (uint256) {
        revert Handed(gasleft());
    }
}

contract SolveGasIsHandedTest is Test {
    /// Core.SOLVE_GAS (read by the Router).
    uint256 constant SOLVE_GAS = 14_700_000;
    /// What the echo's own dispatch may spend before it reads gasleft(): far below any budget.
    uint256 constant DISPATCH = 5_000;

    BlazePhoenixRouter router;
    address constant T_IN = address(0x1111);
    address constant T_OUT = address(0x2222);

    function setUp() public {
        BlazePhoenixHub hub = new BlazePhoenixHub(address(this));
        router = new BlazePhoenixRouter(
            address(hub), address(new SolveGasEchoSolver()), address(this), address(0xFEE1), address(0xFEE2)
        );
    }

    /// The gas the search was handed, as the Solver declares it through entry B.
    function _handed(uint256 callGas) internal returns (uint256 g) {
        (bool ok, bytes memory ret) = address(router).call{gas: callGas}(
            abi.encodeCall(BlazePhoenixRouter.swapBestExactIn, (T_IN, T_OUT, 1e18, 1, address(this), block.timestamp + 1))
        );
        assertFalse(ok, "precondition: the echo answers by reverting");
        assertEq(ret.length, 36, "precondition: the Solver's revert passes through whole");
        assertEq(bytes4(ret), SolveGasEchoSolver.Handed.selector, "precondition: the Solver's own revert");
        assembly ("memory-safe") { g := mload(add(ret, 36)) }
    }

    /// Kills [morf-1i] (the [384] mutation: SOLVE_GAS raised to 30,000,000) by the answer.
    /// Attached gas: twice the budget, and the most a transaction can carry (EIP-7825, 2^24).
    function test_EntryB_TheSearchIsHandedSolveGasWhateverTheCallerAttaches() public {
        uint256[2] memory attached = [uint256(2 * SOLVE_GAS), 16_777_216];
        for (uint256 i; i < 2; ++i) {
            uint256 g = _handed(attached[i]);
            emit log_named_uint("gas the search was handed", g);
            assertLt(g, SOLVE_GAS, "the search was handed more than SOLVE_GAS");
            assertGt(g, SOLVE_GAS - DISPATCH, "the neighbour: the cap, not the caller, sets the budget");
        }
    }
}
