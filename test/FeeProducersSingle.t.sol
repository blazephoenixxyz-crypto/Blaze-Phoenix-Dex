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
// (2) "qual e a fee VIVA desta pool concentrada?"     -> BPC.quoteV3Fee
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
        vm.assume(declarada != 0 && declarada <= 100);   // <= o tecto V2_FEE_CEILING_BPS
        assertEq(BPC.effV2Fee(declarada), declarada, "uma fee V2 PLAUSIVEL (<= 1%) nao pode ser substituida");
    }

    /// O TECTO — a espec escrita do defeito F2 (revisao 2026-08-25). Uma fee de
    /// calldata acima de 1% e adversarial (um par V2 real nunca cobra tanto, e
    /// nao ha `fee()` para a desmentir): cai no default da casa, e por isso o
    /// piso do protocolo deixa de ser deflacionavel. Medido: 9_900 -> 30.
    function testFuzz_FeeV2AdversarialCaiNoDefault(uint24 declarada) public pure {
        vm.assume(declarada > 100);
        assertEq(BPC.effV2Fee(declarada), 30, "fee V2 > 1% e adversarial: tem de cair no default de 30 bps");
    }

    // ─── (2) quoteV3Fee — o produtor unico do caminho quote/impacto ──────────
    //
    // Era `effV3Fee` (pure). O Router mantinha um ternario proprio semanticamente
    // identico, e a familia CL inteira quotava 0 porque o sentinel `fee=0` da
    // Algebra era aplicado a pools cuja fee vive em `fee()` (nota 136 do cofre).
    // O produtor unico resolve as TRES fontes por ordem de autoridade:
    // config > globalState medido > fee() do pool > fail-closed.
    // `SEM_FEE` nao tem codigo: o staticcall a fee() devolve 0 bytes e o
    // produtor tem de tratar isso como imedivel.

    address internal constant SEM_FEE = address(0xdeAD00000000000000000000000000000000dEAd);

    /// O NUCLEO. Um 0% MEDIDO e legal e tem de sair como 0 — nunca como o sentinela.
    /// Este e o caso exato em que a copia do Router divergia.
    function test_ZeroPorcentoMedidoEhLegal() public view {
        assertEq(BPC.quoteV3Fee(SEM_FEE, 0, 0, true), 0, "0% medido com sucesso e uma fee legal, nao uma falha");
    }

    /// A metade oposta: nao medido (e sem fee() que responda) fecha.
    function test_NaoMedidoFechaFechado() public view {
        assertEq(BPC.quoteV3Fee(SEM_FEE, 0, 0, false), 0xFFFFFF, "fee dinamica nao medida tem de fechar fechado");
        assertTrue(BPC.quoteV3Fee(SEM_FEE, 0, 0, false) >= 1_000_000, "o sentinela tem de matar a cotacao");
    }

    /// O CASO CL — a razao de o produtor ser view: config 0, pool nao-dinamica,
    /// mas a fee vive no proprio pool. Antes disto: sentinela e quote 0 para a
    /// familia inteira (Aero CL: 0 pares ganhos em 122 com 1.479 WETH no pool).
    function test_FeeDoPoolResolveOCasoCL() public {
        FeeOnlyPool pool = new FeeOnlyPool();
        assertEq(BPC.quoteV3Fee(address(pool), 0, 0, false), 334, "config 0 + nao-dyn tem de ler fee() do pool");
    }

    function testFuzz_MedidaPassaIntacta(uint24 medida) public view {
        medida = uint24(bound(uint256(medida), 0, 999_999));
        assertEq(BPC.quoteV3Fee(SEM_FEE, 0, medida, true), medida, "a fee medida passa sem ser tocada");
    }

    function testFuzz_ChaveEstaticaVenceTudo(uint24 cfg, uint24 medida, bool dyn) public view {
        vm.assume(cfg != 0);
        assertEq(BPC.quoteV3Fee(SEM_FEE, cfg, medida, dyn), cfg, "uma chave estatica nao-zero e a verdade");
    }

    // ─── A CONSEQUENCIA OBSERVAVEL ───────────────────────────────────────────

    /// E aqui que se ve o dano que a copia causava. Os dois zeros produzem cotacoes OPOSTAS:
    /// pelo produtor unico a pool cota; pelo sentinela cota ZERO e desaparece do routing.
    /// Sem esta assercao, os testes acima seriam aritmetica sobre uma funcao pura sem provar
    /// que a diferenca importa.
    function test_OsDoisZerosDaoCotacoesOpostas() public view {
        // Preco 1:1 (sqrtPriceX96 = 2^96). Um preco no extremo do dominio faria a curva
        // devolver zero por razao FISICA e o teste passaria por engano — a fee tem de ser a
        // unica variavel entre as duas cotacoes.
        uint160 sp  = uint160(1) << 96;
        uint128 liq = 1e18;

        uint24 legal    = BPC.quoteV3Fee(SEM_FEE, 0, 0, true);   // 0% medido
        uint24 fechado  = BPC.quoteV3Fee(SEM_FEE, 0, 0, false);  // nao medido

        uint256 comFeeLegal   = BPC.outV3(1e18, sp, liq, legal,   true, 0);
        uint256 comSentinela  = BPC.outV3(1e18, sp, liq, fechado, true, 0);

        assertGt(comFeeLegal, 0, "uma pool de 0% tem de continuar cotavel");
        assertEq(comSentinela, 0, "uma fee nao medida tem de matar a cotacao");
    }
}

/// Pool minima que so sabe a propria fee — o contrato exato do caso CL.
contract FeeOnlyPool {
    function fee() external pure returns (uint24) { return 334; }
}
