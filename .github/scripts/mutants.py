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
import re, subprocess, sys, shutil, os, tempfile, json, hashlib

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
 # ── as duas fronteiras exatas antes REJEITADAS (2026-09-01) ────────────────
 # Os dois flips < -> <= abaixo tinham ficado FORA da lista por falta de teste
 # que pousasse na igualdade (os testes do orcamento viviam a 82%/85%; o do
 # minOut controlava delivered, nao amountOut). Provado que NAO sao
 # equivalentes: a fronteira e alcancavel para QUALQUER quote G — no caso do
 # orcamento com hopAttested = S = 10*floor(2G/9) + (2G mod 9) (a funcao
 # S - floor(S/10) percorre todos os inteiros), no caso do piso com
 # singleOutFloor = amountOut (identidade de calldata). A chave de exatidao em
 # ambos: amountIn = soma(leg.amountIn) + fee pre-paga -> scaleNum == scaleDen
 # -> os mulDiv de escala sao identidades. Kill verificado no box 2026-09-01:
 # cada teste PASSA limpo e FALHA RouterE(5) com o seu mutante, com o vizinho
 # verde (atribuicao de sitio limpa nos dois sentidos).
 dict(nome="orcamento por hop: < vira <= (a fronteira exata, nao a folga dobrada)",
      f="src/BlazePhoenixRouter.sol",
      old="                if (hopGot + slack < hopAttested) revert RouterE(5);",
      new="                if (hopGot + slack <= hopAttested) revert RouterE(5); // MUTANTE",
      teste="test_HopBudget_ExactBoundaryDelivers"),
 dict(nome="piso agregado: < vira <= na comparacao amountOut/effMin",
      f="src/BlazePhoenixRouter.sol",
      old="        if (amountOut < effMin) revert RouterE(5);",
      new="        if (amountOut <= effMin) revert RouterE(5); // MUTANTE",
      teste="test_AggregateFloor_ExactBoundaryDelivers"),
 # ── as doze guardas que nunca tinham disparado (2026-09-01) ────────────────
 # Um inventario classificou 29 sitios de recusa como conduzidos de um so lado.
 # Doze eram ALCANCAVEIS e tinham testemunha derivada; o test/GuardsNeverFired
 # faz cada uma disparar com o codigo EXATO. Metade partilha o codigo de erro
 # com uma guarda vizinha, e por isso um expectRevert nu passaria na errada.
 dict(nome="hook: o pin de codehash na EXECUCAO (Layer 3) deixa de pausar",
      f="src/BlazePhoenixRouter.sol",
      old="            if (!hub.isHookLive(leg.hooks)) revert RouterE(9);",
      new="            // MUTANTE",
      teste="test_W1_FireB_MutatedHookCode_Reverts9"),
 dict(nome="deadline: a verificacao das portas pre-pulled cai",
      f="src/BlazePhoenixRouter.sol",
      old="        address recipient, uint256 deadline, address payer\n    ) private returns (uint256) {\n        if (block.timestamp > deadline) revert RouterE(4);",
      new="        address recipient, uint256 deadline, address payer\n    ) private returns (uint256) {\n        deadline; // MUTANTE",
      teste="test_W2_Permit2Door_DeadlinePassed_Reverts4"),
 dict(nome="solver hostil: o fail-closed antes do pull cai",
      f="src/BlazePhoenixRouter.sol",
      old="        if (\n            plan.best.hops.length == 0 || plan.best.hops[0].tokenIn != tokenIn\n                || plan.best.hops[plan.best.hops.length - 1].tokenOut != tokenOut\n        ) revert RouterE(3); // fail-closed",
      new="        // MUTANTE",
      teste="test_W3_FireB_TokenInMismatchPlan_Reverts3_BeforeAnyPull"),
 dict(nome="V4: o portao auxId==0 cai (o vizinho com o mesmo codigo 8 nao o cobre)",
      f="src/BlazePhoenixRouter.sol",
      old="        address tokenOther = address(uint160(uint256(leg.auxId)));\n        if (tokenOther == address(0)) revert RouterE(8);",
      new="        address tokenOther = address(uint160(uint256(leg.auxId)));\n        // MUTANTE",
      teste="test_W4_Fire_V4LegAuxIdZero_Reverts8"),
 dict(nome="mulDiv: a require da reducao 512->256 cai",
      f="src/BlazePhoenixCore.sol",
      old='            require(d > prod1, "BPC:mulDiv");',
      new="            // MUTANTE",
      teste="test_W5_Fire_MulDivResultOverflows_Reverts"),
 dict(nome="claimV4: c0==c1 cai na porta permissionless",
      f="src/BlazePhoenixHub.sol",
      old="        _ne0(c0); _ne0(c1);                 // native currency (address(0)) rejected\n        if (c0 == c1) revert HubE(4);",
      new="        _ne0(c0); _ne0(c1);                 // native currency (address(0)) rejected\n        // MUTANTE",
      teste="test_W6_Fire_ClaimV4EqualCurrencies_Reverts4"),
 dict(nome="addFactory: o emparelhamento fees/spacings do modo 9 cai",
      f="src/BlazePhoenixHub.sol",
      old="            if (fees.length != spacings.length) revert HubE(5);",
      new="            // MUTANTE",
      teste="test_W7_Fire_Mode9UnpairedFees_Reverts5"),
 dict(nome="porta nativa: a recusa de rota vazia cai (vira Panic 0x32)",
      f="src/BlazePhoenixRouter.sol",
      old="        if (route.hops.length == 0) revert RouterE(3);\n        if (route.hops[0].tokenIn != w) revert RouterE(3);   // route must start in WETH",
      new="        if (route.hops[0].tokenIn != w) revert RouterE(3);   // route must start in WETH // MUTANTE",
      teste="test_W8_Fire_NativeDoorEmptyRoute_Reverts3"),
 dict(nome="rescue: o destino zero passa a poder ser posto em fila",
      f="src/BlazePhoenixRouter.sol",
      old="    function queueRescue(address token, address to) external onlyControl {\n        if (to == address(0)) revert RouterE(3);",
      new="    function queueRescue(address token, address to) external onlyControl {\n        // MUTANTE",
      teste="test_W9_Fire_QueueRescueZeroTo_Reverts3"),
 dict(nome="addV4: c0==c1 cai na porta do operador",
      f="src/BlazePhoenixHub.sol",
      old="        _ne0(c1);\n        if (c0 == c1) revert HubE(4);",
      new="        _ne0(c1);\n        // MUTANTE",
      teste="test_W10_Fire_AddV4EqualCurrencies_Reverts4"),
 dict(nome="construtor do Router: os tres bracos zero deixam de recusar",
      f="src/BlazePhoenixRouter.sol",
      old="        if (hub_ == address(0) || solver_ == address(0) || admin_ == address(0)) revert RouterE(3);",
      new="        // MUTANTE",
      teste="test_W11_FireA_CtorZeroHub_Reverts3"),
 dict(nome="construtor do Solver: o hub zero deixa de recusar",
      f="src/BlazePhoenixSolver.sol",
      old='        require(hub_ != address(0), "Solver:hub0");',
      new="        // MUTANTE",
      teste="test_W12_Fire_SolverCtorZeroHub_Reverts"),
 # ── o cadeado de reentrancia, que nao tinha vigia nenhuma ──────────────────
 # O `invariant_reentrancyBlocked` contava como cobertura e era uma TAUTOLOGIA:
 # o sentinela so virava se uma chamada aninhada REGRESSASSE, e a carga dele era
 # uma rota vazia — que reverte RouterE(3) com cadeado e sem cadeado. Estava
 # preso ao valor seguro em todas as versoes possiveis do contrato. Duas
 # maneiras distintas de o cadeado falhar, dois vectores, dois testes.
 dict(nome="reentrancia: a verificacao do cadeado deixa de recusar (regiao V4 bloqueada)",
      f="src/BlazePhoenixRouter.sol",
      old="        if (v != 0) revert RouterE(7);",
      new="        v; // MUTANTE",
      teste="test_NestedReentryDuringV4Settle_BlockedByExactLockCode"),
 dict(nome="reentrancia: o cadeado nunca chega a ser armado (a puxada de tokens)",
      f="src/BlazePhoenixRouter.sol",
      old="        assembly { tstore(s, 1) }",
      new="        // MUTANTE",
      teste="test_ReentrancyGuard_BlocksNestedSwapExactInDuringTokenPull"),
 # ── review 2026-09-02: T19 (the poolDeployer pin), the V2/Solidly refuter, the
 # tier in the freshness gate, allowHook's removal arm, and the A1 doors ────────
 # Three read-only reviewers over main 19b2f08. Every entry was judged on the
 # CI box BEFORE it entered this list: mutant applied -> the named test goes
 # red, its neighbour stays green. Where one `old` serves two mutants (the R-B
 # ceiling) the list applies them one at a time, so both are valid.
 dict(nome="T19: the poolDeployer pin at admission is dropped (the attested origin is never written)",
      f="src/BlazePhoenixHub.sol",
      old="            if (mayPin) $.factoryDeployer[factory] = live;",
      new="            if (mayPin) live; // MUTANT",
      teste="test_T19_AnswerSwap_DerivesFromAttestedDeployer"),
 dict(nome="A1: the decimals sentinel returns (a zero-decimal token is read as an instruction not to scale)",
      f="src/BlazePhoenixCore.sol",
      old="        uint256 sIn  = 10 ** (18 - dIn);",
      new="        uint256 sIn  = (dIn == 0) ? 1 : 10 ** (18 - dIn); // MUTANT",
      teste="test_ZeroDecimals_IsAValue_NotAnInstructionNotToScale"),
 dict(nome="S3: a derive row may become an ask row again after renunciation (the mode transition is ungated)",
      f="src/BlazePhoenixHub.sol",
      old='                && ($.factoryCodehash[factory] != factory.codehash || (f.mode > 3 && mode < 4)))',
      new='                && ($.factoryCodehash[factory] != factory.codehash))  // MUTANT',
      teste="test_C4_S3_DeriveRowMustNotBecomeAnAskRowAfterRenounce"),
 dict(nome="VOL_01: the registry is handed the declaration again instead of the measured spend",
      f="src/BlazePhoenixRouter.sol",
      old="                uint256 inM = BPC.mulDiv(leg.amountIn,    sc, 1e18);",
      new="                uint256 inM = leg.amountIn; // MUTANT",
      teste="test_INV_F4_VolumeInEqualsTheMeasuredPoolDelta"),
 dict(nome="FEE_01: the preview stops modelling the exhaustion regime (deducts once when the Router charges per hop)",
      f="src/BlazePhoenixQuoter.sol",
      old="            if (!anchored) charges = route.hops.length;",
      new="            if (!anchored) charges = 1; // MUTANT",
      teste="test_INV_F2_PreviewPredictsDeliveryWithNoBridge"),
 dict(nome="FEE_01: the regime question is never asked (single-hop short circuit swallows every route)",
      f="src/BlazePhoenixQuoter.sol",
      old="        if (route.hops.length > 1) {",
      new="        if (route.hops.length > 99) { // MUTANT",
      teste="test_INV_F2_PreviewPredictsDeliveryWithNoBridge"),
 dict(nome="T19: the first pin loses its post-renunciation gate (an already-admitted row attests after ossification)",
      f="src/BlazePhoenixHub.sol",
      old="                ? (row == n || !$.controlRenounced)",
      new="                ? true // MUTANT",
      teste="test_C4_FirstPin_AfterRenounce_MustNotAttestTheLiveAnswer"),
 dict(nome="T19: the Algebra derive origin is the LIVE answer again",
      f="src/BlazePhoenixHub.sol",
      old="            address orig = _store().factoryDeployer[fac.factory];",
      new="            address orig = BPC.resolvePoolDeployer(fac.factory); // MUTANTE",
      teste="test_T19_ResolverDies_AttestedPoolStaysServed"),
 dict(nome="T19: the predicate loses fee == 0 (a fee-3000 V3 row derives with the Algebra salt)",
      f="src/BlazePhoenixHub.sol",
      old="        if (fac.mode == MODE_CREATE2_V3 && fee == 0) {",
      new="        if (fac.mode == MODE_CREATE2_V3) { // MUTANTE",
      teste="test_T19_PlainV3Mode5_FeeInSalt_FactoryOrigin"),
 dict(nome="T19: the factory fallback is dropped (a zero origin derives elsewhere)",
      f="src/BlazePhoenixHub.sol",
      old="            if (orig == address(0)) orig = fac.factory;",
      new="            // MUTANTE",
      teste="test_T19_NoResolverAtAdmission_FactoryIsOrigin"),
 dict(nome="kind: the pair-shaped family takes the declaration again (V2 vs Solidly)",
      f="src/BlazePhoenixHub.sol",
      old="            if (!isConc) kind = BPC.isSolidlyShaped(pool) ? BPC.KIND_SOLIDLY : BPC.KIND_V2;",
      new="            isConc; // MUTANTE",
      teste="test_SolidlyShapedPool_MustNotPersistAsV2"),
 dict(nome="freshness gate: permissionless rows can switch discovery off again",
      f="src/BlazePhoenixSolver.sol",
      old="            if (BPC.decodeTier(s) != 0) { unchecked { ++i; } continue; }",
      new="            // MUTANTE",
      teste="test_ThreeSelfRegisteredDustRows_CannotSilenceDiscovery"),
 dict(nome="allowHook: the removal arm survives renounceControl again",
      f="src/BlazePhoenixHub.sol",
      old="        if (!ok && $.controlRenounced) revert HubE(1);",
      new="        // MUTANTE",
      teste="test_AfterRenounce_DelistingAHookIsRefused"),
 dict(nome="A1 door 2 (permit2): the zero-minOut refusal is dropped",
      f="src/BlazePhoenixRouter.sol",
      old="        if (amountIn > 0 && userMinOut == 0) revert RouterE(10);\n        if (permit.permitted.amount < amountIn) revert RouterE(3);",
      new="        if (permit.permitted.amount < amountIn) revert RouterE(3); // MUTANTE",
      teste="test_A1_Door2_Permit2_RefusesZeroMinOut"),
 dict(nome="A1 door 3 (native): the zero-minOut refusal is dropped",
      f="src/BlazePhoenixRouter.sol",
      old="        if (userMinOut == 0) revert RouterE(10);\n        if (route.hops.length == 0) revert RouterE(3);\n        if (route.hops[0].tokenIn != w) revert RouterE(3);   // route must start in WETH",
      new="        if (route.hops.length == 0) revert RouterE(3); // MUTANTE\n        if (route.hops[0].tokenIn != w) revert RouterE(3);   // route must start in WETH",
      teste="test_A1_Door3_Native_RefusesZeroMinOut"),
 dict(nome="A1 door 4 (swapBestExactIn): the zero-minOut refusal is dropped, before the solve",
      f="src/BlazePhoenixRouter.sol",
      old="        uint256 userMinOut, address recipient, uint256 deadline\n    ) external whenLive nrEntrant returns (uint256) {\n        if (amountIn == 0 || amountIn > type(uint128).max) revert RouterE(3);\n        if (userMinOut == 0) revert RouterE(10);",
      new="        uint256 userMinOut, address recipient, uint256 deadline\n    ) external whenLive nrEntrant returns (uint256) {\n        if (amountIn == 0 || amountIn > type(uint128).max) revert RouterE(3);\n        // MUTANTE",
      teste="test_A1_Door4_Best_RefusesZeroMinOut_BeforeTheSolve"),
 dict(nome="A1 door 5 (self-call): the door stops requiring msg.sender == this",
      f="src/BlazePhoenixRouter.sol",
      old="        if (msg.sender != address(this)) revert RouterE(1);",
      new="        // MUTANTE",
      teste="test_A1_Door5_SelfCall_StrangerIsRefused"),
 dict(nome="factory codehash pin (modes 0-3): dropped",
      f="src/BlazePhoenixHub.sol",
      old="        if (fac.mode < 4 && fac.factory.codehash != _store().factoryCodehash[fac.factory]) return k;",
      new="        // MUTANTE",
      teste="test_RuntimeMutatedFactoryStopsBeingADiscoverySource"),
 dict(nome="R-B ceiling, multi-hop: the worst-leg arm is dropped (only the mean gates)",
      f="src/BlazePhoenixSolver.sol",
      old="        if (maxLegImpactBps >= MAX_ROUTE_IMPACT_BPS || gateImpactBps >= MAX_ROUTE_IMPACT_BPS) return route;",
      new="        if (gateImpactBps >= MAX_ROUTE_IMPACT_BPS) return route; // MUTANTE",
      teste="test_L1498c1_WorstLegArmAloneRefusesTheDilutedDestroyer"),
 dict(nome="R-B ceiling, multi-hop: the aggregate arm is dropped (only the worst leg gates)",
      f="src/BlazePhoenixSolver.sol",
      old="        if (maxLegImpactBps >= MAX_ROUTE_IMPACT_BPS || gateImpactBps >= MAX_ROUTE_IMPACT_BPS) return route;",
      new="        if (maxLegImpactBps >= MAX_ROUTE_IMPACT_BPS) return route; // MUTANTE",
      teste="test_L1498c2_AggregateArmAloneRefusesTwoHalfImpactHops"),
 dict(nome="balanceOf: an empty return becomes a refusal instead of zero (the unset token)",
      f="src/BlazePhoenixCore.sol",
      old="                if iszero(lt(returndatasize(), 32)) { b := mload(m) }",
      new="                if iszero(lt(returndatasize(), 32)) { b := mload(m) }\n                if lt(returndatasize(), 32) { ok := 0 } // MUTANTE",
      teste="test_BalanceOf_CodelessIsDeliberateZero_NotARefusal"),
 dict(nome="NM-002: the floor no longer falls back to the attested quote when the last hop's quote is zero",
      f="src/BlazePhoenixRouter.sol",
      # Retargeted 2026-09-04: the two producers of `finalHopQuote` were folded into one
      # expression by the FLOOR-01 fix. NM-002's property lives inside it - a hop that DID
      # execute but could not be quoted in-frame falls back to its attested figure - so the
      # mutant now removes exactly that fallback and leaves the rest of the fix standing.
      old="                finalHopQuote = hopQuote != 0 ? hopQuote : hopAttested;",
      new="                finalHopQuote = hopQuote;",
      teste="test_LiquidityGapOnLastHop_FloorFallsBackToAttested"),
 dict(nome="impact: an unquotable concentrated leg counts BPS again (the floor collapses to the clamp)",
      f="src/BlazePhoenixRouter.sol",
      old="                        q_ == 0 ? BPC.DEFAULT_IMPACT_BPS : BPC.impactV3FromOut(q_, legAmt, sp, leg.zeroForOne),",
      new="                        BPC.impactV3FromOut(q_, legAmt, sp, leg.zeroForOne), // MUTANTE",
      teste="test_UnquotableFeeZeroLeg_FloorDoesNotCollapseToTheClamp"),
 dict(nome="swapBestExactIn: the plan's output end is no longer checked",
      f="src/BlazePhoenixRouter.sol",
      old="                || plan.best.hops[plan.best.hops.length - 1].tokenOut != tokenOut\n        ) revert RouterE(3); // fail-closed",
      new="        ) revert RouterE(3); // fail-closed // MUTANTE",
      teste="test_PlanEndingInAnotherToken_IsRefusedBeforeThePull"),
 dict(nome="per-leg floor: mulDivUp becomes mulDiv in the 3/2 window (the 1-wei threshold rounds to zero)",
      f="src/BlazePhoenixRouter.sol",
      old="            if (bound != 0 && got < BPC.mulDivUp(bound, BPC.LEG_FLOOR_BPS, BPC.BPS)) revert RouterE(5);",
      new="            if (bound != 0 && got < BPC.mulDiv(bound, BPC.LEG_FLOOR_BPS, BPC.BPS)) revert RouterE(5); // MUTANTE",
      teste="test_OneWeiBound_LegDeliveringNothingIsRefused"),
 dict(nome="registry: a pair-shaped row's fee comes from the V3 getter again",
      f="src/BlazePhoenixHub.sol",
      old="            feeReg = isConc ? (dynShape ? 0 : BPC.getV3Fee(pool)) : 0;",
      new="            feeReg = dynShape ? 0 : BPC.getV3Fee(pool); // MUTANTE",
      teste="test_V2PairWithForeignFeeGetter_RowFeeIsZero"),
 dict(nome="resolvePoolDeployer: the >= 32 policy becomes == 32 again (a wide answer reads as zero)",
      f="src/BlazePhoenixCore.sol",
      old="            if and(ok, iszero(lt(returndatasize(), 32))) {",
      new="            if and(ok, eq(returndatasize(), 32)) { // MUTANTE",
      teste="test_T19_WideAnswerFactory_IsAttestedFromTheFirstWord"),
 # ── 6th bounty wave (mohaseenkatika), 2026-09-02: one floor, two producers ────
 dict(nome="solver floor: the attested floor rounds DOWN again (1 wei under the Router's)",
      f="src/BlazePhoenixSolver.sol",
      old="        uint256 floorOut = BPC.mulDivUp(hop.expectedOut, floorBps, BPC.BPS);",
      new="        uint256 floorOut = BPC.mulDiv(hop.expectedOut, floorBps, BPC.BPS); // MUTANTE",
      teste="test_Parity_SingleLegRoute_AttestedFloorEqualsEnforcedFloor"),
 dict(nome="solver floor: the hop impact is the UNWEIGHTED mean again (dust votes like a whole leg)",
      f="src/BlazePhoenixSolver.sol",
      old="            totalImpactBps += hopIn == 0 ? li : BPC.mulDiv(li * legs, hop.legs[i].amountIn, hopIn);",
      new="            totalImpactBps += li; // MUTANTE",
      teste="test_Parity_SplitRoute_AttestedFloorEqualsEnforcedFloor"),
 # ── frozen-at-write probes (7th bounty wave, 2026-09-02): the CONTROLS must have teeth ──
 dict(nome="hook liveness: drop the live codehash comparison",
      f="src/BlazePhoenixHub.sol",
      old="        return $.hookAllowed[h] && h.codehash == $.hookCodehash[h];",
      new="        return $.hookAllowed[h]; // MUTANT",
      teste="test_control_hookCodehash_isPinnedAtAdmissionAndReadLive"),
 dict(nome="register: forget the key-existence guard (duplicate rows)",
      f="src/BlazePhoenixHub.sol",
      old="        if ($.poolOf[key] == address(0)) {",
      new="        if (true) { // MUTANT",
      teste="test_control_tier_isRefreshedInPlaceBySeedPool"),
 dict(nome="solidly quote: skip the pool's own getAmountOut",
      f="src/BlazePhoenixCore.sol",
      old="            out = solidlyGetAmountOut(c.pool, amountIn, c.tokenIn);",
      new="            out = 0; // MUTANT",
      teste="test_control_stableField_standardPoolIsPricedByItsOwnGetter"),
 # ── the fixes behind the probes (7th bounty wave): each producer must be the one read ──
 dict(nome="BRIDGE-01: the bridge term of psi stops following the live bridge",
      f="src/BlazePhoenixHub.sol",
      old="        return _isRoutableBridge($, t0) || _isRoutableBridge($, t1);\n    }",
      new="        t0; t1; return false; // MUTANT\n    }",
      teste="test_probe_bridgedBit_removeBridge_psiFollowsTheLiveBridge"),
 dict(nome="BRIDGE-01 (mirror): a pool registered before addBridge must earn the bonus",
      f="src/BlazePhoenixHub.sol",
      old="        return _isRoutableBridge($, t0) || _isRoutableBridge($, t1);\n    }",
      new="        t0; t1; return false; // MUTANT\n    }",
      teste="test_probe_bridgedBit_addBridge_psiFollowsTheLiveBridge"),
 dict(nome="SLOT-01: the stable bit is never written at registration",
      f="src/BlazePhoenixHub.sol",
      old="        if (kind == BPC.KIND_SOLIDLY && BPC.solidlyStable(pool)) s = _markStable(s, true);",
      new="        pool; // MUTANT",
      teste="test_probe_stableField_registryReadReturnsThePoolsAnswer"),
 dict(nome="SLOT-01: the fallback curve reads a constant instead of the registry flag",
      f="src/BlazePhoenixHub.sol",
      old="        p.stable      = _isStable(s);",
      new="        p.stable      = false; // MUTANT",
      teste="test_probe_stableField_fallbackCurveReadsTheRegistryFlag"),
 dict(nome="PROV-01: declared reserves are no longer capped by physical holdings (Solver)",
      f="src/BlazePhoenixSolver.sol",
      old="                    if (physical < depths[i]) depths[i] = physical == 0 ? 1 : physical;",
      new="                    physical; // MUTANT",
      teste="test_probe_forgedMass_cannotCaptureTheRouteWithoutCapital"),
 # ── the multi-hop twin of the floor (found by the review pass after PR #25) ──
 dict(nome="floor, multi-hop: a leg's impact stops being weighted by its share",
      f="src/BlazePhoenixSolver.sol",
      old="                weightedAcc += hopIn == 0 ? li : BPC.mulDiv(li * legs, a, hopIn);",
      new="                weightedAcc += li; // MUTANT",
      teste="test_Parity_TwoHopSplitRoute_AttestedFloorRateEqualsEnforcedFloorRate"),
 dict(nome="floor, multi-hop: the sum of per-hop means feeds the floor again",
      f="src/BlazePhoenixSolver.sol",
      old="        uint256 totalImpactBps = totalLegs > 0 ? weightedAcc / totalLegs : 0;",
      new="        uint256 totalImpactBps = gateImpactBps; weightedAcc; // MUTANT",
      teste="test_Parity_TwoHopSplitRoute_AttestedFloorRateEqualsEnforcedFloorRate"),
 # ── the review pass after PR #25 (2026-09-02): authority, gas-bomb, hop ceiling ──
 dict(nome="hooks: after renunciation a mutated hook can be re-armed again",
      f="src/BlazePhoenixHub.sol",
      old="        if (ok && $.controlRenounced && $.hookAllowed[h] && $.hookCodehash[h] != h.codehash) revert HubE(1);",
      new="        // MUTANT",
      teste="test_RenouncedAdmin_CanStillRearmMutatedHook"),
 dict(nome="V4 index: seedPool stops writing the O(1) entry for a V4 row",
      f="src/BlazePhoenixHub.sol",
      old="                $.v4EntryOf[key] = $.v4Entries.length;\n            }\n        }\n        _register(key, pool, kind, fee, hooks, t0, t1, true);",
      new="                // MUTANT\n            }\n        }\n        _register(key, pool, kind, fee, hooks, t0, t1, true);",
      teste="test_SeedPoolV4Row_FallsIntoUnboundedScan"),
 dict(nome="V4 index: the step-5 backstop stops answering (recovery gives up)",
      f="src/BlazePhoenixHub.sol",
      old="        uint256 ep = $.v4EntryOf[key];\n        if (ep != 0) {\n            ts = $.v4Entries[ep - 1].tickSpacing;",
      new="        uint256 ep = 0; key; // MUTANT\n        if (ep != 0) {\n            ts = $.v4Entries[ep - 1].tickSpacing;",
      teste="test_RecordSwap_WalksTheArrayUpToTheRowsIndex"),
 dict(nome="router: the hop ceiling is gone",
      f="src/BlazePhoenixRouter.sol",
      old="        if (route.hops.length > MAX_HOPS) revert RouterE(3);",
      new="        // MUTANT",
      teste="test_RouteHopCountHasACeiling"),
 dict(nome="router: Layer 2 falls back to per-hop scope (the hooked flag resets every hop)",
      f="src/BlazePhoenixRouter.sol",
      old="            uint256 hopGot;",
      new="            uint256 hopGot; sawHooked = false; // MUTANT",
      teste="test_HookedLegInHop0_BeforeHookless_Reverts"),
 # ── the NEGATIVE halves the MC/DC campaign of 2026-09-03 found missing ──
 # Each of these three sub-conditions was neutralised and the whole suite stayed
 # green, because every fix above was tested only in the direction that makes it
 # fire. Mutation had not found them: the mutants were written from the same
 # one-sided intuition as the tests.
 dict(nome="BRIDGE-01: the second arm of the bridge disjunction stops answering",
      f="src/BlazePhoenixHub.sol",
      old="        return _isRoutableBridge($, t0) || _isRoutableBridge($, t1);",
      new="        return _isRoutableBridge($, t0); // MUTANT",
      teste="test_probe_bridgedBit_secondArgumentArmGrantsTheBonus"),
 dict(nome="BRIDGE-01: the first arm of the bridge disjunction stops answering",
      f="src/BlazePhoenixHub.sol",
      old="        return _isRoutableBridge($, t0) || _isRoutableBridge($, t1);",
      new="        return _isRoutableBridge($, t1); // MUTANT",
      teste="test_probe_bridgedBit_firstArgumentArmGrantsTheBonus"),
 dict(nome="SLOT-01: every registered pool is marked stable (the read forced true)",
      f="src/BlazePhoenixHub.sol",
      old="        p.stable      = _isStable(s);",
      new="        p.stable      = true; // MUTANT",
      teste="test_probe_stableField_volatilePoolReadsBackVolatile"),
 dict(nome="SLOT-01: the kind arm drops, so any shape that answers stable() carries the bit",
      f="src/BlazePhoenixHub.sol",
      old="        if (kind == BPC.KIND_SOLIDLY && BPC.solidlyStable(pool)) s = _markStable(s, true);",
      new="        if (BPC.solidlyStable(pool)) s = _markStable(s, true); // MUTANT",
      teste="test_probe_stableField_nonSolidlyKindNeverCarriesTheBit"),
 # ── MC/DC inerts that change an OUTPUT (campaign of 2026-09-03, see test/McdcInertsClosed.t.sol) ──
 dict(nome="solidly overflow sentinel: the Y arm drops, so an absurd out-reserve reaches mulDiv and panics",
      f="src/BlazePhoenixCore.sol",
      old="        if (X > 3.4e38 || Y > 3.4e38) return 0;",
      new="        if (X > 3.4e38) return 0; // MUTANT",
      teste="test_absurdOutReserve_returnsZeroNotPanic"),
 dict(nome="V4 learned codes: the bridge exclusion drops on t0, so a bridge learns a code",
      f="src/BlazePhoenixHub.sol",
      old="        if (!$.isBridge[t0] && $.v4CodeOf[t0] != c) $.v4CodeOf[t0] = c;",
      new="        if ($.v4CodeOf[t0] != c) $.v4CodeOf[t0] = c; // MUTANT",
      teste="test_bridgeSide_neverLearnsACode_counterpartDoes"),
 # Router:1003 `bt != tokenOut` deliberately has NO entry: the campaign found the
 # arm inert and reading confirmed why - line 1078 prices a hop whose input is
 # tokenOut against `toutStart`, never against bridgeBase, so the arm skips a
 # read nobody consumes. The property (holds-nothing on the A -> C -> B -> C
 # topology) is pinned by test_strandedTokenOut_isNotScaledIntoAnIntermediateHop
 # and carried by the `toutStart` branch of 1078, which is the line a mutant
 # should target if that branch ever gains one.
 # ── Security Closure build pass (2026-09-03): C1 authority, C2 Router cap, C3 addFactory re-arm, C4 T19 re-admission, C5 temporal orderings, C6 outV3 twin ──
 dict(nome='hub authority: onlyAdmin - the identity check is gone',
      f='src/BlazePhoenixHub.sol',
      old='    modifier onlyAdmin()    { _auth(msg.sender == _store().admin); _; }',
      new='    modifier onlyAdmin()    { _; } // MUTANT',
      teste='test_Authority_OnlyAdmin_StrangerCannotRenounceControl'),
 dict(nome='hub authority: onlyControl - the whole guard is gone',
      f='src/BlazePhoenixHub.sol',
      old='    modifier onlyControl()  {\n        HubStore storage $ = _store();\n        _auth(msg.sender == $.admin && !$.controlRenounced);\n        _;\n    }',
      new='    modifier onlyControl()  {\n        _; // MUTANT\n    }',
      teste='test_Authority_OnlyControl_StrangerCannotSetPaused'),
 dict(nome='hub authority: onlyOperator - the whole guard is gone',
      f='src/BlazePhoenixHub.sol',
      old='    modifier onlyOperator() { _auth(_store().operator[msg.sender] || msg.sender == _store().admin); _; }',
      new='    modifier onlyOperator() { _; } // MUTANT',
      teste='test_SeedPool_OnlyOperator'),
 dict(nome='hub authority: onlyRouter - the identity check is gone',
      f='src/BlazePhoenixHub.sol',
      old='    modifier onlyRouter()   { _auth(msg.sender == _store().router); _; }',
      new='    modifier onlyRouter()   { _; } // MUTANT',
      teste='test_RecordSwap_OnlyRouter'),
 dict(nome='hub authority: whenLive - the pause check is gone',
      f='src/BlazePhoenixHub.sol',
      old='    modifier whenLive()     { if (_store().paused) revert HubE(2); _; }',
      new='    modifier whenLive()     { _; } // MUTANT',
      teste='test_RecordSwap_RevertsWhenPaused'),
 dict(nome='hub authority: onlyControl - the identity arm is gone (anyone may act while control lives)',
      f='src/BlazePhoenixHub.sol',
      old='        _auth(msg.sender == $.admin && !$.controlRenounced);',
      new='        _auth(!$.controlRenounced); // MUTANT',
      teste='test_Authority_OnlyControl_StrangerCannotSetPaused'),
 dict(nome='hub authority: onlyControl - the renunciation arm is gone (control outlives renounceControl)',
      f='src/BlazePhoenixHub.sol',
      old='        _auth(msg.sender == $.admin && !$.controlRenounced);',
      new='        _auth(msg.sender == $.admin); // MUTANT',
      teste='test_Authority_SetV4Manager_RenouncedAdminCannotRepointTheSingleton'),
 dict(nome='hub authority: onlyOperator - the operator-map arm is gone (only the admin passes)',
      f='src/BlazePhoenixHub.sol',
      old='    modifier onlyOperator() { _auth(_store().operator[msg.sender] || msg.sender == _store().admin); _; }',
      new='    modifier onlyOperator() { _auth(msg.sender == _store().admin); _; } // MUTANT',
      teste='test_SetOperator_OnlyControl_AndGrantsSeedPool'),
 dict(nome='hub authority: onlyOperator - the admin arm is gone (the admin needs the bit)',
      f='src/BlazePhoenixHub.sol',
      old='    modifier onlyOperator() { _auth(_store().operator[msg.sender] || msg.sender == _store().admin); _; }',
      new='    modifier onlyOperator() { _auth(_store().operator[msg.sender]); _; } // MUTANT',
      teste='test_L432_AdminWhoIsNotOperator_StillPassesOperatorDoor'),
 dict(nome='hub authority: initialize - the one-shot arm is gone (the admin may re-initialize)',
      f='src/BlazePhoenixHub.sol',
      old='        if ($.initialized || msg.sender != $.admin || $.controlRenounced) revert HubE(1);',
      new='        if (msg.sender != $.admin || $.controlRenounced) revert HubE(1); // MUTANT',
      teste='test_Initialize_RevertsOnSecondCall'),
 dict(nome='hub authority: initialize - the caller arm is gone (anyone may claim a virgin registry)',
      f='src/BlazePhoenixHub.sol',
      old='        if ($.initialized || msg.sender != $.admin || $.controlRenounced) revert HubE(1);',
      new='        if ($.initialized || $.controlRenounced) revert HubE(1); // MUTANT',
      teste='test_Initialize_RevertsWhenCalledByNonDeployer'),
 dict(nome='hub authority: setV4Manager loses its modifier (the V4 instrument becomes permissionless)',
      f='src/BlazePhoenixHub.sol',
      old='    function setV4Manager(address m) external onlyControl { _store().v4PoolManager = m; emit RoleSet(5, m); }',
      new='    function setV4Manager(address m) external { _store().v4PoolManager = m; emit RoleSet(5, m); } // MUTANT',
      teste='test_Authority_SetV4Manager_RenouncedAdminCannotRepointTheSingleton'),
 dict(nome='hub authority: recordSwap loses whenLive (the emergency switch stops reaching the registry)',
      f='src/BlazePhoenixHub.sol',
      old='    ) external onlyRouter whenLive {',
      new='    ) external onlyRouter { // MUTANT',
      teste='test_RecordSwap_RevertsWhenPaused'),
 dict(nome='hub authority: renounceControl loses onlyAdmin (a stranger may freeze the control plane for ever)',
      f='src/BlazePhoenixHub.sol',
      old='    function renounceControl() external onlyAdmin {',
      new='    function renounceControl() external { // MUTANT',
      teste='test_Authority_OnlyAdmin_StrangerCannotRenounceControl'),
 dict(nome='hub authority: onlyAdmin gone - a stranger may admit a hook after renunciation',
      f='src/BlazePhoenixHub.sol',
      old='    modifier onlyAdmin()    { _auth(msg.sender == _store().admin); _; }',
      new='    modifier onlyAdmin()    { _; } // MUTANT',
      teste='test_Authority_OnlyAdmin_StrangerCannotAdmitAHookAfterRenounce'),
 dict(nome='hub authority: onlyRouter gone - the stranger must then get the PAUSE code',
      f='src/BlazePhoenixHub.sol',
      old='    modifier onlyRouter()   { _auth(msg.sender == _store().router); _; }',
      new='    modifier onlyRouter()   { _; } // MUTANT',
      teste='test_Authority_ModifierOrder_AuthCodeWinsOverThePauseCode'),
 dict(nome='PROV-01 (Router): the physical cap is gone - declared reserves become the registry depth',
      f='src/BlazePhoenixRouter.sol',
      old='        if (b0 < r0) r0 = b0;\n        if (b1 < r1) r1 = b1;',
      new='        b0; b1; // MUTANT',
      teste='test_probe_forgedReserves_registryBucketIsThePhysicalMass'),
 dict(nome='PROV-01 (Router): the token0 arm of the cap stops binding',
      f='src/BlazePhoenixRouter.sol',
      old='        if (b0 < r0) r0 = b0;',
      new='        b0; // MUTANT',
      teste='test_probe_forgedReserves_slot0ArmCapsTheShortSide'),
 dict(nome='PROV-01 (Router): the token1 arm of the cap stops binding',
      f='src/BlazePhoenixRouter.sol',
      old='        if (b1 < r1) r1 = b1;',
      new='        b1; // MUTANT',
      teste='test_probe_forgedReserves_slot1ArmCapsTheShortSide'),
 dict(nome='factory codehash pin (modes 0-3): the comparison is inverted (the unchanged factory is the one refused)',
      f='src/BlazePhoenixHub.sol',
      old='        if (fac.mode < 4 && fac.factory.codehash != _store().factoryCodehash[fac.factory]) return k;',
      new='        if (fac.mode < 4 && fac.factory.codehash == _store().factoryCodehash[fac.factory]) return k; // MUTANT',
      teste='test_FactoryRearm_MutatedFactoryIsAutoPausedBeforeAnyReAdd'),
 dict(nome='addFactory: the curator power is downgraded to a control power (dies with renounceControl)',
      f='src/BlazePhoenixHub.sol',
      old='    ) external onlyAdmin returns (uint8) {',
      new='    ) external onlyControl returns (uint8) { // MUTANT',
      teste='test_FactoryRearm_ANewFactoryIsStillAdmittedAfterRenounce'),
 dict(nome='addFactory: the codehash re-attestation becomes first-write-only (a live admin can no longer re-attest)',
      f='src/BlazePhoenixHub.sol',
      old='        $.factoryCodehash[factory] = factory.codehash;',
      new='        if ($.factoryCodehash[factory] == bytes32(0)) $.factoryCodehash[factory] = factory.codehash; // MUTANT',
      teste='test_FactoryRearm_BeforeRenounceTheAdminMayReattest'),
 dict(nome='C4: the deployer pin loses its mode gate (any re-admission re-attests)',
      f='src/BlazePhoenixHub.sol',
      old='        if (mode == MODE_CREATE2_V3) {\n            address live = BPC.resolvePoolDeployer(factory);',
      new='        { address live = BPC.resolvePoolDeployer(factory); // MUTANT',
      teste='test_C4_ReAdmit_UnderANonMode5Row_LeavesThePinIntact'),
 dict(nome='C4 (anti-rigidity): re-admission is banned outright after renounceControl',
      f='src/BlazePhoenixHub.sol',
      old='        _ne0(factory);',
      new='        _ne0(factory);\n        if (_store().controlRenounced && _store().factoryCodehash[factory] != bytes32(0)) revert HubE(1); // MUTANT',
      teste='test_C4_ReAdmit_UnchangedAnswer_AfterRenounce_IsAccepted'),
 dict(nome='C5 ordering: renunciation stops binding the control plane (setRoles)',
      f='src/BlazePhoenixHub.sol',
      old='        _auth(msg.sender == $.admin && !$.controlRenounced);',
      new='        _auth(msg.sender == $.admin); // MUTANT',
      teste='test_AfterRenounce_TheRegistryWriteDoorIsPinnedToOneAddressForever'),
 dict(nome='C5 ordering: renunciation stops binding the control plane (setOperator)',
      f='src/BlazePhoenixHub.sol',
      old='        _auth(msg.sender == $.admin && !$.controlRenounced);',
      new='        _auth(msg.sender == $.admin); // MUTANT',
      teste='test_AfterRenounce_TheOperatorGrantIsPermanent'),
 dict(nome='outV2: the empty-in-reserve arm drops, so an empty pool quotes the whole input',
      f='src/BlazePhoenixCore.sol',
      old='    function outV2(uint256 ain, uint256 rIn, uint256 rOut, uint256 fee)\n        internal pure returns (uint256)\n    {\n        if (ain == 0 || rIn == 0 || rOut == 0) return 0;',
      new='    function outV2(uint256 ain, uint256 rIn, uint256 rOut, uint256 fee)\n        internal pure returns (uint256)\n    {\n        if (ain == 0 || rOut == 0) return 0; // MUTANT',
      teste='test_OutV2_ZeroInputsReturnZero'),
 dict(nome='outV3: the load-bearing half of the twin clamp - a zero sqrtLimit becomes a clamp to zero',
      f='src/BlazePhoenixCore.sol',
      old='            if (sqrtLimit != 0 && sqrtNew > sqrtLimit) sqrtNew = sqrtLimit;',
      new='            if (sqrtNew > sqrtLimit) sqrtNew = sqrtLimit; // MUTANT',
      teste='test_OutV3_NonBindingUpperLimitDoesNotBendTheQuote'),
 dict(nome='outV3: the zero-input refusal answers the raw liquidity instead of zero',
      f='src/BlazePhoenixCore.sol',
      old='        if (ain == 0 || liq == 0 || sqrtP == 0) return 0;',
      new='        if (ain == 0 || liq == 0 || sqrtP == 0) return uint256(liq); // MUTANT',
      teste='test_OutV3_ZeroInputsReturnZero'),
 # ── the fixes the 7 red built tests demanded (addFactory refresh-in-place + post-renounce re-arm guard, frozen T19 attestation, initialize after renounce) ──
 dict(nome='factories: after renunciation a mutated factory can be re-armed again (twin of the hook guard)',
      f='src/BlazePhoenixHub.sol',
      old='                && ($.factoryCodehash[factory] != factory.codehash || (f.mode > 3 && mode < 4)))',
      new='                && (false))  // MUTANT',
      teste='test_FactoryRearm_RenouncedAdminCanReArmAMutatedFactory'),
 dict(nome='addFactory: the duplicate-address guard is gone (a second row is pushed for one address)',
      f='src/BlazePhoenixHub.sol',
      old='            if ($.factories[i].factory == factory) { row = i; break; }',
      new='            if (false) { row = i; break; } // MUTANT',
      teste='test_FactoryRearm_ReAddingTheSameFactoryPushesADuplicateRow'),
 dict(nome='addFactory: the duplicate guard is gone, so one address can exhaust MAX_FACTORIES',
      f='src/BlazePhoenixHub.sol',
      old='            if ($.factories[i].factory == factory) { row = i; break; }',
      new='            if (false) { row = i; break; } // MUTANT',
      teste='test_FactoryRearm_ReAddsExhaustTheTableWithOneAddress'),
 dict(nome='T19 re-admission: after renunciation the attested origin follows the live answer again',
      f='src/BlazePhoenixHub.sol',
      old='                : (!$.controlRenounced && live != address(0));',
      new='                : (live != address(0)); // MUTANT',
      teste='test_C4_ReAdmit_AfterRenounce_MustNotFollowTheLiveAnswer'),
 dict(nome='T19 re-admission: a dead resolver demotes a good attestation to zero',
      f='src/BlazePhoenixHub.sol',
      old='                : (!$.controlRenounced && live != address(0));',
      new='                : (!$.controlRenounced);  // MUTANT',
      teste='test_C4_ReAdmit_WithDeadResolver_MustNotDemoteToZero'),
 dict(nome='C5 ordering: initialize survives renunciation again',
      f='src/BlazePhoenixHub.sol',
      old='        if ($.initialized || msg.sender != $.admin || $.controlRenounced) revert HubE(1);',
      new='        if ($.initialized || msg.sender != $.admin) revert HubE(1); // MUTANT',
      teste='test_AfterRenounce_InitializeIsRefused'),
 # ── C7 native-V4 (2026-09-03): the three MC/DC inerts that needed the V4 harness, each disjunction guarded on BOTH arms ──
 dict(nome='C7 #21: _scanV4 loses the t0 == w arm - native discovery vanishes when WETH sorts first',
      f='src/BlazePhoenixHub.sol',
      old='        if (w != address(0) && (t0 == w || t1 == w)) {',
      new='        if (w != address(0) && (t1 == w)) { // MUTANT',
      teste='test_C7_L1039_NativeDiscovery_WhenWethSortsFirst'),
 dict(nome='C7 #21 (twin arm): _scanV4 loses the t1 == w arm - native discovery vanishes when WETH sorts second',
      f='src/BlazePhoenixHub.sol',
      old='        if (w != address(0) && (t0 == w || t1 == w)) {',
      new='        if (w != address(0) && (t0 == w)) { // MUTANT',
      teste='test_L977_NativeDiscovery_WhenWethSortsSecond'),
 dict(nome='C7 #10: universalQuote loses the KIND_V4_NATIVE arm - every native V4 candidate quotes zero',
      f='src/BlazePhoenixCore.sol',
      old='        if (k == KIND_V4 || k == KIND_V4_NATIVE) {',
      new='        if (k == KIND_V4) { // MUTANT',
      teste='test_NativeV4_Quote_ZeroForOne_HasOutputAndDepth'),
 dict(nome='C7 #10 (twin arm): universalQuote loses the KIND_V4 arm - every wrapped V4 candidate quotes zero',
      f='src/BlazePhoenixCore.sol',
      old='        if (k == KIND_V4 || k == KIND_V4_NATIVE) {',
      new='        if (k == KIND_V4_NATIVE) { // MUTANT',
      teste='test_NativeV4_Quote_MatchesTheWrappedKindOverTheSameCurrencies'),
 dict(nome='C7 #10: the V4 pool id stops sorting its currencies - a native pool read from the counter side vanishes',
      f='src/BlazePhoenixCore.sol',
      old='            (address s0, address s1) = sortTokens(c.tokenIn, c.tokenOther);',
      new='            (address s0, address s1) = (c.tokenIn, c.tokenOther); // MUTANT',
      teste='test_NativeV4_Quote_OneForZero_HasOutputAndDepth'),
 dict(nome='C7 #10: the V4 depth stops mapping decimals onto token0/token1 by direction',
      f='src/BlazePhoenixCore.sol',
      old='            (uint8 a0, uint8 a1) = c.zeroForOne ? (dIn4, dOt4) : (dOt4, dIn4);',
      new='            (uint8 a0, uint8 a1) = (dIn4, dOt4); // MUTANT',
      teste='test_NativeV4_Quote_DepthIsDirectionIndependentUnderAsymmetricDecimals'),
 dict(nome='V4 unlockCallback: the native INPUT arm (currency0 == 0)',
      f='src/BlazePhoenixRouter.sol',
      old='        if (key.currency0 == address(0) && zfo) {',
      new='        if (zfo) { // MUTANT',
      teste='test_V4NonNative_ZeroForOne_TakesErc20Seam'),
 dict(nome='V4 unlockCallback: the native OUTPUT arm (currency0 == 0)',
      f='src/BlazePhoenixRouter.sol',
      old='        if (key.currency0 == address(0) && !zfo) {',
      new='        if (!zfo) { // MUTANT',
      teste='test_V4NonNative_OneForZero_TakesErc20Seam'),
 # ── FEE-02 (eighth disclosure round, 2026-09-03): previewPlanExact returns the NET output ──
 dict(nome='FEE-02: previewPlanExact loses the protocol-fee deduction (exactOut is the pool-math ceiling again)',
      f='src/BlazePhoenixQuoter.sol',
      old='        exactOut = gross - BPC.mulDivUp(gross, BPC.PROTOCOL_FEE_BPS, BPC.BPS);',
      new='        exactOut = gross; // MUTANT',
      teste='test_ExactOut_IsAFloorTheRouterHonours'),
 dict(nome='FEE-02: the deduction rounds DOWN (a wei more than delivery on inexact divisions)',
      f='src/BlazePhoenixQuoter.sol',
      old='        exactOut = gross - BPC.mulDivUp(gross, BPC.PROTOCOL_FEE_BPS, BPC.BPS);',
      new='        exactOut = gross - BPC.mulDiv(gross, BPC.PROTOCOL_FEE_BPS, BPC.BPS); // MUTANT',
      teste='test_ExactOut_OneHop_IsThePoolMathCeilingLessTheFeeRoundedUp'),
 # The compiler's own refusal, paired. `Router:_execute` divides hopAttested/hopQuoted under
 # `if (hopAttested != 0)`, and that guard is what makes panic 0x12 unreachable there: the three
 # hop accumulators are declared inside the hop loop and hopAttested is the sum of exactly the
 # legAtt values whose non-zero-ness increments hopQuoted, so a non-zero sum needs a non-zero
 # term. Moving the guard onto hopGot - an accumulator the divisor is NOT built from - lets a hop
 # that executes without attesting divide by zero. It dies with `panic: division or modulo by
 # zero (0x12)`, which is the point: the corpus really does drive such a hop, so the argument
 # above is tested rather than merely asserted.
 dict(nome="panic 0x12: the hop-slack guard moves to an accumulator the divisor is not built from",
      f="src/BlazePhoenixRouter.sol",
      old="            if (hopAttested != 0) {",
      new="            if (hopGot != 0) {",
      teste="test_G7_OneWeiOutput_BoundaryPasses"),
 # The joint the whole hook argument stands on. The sieve reads `leg.hooks`; the swap executes
 # `key.hooks`; one assignment binds them. Before test/V4SievedHookIsTheExecutedHook.t.sol this
 # mutant survived the ENTIRE suite - measured 2026-09-04: 1002 passed, 1 failed, and the one
 # was the new test. Every V4 mock in the corpus declares the pool key parameter unnamed and
 # throws it away, and the artefact standing in for this property was a lexical census.
 dict(nome="V4 key: the executed hook is not the hook the sieve inspected",
      f="src/BlazePhoenixRouter.sol",
      old="            tickSpacing: leg.tickSpacing, hooks: leg.hooks",
      new="            tickSpacing: leg.tickSpacing, hooks: address(0)",
      teste="test_TheSievedHookIsTheOneTheSwapExecutesAgainst"),

 # FLOOR-01: the anchor goes back to "the LAST hop DECLARED" instead of "the last hop that
 # MOVED". A trailing hop carrying amountIn = 0 then anchors the floor on its own zero and
 # mulDivUp(0, ...) removes the protocol floor entirely.
 dict(nome="FLOOR-01: the floor anchors on the last DECLARED hop instead of the last that moved",
      f="src/BlazePhoenixRouter.sol",
      old="            if (hopGot != 0 && route.hops[h].tokenOut == tokenOut)",
      new="            if (h + 1 == route.hops.length)",
      teste="test_TrailingHopThatMovesNothingCannotZeroTheProtocolFloor"),

 # FLOOR-02: the leg count goes back to the DECLARED legs of the hop instead of the executed
 # mask, so padding with zero-amount legs shaves FLOOR_PER_LEG_BPS each.

 # WIDENING mutants. Measured 2026-09-04 over this register: 33 entries neutralise a guard, 21
 # tighten one, and only 17 widen - exactly one adds an alternative with `||`. "Absence read as
 # permission" is the axis this project named, and the corpus barely exercised it. These two add
 # the door rather than remove it, which is the direction a real mistake takes.
 dict(nome="widening: onlyRouter admits any operator (the router door stops being one address)",
      f="src/BlazePhoenixHub.sol",
      old="    modifier onlyRouter()   { _auth(msg.sender == _store().router); _; }",
      new="    modifier onlyRouter()   { _auth(msg.sender == _store().router || _store().operator[msg.sender]); _; }",
      teste="test_AnOperatorIsRefusedAtTheRouterDoor"),
 dict(nome="widening: onlyAdmin admits any operator (the curator's grow-only power spreads)",
      f="src/BlazePhoenixHub.sol",
      old="    modifier onlyAdmin()    { _auth(msg.sender == _store().admin); _; }",
      new="    modifier onlyAdmin()    { _auth(msg.sender == _store().admin || _store().operator[msg.sender]); _; }",
      teste="test_AnOperatorIsRefusedAtTheAdminDoor"),
 # The ceiling itself. Raising it leaves every existing test green - the one that names it
 # builds a 61-hop route and swallows the result with a bare expectRevert, and 61 > 60.
 dict(nome="MAX_HOPS: the route-length ceiling is raised and nothing notices",
      f="src/BlazePhoenixRouter.sol",
      old="    uint8   internal constant MAX_HOPS          = 3;",
      new="    uint8   internal constant MAX_HOPS          = 4;",
      teste="test_FourHopsIsPastTheCeilingAndRefused"),
 # FLOOR-02, closed 2026-09-04. The shave came from the DECLARED leg count; four zero-amount
 # legs bought 800 bps of floor for the price of calldata. It now comes from the concentration
 # of the trade across legs (Core.legShaveBps). This mutant puts the count back.
 dict(nome="FLOOR-02: the leg shave counts DECLARED legs again instead of their concentration",
      f="src/BlazePhoenixRouter.sol",
      old="        uint256 floorBps  = BPC.ironFloorBpsShv(avgImpact, legShv, 0);",
      new="        uint256 floorBps  = BPC.ironFloorBps(avgImpact, declaredLegs, 0);",
      teste="test_PaddedZeroAmountLegsCannotLowerTheProtocolFloor"),
 dict(nome="OX-05 (High): the leg-token gate stops checking the leg's INPUT token",
      f='src/BlazePhoenixRouter.sol',
      old='                if (legIn != hop.tokenIn || legOutRaw != hop.tokenOut) revert RouterE(3);',
      new='                if (legOutRaw != hop.tokenOut) revert RouterE(3); // MUTANT',
      teste='test_DivergentLegIn_DrainsStrandedBalance'),
 dict(nome='P1 NetGakarot (High): hop 0 stops capping the measured input to the committed sum',
      f='src/BlazePhoenixRouter.sol',
      old='            if (h == 0 && scaleNum > scaleDen) scaleNum = scaleDen;',
      new='            scaleNum; // MUTANT',
      teste='test_Router_ExecutesCutRoute_WithoutForceFeeding'),
 dict(nome="REC-A (High): the exact pass stops clamping hop 0's carry to the planned input",
      f='src/BlazePhoenixQuoter.sol',
      old='            if (h == 0 && carry > plannedIn) carry = plannedIn;',
      new='            carry; // MUTANT',
      teste='test_ExactQuoteMustNotOverstateDeliverable'),
 dict(nome='F-B: the concentrated arm stops capping depth by the mass the pool holds',
      f='src/BlazePhoenixRouter.sol',
      old='                        if (held < depth) depth = held;',
      new='                        held; // MUTANT',
      teste='test_ConcentratedDepthIsTheDeclaredL_NotThePhysicalMass'),
 dict(nome='REG-03: the V4 registry row goes back to the DECLARED pool',
      f='src/BlazePhoenixRouter.sol',
      old='                        : BPC.computeV4PoolId(t0, t1, leg.fee, leg.tickSpacing, leg.hooks);',
      new='                        : bytes32(uint256(uint160(leg.pool))); // MUTANT',
      teste='test_V4LegDeclaredPoolIsNeverConfirmed'),
 dict(nome='BP-15: hops stop having to chain',
      f='src/BlazePhoenixRouter.sol',
      old='                if (hop.tokenIn != route.hops[h - 1].tokenOut) revert RouterE(3);',
      new='                // MUTANT',
      teste='test_Discontinuous_StrandedTokenHop_RevertsRouterE3'),
 dict(nome='D1 / W4-05: the Solidly fallback fee loses its ceiling',
      f='src/BlazePhoenixCore.sol',
      old='        fee = (cfgFee == 0 || cfgFee > V2_FEE_CEILING_BPS) ? 30 : cfgFee;',
      new='        fee = cfgFee == 0 ? 30 : cfgFee; // MUTANT',
      teste='test_DeclaredFeeAboveCeilingCannotDeflateTheSolidlyQuote'),
 dict(nome='duxun A4: claimV4 stops asking _canInsert for the eviction margin',
      f='src/BlazePhoenixHub.sol',
      old='        if (!_canInsert($.pairKeys[s0][s1], depthTok, _pairBridged($, s0, s1))) return key;',
      new='        // MUTANT',
      teste='test_ClaimV4_FullPair_ThinClaimBelowMarginDoesNotEvict'),
 dict(nome='Quoter callback: the manager-only check on unlockCallback is gone',
      f='src/BlazePhoenixQuoter.sol',
      old='        if (msg.sender != mgr) revert QuoterE(6);',
      new='        // MUTANT',
      teste='test_QuoterUnlockCallback_RevertsWhenNotV4Manager'),
 dict(nome="S2b: seedPool admits a hook that addV4 would refuse",
      f="src/BlazePhoenixHub.sol",
      old="        if (hooks != address(0) && !_store().hookAllowed[hooks]) revert HubE(8);",
      new="        // MUTANT",
      teste="test_SeedPoolRefusesAnUnlistedHook"),
    dict(nome='FOT-01 door: the Permit2 pull stops noting the measured net ratio', f='src/BlazePhoenixRouter.sol', old='        if (received != amountIn) _noteFot(BPC.mulDiv(received, BPC.BPS, amountIn));\n        // Tokens are now on the Router; skip the user-pull in the core path.', new='        // MUTANT\n        // Tokens are now on the Router; skip the user-pull in the core path.', teste='test_Permit2Door_AsymTax25_NominalFloorWouldRefuse_MeasuredRepriceSettles'),
    dict(nome="PIN-01 Solver side: the per-stage leg budget widens past the executor's mirror", f='src/BlazePhoenixSolver.sol', old='    uint8   internal constant MAX_LEGS_PER_STAGE   = 4;', new='    uint8   internal constant MAX_LEGS_PER_STAGE   = 6;', teste='test_Seam2_SolverMaxSplit_ExecutesThroughRouter'),
    dict(nome="REG-01: the registry fee comes from calldata again instead of the pool's shape", f='src/BlazePhoenixHub.sol', old='            feeReg = isConc ? (dynShape ? 0 : BPC.getV3Fee(pool)) : 0;', new='            feeReg = fee;', teste='test_FeeForjadaNoCalldataNaoEntraNoRegisto'),
]

