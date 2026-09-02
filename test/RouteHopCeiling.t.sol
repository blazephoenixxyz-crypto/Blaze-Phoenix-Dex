// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  F8 — THERE IS NO PRODUCER OF "HOW MANY HOPS FIT IN A ROUTE".
//
//      grep -rn "MAX_HOPS" src/     ->  nothing
//
//  The Router bounds legs per hop (MAX_LEGS_PER_HOP = 5, checked at Router:1042)
//  and the Solver bounds legs globally and per stage (MAX_LEGS = 11,
//  MAX_LEGS_PER_STAGE = 4). `route.hops.length` is unbounded at all four doors.
//  Three consequences, none of them theft:
//
//   1. `executedMask` is a uint256 and `legIdx` runs across the WHOLE route
//      (Router:1037-1038, Router:1207). Past leg 255 the shift yields 0 and the
//      leg is silently not credited. Router:1033-1036 documents that as
//      fail-closed — correct — but justifies it with "unreachable anyway with
//      MAX_LEGS_PER_HOP at 5", which uses a PER-HOP constant to bound a
//      PER-ROUTE quantity. It is only true because nobody sends 52 hops.
//
//   2. In the fee-exhaustion regime (no hop input is a bridge, Router:1024-1028)
//      the fee is charged on EVERY hop. An unbounded hop count therefore has an
//      unbounded effective fee rate. Self-harm, but it is the one place where
//      the published "28 bps" has no ceiling written in code.
//
//   3. `bridgeBase = new uint256[](route.hops.length)` (Router:992), plus one
//      `hub.isBridgeToken` staticcall per hop before the loop.
//
//  SHARED_QUANTITIES.md lists PIN-01 (MAX_LEGS_PER_STAGE 4 vs MAX_LEGS_PER_HOP 5)
//  as the leg-count disagreement. The hop count is the sibling row that does not
//  exist: two producers could at least disagree; here there is none.
//
//  forge test --match-contract RouteHopCeiling -vv
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";

