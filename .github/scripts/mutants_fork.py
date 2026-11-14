#!/usr/bin/env python3
"""Runs M_FORK (mutants.py): the mutants whose paired tests live in test/fork/ and need an RPC.

mutants.py's own baseline is one keyless `forge test`. A fork test skips there, reads as neither
PASS nor FAIL, and every mutant pinned to it would be BASELINE MISSING. So these mutants have
their own list and this runner, which runs where the fork lane's keys are in the environment
(DRPC_KEY, and ARBITRUM_FORK_URL where the public Arbitrum endpoint does not serve the block).

One forge run per mutant, judged against EVERY test paired with it:

  KILLED       the run printed [FAIL ...] for that test
  ALIVE        the run printed [PASS] for that test
  NOT REACHED  neither (compile error, RPC, skip, timeout). Never scored as killed: a run that
               did not reach the test says nothing about the guard.

The baseline run (nothing mutated) must print [PASS] for every paired test first, or nothing is
judged: a test that is red on its own kills every mutant for free.

  FORGE_CMD           command prefix for forge (default "forge"), e.g. a wrapper that queues runs
  MUTANTS_FORK_ONLY   comma-separated 1-based indexes into M_FORK
  MUTANTS_FORK_LOGS   directory that receives each run's output, RPC secrets masked

Nothing forge prints reaches stdout: an RPC error carries the URL, and the URL carries the key.
Run from the repository root, like mutants.py."""
import importlib.util
import os
import re
import shlex
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PATH = "test/fork/AtqForkVenueOracle.t.sol"


def load():
    spec = importlib.util.spec_from_file_location("bp_mutants", os.path.join(HERE, "mutants.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod.M_FORK


def secrets():
    found = [v for k, v in os.environ.items()
             if (k == "DRPC_KEY" or k.endswith("_FORK_URL") or k.endswith("_RPC_URL")) and len(v) > 7]
    # An endpoint's last path segment is its key: masked on its own too, in case forge prints
    # the URL in another shape.
    found += [v.rstrip("/").rsplit("/", 1)[-1] for v in found if "://" in v]
    return sorted({v for v in found if len(v) > 7}, key=len, reverse=True)


def forge(tests, tag):
    cmd = shlex.split(os.environ.get("FORGE_CMD", "forge")) + [
        "test", "--match-path", PATH, "--match-test", "^(" + "|".join(tests) + r")\(", "-vv"]
    r = subprocess.run(cmd, capture_output=True, text=True)
    out = r.stdout + r.stderr
    for s in secrets():
        out = out.replace(s, "***")
    logs = os.environ.get("MUTANTS_FORK_LOGS")
    if logs:
        with open(os.path.join(logs, tag + ".log"), "w") as f:
            f.write(out)
    return out


def verdict(out, t):
    if re.search(r"^\[FAIL[^\n]*\] " + re.escape(t) + r"\(", out, re.M):
        return "KILLED"
    if re.search(r"^\[PASS\] " + re.escape(t) + r"\(", out, re.M):
        return "ALIVE"
    return "NOT REACHED"


def main():
    M = load()
    only = {int(x) for x in os.environ.get("MUTANTS_FORK_ONLY", "").split(",") if x.strip()}
    mine = [(i, m) for i, m in enumerate(M, 1) if not only or i in only]
    paired = sorted({t for _, m in mine for t in m["testes"]})
    bad = []
    base = forge(paired, "baseline")
    for t in paired:
        v = verdict(base, t)
        if v != "ALIVE":
            bad.append(f"BASELINE {'RED' if v == 'KILLED' else 'MISSING'}: '{t}' is not green with no mutation.")
            print(f"  BASELINE {'RED' if v == 'KILLED' else '?  '}  {t}", flush=True)
    if bad:
        print("NOTHING JUDGED:"); [print("  -", b) for b in bad]
        sys.exit(1)
    pairs = 0
    for i, m in mine:
        src = open(m["f"]).read()
        if src.count(m["old"]) != 1:
            bad.append(f"[{i}] {m['nome']}: the mutant target does not exist (or there are several) in {m['f']}.")
            print(f"  [{i}] TARGET LOST  {m['nome']}", flush=True)
            continue
        try:
            with open(m["f"], "w") as f:
                f.write(src.replace(m["old"], m["new"]))
            out = forge(m["testes"], f"mutant-{i}")
        finally:
            with open(m["f"], "w") as f:
                f.write(src)
        for t in m["testes"]:
            v = verdict(out, t)
            pairs += 1
            print(f"  [{i}] {v:<11}  {m['nome']}  <- {t}", flush=True)
            if v != "KILLED":
                bad.append(f"[{i}] {m['nome']}: {v} on '{t}'.")
    print()
    if bad:
        print("UNWATCHED GUARDS:"); [print("  -", b) for b in bad]
        sys.exit(1)
    print(f"{pairs}/{pairs} (mutant, fork test) pairs killed, {len(mine)} mutants of {len(M)}, "
          f"all {len(paired)} paired tests green at baseline.")


if __name__ == "__main__":
    main()
