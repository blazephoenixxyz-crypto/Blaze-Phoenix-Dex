#!/usr/bin/env python3
"""Static check: every mutant in mutants.py must still have EXACTLY ONE target.

WHY THIS EXISTS. On 2026-09-03 a rename inside `_assembleRouteMulti`
(`totalImpactBps` -> `gateImpactBps`) silently orphaned two pre-existing mutants.
Nothing noticed, because the session that made the rename ran only the SUBSET of
mutants it had just added. A subset run cannot see a lost target in an entry it
does not run, and a lost target is not a failing test - it is a guard that
stopped being watched, reported as `ALVO PERDIDO` only when the full list runs.

This check costs a second, needs no compiler and no CI box, and is the thing to
run after ANY edit to src/. It answers one question: does every mutant still
point at a line that exists, exactly once?
"""
import os, sys
os.chdir(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
ns = {}
exec(open(".github/scripts/mutants.py").read().split("def run(")[0], ns)
M = ns["M"]
bad = []
for i, m in enumerate(M, 1):
    n = open(m["f"]).read().count(m["old"])
    if n != 1:
        bad.append((i, n, m["nome"], m["f"]))
        print(f"  [{i}] {'LOST' if n == 0 else 'AMBIGUOUS (%d matches)' % n}  {m['nome']}  in {m['f']}")
if bad:
    print(f"\n{len(bad)} of {len(M)} mutants no longer point at a unique line.")
    print("A mutant with no target is a guard nobody is watching. Update the entry to the new text.")
    sys.exit(1)
print(f"{len(M)}/{len(M)} mutants still point at exactly one line.")
