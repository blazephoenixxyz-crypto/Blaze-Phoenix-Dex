#!/usr/bin/env python3
"""Properties of the COMPILED artefact that the source cannot guarantee.

Everything else in this directory reads source and tests. This one reads what the compiler
actually emitted, because there is a class of defect that exists only there: the source is
right, the reviewer is right, and the bytecode is wrong. Three shapes of it are worth naming.

  COMPILER MISCOMPILATION. In February 2026 a code-generator bug was reported in Solidity
  0.8.28-0.8.33 under the IR pipeline: a contract clearing both a persistent and a transient
  variable of the same type emitted the WRONG OPCODE for one of them - sstore where tstore was
  meant, or the reverse - because the generated Yul helpers collided by name. Rated high. No
  source-level review finds that, and no source-level test does either unless it happens to
  exercise the exact interleaving. An assertion over the emitted opcodes does.

  ABSENCE THAT MUST STAY ABSENT. A contract that never deploys, never delegates outside its
  library, and never self-destructs should contain no opcode for any of those. Source review
  establishes it for the code you read; the artefact establishes it for the code that exists,
  including anything a dependency, an assembly block or a future refactor introduces.

  DIVERGENCE FROM WHAT IS DEPLOYED. The strongest bytecode property is not internal at all: it
  is that the runtime on chain equals the runtime this tree builds. That check is not in this
  script because it needs a network; it belongs in the fork job. It is named here because it is
  the one that matters most, and because this project has already met a case where the reviewed
  tree and the deployed contract had diverged on a security-relevant constant.

WHAT THIS DOES NOT DO. It reads the artefact, not the semantics: opcode presence is a coarse
property, and absence of an opcode is a real guarantee while presence proves nothing on its own.
It is a floor. Anything requiring the MEANING of the emitted code needs symbolic execution or a
verified compiler, and neither is claimed here.

Usage: python3 bytecode_invariants.py <repo_root>
"""
import json, os, sys, glob, re

ROOT = sys.argv[1] if len(sys.argv) > 1 else "."
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _freshness import require_fresh
require_fresh(ROOT, quiet=True)
OUT  = os.path.join(ROOT, "out")

# opcode -> (name, may it appear in these contracts?)
FORBIDDEN = {
    0xff: "SELFDESTRUCT",   # nothing here is destructible; the contracts are immutable
    0xf2: "CALLCODE",       # deprecated, and never intended
    0x32: "ORIGIN",         # tx.origin is never an authority here, and the artefact says so
}
# Opcodes worth COUNTING rather than forbidding. Each maps to a defect class this project has
# actually met, which is the only reason any of them is here.
COUNTED = {
    0xf4: "DELEGATECALL",   # the library link, and nothing else. A new one is an event.
    0x55: "SSTORE",         # a guard that should write once and emits two writes is visible here
    0x5d: "TSTORE",
    0xf1: "CALL",
    0xfa: "STATICCALL",
}
REQUIRED_SOMEWHERE = {
    0x5c: "TLOAD",          # the reentrancy lock and the fee-on-transfer probes are transient
    0x5d: "TSTORE",
}

LIB_REF = re.compile(r"__\$[0-9a-fA-F]{34}\$__")

def walk(hexstr):
    """Yield (offset, opcode, immediate) skipping PUSH data, so a constant is never read as an
    instruction. Getting this wrong shifts the walk and turns data into opcodes, which is the
    classic way a bytecode scanner invents findings."""
    h = hexstr[2:] if hexstr.startswith("0x") else hexstr
    h = LIB_REF.sub("0" * 40, h)
    b = bytes.fromhex(h)
    i = 0
    while i < len(b):
        op = b[i]
        if 0x60 <= op <= 0x7f:
            n = op - 0x5f
            yield i, op, b[i + 1:i + 1 + n]
            i += 1 + n
        else:
            yield i, op, b""
            i += 1


def opcodes(hexstr):
    """Walk the code, skipping PUSH immediates so a constant is never read as an opcode.

    Unlinked library references appear as `__$<34 hex>$__` placeholders and are not hex. They
    are 40 characters - exactly one address - so substituting zeroes preserves every offset and
    therefore every opcode boundary. Getting that wrong would shift the walk and turn PUSH data
    into instructions, which is the classic way a bytecode scanner invents findings."""
    h = hexstr[2:] if hexstr.startswith("0x") else hexstr
    h = LIB_REF.sub("0" * 40, h)
    b = bytes.fromhex(h)
    seen, i = set(), 0
    while i < len(b):
        op = b[i]
        seen.add(op)
        if 0x60 <= op <= 0x7f:          # PUSH1..PUSH32
            i += 1 + (op - 0x5f)
        else:
            i += 1
    return seen

