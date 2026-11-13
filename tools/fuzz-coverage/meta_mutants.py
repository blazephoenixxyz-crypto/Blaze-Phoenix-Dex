#!/usr/bin/env python3
"""Meta-mutants: the mutants of the fuzz-matrix infrastructure (the guards of the guards).

Each entry breaks one input of a guard the way a careless or motivated edit would, and names
the test of test_infra.py that must go red. Same shape as .github/scripts/mutants.py:
nome, f (repo-relative), old (must occur exactly once), new, teste.

  python3 tools/fuzz-coverage/meta_mutants.py             baseline green, then every mutant red
  python3 tools/fuzz-coverage/meta_mutants.py --check     targets only (each `old` exactly once)
  python3 tools/fuzz-coverage/meta_mutants.py --apply NOME | --restore NOME
                                                          one FORGE_M entry (fork lanes in CI)

M runs here, in Python, in seconds. FORGE_M holds the source mutants of the fork tests: the
mutation guard of ci.yml runs without an RPC key, where a fork test skips and a skipped test
would let its mutant survive, so they run in .github/workflows/fuzz-mc.yml instead.
"""
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, HERE)
CELLS = "docs/assurance/fuzz-matrix/cells.tsv"
DIMS = "docs/assurance/fuzz-matrix/dimensions.tsv"
MC_PRE = "docs/prereg/mc-1113.tsv"
MC_SOL = "test/MonteCarloPreviewParity.t.sol"
WF_SOL = "test/fork/WalkForwardFidelity.t.sol"


def _reseal(rel, old_line, new_line):
    """(old, new) blocks that edit one body line of a prereg AND recompute its lock: the edit a
    careful cheater makes. The lock then agrees with the body; only the test's frozen copy of
    the lock (PREREG_LOCK in the .sol, committed before any result) can still tell."""
    import prereg
    try:
        text = open(os.path.join(ROOT, rel)).read()
    except OSError:
        return ("<missing " + rel + ">", "")
    i = text.find(old_line)
    if i < 0:
        return ("<missing line in " + rel + ">", "")
    body = text[: text.rfind("lock\t")].replace(old_line, new_line)
    return (text[i:], body[i:] + "lock\t" + prereg.lock_of(body) + "\n")


_MC3B = _reseal(MC_PRE, "const\tABS_TOL_WEI\t4\n", "const\tABS_TOL_WEI\t40\n")

M = [
    dict(nome="meta [mm-1]: a matrix line is lost",
         f=CELLS, old="mc\tamm\tv2\t-\ttestMC_SampledNeverOverpromise\tcovered\n", new="",
         teste="test_matrix_every_declared_cell_is_present"),
    dict(nome="meta [mm-2]: a seam line is lost",
         f=CELLS, old="mc\t-\t-\tSolver-Quoter\ttestMC_SampledNeverOverpromise\tcovered\n", new="",
         teste="test_matrix_every_seam_has_its_cells"),
    dict(nome="meta [mm-3]: a dimension is cut to one value",
         f=DIMS, old="hops\t1\tmin\tmc,wf\nhops\t2\tmax\tmc,wf\n", new="hops\t1\tmin\tmc,wf\n",
         teste="test_matrix_dimensions_span_min_and_max"),
    dict(nome="meta [mm-4]: a covered cell names a test that does not exist",
         f=CELLS, old="wf\tnetwork\tbase\t-\ttest_WF_QuoteNeverAboveDelivered\tcovered\n",
         new="wf\tnetwork\tbase\t-\ttest_WF_RenamedAway\tcovered\n",
         teste="test_matrix_covered_cells_name_existing_tests"),
    dict(nome="meta [mm-5]: the MC seed is chosen, not derived",
         f=MC_SOL, old="        return uint256(sha256(abi.encodePacked(PREREG_TAG, i)));\n",
         new="        return uint256(keccak256(abi.encode(0xB1A2E, i))); // MUTANT\n",
         teste="test_prereg_mc_binds_the_test"),
    dict(nome="meta [mm-6]: the MC sample count is cut below the registered N",
         f=MC_SOL, old="    uint256 internal constant N_SAMPLES = 4096;\n",
         new="    uint256 internal constant N_SAMPLES = 64; // MUTANT\n",
         teste="test_prereg_mc_binds_the_test"),
    dict(nome="meta [mm-7]: the MC prereg is edited after the results (lock left stale)",
         f=MC_PRE, old="const\tMAX_DEV_BPS\t10\n", new="const\tMAX_DEV_BPS\t50\n",
         teste="test_prereg_mc_lock_matches_body"),
    dict(nome="meta [mm-8]: the MC prereg is edited after the results and its lock recomputed",
         f=MC_PRE, old=_MC3B[0], new=_MC3B[1],
         teste="test_prereg_mc_binds_the_test"),
    dict(nome="meta [mm-9]: the WF tolerance is raised in the test, not in the prereg",
         f=WF_SOL, old="    uint256 internal constant MAX_DEV_BPS = 10;\n",
         new="    uint256 internal constant MAX_DEV_BPS = 50; // MUTANT\n",
         teste="test_prereg_wf_binds_the_test"),
    dict(nome="meta [mm-10]: the WF hard rule is relaxed by a margin",
         f=WF_SOL, old="            assertLe(pv.netOut, got, \"WF: the quote promised more than the balance delta\");\n",
         new="            assertLe(pv.netOut, got + got / 100, \"WF: the quote promised more than the balance delta\"); // MUTANT\n",
         teste="test_prereg_wf_binds_the_test"),
    dict(nome="meta [mm-11]: the WF block rule takes the first block AFTER the target",
         f="tools/fuzz-coverage/prereg.py", old="        if ts_of(mid) >= target:\n",
         new="        if ts_of(mid) > target:  # MUTANT\n",
         teste="test_prereg_wf_block_rule_takes_the_first_block_at_the_target"),
    dict(nome="meta [mm-12]: results are accepted without the registered lock",
         f="tools/fuzz-coverage/prereg.py", old="    if seen != want:\n", new="    if False:  # MUTANT\n",
         teste="test_prereg_results_must_carry_the_registered_lock"),
    dict(nome="meta [mm-13]: anvil compares the quote with itself, not with the delivered",
         f="tools/fuzz-coverage/anvil_compare.py", old="        delivered = int(r[\"delivered\"])\n",
         new="        delivered = int(r[\"net_out\"])  # MUTANT\n",
         teste="test_anvil_compare_catches_short_delivery"),
    dict(nome="meta [mm-14]: anvil reads zero measured rows as a pass",
         f="tools/fuzz-coverage/anvil_compare.py", old="    if n == 0:\n", new="    if False:  # MUTANT\n",
         teste="test_anvil_compare_refuses_zero_measured_rows"),
]

