#!/usr/bin/env python3
"""Assertion locality: does the test paired with a mutant NAME what the mutant changes?

WHAT THIS IS NOT. It is tempting to call this "observable coverage" - the criterion that asks
whether an assertion actually observes the mutated state. It is not that, and calling it that
would overstate it. Observation is a dynamic property; this is a static, textual screen, and
the difference matters because the commonest way for a test to observe a mutation is through a
value that carries a DIFFERENT NAME by the time it is asserted. A mutation to a fee-charge
counter is observed perfectly well by an assertion on a delivered balance.

WHAT IT MEASURES. For each mutant, whether the paired test's assertions mention any symbol the
mutated line touches:

  LOCAL      an assertion names a symbol the mutation touches - the test asserts AT the change
  NEARBY     the test names the symbol outside its assertions - the state is reached, but what
             is asserted about it is expressed in other terms
  DISTANT    nothing in the test names anything the mutation touches - the red, if it comes,
             comes through propagation

A DISTANT pair is not a defect. An end-to-end test SHOULD be distant: that is what end-to-end
means. The false-positive rate of reading DISTANT as "bad" is high and is not estimated here.

WHAT IT IS FOR. Two things, and only these:

  1. The RATIO is a shape measurement of the guard as a whole. A guard that is entirely LOCAL
     is a unit-test guard and will miss composition; one that is entirely DISTANT cannot tell
     you WHICH guard refused, only that something did. Watching the ratio move across commits
     says something about the guard's character that a mutation score cannot.
  2. The DISTANT list is a reading list, not a finding list. The pairs worth a human minute are
     those where the paired test is ALSO a unit test of the mutated symbol and still does not
     assert on it - which this screen surfaces and cannot itself decide.

Anyone reporting the ratio as a coverage claim is reporting something this file does not
measure.
"""
import json, os, re, sys, glob

ROOT = sys.argv[1] if len(sys.argv) > 1 else "."
ns = {}
exec(open(os.path.join(ROOT, ".github/scripts/mutants.py")).read().split("def run(")[0], ns)
M = ns["M"]

tests = {}
for p in glob.glob(os.path.join(ROOT, "test", "**", "*.t.sol"), recursive=True):
    src = open(p).read()
    for m in re.finditer(r"function\s+(test\w*|invariant_\w*|check_\w*)\s*\(", src):
        i = src.find("{", m.end())
        if i < 0: continue
        d, j = 0, i
        while j < len(src):
            if src[j] == "{": d += 1
            elif src[j] == "}":
                d -= 1
                if d == 0: break
            j += 1
        tests.setdefault(m.group(1), []).append(src[i:j])

STOP = {"if", "else", "return", "uint256", "uint", "int256", "address", "bool", "bytes32",
        "memory", "storage", "calldata", "true", "false", "new", "for", "while", "MUTANT",
        "unchecked", "revert", "emit", "require", "assert", "public", "private", "internal"}

def symbols(line):
    return {s for s in re.findall(r"[A-Za-z_]\w*", line) if s not in STOP and len(s) > 2}

grades = {"LOCAL": 0, "NEARBY": 0, "DISTANT": 0, "NO TEST BODY": 0}
unseen = []
for i, m in enumerate(M, 1):
    bodies = tests.get(m["teste"], [])
    if not bodies:
        grades["NO TEST BODY"] += 1
        unseen.append((i, m["teste"], "test body not found"))
        continue
    touched = symbols(m["old"]) | symbols(m["new"])
    body = "\n".join(bodies)
    asserts = " ".join(re.findall(r"assert\w*\([^;]*;", body))
    if any(re.search(r"\b%s\b" % re.escape(s), asserts) for s in touched):
        grades["LOCAL"] += 1
    elif any(re.search(r"\b%s\b" % re.escape(s), body) for s in touched):
        grades["NEARBY"] += 1
    else:
        grades["DISTANT"] += 1
        unseen.append((i, m["teste"], m["nome"][:70]))

tot = len(M)
print(f"mutants                       : {tot}")
for k in ("LOCAL", "NEARBY", "DISTANT", "NO TEST BODY"):
    print(f"  {k:14}              : {grades[k]}")
print(f"assertion locality (LOCAL/all): {grades['LOCAL']}/{tot} = {grades['LOCAL']/tot:.3f}")
if unseen:
    print("\nDISTANT pairs - a reading list, not a finding list:")
    for i, t, n in unseen[:40]:
        print(f"  [{i}] {t}  -- {n}")
json.dump({"mutants": tot, **{k.lower().replace(' ', '_'): v for k, v in grades.items()},
           "locality_ratio": round(grades["LOCAL"] / tot, 4) if tot else 0.0},
          open(os.path.join(ROOT, "assurance-observable.json"), "w"), indent=1)