targets, problems, rows = [], [], []
for p in glob.glob(os.path.join(OUT, "BlazePhoenix*.sol", "*.json")):
    name = os.path.basename(p)[:-5]
    if not name.startswith("BlazePhoenix"): continue
    try:
        art = json.load(open(p))
    except Exception:
        continue
    obj = (art.get("deployedBytecode") or {}).get("object")
    if not obj or len(obj) < 10: continue
    targets.append(name)
    ops = opcodes(obj)
    counts, push4 = {}, set()
    for _off, op, imm in walk(obj):
        if op in COUNTED:
            counts[COUNTED[op]] = counts.get(COUNTED[op], 0) + 1
        if op == 0x63:                      # PUSH4 - the dispatcher's selector constants
            push4.add(imm.hex())
    # SELECTOR INVENTORY. Every function the ABI declares must appear as a PUSH4 in the runtime
    # dispatcher. One that does not is declared and unreachable, which is a linking or codegen
    # defect and not something source review can see - the source says the function is there.
    abi_sel = set()
    for e in art.get("methodIdentifiers", {}).values():
        abi_sel.add(e.lower())
    missing = sorted(abi_sel - push4)
    if missing:
        problems.append(f"{name}: {len(missing)} declared function(s) have no selector in the "
                        f"dispatcher - declared and unreachable: {', '.join(missing[:6])}")
    # THE OPTIMISER IS AN UNREACHABILITY PROVER, and nobody has asked it what it proved.
    # Every refusal in the source names an error and an argument. Both are emitted as constants.
    # If a code that the source still contains has NO path in the artefact that can produce it,
    # the optimiser proved the condition impossible - so either the guard is dead code wearing
    # the costume of a defence, or the optimiser is wrong, and the second is worse. Either way
    # it is a fact about the shipped contract that no source review and no test can reach.
    #
    # Detection is coarse on purpose: the error selector must appear as a PUSH constant, and the
    # numeric argument as an immediate somewhere in the code. A missing selector is strong
    # evidence; a present one proves only that some path mentions it.
    src_codes = set()
    for sp in sorted(glob.glob(os.path.join(ROOT, "src", "*.sol"))):
        body = open(sp).read()
        if os.path.basename(sp)[:-4] not in name: continue
        for m in re.finditer(r"revert\s+(\w+)\s*\(\s*(\d+)\s*\)", body):
            src_codes.add((m.group(1), int(m.group(2))))
    imm = set()
    for _o, op, i2 in walk(obj):
        if 0x60 <= op <= 0x7f and i2:
            v = int.from_bytes(i2, "big")
            if v < 256: imm.add(v)
    gone = sorted({f"{e}({n})" for e, n in src_codes if n not in imm})
    if gone:
        problems.append(f"{name}: refusal code(s) present in source but with no matching "
                        f"immediate in the artefact - the optimiser may have proved them "
                        f"unreachable: {', '.join(gone)}")
    row = {"contract": name, "bytes": (len(obj) - 2) // 2,
           "src_refusal_codes": len(src_codes), "codes_absent_from_artefact": len(gone),
           "unlinked_libs": len(LIB_REF.findall(obj)),
           "selectors_declared": len(abi_sel), "selectors_missing": len(missing),
           **counts}
    for op, label in FORBIDDEN.items():
        if op in ops:
            problems.append(f"{name}: emits {label}, which nothing in this system may do")
        row[label] = op in ops
    for op, label in REQUIRED_SOMEWHERE.items():
        row[label] = op in ops
    rows.append(row)

# The lock is the property the February 2026 miscompilation would break: it must be transient,
# and if TSTORE ever disappears from the executor the guard silently became persistent storage -
# which still passes every source-level test, and is a different contract.
router = next((r for r in rows if r["contract"] == "BlazePhoenixRouter"), None)
if router and not (router.get("TLOAD") and router.get("TSTORE")):
    problems.append("BlazePhoenixRouter: no transient opcodes in the artefact - the reentrancy "
                    "lock and the fee-on-transfer probes are supposed to be transient. If the "
                    "source still says tload/tstore, the compiler did not emit them.")

print(f"{'CONTRACT':22} {'bytes':>6} {'sel':>4} {'DELEGATE':>8} {'SSTORE':>7} {'CALL':>5} "
      f"{'STATIC':>7}  TLOAD/TSTORE")
print("-" * 78)
for r in sorted(rows, key=lambda r: r["contract"]):
    print(f"{r['contract']:22} {r['bytes']:6} {r['selectors_declared']:4} "
          f"{r.get('DELEGATECALL',0):8} {r.get('SSTORE',0):7} {r.get('CALL',0):5} "
          f"{r.get('STATICCALL',0):7}  {'yes' if r.get('TLOAD') else '-':^5}"
          f"{'yes' if r.get('TSTORE') else '-':^6}")
print(f"\nartefacts read                : {len(targets)}")
print(f"bytecode invariants broken    : {len(problems)}")
for p in problems:
    print("  BROKEN:", p)
if not targets:
    print("  (no artefacts - run a build first; this check is a no-op on a clean tree)")

json.dump({"artefacts": len(targets), "problems": problems, "rows": rows},
          open(os.path.join(ROOT, "assurance-bytecode.json"), "w"), indent=1)
sys.exit(1 if problems else 0)
