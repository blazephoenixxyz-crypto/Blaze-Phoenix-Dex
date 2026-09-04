#!/usr/bin/env python3
"""The denominator that comes before the threat catalogue.

Everything else here starts from a class of published exploit. That denominator is LAGGING: it
contains what has already happened to somebody, and it cannot answer the question that matters
most - what if a property was never written because nobody had thought of the threat?

An asset-by-loss matrix is the leading denominator. It is enumerable from the DESIGN: what does
this system hold or decide that anyone could lose, and in how many ways can a thing be lost?
Every cell must resolve to a threat class that already exists, to an explicit exemption with a
reason, to not-applicable, or be recorded OPEN.

The count of OPEN cells is the number this file exists to produce. It is not a defect count. It
is the number of places where the design admits a loss is conceivable and nothing in the chain
below answers it yet - which is a different and more useful thing to know than how many known
exploit classes are covered, because a taxonomy cannot contain what nobody has published.

Checks performed:
  * every threat id named in a cell exists in threats.json;
  * a covered cell names at least one threat;
  * an out-of-scope or not-applicable cell carries a rationale;
  * an open cell carries a note saying what is unresolved.

Usage: python3 asset_closure.py <repo_root>
"""
import json, os, sys

ROOT = sys.argv[1] if len(sys.argv) > 1 else "."
A = json.load(open(os.path.join(ROOT, "docs/assurance/assets.json")))
T = {c["id"] for c in json.load(open(os.path.join(ROOT, "docs/assurance/threats.json")))["classes"]}

modes = list(A["loss_modes"])
broken, counts = [], {}
for asset in A["assets"]:
    name = asset["asset"]
    for m in modes:
        cell = asset["cells"].get(m)
        if cell is None:
            broken.append(f"{name} x {m}: no cell at all"); continue
        st = cell.get("status")
        counts[st] = counts.get(st, 0) + 1
        if st == "covered":
            ts = cell.get("threats") or []
            if not ts:
                broken.append(f"{name} x {m}: covered with no threat named")
            for t in ts:
                if t not in T:
                    broken.append(f"{name} x {m}: names threat '{t}', which is not in threats.json")
        elif st in ("out-of-scope", "not-applicable"):
            if not cell.get("rationale"):
                broken.append(f"{name} x {m}: {st} with no rationale")
        elif st == "open":
            if not cell.get("note"):
                broken.append(f"{name} x {m}: open with nothing said about what is unresolved")
        else:
            broken.append(f"{name} x {m}: unknown status '{st}'")

w = max(len(a["asset"]) for a in A["assets"])
print(f"{'ASSET':{w}}  " + "  ".join(f"{m[:9]:>9}" for m in modes))
print("-" * (w + 11 * len(modes)))
SHORT = {"covered": "covered", "out-of-scope": "exempt", "not-applicable": "n/a", "open": "OPEN"}
for asset in A["assets"]:
    row = "  ".join(f"{SHORT.get(asset['cells'][m]['status'], '?'):>9}" for m in modes)
    print(f"{asset['asset']:{w}}  {row}")

tot = sum(counts.values())
print(f"\ncells (assets x loss modes)     : {tot}")
for k in ("covered", "out-of-scope", "not-applicable", "open"):
    print(f"  {k:16}             : {counts.get(k, 0)}")
print(f"claims that no longer hold     : {len(broken)}")
for b in broken:
    print("  BROKEN:", b)
print("\nOPEN is not a defect count. It is where the design admits a loss is conceivable and")
print("nothing below in the chain answers it yet - which a taxonomy of published exploits")
print("cannot tell you, because it contains only what has already happened to somebody.")
json.dump({"cells": tot, **counts, "broken_claims": broken},
          open(os.path.join(ROOT, "assurance-asset-closure.json"), "w"), indent=1)
sys.exit(1 if broken else 0)
