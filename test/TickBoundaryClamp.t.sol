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
        uint160 lim = BPC.sqrtPriceAtTick(-60);   // the lower edge of [-60, 0), below price 1
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
        uint160 lim = BPC.sqrtPriceAtTick(-60);
        assertEq(
            BPC.outV3(ain, sp, L, 3000, true, lim),
            BPC.outV3(ain, sp, L, 3000, true, 0),
            "o que cabe no intervalo nao pode ser tocado"
        );
    }

    // The spacing-inferred boundary these tests once pinned (`sqrtBoundary`) is gone: since the
    // ninth wave a V4 promise walks the pool's own book (`Core.v4WalkOut`, pinned by
    // test/V4TickWalk.t.sol and test/V4PromiseBound.t.sol). What remains here is `outV3`'s
    // truncation at a price limit, a primitive the n-version lane also exercises.
}
