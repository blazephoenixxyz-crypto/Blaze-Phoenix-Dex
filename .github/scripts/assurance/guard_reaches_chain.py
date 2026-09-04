#!/usr/bin/env python3
"""Does each named guard reach the artefact that deploys?

The traceability chain in this repository runs threat -> property -> guard -> test -> mutant, and
every link of it is established in SOURCE. For an immutable contract that is one link short. The
thing users interact with is not the source; it is the runtime on chain, and a guard that reads
perfectly and compiles to nothing is invisible to every check that stops at the source.

Critical-systems practice calls the discipline bidirectional traceability and requires the links
to be maintained across the lifecycle rather than established once. Applied here, the missing
half is:

    guard  ->  INSTRUCTIONS IN THE SHIPPED ARTEFACT  ->  a test that executes them

This closes the first arrow. For every guard named in docs/assurance/threats.json it finds the
symbol's occurrences in src/, then walks the deployed bytecode alongside its source map and
counts the instructions attributed to those spans. A guard contributing ZERO instructions is a
guard that did not reach the chain.

The second arrow needs execution, not reading: an opcode-level coverage trace accumulating the
program counters a test suite actually touches. It is not attempted here, and saying so is the
point - a chain with a link asserted rather than measured is the failure this whole apparatus
exists to avoid.

HONEST LIMITS. Attribution under the IR pipeline is lossy in the way documented in
branch_attribution.py: the map points at generated helpers, so a guard can be present and
under-attributed. A zero is therefore a QUESTION worth reading, not a verdict - and a nonzero is
weak evidence of presence rather than proof of reachability. Constants are counted at their use
sites, because that is where a constant becomes instructions.

Usage: python3 guard_reaches_chain.py <repo_root>
"""
import json, os, re, sys, glob

ROOT = sys.argv[1] if len(sys.argv) > 1 else "."
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _freshness import require_fresh
require_fresh(ROOT, quiet=True)
def shipped_artefacts(root):
    """Only the compilation units that DEPLOY. `out/` also holds artefacts for test contracts,
    whose directories match any glob over BlazePhoenix*.sol - and including them made every
    bytecode number here depend on whether the suite happened to be built. It did: a full build
    turned five artefacts into eleven and the attribution figure from 92% into 36%."""
    out = []
    for p in sorted(glob.glob(os.path.join(root, "out", "BlazePhoenix*.sol", "*.json"))):
        d = os.path.basename(os.path.dirname(p))
        if d.endswith(".t.sol") or d.endswith(".s.sol"): continue
        if os.path.basename(p)[:-5] + ".sol" != d: continue      # an interface beside a contract
        out.append(p)
    return out


LIB_REF = re.compile(r"__\$[0-9a-fA-F]{34}\$__")

def instructions(hexstr):
    h = hexstr[2:] if hexstr.startswith("0x") else hexstr
    h = LIB_REF.sub("0" * 40, h)
    b = bytes.fromhex(h)
    i, n = 0, 0
    while i < len(b):
        op = b[i]
        yield n
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

# every source-map span that some instruction in some shipped artefact is attributed to,
# together with the source-unit id it belongs to
spans_by_file = {}
ids = {}
for p in sorted(shipped_artefacts(ROOT)):
    try: a = json.load(open(p))
    except Exception: continue
    if isinstance(a.get("id"), int):
        ids[os.path.basename(os.path.dirname(p))[:-4]] = a["id"]
    db = a.get("deployedBytecode", {})
    obj, sm = db.get("object"), db.get("sourceMap")
    if not obj or not sm or len(obj) < 10: continue
    smap = parse_map(sm)
    for idx in instructions(obj):
        if idx >= len(smap): break
        s, l, f, _j, _m = smap[idx]
        if f is None or f < 0: continue
        spans_by_file.setdefault(f, []).append((s, max(l, 1)))

src_files = {}
for sp in sorted(glob.glob(os.path.join(ROOT, "src", "*.sol"))):
    name = os.path.basename(sp)[:-4]
    src_files[name] = open(sp).read()

cat = json.load(open(os.path.join(ROOT, "docs/assurance/threats.json")))["classes"]
guards = sorted({c["guard"] for c in cat if c.get("guard")})

def instr_for(symbol):
    """Instructions attributed to any occurrence of this symbol, across the shipped set."""
    total = 0
    for cname, text in src_files.items():
        fid = ids.get(cname)
        if fid is None or fid not in spans_by_file: continue
        occ = [m.start() for m in re.finditer(r"\b%s\b" % re.escape(symbol), text)]
        if not occ: continue
        for s, l in spans_by_file[fid]:
            if any(s <= o < s + l for o in occ):
                total += 1
    return total

rows = [{"guard": g, "instructions": instr_for(g)} for g in guards]
zero = [r for r in rows if r["instructions"] == 0]

# PRESENCE, NOT MAGNITUDE. The count is printed as a diagnostic and must not be read as a
# measure of how much code a guard produced: source-map spans can cover a whole function, so a
# symbol used inside a large span inherits every instruction in it. Probed against symbols that
# do not exist in the tree, which return zero - so the check discriminates presence from
# absence, and nothing finer.
w = max(len(r["guard"]) for r in rows)
print(f"{'GUARD':{w}}  reaches the chain   (attributed count, diagnostic only)")
print("-" * (w + 52))
for r in sorted(rows, key=lambda r: (r["instructions"] == 0, r["guard"])):
    mark = "NO  <<< compiles to nothing" if not r["instructions"] else "yes"
    print(f"{r['guard']:{w}}  {mark:26} {r['instructions']:6}")
print(f"\nguards named in the catalogue  : {len(rows)}")
print(f"  reaching the artefact        : {len(rows) - len(zero)}")
print(f"  reaching nothing             : {len(zero)}")
print("\nThe reverse arrow - every shipped instruction executed by some test - needs an")
print("opcode-level execution trace and is NOT established here. A chain with a link")
print("asserted rather than measured is the failure this apparatus exists to avoid.")
json.dump({"guards": len(rows), "reaching": len(rows) - len(zero),
           "zero": [r["guard"] for r in zero], "rows": rows},
          open(os.path.join(ROOT, "assurance-guard-reach.json"), "w"), indent=1)
