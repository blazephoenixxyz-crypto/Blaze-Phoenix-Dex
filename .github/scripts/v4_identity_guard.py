#!/usr/bin/env python3
"""V4 identity guard (2026-10-20): the native side of a V4 leg is derived once, in the Core.

A native V4 pool's currency0 is address(0), and every reader that builds its key has to put the
chain's coin on the right side first. That substitution was written by hand five times outside the
Router (Quoter `_hookRefusedIn` and `_simV4`, Solver `_capByLiveDepth`, `_heldShare` - in
BlazePhoenixMath since D10 - and `_quoteWithDepth`); all five then called Core.v4LegCurrencies, the orientation producer. The Router
keeps its own producer, Core.nativeMapVerified, because it settles and may only ever touch the
canonical WETH (test/Fusion1020V4LegCurrencies.t.sol proves the two name the same pool on every leg
the Router admits). Since 2026-10-21 (#52 seal) the Quoter asks nativeMapVerified too, fed the
Router's WETH through Hub.weth(): on a leg the Router REFUSES (no WETH side) the orientation
producer still named a pool, and the preview endorsed what the execution reverted with RouterE(8)
(test/Seal1021NativeParity.t.sol). The Solver keeps v4LegCurrencies on registry rows.

What the guard checks, over src/*.sol with comments stripped:
  1. A HAND DERIVATION is a test against KIND_V4_NATIVE whose branch (the block or statement an
     `if` guards, or the rest of the statement for a ternary) mentions address(0). Outside the
     Core every one must be in CENSUS, keyed by (file, enclosing function), with the reason it is
     not a copy of v4LegCurrencies. A pinned site that is gone also goes red, so the census
     cannot rot.
  2. nativeMapVerified is called outside the Core only by the census sites (the Router's own
     producer), and v4LegCurrencies / nativeMapVerified are defined only in the Core.

Known escape: a native test hoisted into a local (`bool nat = kind == KIND_V4_NATIVE;`) and
branched on later is not followed. The Hub's `addV4` does that, and it builds no key from a leg:
its caller passes the pool's real currencies.

Exit 0 when both hold, 1 with ::error:: lines otherwise. Usage: v4_identity_guard.py [src_dir]
"""
import os
import re
import sys

SRC = sys.argv[1] if len(sys.argv) > 1 else "src"
CORE = "BlazePhoenixCore.sol"

# (file, function) -> why this native branch is not a copy of Core.v4LegCurrencies
CENSUS = {
    ("BlazePhoenixRouter.sol", "_v4LegQuote"):
        "the Router's quote arm: nativeMapVerified recognises the native side by the canonical "
        "WETH, the coordinate the execution arm settles in; a leg naming no WETH is 0-quoted.",
    ("BlazePhoenixRouter.sol", "_execV4Amt"):
        "the Router's execution arm: the callback unwraps and wraps, so the native side must be "
        "the canonical WETH (RouterE(8) otherwise), not whatever side zeroForOne points at.",
    ("BlazePhoenixRouter.sol", "_recordHits"):
        "the executed leg's registry id: t0 is the WETH side because _execV4Amt proved it. Same "
        "form as v4LegCurrencies(kind, t0, t1, true); moving it is fusion phase 2 (Router margin).",
    ("BlazePhoenixQuoter.sol", "_hookRefusedIn"):
        "the preview's key check: the Router's producer (nativeMapVerified) on the Router's WETH "
        "(Hub.weth), so a native leg naming no WETH side is refused as _execV4Amt refuses it (8).",
    ("BlazePhoenixQuoter.sol", "_simV4"):
        "the dry-run's key: the same producer on the same WETH, so the pool priced is the pool the "
        "Router settles; a native leg naming no WETH side is unquotable (#52 seal).",
    ("BlazePhoenixHub.sol", "recordSwap"):
        "registration, not a leg: the swap does not carry which hop token is the wrapped one, so "
        "both orientations are tried and the 160-bit poolId truncation authenticates the match.",
}
MAP_CALLERS = {("BlazePhoenixRouter.sol", "_v4LegQuote"), ("BlazePhoenixRouter.sol", "_execV4Amt"),
               ("BlazePhoenixQuoter.sol", "_hookRefusedIn"), ("BlazePhoenixQuoter.sol", "_simV4")}

