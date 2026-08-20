// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test, console2} from "forge-std/Test.sol";
import {BaseTestDeploy} from "./BaseTestDeploy.sol";
import {BlazePhoenixHub} from "../../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../../src/BlazePhoenixRouter.sol";
import {BlazePhoenixQuoter} from "../../src/BlazePhoenixQuoter.sol";

interface IERC20ColdWarm {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

/// @notice Same pair, three previewPlan snapshots, to show what
///         `_registryFresh` (BlazePhoenixSolver.sol) actually changes:
///         cold (registry empty, forces hub.discoverFor), warm (registry
///         has >=MIN_FRESH_VENUES fresh entries right after a real swap,
///         discoverFor skipped), and cold-again (TTL expired via vm.warp,
///         falls back to discovery). Route with -vvvv to see discoverFor's
///         factory staticcalls present in call #1 and #3, absent in #2.
contract DiscoveryColdWarmTest is Test {
    address constant BASE_WETH = 0x4200000000000000000000000000000000000006;
    address constant BASE_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

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
    }

    function _logRoute(string memory label, BlazePhoenixQuoter.Preview memory pv) internal view {
        console2.log(label);
        console2.log("  legs:", pv.legs);
        console2.log("  grossOut(wei):", pv.grossOut);
        for (uint256 h; h < pv.route.hops.length; h++) {
            for (uint256 i; i < pv.route.hops[h].legs.length; i++) {
                console2.log("  pool:", pv.route.hops[h].legs[i].pool);
            }
        }
    }

    function test_ColdVsWarmVsColdAgain() public {
        address user = address(0xBEEF);
        uint256 amountIn = 1_000e6;
        // Seed the clock ONCE. Re-reading block.timestamp at a second call site in the same
        // function returns a stale pre-warp value on this forge build (1.7.1-dev), which would
        // silently make the TTL-expiry step below a no-op and turn call #3 back into a WARM
        // lookup while still being reported as COLD-AGAIN.
        uint256 t = block.timestamp;
        deal(BASE_USDC, user, amountIn * 10);
        vm.prank(user);
        IERC20ColdWarm(BASE_USDC).approve(address(router), type(uint256).max);

        // ── Call 1: COLD. Registry for this pair is empty -> discoverFor runs. ──
        (BlazePhoenixQuoter.Preview memory pv1,,) = quoter.previewPlan(BASE_USDC, BASE_WETH, amountIn);
        assertGt(pv1.grossOut, 0, "cold: must find a route");
        _logRoute("COLD", pv1);

        // Execute it for real so Hub.recordSwap populates the registry with
        // fresh (block.timestamp) entries for every leg that was used.
        vm.prank(user);
        router.swapExactIn(pv1.route, amountIn, 1, user, t + 60);
        console2.log("registered pools after 1 execution:", hub.getActivePools(BASE_USDC, BASE_WETH).length);

        // ── Call 2: WARM. Same block, pair now has recent registry entries. ──
        // If pv1 used >= MIN_FRESH_VENUES (3) legs, _registryFresh(reg) is
        // true and discoverFor is skipped entirely for this call.
        (BlazePhoenixQuoter.Preview memory pv2,,) = quoter.previewPlan(BASE_USDC, BASE_WETH, amountIn);
        assertGt(pv2.grossOut, 0, "warm: must still find a route from the registry alone");
        _logRoute("WARM", pv2);

        // ── Call 3: COLD AGAIN. Warp past DISCOVERY_TTL_SECONDS (3600s) so ──
        // every registry entry is stale -> discoverFor runs again.
        t += 3_601;
        vm.warp(t);
        (BlazePhoenixQuoter.Preview memory pv3,,) = quoter.previewPlan(BASE_USDC, BASE_WETH, amountIn);
        assertGt(pv3.grossOut, 0, "cold-again: must still find a route via fresh discovery");
        _logRoute("COLD-AGAIN (TTL expired)", pv3);
    }
}
