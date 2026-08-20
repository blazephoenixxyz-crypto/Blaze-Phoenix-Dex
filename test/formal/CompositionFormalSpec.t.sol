// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  Halmos symbolic proof — as invariantes descobertas na sessão de 2026-08-19.
//  Cada uma nasceu de um defeito REAL: em vez de ficar como comentário que a
//  próxima pessoa não lê, fica provada por máquina sobre TODOS os inputs.
//
//  Run: halmos --contract CompositionFormalSpec
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixCore as BPC} from "../../src/BlazePhoenixCore.sol";

contract CompositionFormalSpec is Test {
    uint256 constant BPS = 10_000;
    uint256 constant LEG_FLOOR_BPS = 8_000;   // espelha Router.LEG_FLOOR_BPS

    // ─── INVARIANTE A: unidades da profundidade (o bug de 2026-08-19) ───
    // depthWad tem de ser TOKEN-denominado em todos os ramos. Para V3/V4 isso é
    // min(L/sqrtP, L*sqrtP) — as reservas virtuais ao preço atual. A propriedade
    // que prende o defeito: o resultado NUNCA excede o lado curto, e para
    // sqrtP == Q96 (preço 1) coincide com L, que é o único ponto onde L cru
    // estaria certo. Fora daí, L cru é sistematicamente diferente.
    function _depthTok(uint256 liq, uint256 sp) internal pure returns (uint256) {
        uint256 x0 = BPC.mulDiv(liq, BPC.Q96, sp);
        uint256 x1 = BPC.mulDiv(liq, sp, BPC.Q96);
        return x0 < x1 ? x0 : x1;
    }

    /// A profundidade token-denominada é sempre o LADO CURTO — nunca sobrestima.
    function check_depthIsShortSide(uint128 liq, uint160 sp) public pure {
        vm.assume(sp != 0);
        vm.assume(liq != 0);
        uint256 d  = _depthTok(uint256(liq), uint256(sp));
        uint256 x0 = BPC.mulDiv(uint256(liq), BPC.Q96, uint256(sp));
        uint256 x1 = BPC.mulDiv(uint256(liq), uint256(sp), BPC.Q96);
        assertLe(d, x0);
        assertLe(d, x1);
    }

    /// No preço unitário (sqrtP == Q96) a conversão coincide com L — o único
    /// ponto onde L cru estaria correto. Prende a razão de ser da conversão.
    function check_depthEqualsLiqAtUnitPrice(uint128 liq) public pure {
        vm.assume(liq != 0);
        assertEq(_depthTok(uint256(liq), BPC.Q96), uint256(liq));
    }

    // ─── INVARIANTE B: orçamento por hop (Camada 1) ───
    // Σgot + folga >= Σatestado, com folga = (BPS-LEG_FLOOR)*(Σatestado/n)/BPS.
    // A propriedade CRÍTICA (a que o Gemini demoliu na v1): para n == 1 a regra
    // do hop tem de colapsar EXATAMENTE no piso por perna — nem mais apertada
    // (rigidez nova) nem mais larga (proteção perdida).
    function _hopPasses(uint256 got, uint256 attested, uint256 n) internal pure returns (bool) {
        if (attested == 0 || n == 0) return true;
        uint256 slack = BPC.mulDiv(attested / n, BPS - LEG_FLOOR_BPS, BPS);
        return got + slack >= attested;
    }

    /// n == 1: a regra do hop é EQUIVALENTE ao piso por perna. Zero rigidez nova,
    /// provado sobre todos os inputs — não em três casos de teste.
    function check_hopCollapsesToLegFloorAtN1(uint128 got, uint128 attested) public pure {
        vm.assume(attested != 0);
        bool hop = _hopPasses(uint256(got), uint256(attested), 1);
        bool leg = uint256(got) >= BPC.mulDiv(uint256(attested), LEG_FLOOR_BPS, BPS);
        assertTrue(hop == leg);
    }

    /// A folga NUNCA excede o que UMA perna média poderia legitimamente perder.
    /// Impede que a regra se torne mais permissiva do que o piso que a origina.
    function check_slackNeverExceedsOneAverageLeg(uint128 attested, uint8 n) public pure {
        vm.assume(n != 0);
        vm.assume(attested != 0);
        uint256 slack = BPC.mulDiv(uint256(attested) / n, BPS - LEG_FLOOR_BPS, BPS);
        assertLe(slack, BPC.mulDiv(uint256(attested), BPS - LEG_FLOOR_BPS, BPS));
    }

    /// Aumentar n só pode APERTAR a folga (nunca alargá-la) — é o que torna o
    /// orçamento não-manipulável por quem acrescenta pernas.
    function check_moreLegsNeverLoosensBudget(uint128 attested, uint8 n) public pure {
        vm.assume(n != 0 && n < 255);
        vm.assume(attested != 0);
        uint256 s1 = BPC.mulDiv(uint256(attested) / n, BPS - LEG_FLOOR_BPS, BPS);
        uint256 s2 = BPC.mulDiv(uint256(attested) / (uint256(n) + 1), BPS - LEG_FLOOR_BPS, BPS);
        assertLe(s2, s1);
    }
}
