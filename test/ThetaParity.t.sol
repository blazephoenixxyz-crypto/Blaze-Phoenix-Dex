// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// θ — PARIDADE COM OS RAMOS QUE ELA SUBSTITUI.
//
// A tabela θ so vale se cada bit reproduzir EXATAMENTE o predicado escrito a mao que substitui.
// Este ficheiro e a prova disso, kind a kind, atributo a atributo — e e o unico gate que impede
// que a tabela e os ramos se afastem enquanto ambos existirem.
//
// PORQUE ESTE TESTE E O MAIS IMPORTANTE DA MUDANCA. A tabela existe para matar a assinatura de
// defeito da casa ("um fix aplicado a UM de dois canais simetricos"). Mas durante a migracao HA
// dois canais: a tabela e os `if`s que ainda nao foram convertidos. Sem paridade verificada, a
// mudanca que veio curar a divergencia seria ela propria a criar uma.
//
// E o meta-padrao mais fino, aprendido nesta base em 2026-08-20: um fix pode ficar DECORATIVO sem
// ninguem lhe tocar, porque um TERCEIRO fix mudou o mecanismo intermedio de que o teste dependia.
// Por isso as asserções aqui sao contra os predicados LITERAIS, escritos por extenso — nao contra
// um helper que possa ser reescrito ao mesmo tempo que a tabela.

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixCore as BPC} from "../src/BlazePhoenixCore.sol";

