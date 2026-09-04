#!/usr/bin/env python3
"""Does a mutant change the shipped bytecode at all?

The mutation guard asks: apply this mutant, does the paired test go red? A green suite under a
mutant is read as "the test does not watch this guard". That reading has a second possibility
underneath it, and the two look identical from the outside:

  the test does not catch the change              -> a testing defect
  there was no change to catch                    -> a DEAD STATEMENT, or a decorative mutant

This separates them, and it does so without running a single test. Apply the mutant, compile,
compare the deployed bytecode. If the artefact is byte-identical, the compiler considered the
two programs equivalent - so the mutation is invisible in the thing that deploys, and no test
that could ever be written would fail on it.

Two readings of an identical artefact, both worth having:

  the MUTANT is decorative - it edits something the optimiser removes either way, so it proves
  nothing about the guard it claims to watch and should be rewritten;
  or the SOURCE statement is dead - it survives review because it reads as a defence, and the
  compiler has already established that it changes nothing.

This is cheaper than the mutation guard per mutant (one compile, no suite) and answers a
question the guard cannot answer at all. It does not replace it: a mutant that DOES change the
bytecode still has to be killed by a named test, and only the suite can establish that.

Cost is one build per mutant, so it takes a subset by default. Pass indices to select.

Usage: python3 mutant_visibility.py <repo_root> [index ...]
"""
import json, os, re, sys, subprocess, hashlib, glob

ROOT = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else ".")
IDX  = [int(a) for a in sys.argv[2:]] or None

ns = {}
exec(open(os.path.join(ROOT, ".github/scripts/mutants.py")).read().split("def run(")[0], ns)
M = ns["M"]

def build_hashes():
    """Deployed-bytecode digest per contract, so a change anywhere is visible."""
    r = subprocess.run(["forge", "build"], cwd=ROOT, capture_output=True, text=True)
    if r.returncode != 0:
        return None
    h = {}
    for p in sorted(shipped_artefacts(ROOT)):
        try: a = json.load(open(p))
        except Exception: continue
        obj = (a.get("deployedBytecode") or {}).get("object")
        if obj:
            h[os.path.basename(p)[:-5]] = hashlib.sha256(obj.encode()).hexdigest()[:16]
    return h

base = build_hashes()
if base is None:
    print("baseline build failed - nothing to compare against"); sys.exit(1)
print(f"baseline: {len(base)} artefacts")

invisible, visible, failed = [], [], []
targets = IDX or list(range(1, min(len(M), 8) + 1))
for i in targets:
    m = M[i - 1]
    path = os.path.join(ROOT, m["f"])
    src = open(path).read()
    if src.count(m["old"]) != 1:
        failed.append((i, "target lost")); continue
    open(path, "w").write(src.replace(m["old"], m["new"]))
    try:
        h = build_hashes()
    finally:
        # restore BEFORE judging: an interrupt between here and the verdict would otherwise
        # leave a mutant glued into the tree, which has happened in this project before.
        open(path, "w").write(src)
    if h is None:
        failed.append((i, "mutant does not compile")); continue
    same = (h == base)
    (invisible if same else visible).append(i)
    print(f"[{i:3}] {'INVISIBLE' if same else 'visible  '}  {m['nome'][:66]}")

print(f"\nmutants examined              : {len(targets)}")
print(f"  change the shipped bytecode : {len(visible)}")
print(f"  INVISIBLE in the artefact   : {len(invisible)}")
print(f"  could not be judged         : {len(failed)}")
for i, why in failed:
    print(f"    [{i}] {why}")
if invisible:
    print("\nAn invisible mutant proves nothing about the guard it names: the compiler emits the")
    print("same contract with and without it. Either the mutant is decorative, or the statement")
    print("it edits is dead. Both are worth knowing and neither is a testing failure.")
json.dump({"examined": len(targets), "visible": visible, "invisible": invisible,
           "failed": [i for i, _ in failed]},
          open(os.path.join(ROOT, "assurance-mutant-visibility.json"), "w"), indent=1)
