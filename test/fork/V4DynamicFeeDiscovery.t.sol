// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  INV-20 live, end-to-end: a REAL dynamic-fee V4 pool on Base must be
//  admissible, quotable, routable and executable through the full stack.
//  Target (verified 2026-08-11, on-chain binding proven): aeon/WETH, Doppler
//  DecayMulticurve hook 0xbB77...1Adc0 — permission bits 0x2DC0, both
//  RETURNS_DELTA bits CLEAR (admissible by our delta-flag policy), ~$661k
//  reserve, ~$42k/day organic volume, routed by third-party aggregators.
//  The key-reconstruction test also CLOSES the research gap: fee=0x800000 and
//  tickSpacing=200 were not read from raw Initialize bytes — reproducing the
//  published poolId from those params proves them by construction.
// =============================================================================

import {Test, console2} from "forge-std/Test.sol";
import {BlazePhoenixCore as BPC, QuoteCtx} from "../../src/BlazePhoenixCore.sol";
import {BaseTestDeploy} from "./BaseTestDeploy.sol";
import {BlazePhoenixHub} from "../../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../../src/BlazePhoenixRouter.sol";
import {BlazePhoenixQuoter} from "../../src/BlazePhoenixQuoter.sol";

interface IERC20Dyn {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

contract V4DynamicDiscoveryTest is Test {
    address constant BASE_WETH = 0x4200000000000000000000000000000000000006;
    address constant AEON      = 0xBf8E8f0e8866a7052F948C16508644347c57aba3;
    address constant HOOK      = 0xbB7784A4d481184283Ed89619A3e3ed143e1Adc0;
    address constant V4_MGR    = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    bytes32 constant POOL_ID   = 0x4a9b9e13975d26f4e3e17c655593bb82145dd4452aedafb826d856b817c9cfd4;
    uint24  constant DYN       = 0x800000;
    int24   constant TS        = 200;

    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    BlazePhoenixRouter router;
    BlazePhoenixQuoter quoter;

    function setUp() public {
        // Sem DRPC_KEY nao ha fork. SALTAR, nao falhar: um teste que rebenta por falta de uma
        // variavel de ambiente e ruido que esconde falhas reais na suite local — foram 15 destas
        // a mascarar o resultado. O job `fork-tests` do CI tem o segredo e continua a corre-los
        // a serio, portanto a cobertura nao se perde; so deixa de haver vermelho falso.
        if (bytes(vm.envOr("DRPC_KEY", string(""))).length == 0) { vm.skip(true); return; }
        vm.createSelectFork("base");
        (hub, solver, router, quoter) = BaseTestDeploy.deploy(address(this));
        hub.allowHook(HOOK, true);
        hub.addV4(AEON, BASE_WETH, DYN, TS, HOOK);
    }

    /// @notice Reproducing the published poolId from (WETH, aeon, 0x800000,
    ///         200, hook) proves fee and tickSpacing by construction — the
    ///         key params the address research could not read raw.
    function test_KeyReconstruction_ClosesTheGap() public pure {
        (address s0, address s1) = BPC.sortTokens(BASE_WETH, AEON);
        assertEq(
            BPC.computeV4PoolId(s0, s1, DYN, TS, HOOK),
            POOL_ID,
            "key params do not reproduce the published poolId"
        );
    }

    /// @notice INV-20 on a LIVE dynamic-fee pool: the sentinel key must not
    ///         zero the quote — slot0's lpFee prices it.
    function test_DynamicFeePool_QuotesLive() public view {
        QuoteCtx memory c;
        c.kind        = BPC.KIND_V4;
        c.zeroForOne  = BASE_WETH < AEON;
        c.fee         = DYN;
        c.tickSpacing = TS;
        c.tokenIn     = BASE_WETH;
        c.tokenOther  = AEON;
        c.hooks       = HOOK;
        c.v4Manager   = V4_MGR;
        (uint256 out, uint256 depth) = BPC.universalQuote(c, 0.05 ether);
        console2.log("aeon dyn-fee quote out/depth:", out, depth);
        assertGt(depth, 0, "pool must be initialized");
        assertGt(out, 0, "dynamic-fee pool must quote non-zero (INV-20)");
    }

    /// @notice Discovery + routing: with the pool admitted (allowHook + addV4),
    ///         previewPlan must find a WETH->aeon route — the V4 dynamic-fee
    ///         pool is the token's home venue.
    function test_Discovery_RoutesThroughDynamicFeePool() public {
        (BlazePhoenixQuoter.Preview memory pv, , ) =
            quoter.previewPlan(BASE_WETH, AEON, 0.05 ether);
        console2.log("preview grossOut (aeon):", pv.grossOut);
        console2.log("legs/hops:", pv.legs, pv.hops);
        assertGt(pv.grossOut, 0, "must route to the dynamic-fee V4 pool");
        assertTrue(pv.canExecute);
    }

    /// @notice Full e2e: real execution WETH->aeon through the Router against
    ///         the live pool (delta-free hook passes isHookLive).
    function test_Execute_WETHtoAeon() public {
        address user = address(0xBEEF);
        uint256 amountIn = 0.05 ether;
        deal(BASE_WETH, user, amountIn);
        uint256 aeonBefore = IERC20Dyn(AEON).balanceOf(user);

        vm.prank(user);
        IERC20Dyn(BASE_WETH).approve(address(router), amountIn);

        (BlazePhoenixQuoter.Preview memory pv, , ) =
            quoter.previewPlan(BASE_WETH, AEON, amountIn);
        assertGt(pv.grossOut, 0, "precondition: route must exist");

        vm.prank(user);
        uint256 delivered = router.swapExactIn(pv.route, amountIn, 1, user, block.timestamp + 60);

        console2.log("delivered (aeon):", delivered);
        assertGt(delivered, 0);
        assertEq(IERC20Dyn(AEON).balanceOf(user) - aeonBefore, delivered);
        assertEq(IERC20Dyn(BASE_WETH).balanceOf(address(router)), 0);
        assertEq(IERC20Dyn(AEON).balanceOf(address(router)), 0);
    }
}
