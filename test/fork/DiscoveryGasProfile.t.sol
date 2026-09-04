// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test, console2} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../../src/BlazePhoenixRouter.sol";
import {BlazePhoenixQuoter} from "../../src/BlazePhoenixQuoter.sol";
import {BlazePhoenixCore as BPC, Route, PoolInfo} from "../../src/BlazePhoenixCore.sol";

/// @notice ONDE E QUE O GAS DA PORTA B ESTA, AFINAL.
///
/// ─────────────────────────────────────────────────────────────────────────
///  A PERGUNTA
/// ─────────────────────────────────────────────────────────────────────────
///  Um `previewPlan` frio custa ~5,9M de gas. O dono pergunta se ha desperdicio
///  na contabilidade da V4 que se possa cortar. Antes de cortar seja o que for
///  e preciso saber ONDE o gas esta — e uma medicao de ontem diz que a
///  DESCOBERTA era so 3,4% do total, com o resto na COTACAO. Se isso ainda
///  valer, cortar sondas da V4 poupa quase nada e custa cobertura.
///
///  A varredura V4-derive e a passada NATIVA sao ambas novas desde essa
///  medicao, portanto a repartição pode ter mudado. E isso que se mede aqui.
///
/// ─────────────────────────────────────────────────────────────────────────
///  O METODO: TRES CONFIGURACOES, UMA VARIAVEL DE CADA VEZ
/// ─────────────────────────────────────────────────────────────────────────
///   A) so as 8 factories classicas          -> custo base de descoberta
///   B) A + linha MODE_V4_DERIVE, SEM setWeth -> custo da passada WRAPPED
///   C) B + setWeth                           -> custo da passada NATIVA
///
///  O truque de (B) nao e um hack: o `_scanV4` salta a passada nativa quando o
///  Router nao tem WETH cablado (fail-open deliberado). Isso da-nos um
///  interruptor para a passada nativa sem tocar no codigo de producao — o que
///  torna a medicao honesta, porque as tres configuracoes correm o MESMO
///  bytecode.
contract DiscoveryGasProfileTest is Test {
    address constant USDC   = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant WETH   = 0x4200000000000000000000000000000000000006;
    address constant WSTETH = 0xc1CBa3fCea344f92D9239c08C0568f6F2F0ee452;
    address constant LINK   = 0x88Fb150BDc53A65fe94Dea0c9BA0a6dAf8C6e196;
    address constant V4MGR  = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    address constant T1 = address(0x7E51111111111111111111111111111111111111);
    address constant T2 = address(0x7e52222222222222222222222222222222222222);
    bytes32 constant UNIV3_INIT =
        0xe34f199b19b2b4f47f68442619d555527d244f78a3297ea89325f843f87b8b54;

    BlazePhoenixHub hub; BlazePhoenixSolver solver;
    BlazePhoenixRouter router; BlazePhoenixQuoter quoter;
    bool ligado;

    function setUp() public {
        if (bytes(vm.envOr("DRPC_KEY", string(""))).length == 0) { vm.skip(true); return; }   // a bare return reports PASSED on a test that ran nothing
        vm.createSelectFork("base", 49_800_000);
        ligado = true;
    }

    function _base() internal {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), V4MGR);
        solver = new BlazePhoenixSolver(address(hub));
        router = new BlazePhoenixRouter(address(hub), address(solver), address(this), T1, T2);
        quoter = new BlazePhoenixQuoter(address(hub), address(solver));
        hub.setRoles(address(router), address(solver), address(quoter));
        hub.addBridge(WETH); hub.addBridge(USDC); hub.addBridge(WSTETH);
        uint24[] memory f4 = new uint24[](4);
        f4[0]=100; f4[1]=500; f4[2]=3000; f4[3]=10000;
        int24[] memory s4 = new int24[](4);
        s4[0]=1; s4[1]=10; s4[2]=60; s4[3]=200;
        uint24[] memory n0 = new uint24[](0);
        int24[]  memory z0 = new int24[](0);
        hub.addFactory(0x33128a8fC17869897dcE68Ed026d694621f6FDfD, 1, 5, UNIV3_INIT, f4, s4);
        hub.addFactory(0x420DD381b31aEf6683db6B902084cB0FFECe40Da, 5, 2, bytes32(0), n0, z0);
        hub.addFactory(0x5e7BB104d84c7CB9B682AaC2F3d509f5F406809A, 1, 3, bytes32(0), n0, z0);
        hub.addFactory(0x8909Dc15e40173Ff4699343b6eB8132c65e18eC6, 0, 0, bytes32(0), n0, z0);
        hub.addFactory(0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865, 1, 1, bytes32(0), f4, s4);
        hub.addFactory(0xc35DADB65012eC5796536bD9864eD8773aBc74C4, 1, 1, bytes32(0), f4, s4);
        hub.addFactory(0x71524B4f93c58fcbF659783284E38825f0622859, 0, 0, bytes32(0), n0, z0);
        hub.addFactory(0xFDa619b6d20975be80A10332cD39b9a4b0FAa8BB, 0, 0, bytes32(0), n0, z0);
    }

    function _v4Row() internal {
        uint24[] memory n0 = new uint24[](0);
        int24[]  memory z0 = new int24[](0);
        hub.addFactory(V4MGR, 4, 9, bytes32(0), n0, z0);
    }

    function _mede(address tok, string memory etiqueta) internal returns (uint256 g) {
        uint256 a = gasleft();
        PoolInfo[] memory ps = hub.discoverFor(USDC, tok);
        g = a - gasleft();
        console2.log(etiqueta, g, "gas | pools:", ps.length);
    }

    /// @dev DIFERENCA COM SINAL, e a razao e um Panic que este teste ja deu.
    ///      A primeira versao subtraia `gB - gA` em aritmetica CHECKED, assumindo
    ///      que acrescentar sondagens so podia AUMENTAR o gas. Nao e verdade:
    ///      registar a linha V4-derive muda o caminho percorrido e pode sair mais
    ///      barato — e ai a subtracao rebenta com Panic 0x11.
    ///
    ///      Um teste de MEDICAO que aborta ao medir nao mede nada, e o valor de
    ///      falha (revert) e indistinguivel de "a medicao correu e deu zero".
    function _delta(string memory etiqueta, uint256 antes, uint256 depois) internal pure {
        if (depois >= antes) {
            console2.log(string.concat(etiqueta, " : +"), depois - antes);
        } else {
            console2.log(string.concat(etiqueta, " : -"), antes - depois);
        }
    }

    /// @notice A DECOMPOSICAO.
    function test_PerfilDeGas_Descoberta() public {
        if (!ligado) { vm.skip(true); return; }   // skip, not pass: the key is absent, nothing was exercised

        console2.log("=== A) 8 factories classicas ===");
        _base();
        uint256 gA_link = _mede(LINK, "  USDC/LINK :");
        uint256 gA_weth = _mede(WETH, "  USDC/WETH :");

        console2.log("=== B) + V4-derive, SEM setWeth (so wrapped) ===");
        _base(); _v4Row();
        uint256 gB_link = _mede(LINK, "  USDC/LINK :");
        uint256 gB_weth = _mede(WETH, "  USDC/WETH :");

        console2.log("=== C) + setWeth (wrapped + NATIVA) ===");
        _base(); _v4Row(); router.setWeth(WETH);
        uint256 gC_link = _mede(LINK, "  USDC/LINK :");
        uint256 gC_weth = _mede(WETH, "  USDC/WETH :");

        console2.log("--- DELTAS (USDC/WETH, o par que tem V4) ---");
        console2.log("  base 8 factories      :", gA_weth);
        _delta("  + varredura V4 wrapped", gA_weth, gB_weth);
        _delta("  + passada NATIVA      ", gB_weth, gC_weth);
        console2.log("--- DELTAS (USDC/LINK) ---");
        console2.log("  base                  :", gA_link);
        _delta("  + V4 wrapped          ", gA_link, gB_link);
        _delta("  + NATIVA              ", gB_link, gC_link);

        // O NUMERO QUE DECIDE: que fatia do previewPlan e descoberta?
        uint256 a = gasleft();
        quoter.previewPlan(USDC, WETH, 1_000e6);
        uint256 gPreview = a - gasleft();
        console2.log("--- previewPlan(USDC->WETH) total:", gPreview);
        console2.log("--- descoberta (1 par) em % x100 :", (gC_weth * 10_000) / gPreview);

        assertGt(gPreview, 0, "sem preview nao ha fraccao para calcular");
    }
}
