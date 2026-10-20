#!/usr/bin/env python3
"""Theta membership guard (2026-10-20): a question about a CLASS of kinds is asked once, of theta.

Core.THETA_ATTR gives each kind its attribute bits, and Core.kindHas / Core.kindHasAny are the
one predicate that reads them. The defect signature this codebase has confirmed more than ten
times is "a fix applied to one of two symmetric channels"; a hand-written chain such as
`k == KIND_V4 || k == KIND_V4_NATIVE` is one of those channels, because the next kind that joins
the class has to be added to every chain by someone who remembers them all. Four such chains had
come back by 2026-10-20 (Core universalQuote / universalQuoteRank, Hub candidate filter /
recordSwap shape check), with two more over KIND_V3 / KIND_ALGEBRA; all six now ask kindHas or
kindHasAny.

What the guard checks, over src/*.sol with comments stripped:
  1. A CHAIN is two comparisons of the same operand against KIND_* constants joined by || or &&.
     Every chain must be in CENSUS, keyed by (file, enclosing function, chain text), with the
     reason it is an IDENTITY question about named kinds and not a membership question. A new
     chain goes red until it is either rewritten as kindHas/kindHasAny or reviewed and pinned.
     A pinned chain that is gone also goes red, so the census cannot rot.
  2. The predicate is single: thetaOf / kindHas / kindHasAny are defined only in the Core, and
     THETA_ATTR is read only inside thetaOf.

Single comparisons (`kind == BPC.KIND_V4_NATIVE`) are identity tests and are not flagged.
Exit 0 when both hold, 1 with ::error:: lines otherwise. Usage: theta_membership_guard.py [src_dir]
"""
import os
import re
import sys

SRC = sys.argv[1] if len(sys.argv) > 1 else "src"
CORE = "BlazePhoenixCore.sol"

# (file, function, chain with whitespace collapsed) -> why it is an identity, not a membership
CENSUS = {
    # 2026-10-21 (gate-1021): the one pinned chain, Hub addFactory's V3-salt slot test, became
    # the KINDS_V3_SALT mask when KIND_EXTERNAL (the Gate) joined it; the census is empty.
}

OPERAND = r"[A-Za-z_][\w.]*(?:\[[^\]]*\])?(?:\.[A-Za-z_]\w*)*"
KIND = r"(?:BPC\.)?KIND_[A-Z0-9_]+"
CHAIN = re.compile(
    rf"(?P<v>{OPERAND})\s*(?:==|!=)\s*{KIND}"
    rf"(?:\s*(?:\|\||&&)\s*\(?\s*(?P=v)\s*(?:==|!=)\s*{KIND})+")
FUNC = re.compile(r"\bfunction\s+([A-Za-z_0-9]+)\s*\(")


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


def body_span(code, name):
    """(start, end) offsets of the body of function `name`, or None."""
    m = re.search(rf"\bfunction\s+{name}\s*\([^{{;]*\{{", code)
    if not m:
        return None
    depth, i = 1, m.end()
    while i < len(code) and depth:
        depth += {"{": 1, "}": -1}.get(code[i], 0)
        i += 1
    return m.end(), i


def enclosing(code, pos):
    last = None
    for m in FUNC.finditer(code, 0, pos):
        last = m.group(1)
    return last


errors, seen = [], set()
files = sorted(f for f in os.listdir(SRC) if f.endswith(".sol"))
for f in files:
    code = strip_comments(open(os.path.join(SRC, f)).read())
    for m in CHAIN.finditer(code):
        text = " ".join(m.group(0).split())
        line = code.count("\n", 0, m.start()) + 1
        key = (f, enclosing(code, m.start()), text)
        if key in CENSUS:
            seen.add(key)
            continue
        errors.append(f"Theta guard: {f}:{line} ({key[1]}) enumerates kinds by hand: `{text}`. "
                      f"A class question asks Core.kindHas/kindHasAny; an identity question is "
                      f"reviewed and added to CENSUS with its reason.")
    if f != CORE:
        for name in ("thetaOf", "kindHas", "kindHasAny"):
            if re.search(rf"\bfunction\s+{name}\s*\(", code):
                errors.append(f"Theta guard: {f} defines {name}; the theta predicate lives in the Core only.")
        if re.search(r"\bTHETA_ATTR\b", code):
            errors.append(f"Theta guard: {f} reads THETA_ATTR directly; ask Core.kindHas/kindHasAny.")
    else:
        body = body_span(code, "thetaOf")
        for m in re.finditer(r"\bTHETA_ATTR\b", code):
            line_start = code.rfind("\n", 0, m.start()) + 1
            declaration = re.match(r"\s*uint256\s+internal\s+constant\s+THETA_ATTR\s*=", code[line_start:])
            if declaration or (body and body[0] <= m.start() < body[1]):
                continue
            line = code.count("\n", 0, m.start()) + 1
            errors.append(f"Theta guard: {f}:{line} reads THETA_ATTR outside thetaOf.")

for key in CENSUS:
    if key not in seen:
        errors.append(f"Theta guard: the pinned chain `{key[2]}` in {key[0]} ({key[1]}) is gone; "
                      f"if it became kindHas/kindHasAny, remove it from CENSUS.")

if errors:
    for e in errors:
        print(f"::error::{e}")
    sys.exit(1)
print(f"theta guard: {len(files)} files, {len(seen)} pinned identity chain(s), every other kind "
      f"class asks Core.kindHas/kindHasAny")
