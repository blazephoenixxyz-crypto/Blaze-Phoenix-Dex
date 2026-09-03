#!/usr/bin/env python3
"""Epistemic homogeneity: arithmetic that adds terms of different PROVENANCE.

Physics checks dimensional homogeneity - you do not add metres to seconds. Solidity has one
numeric type, so a formula may add quantities of entirely different epistemic status and pass
the compiler, the tests and every coverage criterion.

Three provenances matter here, and they are not interchangeable:

  MEASURED   read from chain in this frame - a balance delta, a reserve, a pool's own answer
  DECLARED   supplied by the caller in calldata - a route's figures, a leg's amounts
  MODELLED   a constant, a count, or a formula over shape - a leg count, a per-leg penalty

When terms of different provenance are SUMMED or COMPARED, the weakest one dominates the
result, and the strongest one can be made irrelevant. This project has a measured instance:
an output floor computed as

    base - [ (legs - 1) * PER_LEG   +   min(impact, BPS)   +   sigma ]
             \\_______MODELLED______/     \\____MEASURED____/

saturates at nine legs from the modelled term alone, after which the measured impact term has
no effect on the result at all. It is formally present and materially inert. No type checks
that, no test noticed it, and no coverage criterion indexes it.

This is a SCREEN. It classifies identifiers by how they are assigned in the enclosing function,
which is a heuristic: a value can be measured two frames away and read as modelled here, and a
constant can be a scaling factor that carries no epistemic weight at all. Mixed provenance is
also frequently CORRECT - a measured amount times a constant rate is exactly what a fee is. The
output is a list to read, and the rows worth reading are sums and comparisons, not products:
multiplying by a constant preserves provenance, adding to one does not.

Usage: python3 provenance.py <repo_root>
"""
import re, os, sys, glob, json

ROOT = sys.argv[1] if len(sys.argv) > 1 else "."

MEASURED = re.compile(r"balanceOf|getReserves|slot0|getLiquidity|v3State|readDynamicFee"
                      r"|staticcall|universalQuote|\bbal\b|impactAcc|realImpact|delivered"
                      r"|outV2\(|outV3\(|getAmountOut")
DECLARED = re.compile(r"\b(?:route|hop|leg|ls|plan)\.")
MODELLED = re.compile(r"\b[A-Z][A-Z0-9_]{2,}\b|\.length\b")

def strip_comments(src):
    src = re.sub(r"/\*.*?\*/", " ", src, flags=re.S)
    return "\n".join(l.split("//")[0] for l in src.splitlines())

def functions(src):
    out = []
    for m in re.finditer(r"function\s+(\w+)\s*\(([^)]*)\)", src):
        i = src.find("{", m.end())
        if i < 0: continue
        d, j = 0, i
        while j < len(src):
            if src[j] == "{": d += 1
            elif src[j] == "}":
                d -= 1
                if d == 0: break
            j += 1
        params = [re.findall(r"(\w+)\s*$", p.strip()) for p in m.group(2).split(",") if p.strip()]
        out.append({"name": m.group(1), "params": [p[0] for p in params if p],
                    "body": src[i:j], "start": m.start(), "end": j})
    return out


def direct(text):
    """Provenance readable from the text itself, with no lookup."""
    if MEASURED.search(text): return "MEASURED"
    if DECLARED.search(text): return "DECLARED"
    if MODELLED.search(text): return "MODELLED"
    return None


ROOTSRC = sorted(glob.glob(os.path.join(ROOT, "src", "*.sol")))
ALL = "\n".join(strip_comments(open(p).read()) for p in ROOTSRC)
FNS = {}
for p in ROOTSRC:
    for fn in functions(strip_comments(open(p).read())):
        fn["file"] = os.path.basename(p)
        FNS[fn["name"]] = fn

# PASS 1 - locals, from their own assignments.
LOCALS = {}
for name, fn in FNS.items():
    m = {}
    for a in re.finditer(r"\b(\w+)\s*=\s*([^;]{0,200});", fn["body"]):
        d = direct(a.group(2))
        if d: m.setdefault(a.group(1), d)
    LOCALS[name] = m

