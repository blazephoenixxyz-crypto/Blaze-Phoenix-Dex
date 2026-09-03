#!/usr/bin/env python3
"""How much of the shipped runtime is attributable to source anyone here wrote.

Every check in this directory asks whether something we WANT is present. This one inverts the
question: of the instructions that will actually be on chain, how many can the artefact's own
map trace back to a file in `src/`?

Instructions that cannot are not a scandal — a compiler emits dispatch tables, memory
allocation, calldata decoding, revert plumbing and ABI encoders that nobody writes by hand, and
they are as much a part of the deployed contract as the logic is. The point is that **nobody
counts them**. They are reviewed by no one, covered by no coverage report, and named in no
threat model, and they are shipped.

Three buckets:

  OURS        attributed to a file in src/
  DEPENDENCY  attributed to a source unit outside src/ - imported code that reached the runtime
  UNMAPPED    attributed to no file at all - compiler-generated glue

WHAT THE NUMBER IS FOR. Not a target: driving UNMAPPED down would mean writing by hand what the
compiler writes better. It is a WATCH and a proportion to know. A build whose unmapped fraction
jumps has started emitting materially more machinery than the last one, and a DEPENDENCY
fraction that rises means imported code is reaching the runtime rather than being inlined away -
both are facts about the shipped artefact that no source review produces.

The mapping is by source-unit id, taken from the artefacts themselves. Under the IR pipeline the
map is lossy in the same way it is elsewhere here, so treat the split as an estimate with a
stated method rather than an exact partition.

Usage: python3 unattributed_code.py <repo_root>
"""
import json, os, re, sys, glob

ROOT = sys.argv[1] if len(sys.argv) > 1 else "."
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _freshness import require_fresh
require_fresh(ROOT, quiet=True)
LIB_REF = re.compile(r"__\$[0-9a-fA-F]{34}\$__")

def instructions(hexstr):
    h = hexstr[2:] if hexstr.startswith("0x") else hexstr
    h = LIB_REF.sub("0" * 40, h)
    b = bytes.fromhex(h)
    i, n = 0, 0
    while i < len(b):
        op = b[i]
        yield n, op, 1 + (op - 0x5f if 0x60 <= op <= 0x7f else 0)
        i += 1 + (op - 0x5f if 0x60 <= op <= 0x7f else 0)
        n += 1

def parse_map(sm):
    out, prev = [], [0, 0, 0, "", 0]
    for entry in sm.split(";"):
        parts = entry.split(":")
        cur = list(prev)
        for k in range(min(len(parts), 5)):
            if parts[k] != "":
                cur[k] = int(parts[k]) if k in (0, 1, 2, 4) else parts[k]
        out.append(cur); prev = cur
    return out

# source-unit ids of the files we wrote, taken from the artefacts themselves
OURS = set()
for p in glob.glob(os.path.join(ROOT, "out", "BlazePhoenix*.sol", "*.json")):
    try: a = json.load(open(p))
    except Exception: continue
    if isinstance(a.get("id"), int): OURS.add(a["id"])

rows, tot = [], {"OURS": 0, "DEPENDENCY": 0, "UNMAPPED": 0}
for p in sorted(glob.glob(os.path.join(ROOT, "out", "BlazePhoenix*.sol", "*.json"))):
    name = os.path.basename(p)[:-5]
    if not name.startswith("BlazePhoenix"): continue
    try: a = json.load(open(p))
    except Exception: continue
    db = a.get("deployedBytecode", {})
    obj, sm = db.get("object"), db.get("sourceMap")
    if not obj or not sm or len(obj) < 10: continue
    smap = parse_map(sm)
    c = {"OURS": 0, "DEPENDENCY": 0, "UNMAPPED": 0}
    for idx, _op, size in instructions(obj):
        f = smap[idx][2] if idx < len(smap) else -1
        k = "UNMAPPED" if f is None or f < 0 else ("OURS" if f in OURS else "DEPENDENCY")
        c[k] += size                                   # weight by BYTES, not instructions
    for k in c: tot[k] += c[k]
    total = sum(c.values()) or 1
    rows.append({"contract": name, **c, "ours_pct": c["OURS"] / total})

print(f"{'CONTRACT':24} {'ours':>7} {'dep':>6} {'unmapped':>9}  attributable to src/")
print("-" * 70)
for r in sorted(rows, key=lambda r: r["contract"]):
    print(f"{r['contract']:24} {r['OURS']:7} {r['DEPENDENCY']:6} {r['UNMAPPED']:9}  {r['ours_pct']:6.1%}")
g = sum(tot.values()) or 1
print(f"\nruntime bytes across the set   : {g}")
for k in ("OURS", "DEPENDENCY", "UNMAPPED"):
    print(f"  {k:11}                : {tot[k]:7}  {tot[k]/g:6.1%}")
print("\nUnmapped bytes are compiler-generated machinery - dispatch, decoding, allocation,")
print("revert plumbing. They are not a defect and not a target. They are the part of the")
print("shipped contract that no review, no coverage report and no threat model mentions.")
json.dump({"totals": tot, "rows": rows,
           "ours_fraction": round(tot["OURS"] / g, 4)},
          open(os.path.join(ROOT, "assurance-unattributed.json"), "w"), indent=1)
