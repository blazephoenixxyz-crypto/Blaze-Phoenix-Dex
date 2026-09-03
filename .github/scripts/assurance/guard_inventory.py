#!/usr/bin/env python3
"""Backward traceability: from every refusal in the code, back to a test that drives it.

The registers in this directory run FORWARD - from a threat, to the guard that answers it, to
the test that would fail without it. That direction finds threats with no answer. It cannot
find the opposite defect: code that refuses something for a reason nobody wrote down, and that
no test has ever made fire.

Systems engineering practice calls the pair BIDIRECTIONAL TRACEABILITY, and requires both
directions to be maintained rather than established once. This repository has done the backward
direction by hand exactly once - an inventory found twelve refusal guards that no test had ever
fired, and a test file was written to drive them. Nothing recomputes that inventory, so it has
been decaying since the day it was taken.

WHAT IS COUNTED

  sites        every `revert XxxE(n)` in src/, located by its enclosing function
  codes        the distinct error codes those sites use
  driven       codes some test asserts EXACTLY (by selector and argument), not by bare revert
  ambiguous    sites that share their code with another site

The last number is the one worth reading, and it is not a coverage figure. Where two refusals
share a code, an assertion that the call reverted with that code CANNOT say which guard refused.
A test that fires one and a mutation that disables the other will still look green, because the
neighbour catches the call and produces the same bytes. Every ambiguous site needs either a
distinct code, or a control that settles cleanly through the neighbour and so pins the fire to
its site - which is what the hand inventory did, and what this counts.

An undriven code is not a bug: some refusals are unreachable by construction and are recorded as
such. It is a list to argue about, and the point of recomputing it is that the argument has to be
made again whenever the code moves.
"""
import re, os, sys, glob, json
from collections import defaultdict

ROOT = sys.argv[1] if len(sys.argv) > 1 else "."

def strip_comments(src):
    src = re.sub(r"/\*.*?\*/", " ", src, flags=re.S)
    return "\n".join(l.split("//")[0] for l in src.splitlines())

def functions(src):
    out = []
    for m in re.finditer(r"function\s+(\w+)\s*\(", src):
        i = src.find("{", m.end())
        if i < 0: continue
        d, j = 0, i
        while j < len(src):
            if src[j] == "{": d += 1
            elif src[j] == "}":
                d -= 1
                if d == 0: break
            j += 1
        out.append((m.group(1), m.start(), j))
    return out

sites = []
for p in sorted(glob.glob(os.path.join(ROOT, "src", "*.sol"))):
    src = strip_comments(open(p).read())
    fns = functions(src)
    for m in re.finditer(r"revert\s+(\w+)\s*\(\s*(\d+)\s*\)", src):
        cands = [f for f in fns if f[1] <= m.start() <= f[2]]
        fn = min(cands, key=lambda f: f[2] - f[1])[0] if cands else "?"
        sites.append({"file": os.path.basename(p), "fn": fn,
                      "code": f"{m.group(1)}({m.group(2)})"})

tests = "\n".join(open(p).read() for p in
                  glob.glob(os.path.join(ROOT, "test", "**", "*.t.sol"), recursive=True))

by_code = defaultdict(list)
for s in sites:
    by_code[s["code"]].append(s)

# LEARN THE LOCAL IDIOM RATHER THAN ASSUMING IT. Tests here wrap the selector in small
# helpers - `_err(9)`, `_hubErr(4)` - and cast the argument to whatever width the error
# declares. The first version of this screen recognised neither, and reported three codes
# as undriven that are driven on the very next line of a file whose header says so. A screen
# that only understands one spelling measures the spelling.
helpers = {}
for m in re.finditer(r"function\s+(_\w+)\s*\([^)]*\)[^{]*\{[^}]*?(\w+)\.selector", tests, re.S):
    helpers[m.group(1)] = m.group(2)

driven, undriven = [], []
for code in sorted(by_code):
    err, num = re.match(r"(\w+)\((\d+)\)", code).groups()
    # An EXACT assertion names the error AND the argument. A bare expectRevert() is not
    # evidence about this guard: it passes for any revert, including a neighbour's.
    pats = [r"%s\.selector\s*,\s*(?:uint\d*\s*\(\s*)?%s\b" % (re.escape(err), num)]
    pats += [r"%s\s*\(\s*%s\b" % (re.escape(h), num) for h, e in helpers.items() if e == err]
    # The STRONGEST form in this corpus is not expectRevert at all: the revert is caught, the
    # code decoded, and the number asserted as a value - which proves WHICH guard fired instead
    # of matching bytes that a neighbour could also produce. The first version of this screen
    # did not recognise it and so reported the reentrancy lock, the most carefully tested guard
    # in the contract, as undriven. A screen that ranks evidence must understand the evidence.
    pats += [r"assertEq\s*\(\s*\w+\s*,\s*%s\s*,[^;]*%s" % (num, re.escape(err))]
    (driven if any(re.search(p, tests) for p in pats) else undriven).append(code)

ambiguous = sum(len(v) for v in by_code.values() if len(v) > 1)

print(f"refusal sites in src/         : {len(sites)}")
print(f"distinct codes                : {len(by_code)}")
print(f"  driven by an exact assertion: {len(driven)}")
print(f"  not driven exactly          : {len(undriven)}")
print(f"sites sharing a code          : {ambiguous}/{len(sites)}"
      f"  <- a revert assertion cannot say which of these fired")
if undriven:
    print("\ncodes with no exact assertion (argue or drive; unreachable-by-construction is an answer):")
    print("  " + ", ".join(undriven))

json.dump({"sites": len(sites), "codes": len(by_code), "driven": len(driven),
           "undriven": undriven, "ambiguous_sites": ambiguous,
           "detail": sites},
          open(os.path.join(ROOT, "assurance-guard-inventory.json"), "w"), indent=1)
