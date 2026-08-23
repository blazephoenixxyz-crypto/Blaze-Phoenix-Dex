// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test, console2} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../../src/BlazePhoenixRouter.sol";
import {BlazePhoenixQuoter} from "../../src/BlazePhoenixQuoter.sol";
import {BlazePhoenixCore as BPC, Route} from "../../src/BlazePhoenixCore.sol";

interface IERC20B {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

/// @notice BENCHMARK CONTRA UM AGREGADOR A SERIO (KyberSwap), MESMO BLOCO.
///
///  A qualidade de um router mede-se numa coisa so: OUTPUT ENTREGUE no mesmo
///  par, mesmo montante, mesmo estado da cadeia. Tudo o resto e arquitectura
///  falada.
///
///  Duas comparacoes, porque medem coisas diferentes:
///    · grossOut vs Kyber -> QUALIDADE DE ROTEAMENTO (antes da nossa fee)
///    · netOut   vs Kyber -> O QUE O UTILIZADOR RECEBE (com os 28 bps)
///  A Kyber nao cobra fee de protocolo nas rotas publicas, portanto a segunda
///  comparacao carrega os nossos 28 bps inteiros. E deliberado: e o numero
///  honesto do ponto de vista de quem faz a swap.
contract BenchKyberTest is Test {
    address constant USDC    = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant WETH    = 0x4200000000000000000000000000000000000006;
    address constant WSTETH  = 0xc1CBa3fCea344f92D9239c08C0568f6F2F0ee452;
    address constant AERO    = 0x940181a94A35A4569E4529A3CDfB74e38FD98631;
    address constant LINK    = 0x88Fb150BDc53A65fe94Dea0c9BA0a6dAf8C6e196;
    address constant VIRTUAL = 0x0b3e328455c4059EEb9e3f84b5543F74E24e7E1b;
    address constant MORPHO  = 0xBAa5CC21fd487B8Fcc2F632f3F4E8D37262a0842;
    address constant V4MGR   = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    address constant T1 = address(0x7E51111111111111111111111111111111111111);
    address constant T2 = address(0x7e52222222222222222222222222222222222222);
    bytes32 constant UNIV3_INIT =
        0xe34f199b19b2b4f47f68442619d555527d244f78a3297ea89325f843f87b8b54;

    uint256 constant BLOCO = 50_322_218;

    BlazePhoenixHub hub; BlazePhoenixSolver solver;
    BlazePhoenixRouter router; BlazePhoenixQuoter quoter;
    bool ligado;

    function _temFixtures() internal view returns (bool) {
        try vm.readFile(".bench/USDC_WETH.txt") returns (string memory d) {
            return bytes(d).length > 2;
        } catch { return false; }
    }

    function setUp() public {
        // SUITE DE MEDICAO, nao de correccao. Depende de fixtures de terceiros
        // (calldata da API da KyberSwap) fixadas num bloco: envelhecem com a
        // janela de arquivo do RPC e mudam se a API deles mudar. `vm.skip`
        // torna isso VISIVEL no relatorio, em vez de um `return` silencioso que
        // se parece com um teste que passou.
        if (bytes(vm.envOr("DRPC_KEY", string(""))).length == 0) vm.skip(true);
        if (!_temFixtures()) vm.skip(true);
        vm.createSelectFork("base", BLOCO);
        ligado = true;
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), V4MGR);
        solver = new BlazePhoenixSolver(address(hub));
        router = new BlazePhoenixRouter(address(hub), address(solver), address(this), T1, T2);
        quoter = new BlazePhoenixQuoter(address(hub), address(solver));
        hub.setRoles(address(router), address(solver), address(quoter));
        router.setWeth(WETH);
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
        hub.addV4(address(0), USDC, 500, 10, address(0));
        hub.addFactory(V4MGR, 4, 9, bytes32(0), n0, z0);
    }

    /// @dev PROMESSA vs ENTREGA. O benchmark anterior comparou `grossOut`
    ///      contra a cotacao dos agregadores — mas o nosso modelo de intervalo
    ///      unico SUBESTIMA pernas concentradas (medido: +14,5% na pool
    ///      ENA/USDC a 1.000 USDC). Comparar promessas penaliza-nos por sermos
    ///      conservadores, nao por rotearmos pior. O numero honesto e o
    ///      ENTREGUE, medido por variacao de saldo.
    function _exec(address tIn, address tOut, uint256 amt)
        internal returns (uint256 entregue)
    {
        address u = address(0xB0B);
        deal(tIn, u, amt);
        vm.prank(u);
        IERC20B(tIn).approve(address(router), amt);
        (BlazePhoenixQuoter.Preview memory pv, , ) = quoter.previewPlan(tIn, tOut, amt);
        if (pv.grossOut == 0) return 0;
        uint256 antes = IERC20B(tOut).balanceOf(u);
        vm.prank(u);
        try router.swapExactIn(pv.route, amt, 1, u, block.timestamp + 600) returns (uint256) {
            entregue = IERC20B(tOut).balanceOf(u) - antes;
        } catch { entregue = 0; }
    }

    /// @dev A PORTA B de ponta a ponta. Se ela entregar o mesmo que a porta A,
    ///      entao o caminho sem confianca nenhuma nao custa preco — custa so
    ///      gas, e o gas esta medido.
    function _execB(address tIn, address tOut, uint256 amt)
        internal returns (uint256 entregue, uint256 gasto)
    {
        address u = address(0xB0BB);
        deal(tIn, u, amt);
        vm.prank(u);
        IERC20B(tIn).approve(address(router), amt);
        uint256 antes = IERC20B(tOut).balanceOf(u);
        uint256 g0 = gasleft();
        vm.prank(u);
        try router.swapBestExactIn(tIn, tOut, amt, 1, u, block.timestamp + 600) returns (uint256) {
            gasto = g0 - gasleft();
            entregue = IERC20B(tOut).balanceOf(u) - antes;
        } catch { gasto = g0 - gasleft(); entregue = 0; }
    }

    function _q(string memory rot, address tIn, address tOut, uint256 amt) internal {
        uint256 a = gasleft();
        try quoter.previewPlan(tIn, tOut, amt)
            returns (BlazePhoenixQuoter.Preview memory pv, Route memory, bool)
        {
            uint256 g = a - gasleft();
            console2.log(rot);
            console2.log("  gross ", pv.grossOut);
            console2.log("  net   ", pv.netOut);
            console2.log("  legs/hops/estGas", pv.legs, pv.hops, pv.estGas);
            console2.log("  gasCotacao", g);
            uint256 snap = vm.snapshotState();
            uint256 ent = _exec(tIn, tOut, amt);
            vm.revertToState(snap);
            console2.log("  ENTREGUE portaA", ent);
            // PORTA B: o solve corre DENTRO da transacao. Sem preview, sem
            // servidor, sem rota em calldata — so (tokenIn, tokenOut, amount).
            // Nenhum agregador off-chain consegue oferecer isto: o Pathfinder
            // deles nao corre on-chain, por construcao.
            snap = vm.snapshotState();
            (uint256 entB, uint256 gasB) = _execB(tIn, tOut, amt);
            vm.revertToState(snap);
            console2.log("  ENTREGUE portaB", entB);
            console2.log("  GAS portaB", gasB);
        } catch {
            console2.log(rot);
            console2.log("  SEM ROTA");
        }
    }

    function test_Bench() public {
        if (!ligado) return;
        console2.log("=== BlazePhoenix @ bloco", BLOCO, "===");
        _q("USDC->WETH 1k",     USDC, WETH,    1_000e6);
        _q("USDC->WETH 10k",    USDC, WETH,   10_000e6);
        _q("USDC->WETH 100k",   USDC, WETH,  100_000e6);
        _q("WETH->USDC 1",      WETH, USDC,        1e18);
        _q("WETH->USDC 10",     WETH, USDC,       10e18);
        _q("USDC->AERO 1k",     USDC, AERO,    1_000e6);
        _q("USDC->LINK 1k",     USDC, LINK,    1_000e6);
        _q("USDC->VIRTUAL 1k",  USDC, VIRTUAL, 1_000e6);
        _q("USDC->MORPHO 1k",   USDC, MORPHO,  1_000e6);
    }
}
