// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// E1 — O RACIO DE FoT E MEDIDO, GUARDADO EM TRANSIENT, E LIDO POR UM PISO DE TRES.
//
// O DEFEITO. O `_noteFot` mede o racio LIQUIDO real (o que a pool recebeu a dividir pelo que lhe
// foi enviado) e grava-o em transient. Esse numero e consumido em EXATAMENTE UM sitio — o piso
// agregado, que re-preca o `protocolFloorOut` sobre ele. Os outros DOIS pisos nao o leem:
//
//     1. o PORTAO POR PERNA em _execScaled  — compara `got` (LIQUIDO, delta de balanceOf) com
//        `bound` (BRUTO, quote calculada sobre o que se TENCIONOU enviar);
//     2. a CAMADA 1 por hop                 — soma `hopAttested` (BRUTO) contra `hopGot` (LIQUIDO).
//
// Com um imposto de ENTRADA de t, a pool so recebe (1-t) do que lhe mandamos, logo entrega
// aproximadamente (1-t) do que a quote bruta previa. Os dois pisos leem isso como uma pool a
// entregar a menos, e revertem uma liquidacao PERFEITAMENTE CORRETA.
//
// A PROVA JA ESTAVA ESCRITA NO PROPRIO CODIGO. O comentario do piso agregado (Router:942-946)
// diz textualmente que um piso nao re-precado "would falsely reject a correct FoT fill once the
// transfer fee exceeds ~(BPS - floorBps)/BPS". E exatamente o que estes dois fazem hoje.
//
// E OS DOIS CANAIS RACIOCINAM UM SOBRE O OUTRO DE FORMA INCONSISTENTE: Router:955-957 justifica a
// permissividade do piso agregado invocando "the per-leg LEG_FLOOR_BPS guard at every pool seam"
// como uma das barreiras mais duras que o cobrem — e o portao por perna nao sabe que FoT existe.
//
// ASSINATURA DE DEFEITO DA CASA, outra vez: um fix aplicado a UM de N canais simetricos. So que
// desta vez N = 3, e o remedio ja esta escrito no canal irmao.
//
// PORQUE SAO DOIS TESTES E NAO UM. A licao do portao de cobertura: um revert com o codigo certo
// NAO prova que a verificacao certa disparou. Os dois limiares sao DIFERENTES e o segundo teste e
// o unico que apanha a Camada 1:
//
//     portao por perna : passa se  t <= 20%              (LEG_FLOOR_BPS = 8.000)
//     Camada 1         : passa se  t <= 20% / n_pernas   (a folga e a MEDIA, dividida por n)
//
// Com UMA perna a 25% so o portao dispara. Com DUAS pernas a 15% o portao PASSA (15 < 20) e so a
// Camada 1 dispara (15 > 10). Sem o segundo teste, um fix que so tratasse o portao por perna
// passaria por bom com a Camada 1 ainda cega.
//
// AMBITO HONESTO: o `_noteFot` so e chamado nos bracos V2 e SOLIDLY. Uma perna V3/V4 com token
// FoT nao regista nada, e o imposto do lado da SAIDA nunca e medido em lado nenhum. Isto fecha o
// que e mensuravel, nao o universo.

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

interface IERC20MinF {
    function transfer(address to, uint256 amt) external returns (bool);
    function balanceOf(address who) external view returns (uint256);
}

/// @notice Par V2 honesto: paga exatamente o que lhe pedem e reconcilia as reservas pelos saldos
///         medidos. Nao impoe K de proposito — o objetivo aqui e isolar o comportamento dos
///         PISOS do Router perante um input taxado, nao o comportamento da pool.
contract HonestV2Pair {
    address public token0;
    address public token1;
    uint112 public reserve0;
    uint112 public reserve1;

    /// @notice 10.000 = paga o que lhe pedem. Abaixo disso, paga a menos — e o efeito
    ///         observavel de um sandwich, sem precisar de montar um.
    uint256 public payBps = 10_000;

    constructor(address a, address b) { (token0, token1) = a < b ? (a, b) : (b, a); }

    function setReserves(uint112 r0, uint112 r1) external { reserve0 = r0; reserve1 = r1; }
    function setPayBps(uint256 b) external { payBps = b; }

    function getReserves() external view returns (uint112, uint112, uint32) {
        return (reserve0, reserve1, uint32(block.timestamp));
    }

    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata) external {
        if (amount0Out > 0) IERC20MinF(token0).transfer(to, (amount0Out * payBps) / 10_000);
        if (amount1Out > 0) IERC20MinF(token1).transfer(to, (amount1Out * payBps) / 10_000);
        reserve0 = uint112(IERC20MinF(token0).balanceOf(address(this)));
        reserve1 = uint112(IERC20MinF(token1).balanceOf(address(this)));
    }
}