# PASS 2 - parameters, from what CALLERS pass at that position. Without this the screen misses
# the one instance it was built for: an output floor that adds a modelled term to a measured
# one, where the measured term arrives as a parameter and looks modelled when read locally.
# Calls are matched with an optional library prefix, because `BPC.f(...)` is how every call to
# the shared library is written here and a pattern that forbids the dot sees none of them.
PARAM_PROV = {}
for callee, fn in FNS.items():
    if not fn["params"]: continue
    for caller, cf in FNS.items():
        for call in re.finditer(r"(?:\b\w+\.)?\b%s\s*\(([^;]{0,300}?)\)" % re.escape(callee),
                                cf["body"]):
            args = [a.strip() for a in re.split(r",(?![^()]*\))", call.group(1))]
            if len(args) != len(fn["params"]): continue
            for pname, arg in zip(fn["params"], args):
                d = direct(arg) or LOCALS.get(caller, {}).get(arg.strip())
                if d == "MEASURED" or (d and (callee, pname) not in PARAM_PROV):
                    PARAM_PROV[(callee, pname)] = d


def classify(term, fname):
    d = direct(term)
    ids = re.findall(r"[A-Za-z_]\w*", term)
    # a local's own assignment beats the raw text: `impShv = min(impactBps, BPS)` is measured,
    # even though the only capitalised name in it is a scaling constant
    for i in ids:
        if i in LOCALS.get(fname, {}):
            lv = LOCALS[fname][i]
            if lv == "MEASURED": return lv
            d = d or lv
    for i in ids:
        if (fname, i) in PARAM_PROV:
            pv = PARAM_PROV[(fname, i)]
            if pv == "MEASURED": return pv
            d = d or pv
    # one hop: a local assigned from something that is itself a parameter or a measured local
    for i in ids:
        m = re.search(r"\b%s\s*=\s*([^;]{0,200});" % re.escape(i), FNS.get(fname, {}).get("body", ""))
        if m:
            for j in re.findall(r"[A-Za-z_]\w*", m.group(1)):
                if (fname, j) in PARAM_PROV and PARAM_PROV[(fname, j)] == "MEASURED":
                    return "MEASURED"
                if LOCALS.get(fname, {}).get(j) == "MEASURED":
                    return "MEASURED"
    return d or "?"


rows = []
for name, fn in FNS.items():
    for line in fn["body"].splitlines():
        line = line.strip()
        if not re.search(r"[A-Za-z_)\]]\s*[+\-]\s*[A-Za-z_(]", line): continue
        terms = [t.strip() for t in re.split(r"\s[+\-]\s", line) if t.strip()]
        if len(terms) < 2: continue
        provs = {classify(t, name) for t in terms}
        provs.discard("?")
        if len(provs) > 1:
            rows.append({"file": fn["file"], "fn": name,
                         "provenances": sorted(provs), "line": line[:110]})

mix = {}
for r in rows:
    mix[tuple(r["provenances"])] = mix.get(tuple(r["provenances"]), 0) + 1
print(f"mixed-provenance sums/comparisons : {len(rows)}")
for k, v in sorted(mix.items(), key=lambda kv: -kv[1]):
    print(f"  {' + '.join(k):34} {v}")
print("\nMEASURED mixed with MODELLED - where a model can dominate a measurement:")
n = 0
for r in rows:
    if "MEASURED" in r["provenances"] and "MODELLED" in r["provenances"]:
        n += 1
        if n <= 20:
            print(f"  {r['file'][12:-4]:8} {r['fn']:24} {r['line']}")
print(f"  ({n} total)")
json.dump({"mixed": len(rows), "by_kind": {" + ".join(k): v for k, v in mix.items()},
           "rows": rows},
          open(os.path.join(ROOT, "assurance-provenance.json"), "w"), indent=1)
