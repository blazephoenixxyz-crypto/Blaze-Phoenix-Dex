#!/usr/bin/env python3
"""Relational consistency: every quantity with two producers must have a test that ties them.

A quantity computed in two places is a standing invitation for one of them to change alone.
The register in docs/assurance/relational.json names both producers and the test that asserts
they agree; this script checks that the symbols and the test still exist, and reports the
fraction of pairs that are tied.

The metric is deliberately reported as tied/total rather than as a percentage alone: widening
the register lowers the ratio until the new rows are answered, which is the behaviour you want
from a completeness measure. A register that only lists solved rows measures nothing.
"""
import json, os, re, sys, glob

ROOT = sys.argv[1] if len(sys.argv) > 1 else "."
src  = "\n".join(open(p).read() for p in sorted(glob.glob(os.path.join(ROOT, "src", "*.sol"))))
test = "\n".join(open(p).read() for p in
                 sorted(glob.glob(os.path.join(ROOT, "test", "**", "*.t.sol"), recursive=True)))

reg = json.load(open(os.path.join(ROOT, "docs/assurance/relational.json")))["pairs"]
broken, tied = [], 0
for r in reg:
    q = r["quantity"]
    for k in ("producer_a", "producer_b"):
        sym = r[k]
        if not re.search(r"\b%s\b" % re.escape(sym), src):
            broken.append(f"{q}: producer '{sym}' is no longer in src/")
    if r["status"] == "tied":
        tied += 1
        t = r.get("test")
        if not t:
            broken.append(f"{q}: status 'tied' with no test named")
        elif not re.search(r"\b%s\b" % re.escape(t), test):
            broken.append(f"{q}: test '{t}' is no longer in test/")
    elif r["status"] != "open":
        broken.append(f"{q}: unknown status '{r['status']}'")

total = len(reg)
print(f"quantities with two producers : {total}")
print(f"  tied by a named test        : {tied}")
print(f"  open                        : {total - tied}")
print(f"relational consistency        : {tied}/{total} = {tied/total:.3f}" if total else "")
print(f"claims that no longer hold    : {len(broken)}")
for b in broken:
    print("  BROKEN:", b)
json.dump({"pairs": total, "tied": tied, "open": total - tied,
           "ratio": round(tied / total, 4) if total else 0.0, "broken_claims": broken},
          open(os.path.join(ROOT, "assurance-relational.json"), "w"), indent=1)
sys.exit(1 if broken else 0)
