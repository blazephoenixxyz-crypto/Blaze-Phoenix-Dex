// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test, console2} from "forge-std/Test.sol";
import {BlazePhoenixQuoter} from "../src/BlazePhoenixQuoter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";

/// @notice A MARGEM DE ERRO DA COTACAO TEM DE ENTRAR NO BUFFER — e ate hoje nao
///         entrava.
///
/// O `safety(n)` do Quoter conta PERNAS e ignora COMO cada uma foi cotada:
///     sBps = (legs - 2) x 1 bps, cap 10
/// Trata igual uma perna que PERGUNTOU ao pool (Solidly `getAmountOut`, V4
/// `extsload`, V3 `fee()` + slot0 — erro de modelo ~0) e uma perna V2 cuja fee
/// foi ASSUMIDA. E a fee de um par V2 nao e uma escolha de desenho: MEDIDO
/// 2026-08-25 na Base, os quatro pares USDC/WETH dos venues V2 cablados
/// (UniV2 0x88a43bbd, PancakeV2 0x79474223, SushiV2 0x2f8818d1, BaseSwap
/// 0xab067c01) respondem a NENHUM de `swapFee()`, `fee()`, `feeRate()`. Nao ha
/// a quem perguntar; o default e inevitavel, e por isso a incerteza dele e
/// real e tem de ser publicada.
///
/// A DIRECCAO DO ERRO decide se isto e um buffer ou um piso:
///   · assumido 30, real 25 (Pancake) -> SUB-cota -> conservador, inofensivo.
///   · assumido 30, real > 30         -> SOBRE-cota -> promete mais do que a
///     execucao entrega -> `delivered < effectiveMinOut` -> revert.
/// So o segundo caso magoa, e magoa como FALSO REJEITO (fail-closed), nunca
/// como mau fill: o piso de ferro e a revert da execucao ja cobrem o valor. O
/// buffer nao existe para tapar o pior caso (isso e trabalho do piso) — existe
/// para o `netOut` PUBLICADO deixar de mentir por omissao sobre uma perna
/// cotada por assuncao.
///
/// O SINAL NAO E RE-DERIVADO. A pergunta "esta fee foi assumida?" e feita ao
/// PRODUTOR UNICO — `BPC.effV2Fee(leg.fee) != leg.fee` significa "o produtor
/// substituiu". Zero campos novos no `Leg`, zero bytes de ABI, e a doutrina do
/// produtor unico mantem-se: a alternativa (reimplementar `== 0 || > tecto` no
/// Quoter) e exactamente o defeito que a `CoreV2QuoteParity` e o `_gateCtx`
/// custaram hoje.
///
/// forge test --match-contract QuoterAssumedFeeMargin -vv
contract QuoterAssumedFeeMarginTest is Test {
    BlazePhoenixQuoter quoter;

    function setUp() public {
        // `previewRoute` e pure: o hub/solver nunca sao tocados por estes testes.
        quoter = new BlazePhoenixQuoter(address(0x1111), address(0x2222));
    }

    /// Uma rota de UMA perna V2, parametrizada so pela fee declarada.
    function _rota(uint24 fee, uint8 kind) internal pure returns (Route memory r) {
        Leg[] memory ls = new Leg[](1);
        ls[0] = Leg({
            pool: address(0xBEEF), hooks: address(0), kind: kind, fee: fee,
            tickSpacing: 0, zeroForOne: true, stable: false,
            amountIn: 1_000e18, expectedOut: 1_000e18, auxId: bytes32(0)
        });
        Hop[] memory hs = new Hop[](1);
        hs[0] = Hop({
            tokenIn: address(0xA), tokenOut: address(0xB),
            amountIn: 1_000e18, expectedOut: 1_000e18, legs: ls
        });
        r.hops = hs;
        r.totalOut = 1_000e18;
        r.singleOut = 1_000e18;
    }

    /// O NUCLEO: a mesma rota, o mesmo output bruto, a mesma contagem de pernas
    /// — muda so a BASE EPISTEMICA da fee. O buffer tem de as distinguir.
    function test_FeeAssumidaPagaMargemQueFeeDeclaradaNaoPaga() public view {
        BlazePhoenixQuoter.Preview memory declarada =
            quoter.previewRoute(_rota(30, BPC.KIND_V2), 0);   // 30 bps DECLARADO: passa intacto
        BlazePhoenixQuoter.Preview memory assumida =
            quoter.previewRoute(_rota(0,  BPC.KIND_V2), 0);   // 0 -> o produtor substitui: ASSUMIDO

        console2.log("buffer declarada / assumida:", declarada.safetyBuffer, assumida.safetyBuffer);
        console2.log("netOut declarada / assumida:", declarada.netOut, assumida.netOut);

        assertGt(assumida.safetyBuffer, declarada.safetyBuffer,
            "uma perna cotada por ASSUNCAO tem de pagar margem que uma cotada por declaracao nao paga");
        assertLt(assumida.netOut, declarada.netOut,
            "a margem tem de sair do netOut PUBLICADO, senao nao muda nada para quem le");
    }

    /// A fee adversarial (acima do tecto) tambem cai no default, logo tambem e
    /// uma assuncao — e tem de pagar a mesma margem. Sem isto, o caller que
    /// declara 99% obtinha o quote do default SEM o aviso de incerteza.
    function test_FeeAdversarialTambemEhAssuncao() public view {
        BlazePhoenixQuoter.Preview memory adversarial =
            quoter.previewRoute(_rota(9_900, BPC.KIND_V2), 0);
        BlazePhoenixQuoter.Preview memory assumida =
            quoter.previewRoute(_rota(0, BPC.KIND_V2), 0);

        assertEq(adversarial.safetyBuffer, assumida.safetyBuffer,
            "uma fee acima do tecto e uma assuncao como qualquer outra");
    }

    /// A FRONTEIRA DA FAMILIA: uma perna que PERGUNTOU ao pool nao paga margem
    /// nenhuma, mesmo com `fee` a zero — no Solidly o zero nao e sentinela de
    /// assuncao, o quote vem do `getAmountOut` do proprio pool. Aplicar a
    /// margem aqui seria penalizar a familia MAIS exacta que temos.
    function test_SolidlyNaoPagaMargem_PerguntaAoPool() public view {
        BlazePhoenixQuoter.Preview memory solidly =
            quoter.previewRoute(_rota(0, BPC.KIND_SOLIDLY), 0);
        BlazePhoenixQuoter.Preview memory v2 =
            quoter.previewRoute(_rota(0, BPC.KIND_V2), 0);

        assertLt(solidly.safetyBuffer, v2.safetyBuffer,
            "Solidly pergunta ao pool: nao ha assuncao a cobrar");
    }

    /// O buffer nunca pode passar o tecto, por muitas pernas assumidas que a
    /// rota tenha — um buffer sem tecto vira um piso, e o piso ja existe.
    function test_BufferRespeitaOTecto() public view {
        BlazePhoenixQuoter.Preview memory pv = quoter.previewRoute(_rota(0, BPC.KIND_V2), 0);
        assertLe(pv.safetyBuffer * BPC.BPS / pv.grossOut, 10,
            "o buffer tem de continuar limitado pelo SAFETY_CAP_BPS");
    }
}
