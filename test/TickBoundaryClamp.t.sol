// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixCore as BPC} from "../src/BlazePhoenixCore.sol";

/// @notice A COTACAO CONCENTRADA NAO PODE PROMETER ALEM DO INTERVALO QUE VE.
///
/// ─────────────────────────────────────────────────────────────────────────
///  O DEFEITO, MEDIDO
/// ─────────────────────────────────────────────────────────────────────────
///  `outV3` (Core) e um modelo de UM UNICO INTERVALO DE TICKS: usa o `L` e o
///  `sqrtP` correntes e assume `L` constante durante toda a swap. Nunca
///  atravessa ticks. Serve V3 E V4, porque a matematica e a mesma.
///
///  Medido na pool V4 ENA/USDC fee 1% da Base, liquido dos 28 bps de fee:
///      100 USDC     -> -0,16 bps   (exacto: cabe no intervalo)
///      1.000 USDC   -> +1.450 bps  (o preco saiu do intervalo)
///      1.000.000    -> +432 bps, com a saida real SATURADA em 3.376,40 ENA
///
///  O erro tem DOIS sentidos e nao sao equivalentes:
///    · SOBRESTIMAR e perigoso — promete-se o que nao se entrega, e o piso de
///      ferro nao protege porque e derivado da MESMA cotacao inflacionada.
///    · SUBESTIMAR e caro — perdem-se rotas que deviam ganhar.
///  O alvo e EXACTO-OU-ABAIXO.
///
/// ─────────────────────────────────────────────────────────────────────────
///  A CURA, E PORQUE E BARATA
/// ─────────────────────────────────────────────────────────────────────────
///  Os ticks inicializados de uma pool sao SEMPRE multiplos do `tickSpacing`
///  (uma posicao nao pode comecar noutro sitio). Entre dois deles o `L` nao
///  muda. Logo, truncar a swap na fronteira do intervalo corrente da um
///  resultado EXACTO para tudo o que la caiba e ESTRITAMENTE ABAIXO para o
///  resto — nunca acima, para qualquer distribuicao de liquidez.
///
///  E nao custa leituras: o tick corrente vive na MESMA palavra do `slot0` que
///  ja lemos para o `sqrtPriceX96`.
///
///  APROXIMACAO DELIBERADA: a fronteira a `d` ticks esta a um racio de
///  `1,0001^(d/2)` em sqrtPrice. Em vez de exponenciar usa-se `1 + d/20000`.
///  Como `e^x >= 1+x`, a fronteira calculada fica sempre MAIS PERTO que a
///  verdadeira — clampa-se mais cedo, portanto o erro e sempre para o lado
///  seguro. Para spacing 200 a diferenca e 0,005%.
contract TickBoundaryClampTest is Test {
    uint256 constant Q96 = 1 << 96;

    /// @notice O NUCLEO: o clamp nunca pode aumentar a saida.
    function test_ClampNuncaAumentaASaida() public pure {
        uint160 sp = uint160(Q96);          // preco 1
        uint128 L  = 1e21;
        uint256 ain = 1e20;                 // grande de propositio: sai do intervalo
        uint256 semLimite = BPC.outV3(ain, sp, L, 3000, true, 0);
        uint160 lim = BPC.sqrtBoundary(sp, 0, 60, true);
        uint256 comLimite = BPC.outV3(ain, sp, L, 3000, true, lim);
        assertLe(comLimite, semLimite, "clampar nunca pode dar MAIS");
        assertGt(comLimite, 0, "e tem de dar alguma coisa");
    }

    /// @notice E o simetrico, que impede o teste acima de ficar verde com um
    ///         clamp que devolva sempre zero: uma swap PEQUENA cabe no
    ///         intervalo e tem de dar EXACTAMENTE o mesmo.
    function test_SwapPequenaNaoEAfectada() public pure {
        uint160 sp = uint160(Q96);
        uint128 L  = 1e21;
        uint256 ain = 1e12;                 // minuscula face a L
        uint160 lim = BPC.sqrtBoundary(sp, 0, 60, true);
        assertEq(
            BPC.outV3(ain, sp, L, 3000, true, lim),
            BPC.outV3(ain, sp, L, 3000, true, 0),
            "o que cabe no intervalo nao pode ser tocado"
        );
    }

    /// @notice A FRONTEIRA tem de estar do lado certo do preco, nas duas
    ///         direccoes. Sem isto, um sinal trocado clampava para o lado
    ///         errado e o clamp deixava de morder.
    function test_FronteiraDoLadoCerto() public pure {
        uint160 sp = uint160(Q96);
        assertLt(BPC.sqrtBoundary(sp, 30, 60, true),  sp, "zeroForOne: preco DESCE");
        assertGt(BPC.sqrtBoundary(sp, 30, 60, false), sp, "oneForZero: preco SOBE");
    }

    /// @notice Um `spacing` maior da uma fronteira MAIS LONGE — e o que torna
    ///         as pools de 1% (spacing 200) mais permissivas que as de 0,05%
    ///         (spacing 10), como tem de ser.
    function test_SpacingMaiorFronteiraMaisLonge() public pure {
        uint160 sp = uint160(Q96);
        uint160 perto  = BPC.sqrtBoundary(sp, 0, 10,  true);
        uint160 longe  = BPC.sqrtBoundary(sp, 0, 200, true);
        assertGt(perto, longe, "spacing 200 deixa o preco descer mais que spacing 10");
    }

    /// @notice `tickSpacing == 0` (pools nao concentradas, ou registo
    ///         incompleto) tem de desligar o clamp em vez de rebentar.
    function test_SpacingZeroDesligaOClamp() public pure {
        uint160 sp = uint160(Q96);
        assertEq(BPC.sqrtBoundary(sp, 0, 0, true), 0, "spacing 0 = sem limite");
    }
}
