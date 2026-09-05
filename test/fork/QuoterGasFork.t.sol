// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;
// What a live quote costs through the ABI on Base: cold (registry empty, discovery sweeps the
// admitted factories), warm (registry fresh after one real execution), cold again (TTL expired).
// previewPlan and previewAndEncode, five sizes each, mean gas printed per mode. Needs DRPC_KEY.
//
// forge test --match-path test/fork/QuoterGasFork.t.sol -vv
import {Test, console2} from "forge-std/Test.sol";
import {BaseTestDeploy} from "./BaseTestDeploy.sol";
import {BlazePhoenixHub} from "../../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../../src/BlazePhoenixRouter.sol";
import {BlazePhoenixQuoter} from "../../src/BlazePhoenixQuoter.sol";

interface IERC20QG { function approve(address, uint256) external returns (bool); }

contract QuoterGasForkTest is Test {
    address constant BASE_WETH = 0x4200000000000000000000000000000000000006;
    address constant BASE_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    BlazePhoenixHub hub; BlazePhoenixSolver solver; BlazePhoenixRouter router; BlazePhoenixQuoter quoter;
    address user = address(0xBEEF);

    function setUp() public {
        if (bytes(vm.envOr("DRPC_KEY", string(""))).length == 0) { vm.skip(true); return; }
        vm.createSelectFork("base");
        (hub, solver, router, quoter) = BaseTestDeploy.deploy(address(this));
        deal(BASE_USDC, user, 100_000e6);
        vm.prank(user); IERC20QG(BASE_USDC).approve(address(router), type(uint256).max);
    }

    function _measure(string memory tag) private returns (uint256 planMean, uint256 encMean) {
        uint256 ps; uint256 es;
        for (uint256 i; i < 5; ++i) {
            uint256 amt = 200e6 * (i + 1);
            uint256 g0 = gasleft();
            (BlazePhoenixQuoter.Preview memory pv, , ) = quoter.previewPlan(BASE_USDC, BASE_WETH, amt);
            ps += g0 - gasleft();
            assertTrue(pv.canExecute, "the live quote exists");
            g0 = gasleft();
            quoter.previewAndEncode(BASE_USDC, BASE_WETH, amt, user, block.timestamp + 30);
            es += g0 - gasleft();
        }
        planMean = ps / 5; encMean = es / 5;
        console2.log(tag, "previewPlan mean gas", planMean);
        console2.log(tag, "previewAndEncode mean gas", encMean);
    }

    function test_LiveBase_ColdWarmColdAgain_GasThroughTheAbi() public {
        (uint256 cold, ) = _measure("COLD      ");
        (BlazePhoenixQuoter.Preview memory pv, , ) = quoter.previewPlan(BASE_USDC, BASE_WETH, 1_000e6);
        vm.prank(user);
        router.swapExactIn(pv.route, 1_000e6, 1, user, block.timestamp + 60);
        console2.log("registered pools after one execution", hub.getActivePools(BASE_USDC, BASE_WETH).length);
        (uint256 warm, ) = _measure("WARM      ");
        vm.warp(block.timestamp + 3_601);
        (uint256 coldAgain, ) = _measure("COLD AGAIN");
        console2.log("cold / warm x100", cold * 100 / warm);
        assertGt(cold, 0); assertGt(warm, 0); assertGt(coldAgain, 0);
    }
}
