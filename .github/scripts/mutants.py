#!/usr/bin/env python3
"""Guarda de mutacao — prova que os guardas que ja existem TEM testes que os vigiam.

PORQUE ISTO EXISTE. Nesta base de codigo, DUAS vezes documentadas, um fix vivo ficou com testes
mortos: a suite passava na mesma com o fix REMOVIDO. O caso mais recente passou 5/5 com o portao
de cobertura arrancado — o revert que o teste apanhava vinha de OUTRA verificacao com o MESMO
codigo de erro. Um revert com o codigo certo nao prova que a verificacao certa disparou.

NAO E UMA FERRAMENTA DE MUTACAO GENERICA, de proposito. E uma lista FIXA e VERSIONADA de mutantes,
cada um emparelhado com o teste nomeado que TEM de o apanhar. Corre em segundos, nao precisa de
framework, e falha de forma legivel: diz que guarda ficou sem vigia.

O CONTRATO: aplicar o mutante -> o teste nomeado tem de ficar VERMELHO. Se ficar verde, o guarda
esta desprotegido e o CI para. Adicionar um guarda de seguranca ao protocolo implica adicionar a
sua linha aqui.
"""
import subprocess, sys, shutil, os, tempfile

M = [
 dict(nome="portao-de-cobertura: elevacao para a quote medida",
      f="src/BlazePhoenixRouter.sol",
      old="                if (bound < BPC.mulDiv(qs, MIN_QUOTE_COVERAGE_BPS, BPC.BPS)) bound = qs;",
      new="                qs; // MUTANTE",
      teste="test_BleedingLegHiddenInAHealthyTotalIsCaught"),
 dict(nome="portao-de-cobertura: o piso por perna",
      f="src/BlazePhoenixRouter.sol",
      old="            if (bound != 0 && got < BPC.mulDivUp(bound, BPC.LEG_FLOOR_BPS, BPC.BPS)) revert RouterE(5);",
      new="            bound; // MUTANTE",
      teste="test_BleedingLegHiddenInAHealthyTotalIsCaught"),
 dict(nome="FoT: a re-escala do piso pela medicao",
      f="src/BlazePhoenixRouter.sol",
      old="                    if (legNet < BPC.BPS) bound = BPC.mulDiv(bound, legNet, BPC.BPS);",
      new="                    legNet; // MUTANTE",
      teste="test_EntryTax25_OneLeg_MustSettle"),
 dict(nome="FoT: o fix-buraco (anular o piso em vez de o re-precar)",
      f="src/BlazePhoenixRouter.sol",
      old="""                if (fotAfter != fotBefore && bound != 0) {
                    uint256 legNet = fotBefore == 0
                        ? fotAfter
                        : BPC.mulDiv(fotAfter, BPC.BPS, fotBefore);
                    if (legNet < BPC.BPS) bound = BPC.mulDiv(bound, legNet, BPC.BPS);
                }""",
      new="                if (fotAfter != fotBefore) { bound = 0; } // MUTANTE",
      teste="test_FotIsNotAnExcuseToBleed"),
 dict(nome="theta: um bit da tabela de atributos",
      f="src/BlazePhoenixCore.sol",
      old="    uint256 internal constant THETA_ATTR = 0x040A9400A9;",
      new="    uint256 internal constant THETA_ATTR = 0x040A9400A8; // MUTANTE",
      teste="test_Parity_Reserves"),
 dict(nome="solidly: re-cegar os decimais na primitiva unica",
      f="src/BlazePhoenixCore.sol",
      old="        return outSolidlyStable(ain, rIn, rOut, liveFee, _decimalsOf(tokenIn), _decimalsOf(other));",
      new="        other; return outSolidlyStable(ain, rIn, rOut, liveFee, 0, 0); // MUTANTE",
      teste="test_FallbackPath_UnequalDecimals_MustStillSettle"),
 dict(nome="depthFromL: repor o L cru quando nao ha preco",
      f="src/BlazePhoenixCore.sol",
      old="    function depthFromL(uint128 liq, uint160 sp) internal pure returns (uint256) {\n        if (sp == 0) return 0;",
      new="    function depthFromL(uint128 liq, uint160 sp) internal pure returns (uint256) {\n        if (sp == 0) return uint256(liq); // MUTANTE",
      teste="test_NoPriceMeansNoDepth"),
 dict(nome="fee: a cobranca por hop (a fuga pelo prefixo de po)",
      f="src/BlazePhoenixRouter.sol",
      old="            amountIn = _chargeHopFee(hop, h, amountIn, foreignBase);",
      new="            foreignBase; // MUTANTE",
      teste="test_JUIZ_PrefixoSemValorEscapaAFee"),
 dict(nome="fee: so no hop 0 (a fuga que a ancora na entrada tinha)",
      f="src/BlazePhoenixRouter.sol",
      old="        uint256 feeH = BPC.mulDivUp(baseH, BPC.PROTOCOL_FEE_BPS, BPC.BPS);",
      new="        uint256 feeH = h == 0 ? BPC.mulDivUp(baseH, BPC.PROTOCOL_FEE_BPS, BPC.BPS) : 0; // MUTANTE",
      teste="test_JUIZ_PrefixoSemValorEscapaAFee"),
 dict(nome="fee: a baseline do sweep recalculada tarde (holds-nothing)",
      f="src/BlazePhoenixRouter.sol",
      old="        uint256 baseIn = tinStart > amountIn ? tinStart - amountIn : 0;",
      new="        uint256 baseIn = tinStart; // MUTANTE",
      teste="test_Refund_BestExactIn_ResidualGoesToPayer_NotRouter"),
 dict(nome="solver: a base da banda e a mediana PONDERADA (ponto de rutura 0 -> 50%)",
      f="src/BlazePhoenixSolver.sol",
      old="            if (acc >= metade) return r[i];",
      new="            if (acc >= metade) return r[m - 1]; // MUTANTE: um so sensor captura a base",
      teste="test_UmaPoolFundaNaoCapturaABanda"),
 dict(nome="solver: o peso do split vem da profundidade, nao do saldo (T2)",
      f="src/BlazePhoenixSolver.sol",
      old="            uint256 w = mx == 0 ? 1 : BPC.mulDiv(depth[i], 10_000, mx);",
      new="            uint256 w = mx == 0 ? 1 : BPC.mulDiv(bals[i], 10_000, mx); // MUTANTE",
      teste="test_DoacaoNaoCompraFatiaDoSplit"),
 dict(nome="router: a bijecao WETH nativa colapsada num produtor",
      f="src/BlazePhoenixCore.sol",
      old="        if (tokenOther == weth)  return (tokenIn, address(0));",
      new="        if (tokenOther == weth)  return (tokenIn, tokenOther); // MUTANTE",
      teste="test_LadoDoOutro"),
 dict(nome="router: eventos atribuidos ao pagador, nao ao msg.sender",
      f="src/BlazePhoenixRouter.sol",
      old="        emit ExecutionProof(payer, tokenOut, finalHopQuote, delivered, protocolFloorOut, block.number);",
      new="        emit ExecutionProof(msg.sender, tokenOut, finalHopQuote, delivered, protocolFloorOut, block.number); // MUTANTE",
      teste="test_SwapBest_EventosAtribuidosAoUtilizador"),
 dict(nome="quoter: a fee do preview compoe por hop",
      f="src/BlazePhoenixQuoter.sol",
      old="        afterFee -= BPC.mulDivUp(afterFee, BPC.PROTOCOL_FEE_BPS, BPC.BPS);",
      new="        afterFee -= 0; // MUTANTE",
      teste="test_DoisHops_PreviewBateComAEntrega"),
 dict(nome="solver: o filtro de hooks que alteram deltas",
      f="src/BlazePhoenixSolver.sol",
      old="            if (!BPC.hookAltersDeltas(reg[i].hooks)) { merged[n] = reg[i]; unchecked { ++n; } }",
      new="            { merged[n] = reg[i]; unchecked { ++n; } } // MUTANTE",
      teste="test_DeltaAlteringHookIsNeverRouted"),
 dict(nome="solver: a ordem canonica hookless-antes-de-hooked",
      f="src/BlazePhoenixSolver.sol",
      old="        _orderLegs(hop);",
      new="        // MUTANTE",
      teste="test_HooklessLegsComeFirst"),
 dict(nome="hub: a mascara de prova de par perde um kind vivo",
      f="src/BlazePhoenixHub.sol",
      old="        | (uint256(1) << BPC.KIND_SOLIDLY) | (uint256(1) << BPC.KIND_ALGEBRA);",
      new="        | (uint256(1) << BPC.KIND_SOLIDLY); // MUTANTE",
      teste="test_PairProofMaskMatchesTheta"),
 dict(nome="hub: o portao de kinds na SEGUNDA porta de registo",
      f="src/BlazePhoenixHub.sol",
      old="        if (((KINDS_EXECUTABLE >> kind) & 1) == 0) return;",
      new="        // MUTANTE",
      teste="test_RecordSwapRejectsExcisedKind"),
 # ── guardas da vaga de selagem 2026-08-31/09-01 ────────────────────────────
 # O CONTRATO deste ficheiro em accao: nove commits acrescentaram guardas e a
 # lista nao foi actualizada. Foi ele proprio que o apanhou, com tres ALVO
 # PERDIDO — os tres alvos que a selagem tinha movido de mulDiv para mulDivUp.
 dict(nome="balanceOf: uma leitura falhada volta a ser saldo zero",
      f="src/BlazePhoenixCore.sol",
      old='        require(ok, "BPC:balanceOf");',
      new="        ok; // MUTANTE",
      teste="test_FailedRead_IsReportedAsZeroBalance"),
 dict(nome="bridges: sem guarda de duplicados os dois produtores voltam a discordar",
      f="src/BlazePhoenixHub.sol",
      old="        if ($.isBridge[t]) return;",
      new="        // MUTANTE",
      teste="test_DupAddThenRemove_ArrayMappingDesync"),
 dict(nome="registo: creditar legs declaradas em vez das executadas (a leg fantasma)",
      f="src/BlazePhoenixRouter.sol",
      old="                if (!ran) { unchecked { ++l; } continue; }",
      new="                ran; // MUTANTE",
      teste="test_PhantomLeg_NotCreditedToRegistry"),
 dict(nome="V4: o grid volta a ser suprimido por um codigo aprendido",
      f="src/BlazePhoenixHub.sol",
      old="        if (kf >> 128 == kfBeforeOwnProbes) kf = _probeV4Batch(mgr, t0, t1, _v4GridTiers(), hits, kf);",
      new="        if (kf >> 128 == 0) kf = _probeV4Batch(mgr, t0, t1, _v4GridTiers(), hits, kf); // MUTANTE",
      teste="test_LearnedCode_DoesNotSuppressGridDiscovery"),
 dict(nome="kind: aceitar a declaracao da calldata contra a forma medida",
      f="src/BlazePhoenixHub.sol",
      old="            if (declaredConc != isConc) return;",
      new="            declaredConc; isConc; // MUTANTE",
      teste="test_ConcentratedPool_MustNotPersistAsV2"),
 dict(nome="kind: nao derivar a familia concentrada da forma da pool",
      f="src/BlazePhoenixHub.sol",
      old="            if (isConc) kind = dynShape ? BPC.KIND_ALGEBRA : BPC.KIND_V3;",
      new="            isConc; // MUTANTE",
      teste="test_AlgebraShapedPool_MustNotPersistAsV3"),
 # NOTA: a distincao media-vs-maximo NAO e alcancavel pela API do Solver — ele
 # escolhe sempre a melhor pool e nunca oferece uma leg destruidora, logo todas
 # as rotas deste par sao de UMA leg, onde media == maximo. O mutante abaixo
 # vigia o que E alcancavel: que o tecto continua ligado e a recusar.
 dict(nome="impacto: o tecto do Solver deixa de recusar (media ou maximo)",
      f="src/BlazePhoenixSolver.sol",
      old="        if (maxLegImpactBps >= MAX_ROUTE_IMPACT_BPS) return route;",
      new="        maxLegImpactBps; // MUTANTE",
      teste="test_ShallowPool_RouteIsRefused"),
 dict(nome="psi: bucketWeight deixa de dobrar, e a histerese desaparece em silencio",
      f="src/BlazePhoenixCore.sol",
      old="    function bucketWeight(uint8 b) internal pure returns (uint256) {\n        return uint256(1) << b;",
      new="    function bucketWeight(uint8 b) internal pure returns (uint256) {\n        return uint256(1) + b; // MUTANTE",
      teste="test_AdmissionMargin_IsNotRedundantWithQuantisation"),
]

