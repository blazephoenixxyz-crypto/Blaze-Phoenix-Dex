// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// O QUOTER TEM DE PREVER O QUE O ROUTER ENTREGA.
//
// PORQUE ESTE FICHEIRO EXISTE. A fee do protocolo mudou DUAS vezes em 2026-08-21 — de "uma vez
// sobre a saida cotada" para "uma vez sobre a entrada", e dai para "em cada hop, sobre a entrada
// desse hop". Nas duas vezes a suite ficou VERDE com o Quoter a prever o modelo antigo. Nao havia
// um unico teste a comparar o que o preview diz com o que a execucao faz.
//
// Um preview que mente nao perde fundos — mas e a unica coisa que o utilizador ve antes de
// assinar, e este protocolo publica a promessa de que "cotar e executar leem a mesma chain". Um
// numero errado ali e uma promessa quebrada, mesmo sem um wei se mover.
//
// A INVARIANTE: netOut previsto ~= entregue realizado, para a MESMA rota e o MESMO montante, no
// mesmo bloco. A margem e a do buffer de seguranca (que existe precisamente para cobrir deriva
// entre pernas), nunca a ordem de grandeza de uma fee esquecida.

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixQuoter} from "../src/BlazePhoenixQuoter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";

contract PreviewExecutionParityTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    BlazePhoenixQuoter quoter;
    BlazePhoenixRouter router;
    MockERC20 tA;
    MockERC20 tB;
    MockERC20 tC;
    MockV2Pair ab;
    MockV2Pair bc;

    address user = address(0x5E4);
    uint256 constant AMOUNT_IN = 1_000e18;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0xBEEF));
        solver = new BlazePhoenixSolver(address(hub));
        quoter = new BlazePhoenixQuoter(address(hub), address(solver));
        router = new BlazePhoenixRouter(
            address(hub), address(solver), address(this), address(0x7451), address(0x7452)
        );

        tA = new MockERC20("A", "A");
        tB = new MockERC20("B", "B");
        tC = new MockERC20("C", "C");
        ab = _pair(tA, tB);
        bc = _pair(tB, tC);

        hub.setRoles(address(this), address(solver), address(quoter));
        _seed(ab, tA, tB);
        _seed(bc, tB, tC);
        hub.setRoles(address(router), address(solver), address(quoter));
        hub.addBridge(address(tB));

        tA.mint(user, 10_000e18);
        vm.prank(user);
        tA.approve(address(router), type(uint256).max);
    }

    function _pair(MockERC20 x, MockERC20 y) private returns (MockV2Pair p) {
        p = new MockV2Pair(address(x), address(y));
        x.mint(address(p), 1_000_000e18);
        y.mint(address(p), 1_000_000e18);
        p.setReserves(uint112(1_000_000e18), uint112(1_000_000e18));
    }

    function _seed(MockV2Pair p, MockERC20 x, MockERC20 y) private {
        for (uint256 i; i < 5; i++) {
            hub.recordSwap(address(p), BPC.KIND_V2, 30, address(0),
                address(x), address(y), 1e18, 1e18, 1_000_000e18);
        }
    }

    /// UM HOP. O preview tem de bater com a entrega dentro do buffer de seguranca.
    function test_UmHop_PreviewBateComAEntrega() public {
        (BlazePhoenixQuoter.Preview memory pv, , ) = quoter.previewPlan(address(tA), address(tB), AMOUNT_IN);
        assertEq(pv.hops, 1, "pre-condicao: rota de um hop");
        assertGt(pv.netOut, 0, "pre-condicao: tem de cotar alguma coisa");

        vm.prank(user);
        uint256 entregue = router.swapBestExactIn(
            address(tA), address(tB), AMOUNT_IN, 1, user, block.timestamp + 1
        );

        emit log_named_decimal_uint("previsto ", pv.netOut, 18);
        emit log_named_decimal_uint("entregue ", entregue, 18);
        // 10 bps de margem, e o numero e escolhido por MEDICAO e nao por conforto: a diferenca
        // real e ~8,4e-9 relativa (arredondamento puro), e o buffer de seguranca e 0 ate 2 pernas.
        // Uma fee esquecida vale 28 bps — QUASE TRES VEZES esta margem, logo cai cá fora.
        // A primeira versao usava 0,5% e o guarda de mutacao mostrou porque estava errada: 0,5%
        // e MAIOR que os 28 bps que o mutante apagava, portanto o teste passava mutado. Uma
        // tolerancia maior que o defeito que se quer apanhar e um teste decorativo com outro nome.
        assertApproxEqRel(entregue, pv.netOut, 0.001e18, "o preview de um hop nao bate com a entrega");
    }

    /// DOIS HOPS — e e este que apanha o modelo de fee errado. Com a fee cobrada por hop, uma rota
    /// de dois paga DUAS vezes; um preview que so descontasse uma vez erraria ~28 bps, cinco vezes
    /// a margem deste teste.
    function test_DoisHops_PreviewBateComAEntrega() public {
        (BlazePhoenixQuoter.Preview memory pv, , ) = quoter.previewPlan(address(tA), address(tC), AMOUNT_IN);
        assertEq(pv.hops, 2, "pre-condicao: a rota TEM de ter dois hops, senao nao testa a composicao");
        assertGt(pv.netOut, 0, "pre-condicao: tem de cotar alguma coisa");

        vm.prank(user);
        uint256 entregue = router.swapBestExactIn(
            address(tA), address(tC), AMOUNT_IN, 1, user, block.timestamp + 1
        );

        emit log_named_decimal_uint("previsto ", pv.netOut, 18);
        emit log_named_decimal_uint("entregue ", entregue, 18);
        assertApproxEqRel(entregue, pv.netOut, 0.001e18, "o preview de dois hops nao bate com a entrega");
    }

    /// @notice A FEE DEIXOU DE COMPOR — 2026-08-22, decisao do dono.
    ///
    /// @dev Ate 21/08 o Router cobrava em CADA hop e o Quoter modelava
    ///      `(1-fee)^H`: uma rota de dois hops descontava ~56 bps quando a
    ///      constante diz 28. Com as topologias de tres hops o H so ia crescer
    ///      (~84 bps), e o numero deixava de ter relacao com o que dizia.
    ///
    ///      Agora cobra-se UMA vez, na primeira moeda de PONTE. Este teste
    ///      passou a pinar o contrario do que pinava: as duas rotas descontam
    ///      ~28 bps, e a de dois hops desconta LIGEIRAMENTE MENOS — porque a
    ///      fee incide sobre o valor na ponte, que ja sofreu o impacto de preco
    ///      do hop 0. Medido: 27 contra 28.
    ///
    ///      Esse desconto e a fuga limitada que o test/FeeEscapeViaBridgeResidual
    ///      documenta: acrescentar um hop faz a fee descer pelo impacto de UM
    ///      hop, e nao mais. Se algum dia esta fraccao descer muito abaixo de 27,
    ///      ha uma fuga NOVA e este teste apanha-a.
    function test_FeeNaoCompoeEDescontaUmaSoVez() public view {
        (BlazePhoenixQuoter.Preview memory um, , ) = quoter.previewPlan(address(tA), address(tB), AMOUNT_IN);
        (BlazePhoenixQuoter.Preview memory dois, , ) = quoter.previewPlan(address(tA), address(tC), AMOUNT_IN);
        assertEq(um.hops, 1, "pre-condicao");
        assertEq(dois.hops, 2, "pre-condicao");

        // Em fraccao da saida bruta, para comparar rotas de tamanhos diferentes.
        uint256 fracUm   = BPC.mulDiv(um.protocolFee,   10_000, um.grossOut);
        uint256 fracDois = BPC.mulDiv(dois.protocolFee, 10_000, dois.grossOut);
        assertApproxEqAbs(fracUm, 28, 1, "um hop desconta ~28 bps");
        // NAO 56: a fee e uma so. E ligeiramente ABAIXO de 28 porque incide
        // sobre o valor na ponte, ja depois do impacto do hop 0.
        assertApproxEqAbs(fracDois, 27, 1, "dois hops descontam ~28 bps, nao ~56: a fee NAO compoe");
        assertLe(fracDois, fracUm, "e nunca mais do que a rota curta");
    }
}
