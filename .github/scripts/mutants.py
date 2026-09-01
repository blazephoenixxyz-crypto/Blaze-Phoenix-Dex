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
 # ── pontos cegos apanhados a auditar a propria guarda (2026-09-01) ─────────
 # Os 27 cobriam a leg fantasma, o grid V4, o kind derivado, o desync das
 # bridges e o balanceOf. NAO cobriam os fixes de ARITMETICA da mesma vaga: o
 # sentido do arredondamento da fee, o sentinela da curva estavel, os dois
 # clamps do preview e a ponderacao do impacto. Um teste que corrige um bug
 # sem mutante a apontar-lhe nao esta provado a apanhar a regressao que existe
 # para impedir.
 dict(nome="fee: o arredondamento volta a ser para BAIXO (a fee que desaparece no po)",
      f="src/BlazePhoenixRouter.sol",
      old="        uint256 feeH = BPC.mulDivUp(baseH, BPC.PROTOCOL_FEE_BPS, BPC.BPS);",
      new="        uint256 feeH = BPC.mulDiv(baseH, BPC.PROTOCOL_FEE_BPS, BPC.BPS); // MUTANTE",
      teste="test_DustSwap_PaysAProtocolFee"),
 dict(nome="solidly: o sentinela volta a vigiar as reservas em vez do resultado",
      f="src/BlazePhoenixCore.sol",
      old="        if (!_solKFits(X + A, Y)) return 0;",
      new="        // MUTANTE",
      teste="test_ReservesInsideTheWindow_MustNotRevert"),
 dict(nome="quoter: a leg Solidly volta a re-escalar em vez de medir na pool",
      f="src/BlazePhoenixQuoter.sol",
      old="                    (legOut, ) = BPC.universalQuote(sc, legIn);",
      new="                    legOut = BPC.mulDiv(leg.expectedOut, legIn, base); // MUTANTE",
      teste="test_RED_SolidlyLeg_UpscaledQuoteExceedsPoolTruth"),
 dict(nome="quoter: o clamp do fallback concentrado extrapola outra vez pela tangente",
      f="src/BlazePhoenixQuoter.sol",
      old="                    // may keep the plan's own claim, never exceed it.\n                    if (legOut == 0)\n                        legOut = BPC.mulDiv(\n                            leg.expectedOut, legIn > base ? base : legIn, base);",
      new="                    // may keep the plan's own claim, never exceed it.\n                    if (legOut == 0)\n                        legOut = BPC.mulDiv(leg.expectedOut, legIn, base); // MUTANTE",
      teste="test_RED_ConcFallback_NeverScalesAbovePlan"),
 dict(nome="quoter: o clamp do fallback V4 extrapola outra vez pela tangente",
      f="src/BlazePhoenixQuoter.sol",
      old="                    // plan's point upward along the tangent.\n                    if (legOut == 0)\n                        legOut = BPC.mulDiv(\n                            leg.expectedOut, legIn > base ? base : legIn, base);",
      new="                    // plan's point upward along the tangent.\n                    if (legOut == 0)\n                        legOut = BPC.mulDiv(leg.expectedOut, legIn, base); // MUTANTE",
      teste="test_RED_V4Fallback_NeverScalesAbovePlan"),
 dict(nome="impacto: o termo deixa de ser ponderado pelo tamanho da leg (o po volta a votar)",
      f="src/BlazePhoenixRouter.sol",
      old="        return BPC.mulDiv(imp * legs, legAmountIn, scaleDen);",
      new="        return imp; // MUTANTE",
      teste="test_DustPadding_MustNotCollapseTheFloor"),
 dict(nome="callback: a porta de autenticacao v3 aceita quem nao e a pool esperada",
      f="src/BlazePhoenixRouter.sol",
      old="        if (msg.sender != expected || expected == address(0)) revert RouterE(6);",
      new="        if (expected == address(0)) revert RouterE(6); // MUTANTE",
      teste="test_ImpostorCallingTheCallbackMidSwapIsNeverPaid"),
 dict(nome="callback: o unlockCallback V4 aceita quem nao e o PoolManager",
      f="src/BlazePhoenixRouter.sol",
      old="        if (msg.sender != mgr) revert RouterE(6);",
      new="        mgr; // MUTANTE",
      teste="test_UnlockCallback_RevertsWhenNotV4Manager"),
 dict(nome="renounce: o Router volta a poder ossificar pausado (estado terminal)",
      f="src/BlazePhoenixRouter.sol",
      old="        if (paused) revert RouterE(2);\n        controlRenounced = true;",
      new="        controlRenounced = true; // MUTANTE",
      teste="test_Composition_PauseThenRenounce_IsRefused"),
 dict(nome="renounce: o Hub volta a poder ossificar pausado (registo surdo p/ sempre)",
      f="src/BlazePhoenixHub.sol",
      old="        if (_store().paused) revert HubE(2);\n        _store().controlRenounced = true;",
      new="        _store().controlRenounced = true; // MUTANTE",
      teste="test_Composition_HubPauseThenRenounce_IsRefused"),
 # ── operadores ausentes: relacional, &&/||, codigo de erro (2026-09-01) ───
 # A auditoria da PROPRIA lista encontrou a distribuicao coxa: ~14 mutantes de
 # delecao e ZERO de substituicao relacional, ZERO de troca de conector logico,
 # ZERO de troca de codigo de erro — ironico, porque o cabecalho deste ficheiro
 # nomeia "revert com o codigo certo da verificacao errada" como a assinatura
 # da casa. Tambem sem vigia: os guardas de entrada (deadline, minOut==0), o
 # whenLive das portas, e a APLICACAO do piso final (os mutantes existentes
 # vigiavam como o piso e CONSTRUIDO, nenhum vigiava a comparacao que o aplica).
 # Cada entrada abaixo foi verificada a matar o seu teste no box a 2026-09-01.
 dict(nome="piso aplicado: < vira <= na comparacao final delivered/userMinOut",
      f="src/BlazePhoenixRouter.sol",
      old="        if (delivered < userMinOut) revert RouterE(5);",
      new="        if (delivered <= userMinOut) revert RouterE(5); // MUTANTE",
      teste="test_MinOut_Boundary_ExactNetDelivers"),
 dict(nome="piso aplicado: um wei de folga na comparacao final",
      f="src/BlazePhoenixRouter.sol",
      old="        if (delivered < userMinOut) revert RouterE(5);",
      new="        if (delivered + 1 < userMinOut) revert RouterE(5); // MUTANTE",
      teste="test_MinOut_DeliveredShortfallIsRefused"),
 dict(nome="deadline: > vira >= na porta classica (a fronteira do prazo)",
      f="src/BlazePhoenixRouter.sol",
      old="""        if (block.timestamp > deadline) revert RouterE(4);
        if (route.hops.length == 0 || amountIn == 0) revert RouterE(3);
        address tokenIn  = route.hops[0].tokenIn;""",
      new="""        if (block.timestamp >= deadline) revert RouterE(4); // MUTANTE
        if (route.hops.length == 0 || amountIn == 0) revert RouterE(3);
        address tokenIn  = route.hops[0].tokenIn;""",
      teste="test_Deadline_ExpiredRefusedAndBoundaryHolds"),
 dict(nome="fee-no-output: >= vira > (a fee que consome o output inteiro passa)",
      f="src/BlazePhoenixRouter.sol",
      old="                if (fOut >= amountOut) revert RouterE(8);",
      new="                if (fOut > amountOut) revert RouterE(8); // MUTANTE",
      teste="test_FeeOnOut_OneWeiOutputWhollyConsumedIsRefused"),
 dict(nome="orcamento por hop: a folga atestada dobra (limite estrito vira frouxo)",
      f="src/BlazePhoenixRouter.sol",
      old="                if (hopGot + slack < hopAttested) revert RouterE(5);",
      new="                if (hopGot + slack + slack < hopAttested) revert RouterE(5); // MUTANTE",
      teste="test_TwoBleedingLegs_RevertOnHopBudget"),
 dict(nome="entrada: && vira || no guarda de minOut zero (a condicao inverte o alcance)",
      f="src/BlazePhoenixRouter.sol",
      old="""        if (amountIn > 0 && userMinOut == 0) revert RouterE(10);
        return _swap(route, amountIn, userMinOut, recipient, deadline);""",
      new="""        if (amountIn > 0 || userMinOut == 0) revert RouterE(10); // MUTANTE
        return _swap(route, amountIn, userMinOut, recipient, deadline);""",
      teste="test_INV6_zeroAmountIsNotTreatedAsAZeroMinOutSwap"),
 dict(nome="callback v3: || vira && na autenticacao (impostor com expected vivo passa)",
      f="src/BlazePhoenixRouter.sol",
      old="        if (msg.sender != expected || expected == address(0)) revert RouterE(6);",
      new="        if (msg.sender != expected && expected == address(0)) revert RouterE(6); // MUTANTE",
      teste="test_ImpostorCallingTheCallbackMidSwapIsNeverPaid"),
 dict(nome="onlyControl: || vira && (um estranho passa enquanto nao houver renounce)",
      f="src/BlazePhoenixRouter.sol",
      old="    modifier onlyControl() { if (msg.sender != admin || controlRenounced) revert RouterE(1); _; }",
      new="    modifier onlyControl() { if (msg.sender != admin && controlRenounced) revert RouterE(1); _; } // MUTANTE",
      teste="test_Control_EveryControlDoorRefusesAStranger"),
 dict(nome="codigo de erro: fee-consome-output troca 8 por 5 (o selector e a unica testemunha)",
      f="src/BlazePhoenixRouter.sol",
      old="                if (fOut >= amountOut) revert RouterE(8);",
      new="                if (fOut >= amountOut) revert RouterE(5); // MUTANTE",
      teste="test_FeeOnOut_OneWeiOutputWhollyConsumedIsRefused"),
 dict(nome="codigo de erro: minOut zero troca 10 por 3",
      f="src/BlazePhoenixRouter.sol",
      old="""        if (amountIn > 0 && userMinOut == 0) revert RouterE(10);
        return _swap(route, amountIn, userMinOut, recipient, deadline);""",
      new="""        if (amountIn > 0 && userMinOut == 0) revert RouterE(3); // MUTANTE
        return _swap(route, amountIn, userMinOut, recipient, deadline);""",
      teste="test_INV6_swapExactIn_rejectsZeroMinOut"),
 dict(nome="whenLive: o modificador cai da porta classica (pausado deixa de travar)",
      f="src/BlazePhoenixRouter.sol",
      old="""    function swapExactIn(
        Route calldata route, uint256 amountIn, uint256 userMinOut,
        address recipient, uint256 deadline
    ) external whenLive nrEntrant returns (uint256) {""",
      new="""    function swapExactIn(
        Route calldata route, uint256 amountIn, uint256 userMinOut,
        address recipient, uint256 deadline
    ) external nrEntrant returns (uint256) { // MUTANTE""",
      teste="test_SetPaused_BlocksSwaps"),
 dict(nome="fee-no-output: mulDivUp vira mulDiv (a fee de 1 wei desaparece no po)",
      f="src/BlazePhoenixRouter.sol",
      old="            uint256 fOut = BPC.mulDivUp(amountOut, BPC.PROTOCOL_FEE_BPS, BPC.BPS);",
      new="            uint256 fOut = BPC.mulDiv(amountOut, BPC.PROTOCOL_FEE_BPS, BPC.BPS); // MUTANTE",
      teste="test_FeeOnOut_OneWeiOutputWhollyConsumedIsRefused"),
 dict(nome="constante: MAX_LEGS_PER_HOP empurrada de 5 para 4 (a fronteira, nao a remocao)",
      f="src/BlazePhoenixRouter.sol",
      old="    uint8   internal constant MAX_LEGS_PER_HOP  = 5;",
      new="    uint8   internal constant MAX_LEGS_PER_HOP  = 4; // MUTANTE",
      teste="test_G8_FiveLegs_BoundaryPasses"),
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