contract FotFloorRepriceTest is Test {
    BlazePhoenixHub    hub;
    BlazePhoenixRouter router;
    MockERC20 tokenIn;    // o token com imposto
    MockERC20 tokenOut;
    HonestV2Pair pair;
    HonestV2Pair pairB;

    address user      = address(0x5E4);
    address treasury1 = address(0x7451);
    address treasury2 = address(0x7452);

    uint256 constant AMOUNT_IN = 1_000e18;

    function setUp() public {
        hub      = new BlazePhoenixHub(address(this));
        tokenIn  = new MockERC20("In", "IN");
        tokenOut = new MockERC20("Out", "OUT");
        pair     = new HonestV2Pair(address(tokenIn), address(tokenOut));
        pairB    = new HonestV2Pair(address(tokenIn), address(tokenOut));

        router = new BlazePhoenixRouter(
            address(hub), address(0xBEEF), address(this), treasury1, treasury2
        );

        tokenIn.mint(address(pair), 100_000e18);
        tokenOut.mint(address(pair), 100_000e18);
        pair.setReserves(100_000e18, 100_000e18);
        tokenIn.mint(address(pairB), 100_000e18);
        tokenOut.mint(address(pairB), 100_000e18);
        pairB.setReserves(100_000e18, 100_000e18);

        tokenIn.mint(user, 10_000e18);
        vm.prank(user);
        tokenIn.approve(address(router), type(uint256).max);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    //  Rotas. As atestacoes sao as quotes BRUTAS honestas — e o que um Solver produz:
    //  ele cota sobre o montante nominal, nao sobre o que sobrevive ao imposto.
    // ─────────────────────────────────────────────────────────────────────────────

    function _oneLeg() private view returns (Route memory r) {
        uint256 q = _outV2(AMOUNT_IN, 100_000e18, 100_000e18);
        Leg[] memory legs = new Leg[](1);
        legs[0] = Leg({
            pool: address(pair), hooks: address(0), kind: BPC.KIND_V2, fee: 30,
            tickSpacing: 0, zeroForOne: address(tokenIn) < address(tokenOut),
            stable: false, amountIn: AMOUNT_IN, expectedOut: q, auxId: bytes32(0)
        });
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({
            tokenIn: address(tokenIn), tokenOut: address(tokenOut),
            amountIn: AMOUNT_IN, expectedOut: q, legs: legs
        });
        r = Route({
            hops: hops, totalOut: q, singleOut: q, singleOutFloor: 0,
            expectedImpactBps: 0, confidenceWad: 0, estGas: 0,
            hasSurplus: false, isV4Bundle: false
        });
    }

    function _twoLegs() private view returns (Route memory r) {
        uint256 aIn = 980e18;
        uint256 bIn =  20e18;
        uint256 qA = _outV2(aIn, 100_000e18, 100_000e18);
        uint256 qB = _outV2(bIn, 100_000e18, 100_000e18);

        Leg[] memory legs = new Leg[](2);
        legs[0] = Leg({
            pool: address(pair), hooks: address(0), kind: BPC.KIND_V2, fee: 30,
            tickSpacing: 0, zeroForOne: address(tokenIn) < address(tokenOut),
            stable: false, amountIn: aIn, expectedOut: qA, auxId: bytes32(0)
        });
        legs[1] = Leg({
            pool: address(pairB), hooks: address(0), kind: BPC.KIND_V2, fee: 30,
            tickSpacing: 0, zeroForOne: address(tokenIn) < address(tokenOut),
            stable: false, amountIn: bIn, expectedOut: qB, auxId: bytes32(0)
        });
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({
            tokenIn: address(tokenIn), tokenOut: address(tokenOut),
            amountIn: AMOUNT_IN, expectedOut: qA + qB, legs: legs
        });
        r = Route({
            hops: hops, totalOut: qA + qB, singleOut: qA + qB, singleOutFloor: 0,
            expectedImpactBps: 0, confidenceWad: 0, estGas: 0,
            hasSurplus: false, isV4Bundle: false
        });
    }

    /// A curva do V2 com 30 bps, escrita por extenso de proposito: a assercao tem de ser contra
    /// o predicado literal, nao contra um helper que possa ser reescrito ao mesmo tempo.
    function _outV2(uint256 amtIn, uint256 rIn, uint256 rOut) private pure returns (uint256) {
        uint256 inAfterFee = amtIn * 9970;
        return (inAfterFee * rOut) / (rIn * 10_000 + inAfterFee);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    //  ANTI-REGRESSAO — tem de passar ANTES e DEPOIS do fix.
    // ─────────────────────────────────────────────────────────────────────────────

    /// Sem imposto, tudo liquida. Se este ficar vermelho, o fix partiu o caminho comum.
    function test_NoTax_OneLeg_Settles() public {
        vm.prank(user);
        uint256 out = router.swapExactIn(_oneLeg(), AMOUNT_IN, 1, user, block.timestamp + 1);
        assertGt(out, 900e18, "sem imposto uma perna tem de liquidar");
    }

    function test_NoTax_TwoLegs_Settle() public {
        vm.prank(user);
        uint256 out = router.swapExactIn(_twoLegs(), AMOUNT_IN, 1, user, block.timestamp + 1);
        assertGt(out, 900e18, "sem imposto duas pernas tem de liquidar");
    }

    /// Imposto PEQUENO (5%): passa nos dois pisos mesmo hoje. Fixa o limite inferior do defeito —
    /// prova que o problema e o LIMIAR, nao a presenca de FoT.
    function test_SmallTax_StillSettlesToday() public {
        tokenIn.setFeeOnTransferBps(500);
        vm.prank(user);
        uint256 out = router.swapExactIn(_oneLeg(), AMOUNT_IN, 1, user, block.timestamp + 1);
        assertGt(out, 1, "5% tem de liquidar mesmo antes do fix");
    }

    // ─────────────────────────────────────────────────────────────────────────────
    //  OS DOIS QUE ESTAO VERMELHOS HOJE.
    // ─────────────────────────────────────────────────────────────────────────────

    /// (a) ISOLA O PORTAO POR PERNA. 25% de imposto de entrada, UMA perna.
    ///     A pool recebe 75% e entrega ~75% da quote bruta. 75% < LEG_FLOOR_BPS (80%) => reverte.
    ///     Com UMA perna a folga da Camada 1 e 20% (nao dividida), logo ela NAO dispara aqui:
    ///     0,75 + 0,20 = 0,95 < 1 ... dispara tambem. Ver o teste (b) para a separacao limpa.
    ///     Este continua a isolar o portao porque e o PRIMEIRO a correr — o revert vem de la.
    function test_EntryTax25_OneLeg_MustSettle() public {
        tokenIn.setFeeOnTransferBps(2_500);
        vm.prank(user);
        uint256 out = router.swapExactIn(_oneLeg(), AMOUNT_IN, 1, user, block.timestamp + 1);
        assertGt(out, 1, "uma liquidacao FoT CORRETA nao pode ser rejeitada pelo piso por perna");
    }

    /// (c) O QUE FECHA O FIX-BURACO, e o mais dificil de escrever dos tres.
    ///
    ///     Existe um "fix" que passa em (a) e (b) e deixa os 7 testes do CoverageGate verdes:
    ///     ANULAR o piso por perna sempre que houver FoT (`bound = 0`). O CoverageGate nao o
    ///     apanha porque nenhum dos seus casos usa um token taxado — o portao la corre na mesma.
    ///
    ///     A PRIMEIRA VERSAO DESTE TESTE ERA DECORATIVA, e a mutacao provou-o. Era de UMA perna
    ///     com a pool a pagar metade: passava, mas o `RouterE(5)` vinha do piso da ROTA (a
    ///     entrega ficava 37,5% do bruto, muito abaixo do piso agregado), nao do portao por
    ///     perna. Com o fix-buraco aplicado, continuava verde. E a mesma armadilha que apanhou
    ///     a primeira versao do CoverageGate: um revert com o codigo certo NAO prova que a
    ///     verificacao certa disparou.
    ///
    ///     A versao que discrimina e a de DUAS pernas — o cenario para o qual o piso por perna
    ///     existe. 98% do input numa pool honesta que segura o agregado acima do seu piso, 2%
    ///     numa que nao entrega NADA. Com imposto de 25% nas duas. O piso agregado sobrevive
    ///     (e ate e MAIS permissivo aqui, porque o racio composto das duas pernas sobre-desconta
    ///     — o proprio codigo o documenta). So o portao por perna pode apanhar a perna pequena.
    ///
    ///     A regra que isto encarna: re-precar um piso pela medicao NAO e o mesmo que desligar o
    ///     piso. O imposto explica parte do defice — nunca todo.
    function test_FotIsNotAnExcuseToBleed() public {
        tokenIn.setFeeOnTransferBps(2_500);
        pairB.setPayBps(0);              // a perna de 2% nao entrega nada
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, uint16(5)));
        vm.prank(user);
        router.swapExactIn(_twoLegs(), AMOUNT_IN, 1, user, block.timestamp + 1);
    }

    /// (b) O QUE DISCRIMINA. 15% de imposto, DUAS pernas honestas.
    ///     Portao por perna: 85% > 80% => PASSA.
    ///     Camada 1: folga = MEDIA/n * 20% = 10%; 0,85 + 0,10 = 0,95 < 1 => REVERTE.
    ///     Sem este teste, um fix que so re-precasse o portao por perna passava por bom.
    function test_EntryTax15_TwoLegs_Layer1MustNotReject() public {
        tokenIn.setFeeOnTransferBps(1_500);
        vm.prank(user);
        uint256 out = router.swapExactIn(_twoLegs(), AMOUNT_IN, 1, user, block.timestamp + 1);
        assertGt(out, 1, "a Camada 1 nao pode rejeitar duas pernas FoT corretas");
    }
}