FORGE_M = [
    dict(nome="fork [wf-1]: the preview promises 50 bps more than the fee model",
         f="src/BlazePhoenixQuoter.sol",
         old="        pv.netOut       = afterFee > pv.safetyBuffer ? afterFee - pv.safetyBuffer : 0;\n",
         new="        pv.netOut       = afterFee + afterFee / 200; // MUTANT\n",
         teste="test_WF_QuoteNeverAboveDelivered"),
]


def _path(m):
    return os.path.join(ROOT, m["f"])


def check(entries):
    bad = []
    for m in entries:
        try:
            n = open(_path(m)).read().count(m["old"])
        except OSError:
            n = -1
        if n != 1:
            bad.append(f"{m['nome']}: target found {n} times in {m['f']} (need exactly 1)")
    return bad


def _unittest(teste=None):
    cmd = [sys.executable, os.path.join(HERE, "test_infra.py"), "-v"] + (["-k", teste] if teste else [])
    r = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
    return r.returncode, r.stdout + r.stderr


def run():
    bad = check(M) + check(FORGE_M)
    if bad:
        sys.exit("\n".join(bad))
    rc, out = _unittest()
    if rc != 0:
        sys.exit("baseline is not green:\n" + out[-2000:])
    survived = []
    for m in M:
        p = _path(m)
        orig = open(p).read()
        try:
            open(p, "w").write(orig.replace(m["old"], m["new"], 1))
            rc, out = _unittest(m["teste"])
        finally:
            open(p, "w").write(orig)
        killed = rc != 0 and m["teste"] in out
        print(("KILLED   " if killed else "SURVIVED ") + m["nome"] + "  <- " + m["teste"], flush=True)
        if not killed:
            survived.append(m["nome"])
    if survived:
        sys.exit(f"{len(survived)} meta-mutant(s) survived")
    print(f"{len(M)}/{len(M)} meta-mutants killed by name, baseline green.")


def _one(nome):
    for m in FORGE_M:
        if m["nome"].split("[")[1].split("]")[0] == nome or m["nome"] == nome:
            return m
    sys.exit(f"no FORGE_M entry {nome}")


if __name__ == "__main__":
    a = sys.argv[1:]
    if a[:1] == ["--check"]:
        b = check(M) + check(FORGE_M)
        print("\n".join(b) or f"{len(M) + len(FORGE_M)} targets, each exactly once.")
        sys.exit(1 if b else 0)
    if a[:1] in (["--apply"], ["--restore"]):
        m = _one(a[1])
        p = _path(m)
        t = open(p).read()
        src, dst = (m["old"], m["new"]) if a[0] == "--apply" else (m["new"], m["old"])
        if t.count(src) != 1:
            sys.exit(f"{m['nome']}: {a[0]} target not found exactly once")
        open(p, "w").write(t.replace(src, dst, 1))
        print(f"{a[0][2:]} {m['nome']}")
        sys.exit(0)
    run()