contract ThetaParityTest is Test {

    /// A_RESERVES: profundidade e impacto por getReserves(). O predicado literal de hoje, escrito
    /// por extenso no Router (`_v2Depth`) e no Solver, e `k == KIND_V2 || k == KIND_SOLIDLY`.
    function test_Parity_Reserves() public pure {
        for (uint8 k = 0; k <= 8; k++) {
            bool ramoAntigo = (k == BPC.KIND_V2 || k == BPC.KIND_SOLIDLY);
            assertEq(BPC.kindHas(k, BPC.A_RESERVES), ramoAntigo, "A_RESERVES diverge do ramo escrito a mao");
        }
    }

    /// A_CONC_POOL: sqrtPriceX96 e L lidos NO ENDERECO DA POOL. Predicado literal:
    /// `k == KIND_V3 || k == KIND_ALGEBRA` (o braco de cotacao do Router, Core.universalQuote).
    function test_Parity_ConcentratedAtPool() public pure {
        for (uint8 k = 0; k <= 8; k++) {
            bool ramoAntigo = (k == BPC.KIND_V3 || k == BPC.KIND_ALGEBRA);
            assertEq(BPC.kindHas(k, BPC.A_CONC_POOL), ramoAntigo, "A_CONC_POOL diverge");
        }
    }

    /// A_CONC_SING: estado por extsload no singleton; `pool` e o poolId truncado (sem codigo) e o
    /// tokenOut viaja em auxId. Predicado literal: `k == KIND_V4 || k == KIND_V4_NATIVE`.
    function test_Parity_ConcentratedAtSingleton() public pure {
        for (uint8 k = 0; k <= 8; k++) {
            bool ramoAntigo = (k == BPC.KIND_V4 || k == BPC.KIND_V4_NATIVE);
            assertEq(BPC.kindHas(k, BPC.A_CONC_SING), ramoAntigo, "A_CONC_SING diverge");
        }
    }

    /// A_PAIR_VER: token0()/token1() existem, logo a prova de autenticidade do Hub aplica-se.
    /// O predicado de hoje e a constante `KINDS_PAIR_PROOF` do Hub, usada no `recordSwap` (NAO
    /// no `_register`, como esta prosa afirmou durante dias — era o mesmo erro que estava no
    /// backlog da nota 122). Era o literal 0x6b = bits {0,1,3,5,6}; o bit 3 pertencia a uma venue
    /// ja retirada e saiu quando se provou que o kind 3 e inalcancavel a partir do unico produtor
    /// de kinds. Hoje coincide EXATAMENTE com o A_PAIR_VER — e essa coincidencia esta pinada por
    /// construcao em `test_PairProofMaskMatchesTheta`, e NAO colapsada: continuam a ser duas
    /// perguntas diferentes (forma do estado vs predicado de aceitacao).
    function test_Parity_PairVerifiable_LiveKinds() public pure {
        uint8[3] memory vivos = [BPC.KIND_V2, BPC.KIND_V3, BPC.KIND_SOLIDLY];
        for (uint256 i; i < vivos.length; i++) {
            assertTrue(BPC.kindHas(vivos[i], BPC.A_PAIR_VER), "kind vivo pair-shaped perdeu A_PAIR_VER");
            // (o pino contra a constante REAL do Hub vive em test_PairProofMaskMatchesTheta —
            //  este laco so afirma que a theta marca os kinds vivos que sao pares)
        }
        assertTrue(BPC.kindHas(BPC.KIND_ALGEBRA, BPC.A_PAIR_VER), "ALGEBRA e pair-shaped");
        // Os singleton-shaped nao expoem token0/token1 — a prova de autenticidade nao lhes aplica.
        assertFalse(BPC.kindHas(BPC.KIND_V4, BPC.A_PAIR_VER), "V4 nao e um par");
        assertFalse(BPC.kindHas(BPC.KIND_V4_NATIVE, BPC.A_PAIR_VER), "V4_NATIVE nao e um par");
    }

    /// LAPIDES. Os kinds excisados (Curve/Balancer) tem campo ZERO: nenhum atributo, em nenhuma
    /// consulta. E o fail-closed de graca — nao ha ramo de default para alguem esquecer.
    function test_DeadKindsHaveNoAttributes() public pure {
        uint8[3] memory mortos = [uint8(2), 3, 7];
        for (uint256 i; i < mortos.length; i++) {
            assertEq(BPC.thetaOf(mortos[i]), 0, "kind excisado ainda tem atributos");
            assertFalse(BPC.kindHasAny(mortos[i], 0xF), "kind excisado responde a alguma consulta");
        }
    }

    /// Um kind fora do dominio devolve zero — sem revert, sem lixo. Um shift alto da 0 por
    /// construcao, e e por isso que nao existe um ramo de "default" para manter sincronizado.
    function test_UnknownKindFailsClosed() public pure {
        assertEq(BPC.thetaOf(9), 0, "kind 9 devia ser vazio");
        assertEq(BPC.thetaOf(200), 0, "kind alto devia ser vazio");
        assertEq(BPC.thetaOf(255), 0, "kind maximo devia ser vazio");
        assertFalse(BPC.kindHasAny(255, 0xF), "kind fora do dominio respondeu a uma consulta");
    }

    /// kindHas exige TODOS os bits da mascara; kindHasAny exige UM. A distincao existe porque as
    /// duas perguntas aparecem no codigo: "e concentrado (em qualquer sitio)?" e "e concentrado
    /// NA POOL?". Confundi-las era exatamente a forma de criar um irmao divergente.
    function test_AllVersusAnySemantics() public pure {
        uint8 concentrado = BPC.A_CONC_POOL | BPC.A_CONC_SING;
        // V3 e concentrado, mas so na pool: tem ALGUM, nao tem TODOS.
        assertTrue (BPC.kindHasAny(BPC.KIND_V3, concentrado), "V3 e concentrado");
        assertFalse(BPC.kindHas   (BPC.KIND_V3, concentrado), "V3 nao pode ser as duas coisas");
        // V4 idem, do outro lado.
        assertTrue (BPC.kindHasAny(BPC.KIND_V4, concentrado), "V4 e concentrado");
        assertFalse(BPC.kindHas   (BPC.KIND_V4, concentrado), "V4 nao pode ser as duas coisas");
        // Nenhum kind e concentrado nos dois sitios ao mesmo tempo — sao formas exclusivas.
        for (uint8 k = 0; k <= 8; k++) {
            assertFalse(BPC.kindHas(k, concentrado), "um kind nao pode ser pool-shaped E singleton-shaped");
        }
    }

    /// A UNIAO — o predicado exato que as duas copias do psi no Hub tinham escrito a mao:
    /// `k == V3 || k == ALGEBRA || k == V4 || k == V4_NATIVE`. Nao e nenhum dos dois atributos
    /// isolados: e "concentrada EM QUALQUER SITIO", que so se exprime como kindHasAny da uniao.
    /// Este pino e o que impede que a conversao e a cadeia se afastem enquanto a cadeia existir
    /// em qualquer outro sitio do protocolo.
    function test_Parity_ConcentratedAnywhere() public pure {
        uint8 uniao = BPC.A_CONC_POOL | BPC.A_CONC_SING;
        for (uint8 k = 0; k <= 8; k++) {
            bool ramoAntigo = (k == BPC.KIND_V3 || k == BPC.KIND_ALGEBRA
                || k == BPC.KIND_V4 || k == BPC.KIND_V4_NATIVE);
            assertEq(BPC.kindHasAny(k, uniao), ramoAntigo, "a uniao conc diverge da cadeia literal");
        }
    }

    /// ESCADA DE GAS: paridade com os numeros literais do Solver de hoje, e o default preservado.
    function test_Parity_GasLadder() public pure {
        assertEq(BPC.kindGasBase(BPC.KIND_V2),         90_000,  "V2");
        assertEq(BPC.kindGasBase(BPC.KIND_V3),        110_000,  "V3");
        assertEq(BPC.kindGasBase(BPC.KIND_SOLIDLY),    90_000,  "SOLIDLY");
        assertEq(BPC.kindGasBase(BPC.KIND_ALGEBRA),   110_000,  "ALGEBRA");
        assertEq(BPC.kindGasBase(BPC.KIND_V4),        180_000,  "V4");
        assertEq(BPC.kindGasBase(BPC.KIND_V4_NATIVE), 215_000,  "V4_NATIVE");
        // Kind sem campo cai no default historico — o comportamento de hoje para desconhecidos.
        assertEq(BPC.kindGasBase(2 /* lapide */),     90_000,  "excisado cai no default");
        assertEq(BPC.kindGasBase(9),                   90_000,  "desconhecido cai no default");
        assertEq(BPC.kindGasBase(255),                 90_000,  "fora do dominio cai no default");
    }
}
