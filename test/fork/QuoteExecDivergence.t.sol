// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test, console2} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../../src/BlazePhoenixRouter.sol";
import {BlazePhoenixQuoter} from "../../src/BlazePhoenixQuoter.sol";
import {BlazePhoenixCore as BPC, Route, Leg} from "../../src/BlazePhoenixCore.sol";
import {BaseTestDeploy} from "./BaseTestDeploy.sol";

interface IERC20Q {
    function approve(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
    function decimals() external view returns (uint8);
    function symbol() external view returns (string memory);
}

/// @notice DIAGNOSTICO — uma cotacao que se declara EXECUTAVEL e reverte.
///
/// Encontrado a 2026-08-21 no varrimento de metricas: USDC -> USDS na Base,
/// bloco 49.800.000, 1.000 USDC. O `previewPlan` devolve `grossOut > 0` E
/// `canExecute == true`, e o `swapExactIn` reverte com `RouterE(5)`.
///
/// `RouterE(5)` tem QUATRO sitios no Router, e sao perguntas diferentes:
///   Router:1007  hopGot + slack < hopAttested   (Camada 1, por hop)
///   Router:1122  amountOut < effMin             (piso agregado da rota)
///   Router:1140  delivered < userMinOut         (piso do utilizador)
///   Router:1320  got < bound * LEG_FLOOR_BPS    (piso POR PERNA)
///
/// Este ficheiro nao adivinha qual deles e: imprime o que a cotacao prometeu,
/// o que a execucao entregou, e deixa o trace dizer a linha. `userMinOut` e 1,
/// por isso o 1140 esta excluido por construcao — sobram tres.
contract QuoteExecDivergenceTest is Test {
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant USDS = 0x820C137fa70C8691f0e44Dc420a5e53c168921Dc;
    uint256 constant BLK  = 49_800_000;

    BlazePhoenixHub    hub;
    BlazePhoenixSolver solver;
    BlazePhoenixRouter router;
    BlazePhoenixQuoter quoter;
    address user = address(0xB1A2E);

    function setUp() public {
        if (bytes(vm.envOr("DRPC_KEY", string(""))).length == 0) return;
        vm.createSelectFork("base", BLK);
        (hub, solver, router, quoter) = BaseTestDeploy.deploy(address(this));
    }

    function test_USDS_QuoteDizExecutavelMasReverte() public {
        if (address(hub) == address(0)) { vm.skip(true); return; }
        uint256 amt = 1_000e6;
        uint256 t0 = block.timestamp;

        console2.log("=========================================");
        console2.log(" USDC -> USDS  |  1.000 USDC  |  Base @", BLK);
        console2.log("=========================================");
        console2.log("USDS decimals:", IERC20Q(USDS).decimals());

        (BlazePhoenixQuoter.Preview memory pv, Route memory r, bool ok) =
            quoter.previewPlan(USDC, USDS, amt);

        console2.log("--- O QUE A COTACAO PROMETEU ---");
        console2.log("  ok flag        :", ok);
        console2.log("  canExecute     :", pv.canExecute);
        console2.log("  grossOut       :", pv.grossOut);
        console2.log("  netOut         :", pv.netOut);
        console2.log("  ironFloor      :", pv.ironFloor);
        console2.log("  effectiveMinOut:", pv.effectiveMinOut);
        console2.log("  protocolFee    :", pv.protocolFee);
        console2.log("  safetyBuffer   :", pv.safetyBuffer);
        console2.log("  hops / legs    :", pv.hops, pv.legs);
        console2.log("  topology       :", pv.topology);

        for (uint256 h; h < r.hops.length; ++h) {
            console2.log("  hop", h);
            console2.log("     tokenIn/Out:", r.hops[h].tokenIn, r.hops[h].tokenOut);
            console2.log("     amountIn   :", r.hops[h].amountIn);
            console2.log("     expectedOut:", r.hops[h].expectedOut);
            for (uint256 l; l < r.hops[h].legs.length; ++l) {
                Leg memory lg = r.hops[h].legs[l];
                console2.log("     leg pool:", lg.pool);
                console2.log("        kind/fee   :", lg.kind, lg.fee);
                console2.log("        amountIn   :", lg.amountIn);
                console2.log("        expectedOut:", lg.expectedOut);
            }
        }

        // A `Preview` tem um campo `route` PROPRIO, e o previewPlan devolve
        // AINDA outra `Route` em separado. Se as duas divergirem, quem usar os
        // numeros de uma com a rota da outra recebe uma mentira coerente.
        console2.log("--- pv.route CONTRA a Route devolvida ---");
        console2.log("  pv.hops (campo)     :", pv.hops);
        console2.log("  pv.route.hops.length:", pv.route.hops.length);
        console2.log("  route.hops.length   :", r.hops.length);
        for (uint256 h; h < pv.route.hops.length; ++h) {
            console2.log("  pv.route hop", h);
            console2.log("     tokenIn/Out:", pv.route.hops[h].tokenIn, pv.route.hops[h].tokenOut);
            console2.log("     expectedOut:", pv.route.hops[h].expectedOut);
        }

        // O piso por perna e 80% do bound. Se a entrega real ficar abaixo,
        // e o Router:1320 que dispara — e a divergencia e POR PERNA, nao da rota.
        console2.log("--- LIMIAR DO PISO POR PERNA (80%) ---");
        for (uint256 h; h < r.hops.length; ++h) {
            for (uint256 l; l < r.hops[h].legs.length; ++l) {
                uint256 bound = r.hops[h].legs[l].expectedOut;
                console2.log("     leg", l, "piso 80% =", (bound * 8_000) / 10_000);
            }
        }

        deal(USDC, user, amt * 4);
        vm.prank(user);
        IERC20Q(USDC).approve(address(router), type(uint256).max);

        console2.log("--- O QUE A EXECUCAO FEZ ---");
        uint256 antes = IERC20Q(USDS).balanceOf(user);
        vm.prank(user);
        try router.swapExactIn(r, amt, 1, user, t0 + 600) returns (uint256 got) {
            console2.log("  NAO reverteu. entregue:", got);
            console2.log("  delta saldo           :", IERC20Q(USDS).balanceOf(user) - antes);
            console2.log("  entregue / prometido (x100):",
                pv.grossOut == 0 ? 0 : (got * 100) / pv.grossOut);
        } catch (bytes memory err) {
            console2.log("  REVERTEU. selector+dados:");
            console2.logBytes(err);
            console2.log("  >> correr com -vvvv para ver a linha exacta do Router");
        }
    }
}
