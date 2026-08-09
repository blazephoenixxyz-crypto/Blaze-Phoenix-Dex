// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test, console2} from "forge-std/Test.sol";
import {BaseTestDeploy} from "./BaseTestDeploy.sol";
import {BlazePhoenixHub} from "../../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../../src/BlazePhoenixRouter.sol";
import {BlazePhoenixQuoter} from "../../src/BlazePhoenixQuoter.sol";
import {Top100BaseTokens} from "./Top100BaseTokens.sol";
import {Route} from "../../src/BlazePhoenixCore.sol";

/// @notice Extrapolation of BaseFork.t.sol across 100 REAL Base mainnet
///         tokens (top-100 by global CoinGecko market-cap rank among tokens
///         with a verified Base deployment — addresses fetched via curl from
///         CoinGecko's public API, not hand-typed, to avoid the checksum
///         mistakes that come from typing 40-hex-digit addresses by hand;
///         see Top100BaseTokens.sol). For each token, previews a
///         USDC -> token quote against LIVE Base liquidity via the fully
///         wired (real factories, real bridges, real V4 key) stack. This is
///         a discovery/coverage sweep, not a per-token correctness
///         assertion — most long-tail tokens legitimately have no route
///         through the wired venues (thin/no Uniswap V3 or Aerodrome pool),
///         and that must NOT be treated as a failure.
contract BaseTop100Test is Test {
    address constant BASE_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    BlazePhoenixRouter router;
    BlazePhoenixQuoter quoter;

    function setUp() public {
        vm.createSelectFork("base");
        (hub, solver, router, quoter) = BaseTestDeploy.deploy(address(this));
    }

    function test_Sweep_USDCtoTop100BaseTokens() public {
        Top100BaseTokens.Entry[100] memory tokens = Top100BaseTokens.all();
        uint256 amountIn = 1_000e6; // 1,000 USDC

        uint256 routeFound;
        uint256 noRoute;
        uint256 selfPair; // token IS USDC itself (rank-1 stablecoin), skip
        uint256 totalGas;

        for (uint256 i; i < tokens.length; ++i) {
            address token = tokens[i].token;
            if (token == BASE_USDC) { selfPair++; continue; }

            uint256 g0 = gasleft();
            try quoter.previewPlan(BASE_USDC, token, amountIn)
                returns (BlazePhoenixQuoter.Preview memory pv, Route memory, bool)
            {
                uint256 gasUsed = g0 - gasleft();
                totalGas += gasUsed;
                if (pv.grossOut > 0) {
                    routeFound++;
                    console2.log("[FOUND]", tokens[i].symbol, pv.grossOut, gasUsed);
                } else {
                    noRoute++;
                    console2.log("[ZERO ] ", tokens[i].symbol);
                }
            } catch {
                noRoute++;
                console2.log("[REVERT]", tokens[i].symbol);
            }
        }

        console2.log("================ SUMMARY ================");
        console2.log("routeFound:", routeFound);
        console2.log("noRoute   :", noRoute);
        console2.log("selfPair  :", selfPair);
        if (routeFound > 0) console2.log("avgGasPerFoundQuote:", totalGas / routeFound);

        // Discovery-coverage floor, not a strict correctness bound: at least
        // a meaningful fraction of top-100-by-market-cap tokens must be
        // reachable through the wired venues, or the deployment itself is
        // broken (wrong factories, wrong bridges, etc.) rather than this
        // just being long-tail illiquidity.
        assertGt(routeFound, 10, "too few real top-100 tokens found a route - check venue wiring");
    }
}
