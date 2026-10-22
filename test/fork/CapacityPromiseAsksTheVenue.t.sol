// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  3073 (M2000 Slash; 3212, 3230): a concentrated leg whose quote passes the
//  Solver's capacity cap (MAX_CONC_DRAIN_BPS, 30 % of the pool's tokenOut
//  holdings) but stays within those holdings keeps its whole input. Its promise
//  used to be the cap itself: an output bound standing in for the venue's answer
//  for the input actually committed. Measured at Base block 52,900,000, DAI->USDC
//  10k: three V3 legs promised at the cap, delivery 19 % above netOut.
//
//  The property pinned here, per leg and per route:
//    leg:   cap <= leg.expectedOut <= the pool's own dry-run of leg.amountIn
//           (previewPlanExact), and within 1 bps of it;
//    route: netOut <= delivered <= netOut * (1 + 10 bps).
//  Dimensions: size (10k, 15k, 20k; at 5k the cap binds no leg), venue family (Uniswap V3, SushiSwap V3,
//  PancakeSwap V3, all fee 100 / spacing 1), split and single-leg plans.
//  At 20k the PancakeSwap V3 leg's book needs more than the walk's sixteen stretches
//  (V4_WALK_MAX_STEPS): its walk stops short of the cap, so the promise stays at the cap,
//  a lower bound on what the pool pays. That size pins the two bounds alone.
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BaseTestDeploy} from "./BaseTestDeploy.sol";
import {BlazePhoenixHub} from "../../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../../src/BlazePhoenixRouter.sol";
import {BlazePhoenixQuoter} from "../../src/BlazePhoenixQuoter.sol";
import {BlazePhoenixCore as BPC, Route} from "../../src/BlazePhoenixCore.sol";

interface IERC20CP {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

contract CapacityPromiseAsksTheVenueTest is Test {
    uint256 internal constant BLK = 52_900_000;
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant DAI  = 0x50c5725949A6F0c72E6C4a641F24049A917DB0Cb;

    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    BlazePhoenixRouter router;
    BlazePhoenixQuoter quoter;
    address user = address(0xD1A6);

    function setUp() public {
        vm.createSelectFork("base", BLK);
        (hub, solver, router, quoter) = BaseTestDeploy.deploy(address(this));
    }

    /// @dev Every concentrated leg the cap bound: promise between the cap and the pool's
    ///      own answer, within 1 bps of it. Returns how many legs the cap bound.
    function _legsAskTheVenue(Route memory plan, Route memory exact, bool walked) internal view returns (uint256 bound) {
        for (uint256 h; h < plan.hops.length; ++h) {
            for (uint256 l; l < plan.hops[h].legs.length; ++l) {
                if (!BPC.kindHas(plan.hops[h].legs[l].kind, BPC.A_CONC_POOL)) continue;
                address tOut = plan.hops[h].tokenOut;
                uint256 cap = IERC20CP(tOut).balanceOf(plan.hops[h].legs[l].pool) * 3_000 / 10_000;
                uint256 promised = plan.hops[h].legs[l].expectedOut;
                uint256 pool = exact.hops[h].legs[l].expectedOut;
                assertEq(exact.hops[h].legs[l].amountIn, plan.hops[h].legs[l].amountIn, "same committed input");
                if (pool <= cap) continue;   // the cap does not bind this leg
                ++bound;
                assertGe(promised, cap, "the venue's answer never lowers the capped promise");
                assertLe(promised, pool, "the promise never exceeds what the pool pays");
                if (walked) assertLe(pool - promised, pool / 10_000, "the promise is the pool's answer (<= 1 bps)");
            }
        }
    }

    function _case(address tIn, address tOut, uint256 amt, bool walked) internal {
        (BlazePhoenixQuoter.Preview memory pv,,) = quoter.previewPlan(tIn, tOut, amt);
        (Route memory ex,) = quoter.previewPlanExact(tIn, tOut, amt);
        assertGt(_legsAskTheVenue(pv.route, ex, walked), 0, "precondition: the capacity cap binds a leg");

        deal(tIn, user, amt);
        vm.prank(user);
        IERC20CP(tIn).approve(address(router), type(uint256).max);
        Route memory r = pv.route;
        uint256 minOut = pv.effectiveMinOut;
        uint256 b0 = IERC20CP(tOut).balanceOf(user);
        vm.prank(user);
        router.swapExactIn(r, amt, minOut, user, block.timestamp + 600);
        uint256 delivered = IERC20CP(tOut).balanceOf(user) - b0;
        assertGe(delivered, pv.netOut, "Q1: the plan's netOut rounds down");
        if (walked) assertLe(delivered - pv.netOut, pv.netOut / 1_000, "netOut within 10 bps of delivery");
    }

    function test_3073_DaiUsdc_10k_PromiseIsTheVenueAnswer() public { _case(DAI, USDC, 10_000 ether, true); }
    function test_3073_DaiUsdc_15k_PromiseIsTheVenueAnswer() public { _case(DAI, USDC, 15_000 ether, true); }
    function test_3073_DaiUsdc_20k_PastTheWalk_PromiseStaysWithinItsBounds() public {
        _case(DAI, USDC, 20_000 ether, false);
    }
}
