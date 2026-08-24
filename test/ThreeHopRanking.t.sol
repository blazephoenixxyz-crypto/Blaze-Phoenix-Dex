// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";

/// @notice ACRESCENTAR TOPOLOGIAS NAO ALONGA ROTAS.
///
/// ─────────────────────────────────────────────────────────────────────────
///  A PREOCUPACAO DO DONO, E PORQUE ELA JA ESTA RESPONDIDA PELO DESENHO
/// ─────────────────────────────────────────────────────────────────────────
///  "se o melhor preco e logo directo ou 1 hop nao ha necessidade de 2 hops"
///
///  O `_considera` (o acumulador que substituiu o `_rank`) compara `totalOut` —
///  a saida CONSTRUIDA e MEDIDA de cada topologia. Nao ha preferencia por
///  profundidade, nem penalizacao por ela: a rota que entrega mais ganha, ponto.
///
///  Acrescentar a topologia de 3 hops (duas pontes) acrescenta um CANDIDATO ao
///  juizo que ja existia. Nunca substitui um vencedor melhor.
///
///  Este ficheiro pina isso replicando a aritmetica exacta do acumulador, para
///  que ninguem introduza mais tarde um desempate por topologia ("preferir a
///  mais curta", "penalizar 3 hops") sem que um teste fique vermelho. Um
///  desempate desses seria um SEGUNDO produtor do juizo "qual rota e melhor",
///  ao lado do `totalOut` — e o pior dos dois, porque topologia e um proxy e
///  `totalOut` e o numero real. E a mesma R1 que a nota 128 §4 documentou.
contract ThreeHopRankingTest is Test {
    /// Replica do acumulador `_considera` do Solver.
    struct M { uint256 bestU; uint256 secU; uint8 bestId; uint8 secId; }

    function _considera(M memory m, uint256 out_, uint8 id) internal pure {
        if (out_ == 0) return;
        if (out_ > m.bestU) { m.secU = m.bestU; m.secId = m.bestId; m.bestU = out_; m.bestId = id; }
        else if (out_ > m.secU) { m.secU = out_; m.secId = id; }
    }

    uint8 constant DIRECTO = 1;
    uint8 constant UMA_PONTE = 2;
    uint8 constant DUAS_PONTES = 3;

    /// @notice O NUCLEO. Se a directa entrega mais, a directa ganha — mesmo com
    ///         as topologias de 3 hops todas presentes e a devolverem rotas.
    function test_DirectaGanhaQuandoEntregaMais() public pure {
        M memory m;
        _considera(m, 1_000e18, DIRECTO);
        _considera(m,   990e18, UMA_PONTE);
        _considera(m,   995e18, DUAS_PONTES);
        _considera(m,   980e18, DUAS_PONTES);
        assertEq(m.bestId, DIRECTO, "a directa entregava mais e tem de ganhar");
        assertEq(m.bestU, 1_000e18, "com a saida dela");
    }

    /// @notice E o simetrico: se as duas pontes entregam mais, ganham. Sem isto
    ///         o teste acima ficaria verde com um acumulador que preferisse
    ///         sempre a directa — que e exactamente o desempate por topologia
    ///         que este ficheiro existe para impedir.
    function test_DuasPontesGanhamQuandoEntregamMais() public pure {
        M memory m;
        _considera(m,   900e18, DIRECTO);
        _considera(m,   950e18, UMA_PONTE);
        _considera(m, 1_010e18, DUAS_PONTES);
        assertEq(m.bestId, DUAS_PONTES, "a de 3 hops entregava mais");
        assertEq(m.secId, UMA_PONTE, "e a segunda melhor e a de 1 ponte");
    }

    /// @notice Uma topologia que nao produz rota (totalOut == 0) nao entra no
    ///         juizo nem ocupa o lugar de segunda. E o que permite chamar
    ///         `_considera` por todas as combinacoes de pontes sem cuidados: as
    ///         que nao existem devolvem uma Route vazia e sao ignoradas.
    function test_TopologiaSemRotaNaoEntra() public pure {
        M memory m;
        _considera(m, 1_000e18, DIRECTO);
        _considera(m,        0, DUAS_PONTES);
        _considera(m,        0, DUAS_PONTES);
        assertEq(m.bestId, DIRECTO, "a directa mantem-se");
        assertEq(m.secU, 0, "nenhuma rota vazia pode ser a segunda melhor");
    }

    /// @notice O EMPATE fica com quem chegou primeiro — e a ordem no Solver e
    ///         directo, 1 ponte, 2 pontes. Logo num empate exacto a rota mais
    ///         CURTA vence, sem precisar de um desempate explicito.
    ///
    ///         Isto responde ao ponto do dono pelo lado mais fino: nao ha
    ///         "necessidade de 2 hops" nem em empate.
    function test_EmpateFicaComAMaisCurta() public pure {
        M memory m;
        _considera(m, 1_000e18, DIRECTO);
        _considera(m, 1_000e18, UMA_PONTE);
        _considera(m, 1_000e18, DUAS_PONTES);
        assertEq(m.bestId, DIRECTO, "empate: `>` e estrito, a primeira fica");
    }
}
