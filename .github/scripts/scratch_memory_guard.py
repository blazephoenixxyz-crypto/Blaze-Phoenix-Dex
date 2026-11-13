#!/usr/bin/env python3
"""Scratch memory guard (F1, 2026-10-22): a raw call or copy writes into scratch, never over 0x40.

Solidity reserves 0x00-0x3f as scratch, 0x40 as the free memory pointer and 0x60 as the zero
slot. An assembly block marked "memory-safe" promises the compiler it touches only scratch and
memory it allocated; the promise is not checked. Core._gateVital broke it: it copied the three
words of Gate.vitalOf to 0x00..0x5f, the third (psi) became the free pointer, and every encoder
after it wrote at address psi (memory expansion quadratic in psi: RouterE(17) at the automatic
door for a wrapper at psi >= ~2.5e6). The fix reads words 1-2 with returndatacopy into scratch.

What the guard checks, over every .sol under src/ with comments stripped:
  1. call / staticcall / delegatecall / callcode whose output offset is a literal below 0x80:
     the output size must be a literal and offset + size <= 0x40.
  2. returndatacopy / calldatacopy / codecopy / mcopy / extcodecopy whose destination is a
     literal below 0x80: the same bound, unless the copy only feeds a revert or return in the
     same block (the bubbling idiom `returndatacopy(0, 0, returndatasize()) revert(0, ...)`).
  3. mstore / mstore8 whose offset is a literal below 0x80 and whose word reaches past 0x3f:
     only `mstore(0x40, <non-literal>)` (moving the free pointer) and `mstore(0x60, 0)` (restoring
     the zero slot) are legal there.
  4. an assembly block that hands the free pointer to Solidity (`r := mload(0x40)`, or a `let`
     copy of it assigned to an outer variable), writes through it, and never moves 0x40: the
     next allocation overwrites what the block returned.
A write to an allocated pointer (`m`, `add(cd, 32)`, a memory array) is not flagged, and neither
is a block that uses the memory past the free pointer as a temporary it does not hand out.

Exit 0 when every site holds, 1 with ::error:: lines otherwise.
Usage: scratch_memory_guard.py [src_dir]        scratch_memory_guard.py --self-test
"""
import os
import re
import sys

CALLS = {"call": 7, "callcode": 7, "staticcall": 6, "delegatecall": 6}
COPIES = {"returndatacopy": (0, 2), "calldatacopy": (0, 2), "codecopy": (0, 2), "mcopy": (0, 2),
          "extcodecopy": (1, 3)}   # name -> (index of destination, index of size)
OPS = re.compile(r"(?<![\w.])(" + "|".join(sorted(set(CALLS) | set(COPIES), key=len, reverse=True))
                 + r")\s*\(")
LIT = re.compile(r"^(0x[0-9a-fA-F]+|\d+)$")
SCRATCH_END = 0x40
RESERVED_END = 0x80


def strip_comments(text):
    text = re.sub(r"/\*.*?\*/", lambda m: "\n" * m.group(0).count("\n"), text, flags=re.S)
    return re.sub(r"//[^\n]*", "", text)


def args_at(text, i):
    """Split the argument list that opens at text[i] == '(' (balanced). -> (args, end)."""
    depth, cur, out = 0, [], []
    for j in range(i, len(text)):
        c = text[j]
        if c == "(":
            depth += 1
            if depth == 1:
                continue
        elif c == ")":
            depth -= 1
            if depth == 0:
                out.append("".join(cur).strip())
                return out, j + 1
        elif c == "," and depth == 1:
            out.append("".join(cur).strip())
            cur = []
            continue
        cur.append(c)
    return out, len(text)


def lit(s):
    return int(s, 0) if LIT.match(s) else None


def check(text, name):
    errors = []
    for m in OPS.finditer(text):
        op = m.group(1)
        args, end = args_at(text, m.end() - 1)
        if op in CALLS:
            if len(args) != CALLS[op]:
                continue   # a Solidity member call such as `.call(`, or another arity
            dst, size = args[-2], args[-1]
        else:
            di, si = COPIES[op]
            if len(args) <= si:
                continue
            dst, size = args[di], args[si]
        d = lit(dst)
        if d is None or d >= RESERVED_END:
            continue
        n = lit(size)
        if n is not None and d + n <= SCRATCH_END:
            continue
        if op in COPIES and re.match(r"\s*(revert|return)\s*\(", text[end:]):
            continue   # bubbling: the copy is the payload of a frame that ends here
        line = text.count("\n", 0, m.start()) + 1
        errors.append(f"{name}:{line}: {op} writes [{dst}, +{size}) - past the 0x40 scratch into the "
                      f"free memory pointer / zero slot. Copy only the words you read into 0x00-0x3f "
                      f"(returndatacopy), or into memory you allocated.")
    return errors


STORES = re.compile(r"(?<![\w.])(mstore8|mstore)\s*\(")
ASM = re.compile(r"(?<![\w.])assembly\s*(\(\s*\"memory-safe\"\s*\))?\s*\{")
FMP = r"mload\(\s*(?:0x40|64)\s*\)"


def check_stores(text, name):
    errors = []
    for m in STORES.finditer(text):
        args, _ = args_at(text, m.end() - 1)
        if len(args) != 2:
            continue
        d = lit(args[0])
        width = 1 if m.group(1) == "mstore8" else 32
        if d is None or d >= RESERVED_END or d + width <= SCRATCH_END:
            continue
        v = lit(args[1])
        if (d == 0x40 and v is None) or (d == 0x60 and v == 0 and width == 32):
            continue
        line = text.count("\n", 0, m.start()) + 1
        errors.append(f"{name}:{line}: {m.group(1)}({args[0]}, {args[1]}) writes the free memory pointer / "
                      f"zero slot. Only mstore(0x40, <new pointer>) and mstore(0x60, 0) belong there.")
    return errors


