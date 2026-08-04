// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../../src/BlazePhoenixRouter.sol";
import {BlazePhoenixQuoter} from "../../src/BlazePhoenixQuoter.sol";
import {BlazePhoenixCore as BPC} from "../../src/BlazePhoenixCore.sol";

interface IERC20Fork {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

/// @notice Fork test against REAL Curve 3pool on Ethereum mainnet (DAI/USDC/
///         USDT, 0xbEbc44782C7dB0a1A60Cb6fe97d0b483032FF1C7) — exercises the
///         "ask the pool, never replicate" Curve adapter (curveResolveIndices
///         / curveGetDy / exchange) against real Curve bytecode, which no
///         mock can validate (Curve's coins()/get_dy() ABI quirks — int128
///         vs uint256 signature variants — only show up against the real
///         thing). Registered directly via seedPool rather than through
///         Hub.discoverFor's Curve meta-registry scan, so this test does not
///         depend on knowing the exact on-chain registry address (a separate,
///         lower-confidence detail); it isolates and proves the EXECUTION
///         adapter instead.
contract EthereumCurveForkTest is Test {
    address constant CURVE_3POOL = 0xbEbc44782C7dB0a1A60Cb6fe97d0b483032FF1C7;
    address constant DAI  = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;

    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    BlazePhoenixRouter router;
    BlazePhoenixQuoter quoter;

    function setUp() public {
        vm.createSelectFork("mainnet");

        hub = new BlazePhoenixHub();
        hub.initialize(address(this), address(0));
        solver = new BlazePhoenixSolver(address(hub));
        router = new BlazePhoenixRouter(address(hub), address(solver), address(this), address(0xFEE1), address(0xFEE2));
        quoter = new BlazePhoenixQuoter(address(hub), address(solver));
        hub.setRoles(address(router), address(solver), address(quoter));

        hub.seedPool(CURVE_3POOL, BPC.KIND_STABLE, 0, address(0), USDC, DAI);
    }

    function test_CurveResolveIndices_MatchesRealPoolCoins() public view {
        (int128 i, int128 j, bool ok) = BPC.curveResolveIndices(CURVE_3POOL, USDC, DAI);
        assertTrue(ok);
        // 3pool's canonical order is DAI=0, USDC=1, USDT=2.
        assertEq(i, 1, "USDC must resolve to coins() index 1");
        assertEq(j, 0, "DAI must resolve to coins() index 0");
    }

    function test_CurveGetDy_ReturnsRealPoolQuote() public view {
        uint256 amountIn = 1_000e6; // 1,000 USDC
        (int128 i, int128 j, bool ok) = BPC.curveResolveIndices(CURVE_3POOL, USDC, DAI);
        assertTrue(ok);
        uint256 dy = BPC.curveGetDy(CURVE_3POOL, i, j, amountIn);
        console2.log("3pool USDC->DAI quote (wei DAI):", dy);
        // A balanced stable pool should quote close to 1:1 (18 decimals out
        // for 6-decimal-scaled input) — a loose band, not a peg assertion.
        assertGt(dy, 900e18);
        assertLt(dy, 1_100e18);
    }

    function test_Preview_USDCtoDAI_ViaCurveAdapter() public {
        uint256 amountIn = 1_000e6;
        (BlazePhoenixQuoter.Preview memory pv, , ) = quoter.previewPlan(USDC, DAI, amountIn);
        console2.log("Solver-routed USDC->DAI grossOut:", pv.grossOut);
        assertGt(pv.grossOut, 0, "Solver must find and quote the seeded Curve pool");
        assertEq(pv.route.hops[0].legs[0].pool, CURVE_3POOL);
        assertEq(pv.route.hops[0].legs[0].kind, BPC.KIND_STABLE);
    }

    /// @notice Full execution: exchange() on the REAL 3pool, verified by the
    ///         Router's own balance-delta check (not trusted return data) —
    ///         the exact defence documented in BlazePhoenixRouter._execCurveAmt
    ///         against tricrypto-NG-style pools that accept the int128
    ///         selector without reverting but pay out 0.
    function test_Execute_USDCtoDAI_AgainstRealCurve3Pool() public {
        address user = address(0xBEEF);
        uint256 amountIn = 1_000e6;
        deal(USDC, user, amountIn);

        vm.prank(user);
        IERC20Fork(USDC).approve(address(router), amountIn);

        (BlazePhoenixQuoter.Preview memory pv, , ) = quoter.previewPlan(USDC, DAI, amountIn);
        assertGt(pv.grossOut, 0);

        vm.prank(user);
        uint256 delivered = router.swapExactIn(pv.route, amountIn, 0, user, block.timestamp + 60);

        console2.log("delivered (wei DAI):", delivered);
        assertGt(delivered, 0);
        assertEq(IERC20Fork(DAI).balanceOf(user), delivered);
        assertEq(IERC20Fork(USDC).balanceOf(address(router)), 0);
        assertEq(IERC20Fork(DAI).balanceOf(address(router)), 0);
    }
}
