#!/usr/bin/env python3
"""How many of the confirmations behind a property are actually independent of each other.

Every other check here asks whether evidence EXISTS. This one asks whether the evidence that
exists is one hypothesis or several. Three confirmations that all derive from the same
implementation, judged by the same oracle, run by the same tool, in the same environment, under
the same method are not three confirmations. They are one, written down three times, and they
fail together the moment the thing they share is wrong.

This project has met that exactly. Around twenty assertions of the shape
`balanceOf(router) == 0` all passed, and they passed BECAUSE of a real defect: unspent input was
refunded to the executor and paid out later, so the balance ended at zero either way. Twenty
rows, one hypothesis. In the language below, profile (1,1,1,1,1).

THE PROFILE. For a property P with confirmations C1..Cn, the independence profile is the count
of DISTINCT values along five axes:

  source        which implementation produced the expected value
  oracle        a literal, the code's own output, or an independent producer
  tool          the runner that executed it - unit harness, symbolic, prover, mutation
  environment   unit, forked chain, formal, release profile
  methodology   example, property, invariant, metamorphic, mutation, proof

THE SCALAR IS THE MINIMUM, NOT THE SUM. Evidence is a chain, not a bundle. If every confirmation
uses one tool, a bug in that tool invalidates all of them at once, and independence along the
other four axes does not save you. A sum would hide the weak axis exactly as a mean hides a tail.

  assurance(P) = min over axes of the distinct count

HONEST LIMITS. The axes are inferred from where evidence lives and what it looks like, so this
is a screen. `source` in particular is approximated: two tests can import different helpers and
still inherit one idea, and no text analysis sees that. A profile is a floor on dependence, not
a proof of independence - the number can only be too generous, never too harsh.

Usage: python3 evidence_independence.py <repo_root>
"""
import json, os, re, sys, glob

ROOT = sys.argv[1] if len(sys.argv) > 1 else "."

def strip_comments(src):
    src = re.sub(r"/\*.*?\*/", " ", src, flags=re.S)
    return "\n".join(l.split("//")[0] for l in src.splitlines())

files = {}
for p in glob.glob(os.path.join(ROOT, "test", "**", "*.t.sol"), recursive=True):
    files[p] = strip_comments(open(p).read())
for p in glob.glob(os.path.join(ROOT, "certora", "specs", "*.spec")):
    files[p] = open(p).read()

CROSS = lambda t: bool(
    re.search(r"\.previewPlan\(|\.previewRoute\(|\.previewPlanExact\(", t)
    and re.search(r"\.swapExactIn\(|\.swapBestExactIn\(", t)
    and re.search(r"assert\w*\([^;]*\bpv\.|assert\w*\([^;]*preview", t))

_WORKFLOWS = None


def _is_run_by_ci(path):
    """Does any workflow name the contract this file declares?"""
    global _WORKFLOWS
    if _WORKFLOWS is None:
        _WORKFLOWS = ""
        for w in glob.glob(os.path.join(ROOT, ".github", "workflows", "*.y*ml")):
            _WORKFLOWS += open(w).read()
    for m in re.finditer(r"contract\s+(\w+)", open(path).read()):
        if m.group(1) in _WORKFLOWS:
            return True
    return False


