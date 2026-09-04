#!/usr/bin/env python3
"""Which storage slots the emitted code actually writes.

The library here is DELEGATECALL-linked, so it executes in the CALLER's storage. Every contract
in this system keeps its state under an ERC-7201 namespace precisely so that a library, a future
contract at the same address, or an inherited base cannot land on the same word by accident. The
source expresses that as `$.field`, which hides the slot arithmetic entirely - and a review of
the source therefore cannot see whether the discipline held.

The artefact can. A namespaced write derives its slot from a PUSH32 base and an offset. A write
to a SMALL LITERAL slot - 0, 1, 2 - did not come from a namespace, and in a delegated context
that is a collision waiting for the first contract that uses the same low word.

WHAT IS REPORTED, per contract:

  SSTORE sites            how many storage writes the emitted code contains
  small-literal slots     writes whose slot is a small constant pushed nearby
  namespace bases         distinct PUSH32 values that look like ERC-7201 bases

A small-literal write is not automatically wrong: a contract that is never delegated into may use
low slots perfectly safely, and the compiler also uses transient and scratch space that is not
storage at all. It is a list to read, and the list is short.

DETECTION is a backward window: for each SSTORE, the nearest preceding PUSH is taken as the slot
when no arithmetic intervenes. That misses computed slots, which is the safe direction - it can
under-report and cannot invent a write that is not there.

Usage: python3 storage_discipline.py <repo_root>
"""
import json, os, re, sys, glob

ROOT = sys.argv[1] if len(sys.argv) > 1 else "."
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _freshness import require_fresh
require_fresh(ROOT, quiet=True)

LIB_REF = re.compile(r"__\$[0-9a-fA-F]{34}\$__")

def shipped_artefacts(root):
    out = []
    for p in sorted(glob.glob(os.path.join(root, "out", "BlazePhoenix*.sol", "*.json"))):
        d = os.path.basename(os.path.dirname(p))
        if d.endswith(".t.sol") or d.endswith(".s.sol"): continue
        if os.path.basename(p)[:-5] + ".sol" != d: continue
        out.append(p)
    return out

def ops(hexstr):
    h = hexstr[2:] if hexstr.startswith("0x") else hexstr
    h = LIB_REF.sub("0" * 40, h)
    b = bytes.fromhex(h)
    out, i = [], 0
    while i < len(b):
        op = b[i]
        n = op - 0x5f if 0x60 <= op <= 0x7f else 0
        out.append((op, int.from_bytes(b[i+1:i+1+n], "big") if n else None))
        i += 1 + n
    return out

# arithmetic between a PUSH and the SSTORE means the slot was computed, not the literal
ARITH = {0x01, 0x02, 0x03, 0x04, 0x06, 0x08, 0x0a, 0x16, 0x17, 0x1b, 0x20}
WINDOW = 4

rows = []
for p in shipped_artefacts(ROOT):
    name = os.path.basename(p)[:-5]
    try: a = json.load(open(p))
    except Exception: continue
    obj = (a.get("deployedBytecode") or {}).get("object")
    if not obj or len(obj) < 10: continue
    seq = ops(obj)
    stores, small, bases = 0, [], set()
    for k, (op, v) in enumerate(seq):
        if v is not None and v > (1 << 200):
            bases.add(v)                       # a PUSH32-sized constant: an ERC-7201 base shape
        if op != 0x55: continue                # SSTORE
        stores += 1
        for back in range(1, WINDOW + 1):
            if k - back < 0: break
            pop, pv = seq[k - back]
            if pop in ARITH: break             # the slot was computed
            if pv is not None:
                if pv < 1024: small.append(pv)
                break
    rows.append({"contract": name, "sstore": stores,
                 "small_literal_slots": sorted(set(small)), "namespace_bases": len(bases)})

w = max((len(r["contract"]) for r in rows), default=10)
print(f"{'CONTRACT':{w}}  {'SSTORE':>6}  {'bases':>5}  slots written as a small literal")
print("-" * (w + 46))
flagged = 0
for r in sorted(rows, key=lambda r: r["contract"]):
    s = ", ".join(str(x) for x in r["small_literal_slots"]) or "-"
    if r["small_literal_slots"]: flagged += 1
    print(f"{r['contract']:{w}}  {r['sstore']:6}  {r['namespace_bases']:5}  {s}")

print(f"\ncontracts read                 : {len(rows)}")
print(f"  writing to a small literal   : {flagged}")
print("\nA delegated library executes in the CALLER's storage, which is why every contract here")
print("keeps state under a namespace. A small literal slot did not come from one. Whether that")
print("matters depends on who delegates into the contract - which is why this is a list, not a")
print("verdict.")
json.dump({"rows": rows, "flagged": flagged},
          open(os.path.join(ROOT, "assurance-storage.json"), "w"), indent=1)
