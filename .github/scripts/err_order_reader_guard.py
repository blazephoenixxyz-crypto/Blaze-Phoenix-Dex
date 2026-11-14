#!/usr/bin/env python3
"""errOrder reader guard (ROUTEQ, 2026-11-13): the bound at the hop's size has ONE reader.

`Core.universalProbe` returns errOrder (WAD) without a clamp: it is not capped at WAD. The
Solver packs it into `fe` bits 88 up (`fe[i] = f | e << 24 | eo << 88`). The proof that no clamp
is needed is "min(errOrder, WAD) is what the system reads", and it holds only while the one
reader is `Math._inBand`'s `kbLo = _keep(fb, fe[b] >> 88)`, because `_keep` reads a bound past
WAD as WAD (property-tested and mutated in test/ErrOrderHasOneReader.t.sol). A second reader of
bits 88 up, or a read of bits 24 up without ERR_MASK, would see the raw unclamped value. This
guard makes "one reader" a checked fact instead of a remembered one.

What it checks, over src/*.sol with comments and strings stripped:
  1. `>> 88` occurs exactly once, in BlazePhoenixMath.sol, as `_keep(fb, fe[b] >> 88)`.
  2. `<< 88` occurs exactly once, in BlazePhoenixSolver.sol, as `fe[i] = f | e << 24 | eo << 88`.
  3. Every other indexed read of `fe[...]` is `fe[x] & FEE_MASK` or `(fe[x] >> 24) & ERR_MASK`:
     the fee (bits 0-23) and the bound at the probe (bits 24-87), neither of which reaches 88.
Exit 0 when all hold, 1 with ::error:: lines otherwise.
Usage: err_order_reader_guard.py [src_dir] | --self-test
"""
import os
import re
import sys

READER = ("BlazePhoenixMath.sol", "_keep(fb, fe[b] >> 88)")
WRITER = ("BlazePhoenixSolver.sol", "fe[i] = f | e << 24 | eo << 88")
SHR88 = re.compile(r">>\s*\(?\s*88\b")
SHL88 = re.compile(r"<<\s*\(?\s*88\b")
FE_READ = re.compile(r"\bfe\s*\[[^\]]*\]")
ALLOWED_AFTER = [
    re.compile(r"\s*&\s*FEE_MASK\b"),
]
ALLOWED_WRAPPED = re.compile(r"\(\s*$")  # `(fe[x]` then `>> 24) & ERR_MASK`
ERR_AFTER = re.compile(r"\s*>>\s*24\s*\)\s*&\s*ERR_MASK\b")


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
            out.append(" " * (min(j + 1, n) - i)); i = min(j + 1, n)
        else:
            out.append(text[i]); i += 1
    return "".join(out)


def norm(s):
    return re.sub(r"\s+", " ", s).strip()


def check(files):
    """files: {name: source}. Returns the list of errors."""
    errs, shr, shl = [], [], []
    for name, src in sorted(files.items()):
        code = strip_comments(src)
        for m in SHR88.finditer(code):
            line = code.count("\n", 0, m.start()) + 1
            text = norm(code[code.rfind("\n", 0, m.start()) + 1:code.find("\n", m.end())])
            shr.append((name, line, text))
        for m in SHL88.finditer(code):
            line = code.count("\n", 0, m.start()) + 1
            text = norm(code[code.rfind("\n", 0, m.start()) + 1:code.find("\n", m.end())])
            shl.append((name, line, text))
        for m in FE_READ.finditer(code):
            line = code.count("\n", 0, m.start()) + 1
            after = code[m.end():m.end() + 60]
            before = code[max(0, m.start() - 4):m.start()]
            if re.match(r"\s*>>\s*\(?\s*88\b", after) or re.match(r"\s*=[^=]", after):
                continue  # the one reader (rule 1) and the one writer (rule 2) are counted there
            if any(p.match(after) for p in ALLOWED_AFTER):
                continue
            if ALLOWED_WRAPPED.search(before) and ERR_AFTER.match(after):
                continue
            errs.append(f"::error file=src/{name},line={line}::fe read that may reach bits 88 up "
                        f"(errOrder, unclamped): only `fe[x] & FEE_MASK`, `(fe[x] >> 24) & ERR_MASK` "
                        f"and `_keep(fb, fe[b] >> 88)` may read `fe`")
    got_r = [(f, t) for f, _, t in shr]
    if len(shr) != 1 or shr[0][0] != READER[0] or READER[1] not in shr[0][2]:
        errs.append(f"::error::`>> 88` must occur once, as `{READER[1]}` in {READER[0]}; found {got_r} "
                    f"(a second reader sees errOrder unclamped; route it through _keep)")
    if len(shl) != 1 or shl[0][0] != WRITER[0] or WRITER[1] not in shl[0][2]:
        errs.append(f"::error::`<< 88` must occur once, as `{WRITER[1]}` in {WRITER[0]}; "
                    f"found {[(f, t) for f, _, t in shl]}")
    return errs


def self_test():
    math_ok = ("uint256 fb = fe[b] & FEE_MASK;\nkb = _keep(fb, (fe[b] >> 24) & ERR_MASK);\n"
               "kbLo = _keep(fb, fe[b] >> 88);\nuint256 f = fe[i] & FEE_MASK; // fe[i] >> 88 in a comment\n")
    solver_ok = "fe[i]     = f | e << 24 | eo << 88;\n"
    base = {"BlazePhoenixMath.sol": math_ok, "BlazePhoenixSolver.sol": solver_ok}
    assert check(base) == [], check(base)
    bad = [
        dict(base, **{"BlazePhoenixMath.sol": math_ok + "uint256 x = fe[b] >> 88;\n"}),       # second reader
        dict(base, **{"BlazePhoenixMath.sol": math_ok + "uint256 y = fe[b] >> 24;\n"}),       # no ERR_MASK
        dict(base, **{"BlazePhoenixMath.sol": math_ok + "if (fe[b] > 1) y = 1;\n"}),          # whole word
        dict(base, **{"BlazePhoenixMath.sol": math_ok.replace("_keep(fb, fe[b] >> 88)", "fe[b] >> 88")}),
        dict(base, **{"BlazePhoenixCore.sol": "uint256 z = w << 88;\n"}),                     # second writer
    ]
    for k, files in enumerate(bad):
        assert check(files), f"self-test case {k} should go red"
    print("err_order_reader_guard self-test: ok (1 green, %d red)" % len(bad))


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "--self-test":
        self_test(); return 0
    src = sys.argv[1] if len(sys.argv) > 1 else "src"
    files = {f: open(os.path.join(src, f)).read() for f in os.listdir(src) if f.endswith(".sol")}
    errs = check(files)
    for e in errs:
        print(e)
    if not errs:
        print("err_order_reader_guard: ok (one reader of bits 88 up, inside _keep; one writer)")
    return 1 if errs else 0


if __name__ == "__main__":
    sys.exit(main())
