// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test, console2} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../../src/BlazePhoenixRouter.sol";
import {BlazePhoenixQuoter} from "../../src/BlazePhoenixQuoter.sol";
import {Route} from "../../src/BlazePhoenixCore.sol";
import {BaseTestDeploy} from "./BaseTestDeploy.sol";

interface IERC20D {
    function approve(address, uint256) external returns (bool);
    function decimals() external view returns (uint8);
}

/// @notice QUANTO CUSTA O DISCOVERY 100% ON-CHAIN — e quanto custaria
///         normalizar os decimais no caminho quente.
///
/// A pergunta do dono, textual: "e gratis o gas porque o quoter passa a rota,
/// e se for 100% onchain quanto custa o discovery?"
///
/// A resposta so pode vir de uma medicao, porque as duas coisas que a decidem
/// sao contra-intuitivas:
///   1. o solve on-chain so acontece na PORTA B (`swapBestExactIn`); nas outras
///      tres portas a rota vem de calldata e o Solver nunca corre;
///   2. o custo de ler `decimals()` por candidato NAO e linear: o EIP-2929 torna
///      o primeiro acesso a cada token FRIO (2600) e todos os seguintes QUENTES
///      (100). Como todos os candidatos de um par partilham os mesmos dois
///      tokens, o custo total tende para uma constante, nao para O(n).
contract OnchainDiscoveryCostTest is Test {
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant LINK = 0x88Fb150BDc53A65fe94Dea0c9BA0a6dAf8C6e196;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    uint256 constant PINNED_BLOCK = 49_800_000;

    BlazePhoenixHub    hub;
    BlazePhoenixSolver solver;
    BlazePhoenixRouter router;
    BlazePhoenixQuoter quoter;
    address user = address(0xB1A2E);

    function setUp() public {
        if (bytes(vm.envOr("DRPC_KEY", string(""))).length == 0) { vm.skip(true); return; }   // a bare return reports PASSED on a test that ran nothing
        vm.createSelectFork("base", PINNED_BLOCK);
        (hub, solver, router, quoter) = BaseTestDeploy.deploy(address(this));
    }

    function _fund(uint256 amt) internal {
        deal(USDC, user, amt * 8);
        vm.prank(user);
        IERC20D(USDC).approve(address(router), type(uint256).max);
    }

    /// @notice PORTA B a frio e a quente — o custo real de "100% on-chain".
    function test_PortaB_FrioVsQuente() public {
        if (address(hub) == address(0)) { vm.skip(true); return; }
        uint256 amt = 1_000e6;
        uint256 t0 = block.timestamp;
        _fund(amt);

        console2.log("=========================================");
        console2.log(" DISCOVERY 100% ON-CHAIN (porta B)");
        console2.log("=========================================");

        // ── Porta B a FRIO: registo vazio, discoverFor corre DENTRO da tx ──
        vm.prank(user);
        uint256 g = gasleft();
        uint256 outFrio = router.swapBestExactIn(USDC, LINK, amt, 1, user, t0 + 600);
        uint256 gasBfrio = g - gasleft();
        console2.log("PORTA B a FRIO   gas:", gasBfrio, "out:", outFrio);

        // ── Porta B a QUENTE: o registo foi povoado pela tx acima ──
        vm.prank(user);
        g = gasleft();
        uint256 outQuente = router.swapBestExactIn(USDC, LINK, amt, 1, user, t0 + 600);
        uint256 gasBquente = g - gasleft();
        console2.log("PORTA B a QUENTE gas:", gasBquente, "out:", outQuente);
        console2.log("poupanca do registo quente:",
            gasBfrio > gasBquente ? gasBfrio - gasBquente : 0);

        // ── Porta A com a mesma rota, para isolar o custo do SOLVE ──
        (, Route memory r, ) = quoter.previewPlan(USDC, LINK, amt);
        vm.prank(user);
        g = gasleft();
        router.swapExactIn(r, amt, 1, user, t0 + 600);
        uint256 gasA = g - gasleft();
        console2.log("PORTA A (rota dada) gas:", gasA);
        console2.log("-----------------------------------------");
        console2.log("CUSTO DO DISCOVERY ON-CHAIN (B quente - A):",
            gasBquente > gasA ? gasBquente - gasA : 0);
        console2.log("CUSTO DO DISCOVERY ON-CHAIN (B frio   - A):",
            gasBfrio > gasA ? gasBfrio - gasA : 0);
    }

    /// @notice Quanto custa REALMENTE ler decimals() dos dois tokens do par.
    ///         Este numero decide se a normalizacao pode entrar no caminho
    ///         quente ou se tem de ficar so no registo.
    function test_CustoDeLerDecimals() public view {
        if (address(hub) == address(0)) return;
        console2.log("=========================================");
        console2.log(" CUSTO DE decimals() -- frio vs quente");
        console2.log("=========================================");

        uint256 g = gasleft();
        uint8 d1 = IERC20D(USDC).decimals();
        uint256 frio1 = g - gasleft();

        g = gasleft();
        uint8 d2 = IERC20D(WETH).decimals();
        uint256 frio2 = g - gasleft();

        // Segundo acesso aos MESMOS tokens: conta warm pelo EIP-2929.
        g = gasleft();
        IERC20D(USDC).decimals();
        uint256 quente1 = g - gasleft();

        g = gasleft();
        IERC20D(WETH).decimals();
        uint256 quente2 = g - gasleft();

        console2.log("USDC decimals =", d1, "| 1a leitura (fria):", frio1);
        console2.log("WETH decimals =", d2, "| 1a leitura (fria):", frio2);
        console2.log("2a leitura USDC (quente):", quente1);
        console2.log("2a leitura WETH (quente):", quente2);
        console2.log("-----------------------------------------");
        console2.log("custo UNICO por par (as duas frias):", frio1 + frio2);
        console2.log("custo por candidato adicional      :", quente1 + quente2);
        console2.log(">> se o quente for ~100x2, normalizar no caminho quente");
        console2.log(">> custa uma CONSTANTE por par, nao O(n) por candidato.");
    }
}