def run(t):
    r = subprocess.run(["forge","test","--match-test",t],
                       capture_output=True, text=True,
                       env={**os.environ,"FOUNDRY_PROFILE":"release"})
    return r.returncode == 0, r.stdout + r.stderr

def main():
    falhas = []
    for i, m in enumerate(M, 1):
        src = open(m["f"]).read()
        if src.count(m["old"]) != 1:
            falhas.append(f"[{i}] {m['nome']}: o alvo do mutante nao existe (ou ha varios) em {m['f']}. "
                          f"O codigo mudou e esta lista nao foi atualizada.")
            print(f"  [{i}] ALVO PERDIDO  {m['nome']}"); continue
        bak = src
        try:
            open(m["f"],"w").write(src.replace(m["old"], m["new"]))
            ok, out = run(m["teste"])
            if ok:
                falhas.append(f"[{i}] {m['nome']}: o teste '{m['teste']}' PASSOU com o guarda mutado. "
                              f"O guarda esta sem vigia — o teste e decorativo.")
                print(f"  [{i}] DECORATIVO   {m['nome']}  ({m['teste']} passou mutado)")
            elif "No tests match" in out or "Compiler run failed" in out:
                falhas.append(f"[{i}] {m['nome']}: o teste '{m['teste']}' nao existe.")
                print(f"  [{i}] TESTE AUSENTE {m['nome']}")
            else:
                print(f"  [{i}] ok           {m['nome']}")
        finally:
            open(m["f"],"w").write(bak)
    print()
    if falhas:
        print("GUARDAS SEM VIGIA:"); [print("  -", f) for f in falhas]
        sys.exit(1)
    print(f"{len(M)}/{len(M)} guardas com teste que os apanha.")

if __name__ == "__main__":
    main()
