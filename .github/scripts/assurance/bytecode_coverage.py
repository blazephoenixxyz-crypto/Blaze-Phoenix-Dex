#!/usr/bin/env python3
"""What fraction of the SHIPPED runtime bytes the test suite executes.

Coverage is normally reported over source: lines, branches, functions. For an immutable contract
that measures the wrong object. Nobody deploys the source. The thing that receives money is the
runtime on chain, and a source-line coverage figure says nothing about how much of THAT anyone
has ever executed.

METHOD, stated so the number can be checked and attacked:

  1. `forge coverage --report lcov` gives hit counts per source line.
  2. The artefact's source map gives, for every instruction in the deployed bytecode, the source
     offset it came from.
  3. Each instruction is charged its own byte length and attributed to the line containing that
     offset. An instruction is COVERED if the suite hit that line at least once.
  4. Instructions the map attributes to no file - compiler machinery: dispatch, decoding,
     allocation, revert plumbing - are counted as UNMAPPED and reported separately. They are not
     scored as covered, and they are not hidden in the denominator either.

The headline is therefore three numbers, not one:

    covered / mapped        of the runtime that traces to our source, how much runs
    unmapped                bytes no source line can claim, so no test can be said to cover
    covered / total         the honest figure for the deployed object

WHAT MAKES IT FALSIFIABLE. Every step is reproducible from a clean checkout with two commands,
and each of the three numbers moves in a predictable direction under a change anyone can make:
delete a test and covered/mapped falls; add a contract and unmapped rises; change the optimiser
and both move. A reader who thinks the figure is wrong can recompute it. That is the whole claim
being made for it.

WHAT IT IS NOT. Line granularity is coarser than the instruction: an instruction is called
covered because its LINE ran, not because that instruction did, so a line with an untaken branch
still contributes its bytes as covered. The figure is therefore an UPPER BOUND on true
instruction coverage, and it is reported as such. A tighter number needs a PC-level trace, which
this does not attempt.

Usage: python3 bytecode_coverage.py <repo_root> [lcov_path]
"""
import json, os, re, sys, glob, bisect

ROOT = sys.argv[1] if len(sys.argv) > 1 else "."
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _freshness import require_fresh
require_fresh(ROOT, quiet=True)
LCOV = sys.argv[2] if len(sys.argv) > 2 else os.path.join(ROOT, "lcov.info")
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

if not os.path.exists(LCOV):
    print(f"no lcov at {LCOV} - run: forge coverage --report lcov")
    sys.exit(2)

# lcov -> {normalised source path: {line: hits}}
hits, cur = {}, None
for line in open(LCOV):
    line = line.strip()
    if line.startswith("SF:"):
        cur = line[3:].replace(os.path.abspath(ROOT) + "/", "").lstrip("./")
        hits.setdefault(cur, {})
    elif line.startswith("DA:") and cur:
        n, h = line[3:].split(",")[:2]
        hits[cur][int(n)] = int(h)

# offset -> line, per source file
lines_at = {}
for p in sorted(glob.glob(os.path.join(ROOT, "src", "*.sol"))):
    text = open(p).read()
    starts, off = [0], 0
    for ch in text.split("\n")[:-1]:
        off += len(ch) + 1
        starts.append(off)
    lines_at[os.path.basename(p)] = starts

def line_of(fname, offset):
    st = lines_at.get(fname)
    if not st: return None
    return bisect.bisect_right(st, offset)          # 1-based

SCORED = {}
def nearest_hit(fname, ln):
    key = "src/" + fname
    if key not in hits: return None
    if key not in SCORED:
        SCORED[key] = sorted(hits[key].keys())
    ks = SCORED[key]
    if not ks or ln is None: return None
    i = bisect.bisect_right(ks, ln) - 1
    if i < 0: return None
    return hits[key][ks[i]]


def instructions(hexstr):
    h = hexstr[2:] if hexstr.startswith("0x") else hexstr
    h = LIB_REF.sub("0" * 40, h)
    b = bytes.fromhex(h)
    i, n = 0, 0
    while i < len(b):
        op = b[i]
        size = 1 + (op - 0x5f if 0x60 <= op <= 0x7f else 0)
        yield n, size
        i += size; n += 1

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