contract RouteHopCeilingTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    BlazePhoenixRouter router;

    MockERC20 tokenA; MockERC20 tokenB;
    MockV2Pair pool;

    address user = address(0xBEEF);
    address constant T1 = address(0xFEE1);
    address constant T2 = address(0xFEE2);

    uint256 constant AMT = 100e18;
    uint112 constant RESERVE = uint112(10_000_000e18);

    /// Odd, so the last hop ends in tokenB and the route is not the degenerate
    /// tokenIn == tokenOut case. Far beyond anything the Solver can build
    /// (MAX_LEGS = 11 caps it at three hops).
    uint256 constant HOPS = 61;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        solver = new BlazePhoenixSolver(address(hub));
        router = new BlazePhoenixRouter(address(hub), address(solver), address(this), T1, T2);
        hub.setRoles(address(router), address(solver), address(this));

        tokenA = new MockERC20("A", "A");
        tokenB = new MockERC20("B", "B");
        pool = new MockV2Pair(address(tokenA), address(tokenB));
        tokenA.mint(address(pool), uint256(RESERVE));
        tokenB.mint(address(pool), uint256(RESERVE));
        pool.setReserves(RESERVE, RESERVE);

        hub.seedPool(address(pool), BPC.KIND_V2, 30, address(0), address(tokenA), address(tokenB));

        tokenA.mint(user, 1_000_000e18);
        vm.prank(user);
        tokenA.approve(address(router), type(uint256).max);
    }

    /// A route that bounces A -> B -> A -> ... through the SAME pool. Continuity
    /// holds at every seam (hops[h].tokenIn == hops[h-1].tokenOut), which is the
    /// only structural rule Router:1058 imposes between hops.
    function _pingPongRoute(uint256 n) internal view returns (Route memory r) {
        Hop[] memory hops = new Hop[](n);
        for (uint256 h; h < n; ++h) {
            address tIn  = h % 2 == 0 ? address(tokenA) : address(tokenB);
            address tOut = h % 2 == 0 ? address(tokenB) : address(tokenA);
            Leg[] memory legs = new Leg[](1);
            legs[0] = Leg({
                pool: address(pool),
                hooks: address(0),
                kind: BPC.KIND_V2,
                fee: 30,
                tickSpacing: 0,
                zeroForOne: pool.token0() == tIn,
                stable: false,
                amountIn: AMT,
                expectedOut: 0,
                auxId: bytes32(0)
            });
            hops[h] = Hop({tokenIn: tIn, tokenOut: tOut,
                           amountIn: AMT, expectedOut: 0, legs: legs});
        }
        r = Route({hops: hops, totalOut: 0, singleOut: 0, singleOutFloor: 0,
                   expectedImpactBps: 0, confidenceWad: 0, estGas: 0,
                   hasSurplus: false, isV4Bundle: false});
    }

    // ─── THE CLAIM UNDER TEST (RED TODAY) ────────────────────────────────────

    /// A route with 61 hops is not a route any producer in this system can
    /// build, and nothing refuses it. The Router should have a ceiling of its
    /// own, exactly as it has MAX_LEGS_PER_HOP.
    function test_RouteHopCountHasACeiling() public {
        Route memory r = _pingPongRoute(HOPS);   // built before the cheatcodes (the builder calls token0())
        vm.prank(user);
        vm.expectRevert();
        router.swapExactIn(r, AMT, 1, user, block.timestamp + 1);
    }

    /// The same fact as a measurement rather than a refusal: how much of the
    /// user's input the uncapped exhaustion-regime fee eats over 61 hops. Wrapped
    /// in try/catch so that the day a ceiling lands, this test passes by
    /// REFUSAL instead of becoming permanently broken.
    function test_ExhaustionRegimeFeeIsUnboundedInHopCount() public {
        uint256 t1Before = tokenA.balanceOf(T1) + tokenB.balanceOf(T1);
        uint256 t2Before = tokenA.balanceOf(T2) + tokenB.balanceOf(T2);

        Route memory r = _pingPongRoute(HOPS);
        vm.prank(user);
        try router.swapExactIn(r, AMT, 1, user, block.timestamp + 1)
            returns (uint256 got)
        {
            uint256 taken =
                (tokenA.balanceOf(T1) + tokenB.balanceOf(T1) - t1Before) +
                (tokenA.balanceOf(T2) + tokenB.balanceOf(T2) - t2Before);

            emit log_named_uint("hops                          ", HOPS);
            emit log_named_uint("user input                    ", AMT);
            emit log_named_uint("delivered                     ", got);
            emit log_named_uint("total taken by the treasuries ", taken);

            // No bridge is configured, so feeHop == type(uint256).max and the fee
            // is charged on EVERY hop (Router:1094). The published rate is 28 bps.
            assertLe(taken, BPC.mulDivUp(AMT, BPC.PROTOCOL_FEE_BPS, BPC.BPS) * 3,
                "the effective protocol rate grows without bound in the hop count, because nothing bounds the hop count");
        } catch {
            // Refused — a hop ceiling exists, which is the fix.
        }
    }

    // ─── CONTROLS ────────────────────────────────────────────────────────────

    /// Whatever ceiling is chosen must leave the Solver's own topologies alone:
    /// three hops is the deepest route _planViaTwoBridges can build.
    function test_ThreeHopRoute_StillRoutes() public {
        Route memory r = _pingPongRoute(3);
        vm.prank(user);
        uint256 got = router.swapExactIn(r, AMT, 1, user, block.timestamp + 1);
        assertGt(got, 0, "a 3-hop route is what the Solver builds and must keep working");
    }

    /// The executedMask boundary, documented without paying for a 256-hop route:
    /// past leg 255 the shift is 0, so the leg is not credited. Fail-closed, and
    /// only unreachable because nothing bounds hops.
    function test_ExecutedMaskSilentlyStopsAt256Legs() public view {
        uint256 idx = 255;
        assertTrue((uint256(1) << idx) != 0, "leg 255 still sets a bit");
        idx = 256;
        assertEq(uint256(1) << idx, 0,
            "leg 256 sets no bit: the mask silently stops crediting, and only the absence of long routes hides it");
    }
}
