// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixQuoter} from "../src/BlazePhoenixQuoter.sol";
import {
    BlazePhoenixCore as BPC,
    Route, Hop, Leg, RoutePlan
} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";
import {MockV3Pool} from "./mocks/MockV3Pool.sol";

/// @notice Coverage for BlazePhoenixQuoter — previously zero tests (see
///         TESTING.md "Known gaps"). Exercises previewPlan / previewRoute /
///         batchQuote packing math, the documented fee-vs-floor divergence
///         from the Router's real execution path, and previewPlanExact's
///         revert-extraction dry-run (both the V3 callback path and the
///         plain-formula V2 path).
contract BlazePhoenixQuoterTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    BlazePhoenixQuoter quoter;

    MockERC20 tokenA;
    MockERC20 tokenB;

    uint16 constant PROTOCOL_FEE_BPS = BPC.PROTOCOL_FEE_BPS;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        solver = new BlazePhoenixSolver(address(hub));
        quoter = new BlazePhoenixQuoter(address(hub), address(solver));

        tokenA = new MockERC20("A", "A");
        tokenB = new MockERC20("B", "B");
    }

    // ─── helpers ──────────────────────────────────────────────────────

    function _seedV2(address tX, address tY, uint256 reserveX, uint256 reserveY)
        internal returns (MockV2Pair p)
    {
        p = new MockV2Pair(tX, tY);
        MockERC20(tX).mint(address(p), reserveX);
        MockERC20(tY).mint(address(p), reserveY);
        (address t0, ) = tX < tY ? (tX, tY) : (tY, tX);
        p.setReserves(
            uint112(tX == t0 ? reserveX : reserveY),
            uint112(tX == t0 ? reserveY : reserveX)
        );
        hub.seedPool(address(p), BPC.KIND_V2, 30, address(0), tX, tY);
    }

    function _buildSingleLegRoute(address pool, uint256 amountIn, uint256 totalOut, uint256 floor)
        internal view returns (Route memory route)
    {
        Leg[] memory legs = new Leg[](1);
        legs[0] = Leg({
            pool: pool, hooks: address(0), kind: BPC.KIND_V2, fee: 30,
            tickSpacing: 0, zeroForOne: address(tokenA) < address(tokenB), stable: false,
            amountIn: amountIn, expectedOut: totalOut, auxId: bytes32(0)
        });
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({
            tokenIn: address(tokenA), tokenOut: address(tokenB),
            amountIn: amountIn, expectedOut: totalOut, legs: legs
        });
        route = Route({
            hops: hops, totalOut: totalOut, singleOut: totalOut,
            singleOutFloor: floor, expectedImpactBps: 0, confidenceWad: 0,
            estGas: 0, hasSurplus: totalOut > floor, isV4Bundle: false
        });
    }

    function _buildRouteWithNLegs(uint256 legCount, uint256 totalOut)
        internal pure returns (Route memory route)
    {
        Leg[] memory legs = new Leg[](legCount);
        for (uint256 i; i < legCount; ++i) {
            legs[i] = Leg({
                pool: address(uint160(i + 1)), hooks: address(0), kind: BPC.KIND_V2, fee: 30,
                tickSpacing: 0, zeroForOne: true, stable: false,
                amountIn: 1, expectedOut: 1, auxId: bytes32(0)
            });
        }
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({
            tokenIn: address(0x1), tokenOut: address(0x2),
            amountIn: 1, expectedOut: totalOut, legs: legs
        });
        route = Route({
            hops: hops, totalOut: totalOut, singleOut: totalOut,
            singleOutFloor: 0, expectedImpactBps: 0, confidenceWad: 0,
            estGas: 0, hasSurplus: true, isV4Bundle: false
        });
    }

    // =========================================================================
    //  previewPlan
    // =========================================================================

    function test_PreviewPlan_MatchesSolverRoute() public {
        MockV2Pair pool = _seedV2(address(tokenA), address(tokenB), 100_000e18, 160_000e18);
        uint256 amountIn = 1_000e18;

        (BlazePhoenixQuoter.Preview memory pv, , bool hasFallback) =
            quoter.previewPlan(address(tokenA), address(tokenB), amountIn);

        uint256 expectedOut = BPC.outV2(amountIn, 100_000e18, 160_000e18, 30);
        assertEq(pv.grossOut, expectedOut);
        assertEq(pv.route.hops[0].legs[0].pool, address(pool));
        assertFalse(hasFallback);

        uint256 expectedFee = BPC.mulDiv(expectedOut, PROTOCOL_FEE_BPS, BPC.BPS);
        assertEq(pv.protocolFee, expectedFee);
        assertEq(pv.netOut, expectedOut - expectedFee, "legs<=2 -> zero safety buffer");
        assertTrue(pv.canExecute);
    }

    function test_PreviewPlan_RevertsPropagateWhenNoRouteExists() public {
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixSolver.SolverE.selector, 5));
        quoter.previewPlan(address(tokenA), address(tokenB), 1_000e18);
    }

    // =========================================================================
    //  previewPlanWithMinOut — effectiveMinOut = max(userMinOut, ironFloor)
    // =========================================================================

    function test_PreviewPlanWithMinOut_UserBoundTighterThanFloor() public {
        _seedV2(address(tokenA), address(tokenB), 100_000e18, 160_000e18);
        (BlazePhoenixQuoter.Preview memory pv, , ) =
            quoter.previewPlanWithMinOut(address(tokenA), address(tokenB), 1_000e18, type(uint128).max);
        assertEq(pv.effectiveMinOut, type(uint128).max, "user bound must win when it is the tighter one");
    }

    function test_PreviewPlanWithMinOut_FloorTighterThanUserBound() public {
        _seedV2(address(tokenA), address(tokenB), 100_000e18, 160_000e18);
        (BlazePhoenixQuoter.Preview memory pv, , ) =
            quoter.previewPlanWithMinOut(address(tokenA), address(tokenB), 1_000e18, 0);
        assertEq(pv.effectiveMinOut, pv.ironFloor, "floor must win when userMinOut is looser (0)");
        assertGt(pv.ironFloor, 0);
    }

    // =========================================================================
    //  previewRoute — pure packer, exact formula checks
    // =========================================================================

    function test_PreviewRoute_FeeAndNetOutFormula() public view {
        Route memory route = _buildSingleLegRoute(address(0xCAFE), 1_000e18, 100_000e18, 90_000e18);
        BlazePhoenixQuoter.Preview memory pv = quoter.previewRoute(route, 0);

        uint256 expectedFee = BPC.mulDiv(100_000e18, PROTOCOL_FEE_BPS, BPC.BPS);
        assertEq(pv.protocolFee, expectedFee);
        assertEq(pv.netOut, 100_000e18 - expectedFee);
        assertEq(pv.ironFloor, 90_000e18);
        assertEq(pv.hops, 1);
        assertEq(pv.legs, 1);
    }

    function test_PreviewRoute_SafetyBufferZeroAtOrBelowTwoLegs() public view {
        Route memory route = _buildRouteWithNLegs(2, 100_000e18);
        BlazePhoenixQuoter.Preview memory pv = quoter.previewRoute(route, 0);
        assertEq(pv.safetyBuffer, 0);
    }

    function test_PreviewRoute_SafetyBufferScalesPerLegAboveTwo() public view {
        Route memory route = _buildRouteWithNLegs(5, 100_000e18);
        BlazePhoenixQuoter.Preview memory pv = quoter.previewRoute(route, 0);
        uint256 afterFee = 100_000e18 - BPC.mulDiv(100_000e18, PROTOCOL_FEE_BPS, BPC.BPS);
        uint256 expectedSafety = BPC.mulDiv(afterFee, 3, BPC.BPS); // (5-2)*1 = 3 bps
        assertEq(pv.safetyBuffer, expectedSafety);
    }

    function test_PreviewRoute_SafetyBufferCapsAtTenBps() public view {
        Route memory route = _buildRouteWithNLegs(50, 100_000e18); // far above the cap
        BlazePhoenixQuoter.Preview memory pv = quoter.previewRoute(route, 0);
        uint256 afterFee = 100_000e18 - BPC.mulDiv(100_000e18, PROTOCOL_FEE_BPS, BPC.BPS);
        uint256 expectedSafety = BPC.mulDiv(afterFee, 10, BPC.BPS); // capped at SAFETY_CAP_BPS
        assertEq(pv.safetyBuffer, expectedSafety);
    }

    function test_PreviewRoute_CanExecuteFalseWhenNetOutBelowFloor() public view {
        // Floor above net output -> not executable.
        Route memory route = _buildSingleLegRoute(address(0xCAFE), 1_000e18, 1_000e18, 999e18);
        BlazePhoenixQuoter.Preview memory pv = quoter.previewRoute(route, 0);
        assertFalse(pv.canExecute);
    }

    function test_PreviewRoute_ClassifyAlwaysDirectInV2() public view {
        Route memory route = _buildSingleLegRoute(address(0xCAFE), 1_000e18, 100_000e18, 90_000e18);
        BlazePhoenixQuoter.Preview memory pv = quoter.previewRoute(route, 0);
        assertEq(pv.topology, 0);
        assertEq(pv.bridgeUsed, address(0));
    }

    /// @notice Documents the deliberate divergence (see the Quoter's header
    ///         NOTE and vault note 052): _pack's protocolFee tracks
    ///         route.totalOut ALONE and never reads singleOutFloor — unlike
    ///         the Router's real _execute, which can raise the fee base up to
    ///         protocolFloorOut in a degraded fill. Lowering the floor here
    ///         must NOT move the previewed fee.
    function test_PreviewRoute_FeeIgnoresFloorByDesign() public view {
        Route memory routeHighFloor = _buildSingleLegRoute(address(0xCAFE), 1_000e18, 100_000e18, 95_000e18);
        Route memory routeLowFloor  = _buildSingleLegRoute(address(0xCAFE), 1_000e18, 100_000e18, 1);
        BlazePhoenixQuoter.Preview memory pvHigh = quoter.previewRoute(routeHighFloor, 0);
        BlazePhoenixQuoter.Preview memory pvLow  = quoter.previewRoute(routeLowFloor, 0);
        assertEq(pvHigh.protocolFee, pvLow.protocolFee,
            "preview fee must be floor-independent, unlike the Router's real fee base");
    }

    // =========================================================================
    //  batchQuote
    // =========================================================================

    function test_BatchQuote_RevertsAboveMaxBatch() public {
        BlazePhoenixQuoter.BatchEntry[] memory entries = new BlazePhoenixQuoter.BatchEntry[](33);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixQuoter.QuoterE.selector, 4));
        quoter.batchQuote(entries);
    }

    function test_BatchQuote_MixedSuccessAndSwallowedFailure() public {
        _seedV2(address(tokenA), address(tokenB), 100_000e18, 160_000e18);
        MockERC20 tokenC = new MockERC20("C", "C"); // no pool -> Solver reverts for this pair

        BlazePhoenixQuoter.BatchEntry[] memory entries = new BlazePhoenixQuoter.BatchEntry[](2);
        entries[0] = BlazePhoenixQuoter.BatchEntry({
            tIn: address(tokenA), tOut: address(tokenB), amountIn: 1_000e18, userMinOut: 0
        });
        entries[1] = BlazePhoenixQuoter.BatchEntry({
            tIn: address(tokenA), tOut: address(tokenC), amountIn: 1_000e18, userMinOut: 0
        });

        BlazePhoenixQuoter.Preview[] memory previews = quoter.batchQuote(entries);

        assertGt(previews[0].grossOut, 0, "entry with a real route must quote normally");
        assertEq(previews[1].grossOut, 0, "entry with no route must be silently zero, not revert the batch");
    }

    // =========================================================================
    //  previewPlanExact — revert-extraction dry-run
    // =========================================================================

    function test_PreviewPlanExact_V2Leg_MatchesFormula() public {
        _seedV2(address(tokenA), address(tokenB), 100_000e18, 160_000e18);
        uint256 amountIn = 1_000e18;

        (, uint256 exactOut) = quoter.previewPlanExact(address(tokenA), address(tokenB), amountIn);

        assertEq(exactOut, BPC.outV2(amountIn, 100_000e18, 160_000e18, 30));
    }

    function test_PreviewPlanExact_V3Leg_DryRunMatchesPoolMath() public {
        bool zfo = address(tokenA) < address(tokenB);
        MockV3Pool pool = new MockV3Pool(address(tokenA), address(tokenB), 3000);
        uint160 sqrtP = uint160(BPC.Q96);
        uint128 liq = 1_000_000e18;
        pool.setState(sqrtP, liq);
        // Ample real holdings so the Solver's capacity clamp never engages,
        // keeping the planned leg input == the full amountIn.
        tokenB.mint(address(pool), 1_000_000e18);
        hub.seedPool(address(pool), BPC.KIND_V3, 3000, address(0), address(tokenA), address(tokenB));

        uint256 amountIn = 2_000e18;
        (, uint256 exactOut) = quoter.previewPlanExact(address(tokenA), address(tokenB), amountIn);

        uint256 expected = BPC.outV3(amountIn, sqrtP, liq, 3000, zfo);
        assertEq(exactOut, expected, "dry-run must match the pool's own swap math exactly");
    }

    function test_PreviewPlanExact_RevertsWhenNoRouteExists() public {
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixSolver.SolverE.selector, 5));
        quoter.previewPlanExact(address(tokenA), address(tokenB), 1_000e18);
    }

    // =========================================================================
    //  Callback-misuse guards
    // =========================================================================

    function test_Fallback_RevertsOnShortCalldata() public {
        (bool ok, bytes memory ret) = address(quoter).call(hex"aabbccdd");
        assertFalse(ok);
        assertEq(bytes4(ret), BlazePhoenixQuoter.QuoterE.selector);
    }

    function test_UnlockCallback_RevertsWhenNotV4Manager() public {
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixQuoter.QuoterE.selector, 6));
        quoter.unlockCallback("");
    }

    // =========================================================================
    //  Bridge passthrough views
    // =========================================================================

    function test_BridgeViews_PassThroughToHub() public {
        MockERC20 bridgeToken = new MockERC20("BR", "BR");
        hub.addBridge(address(bridgeToken));
        assertEq(quoter.bridgesCount(), 1);
        assertEq(quoter.bridgeAt(0), address(bridgeToken));
        assertTrue(quoter.isBridge(address(bridgeToken)));
        assertFalse(quoter.isBridge(address(tokenA)));
    }
}
