// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// F1 — O VALOR SAI COMO RESIDUAL DE PONTE, E O RESIDUAL NAO PAGA FEE.
//
// A PERGUNTA DO DONO: "garante que ninguem pode escapar ao fee que pusemos."
//
// A fee de 28 bps e cobrada sobre `totalReceived`, e o `totalReceived` e SO o delta de saldo do
// `tokenOut`. Mas uma rota multi-hop tambem devolve ao chamador os RESIDUAIS das pontes — e essa
// devolucao nao tem limite nenhum e nao paga fee:
//
//     if (rb > bb) BPC.safeTransfer(bridge, payer, rb - bb);     // sem cap, sem fee
//     ...
//     uint256 totalReceived = BPC.balanceOf(tokenOut, address(this)) - toutStart;
//
// O comentario do proprio sweep ASSUME que os residuais sao po — "mulDiv rounding, partial-fill,
// ou uma pool nao-conforme que recusou o que lhe foi entregue". Nada o impoe.
//
// O MECANISMO QUE O TORNA EXPLORAVEL esta no callback do V3, e esta escrito por extenso:
// "Pay exactly what the pool demands" — o `owed` vem da POOL, limitado apenas por `maxAmt`. Uma
// pool que peca 1 wei recebe 1 wei. O resto da ponte fica no Router e e varrido para o pagador.
//
// A ROTA DO ATAQUE: A -> B (real, funda) -> C (po, pool do atacante).
//   1. O hop 0 executa a serio: o Router fica com quase todo o B.
//   2. O hop 1 aponta a uma pool que reporta estado ZERO (logo legQuote = 0) e a perna traz
//      expectedOut = 0. Isso desliga TODOS os pisos de uma vez, e cada um por uma razao propria:
//        · o portao por perna nao corre (guard exige uma das duas atestacoes);
//        · a Camada 1 nao corre (hopAttested == 0);
//        · o piso da rota e mulDiv(finalHopQuote=0, ...) = 0.
//      Nenhum deles esta partido. Todos sao RELATIVOS A QUOTE, e uma quote zero torna-os inertes.
//   3. A pool pede 1 wei de B e entrega po de C.
//   4. O sweep devolve B - 1wei ao pagador. SEM FEE.
//   5. `totalReceived` = po de C. A fee e 28 bps de po.
//
// PORQUE E QUE NENHUMA DAS DEFESAS DESTA SESSAO APANHA ISTO: o portao de cobertura e o A1 fecharam
// o canal "valor disfarcado de EXCEDENTE do tokenOut". Este e o canal SIMETRICO — "valor disfarcado
// de RESIDUAL de ponte" — e nunca foi tocado. E a assinatura de defeito da casa: um fix aplicado a
// UM de dois canais simetricos, pela decima-terceira vez.
//
// E o invariante que faltava e nomeavel: NENHUM teste ata a fee ao VALOR MOVIDO. O
// `invariant_FeeNeverExceedsProtocolMax` limita a fee POR CIMA. Ninguem a limita por BAIXO.

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";

interface IERC20MinR {
    function transfer(address to, uint256 amt) external returns (bool);
    function balanceOf(address who) external view returns (uint256);
}

/// @notice Pool com forma de V3 que SUB-CONSOME: pede 1 wei do input e entrega po do output.
///         Reporta estado zero para que a quote in-frame do Router seja 0 e os pisos fiquem inertes.
contract UnderConsumingV3Pool {
    address public token0;
    address public token1;
    address public dustToken;
    uint256 public dust = 1;
    uint256 public demand = 1;

    constructor(address a, address b, address _dust) {
        (token0, token1) = a < b ? (a, b) : (b, a);
        dustToken = _dust;
    }

    // Estado ZERO: e isto que torna todos os pisos inertes de uma so vez.
    function slot0() external pure returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (0, 0, 0, 0, 0, 0, false);
    }
    function liquidity() external pure returns (uint128) { return 0; }
    function fee() external pure returns (uint24) { return 3000; }

    function swap(address recipient, bool zeroForOne, int256, uint160, bytes calldata data)
        external returns (int256 a0, int256 a1)
    {
        IERC20MinR(dustToken).transfer(recipient, dust);
        (a0, a1) = zeroForOne
            ? (int256(demand), -int256(dust))
            : (-int256(dust), int256(demand));
        (bool ok, ) = recipient.call(
            abi.encodeWithSignature("uniswapV3SwapCallback(int256,int256,bytes)", a0, a1, data)
        );
        require(ok, "callback falhou");
    }
}

contract FeeEscapeViaBridgeResidualTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixRouter router;
    MockERC20 tA;   // input
    MockERC20 tB;   // a PONTE — e o token que realmente se move
    MockERC20 tC;   // o tokenOut de fachada
    MockV2Pair pairAB;
    UnderConsumingV3Pool poolBC;

    address user      = address(0x5E4);
    address treasury1 = address(0x7451);
    address treasury2 = address(0x7452);

    uint256 constant AMOUNT_IN = 1_000e18;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        tA = new MockERC20("A", "A");
        tB = new MockERC20("B", "B");
        tC = new MockERC20("C", "C");

        pairAB = new MockV2Pair(address(tA), address(tB));
        tA.mint(address(pairAB), 1_000_000e18);
        tB.mint(address(pairAB), 1_000_000e18);
        pairAB.setReserves(1_000_000e18, 1_000_000e18);

        poolBC = new UnderConsumingV3Pool(address(tB), address(tC), address(tC));
        tC.mint(address(poolBC), 1_000e18);

        router = new BlazePhoenixRouter(
            address(hub), address(0xBEEF), address(this), treasury1, treasury2
        );

        // A PONTE TEM DE SER PONTE PARA O HUB, nao so na prosa deste ficheiro.
        // Ate 2026-08-23 este teste chamava `tB` "a PONTE" nos comentarios e nos
        // asserts e NUNCA registava a bridge — `hub.isBridgeToken(tB)` devolvia
        // false. Nenhum teste de fee do repo exercitava esse predicado, portanto
        // o detector estava CEGO por construcao a qualquer regra baseada em
        // pontes reais: passava so porque a ancora da fee era POSICIONAL.
        // Quando a ancora passou a ser por VALOR (a cura da fuga do po no meio
        // da rota), este teste teria ficado vermelho por artefacto do proprio
        // teste — nao por defeito do produto.
        hub.addBridge(address(tB));

        tA.mint(user, 10_000e18);
        vm.prank(user);
        tA.approve(address(router), type(uint256).max);
    }

    function _rotaDeFuga() private view returns (Route memory r) {
        uint256 qAB = (AMOUNT_IN * 9970 * 1_000_000e18) / (1_000_000e18 * 10_000 + AMOUNT_IN * 9970);

        Leg[] memory l0 = new Leg[](1);
        l0[0] = Leg({
            pool: address(pairAB), hooks: address(0), kind: BPC.KIND_V2, fee: 30,
            tickSpacing: 0, zeroForOne: address(tA) < address(tB),
            stable: false, amountIn: AMOUNT_IN, expectedOut: qAB, auxId: bytes32(0)
        });
        // A perna que desliga tudo: expectedOut = 0 e uma pool de estado zero.
        Leg[] memory l1 = new Leg[](1);
        l1[0] = Leg({
            pool: address(poolBC), hooks: address(0), kind: BPC.KIND_V3, fee: 3000,
            tickSpacing: 60, zeroForOne: address(tB) < address(tC),
            stable: false, amountIn: qAB, expectedOut: 0, auxId: bytes32(0)
        });

        Hop[] memory hops = new Hop[](2);
        hops[0] = Hop({tokenIn: address(tA), tokenOut: address(tB), amountIn: AMOUNT_IN, expectedOut: qAB, legs: l0});
        hops[1] = Hop({tokenIn: address(tB), tokenOut: address(tC), amountIn: qAB, expectedOut: 0, legs: l1});

        r = Route({
            hops: hops, totalOut: 0, singleOut: 0, singleOutFloor: 0,
            expectedImpactBps: 0, confidenceWad: 0, estGas: 0,
            hasSurplus: false, isV4Bundle: false
        });
    }

    // ═════════════════════════════════════════════════════════════════════════════════════════
    //  2026-08-21: a fee ancorava na ENTRADA.  |  2026-08-22: ancora na PRIMEIRA PONTE.
    //
    //  A INVARIANTE DE ONTEM era mais forte NA FORMA:
    //      "28 bps da entrada, em tokenIn, SEMPRE — cobrada ANTES de a rota comecar."
    //  Um numero fixo antes de qualquer execucao, imune a qualquer retorcimento de rota.
    //
    //  A DE HOJE (decisao do dono: uma cobranca em vez de N, e em moeda de ponte):
    //      "28 bps do valor que o Router segura na PRIMEIRA MOEDA DE PONTE da rota."
    //  Multi-hop: o input do hop 1. Directo com destino em ponte: a saida. Directo sem ponte
    //  no destino: a entrada.
    //
    //  O QUE SE GANHOU: uma so cobranca (com tres hops a antiga cobraria ~84 bps efectivos
    //  quando a constante diz 28), e a tesouraria recebe WETH/USDC em vez de po do destino.
    //
    //  O QUE SE PERDEU, E ESTA ESCRITO PARA NAO SER DESCOBERTO POR ACIDENTE: a fee passou a
    //  DEPENDER DA ROTA. Ontem a classe inteira "retorcer a rota para pagar menos" estava
    //  fechada POR CONSTRUCAO; hoje esta fechada POR ARGUMENTO — o canal de fuga conhecido e o
    //  residual da ponte, e e exactamente a ponte que passa a ser taxada, portanto menos ponte
    //  recebida significa menos ponte extraivel. O argumento aguenta para ESTE ataque (medido
    //  abaixo). NAO ha prova de que aguenta para todos.
    // ═════════════════════════════════════════════════════════════════════════════════════════

    /// 28 bps da ENTRADA — o tecto teorico. A cobranca real fica ligeiramente abaixo porque
    /// incide sobre o valor NA PONTE, que sofreu o impacto de preco do hop 0.
    uint256 constant FEE_ESPERADA = (AMOUNT_IN * 28) / 10_000;   // 28 bps de 1000 = 2,8
    /// Tolerancia para esse impacto: 1% do valor da fee. Medido: 2,7888 contra 2,8000 (0,4%).
    uint256 constant TOLERANCIA = FEE_ESPERADA / 100;

    /// A ROTA DE ATAQUE PAGA. E a mesma que extraia ~996 tokens com fee zero.
    function test_RotaDeFugaPagaAFeeCompleta() public {
        uint256 t1Antes = tA.balanceOf(treasury1) + tA.balanceOf(treasury2);

        vm.prank(user);
        router.swapExactIn(_rotaDeFuga(), AMOUNT_IN, 1, user, block.timestamp + 1);

        t1Antes;  // a fee ja nao sai em A; a leitura fica para documentar a mudanca
        // A FEE SAI NA PONTE (tB), nao na entrada nem no destino de fachada.
        uint256 emB = tB.balanceOf(treasury1) + tB.balanceOf(treasury2);
        uint256 emA = tA.balanceOf(treasury1) + tA.balanceOf(treasury2);
        uint256 emC = tC.balanceOf(treasury1) + tC.balanceOf(treasury2);
        emit log_named_decimal_uint("fee em B (a PONTE)", emB, 18);
        assertEq(emA, 0, "nao sai na entrada");
        assertEq(emC, 0, "nao sai no destino de fachada");
        // O NUCLEO: a rota de ataque paga. Extraia ~996 tokens com fee zero antes do fix de 21/08.
        assertGe(emB, FEE_ESPERADA - TOLERANCIA,
            "a rota de fuga tem de pagar ~28 bps do valor movido, na moeda de ponte");
        assertLe(emB, FEE_ESPERADA, "e nunca mais do que 28 bps da entrada");
    }

    /// A INVARIANTE, escrita por extenso: a fee e uma IGUALDADE sobre a entrada, nao um limite
    /// sobre a saida. Nenhuma rota a pode mover.
    /// @notice A FEE DEIXOU DE SER IGUAL EM QUALQUER ROTA — e este teste passou a
    ///         medir QUANTO e que ela varia, em vez de exigir que nao varie.
    ///
    /// @dev O QUE MUDOU E PORQUE ISTO E UMA FUGA, ainda que pequena.
    ///      Ate 21/08 a fee eram 28 bps do `amountIn`, cobrados ANTES de a rota
    ///      correr: identica para toda a gente, imune a forma da rota.
    ///      Desde 22/08 cobra-se UMA vez, na primeira moeda de PONTE. Consequencia
    ///      aritmetica directa:
    ///
    ///        rota de 1 hop cujo destino NAO e ponte  -> 28 bps da ENTRADA
    ///        rota de 2+ hops                          -> 28 bps do valor NA PONTE,
    ///                                                    que ja sofreu o impacto
    ///                                                    de preco do hop 0
    ///
    ///      MEDIDO: 2,8000 contra 2,7888 — o atacante que acrescenta um hop inutil
    ///      paga 0,4% menos. O desconto E o impacto do hop 0, portanto CRESCE com o
    ///      tamanho do trade: num hop 0 com 5% de impacto, a fee desce 5%.
    ///
    ///      NAO COMPOE com mais hops (so ha uma cobranca), logo o desconto esta
    ///      limitado pelo impacto de UM hop. E o preco da decisao de cobrar em
    ///      moeda de ponte, e fica escrito aqui para ninguem o descobrir por
    ///      acidente. Se um dia incomodar, o fecho e cobrar `max(28bps da entrada,
    ///      28bps da ponte)` — mas isso volta a precisar do valor da entrada no
    ///      frame, que foi o que esta mudanca simplificou.
    function test_FeeMenorEmRotaLongaMasLimitadaPeloImpactoDeUmHop() public {
        // rota de ataque: 2 hops, paga na ponte
        uint256 a0 = tB.balanceOf(treasury1) + tB.balanceOf(treasury2);
        vm.prank(user);
        router.swapExactIn(_rotaDeFuga(), AMOUNT_IN, 1, user, block.timestamp + 1);
        uint256 feeAtaque = tB.balanceOf(treasury1) + tB.balanceOf(treasury2) - a0;

        emit log_named_decimal_uint("fee da rota longa (na ponte)", feeAtaque, 18);
        emit log_named_decimal_uint("28 bps da entrada (o tecto)", FEE_ESPERADA, 18);

        // O TECTO: nunca pode pagar MAIS do que 28 bps da entrada.
        assertLe(feeAtaque, FEE_ESPERADA, "a fee nao pode exceder 28 bps da entrada");
        // O CHAO: o desconto esta limitado ao impacto de UM hop. Se algum dia uma
        // rota pagar muito abaixo disto, ha uma fuga NOVA e este teste apanha-a.
        assertGe(feeAtaque, FEE_ESPERADA - TOLERANCIA,
            "o desconto tem de ficar dentro do impacto de um hop");
    }

    function test_DivisaoDasTesourariasMantemSe() public {
        vm.prank(user);
        router.swapExactIn(_rotaDeFuga(), AMOUNT_IN, 1, user, block.timestamp + 1);
        // A DIVISAO 30/70 e o que este teste pina — nao o valor absoluto, que
        // agora depende do impacto do hop 0. Medir o total e dividi-lo mantem o
        // teste a testar a REGRA e nao um numero que a curva mexe.
        uint256 t1 = tB.balanceOf(treasury1);
        uint256 t2 = tB.balanceOf(treasury2);
        uint256 total = t1 + t2;
        assertGe(total, FEE_ESPERADA - TOLERANCIA, "a fee tem de ser ~28 bps do valor movido");
        assertLe(total, FEE_ESPERADA, "e nunca mais do que 28 bps da entrada");
        assertEq(t1, (total * 3_000) / 10_000, "tesouraria 1 leva 30%");
        assertEq(t2, total - t1, "tesouraria 2 leva o resto, sem po perdido");
    }

    /// O SEGUNDO CANAL, tambem fechado. A volta circular A->B->A->C extraia 992 A com fee zero.
    function test_SegundoCanalTambemPaga() public {
        MockV2Pair pairBA = new MockV2Pair(address(tB), address(tA));
        tA.mint(address(pairBA), 1_000_000e18);
        tB.mint(address(pairBA), 1_000_000e18);
        pairBA.setReserves(uint112(1_000_000e18), uint112(1_000_000e18));
        UnderConsumingV3Pool poolAC = new UnderConsumingV3Pool(address(tA), address(tC), address(tC));
        tC.mint(address(poolAC), 1_000e18);

        uint256 qAB = (AMOUNT_IN * 9970 * 1_000_000e18) / (1_000_000e18 * 10_000 + AMOUNT_IN * 9970);
        uint256 qBA = (qAB * 9970 * 1_000_000e18) / (1_000_000e18 * 10_000 + qAB * 9970);

        Leg[] memory l0 = new Leg[](1);
        l0[0] = Leg({pool: address(pairAB), hooks: address(0), kind: BPC.KIND_V2, fee: 30,
            tickSpacing: 0, zeroForOne: address(tA) < address(tB), stable: false,
            amountIn: AMOUNT_IN, expectedOut: qAB, auxId: bytes32(0)});
        Leg[] memory l1 = new Leg[](1);
        l1[0] = Leg({pool: address(pairBA), hooks: address(0), kind: BPC.KIND_V2, fee: 30,
            tickSpacing: 0, zeroForOne: address(tB) < address(tA), stable: false,
            amountIn: qAB, expectedOut: qBA, auxId: bytes32(0)});
        Leg[] memory l2 = new Leg[](1);
        l2[0] = Leg({pool: address(poolAC), hooks: address(0), kind: BPC.KIND_V3, fee: 3000,
            tickSpacing: 60, zeroForOne: address(tA) < address(tC), stable: false,
            amountIn: qBA, expectedOut: 0, auxId: bytes32(0)});

        Hop[] memory hops = new Hop[](3);
        hops[0] = Hop({tokenIn: address(tA), tokenOut: address(tB), amountIn: AMOUNT_IN, expectedOut: qAB, legs: l0});
        hops[1] = Hop({tokenIn: address(tB), tokenOut: address(tA), amountIn: qAB, expectedOut: qBA, legs: l1});
        hops[2] = Hop({tokenIn: address(tA), tokenOut: address(tC), amountIn: qBA, expectedOut: 0, legs: l2});

        Route memory r = Route({hops: hops, totalOut: 0, singleOut: 0, singleOutFloor: 0,
            expectedImpactBps: 0, confidenceWad: 0, estGas: 0, hasSurplus: false, isV4Bundle: false});

        // A volta circular A->B->A->C tem 3 hops: a fee sai no input do hop 1, que e o tB.
        uint256 antes = tB.balanceOf(treasury1) + tB.balanceOf(treasury2);
        vm.prank(user);
        router.swapExactIn(r, AMOUNT_IN, 1, user, block.timestamp + 1);
        uint256 cobrada = tB.balanceOf(treasury1) + tB.balanceOf(treasury2) - antes;

        // O INCENTIVO VOLTOU A INVERTER-SE, E ESTA E A CONSEQUENCIA QUE MAIS IMPORTA.
        //
        // Com a fee POR HOP (21/08), uma volta circular de tres hops pagava TRES
        // vezes: encher a rota de hops era uma forma de pagar MAIS, e o proprio
        // ataque se auto-desencorajava.
        //
        // Com a fee UNICA na primeira ponte (22/08), acrescentar hops faz a fee
        // descer — pelo impacto de preco do hop 0, e so por esse. Medido aqui:
        // 2,7888 contra os 2,8000 que uma rota de 1 hop sem ponte no destino paga.
        //
        // O ATAQUE CONTINUA A NAO COMPENSAR, e e por isso que este teste passa a
        // pinar o LIMITE em vez da igualdade: a volta circular paga ~28 bps do
        // valor na ponte e devolve ao atacante menos do que ele meteu (duas
        // travessias de curva). O desconto de 0,4% nao paga a perda de ~60 bps
        // das duas passagens. Mas o desencorajamento deixou de ser ESTRUTURAL e
        // passou a ser ECONOMICO — depende dos numeros do mercado, nao da forma
        // do contrato.
        emit log_named_decimal_uint("fee da volta circular (na ponte)", cobrada, 18);
        assertLe(cobrada, FEE_ESPERADA, "nunca mais do que 28 bps da entrada");
        assertGe(cobrada, FEE_ESPERADA - TOLERANCIA,
            "o desconto tem de ficar dentro do impacto de UM hop - se descer mais, ha fuga nova");

    }
}
