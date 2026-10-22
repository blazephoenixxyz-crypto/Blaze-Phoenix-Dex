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
A write to an allocated pointer (`m`, `add(cd, 32)`, a memory array) is not flagged.

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


def self_test():
    bad = [
        # the F1 reader as it shipped in 7b8df77
        "let ok := staticcall(mul(GATE_QUOTE_GAS, 2), g, add(cd, 32), mload(cd), 0x00, 0x60)",
        "ok := call(gas(), t, 0, m, 68, 0, 0x60)",
        "pop(staticcall(gas(), t, p, 4, 0x20, 0x40))",
        "returndatacopy(0x00, 0x00, returndatasize())",
        "returndatacopy(0x00, 0x20, 0x60)",
        "extcodecopy(a, 0, 0, 0x80)",
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
    ]
    fails = [s for s in bad if not check(s, "fixture")] + [s for s in good if check(s, "fixture")]
    for s in fails:
        print(f"::error::scratch memory guard self-test misjudged: {s!r}")
    if fails:
        sys.exit(1)
    print(f"scratch memory guard self-test: {len(bad)} writes over 0x40 caught, {len(good)} clean sites passed")


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
            sites += len(OPS.findall(text))
            errors += check(text, p)
    for e in errors:
        print(f"::error::Scratch memory guard: {e}")
    if errors:
        sys.exit(1)
    print(f"scratch memory guard: {sites} raw call/copy sites under {root}/, none writes past 0x40")


if __name__ == "__main__":
    main()
