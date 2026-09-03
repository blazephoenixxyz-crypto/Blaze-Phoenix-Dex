#!/usr/bin/env python3
"""Regime lattice: the combinations of world-state, route shape and oracle provenance that
nothing in the corpus has ever asserted in.

WHY THIS EXISTS, AND WHY THE USUAL METRICS DO NOT COVER IT. Statement, branch and condition
coverage index the CODE. Mutation indexes an injected FAULT. Property and metamorphic testing
index relations over INPUTS. None of them index the two things that decided the last defect
found here:

  * the REGIME - state a fixture fixes before the call, which no argument can vary, so a
    predicate over it never changes value inside a test;
  * the ORACLE - where the expected value came from. An assertion compared against the code's
    own output, a literal, or a helper that reuses production arithmetic is a different kind of
    evidence from one compared against an independent producer, and no coverage criterion
    distinguishes them.

A defect can therefore sit in a cell that every conventional metric reports as covered: the
line runs, the branch is taken, and the mutant on it dies - in a neighbouring cell, under the
regime the fixtures happen to share.

WHAT IT REPORTS. The cross product of the regimes in docs/assurance/regimes.json with route
shape and oracle provenance. An EMPTY cell is a combination in which no test has ever asserted
anything. That is not a bug and this script does not claim it is one; it is the list of places
where a bug could not be caught by anything currently written.

HONEST LIMITS. Membership is decided by pattern-matching test sources with comments stripped,
so a test can be filed in the wrong cell. Two failure modes are known and fixed here and are
worth stating because both produced confident wrong answers first: comments were once read as
fixture, filing a test by what its header DESCRIBED rather than what it did; and shape was
detected only when a route was built by hand, which filed every test that lets the planner
compose the route as single-hop. A cell reported as empty should be confirmed by reading before
it is acted on.

Detail goes to a gitignored artefact. The counts go to stdout. A table naming the least
exercised surfaces of a deployed contract is a reading list, and it is not published.
"""
import json, os, re, sys, glob, itertools

ROOT = sys.argv[1] if len(sys.argv) > 1 else "."
CAT  = json.load(open(os.path.join(ROOT, "docs/assurance/regimes.json")))

def strip_comments(src):
    src = re.sub(r"/\*.*?\*/", " ", src, flags=re.S)
    return "\n".join(l.split("//")[0] for l in src.splitlines())

ENTRY = (r"\.swapExactIn\(|\.swapBestExactIn\(|\.previewPlan\(|\.previewRoute\("
         r"|\.swapExactInNative\s*(?:\{[^}]*\})?\s*\(")
texts = {p: strip_comments(open(p).read())
         for p in glob.glob(os.path.join(ROOT, "test", "**", "*.t.sol"), recursive=True)}
live = {p: t for p, t in texts.items() if re.search(ENTRY, t)}

shape  = CAT["shapes"][0]
oracle = CAT["oracles"][0]
def is_shape(t):  return bool(re.search(shape["match"], t))
def is_cross(t):  return all(re.search(m, t) for m in oracle["match_all"])

empty, cells = [], 0
for reg in CAT["regimes"]:
    for state, shp, orc in itertools.product(("ON", "OFF"), ("multi", "single"), ("cross", "self")):
        cells += 1
        sel = []
        for p, t in live.items():
            if (state == "ON") != bool(re.search(reg["on"], t)):      continue
            if (shp == "multi") != is_shape(t):                        continue
            if (orc == "cross") != is_cross(t):                        continue
            sel.append(os.path.basename(p))
        if not sel:
            empty.append({"regime": reg["name"], "state": state, "shape": shp, "oracle": orc,
                          "why_the_regime_matters": reg["why"]})

n = len(CAT["regimes"])
print(f"regimes                       : {n}")
print(f"tests reaching a value door   : {len(live)}")
print(f"lattice cells                 : {cells}")
print(f"  cells with at least one test: {cells - len(empty)}")
print(f"  cells nothing asserts in    : {len(empty)}")
print(f"lattice coverage              : {(cells-len(empty))}/{cells} = {(cells-len(empty))/cells:.3f}")

# The cross-producer column under composition is the one worth naming as a SHAPE rather than as
# a list: if it is empty everywhere, the only check that compares two independent producers on a
# composed route exists solely in the default world, and every global flag switches it off.
cross_multi_on = [e for e in empty
                  if e["state"] == "ON" and e["shape"] == "multi" and e["oracle"] == "cross"]
print(f"\nregimes with no composed, cross-producer assertion when the flag is ON: "
      f"{len(cross_multi_on)}/{n}")

json.dump({"regimes": n, "cells": cells, "empty": len(empty),
           "coverage": round((cells - len(empty)) / cells, 4),
           "cross_multi_on_empty": len(cross_multi_on), "detail": empty},
          open(os.path.join(ROOT, "assurance-regime-lattice.json"), "w"), indent=1)
