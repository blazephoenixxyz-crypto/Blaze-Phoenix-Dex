#!/usr/bin/env python3
"""Threat-class coverage: check that every claim in the catalogue still points at code.

The catalogue (docs/assurance/threats.json) states, for each class of exploit observed in
the public record, either the guard that refuses it or the reason it is out of scope. This
script refuses to take those statements on trust:

  * a `blocked` class must name a guard SYMBOL that still exists in src/;
  * if it names a test, that test must still exist in test/;
  * an `out-of-scope` class must carry a rationale, and must NOT name a guard - claiming
    both a guard and an exemption is the shape of a claim written to be unfalsifiable.

Symbols, never line numbers: a line number is valid only against a pinned revision, and a
stale anchor is a false claim dressed as evidence.

Exit code 1 on any broken claim. Prints a machine-readable summary on stdout.
"""
import json, os, re, sys, glob

ROOT = sys.argv[1] if len(sys.argv) > 1 else "."
CAT  = os.path.join(ROOT, "docs/assurance/threats.json")

src  = "\n".join(open(p).read() for p in sorted(glob.glob(os.path.join(ROOT, "src", "*.sol"))))
test = "\n".join(open(p).read() for p in
                 sorted(glob.glob(os.path.join(ROOT, "test", "**", "*.t.sol"), recursive=True)))

cat = json.load(open(CAT))
classes = cat["classes"]

broken, blocked, scoped = [], 0, 0
for c in classes:
    cid, status = c["id"], c["status"]
    if status == "blocked":
        blocked += 1
        g = c.get("guard")
        if not g:
            broken.append(f"{cid}: status 'blocked' with no guard named"); continue
        if not re.search(r"\b%s\b" % re.escape(g), src):
            broken.append(f"{cid}: guard symbol '{g}' is no longer in src/")
        t = c.get("test")
        if t and not re.search(r"\b%s\b" % re.escape(t), test):
            broken.append(f"{cid}: test '{t}' is no longer in test/")
    elif status == "out-of-scope":
        scoped += 1
        if not c.get("rationale"):
            broken.append(f"{cid}: out of scope with no rationale")
        if c.get("guard"):
            broken.append(f"{cid}: claims BOTH a guard and an exemption")
    else:
        broken.append(f"{cid}: unknown status '{status}'")

considered = blocked + scoped
index = blocked / considered if considered else 0.0

print(f"threat classes considered : {considered}")
print(f"  refused by a named guard: {blocked}")
print(f"  out of scope, with cause: {scoped}")
print(f"coverage index            : {index:.3f}")
print(f"claims that no longer hold: {len(broken)}")
for b in broken:
    print("  BROKEN:", b)

# The index is a floor on what has been CONSIDERED, never a ceiling on what exists. It is
# reported next to the size of the catalogue precisely so that widening the catalogue -
# which lowers the index until the new classes are answered - is visible rather than hidden.
json.dump({"considered": considered, "blocked": blocked, "out_of_scope": scoped,
           "coverage_index": round(index, 4), "broken_claims": broken},
          open(os.path.join(ROOT, "assurance-threat-coverage.json"), "w"), indent=1)
sys.exit(1 if broken else 0)
