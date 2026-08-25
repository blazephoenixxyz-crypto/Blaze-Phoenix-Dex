// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test, console2} from "forge-std/Test.sol";
import {BlazePhoenixCore as BPC} from "../src/BlazePhoenixCore.sol";

/// @notice REGRESSAO do achado F2 (revisao 2026-08-25, CONFIRMADO por red-first
///         e corrigido no mesmo dia).
///
/// O DEFEITO: `effV2Fee` so substituia o zero e nunca limitava, e um par V2 nao
/// tem `fee()` que desminta a calldata — logo `leg.fee = 9_900` (99%) deflacionava
/// `legQuotes` -> `hopQuote` -> `finalHopQuote` -> `protocolFloorOut` (Router:1217).
/// MEDIDO na primeira versao deste ficheiro: quote honesto 996,0e18 contra 10,0e18
/// fabricado (racio 1%), e o piso do protocolo caia de 956,2e18 para 9,6e18. So o
/// `userMinOut` sobrava — expondo integradores que reencaminham rotas de terceiros.
///
/// A CURA: um TECTO no produtor unico (`V2_FEE_CEILING_BPS = 100`). Fechar no
/// produtor e nao no call-site e o que mantem quote e execucao byte-a-byte iguais
/// — ambos os lados do "par que TEM de concordar" (Core:945-949) chamam esta
/// funcao, e um tecto so num deles fa-los-ia divergir e disparar o piso em rotas
/// honestas.
///
/// Estes testes AFIRMAM A CURA. Se algum voltar a ficar vermelho, o tecto caiu.
contract ReviewF2V2FeeFloorDeflationTest is Test {
    uint256 constant R_IN  = 1_000_000e18;
    uint256 constant R_OUT = 1_000_000e18;
    uint256 constant AMT   = 1_000e18;

    /// A fee adversarial ja nao chega ao quote: cai no default da casa, logo o
    /// quote fabricado e IGUAL ao honesto e nao ha nada a deflacionar.
    function test_FeeAdversarialJaNaoDeprimeOQuote() public pure {
        uint24 honesta   = BPC.effV2Fee(0);
        uint24 fabricada = BPC.effV2Fee(9_900);

        assertEq(honesta, 30, "o default de 30 bps e o contrato de effV2Fee");
        assertEq(fabricada, 30, "REGRESSAO F2: uma fee de 99% tem de cair no default, nao passar intacta");

        uint256 qHonesto   = BPC.outV2(AMT, R_IN, R_OUT, honesta);
        uint256 qFabricado = BPC.outV2(AMT, R_IN, R_OUT, fabricada);

        console2.log("quote honesto  :", qHonesto);
        console2.log("quote fabricado:", qFabricado);
        assertEq(qFabricado, qHonesto, "com o tecto, a calldata adversarial nao move o quote");
    }

    /// O piso do protocolo e linear no quote — com o tecto, deixa de herder
    /// deflacao nenhuma. (Era este o dano: piso 956,2e18 -> 9,6e18.)
    function test_PisoDoProtocoloJaNaoEhDeflacionavel() public pure {
        uint256 floorBps = 9_600;   // FLOOR_BASE_BPS, o caso limpo
        uint256 pisoHonesto   = BPC.mulDiv(BPC.outV2(AMT, R_IN, R_OUT, BPC.effV2Fee(0)),     floorBps, BPC.BPS);
        uint256 pisoFabricado = BPC.mulDiv(BPC.outV2(AMT, R_IN, R_OUT, BPC.effV2Fee(9_900)), floorBps, BPC.BPS);

        console2.log("piso honesto  :", pisoHonesto);
        console2.log("piso fabricado:", pisoFabricado);
        assertEq(pisoFabricado, pisoHonesto, "REGRESSAO F2: o piso do protocolo nao pode seguir a fee da calldata");
    }

    /// A FRONTEIRA, porque um tecto so vale se souber onde esta. 100 bps (1%) e
    /// plausivel e passa; 101 ja e adversarial e cai. E as fees reais do terreno
    /// (30 da UniV2, 25 da Pancake, 5 de stables) continuam a passar intactas —
    /// o tecto nao pode custar cobertura em forks legitimos.
    function test_AFronteiraDoTecto() public pure {
        assertEq(BPC.effV2Fee(100), 100, "1% e o limite plausivel: tem de passar");
        assertEq(BPC.effV2Fee(101), 30,  "acima de 1% e adversarial: cai no default");
        assertEq(BPC.effV2Fee(30),  30,  "UniV2/Sushi: 30 bps");
        assertEq(BPC.effV2Fee(25),  25,  "Pancake V2: 25 bps");
        assertEq(BPC.effV2Fee(5),   5,   "pares de stables em forks Solidly-like: 5 bps");
    }
}
