#!/usr/bin/env python3
"""Branch ATTRIBUTION: which source conditionals the artefact's own map still points back to.

The idea this started from is worth keeping and is not what the script ended up measuring, so
both are written down.

THE IDEA. The optimiser is an unreachability prover nobody interrogates. When it shows a
condition constant it deletes the branch silently: the source still reads as a guarded path,
every review still sees the guard, and the shipped contract does not branch there. A conditional
present in source and absent from the artefact is either a defence that cannot fire, or a
compiler that is wrong - and the second produced a high-severity advisory against this compiler
family in 2026.

WHAT IT ACTUALLY MEASURES. Solidity artefacts carry a source map with one entry per instruction.
Walking the runtime alongside it attributes every JUMPI - the EVM's only conditional jump - to a
span of source. This script reports how many source conditionals have a JUMPI attributed inside
them.

WHY THAT IS NOT SURVIVAL, established rather than assumed. Six conditionals here have no JUMPI
attributed. Two are `if (a < b) b = a;` - a minimum, which the optimiser emits without a branch
at all, so their absence is strength reduction and entirely correct. The other four sit inside
an external entry point that forty-seven test files exercise by name, and whose refusals are
driven by exact-code assertions. Those branches unquestionably exist. The map simply does not
point at them, because under the IR pipeline it attributes instructions to generated Yul helpers
that remap elsewhere.

So the number is an ATTRIBUTION rate, and the honest reading is: this is a fact about the map,
not about the code. It earns its place as a WATCH: the rate is stable for a given compiler and
pipeline, so a sudden fall is a change in what the compiler is doing to the guards - which is
precisely the event worth being told about, even when the absolute value cannot be read as
coverage.

The stronger check on the same question does not use the map at all and lives in
bytecode_invariants.py: every refusal code in the source must have a matching immediate in the
artefact. A code that vanished is evidence the optimiser proved its guard unreachable.
"""

import json, os, re, sys, glob

ROOT = sys.argv[1] if len(sys.argv) > 1 else "."
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _freshness import require_fresh
require_fresh(ROOT, quiet=True)
LIB_REF = re.compile(r"__\$[0-9a-fA-F]{34}\$__")

def instructions(hexstr):
    """(index, opcode) per INSTRUCTION - the unit the source map counts in."""
    h = hexstr[2:] if hexstr.startswith("0x") else hexstr
    h = LIB_REF.sub("0" * 40, h)
    b = bytes.fromhex(h)
    i, n = 0, 0
    while i < len(b):
        op = b[i]
        yield n, op
        i += 1 + (op - 0x5f if 0x60 <= op <= 0x7f else 0)
        n += 1

def parse_map(sm):
    """Decompress `s:l:f:j:m`; an empty field repeats the previous instruction's value."""
    out, prev = [], [0, 0, 0, "", 0]
    for entry in sm.split(";"):
        parts = entry.split(":")
        cur = list(prev)
        for k in range(min(len(parts), 5)):
            if parts[k] != "":
                cur[k] = int(parts[k]) if k in (0, 1, 2, 4) else parts[k]
        out.append(cur); prev = cur
    return out

# every conditional in the source, with the byte span it occupies
COND = re.compile(r"\b(?:if|require)\s*\(")

rows, total_c, total_live = [], 0, 0
for sp in sorted(glob.glob(os.path.join(ROOT, "src", "*.sol"))):
    name = os.path.basename(sp)[:-4]
    arts = glob.glob(os.path.join(ROOT, "out", name + ".sol", name + ".json"))
    if not arts: continue
    art = json.load(open(arts[0]))
    db = art.get("deployedBytecode", {})
    obj, sm = db.get("object"), db.get("sourceMap")
    if not obj or not sm: continue
    smap = parse_map(sm)

    # source offsets of every JUMPI, restricted to entries whose file index is this contract's
    jumpi_at = set()
    for idx, op in instructions(obj):
        if op == 0x57 and idx < len(smap):          # JUMPI
            s, l, f, _j, _m = smap[idx]
            jumpi_at.add((f, s, l))

    src = open(sp, 'rb').read().decode('latin-1')   # source maps are BYTE offsets
    # THE SPAN IS THE STATEMENT, NOT THE KEYWORD. Under the IR pipeline the map attributes a
    # JUMPI to the CONDITION sub-expression, which begins after `if (`. The first version of
    # this script matched only against the keyword's own few characters and therefore reported
    # four conditionals inside `seedPool` - an external door named by forty-seven tests - as
    # having no branch at all. Validated against that known-live guard rather than assumed.
    conds = []
    for m in COND.finditer(src):
        nl = src.find("\n", m.end())
        conds.append((m.start(), nl if nl > 0 else m.end()))
    # a conditional survives if some JUMPI's source span overlaps it
    live, missing = 0, []
    for cs, ce in conds:
        if any(s <= cs < s + max(l, 1) or cs <= s < ce for _f, s, l in jumpi_at):
            live += 1
        else:
            ln = src.count("\n", 0, cs) + 1
            missing.append({"line": ln, "text": src[cs:src.find("\n", cs)].strip()[:90]})
    total_c += len(conds); total_live += live
    rows.append({"contract": name, "conditionals": len(conds), "with_a_branch": live,
                 "jumpi_sites": len(jumpi_at), "no_branch": missing})

print(f"{'CONTRACT':24} {'conds':>6} {'branched':>9} {'JUMPI spans':>12}  attributed")
print("-" * 66)
for r in sorted(rows, key=lambda r: r["contract"]):
    pct = r["with_a_branch"] / r["conditionals"] if r["conditionals"] else 0
    print(f"{r['contract']:24} {r['conditionals']:6} {r['with_a_branch']:9} "
          f"{r['jumpi_sites']:12}  {pct:6.1%}")
rate = total_live / total_c if total_c else 0
print(f"\nsource conditionals            : {total_c}")
print(f"  with a branch in the artefact: {total_live}")
print(f"branch attribution             : {rate:.3f}")
print("\nThis is an ATTRIBUTION rate, not a survival rate: under the IR pipeline the map")
print("points at generated helpers, and conditionals known to be exercised can go unmapped.")
print("Watch the rate for CHANGE - a fall means the compiler started treating guards")
print("differently. Do not read the absolute value as coverage.")
json.dump({"conditionals": total_c, "with_branch": total_live,
           "attribution": round(rate, 4), "rows": rows},
          open(os.path.join(ROOT, "assurance-branch-attribution.json"), "w"), indent=1)