def axes_of(path, text):
    """The five coordinates of one body of evidence."""
    # tool and environment come from where it lives
    if path.endswith(".spec"):
        tool, env = "certora", "formal"
    elif "/formal/" in path:
        # A path is not a runner. `check_` is the Halmos prefix, so `forge test` skips these
        # files entirely, and a spec no job invokes discharges nothing — one such file was
        # counted here as formal evidence for months while being executed by nothing, and was
        # cited in SHARED_QUANTITIES.md as a PIN. Classify by whether some workflow actually
        # names the contract; everything else is evidence that does not exist.
        tool, env = ("halmos", "formal") if _is_run_by_ci(path) else ("unrun", "none")
    elif "/fork/" in path:
        tool, env = "forge", "fork"
    else:
        tool, env = "forge", "unit"

    # methodology from the shape of what is written
    if re.search(r"\bfunction\s+invariant_", text):      meth = "invariant"
    elif re.search(r"\bfunction\s+testFuzz", text):      meth = "property"
    elif "Parity" in os.path.basename(path) or re.search(r"assertApproxEqRel", text):
        meth = "metamorphic"
    elif env == "formal":                                 meth = "proof"
    else:                                                 meth = "example"

    # oracle: where the expected value came from
    if CROSS(text):                                       oracle = "cross-producer"
    elif re.search(r"assert\w*\([^;]*,\s*\d", text):      oracle = "literal"
    else:                                                 oracle = "self"

    # source: which implementation the expectation is drawn from. Approximated by whether the
    # test recomputes with the production library or states the value some other way.
    src = "production-lib" if re.search(r"\bBPC\.\w+\(", text) else "hand-stated"
    return src, oracle, tool, env, meth

cat = json.load(open(os.path.join(ROOT, "docs/assurance/threats.json")))["classes"]
guards = sorted({c["guard"] for c in cat if c.get("guard")})

# A MODIFIER IS NEVER WRITTEN BY NAME IN A TEST. The first version looked for the guard symbol
# in the test text and reported nine guards - including the reentrancy lock and the admin role -
# as having no evidence at all, because a test exercises a modifier's EFFECT and never mentions
# it. The mutation register already holds the link that does not depend on naming: each mutant
# names a source line and the single test that must die to it. Guards are matched through it.
ns = {}
exec(open(os.path.join(ROOT, ".github/scripts/mutants.py")).read().split("def run(")[0], ns)
BY_GUARD = {}
for m in ns["M"]:
    for g in guards:
        if re.search(r"\b%s\b" % re.escape(g), m["old"]) or re.search(r"\b%s\b" % re.escape(g), m["nome"]):
            BY_GUARD.setdefault(g, set()).add(m["teste"])

# and the catalogue's own named test, where it has one
for c in cat:
    if c.get("guard") and c.get("test"):
        BY_GUARD.setdefault(c["guard"], set()).add(c["test"])

rows = []
for g in guards:
    ev = [(p, t) for p, t in files.items() if re.search(r"\b%s\b" % re.escape(g), t)]
    # plus every file holding a test the mutation register pairs with this guard
    for tn in BY_GUARD.get(g, ()):
        for p, t in files.items():
            if re.search(r"\bfunction\s+%s\s*\(" % re.escape(tn), t) and (p, t) not in ev:
                ev.append((p, t))
    if not ev:
        rows.append({"guard": g, "n": 0, "profile": [0] * 5, "min": 0}); continue
    cols = list(zip(*[axes_of(p, t) for p, t in ev]))
    prof = [len(set(c)) for c in cols]
    rows.append({"guard": g, "n": len(ev), "profile": prof, "min": min(prof)})

w = max(len(r["guard"]) for r in rows)
print(f"{'GUARD':{w}}  {'bodies':>6}  src orc tool env meth   min")
print("-" * (w + 40))
for r in sorted(rows, key=lambda r: (r["min"], -r["n"])):
    p = r["profile"]
    print(f"{r['guard']:{w}}  {r['n']:6}  {p[0]:3} {p[1]:3} {p[2]:4} {p[3]:3} {p[4]:4}  {r['min']:5}")

ones = [r for r in rows if r["min"] <= 1 and r["n"] > 1]
print(f"\nproperties examined            : {len(rows)}")
print(f"  with several bodies of evidence that share EVERY axis on some dimension: {len(ones)}")
print("\nA property whose minimum is 1 has n confirmations and one hypothesis along that axis.")
print("It is not wrong; it is undiversified, and it fails all at once. The minimum is the")
print("scalar because evidence is a chain: the weakest axis is the one that breaks.")
json.dump({"rows": rows, "single_axis": [r["guard"] for r in ones]},
          open(os.path.join(ROOT, "assurance-evidence-independence.json"), "w"), indent=1)
