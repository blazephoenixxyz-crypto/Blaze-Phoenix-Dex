#!/usr/bin/env python3
"""Mutants of build_cases.py, g8.py and g8-pool-tests.yml: each one must turn its test red.
Run: python3 -I tools/g8-pool-tests/mutants_g8.py (offline, no RPC, no key).

Every mutant is applied alone in a temporary tree (tools/g8-pool-tests with bridges.tsv, a copy of
tools/g7-gas-campaign without state/prereg/site, .github/workflows/g8-pool-tests.yml) and the
named test runs there; a GREEN! line is a survivor and fails the run. BADPAT means the pattern
is not found exactly once: the mutant list is stale, fix it before trusting the green."""
import os
import shutil
import subprocess
import sys
import tempfile

SRC = os.path.dirname(os.path.abspath(__file__))
G7 = os.path.join(SRC, "..", "g7-gas-campaign")
YML = os.path.join(SRC, "..", "..", ".github", "workflows", "g8-pool-tests.yml")

# (test id, old, new[, file]); the file defaults to build_cases.py
M = [
 ("Cases.test_top_pool_per_family_is_the_deepest", 'v > bs.liq(best[r["family"]])', 'v < bs.liq(best[r["family"]])'),
 ("Cases.test_rows_without_liq_are_not_ranked", "        v = bs.liq(r)\n        if v is None:\n            continue\n", "        v = bs.liq(r) or 0\n"),
 ("Cases.test_gate_pool_reuses_the_g7_stratum_or_is_not_covered", "                if not g:\n", "                if False:\n"),
 ("Cases.test_exotic_bridge_seeds_the_deepest_non_gate_pool_alone", "return max(ok, key=bs.liq) if ok else None", "return ok[0] if ok else None"),
 ("Cases.test_exotic_bridge_seeds_the_deepest_non_gate_pool_alone", '"xb-%s-%s-%s" % (fam, sym, x)', '"xb-%s-%s-%s" % (fam, sym, x[:10])'),
 ("Cases.test_via_bridge_seeds_both_hop_pools", "r, x, y, [p1, p2], fam)", "r, x, y, [p1], fam)"),
 ("Cases.test_pair_without_a_common_bridge_is_not_covered", "                if not common:\n", "                if False:\n"),
 ("Cases.test_chain_without_a_bridge_list_has_no_bridge_cases", "        if br is None:\n            notcov.append", "        if False:\n            notcov.append"),
 ("Cases.test_chain_without_a_bridge_list_has_no_bridge_cases", 'if r.get("address", "").startswith("0x") and len(r["address"]) == 42:', "if True:"),
 ("Cases.test_amounts_are_dust_mid_deep", "STEPS = (5, 3, 1)", "STEPS = (5, 3, 2)"),
 ("Cases.test_spec_copies_window_and_modes_from_g7", 'COPY = ("window", "ages", "mf_ages",', 'COPY = ("window", "ages",'),
 ("Cases.test_bridges_tsv_matches_deploy_addbridge", "        hub.addBridge(0xc6911796042b15d7Fa4F6CDe69e245DdCd3d9c31); // VIRTUAL (pool token, 18 decimals; owner decision 13/11)\n", "", "../g7-gas-campaign/G7Deploy.s.sol"),
 ("Draws.test_both_directions_every_amount", "for fwd in (True, False):", "for fwd in (True,):", "g8.py"),
 ("Draws.test_seed_fixes_the_block", "b, idx = rng.randint(b0, b1), 0", "b, idx = b0, 0", "g8.py"),
 ("Report.test_per_case_line_counts_only_ok_rows", 'ok = [r for r in rs if r["outcome"] == "ok"]', "ok = rs", "g8.py"),
 ("Report.test_per_case_split_has_n_p50_p95_per_ms_case", '== (cn, st["id"], k) and r["outcome"] == "ok"]', '== (cn, st["id"], k)]', "g8.py"),
 ("Report.test_per_case_split_has_n_p50_p95_per_ms_case", "str(g7.pct(v, 95))", "str(g7.pct(v, 50))", "g8.py"),
 ("Workflow.test_dispatch_only_masked_key_and_g8_commands", '          echo "::add-mask::$DRPC_KEY"\n', "", "g8-pool-tests.yml"),
]


def tree():
    root = tempfile.mkdtemp()
    d = os.path.join(root, "tools", "g8-pool-tests")
    os.makedirs(d)
    for f in ("g8.py", "build_cases.py", "test_g8.py", "bridges.tsv"):
        shutil.copy(os.path.join(SRC, f), d)
    shutil.copytree(G7, os.path.join(root, "tools", "g7-gas-campaign"),
                    ignore=shutil.ignore_patterns("__pycache__", "state", "prereg", "site"))
    w = os.path.join(root, ".github", "workflows")
    os.makedirs(w)
    shutil.copy(YML, w)
    return root, d, w


fail = 0
for tid, old, new, *tgt in M:
    root, d, w = tree()
    name = tgt[0] if tgt else "build_cases.py"
    p = os.path.join(w if name.endswith(".yml") else d, name)
    s = open(p).read()
    if s.count(old) != 1:
        print("BADPAT", tid, s.count(old)); fail += 1; shutil.rmtree(root); continue
    open(p, "w").write(s.replace(old, new))
    r = subprocess.run([sys.executable, "-I", "-W", "ignore", os.path.join(d, "test_g8.py"), tid],
                       capture_output=True, text=True, timeout=120)
    red = r.returncode != 0
    print(("RED " if red else "GREEN!") + "\t" + tid)
    fail += 0 if red else 1
    shutil.rmtree(root)
print("survivors/bad:", fail, "of", len(M))
sys.exit(1 if fail else 0)
