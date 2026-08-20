// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test, console2} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../../src/BlazePhoenixRouter.sol";
import {BlazePhoenixQuoter} from "../../src/BlazePhoenixQuoter.sol";
import {BlazePhoenixCore as BPC, PoolInfo} from "../../src/BlazePhoenixCore.sol";

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
    // Curve main Registry (exposes find_pool_for_coins) — verified on-chain to
    // return the 3pool for the USDC/DAI pair in both token orderings. This is
    // the address a real deploy wires as a MODE_CURVE_META factory to enable
    // Curve pool discovery through Hub.discoverFor.
    address constant CURVE_REGISTRY = 0x90E00ACe148ca3b23Ac1bC8C240C2a7Dd9c2d7f5;
    uint8   constant MODE_CURVE_META = 8;

    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    BlazePhoenixRouter router;
    BlazePhoenixQuoter quoter;

    // Pinned to a recent finalized mainnet block: reproducible Curve quotes and
    // execution across runs, and hot-cached archive state (dRPC) instead of
    // flaky latest-state reads that can time out mid-fork.
    uint256 constant MAINNET_BLOCK = 25_700_000;

    function setUp() public {
        // Sem DRPC_KEY nao ha fork. SALTAR, nao falhar: um teste que rebenta por falta de uma
        // variavel de ambiente e ruido que esconde falhas reais na suite local — foram 15 destas
        // a mascarar o resultado. O job `fork-tests` do CI tem o segredo e continua a corre-los
        // a serio, portanto a cobertura nao se perde; so deixa de haver vermelho falso.
        if (bytes(vm.envOr("DRPC_KEY", string(""))).length == 0) { vm.skip(true); return; }
        vm.createSelectFork("mainnet", MAINNET_BLOCK);

        hub = new BlazePhoenixHub(address(this));
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
        uint256 delivered = router.swapExactIn(pv.route, amountIn, 1, user, block.timestamp + 60);

        console2.log("delivered (wei DAI):", delivered);
        assertGt(delivered, 0);
        assertEq(IERC20Fork(DAI).balanceOf(user), delivered);
        assertEq(IERC20Fork(USDC).balanceOf(address(router)), 0);
        assertEq(IERC20Fork(DAI).balanceOf(address(router)), 0);
    }

    /// @notice Proves the DISCOVERY path a real deploy relies on — not the
    ///         manual seedPool the other tests use. Registering the Curve
    ///         registry as a MODE_CURVE_META factory lets Hub.discoverFor find
    ///         the 3pool for a USDC/DAI pair via find_pool_for_coins, exactly as
    ///         production wiring would. The registry address was verified
    ///         on-chain to return the 3pool for this pair (both token orderings).
    function test_Discovery_FindsCurve3PoolViaRegistryScan() public {
        hub.addFactory(
            CURVE_REGISTRY, BPC.KIND_STABLE, MODE_CURVE_META, bytes32(0),
            new uint24[](0), new int24[](0)
        );
        PoolInfo[] memory hits = hub.discoverFor(USDC, DAI);
        bool found;
        for (uint256 i; i < hits.length; ++i) {
            if (hits[i].pool == CURVE_3POOL) {
                assertEq(uint256(hits[i].kind), uint256(BPC.KIND_STABLE), "3pool under KIND_STABLE");
                assertTrue(hits[i].stable, "3pool flagged stable");
                found = true;
            }
        }
        assertTrue(found, "discoverFor must find the real Curve 3pool via the registry scan");
    }
}
