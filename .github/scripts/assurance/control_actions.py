#!/usr/bin/env python3
"""Control actions and their unsafe forms - a hazard screen in the STPA shape.

STPA (Leveson) asks, of each control action a system offers, four questions: is a hazard
caused by NOT providing it, by providing it, by providing it at the wrong time or out of
order, or by stopping it too soon. The value of the framing for a contract is that it starts
from the CONTROL SURFACE rather than from a list of known bug patterns, so it can name a
hazard nobody had a category for.

Only two of the four questions are decidable by reading source and tests, and this script is
honest about which:

  REFUSAL   is there a test that names this action and asserts it is REFUSED - the "provided
            when it should not be" arm? Detected by a test naming the function together with
            an expected revert.
  LIFECYCLE is there a test that names this action in a post-renunciation or paused world -
            the "stopped too soon / applied too long" arm? A permission that outlives the
            control plane is this system's sharpest hazard shape, because nothing can answer
            it afterwards.

The other two arms - hazards from the action never being taken, and from ordering between
actions - are not textual properties and are argued in docs/assurance/ASSURANCE.md rather
than counted here. A screen that pretended to count them would be measuring its own regex.

Output is a matrix over control actions. A row with neither column is not a defect; it is a
row nobody has written the argument for.
"""
import re, os, sys, glob, json

ROOT = sys.argv[1] if len(sys.argv) > 1 else "."
STATE_CHANGING = re.compile(
    r"function\s+(\w+)\s*\([^)]*\)\s*(?:external|public)(?![^{;]*\b(?:view|pure)\b)[^{;]*\{")

actions = []
for p in sorted(glob.glob(os.path.join(ROOT, "src", "*.sol"))):
    src = open(p).read()
    src = re.sub(r"/\*.*?\*/", " ", src, flags=re.S)
    src = "\n".join(l.split("//")[0] for l in src.splitlines())
    for m in STATE_CHANGING.finditer(src):
        name = m.group(1)
        if name.startswith("_"): continue
        head = src[m.start():m.end()]
        mods = [x for x in ("onlyAdmin", "onlyControl", "onlyOperator", "onlyRouter",
                            "whenLive", "nrEntrant") if x in head]
        actions.append({"contract": os.path.basename(p), "action": name, "guards": mods})

tests = {}
for p in glob.glob(os.path.join(ROOT, "test", "**", "*.t.sol"), recursive=True):
    tests[p] = open(p).read()
alltests = "\n".join(tests.values())

REVERT = re.compile(r"expectRevert|vm\.expectPartialRevert|try\s+\w+\.")
LIFE   = re.compile(r"renounceControl|setPaused\s*\(\s*true")

rows = []
for a in actions:
    # `router.f{value: x}(...)` puts a call-option block between the name and the paren.
    # The first version of this line missed it and reported a fully tested native entry
    # point as having no tests at all - a false negative in the instrument, caught only
    # by checking it against a case already known to be covered.
    pat = r"\.%s\s*(?:\{[^}]*\})?\s*\(" % re.escape(a["action"])
    named = [t for t in tests.values() if re.search(pat, t)]
    refusal   = any(REVERT.search(t) for t in named)
    lifecycle = any(LIFE.search(t)   for t in named)
    rows.append({**a, "tests_naming_it": len(named), "refusal": refusal, "lifecycle": lifecycle})

w = max((len(r["action"]) for r in rows), default=10)
print(f"{'CONTROL ACTION':{w}}  {'tests':>5}  refusal  lifecycle  guards")
print("-" * (w + 46))
for r in sorted(rows, key=lambda r: (r["refusal"] + r["lifecycle"], r["action"])):
    print(f"{r['action']:{w}}  {r['tests_naming_it']:5}  "
          f"{'yes' if r['refusal'] else ' - ':^7}  {'yes' if r['lifecycle'] else ' - ':^9}  "
          f"{','.join(r['guards']) or '(none)'}")

n = len(rows)
ref = sum(1 for r in rows if r["refusal"])
lif = sum(1 for r in rows if r["lifecycle"])
print(f"\ncontrol actions               : {n}")
print(f"  refusal arm exercised       : {ref}/{n} = {ref/n:.3f}" if n else "")
print(f"  lifecycle arm exercised     : {lif}/{n} = {lif/n:.3f}" if n else "")
json.dump({"actions": n, "refusal": ref, "lifecycle": lif, "rows": rows},
          open(os.path.join(ROOT, "assurance-control-actions.json"), "w"), indent=1)
