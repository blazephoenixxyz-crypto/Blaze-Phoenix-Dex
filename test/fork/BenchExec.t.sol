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

/// @notice AS DUAS ROTAS EXECUTADAS NO MESMO FORK. Gas REAL, nao estimado.
///
///  Todas as comparacoes anteriores usaram o campo `gas` da API deles, que e
///  uma ESTIMATIVA e pode trazer margem. Aqui o calldata deles e executado
///  contra o router deles no nosso fork, no mesmo bloco em que foi construido.
///  O que sai e gas medido e output medido, dos dois lados.
///
///  A PERGUNTA QUE ISTO RESPONDE: um solver off-chain tem computacao ilimitada
///  para escolher a rota. Se a arquitectura de execucao deles fosse igual ou
///  melhor, uma rota limpa deles custaria <= a nossa. Se custar mais, a
///  diferenca esta no EXECUTOR e nenhuma optimizacao off-chain a corrige.
contract BenchExecTest is Test {
    address constant USDC   = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant WETH   = 0x4200000000000000000000000000000000000006;
    address constant WSTETH = 0xc1CBa3fCea344f92D9239c08C0568f6F2F0ee452;
    address constant LINK   = 0x88Fb150BDc53A65fe94Dea0c9BA0a6dAf8C6e196;
    address constant MORPHO = 0xBAa5CC21fd487B8Fcc2F632f3F4E8D37262a0842;
    address constant V4MGR  = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    address constant KYBER  = 0x6131B5fae19EA4f9D964eAc0408E4408b66337b5;
    address constant BOB    = 0x000000000000000000000000000000000000b0b0;
    address constant T1 = address(0x7E51111111111111111111111111111111111111);
    address constant T2 = address(0x7e52222222222222222222222222222222222222);
    bytes32 constant UNIV3_INIT =
        0xe34f199b19b2b4f47f68442619d555527d244f78a3297ea89325f843f87b8b54;
    uint256 constant BLOCO = 50_323_367;

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

    function _kyber(string memory f, address tOut, uint256 amt)
        internal returns (uint256 got, uint256 gasto)
    {
        bytes memory cd = vm.parseBytes(vm.readFile(string.concat(".bench/", f, ".txt")));
        deal(USDC, BOB, amt);
        vm.prank(BOB); IERC20B(USDC).approve(KYBER, amt);
        uint256 antes = IERC20B(tOut).balanceOf(BOB);
        uint256 g0 = gasleft();
        vm.prank(BOB);
        (bool ok, ) = KYBER.call(cd);
        gasto = g0 - gasleft();
        got = ok ? IERC20B(tOut).balanceOf(BOB) - antes : 0;
    }

    function _nosso(address tOut, uint256 amt) internal returns (uint256 got, uint256 gasto) {
        (BlazePhoenixQuoter.Preview memory pv, , ) = quoter.previewPlan(USDC, tOut, amt);
        if (pv.grossOut == 0) return (0, 0);
        deal(USDC, BOB, amt);
        vm.prank(BOB); IERC20B(USDC).approve(address(router), amt);
        uint256 antes = IERC20B(tOut).balanceOf(BOB);
        uint256 g0 = gasleft();
        vm.prank(BOB);
        try router.swapExactIn(pv.route, amt, 1, BOB, block.timestamp + 600) returns (uint256) {
            gasto = g0 - gasleft();
            got = IERC20B(tOut).balanceOf(BOB) - antes;
        } catch { gasto = g0 - gasleft(); }
    }

    function _par(string memory nome, string memory f, address tOut, uint256 amt) internal {
        uint256 s1 = vm.snapshotState();
        (uint256 gK, uint256 ggK) = _kyber(f, tOut, amt);
        vm.revertToState(s1);
        uint256 s2 = vm.snapshotState();
        (uint256 gN, uint256 ggN) = _nosso(tOut, amt);
        vm.revertToState(s2);
        console2.log(nome);
        console2.log("  KYBER  out/gas", gK, ggK);
        console2.log("  NOSSO  out/gas", gN, ggN);
    }

    function test_ExecReal() public {
        if (!ligado) return;
        _par("USDC->WETH 1k",   "USDC_WETH",   WETH,   1_000e6);
        _par("USDC->LINK 1k",   "USDC_LINK",   LINK,   1_000e6);
        _par("USDC->MORPHO 1k", "USDC_MORPHO", MORPHO, 1_000e6);
    }
}
