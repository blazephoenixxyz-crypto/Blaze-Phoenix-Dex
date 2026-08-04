// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixQuoter} from "../src/BlazePhoenixQuoter.sol";
import {
    BlazePhoenixCore as BPC, Route, Hop, Leg, RoutePlan
} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";
import {MockV2Factory} from "./mocks/MockV2Factory.sol";

/// @notice Not correctness tests — a measurement harness. Every function
///         below logs a gas / price-impact / slippage figure via console2
///         and is meant to be read from `forge test --match-contract
///         GasReport -vv` output, not just green-vs-red. Numbers here are
///         mock-pool measurements (constant-product math, no real-world
///         MEV/latency) — directional and useful for relative comparisons
///         (legs vs legs, factories vs factories), not absolute gas budgets
///         for a mainnet deploy (use `forge test --gas-report` /
///         `[profile.release]` for that).
contract GasReportTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    BlazePhoenixRouter router;
    BlazePhoenixQuoter quoter;
    MockERC20 tokenIn;
    MockERC20 tokenOut;
    MockERC20 bridgeToken;
    address user = address(0xBEEF);

    function setUp() public {
        hub = new BlazePhoenixHub();
        hub.initialize(address(this), address(0));
        solver = new BlazePhoenixSolver(address(hub));
        router = new BlazePhoenixRouter(address(hub), address(solver), address(this), address(0xFEE1), address(0xFEE2));
        quoter = new BlazePhoenixQuoter(address(hub), address(solver));
        hub.setRoles(address(router), address(solver), address(quoter));

        tokenIn = new MockERC20("IN", "IN");
        tokenOut = new MockERC20("OUT", "OUT");
        bridgeToken = new MockERC20("BRIDGE", "BR");
    }

    function _seedPool(address a, address b, uint256 ra, uint256 rb) internal returns (MockV2Pair p) {
        p = new MockV2Pair(a, b);
        MockERC20(a).mint(address(p), ra);
        MockERC20(b).mint(address(p), rb);
        (address t0, ) = a < b ? (a, b) : (b, a);
        p.setReserves(uint112(a == t0 ? ra : rb), uint112(a == t0 ? rb : ra));
        hub.seedPool(address(p), BPC.KIND_V2, 30, address(0), a, b);
    }

    /// @dev Sets reserves in (tokenIn, tokenOut) terms regardless of the
    ///      pool's actual token0/token1 sort order — a raw `setReserves(r0,
    ///      r1)` call assumes an order that depends on the deployed mock
    ///      addresses, which is easy to get backwards by accident.
    function _setReservesInTokenInOutTerms(MockV2Pair pool, uint256 rTokenIn, uint256 rTokenOut) internal {
        bool tokenInIsToken0 = pool.token0() == address(tokenIn);
        pool.setReserves(
            uint112(tokenInIsToken0 ? rTokenIn : rTokenOut),
            uint112(tokenInIsToken0 ? rTokenOut : rTokenIn)
        );
    }

    function _swap(uint256 amountIn) internal returns (uint256 gasUsed, uint256 delivered) {
        RoutePlan memory plan = solver.findBestRoutePlan(address(tokenIn), address(tokenOut), amountIn);
        tokenIn.mint(user, amountIn);
        vm.prank(user);
        // Low-level call: a high-level `tokenIn.approve(...)` ABI-decodes the
        // return value, which reverts against a no-return-data (USDT-style)
        // token — the exact real-world gotcha safeApprove exists to avoid.
        // Using the same low-level shape here mirrors how a real integrator
        // must call approve() against such tokens too.
        (bool okApprove, ) = address(tokenIn).call(abi.encodeWithSignature("approve(address,uint256)", address(router), amountIn));
        require(okApprove, "approve failed");
        uint256 g0 = gasleft();
        vm.prank(user);
        delivered = router.swapExactIn(plan.best, amountIn, 0, user, block.timestamp + 1);
        gasUsed = g0 - gasleft();
    }

    // =========================================================================
    //  Legs scaling — marginal gas cost per extra leg within a single hop
    // =========================================================================

    function _reportLegs(uint256 n) internal {
        for (uint256 i; i < n; ++i) {
            _seedPool(address(tokenIn), address(tokenOut), 100_000e18 * (i + 1), 160_000e18 * (i + 1));
        }
        (uint256 gasUsed, uint256 delivered) = _swap(10_000e18);
        console2.log("[legs] n=%s gasUsed=%s delivered=%s", n, gasUsed, delivered);
    }

    function test_Gas_Legs_1() public { _reportLegs(1); }
    function test_Gas_Legs_2() public { _reportLegs(2); }
    function test_Gas_Legs_3() public { _reportLegs(3); }
    function test_Gas_Legs_5() public { _reportLegs(5); }

    // =========================================================================
    //  Hops scaling — direct vs via-bridge
    // =========================================================================

    function test_Gas_Hops_1_Direct() public {
        _seedPool(address(tokenIn), address(tokenOut), 1_000_000e18, 1_600_000e18);
        (uint256 gasUsed, ) = _swap(1_000e18);
        console2.log("[hops] n=1 (direct) gasUsed=%s", gasUsed);
    }

    function test_Gas_Hops_2_ViaBridge() public {
        hub.addBridge(address(bridgeToken));
        _seedPool(address(tokenIn), address(bridgeToken), 1_000_000e18, 1_000_000e18);
        _seedPool(address(bridgeToken), address(tokenOut), 1_000_000e18, 1_600_000e18);
        (uint256 gasUsed, ) = _swap(1_000e18);
        console2.log("[hops] n=2 (via bridge) gasUsed=%s", gasUsed);
    }

    // =========================================================================
    //  Hub.discoverFor gas vs factory count
    // =========================================================================

    function _reportDiscovery(uint256 nFactories) internal {
        for (uint256 i; i < nFactories; ++i) {
            MockV2Factory f = new MockV2Factory();
            hub.addFactory(address(f), BPC.KIND_V2, 0, bytes32(0), new uint24[](0), new int24[](0));
        }
        uint256 g0 = gasleft();
        hub.discoverFor(address(tokenIn), address(tokenOut));
        uint256 gasUsed = g0 - gasleft();
        console2.log("[discovery] factories=%s gasUsed=%s", nFactories, gasUsed);
    }

    function test_Gas_Discovery_1Factory() public { _reportDiscovery(1); }
    function test_Gas_Discovery_4Factories() public { _reportDiscovery(4); }
    function test_Gas_Discovery_8Factories() public { _reportDiscovery(8); }
    function test_Gas_Discovery_16Factories() public { _reportDiscovery(16); }

    // =========================================================================
    //  Exotic token overhead vs a normal ERC20
    // =========================================================================

    function test_Gas_Token_Normal() public {
        _seedPool(address(tokenIn), address(tokenOut), 1_000_000e18, 1_600_000e18);
        (uint256 gasUsed, ) = _swap(1_000e18);
        console2.log("[token] normal gasUsed=%s", gasUsed);
    }

    /// @notice FIXED (was a finding): a fee-on-transfer TOKENIN (the token
    ///         the user pulls FROM, i.e. hop 0) used to revert every time
    ///         instead of delivering a reduced-but-successful swap — hop 0
    ///         spent `leg.amountIn` exactly as the Solver planned it (the
    ///         PRE-fee amount) while hop 1+ already rescaled against the
    ///         real measured balance. `_execute`'s scaling primitive
    ///         (`_hopScaleImpactAndQuote`) now applies uniformly to every
    ///         hop, using the already-measured post-pull `amountIn` for hop
    ///         0 (no extra staticcall) — so a 1% fee-on-transfer token now
    ///         delivers ~1% less output and completes normally, matching how
    ///         mid-route bridge legs already behaved.
    function test_Gas_Token_FeeOnTransfer_TokenInSucceeds() public {
        tokenIn.setFeeOnTransferBps(100); // 1%
        _seedPool(address(tokenIn), address(tokenOut), 1_000_000e18, 1_600_000e18);
        uint256 amountIn = 1_000e18;
        RoutePlan memory plan = solver.findBestRoutePlan(address(tokenIn), address(tokenOut), amountIn);
        tokenIn.mint(user, amountIn);
        vm.prank(user);
        tokenIn.approve(address(router), amountIn);
        vm.prank(user);
        uint256 delivered = router.swapExactIn(plan.best, amountIn, 0, user, block.timestamp + 1);
        assertGt(delivered, 0, "fee-on-transfer tokenIn must now complete, not revert");
        assertEq(tokenIn.balanceOf(address(router)), 0, "Router must hold nothing afterward");
    }

    function test_Gas_Token_NoReturnData() public {
        tokenIn.setNoReturnData(true); // USDT-style
        _seedPool(address(tokenIn), address(tokenOut), 1_000_000e18, 1_600_000e18);
        (uint256 gasUsed, ) = _swap(1_000e18);
        console2.log("[token] no-return-data (USDT-style) gasUsed=%s", gasUsed);
    }

    // =========================================================================
    //  Price impact across trade sizes (single deep pool)
    // =========================================================================

    function _reportImpact(uint256 amountIn) internal {
        _seedPool(address(tokenIn), address(tokenOut), 1_000_000e18, 1_600_000e18);
        RoutePlan memory plan = solver.findBestRoutePlan(address(tokenIn), address(tokenOut), amountIn);
        console2.log(
            "[impact] amountIn=%s totalOut=%s impactBps=%s",
            amountIn, plan.best.totalOut, plan.best.expectedImpactBps
        );
    }

    function test_Impact_SmallTrade() public { _reportImpact(100e18); }         // 0.01% of pool
    function test_Impact_MediumTrade() public { _reportImpact(10_000e18); }     // 1% of pool
    function test_Impact_LargeTrade() public { _reportImpact(100_000e18); }     // 10% of pool
    function test_Impact_HugeTrade() public { _reportImpact(500_000e18); }      // 50% of pool

    // =========================================================================
    //  Slippage — quoted vs realised, with and without an intervening price move
    // =========================================================================

    function test_Slippage_NoInterveningActivity_QuoteMatchesRealised() public {
        _seedPool(address(tokenIn), address(tokenOut), 1_000_000e18, 1_600_000e18);
        uint256 amountIn = 50_000e18;
        (BlazePhoenixQuoter.Preview memory pv, , ) =
            quoter.previewPlan(address(tokenIn), address(tokenOut), amountIn);

        tokenIn.mint(user, amountIn);
        vm.prank(user);
        tokenIn.approve(address(router), amountIn);
        vm.prank(user);
        uint256 delivered = router.swapExactIn(pv.route, amountIn, 0, user, block.timestamp + 1);

        console2.log("[slippage/quiet] quotedNetOut=%s realisedDelivered=%s", pv.netOut, delivered);
    }

    function test_Slippage_PriceMovesBeforeExecution() public {
        MockV2Pair pool = _seedPool(address(tokenIn), address(tokenOut), 1_000_000e18, 1_600_000e18);
        // A trade tiny relative to pool depth (0.01%) keeps the Solver's own
        // floor loose (impact ~0, floor ~96% of its own quote) — the
        // larger 5%-of-pool trade in test_Slippage_LargerMoveTripsTheQuoteFloor
        // shows the OTHER end of this tradeoff, where even a small stale-quote
        // gap on a sizeable trade gets rejected outright.
        uint256 amountIn = 100e18;
        (BlazePhoenixQuoter.Preview memory pv, , ) =
            quoter.previewPlan(address(tokenIn), address(tokenOut), amountIn);

        // Simulate another trade landing between the user's quote and their
        // execution — a small reserve shift (~0.1%): tokenIn reserve up,
        // tokenOut reserve down (tokenOut got slightly more expensive).
        _setReservesInTokenInOutTerms(pool, 1_001_000e18, 1_598_400e18);

        tokenIn.mint(user, amountIn);
        vm.prank(user);
        tokenIn.approve(address(router), amountIn);
        vm.prank(user);
        uint256 delivered = router.swapExactIn(pv.route, amountIn, 0, user, block.timestamp + 1);

        int256 driftBps = pv.netOut == 0 ? int256(0)
            : (int256(delivered) - int256(pv.netOut)) * int256(BPC.BPS) / int256(pv.netOut);
        console2.log("[slippage/moved] quotedNetOut=%s realisedDelivered=%s", pv.netOut, delivered);
        console2.logInt(driftBps);
    }

    /// @notice A LARGER stale-quote gap (~19% adverse reserve shift) is exactly what
    ///         route.singleOutFloor (the Solver's own ~91-96%-of-its-own-quote
    ///         floor) exists to reject — this is the slippage-protection
    ///         mechanism working as intended, not a bug. Reported as its own
    ///         metric: the floor is measurably tighter than the coarser
    ///         per-leg 75% (LEG_FLOOR_BPS) / aggregate 80% hard-cap
    ///         (FLOOR_HARD_MAX_LOSS_BPS) bounds suggest in isolation.
    function test_Slippage_LargerMoveTripsTheQuoteFloor() public {
        MockV2Pair pool = _seedPool(address(tokenIn), address(tokenOut), 1_000_000e18, 1_600_000e18);
        uint256 amountIn = 50_000e18;
        (BlazePhoenixQuoter.Preview memory pv, , ) =
            quoter.previewPlan(address(tokenIn), address(tokenOut), amountIn);

        _setReservesInTokenInOutTerms(pool, 1_150_000e18, 1_400_000e18); // ~19% adverse shift

        tokenIn.mint(user, amountIn);
        vm.prank(user);
        tokenIn.approve(address(router), amountIn);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, 5));
        router.swapExactIn(pv.route, amountIn, 0, user, block.timestamp + 1);
        console2.log("[slippage/protected] a ~19%% stale-quote gap on a 5%%-of-pool trade was rejected, not silently absorbed");
    }
}