def run(t):
    r = subprocess.run(["forge","test","--match-test",t],
                       capture_output=True, text=True,
                       env={**os.environ,"FOUNDRY_PROFILE":"release"})
    return r.returncode == 0, r.stdout + r.stderr


def artefact_fingerprint():
    """sha256 of each shipped contract's DEPLOYED bytecode.

    A mutant is a claim about the artefact, not about the source. A source edit the optimiser
    folds away compiles to a byte-identical object: the paired test then passes for the same
    reason it always passed, the mutant is scored DECORATIVE, and the verdict is about nothing.
    The reverse is worse - a mutant scored killed while the artefact never moved would be
    counted as evidence for a guard the run never exercised.

    So the guard now reads what decides. Byte-identical artefact means the mutant is inert and
    its verdict is discarded rather than reported. (Owner's point, 2026-09-04: run the mutants
    against the bytecode too, or there is no certainty.)"""
    out = {}
    for c in ("Core", "Quoter", "Solver", "Router", "Hub"):
        f = os.path.join("out", f"BlazePhoenix{c}.sol", f"BlazePhoenix{c}.json")
        if not os.path.exists(f):
            return {}
        art = json.load(open(f))
        # Creation AND runtime: a constant used only by a constructor (PERMIT2_DEFAULT) lives
        # in the creation object alone, and a runtime-only hash is blind to a mutant on it.
        obj = art.get("bytecode", {}).get("object", "") + "|" + art.get("deployedBytecode", {}).get("object", "")
        out[c] = hashlib.sha256(obj.encode()).hexdigest()[:16]
    return out


