// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { Script, console2 } from "forge-std/Script.sol";
import { BlazePhoenixRouter } from "@self/BlazePhoenixRouter.sol";
import { BlazePhoenixQuoter } from "@self/BlazePhoenixQuoter.sol";

interface IERC20Demo {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

/// @notice Demo script: run against a REAL standalone anvil node (already
///         forking Base and already holding a real deployed stack — Hub,
///         Solver, Router, Quoter — from a prior broadcast), not forge's
///         in-test fork cheatcodes. Deals itself
///         USDC via anvil's `anvil_setStorageAt`/impersonation isn't
///         available from a script the way `deal()` is in a test, so this
///         instead impersonates a real USDC whale via anvil_impersonateAccount
///         (called externally before running this script) — see the
///         accompanying shell commands.
///
///   forge script script/AnvilDemoSwap.s.sol:AnvilDemoSwap \
///     --rpc-url http://127.0.0.1:8545 --broadcast --unlocked --sender <whale>
contract AnvilDemoSwap is Script {
    address constant BASE_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant BASE_WETH = 0x4200000000000000000000000000000000000006;

    function run() external {
        address router = vm.envAddress("ROUTER");
        address quoter = vm.envAddress("QUOTER");
        address whale = vm.envAddress("WHALE");
        uint256 amountIn = 100e6;

        console2.log("whale USDC balance before:", IERC20Demo(BASE_USDC).balanceOf(whale));

        (BlazePhoenixQuoter.Preview memory pv, , ) =
            BlazePhoenixQuoter(quoter).previewPlan(BASE_USDC, BASE_WETH, amountIn);
        console2.log("quoted grossOut (wei WETH):", pv.grossOut);
        require(pv.grossOut > 0, "no route found");

        vm.startBroadcast(whale);
        IERC20Demo(BASE_USDC).approve(router, amountIn);
        uint256 delivered = BlazePhoenixRouter(payable(router)).swapExactIn(
            pv.route, amountIn, 0, whale, block.timestamp + 300
        );
        vm.stopBroadcast();

        console2.log("delivered (wei WETH):", delivered);
        console2.log("whale WETH balance after:", IERC20Demo(BASE_WETH).balanceOf(whale));
        console2.log("Router USDC balance after (must be 0):", IERC20Demo(BASE_USDC).balanceOf(router));
        console2.log("Router WETH balance after (must be 0):", IERC20Demo(BASE_WETH).balanceOf(router));
    }
}
