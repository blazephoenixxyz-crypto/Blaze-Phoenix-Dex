#!/usr/bin/env python3
"""The refusal surface we did not write: which Solidity panics the artefact can raise.

This project inventories its own refusals - every `revert XxxE(n)` in the sources, and which of
them a test drives by its exact code. That inventory covers one of the two refusal surfaces a
deployed contract has.

The other is the compiler's. Solidity emits `Panic(uint256)` handlers for the assumptions the
source did not defend itself: arithmetic that could overflow, a division whose divisor could be
zero, an index that could exceed an array, an allocation that could exceed memory. Those handlers
live in the compiler-generated region - the bytes that map to no source line, and that no review,
no coverage report and no threat model in this repository has ever mentioned.

Each panic present in the artefact is an ASSUMPTION MADE AND NOT PROVEN. The compiler could not
show the condition impossible, so it emitted a guard. That is not a defect on its own - checked
arithmetic is the reason to use 0.8.x - but it is a list of places where the contract's behaviour
under an unexpected input is decided by the compiler rather than by us, and where the failure mode
is a bare panic rather than a named refusal a caller can interpret.

WHAT IT REPORTS

  which panic codes the emitted code can raise, per contract
  which of them any test asserts

A panic no test asserts is not proof of a bug. It is a refusal path whose reachability nobody has
established in either direction - the same standing our own undriven refusals had before they were
inventoried, and the reason that inventory was worth taking.

DETECTION. The panic selector is the first four bytes of keccak("Panic(uint256)") = 0x4e487b71,
emitted as a PUSH4 or in the high bytes of a PUSH32 before the code is stored to memory. The code
itself follows as a small immediate. Both are matched; a contract with the selector but no
recognised code is reported rather than silently dropped.

Usage: python3 panic_inventory.py <repo_root>
"""
import json, os, re, sys, glob

ROOT = sys.argv[1] if len(sys.argv) > 1 else "."
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _freshness import require_fresh
require_fresh(ROOT, quiet=True)

LIB_REF = re.compile(r"__\$[0-9a-fA-F]{34}\$__")
PANIC_SELECTOR = 0x4e487b71

MEANING = {
    0x01: "assert(false) - an invariant the source asserts and does not prove",
    0x11: "arithmetic overflow or underflow",
    0x12: "division or modulo by zero",
    0x21: "conversion to a non-existent enum value",
    0x22: "incorrectly encoded storage byte array",
    0x31: "pop() on an empty array",
    0x32: "array index out of bounds",
    0x41: "allocation too large, or memory exhausted",
    0x51: "call to a zero-initialised internal function pointer",
}

def walk(hexstr):
    h = hexstr[2:] if hexstr.startswith("0x") else hexstr
    h = LIB_REF.sub("0" * 40, h)
    b = bytes.fromhex(h)
    i = 0
    while i < len(b):
        op = b[i]
        if 0x60 <= op <= 0x7f:
            n = op - 0x5f
            yield op, int.from_bytes(b[i + 1:i + 1 + n], "big")
            i += 1 + n
        else:
            yield op, None
            i += 1

tests = "\n".join(open(p).read() for p in
                  glob.glob(os.path.join(ROOT, "test", "**", "*.t.sol"), recursive=True))

rows, seen_any = [], set()
for p in sorted(glob.glob(os.path.join(ROOT, "out", "BlazePhoenix*.sol", "*.json"))):
    name = os.path.basename(p)[:-5]
    if not name.startswith("BlazePhoenix"): continue
    try: a = json.load(open(p))
    except Exception: continue
    obj = (a.get("deployedBytecode") or {}).get("object")
    if not obj or len(obj) < 10: continue
    # PROXIMITY, NOT PRESENCE. The first version counted any immediate equal to a panic code
    # anywhere in the artefact - and 0x01, 0x11, 0x12, 0x32 and 0x41 are also 1, 17, 18, 50 and
    # 65, which appear in any contract. It reported assert-panic 0x01 as reachable in all five,
    # while the sources contain no `assert(` at all. Validated against that, and rewritten: the
    # code must be pushed within a short window AFTER the Panic(uint256) selector, which is how
    # Solidity emits the pair - selector to memory at 0, code to memory at 4, revert 0x24 bytes.
    ops = list(walk(obj))
    WINDOW = 12
    imm, has_sel = set(), False
    for k, (op, v) in enumerate(ops):
        if v is None: continue
        if v == PANIC_SELECTOR or (v >> 224) == PANIC_SELECTOR:
            has_sel = True
            for _op2, v2 in ops[k + 1:k + 1 + WINDOW]:
                if v2 in MEANING:
                    imm.add(v2); break
    codes = sorted(imm) if has_sel else []
    seen_any |= set(codes)
    rows.append({"contract": name, "selector_present": has_sel, "codes": codes})

# does any test assert a panic at all?
asserted = set()
for c in MEANING:
    pats = [r"Panic\s*\(\s*uint256\s*\)[^;]{0,80}0x%02x" % c,
            r"stdError\.%s" % {0x11: "arithmeticError", 0x12: "divisionError",
                               0x32: "indexOOBError", 0x01: "assertionError",
                               0x31: "popError", 0x21: "enumConversionError",
                               0x22: "encodeStorageError", 0x41: "memOverflowError",
                               0x51: "zeroVarError"}.get(c, "____"),
            r"0x4e487b71[^;]{0,120}0x%02x" % c]
    if any(re.search(pt, tests) for pt in pats):
        asserted.add(c)

w = max(len(r["contract"]) for r in rows)
print(f"{'CONTRACT':{w}}  panic selector  codes the emitted code can raise")
print("-" * (w + 52))
for r in sorted(rows, key=lambda r: r["contract"]):
    cs = ", ".join(f"0x{c:02x}" for c in r["codes"]) or "-"
    print(f"{r['contract']:{w}}  {'yes' if r['selector_present'] else ' - ':^14}  {cs}")

print(f"\ndistinct panic codes reachable in the shipped set: {len(seen_any)}")
for c in sorted(seen_any):
    mark = "asserted by a test" if c in asserted else "NOT asserted by any test"
    print(f"  0x{c:02x}  {MEANING[c]:56}  {mark}")

unasserted = sorted(seen_any - asserted)
print(f"\nasserted    : {len(seen_any) - len(unasserted)}")
print(f"NOT asserted: {len(unasserted)}")
print("\nA panic no test asserts is not a bug. It is a refusal path whose reachability nobody")
print("has established in either direction - and it is the compiler's guard standing where the")
print("source did not put one of its own.")
json.dump({"rows": rows, "codes": sorted(seen_any),
           "asserted": sorted(asserted), "unasserted": unasserted},
          open(os.path.join(ROOT, "assurance-panics.json"), "w"), indent=1)
