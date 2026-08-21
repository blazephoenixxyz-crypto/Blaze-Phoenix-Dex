// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// DEPTH-01 — `depthWad` tem de ser token-denominado em TODOS os produtores, não em três de quatro.
//
// O PROBLEMA DE UNIDADES. O Hub compara profundidades ENTRE famílias de venue: `_canInsert` exige
// que um recém-chegado bata o incumbente mais fraco por 25%, e `tickSlot` grava o bucket de
// profundidade nos bits [63:60] do Monoslot, que alimenta o ψ de fitness que o Solver lê para
// escolher candidatos. O V2 reporta `min(r0, r1)` — unidades lineares de token. O V3/V4 reportam
// L, que está em escala RAIZ. Entregar L cru infla a profundidade por `max(sqrtP, 1/sqrtP)`, que
// é ≥ 1 SEMPRE — nunca subestima, só sobrestima, e sobrestima em cada par cujo preço bruto (já
// incluindo o desalinhamento de decimais) esteja longe de 1.
//
// OS QUATRO PRODUTORES. A conversão existia inline em três — `universalQuote` ramo V3,
// `universalQuote` ramo V4, `Hub.claimV4` — e faltava por completo no quarto, `Router._recordHits`,
// que corre em TODOS os swaps executados. Pior do que uma omissão: `recordSwap` chama `tickSlot`,
// que REESCREVE o bucket em cada swap, portanto o fix do `claimV4` (já em produção) era desfeito
// no primeiro swap roteado por essa pool.
//
// A RESPOSTA. Uma única primitiva, `BPC.depthFromL`, e os quatro sítios a chamá-la. Três cópias
// irmãs que divergem são a assinatura de defeito desta base de código — foi assim com o mulDiv de
// 512 bits e com a fee viva do Algebra. Uma cópia não pode divergir de si própria.
//
// O red-first estrutural desta correção é a guarda estática no CI ("Depth unit guard"): ela falha
// no código antigo (apanha Router:1518 e Router:1520) e passa no novo. Este ficheiro cobre a outra
// metade — que a primitiva calcula a coisa certa e que a diferença NÃO é cosmética.

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixCore as BPC} from "../src/BlazePhoenixCore.sol";

contract DepthUnitParityTest is Test {
    uint160 constant Q96 = uint160(uint256(1) << 96);

    /// sqrtPriceX96 para um preço bruto `p` (token1 por token0), via sqrt inteira.
    function _sqrtPx96(uint256 p) internal pure returns (uint160) {
        uint256 r = _sqrt(p) * (uint256(1) << 96);
        return uint160(r);
    }

    function _sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2; y = x;
        while (z < y) { y = z; z = (x / z + z) / 2; }
    }

    /// A propriedade que dá nome ao defeito: L cru NUNCA subestima, e a preços longe de 1
    /// sobrestima o suficiente para saltar buckets — logo altera `_canInsert` e o ψ do Solver.
    function test_RawLiquidityOverstatesDepthAwayFromPriceOne() public pure {
        uint128 liq = 1e24;

        // Par tipo USDC(6)/WETH(18): o preço BRUTO carrega o desalinhamento de decimais.
        uint160 sp = _sqrtPx96(1e8);
        uint256 tokenDepth = BPC.depthFromL(liq, sp);
        uint256 rawDepth   = uint256(liq);

        assertLt(tokenDepth, rawDepth, "L cru tem de sobrestimar a preco longe de 1");

        // E a diferenca nao e cosmetica: salta buckets, que e a unidade em que o Hub decide.
        uint8 bTok = BPC.depthBucket(tokenDepth);
        uint8 bRaw = BPC.depthBucket(rawDepth);
        assertGt(bRaw, bTok, "o bucket gravado no Monoslot muda - nao e arredondamento");
    }

    /// A preco 1 as duas leituras coincidem: a conversao nao introduz vies onde nao havia.
    function test_AtPriceOneTokenDepthEqualsRawLiquidity() public pure {
        uint128 liq = 1e24;
        assertApproxEqRel(BPC.depthFromL(liq, Q96), uint256(liq), 1e12, "a preco 1 tem de coincidir");
    }

    /// Simetria: a profundidade e o LADO CURTO, logo inverter o preco da o mesmo numero.
    /// E o que torna a medida comparavel independentemente de qual token e o token0.
    function test_DepthIsSymmetricUnderPriceInversion() public pure {
        uint128 liq = 1e24;
        uint256 high = BPC.depthFromL(liq, _sqrtPx96(1e8));            // preco 1e8
        // preco 1e-8  =>  sqrtP = Q96 / 1e4
        uint256 low  = BPC.depthFromL(liq, uint160(uint256(Q96) / 1e4));
        assertApproxEqRel(high, low, 1e15, "o lado curto tem de ser simetrico na inversao do preco");
    }

    /// MUDANCA DELIBERADA DE COMPORTAMENTO (2026-08-21). Este teste pinava o oposto: afirmava
    /// que `sp == 0` devolvia L cru "exatamente como o ramo else que existia inline antes da
    /// primitiva". Preservar o comportamento anterior era o objetivo certo para a EXTRACAO — e
    /// o errado para a primitiva, porque o comportamento anterior era o proprio bug.
    ///
    /// L esta em escala-RAIZ. Devolve-lo cru quando o preco nao e legivel entrega um numero
    /// NOUTRAS UNIDADES, que e exatamente o defeito que esta funcao existe para eliminar — o
    /// ramo de fallback reintroduzia-o dentro da cura. A regra: a AUSENCIA de medicao nao e um
    /// valor. Zero e a unica resposta honesta.
    ///
    /// E SEGURO porque os consumidores tratam o zero: o `_weights` do Solver normaliza contra o
    /// maximo da familia e da peso minimo a uma profundidade nula, sem divisao por zero. A pool
    /// perde prioridade em vez de envenenar a comparacao — falha SUAVE, na direcao certa.
    function test_NoPriceMeansNoDepth() public pure {
        assertEq(BPC.depthFromL(12345e18, 0), 0, "sem preco tem de devolver zero, nao L cru");
        assertEq(BPC.depthFromL(type(uint128).max, 0), 0, "idem no extremo");
        assertEq(BPC.depthFromL(0, 0), 0, "zero com zero continua zero");
    }

    /// Sem overflow no intermedio: L * sqrtP transborda uint256, e por isso a primitiva usa
    /// mulDiv de 512 bits. Com L no maximo e um preco alto isto reverteria se fosse mul cru.
    function test_NoOverflowAtExtremes() public pure {
        uint128 liq = type(uint128).max;
        uint256 d = BPC.depthFromL(liq, _sqrtPx96(1e12));
        assertGt(d, 0, "o intermedio de 512 bits tem de aguentar os extremos");
        assertLt(d, uint256(liq), "e continuar a ser o lado curto");
    }
}
