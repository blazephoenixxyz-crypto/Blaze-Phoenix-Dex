// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  INV-20 live, end-to-end, against a REAL dynamic-fee V4 pool on Base.
//  Target (verified 2026-08-11, on-chain binding proven): aeon/WETH, Doppler
//  DecayMulticurve hook 0xbB77...1Adc0 — permission bits 0x2DC0, both
//  RETURNS_DELTA bits CLEAR (admissible by our delta-flag policy), ~$661k
//  reserve, ~$42k/day organic volume, routed by third-party aggregators.
//  The key-reconstruction test also CLOSES the research gap: fee=0x800000 and
//  tickSpacing=200 were not read from raw Initialize bytes — reproducing the
//  published poolId from those params proves them by construction.
//
//  SINCE H12 (2026-10-19) THIS POOL IS EXCLUDED FROM THE QUOTE, BY DESIGN.
//  The house rule is quote = execution. The hook carries BEFORE_SWAP_FLAG
//  (1 << 7, set in 0x2DC0) on a dynamic-fee key, so the PoolManager charges
//  the LP fee the hook RETURNS from beforeSwap (v4-core Pool.swap: the
//  override wins over slot0's lpFee). Nothing a quote can read sees that
//  figure: the price may move between the quote and the swap. `_v4Quote`
//  therefore answers such a key as a dead pool, and these tests assert the
//  exclusion on the live pool instead of the route they asserted before.
//  A caller-built leg on the explicit doors still executes, bounded by the
//  Router's floors and userMinOut (test/V4DynamicFeeBeforeSwapHookQuote.t.sol).
// =============================================================================

import {Test, console2} from "forge-std/Test.sol";
import {BlazePhoenixCore as BPC, QuoteCtx, Route} from "../../src/BlazePhoenixCore.sol";
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

    /// @notice H12 on the live pool: the pool is live (the Router's in-frame
    ///         promise, which reads slot0, prices it), yet the shared quote
    ///         producer answers 0 — a dynamic key whose hook runs beforeSwap
    ///         is unquotable, and keeps no depth vote either.
    function test_DynamicFeeBeforeSwapPool_IsExcludedFromTheQuote() public view {
        assertTrue(uint160(HOOK) & 0x80 != 0, "premise: the hook runs beforeSwap (bit 7)");
        bool zeroForOne = BASE_WETH < AEON;
        uint256 promise_ = BPC.v4LegOut(V4_MGR, POOL_ID, 0.05 ether, DYN, TS, zeroForOne);
        assertGt(promise_, 0, "premise: the pool is live and slot0 prices it");

        QuoteCtx memory c;
        c.kind        = BPC.KIND_V4;
        c.zeroForOne  = zeroForOne;
        c.fee         = DYN;
        c.tickSpacing = TS;
        c.tokenIn     = BASE_WETH;
        c.tokenOther  = AEON;
        c.hooks       = HOOK;
        c.v4Manager   = V4_MGR;
        (uint256 out, uint256 depth) = BPC.universalQuote(c, 0.05 ether);
        console2.log("aeon in-frame promise / quote out / depth:", promise_, out, depth);
        assertEq(out, 0, "a dynamic key with a beforeSwap hook must not be quoted (H12)");
        assertEq(depth, 0, "an unquotable V4 key must not keep a depth vote");
    }

    /// @notice Discovery: with the pool admitted (allowHook + addV4), no plan
    ///         the preview returns may cross it. Either no route exists
    ///         (SolverE(5): the pool was the token's home venue) or the route
    ///         found goes through another venue.
    function test_Discovery_NeverRoutesThroughTheBeforeSwapPool() public {
        try quoter.previewPlan(BASE_WETH, AEON, 0.05 ether) returns (
            BlazePhoenixQuoter.Preview memory pv, Route memory fallbackRoute, bool hasFallback
        ) {
            console2.log("preview grossOut (aeon), via another venue:", pv.grossOut);
            _assertAvoidsHook(pv.route);
            if (hasFallback) _assertAvoidsHook(fallbackRoute);
        } catch (bytes memory err) {
            assertEq(err, abi.encodeWithSelector(BlazePhoenixSolver.SolverE.selector, uint16(5)),
                "the only refusal expected is no route (SolverE(5))");
        }
    }

    /// @notice Execution: the best door never swaps through the pool. The
    ///         PoolManager's aeon balance is the witness — a swap through the
    ///         pool pays aeon out of it; no other registered venue touches it.
    function test_Execute_BestDoorNeverSwapsThroughTheBeforeSwapPool() public {
        address user = address(0xBEEF);
        uint256 amountIn = 0.05 ether;
        deal(BASE_WETH, user, amountIn);
        vm.prank(user);
        IERC20Dyn(BASE_WETH).approve(address(router), amountIn);
        uint256 mgrAeon = IERC20Dyn(AEON).balanceOf(V4_MGR);
        uint256 deadline = block.timestamp + 60;

        vm.prank(user);
        try router.swapBestExactIn(BASE_WETH, AEON, amountIn, 1, user, deadline) returns (uint256 delivered) {
            console2.log("delivered (aeon), via another venue:", delivered);
            assertGt(delivered, 0);
        } catch (bytes memory err) {
            assertEq(err, abi.encodeWithSelector(BlazePhoenixSolver.SolverE.selector, uint16(5)),
                "the only refusal expected is no route (SolverE(5))");
        }
        assertEq(IERC20Dyn(AEON).balanceOf(V4_MGR), mgrAeon, "the best door swapped through the beforeSwap pool");
        assertEq(IERC20Dyn(BASE_WETH).balanceOf(address(router)), 0);
        assertEq(IERC20Dyn(AEON).balanceOf(address(router)), 0);
    }

    function _assertAvoidsHook(Route memory r) private pure {
        for (uint256 h; h < r.hops.length; ++h) {
            for (uint256 l; l < r.hops[h].legs.length; ++l) {
                assertTrue(r.hops[h].legs[l].hooks != HOOK, "a route crossed the beforeSwap pool");
            }
        }
    }
}
