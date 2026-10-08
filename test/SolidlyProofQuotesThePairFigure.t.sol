// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  The Solidly leg in the execution proof: which figure is quoted, which is
//  asked, and that the quote follows the leg's own curve.
//
//  Two producers, by design (`Router._solidlyLegQuote`, `Core.solidlyAskOut`):
//    · the in-frame quote is the pair's own `getAmountOut` - a floor basis;
//    · the executor ASKS that figure less one wei, the rounding margin that
//      keeps the pair's K check satisfied.
//  On a one-hop route whose output is not a bridge coin there is no output-side
//  fee, so `ExecutionProof.realized` is the raw delivery and the relation is
//  exact: realized == quoted - 1, on the stable and the volatile curve alike.
//
//  The quote must also come from the leg's curve: `ConditionAdequacyRouter`
//  asserts it for the native V4 leg; here it is asserted for Solidly by running
//  the stable and the volatile curve over identical reserves and amount, where
//  the two curves give different figures.
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, RoutePlan} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockSolidlyPair} from "./mocks/MockSolidlyPair.sol";

contract SolidlyProofQuotesThePairFigureTest is Test {
    bytes32 constant TOPIC = keccak256(
        "ExecutionProof(address,address,uint256,uint256,uint256,uint256)"
    );

    uint112 constant RESERVE = 1_000_000e18;
    uint256 constant AMT     = 1_000e18;
    address constant USER    = address(0xBEEF);

    BlazePhoenixSolver internal solver;
    BlazePhoenixRouter internal router;
    MockERC20 internal tIn;
    MockERC20 internal tOut;   // not a bridge: no output-side fee
    MockSolidlyPair internal pair;

    /// @dev A fresh world per call, so both curves see identical reserves and
    ///      amount without the Solver choosing between them.
    function _world(bool stable) internal {
        BlazePhoenixHub hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        solver = new BlazePhoenixSolver(address(hub));
        router = new BlazePhoenixRouter(
            address(hub), address(solver), address(this), address(0xFEE1), address(0xFEE2)
        );
        hub.setRoles(address(router), address(solver), address(this));

        tIn  = new MockERC20("IN", "IN");
        tOut = new MockERC20("OUT", "OUT");
        pair = new MockSolidlyPair(address(tIn), address(tOut), stable);
        tIn.mint(address(pair), RESERVE);
        tOut.mint(address(pair), RESERVE);
        pair.setReserves(RESERVE, RESERVE);
        hub.seedPool(address(pair), BPC.KIND_SOLIDLY, 30, address(0), address(tIn), address(tOut));

        tIn.mint(USER, 10 * AMT);
        vm.prank(USER);
        tIn.approve(address(router), type(uint256).max);
    }

    /// @dev Swaps AMT through the Solver's plan; returns the proof's figures
    ///      and the delivery measured at the recipient.
    function _run(bool stable) internal returns (uint256 quoted, uint256 realized, uint256 delivered) {
        _world(stable);
        RoutePlan memory plan = solver.findBestRoutePlan(address(tIn), address(tOut), AMT);
        assertEq(plan.best.hops.length, 1, "setup: one hop");
        assertEq(plan.best.hops[0].legs.length, 1, "setup: one leg");

        uint256 before = tOut.balanceOf(USER);
        vm.recordLogs();
        vm.prank(USER);
        router.swapExactIn(plan.best, AMT, 1, USER, block.timestamp + 1);
        delivered = tOut.balanceOf(USER) - before;
        (quoted, realized) = _proof();
    }

    function _proof() internal returns (uint256 quoted, uint256 realized) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool seen;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == TOPIC) {
                (quoted, realized, , ) = abi.decode(logs[i].data, (uint256, uint256, uint256, uint256));
                seen = true;
            }
        }
        assertTrue(seen, "setup: the Router emits ExecutionProof");
    }

    /// @notice Core: the ask is the pair's own figure less one wei.
    function test_SolidlyAskIsThePairFigureLessOneWei() public {
        _run(false);
        uint256 figure = BPC.solidlyGetAmountOut(address(pair), AMT, address(tIn));
        uint256 ask = BPC.solidlyAskOut(
            address(pair), AMT, address(tIn), address(tIn) == pair.token0(), false, 30
        );
        assertGt(figure, 1, "setup: the pair answers (not the fallback)");
        assertEq(ask, figure - 1, "the ask is the pair's figure less one wei");
    }

    /// @notice The proof quotes the pair's figure and realizes the ask, on both
    ///         curves; `realized` is the measured delivery.
    function test_SolidlyProof_QuotesTheFigureAndRealizesTheAsk_BothCurves() public {
        (uint256 qS, uint256 rS, uint256 dS) = _run(true);
        (uint256 qV, uint256 rV, uint256 dV) = _run(false);
        assertEq(rS, dS, "stable: realized is the measured delivery");
        assertEq(rV, dV, "volatile: realized is the measured delivery");
        assertEq(rS + 1, qS, "stable: realized is the quoted figure less the one-wei ask margin");
        assertEq(rV + 1, qV, "volatile: realized is the quoted figure less the one-wei ask margin");
    }

    /// @notice The published quote follows the leg's curve: identical reserves
    ///         and amount give different figures on the two curves.
    function test_SolidlyProof_QuoteFollowsTheLegCurve() public {
        (uint256 qS, , ) = _run(true);
        (uint256 qV, , ) = _run(false);
        assertGt(qS, 0, "setup: the stable leg is quoted");
        assertGt(qV, 0, "setup: the volatile leg is quoted");
        assertTrue(qS != qV, "the published quote must come from the leg's own curve");
    }
}
