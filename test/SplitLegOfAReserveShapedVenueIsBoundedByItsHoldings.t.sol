// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  A SPLIT LEG ON A RESERVE-SHAPED VENUE IS NEVER PROMISED ABOVE ITS HOLDINGS.
//
//  Red against mutant [333] of .github/scripts/mutants.py at 59ecf3f; green on 59ecf3f.
//
//  The split drops a reserve-shaped leg whose quote exceeds the venue's tokenOut
//  balance (Solver, `outL > balsOut[i]`). Since bounty #85 a pair whose reserves
//  exceed its holdings quotes (0, 0) in Core.universalQuote, so a V2 pair can no
//  longer reach that line with a forged promise: its quote is x*y=k on reserves it
//  holds, below its reserveOut. A Solidly pair can. Its quote is its OWN
//  getAmountOut (Core.solidlyAskOut), and holding the reserves it declares says
//  nothing about what that function answers. The pair below holds what it declares,
//  answers honestly at the probe (so the rate band keeps it) and, at the size of a
//  split share, is asked one wei more than it holds: its getAmountOut answers two wei
//  over, and the ask the Solver prices (Core.solidlyAskOut) is that less one wei.
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixCore as BPC, RoutePlan, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";
import {MockSolidlyPair} from "./mocks/MockSolidlyPair.sol";

/// @dev Holds exactly the reserves it reports; its getAmountOut is honest up to LIE_FROM
///      and, above it, answers its whole tokenOut balance plus two wei, so the ask the
///      Solver prices (Core.solidlyAskOut: getAmountOut less one wei) is one wei above it.
contract OverAskingSolidlyPair is MockSolidlyPair {
    uint256 public immutable LIE_FROM;
    constructor(address a, address b, uint256 lieFrom) MockSolidlyPair(a, b, false) { LIE_FROM = lieFrom; }
    function getAmountOut(uint256 amountIn, address tokenIn) public view override returns (uint256) {
        if (amountIn <= LIE_FROM) return super.getAmountOut(amountIn, tokenIn);
        address tokenOut = tokenIn == token0 ? token1 : token0;
        return MockERC20(tokenOut).balanceOf(address(this)) + 2;
    }
}

contract SplitLegOfAReserveShapedVenueIsBoundedByItsHoldingsTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    MockERC20 A;
    MockERC20 B;
    MockV2Pair honest;
    OverAskingSolidlyPair liar;

    uint256 constant R = 1e24;            // each venue's reserves, held on both sides
    uint256 constant AMT = 1e21;          // the order; the probe is AMT / 100
    uint256 constant LIE_FROM = AMT / 10; // above the probe, below a split share

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        solver = new BlazePhoenixSolver(address(hub), address(0));
        A = new MockERC20("A", "A");
        B = new MockERC20("B", "B");
        (address t0, address t1) = address(A) < address(B) ? (address(A), address(B)) : (address(B), address(A));

        honest = new MockV2Pair(t0, t1);
        MockERC20(t0).mint(address(honest), R);
        MockERC20(t1).mint(address(honest), R);
        honest.setReserves(uint112(R), uint112(R));
        hub.seedPool(address(honest), BPC.KIND_V2, 30, address(0), t0, t1);

        liar = new OverAskingSolidlyPair(t0, t1, LIE_FROM);
        MockERC20(t0).mint(address(liar), R);
        MockERC20(t1).mint(address(liar), R);
        liar.setReserves(uint112(R), uint112(R));
        hub.seedPool(address(liar), BPC.KIND_SOLIDLY, 30, address(0), t0, t1);
    }

    function test_ASplitLegOnAReserveShapedVenueIsNeverPromisedAboveItsHoldings() public view {
        // Fixture: both venues are honest at the probe, so the band keeps both, and the
        // reserve door (bounty #85) passes the liar - it holds every unit it reports.
        assertEq(liar.getAmountOut(AMT / 100, address(A)), BPC.outV2(AMT / 100, R, R, 30), "fixture: honest at the probe");
        assertGt(liar.getAmountOut(AMT / 2, address(A)) - 1, B.balanceOf(address(liar)),
            "fixture: its ask (getAmountOut less one wei) exceeds its holdings at a split share");
        RoutePlan memory plan = solver.findBestRoutePlan(address(A), address(B), AMT);
        assertGt(plan.best.totalOut, 0, "control: the honest venue still routes the order");
        for (uint256 h; h < plan.best.hops.length; h++) {
            Leg[] memory legs = plan.best.hops[h].legs;
            for (uint256 l; l < legs.length; l++) {
                assertLe(legs[l].expectedOut, B.balanceOf(legs[l].pool), "a leg was promised above its venue's holdings");
            }
        }
        // Oracle independent of the code under test: x*y=k at 30 bps on one book holding both
        // venues' reserves (2R a side). Two equal x*y=k books split at best 50/50, which is
        // exactly that book; a plan priced on what the venues hold cannot promise more.
        uint256 ain = AMT * 9970;
        uint256 bound = ain * (2 * R) / ((2 * R) * 10000 + ain);
        assertLe(plan.best.totalOut, bound, "the plan promises more than the venues' holdings can pay");
    }
}