def baseline():
    """Which paired tests are GREEN before anything is mutated.

    Killing a mutant is a two-sided claim - the test passed, then the mutation made it fail -
    and only the second side was ever checked here. Any test that is red for a reason of its
    own scores every mutant pinned to it as killed, for free and for ever, and this repository
    has carried a red test for weeks without noticing (two, in the fork job, found on
    2026-09-04). Today no mutant is pinned to one: all 151 paired names exist, resolve to
    exactly one test each, and none lives in test/fork/. That is a fact about today, not a
    property, which is why it is now measured on every run instead of assumed.

    One suite run, in the same profile the mutants use, so the baseline and the verdict cannot
    disagree about which binary they are talking about."""
    r = subprocess.run(["forge", "test"], capture_output=True, text=True,
                       env={**os.environ, "FOUNDRY_PROFILE": "release"})
    out = r.stdout + r.stderr
    green = set(re.findall(r"\[PASS\]\s+(\w+)", out))
    red = set(re.findall(r"\[FAIL[^\]]*\]\s+(\w+)", out))
    return green, red, out

def main():
    falhas = []
    green, red, _ = baseline()
    pristine = artefact_fingerprint()
    inert = []
    unseen = {m["teste"] for m in M} - green - red
    if red & {m["teste"] for m in M}:
        for t in sorted(red & {m["teste"] for m in M}):
            falhas.append(f"BASELINE RED: '{t}' already fails with no mutation, so every mutant "
                          f"paired with it scores as killed for free and proves nothing.")
            print(f"  BASELINE RED  {t}")
    if unseen:
        for t in sorted(unseen):
            falhas.append(f"BASELINE MISSING: '{t}' appeared as neither PASS nor FAIL in the "
                          f"baseline run, so whether it can fail at all is unknown.")
            print(f"  BASELINE ?    {t}")
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
            fp = artefact_fingerprint()
            if pristine and fp and fp == pristine:
                # The source moved and the artefact did not. Whatever the test did, it did not
                # do it because of this mutant.
                inert.append(f"[{i}] {m['nome']}: INERT - the deployed bytecode is byte-identical "
                             f"to pristine, so this mutant exercises nothing.")
                print(f"  [{i}] INERT        {m['nome']}  (artefact unchanged)")
            elif ok:
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
    if inert:
        print("INERT MUTANTS (the artefact never moved, so their verdict means nothing):")
        for f in inert: print("  -", f)
        falhas.extend(inert)
    if falhas:
        print("GUARDAS SEM VIGIA:"); [print("  -", f) for f in falhas]
        sys.exit(1)
    print(f"{len(M)}/{len(M)} guardas com teste que os apanha, "
          f"all green at baseline ({len(green)} passing tests).")

if __name__ == "__main__":
    main()
