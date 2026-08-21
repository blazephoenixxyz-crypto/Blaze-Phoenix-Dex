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
      old="            if (bound != 0 && got < BPC.mulDiv(bound, LEG_FLOOR_BPS, BPC.BPS)) revert RouterE(5);",
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
      old="        if (sp == 0) return 0;",
      new="        if (sp == 0) return uint256(liq); // MUTANTE",
      teste="test_NoPriceMeansNoDepth"),
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
 dict(nome="hub: o portao de kinds na SEGUNDA porta de registo",
      f="src/BlazePhoenixHub.sol",
      old="        if (((KINDS_ROUTABLE >> kind) & 1) == 0) return;",
      new="        // MUTANTE",
      teste="test_RecordSwapRejectsExcisedKind"),
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
