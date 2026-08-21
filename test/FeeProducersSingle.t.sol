// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// DUAS PERGUNTAS DE FEE, DOIS PRODUTORES, ZERO COPIAS.
//
// (1) "que fee cobra uma pool V2 que nao a declara?"  -> BPC.effV2Fee
//     O literal `== 0 ? 30` estava escrito a mao em TRES sitios: o caminho da COTACAO do Router,
//     o da EXECUCAO do Router, e o universalQuote. Os dois primeiros sao o par que TEM de
//     concordar: se divergirem, a cotacao mente sobre o que a execucao vai fazer — a forma exata
//     das fugas de fee ja fechadas nesta base.
//
// (2) "qual e a fee VIVA desta pool concentrada?"     -> BPC.effV3Fee
//     O Router tinha uma copia que DIVERGIA no caso que o Core documenta em voz alta
//     ("0% is legal"): fazia `dynFee != 0 ? dynFee : 0xFFFFFF`, tratando um 0% MEDIDO COM
//     SUCESSO como falha de medicao. Consequencia real: uma pool Algebra de fee genuinamente 0%
//     era cotada a ZERO por esse ramo e caia fora do routing.
//
// O QUE TORNA ISTO INSTRUTIVO: o `test_ZeroDynamicFeeStillQuotes` EXISTIA e PASSAVA — pelo
// caminho do `universalQuote`. Um fix aplicado e testado num de dois canais simetricos, com o
// teste do canal certo a servir de alibi para o canal errado. A assinatura da casa, outra vez.
//
// A DISTINCAO QUE A COPIA PERDIA, e que e o coracao deste ficheiro: o `dyn` de
// `v3StateAndDynFee` e uma flag de SUCESSO DE LEITURA. Com `dyn == true` a leitura correu, logo
// `dynFee == 0` significa "esta pool cobra 0%" e nao "nao consegui ler". Ja o `getV3Fee`
// devolve 0 tanto para "falhou" como para "e mesmo zero" — e por isso SO ESSE ramo pode fechar
// sobre um zero. Dois zeros com significados diferentes; a copia tratava-os como um.

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixCore as BPC} from "../src/BlazePhoenixCore.sol";

contract FeeProducersSingleTest is Test {

    // ─── (1) effV2Fee ────────────────────────────────────────────────────────

    function test_V2FeeDefault() public pure {
        assertEq(BPC.effV2Fee(0), 30, "uma pool V2 que nao declara fee cobra 30 bps");
    }

    function testFuzz_V2FeeDeclaradaVenceSempre(uint24 declarada) public pure {
        vm.assume(declarada != 0);
        assertEq(BPC.effV2Fee(declarada), declarada, "uma fee declarada nao pode ser substituida");
    }

    // ─── (2) effV3Fee ────────────────────────────────────────────────────────

    /// O NUCLEO. Um 0% MEDIDO e legal e tem de sair como 0 — nunca como o sentinela.
    /// Este e o caso exato em que a copia do Router divergia.
    function test_ZeroPorcentoMedidoEhLegal() public pure {
        assertEq(BPC.effV3Fee(0, 0, true), 0, "0% medido com sucesso e uma fee legal, nao uma falha");
    }

    /// A metade oposta: nao medido fecha. O mesmo zero, outro significado.
    function test_NaoMedidoFechaFechado() public pure {
        assertEq(BPC.effV3Fee(0, 0, false), 0xFFFFFF, "fee dinamica nao medida tem de fechar fechado");
        assertTrue(BPC.effV3Fee(0, 0, false) >= 1_000_000, "o sentinela tem de matar a cotacao");
    }

    function testFuzz_MedidaPassaIntacta(uint24 medida) public pure {
        medida = uint24(bound(uint256(medida), 0, 999_999));
        assertEq(BPC.effV3Fee(0, medida, true), medida, "a fee medida passa sem ser tocada");
    }

    function testFuzz_ChaveEstaticaVenceTudo(uint24 cfg, uint24 medida, bool dyn) public pure {
        vm.assume(cfg != 0);
        assertEq(BPC.effV3Fee(cfg, medida, dyn), cfg, "uma chave estatica nao-zero e a verdade");
    }

    // ─── A CONSEQUENCIA OBSERVAVEL ───────────────────────────────────────────

    /// E aqui que se ve o dano que a copia causava. Os dois zeros produzem cotacoes OPOSTAS:
    /// pelo produtor unico a pool cota; pelo sentinela cota ZERO e desaparece do routing.
    /// Sem esta assercao, os testes acima seriam aritmetica sobre uma funcao pura sem provar
    /// que a diferenca importa.
    function test_OsDoisZerosDaoCotacoesOpostas() public pure {
        // Preco 1:1 (sqrtPriceX96 = 2^96). Um preco no extremo do dominio faria a curva
        // devolver zero por razao FISICA e o teste passaria por engano — a fee tem de ser a
        // unica variavel entre as duas cotacoes.
        uint160 sp  = uint160(1) << 96;
        uint128 liq = 1e18;

        uint24 legal    = BPC.effV3Fee(0, 0, true);   // 0% medido
        uint24 fechado  = BPC.effV3Fee(0, 0, false);  // nao medido

        uint256 comFeeLegal   = BPC.outV3(1e18, sp, liq, legal,   true);
        uint256 comSentinela  = BPC.outV3(1e18, sp, liq, fechado, true);

        assertGt(comFeeLegal, 0, "uma pool de 0% tem de continuar cotavel");
        assertEq(comSentinela, 0, "uma fee nao medida tem de matar a cotacao");
    }
}