id_to_file = {}
for p in shipped_artefacts(ROOT):
    try: a = json.load(open(p))
    except Exception: continue
    if isinstance(a.get("id"), int):
        # THE SOURCE FILE IS THE DIRECTORY, NOT THE ARTEFACT NAME. `out/X.sol/Y.json` is
        # contract Y declared inside source X.sol - an interface next to a contract shares
        # its file and its source id. Deriving the filename from the artefact made the last
        # one processed win the id, and the mapping then pointed a real source id at a file
        # that does not exist. Caught by this script disagreeing with unattributed_code.py
        # about the same bytes, which is the only reason it was found at all.
        id_to_file[a["id"]] = os.path.basename(os.path.dirname(p))

rows, T = [], {"covered": 0, "uncovered": 0, "declarative": 0, "machinery": 0}
for p in sorted(shipped_artefacts(ROOT)):
    name = os.path.basename(p)[:-5]
    if not name.startswith("BlazePhoenix"): continue
    try: a = json.load(open(p))
    except Exception: continue
    db = a.get("deployedBytecode", {})
    obj, sm = db.get("object"), db.get("sourceMap")
    if not obj or not sm or len(obj) < 10: continue
    smap = parse_map(sm)
    c = {"covered": 0, "uncovered": 0, "declarative": 0, "machinery": 0}
    for idx, size in instructions(obj):
        f = smap[idx][2] if idx < len(smap) else -1
        fname = id_to_file.get(f) if f is not None and f >= 0 else None
        if not fname:
            c["machinery"] += size; continue      # no source at all: dispatch, decoding, glue
        ln = line_of(fname, smap[idx][0])
        # lcov scores STATEMENTS, not every line: declarations, braces and continuations carry
        # no DA record. Treating those as unmapped was the first version's error, and it showed
        # up as this script claiming 95.9% unmapped while unattributed_code.py, measuring the
        # overlapping quantity a different way, said 8.2%. Two instruments disagreeing about the
        # same object is how one of them gets caught. An instruction is charged to the nearest
        # PRECEDING scored line in its file - the statement whose region it belongs to.
        h = nearest_hit(fname, ln)
        if h is None:
            # OUR source, but a region line coverage cannot score: the header, imports,
            # interface declarations, constants and immutables that sit before the first
            # statement. This code RUNS - a constant becomes a PUSH - but there is no statement
            # for lcov to attach a hit to, so calling it uncovered would be a lie in one
            # direction and calling it covered a lie in the other. It gets its own bucket, which
            # is the only honest place for it.
            c["declarative"] += size
        elif h > 0:
            c["covered"] += size
        else:
            c["uncovered"] += size
    for k in c: T[k] += c[k]
    tot = sum(c.values()) or 1
    rows.append({"contract": name, **c, "pct": c["covered"] / tot})

print(f"{'CONTRACT':22} {'covered':>8} {'uncov':>7} {'declar':>7} {'machin':>7}  cov/executable")
print("-" * 68)
for r in sorted(rows, key=lambda r: r["contract"]):
    ex = r["covered"] + r["uncovered"] or 1
    print(f"{r['contract']:22} {r['covered']:8} {r['uncovered']:7} {r['declarative']:7} "
          f"{r['machinery']:7}  {r['covered']/ex:9.1%}")

g = sum(T.values()) or 1
ex = T["covered"] + T["uncovered"] or 1
print(f"\nshipped runtime bytes            : {g}")
print(f"  executed by the suite          : {T['covered']:7}  {T['covered']/g:6.1%} of total")
print(f"  executable, never executed     : {T['uncovered']:7}  {T['uncovered']/g:6.1%} of total")
print(f"  declarative source (unscorable): {T['declarative']:7}  {T['declarative']/g:6.1%} of total")
print(f"  compiler machinery (no source) : {T['machinery']:7}  {T['machinery']/g:6.1%} of total")
print(f"\nTHE TWO FIGURES, and both are needed:")
print(f"  covered / executable           : {T['covered']/ex:.4f}   how much of the code a")
print(f"                                            statement can be attached to runs")
print(f"  covered / total shipped        : {T['covered']/g:.4f}   how much of what is ON CHAIN")
print(f"                                            any test has ever executed")
print("\nUPPER BOUND: an instruction counts as covered because its LINE ran, so a line with an")
print("untaken branch still contributes its bytes. The complementary LOWER bound is\n"
      "pc_coverage.py, which proves execution instead of inferring it and reports 85.9%.")
json.dump({"totals": T, "rows": rows,
           "covered_over_executable": round(T["covered"] / ex, 4),
           "covered_over_total": round(T["covered"] / g, 4)},
          open(os.path.join(ROOT, "assurance-bytecode-coverage.json"), "w"), indent=1)
