// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixCore as BPC} from "../src/BlazePhoenixCore.sol";
import {MIN_SPLIT_IMPROVEMENT_PPM} from "../src/BlazePhoenixSolver.sol";

/// @notice O LIMIAR DE SPLIT — porque desceu de 20 para 5 bps.
///
/// ─────────────────────────────────────────────────────────────────────────
///  O QUE O GATE FAZIA, E PORQUE O NUMERO ESTAVA ERRADO
/// ─────────────────────────────────────────────────────────────────────────
///  `MIN_SPLIT_IMPROVEMENT_BPS = 20` (hoje `_PPM = 25`, ou seja 0,25 bps): uma rota multi-perna so era aceite se
///  batesse a melhor perna unica por >= 20 bps. O comentario do proprio gate
///  diz para que serve — "kills micro-splits whose marginal output gain is
///  smaller than THE REAL GAS COST OF THE EXTRA LEGS".
///
///  Ou seja: os 20 bps eram um PROXY do ponto morto economico. Medido a
///  2026-08-21, com precos lidos ao vivo (Base 0,006 gwei, OP 0,001 gwei,
///  Arb 0,020 gwei; ETH a $3.300) e uma perna V3 extra a ~150.000 gas:
///
///      chain      custo da perna    ponto morto (trade de $1.000)
///      Base            $0,0030            0,030 bps
///      Optimism        $0,0005            0,005 bps
///      Arbitrum        $0,0099            0,099 bps
///
///  **O proxy estava 200x a 667x acima do que representava.** Um ganho de
///  10 bps — 333x acima do ponto morto da Base — era deitado fora.
///
///  PORQUE 5 E NAO 0: zero dividiria por um ganho de 1 wei, pagando ~150.000
///  gas por nada. 5 bps fica 50x a 1.010x acima do ponto morto das quatro
///  chains ("divide sempre que importa") e ainda recusa micro-splits.
///
/// ─────────────────────────────────────────────────────────────────────────
///  O EFEITO COLATERAL QUE IMPORTA MAIS QUE O PRECO
/// ─────────────────────────────────────────────────────────────────────────
///  O colapso para perna unica era a causa RAIZ de o registo nunca aquecer:
///  o Router so grava as pernas EXECUTADAS, o colapso fazia executar 1 por
///  hop, logo 1 pool por par — e `_registryFresh` exige 3. O portao que
///  saltaria a descoberta NUNCA disparava, e o caminho "quente" voltava a
///  sondar todas as factories. Mediu-se 14,8% de poupanca onde se esperavam
///  ~50%.
///
/// ─────────────────────────────────────────────────────────────────────────
///  A RESSALVA QUE NAO PODE SER ESQUECIDA: p_byte
/// ─────────────────────────────────────────────────────────────────────────
///  Uma perna extra acrescenta ~160 bytes de calldata. O custo desses bytes
///  NAO e o mesmo em todas as chains:
///
///      Base      p_byte      7,2  ->  ~$0,023
///      Arbitrum  p_byte     12,8  ->  ~$0,041
///      OP        p_byte     33,9  ->  ~$0,107
///      Scroll    p_byte 243.256   ->  ~$128,44  (!)
///
///  Nas quatro chains do deploy (p_byte <= 33,9) dividir compensa 5x a 20x.
///  **Numa chain dominada por dados nao compensa de todo.** O limiar correcto
///  e uma FUNCAO de p_byte, nao uma constante — e o `ChainProfile` ja existe
///  para a carregar. Enquanto isso nao existir, este ficheiro e a divida
///  escrita: qualquer chain nova com p_byte alto TEM de rever isto antes do
///  deploy.
contract SplitThresholdTest is Test {
    /// Replica a aritmetica exacta do gate no Solver (`_buildHop`).
    function _colapsa(uint256 totalOut, uint256 singleOut) internal pure returns (bool) {
        // LE A CONSTANTE DA PRODUCAO. A versao anterior recebia o limiar como
        // parametro e as chamadas passavam literais em BPS — quando a producao
        // ja usava PPM. As duas grandezas nem estavam na mesma unidade, e repor
        // 20 bps deixava este ficheiro verde.
        return totalOut < BPC.mulDiv(singleOut, 1_000_000 + MIN_SPLIT_IMPROVEMENT_PPM, 1_000_000);
    }

    /// @notice O NUCLEO. Um split que ganha 10 bps tem de sobreviver.
    ///         Com o limiar antigo (20) era deitado fora — 333x acima do
    ///         ponto morto da Base, e mesmo assim descartado.
    function test_SplitDe10BpsSobrevive() public pure {
        uint256 single = 1_000e18;
        uint256 split  = 1_001e18;                 // +10 bps = 1.000 ppm
        // O LIMIAR EM SI, lido da producao: se alguem repuser 20 bps (2.000 ppm)
        // este assert fica vermelho ANTES de o comportamento mudar, e diz porque.
        assertLt(MIN_SPLIT_IMPROVEMENT_PPM, 1_000,
            "um limiar >= 1.000 ppm mata um ganho de 10 bps: era esse o defeito");
        assertFalse(_colapsa(split, single), "+10 bps tem de sobreviver ao gate");
    }

    /// @notice Um split PIOR continua a colapsar. Sem isto, remover o limiar
    ///         teria removido tambem a proteccao, e o teste acima ficaria
    ///         verde com um gate que aceita tudo.
    function test_SplitPiorContinuaAColapsar() public pure {
        uint256 single = 1_000e18;
        uint256 pior   =   999e18;
        assertTrue(_colapsa(pior, single), "um split PIOR tem de colapsar sempre");
    }

    /// @notice Um ganho ABAIXO do limiar colapsa: 3 bps nao paga 5 bps.
    ///         E o controlo negativo — sem ele, "sobrevive a 10 bps" ficaria
    ///         verde com um gate que aceitasse tudo.
    function test_GanhoAbaixoDoLimiarColapsa() public pure {
        uint256 single = 1_000e18;
        // +1 ppm = 0,01 bps. A 25 ppm isto colapsa; a 3 ppm (o ponto morto real
        // medido na Base) tambem. Os +3 bps da versao anterior deste teste
        // SOBREVIVEM na producao actual — o teste seguia o limiar velho.
        uint256 tenue  = 1_000_001_000_000_000_000_000;  // +1 ppm
        assertTrue(_colapsa(tenue, single),
            "um ganho de 0,01 bps nao paga a calldata de uma perna extra");
    }

    /// @notice A CONTA DO PONTO MORTO, pinada. Se alguem reintroduzir um
    ///         limiar, tem de o justificar contra ISTO e nao contra intuicao.
    ///
    ///         CUIDADO COM A UNIDADE, e este teste ja apanhou o erro uma vez:
    ///         o `cast gas-price` da Base devolve **6.000.000 wei**, que sao
    ///         0,006 gwei — nao 6 gwei. A primeira versao deste teste escreveu
    ///         6e9 e deu um ponto morto 1.000x maior. O teste ficou vermelho e
    ///         o erro era da assercao, nao do codigo.
    ///
    ///         Base: 150.000 gas x 6.000.000 wei x $3.300/ETH = $0,00297/perna.
    ///         Num trade de $1.000 isso e 0,0297 bps.
    function test_PontoMortoDaBaseEmCentesimosDeBps() public pure {
        uint256 custoWei = 150_000 * 6_000_000;   // 9e11 wei = 9e-7 ETH
        // em bps de um trade de 1.000 USD, com ETH a 3.300 USD:
        //   custoUSD = custoWei/1e18 * 3300 ; bps = custoUSD/1000 * 10000
        uint256 bpsX10000 = (custoWei * 3300 * 10_000 * 10_000) / (1e18 * 1000);
        // 0,0297 bps  ->  297 em centesimos-de-milesimo
        assertLt(bpsX10000, 400, "o ponto morto da Base tem de ficar abaixo de 0,04 bps");
        assertGt(bpsX10000, 200, "e acima de 0,02 bps");
    }
}
