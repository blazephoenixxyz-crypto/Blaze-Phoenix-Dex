// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// "O IMPACTO RE-DERIVA A COTACAO" — o padrao, e o pino que impede o seu regresso.
//
// Uma funcao de impacto que embute a curva obriga quem a chama a pagar a curva DUAS vezes,
// porque quem quer impacto JA TEM a cotacao na mao. Era o caso no Router: uma linha chamava
// `impactV3Bps(legAmt, sp, lq, live, zfo)` — que corre o `outV3` por dentro — e a linha
// SEGUINTE chamava `outV3` com argumentos BYTE-IDENTICOS. Uma execucao inteira da curva e um
// delegatecall a mais, por perna concentrada, nas QUATRO portas de swap.
//
// A cura NAO foi duplicar a matematica do racio no Router (isso seria um segundo produtor de um
// numero que ja tem um). Foi extrair a primitiva `impactV3FromOut` e fazer o `impactV3Bps`
// construir-se sobre ela. Continua a haver UMA implementacao do racio.
//
// ESTE FICHEIRO E O QUE TORNA ISSO VERIFICAVEL. Enquanto as duas funcoes existirem, tem de
// concordar EXATAMENTE — e a unica forma honesta de o afirmar e por fuzz, nao por tres casos
// escolhidos por quem escreveu o fix.

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixCore as BPC} from "../src/BlazePhoenixCore.sol";

contract ImpactCurveOnceTest is Test {

    /// A EQUIVALENCIA, por fuzz. Se alguem tocar em qualquer uma das duas sem tocar na outra,
    /// isto fica vermelho com o contra-exemplo na mao.
    function testFuzz_ImpactoDerivadoIgualaImpactoDosInputs(
        uint128 amountIn, uint160 sqrtP, uint128 liq, uint24 feePpm, bool zfo
    ) public pure {
        // Dominio util: o Router so chega aqui com os tres nao-zero (guarda propria), e a fee
        // vive em ppm. Valores fora disto sao cobertos pelos testes de fronteira abaixo.
        amountIn = uint128(bound(uint256(amountIn), 1, type(uint96).max));
        sqrtP    = uint160(bound(uint256(sqrtP), BPC.MIN_SQRT_PRICE_PLUS_ONE, BPC.MAX_SQRT_PRICE_MINUS_ONE));
        liq      = uint128(bound(uint256(liq), 1, type(uint112).max));
        feePpm   = uint24(bound(uint256(feePpm), 0, 1_000_000));

        uint256 dosInputs = BPC.impactV3Bps(amountIn, sqrtP, liq, feePpm, zfo);
        uint256 out       = BPC.outV3(amountIn, sqrtP, liq, feePpm, zfo);
        uint256 derivado  = BPC.impactV3FromOut(out, amountIn, sqrtP, zfo);

        assertEq(derivado, dosInputs,
            "a primitiva e a funcao que a usa divergiram: a curva deixou de correr uma vez");
    }

    /// FRONTEIRAS. As guardas das duas funcoes nao sao as mesmas — a que parte dos inputs tem
    /// de rejeitar `liq == 0` (nao ha curva), a primitiva nem ve a liquidez. O que TEM de ser
    /// igual e o resultado: BPS, o maximo conservador. Uma pool que nao cota trata-se como
    /// impacto total, NUNCA como impacto nulo — inverter isto poria um piso a zero.
    function test_FronteirasFalhamAmbasParaOMaximo() public pure {
        uint160 sp = uint160(BPC.MIN_SQRT_PRICE_PLUS_ONE) + 1e6;

        assertEq(BPC.impactV3Bps(0, sp, 1e18, 3000, true), BPC.BPS, "amountIn 0 -> BPS");
        assertEq(BPC.impactV3Bps(1e18, 0, 1e18, 3000, true), BPC.BPS, "sqrtP 0 -> BPS");
        assertEq(BPC.impactV3Bps(1e18, sp, 0, 3000, true),   BPC.BPS, "liq 0 -> BPS");

        assertEq(BPC.impactV3FromOut(0, 1e18, sp, true),  BPC.BPS, "out 0 -> BPS");
        assertEq(BPC.impactV3FromOut(1e18, 0, sp, true),  BPC.BPS, "amountIn 0 -> BPS");
        assertEq(BPC.impactV3FromOut(1e18, 1e18, 0, true), BPC.BPS, "sqrtP 0 -> BPS");
    }

    /// O SENTINELA DE FAIL-CLOSED. Uma fee >= 1e6 faz o `outV3` devolver 0, e o impacto tem de
    /// ir para BPS pelos DOIS caminhos. E o mecanismo em que o Router se apoia quando nao
    /// consegue medir a fee viva da pool: nunca deixa entrar calldata, deixa entrar o maximo.
    function test_SentinelaDeFeeFechaNosDoisCaminhos() public pure {
        uint160 sp = uint160(BPC.MIN_SQRT_PRICE_PLUS_ONE) + 1e6;
        uint256 out = BPC.outV3(1e18, sp, 1e18, 0xFFFFFF, true);
        assertEq(out, 0, "o sentinela tem de matar a cotacao");
        assertEq(BPC.impactV3Bps(1e18, sp, 1e18, 0xFFFFFF, true), BPC.BPS, "dos inputs -> BPS");
        assertEq(BPC.impactV3FromOut(out, 1e18, sp, true),         BPC.BPS, "derivado -> BPS");
    }
}