def asm_blocks(text):
    for m in ASM.finditer(text):
        depth = 0
        for j in range(m.end() - 1, len(text)):
            depth += {"{": 1, "}": -1}.get(text[j], 0)
            if depth == 0:
                yield m.start(), text[m.end():j]
                break


def check_handout(text, name):
    errors = []
    for start, body in asm_blocks(text):
        if re.search(r"mstore\(\s*(?:0x40|64)\s*,", body):
            continue   # the block moves the free pointer
        held = set(re.findall(r"(?:let\s+)?([A-Za-z_]\w*)\s*:=\s*" + FMP, body))
        if not held:
            continue
        outer = set(re.findall(r"(?<!let )(?<![\w.])([A-Za-z_]\w*)\s*:=\s*" + FMP, body))
        for v in held:
            outer |= set(re.findall(r"(?<!let )(?<![\w.])([A-Za-z_]\w*)\s*:=\s*(?:add\(\s*)?" + re.escape(v)
                                    + r"\b", body))
        outer = {o for o in outer if not re.search(r"let\s+" + re.escape(o) + r"\b", body)}
        writes = any(re.search(r"(?:mstore8?|mcopy|returndatacopy|calldatacopy|codecopy)\(\s*(?:add\(\s*)?"
                               + re.escape(v) + r"\b", body) for v in held)
        if outer and writes:
            line = text.count("\n", 0, start) + 1
            errors.append(f"{name}:{line}: assembly hands the free pointer to {sorted(outer)}, writes through it "
                          f"and never moves 0x40: the next allocation overwrites it. Advance 0x40.")
    return errors


def check_all(text, name):
    return check(text, name) + check_stores(text, name) + check_handout(text, name)


def self_test():
    bad = [
        # the F1 reader as it shipped in 7b8df77
        "let ok := staticcall(mul(GATE_QUOTE_GAS, 2), g, add(cd, 32), mload(cd), 0x00, 0x60)",
        "ok := call(gas(), t, 0, m, 68, 0, 0x60)",
        "pop(staticcall(gas(), t, p, 4, 0x20, 0x40))",
        "returndatacopy(0x00, 0x00, returndatasize())",
        "returndatacopy(0x00, 0x20, 0x60)",
        "extcodecopy(a, 0, 0, 0x80)",
        "mstore(0x40, 0x20)",
        "mstore(0x60, x)",
        "mstore(0x50, x)",
        "mstore(0x30, x)",
        "mstore8(0x7f, 1)",
        # F04 mutant: the block writes past the free pointer, hands it out, and does not advance it
        "assembly (\"memory-safe\") { r := mload(0x40) mstore(r, 0x20) mstore(add(r, 0x20), x) }",
        "assembly { let p := mload(0x40) mstore(p, n) r := p }",
        "assembly (\"memory-safe\") { let l := shl(5, add(mload(c), 1)) let d := mload(0x40) mcopy(d, c, l) c := d }",
    ]
    good = [
        # the F1 reader after the fix
        "let ok := staticcall(mul(GATE_QUOTE_GAS, 2), g, add(cd, 32), mload(cd), 0, 0)\n"
        "if and(ok, iszero(lt(returndatasize(), 0x60))) { returndatacopy(0x00, 0x20, 0x40) }",
        "ok := staticcall(GAS_CAP, target, add(cd, 32), mload(cd), 0x00, 0x20)",
        "if staticcall(GAS_CAP, pool, m, 4, m, 64) {}",
        "ok := staticcall(GAS_CAP, gate, add(cd, 32), mload(cd), ws, 0x80)",
        "returndatacopy(0, 0, returndatasize())\n revert(0, returndatasize())",
        "(bool ok, bytes memory r) = hub.staticcall(abi.encodeCall(I.f, (a, b, c, d, e, f)));",
        "mstore(0x40, add(e, 0x80))",
        "mstore(0x60, 0)",
        "mstore(0x20, x)",
        "assembly (\"memory-safe\") { r := mload(0x40) mstore(r, 0x20) mstore(0x40, add(r, 0x40)) }",
        "assembly (\"memory-safe\") { let m := mload(0x40) mstore(m, s) ok := staticcall(gas(), t, m, 4, 0, 0x20) }",
        "assembly (\"memory-safe\") { top := mload(0x40) }",
    ]
    fails = [s for s in bad if not check_all(s, "fixture")] + [s for s in good if check_all(s, "fixture")]
    for s in fails:
        print(f"::error::scratch memory guard self-test misjudged: {s!r}")
    if fails:
        sys.exit(1)
    print(f"scratch memory guard self-test: {len(bad)} writes over 0x40 or unallocated hand-outs caught, {len(good)} clean sites passed")


def main():
    if sys.argv[1:] == ["--self-test"]:
        self_test()
        return
    root = sys.argv[1] if len(sys.argv) > 1 else "src"
    errors, sites = [], 0
    for d, _, fs in sorted(os.walk(root)):
        for f in sorted(fs):
            if not f.endswith(".sol"):
                continue
            p = os.path.join(d, f)
            text = strip_comments(open(p).read())
            sites += len(OPS.findall(text)) + len(STORES.findall(text))
            errors += check_all(text, p)
    for e in errors:
        print(f"::error::Scratch memory guard: {e}")
    if errors:
        sys.exit(1)
    print(f"scratch memory guard: {sites} raw call/copy/store sites under {root}/, none writes past 0x40 or hands out unallocated memory")


if __name__ == "__main__":
    main()
