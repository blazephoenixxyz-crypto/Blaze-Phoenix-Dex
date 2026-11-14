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

# SHAPE GUARDS. Not every guard refuses: some reshape a value and carry on (a halved step, a
# fail-closed seed). The `revert` screen above cannot see them, so they are registered by hand,
# each with its exact source line and its evidence, and the register is checked against the code
# so that it goes stale loudly. Classes: driven-killed (a test fires it and kills its mutant),
# driven-equivalent (a test fires it; its mutant changes no output, said where the mutant would
# be), defensive-unreached (no sampled input reaches it; the evidence says how it was sampled).
SHAPE_GUARDS = [
    ("BlazePhoenixCore.sol", "if (dy >= y) dy = y / 2;", "driven-equivalent",
     "test_InputThatSwampsThePoolHalvesTheStep"),
    ("BlazePhoenixCore.sol", "if (fp == 0) return y0;", "defensive-unreached",
     "0/53517 sampled Newton runs (X, Y, A log-uniform in 1..3.4e38); K > 0 gives fp >= 1 at the seed"),
    ("BlazePhoenixCore.sol", "for (uint256 j; _solK(x, y) < K; ++j) {", "driven-killed",
     "test_ThinInputSideExitsOnTheSafeSide"),
    ("BlazePhoenixCore.sol", "if (j == 2) return y0;", "defensive-unreached",
     "0/47303 sampled Newton exits need a third climb (thin and full input sides, 2026-11-14)"),
]
stale = []
for f, line, cls, ev in SHAPE_GUARDS:
    body = open(os.path.join(ROOT, "src", f)).read()
    if body.count(line) != 1:
        stale.append(f"{f}: `{line}` found {body.count(line)} times (expected once)")
    if cls.startswith("driven") and not re.search(r"function\s+%s\s*\(" % re.escape(ev), tests):
        stale.append(f"{f}: `{line}` names {ev}, which no test defines")
print(f"shape guards registered       : {len(SHAPE_GUARDS)} ({len(stale)} stale)")
for x in stale:
    print(f"::error::shape guard register is stale: {x}")

json.dump({"sites": len(sites), "codes": len(by_code), "driven": len(driven),
           "undriven": undriven, "ambiguous_sites": ambiguous,
           "shape_guards": [{"file": f, "line": l, "class": c, "evidence": e}
                            for f, l, c, e in SHAPE_GUARDS],
           "shape_guards_stale": stale,
           "detail": sites},
          open(os.path.join(ROOT, "assurance-guard-inventory.json"), "w"), indent=1)
if stale:
    sys.exit(1)
