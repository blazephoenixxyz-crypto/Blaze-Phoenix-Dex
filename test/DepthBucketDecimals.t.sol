// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixCore as BPC} from "../src/BlazePhoenixCore.sol";

/// @notice RED-FIRST — `depthBucket` e cego a decimais, e isso desliga a defesa
///         que o proprio `_canInsert` diz existir.
///
/// ─────────────────────────────────────────────────────────────────────────
///  O DEFEITO
/// ─────────────────────────────────────────────────────────────────────────
///  `depthBucket(d)` devolve 0 para `d < 1e15` e depois `log10(d/1e15)`.
///  `d` vem de `depthFromL` (V3/V4) ou de `min(r0, r1)` (V2/Solidly) — sempre em
///  unidades CRUAS do token do lado curto. Traduzido para valor economico, o
///  limiar de saida do bucket 0 depende dos decimais desse token:
///
///      18 decimais (WETH)  ->  sai do bucket 0 com ~$3
///       6 decimais (USDC)  ->  so sai do bucket 0 com $1.000.000.000
///       8 decimais (WBTC)  ->  so sai do bucket 0 com $650.000.000.000
///
///  Ou seja: TODAS as pools de qualquer par cujo lado curto tenha 6 ou 8
///  decimais caem no bucket 0. A de mil milhoes e a de po ficam com o MESMO
///  peso (`bucketWeight(0) = 1`).
///
///  Medido em fork da Base, bloco 49.800.000 (test/fork/MetricsSweep.t.sol):
///  as duas pools USDC/WETH registadas sairam com `depthBucket = 0`, enquanto
///  a WETH/LINK — 3.481x mais rasa em dolares — saiu com bucket 5, peso 32.
///
/// ─────────────────────────────────────────────────────────────────────────
///  PORQUE IMPORTA (e o alcance exacto, sem exagero)
/// ─────────────────────────────────────────────────────────────────────────
///  `_canInsert` compara sempre candidatos DO MESMO PAR, logo o enviesamento
///  NAO inverte rankings entre pares diferentes — nisso cancela-se. O dano e
///  outro: dentro de um par de 6/8 decimais o sinal de profundidade COLAPSA
///  num unico bucket, e `psi = vitality x bucketWeight x bonus` degenera em
///  `psi = vitality x 1 x bonus`.
///
///  E a defesa por profundidade e exactamente o que o comentario do
///  `_canInsert` (Hub:1356-1360) diz ter sido acrescentado para impedir:
///
///    "an attacker can no longer keep a deep pool out merely by sending dust
///     through 16 shallow slots to hold their vitality at 1"
///
///  Com todos no bucket 0 essa defesa fica INERTE e sobra precisamente a
///  vitality que ela vinha corrigir. A prosa promete uma defesa que a
///  aritmetica nao entrega — para USDC, USDT e WBTC, que sao a liquidez mais
///  funda que existe.
contract DepthBucketDecimalsTest is Test {
    // ── Numeros REAIS, lidos da Base no bloco 49.800.000 ──
    // Pool 0x6c561B446416E1A00E8E93E221854d6eA4171372 (USDC/WETH, fee 3000):
    //   L = 33015326848947965378, sqrtPriceX96 = 3427971880739905985761831
    //   -> lado curto = USDC, 1.428.477.052.604.300 unidades cruas = $1,43 mil milhoes
    uint256 constant DEPTH_USDC_1_43B = 1_428_477_052_604_300;

    // Pool 0x224a5D3f2155f2F85Af70B6D72AEa61a15273ff4 (WETH/LINK, fee 3000):
    //   -> lado curto = WETH, 124.352.476.817.360.547.536 cruas = ~$410 mil
    uint256 constant DEPTH_WETH_410K = 124_352_476_817_360_547_536;

    // Uma pool de po: 100 USDC.
    uint256 constant DEPTH_USDC_100 = 100e6;

    // Reservas virtuais REAIS da pool 0x6c561B44 (USDC/WETH 3000) na Base,
    // bloco 49.800.000. Na Base o WETH (0x42..) ordena antes do USDC (0x83..),
    // logo token0 = WETH (18 casas) e token1 = USDC (6 casas).
    uint256 constant X0_WETH = 763_058_674_940_300_981_077_863; // ~763.059 WETH
    uint256 constant X1_USDC = 1_428_477_052_604_300;           // ~1.428.477.053 USDC

    // A mesma pool com po: 1 WETH de um lado, 100 USDC do outro.
    uint256 constant PO_WETH = 1e18;
    uint256 constant PO_USDC = 100e6;

    /// @notice O NUCLEO. O pipeline que alimenta o bucket tem de distinguir
    ///         1.400 milhoes de 100 dolares.
    ///
    /// @dev PORQUE ESTE TESTE MUDOU DE ALVO. A primeira versao chamava
    ///      `depthBucket(valorCru)` directamente e ficava vermelha para sempre:
    ///      o `depthBucket` recebe um numero e nao sabe de que token e, portanto
    ///      NAO E ELE que pode ser corrigido. O fix vive a montante — em
    ///      `shortSide18`, que normaliza os dois lados ANTES de escolher o curto.
    ///      Um teste que aponta para a costura errada fica vermelho mesmo com o
    ///      defeito corrigido, e isso e um teste decorativo ao contrario.
    function test_PipelineDistingueMilMilhoesDePo() public pure {
        uint256 dFunda = BPC.shortSide18(X0_WETH, 18, X1_USDC, 6);
        uint256 dPo    = BPC.shortSide18(PO_WETH, 18, PO_USDC, 6);
        assertGt(
            BPC.bucketWeight(BPC.depthBucket(dFunda)),
            BPC.bucketWeight(BPC.depthBucket(dPo)),
            "pool de $1,43B e pool de $100 continuam com o mesmo peso"
        );
    }

    /// @notice A defesa anti-po do `_canInsert` tem de morder: o recem-chegado
    ///         fundo tem de bater a margem de 25% sobre o pior incumbente.
    function test_DefesaAntiPoDoCanInsertMorde() public pure {
        uint256 worstPsi = BPC.bucketWeight(BPC.depthBucket(
            BPC.shortSide18(PO_WETH, 18, PO_USDC, 6)));
        uint256 novoPsi = BPC.bucketWeight(BPC.depthBucket(
            BPC.shortSide18(X0_WETH, 18, X1_USDC, 6)));
        assertTrue(
            novoPsi > worstPsi + (worstPsi / 4),
            "a pool de $1,43B nao desloca 16 pools de po - defesa inerte"
        );
    }

    /// @notice O `min` tambem estava enviesado: escolhia o lado com menos
    ///         UNIDADES, nao o economicamente mais raso. Aqui o lado curto real
    ///         e o USDC ($1,43B contra $2,52B de WETH) e tem de continuar a
    ///         ser escolhido DEPOIS da normalizacao — por profundidade, nao por
    ///         acidente de decimais.
    function test_LadoCurtoEscolhidoPorProfundidadeNaoPorDecimais() public pure {
        uint256 d = BPC.shortSide18(X0_WETH, 18, X1_USDC, 6);
        // USDC normalizado = 1,428e15 x 1e12 = 1,428e27; WETH = 7,63e23.
        // O lado curto normalizado e o WETH.
        assertEq(d, BPC.to18(X0_WETH, 18), "o lado curto normalizado devia ser o WETH");
        // E cru, o `min` teria escolhido o USDC — pelos decimais, nao pela profundidade.
        assertLt(X1_USDC, X0_WETH, "cru, o USDC ganha o min por ter menos casas");
    }

    /// @notice O `depthBucket` continua cego a decimais, DE PROPOSITO: ele recebe
    ///         um escalar e nao sabe de que token e. Este teste pina isso para
    ///         que ninguem tente "corrigir" o depthBucket e crie um segundo
    ///         produtor da normalizacao ao lado da `shortSide18`.
    function test_DepthBucketContinuaCegoDePropositoENaoDeveSerCorrigido() public pure {
        assertEq(BPC.depthBucket(410_000_000_000), 0, "410k USDC cru cai no bucket 0");
        assertGt(BPC.depthBucket(124_352_476_817_360_547_536), 0, "o mesmo valor em WETH nao");
    }

    /// @notice Documenta o eixo do defeito sem o julgar: para o MESMO valor
    ///         economico, o bucket muda so por causa dos decimais.
    ///         Este passa hoje e continua a passar depois do fix — existe para
    ///         que o proximo a ler saiba que a assimetria e por decimais e nao
    ///         por profundidade.
    function test_MesmoValorDecimaisDiferentesDaBucketsDiferentes() public pure {
        // ~$410 mil, os dois lados
        uint256 em18dec = 124_352_476_817_360_547_536; // ~124 WETH
        uint256 em6dec  = 410_000_000_000;             // 410.000 USDC
        assertEq(BPC.depthBucket(em6dec), 0, "410k USDC cai no bucket 0");
        assertGt(BPC.depthBucket(em18dec), 0, "o mesmo valor em WETH nao cai");
    }

    /// @notice O WBTC e o caso extremo: 8 decimais tornam o bucket 0 inescapavel
    ///         a qualquer escala que exista no mundo real.
    function test_WbtcNuncaSaiDoBucketZero() public pure {
        uint256 milBitcoins = 1_000 * 1e8; // 1.000 BTC, ~$65 milhoes
        assertEq(
            BPC.depthBucket(milBitcoins), 0,
            "1.000 BTC deviam sair do bucket 0 - com 8 decimais nao saem"
        );
    }
}
