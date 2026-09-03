#!/usr/bin/env python3
"""How many places in the shipped artefact push each security constant.

This repository holds a law: a quantity with more than one producer is a quantity where one
producer can change alone. The guard that enforces it greps the source for the constant's NAME.

The compiler does not see names. It sees the VALUE, and it emits it identically whether it was
written as a named constant, as a literal, or as an expression that folds to the same number. A
copy introduced by any spelling other than the declared one is invisible to a grep over source
and perfectly visible here.

So: for every constant declared in src/, count the distinct sites in the deployed bytecode that
push that immediate, and compare against how many places the source mentions its name.

  sites >> named uses    the value reaches the artefact from somewhere the name does not
  sites == 0             the constant never became an instruction - folded away, or dead

WHAT THIS IS NOT. Small values are shared by everything: 0, 1, 20, 32 and 64 are the compiler's
own vocabulary for memory layout and word arithmetic, and counting their pushes measures the
calling convention. Only constants above a threshold, and not powers of two used for masking,
carry signal. The threshold is stated in the code rather than tuned until the output looked
clean.

A high multiplicity is a QUESTION - inlining legitimately duplicates a constant across the call
sites of the function that uses it. The row worth reading is one where the artefact pushes a
value the source barely mentions.

Usage: python3 constant_multiplicity.py <repo_root>
"""
import json, os, re, sys, glob

ROOT = sys.argv[1] if len(sys.argv) > 1 else "."
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _freshness import require_fresh
require_fresh(ROOT, quiet=True)
LIB_REF = re.compile(r"__\$[0-9a-fA-F]{34}\$__")

# Below this, a value is the compiler's vocabulary rather than ours; and exact powers of two are
# masks. Both stated up front instead of tuned after seeing the output.
MIN_VALUE = 24
def is_mask(v): return v > 0 and (v & (v - 1)) == 0

def pushes(hexstr):
    h = hexstr[2:] if hexstr.startswith("0x") else hexstr
    h = LIB_REF.sub("0" * 40, h)
    b = bytes.fromhex(h)
    i, out = 0, []
    while i < len(b):
        op = b[i]
        if 0x60 <= op <= 0x7f:
            n = op - 0x5f
            out.append(int.from_bytes(b[i + 1:i + 1 + n], "big"))
            i += 1 + n
        else:
            i += 1
    return out

# constants declared in our own sources, with their values
decls = {}
for p in sorted(glob.glob(os.path.join(ROOT, "src", "*.sol"))):
    text = open(p).read()
    for m in re.finditer(r"\bconstant\s+([A-Z][A-Z0-9_]{2,})\s*=\s*([0-9_]+)\s*;", text):
        try: v = int(m.group(2).replace("_", ""))
        except ValueError: continue
        decls[m.group(1)] = v

# how often each NAME is mentioned across our sources
named_uses = {}
allsrc = "\n".join(open(p).read() for p in sorted(glob.glob(os.path.join(ROOT, "src", "*.sol"))))
for name in decls:
    named_uses[name] = len(re.findall(r"\b%s\b" % re.escape(name), allsrc)) - 1  # minus the decl

# how often each VALUE is pushed across the shipped artefacts
counts = {}
for p in sorted(glob.glob(os.path.join(ROOT, "out", "BlazePhoenix*.sol", "*.json"))):
    try: a = json.load(open(p))
    except Exception: continue
    obj = (a.get("deployedBytecode") or {}).get("object")
    if not obj or len(obj) < 10: continue
    for v in pushes(obj):
        counts[v] = counts.get(v, 0) + 1

rows = []
for name, v in sorted(decls.items()):
    if v < MIN_VALUE or is_mask(v): continue
    rows.append({"constant": name, "value": v,
                 "named_uses": named_uses.get(name, 0),
                 "pushed": counts.get(v, 0)})

w = max((len(r["constant"]) for r in rows), default=10)
print(f"{'CONSTANT':{w}}  {'value':>10}  {'named in src':>12}  {'pushed in artefact':>18}")
print("-" * (w + 48))
for r in sorted(rows, key=lambda r: -(r["pushed"] - r["named_uses"])):
    flag = ""
    if r["pushed"] == 0:
        flag = "   folded away or dead"
    elif r["named_uses"] and r["pushed"] > 3 * r["named_uses"]:
        flag = "   value reaches the artefact from more places than the name explains"
    print(f"{r['constant']:{w}}  {r['value']:10}  {r['named_uses']:12}  {r['pushed']:18}{flag}")

zero = [r for r in rows if r["pushed"] == 0]
print(f"\nconstants above the noise floor: {len(rows)}")
print(f"  never pushed in the artefact : {len(zero)}")
print("\nA constant the artefact never pushes was folded into something else or is dead.")
print("A high count is a QUESTION: inlining duplicates a constant across call sites, so it is")
print("the ratio to the NAME's uses that carries signal, not the count.")
json.dump({"rows": rows, "never_pushed": [r["constant"] for r in zero]},
          open(os.path.join(ROOT, "assurance-constants.json"), "w"), indent=1)