FUNC = re.compile(r"\bfunction\s+([A-Za-z_0-9]+)\s*\(")
NATIVE = re.compile(r"\bKIND_V4_NATIVE\b")


def strip_comments(text):
    """Blank out comments and string literals, keeping offsets and newlines."""
    out, i, n = [], 0, len(text)
    while i < n:
        if text.startswith("//", i):
            j = text.find("\n", i)
            j = n if j < 0 else j
            out.append(" " * (j - i)); i = j
        elif text.startswith("/*", i):
            j = text.find("*/", i + 2)
            j = n if j < 0 else j + 2
            out.append(re.sub(r"[^\n]", " ", text[i:j])); i = j
        elif text[i] == '"':
            j = i + 1
            while j < n and text[j] != '"':
                j += 2 if text[j] == "\\" else 1
            j = min(j + 1, n)
            out.append(re.sub(r"[^\n]", " ", text[i:j])); i = j
        else:
            out.append(text[i]); i += 1
    return "".join(out)


def match(code, i, o, c):
    """Offset just past the bracket that closes the one opening at code[i] == o."""
    depth = 0
    while i < len(code):
        depth += (code[i] == o) - (code[i] == c)
        i += 1
        if depth == 0:
            return i
    return i


def branch(code, pos):
    """The code a test at `pos` decides: the guarded block or statement of an enclosing `if`
    condition, else the rest of the statement (a ternary or an assignment)."""
    for m in re.finditer(r"\bif\s*\(", code[:pos]):
        start = m.end() - 1
        end = match(code, start, "(", ")")
        if start < pos < end:
            j = end
            while j < len(code) and code[j].isspace():
                j += 1
            if j < len(code) and code[j] == "{":
                return code[j:match(code, j, "{", "}")]
            return code[j:code.find(";", j) + 1]
    return code[pos:code.find(";", pos) + 1]


def enclosing(code, pos):
    last = None
    for m in FUNC.finditer(code, 0, pos):
        last = m.group(1)
    return last


errors, seen = [], set()
files = sorted(f for f in os.listdir(SRC) if f.endswith(".sol"))
for f in files:
    code = strip_comments(open(os.path.join(SRC, f)).read())
    if f == CORE:
        continue
    for name in ("v4LegCurrencies", "nativeMapVerified"):
        if re.search(rf"\bfunction\s+{name}\s*\(", code):
            errors.append(f"V4 identity guard: {f} defines {name}; the native-side producers live in the Core only.")
    for m in NATIVE.finditer(code):
        if "address(0)" not in branch(code, m.start()):
            continue
        line = code.count("\n", 0, m.start()) + 1
        key = (f, enclosing(code, m.start()))
        if key in CENSUS:
            seen.add(key)
            continue
        errors.append(f"V4 identity guard: {f}:{line} ({key[1]}) puts address(0) on a native V4 side "
                      f"by hand. Ask Core.v4LegCurrencies(kind, tIn, tOther, zeroForOne) (a registry "
                      f"row: zeroForOne = true); a site that must not is reviewed into CENSUS.")
    for m in re.finditer(r"\bnativeMapVerified\s*\(", code):
        key = (f, enclosing(code, m.start()))
        if key not in MAP_CALLERS:
            line = code.count("\n", 0, m.start()) + 1
            errors.append(f"V4 identity guard: {f}:{line} ({key[1]}) calls nativeMapVerified, the "
                          f"Router's WETH-verified producer; a reader with no WETH asks v4LegCurrencies.")

for key in CENSUS:
    if key not in seen:
        errors.append(f"V4 identity guard: the pinned native branch in {key[0]} ({key[1]}) is gone; "
                      f"if it became v4LegCurrencies, remove it from CENSUS.")

if errors:
    for e in errors:
        print(f"::error::{e}")
    sys.exit(1)
print(f"v4 identity guard: {len(files)} files, {len(seen)} pinned native branch(es), every other "
      f"native side is derived by Core.v4LegCurrencies")
