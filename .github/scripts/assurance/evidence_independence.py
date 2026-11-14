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
       python3 evidence_independence.py --self-test
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

_GATING = None

# A SPEC A JOB NAMES IS NOT A SPEC CI ENFORCES. The first version of this test asked whether the
# contract's name appeared anywhere in a workflow. CompositionFormalSpec is named by a job marked
# continue-on-error, CoreFormalSpec by a step ending in `|| true`, and a third spec only in a
# comment: all three came out as ("halmos", "formal") evidence while a red result could not turn
# any run red. A confirmation that cannot fail is not a confirmation. Only a command that can
# fail its workflow counts: in a step's `run`, outside comments, with no `|| true` (or `|| :`)
# on its own command, in a step and a job neither of which is continue-on-error.
_MASKED = re.compile(r"\|\|\s*(true|:)(\s|;|$)")
_COE = re.compile(r"^\s*(-\s+)?continue-on-error:\s*(true|\$\{\{)")


def _commands(run_lines):
    """The shell commands of one `run`, comments dropped, backslash continuations joined."""
    out, cur = [], ""
    for line in run_lines:
        line = re.sub(r"(^|\s)#.*$", "", line).rstrip()
        if line.endswith("\\"):
            cur += line[:-1] + " "
            continue
        cur += line
        if cur.strip():
            out.append(cur.strip())
        cur = ""
    if cur.strip():
        out.append(cur.strip())
    return out


def _gating_commands(text):
    """Every shell command in one workflow that can turn the workflow red."""
    lines = text.splitlines()
    ind = lambda l: len(l) - len(l.lstrip(" "))
    try:
        j0 = next(i for i, l in enumerate(lines) if re.match(r"^jobs:\s*$", l))
    except StopIteration:
        return []
    jobs, cur = [], None
    for l in lines[j0 + 1:]:
        if l.strip() and ind(l) == 0:
            break
        if re.match(r"^  [\w-]+:\s*$", l):
            cur = []
            jobs.append(cur)
        elif cur is not None:
            cur.append(l)
    out = []
    for body in jobs:
        if any(_COE.match(l) and ind(l) == 4 for l in body):
            continue
        steps, cur, k = [], None, None
        s0 = next((i for i, l in enumerate(body) if re.match(r"^    steps:\s*$", l)), len(body))
        for l in body[s0 + 1:]:
            m = re.match(r"^(\s*)-\s", l)
            if m and (k is None or ind(l) == k) and ind(l) > 4:
                k = ind(l)
                cur = [l]
                steps.append(cur)
            elif cur is not None and (not l.strip() or ind(l) > k):
                cur.append(l)
            elif cur is not None:
                cur = None
        for st in steps:
            if any(_COE.match(l) and ind(l.replace("-", " ", 1)) == k + 2 for l in st):
                continue
            for i, l in enumerate(st):
                m = re.match(r"^\s*(-\s+)?run:\s*(.*)$", l)
                if not m or ind(l.replace("-", " ", 1)) != k + 2:
                    continue
                head = m.group(2).strip()
                if head and head[0] not in "|>":
                    body_lines = [head]
                else:
                    body_lines = []
                    for l2 in st[i + 1:]:
                        if l2.strip() and ind(l2) <= k + 2:
                            break
                        body_lines.append(l2)
                out += [c for c in _commands(body_lines) if not _MASKED.search(c)]
    return out


def _is_run_by_ci(path, workflows=None):
    """Does a command that can fail CI name the contract this file declares?"""
    global _GATING
    if workflows is not None:
        gating = [c for w in workflows for c in _gating_commands(w)]
    else:
        if _GATING is None:
            _GATING = []
            for w in glob.glob(os.path.join(ROOT, ".github", "workflows", "*.y*ml")):
                _GATING += _gating_commands(open(w).read())
        gating = _GATING
    for m in re.finditer(r"contract\s+(\w+)", open(path).read()):
        if any(re.search(r"\b%s\b" % re.escape(m.group(1)), c) for c in gating):
            return True
    return False


def profile(bodies):
    """(n, distinct count per axis) over the bodies of evidence that run.

    A spec no gating command runs is classified ("unrun", "none") and confirms nothing, so it
    is left out on every axis: counted, it would add a tool and an environment to any property
    it names and lift a profile it does not support."""
    live = [a for a in bodies if a[2] != "unrun"]
    if not live:
        return 0, [0] * 5
    return len(live), [len(set(c)) for c in zip(*live)]


def _self_test():
    """Each way a job can name a spec without enforcing it, and the one way it does.

    Mutant that must turn this red: drop the `_MASKED` filter (or the continue-on-error skip) in
    _gating_commands, or the comment strip in _commands - a masked or commented spec then
    reports as run by CI; or drop the "unrun" filter in profile - an unrun spec then counts
    as a second tool and environment."""
    import tempfile
    sol = tempfile.NamedTemporaryFile("w", suffix=".t.sol", delete=False)
    sol.write("contract FooFormalSpec {}\n")
    sol.close()
    head = "on: [push]\njobs:\n"
    step = lambda run, coe="": (
        "      - name: s\n" + coe + "        run: " + run + "\n")
    cases = [
        ("gating step", head + "  a:\n    runs-on: x\n    steps:\n"
         + step("halmos --contract FooFormalSpec -v"), True),
        ("job continue-on-error", head + "  a:\n    continue-on-error: true\n    steps:\n"
         + step("halmos --contract FooFormalSpec -v"), False),
        ("step || true", head + "  a:\n    steps:\n"
         + step("timeout 9 halmos --contract FooFormalSpec -v || true"), False),
        ("step continue-on-error", head + "  a:\n    steps:\n"
         + step("halmos --contract FooFormalSpec", "        continue-on-error: true\n"), False),
        ("named only in a comment", head + "  a:\n    steps:\n"
         + "      - name: s\n        # test/formal/FooFormalSpec.t.sol\n        run: echo hi\n",
         False),
        ("named in a comment inside the run", head + "  a:\n    steps:\n"
         + "      - name: s\n        run: |\n          # halmos --contract FooFormalSpec\n"
         "          echo report-only\n", False),
        ("|| true on a continuation", head + "  a:\n    steps:\n"
         + "      - name: s\n        run: |\n          halmos --contract FooFormalSpec \\\n"
         "            -v || true\n", False),
        ("block run, pipefail + grep", head + "  a:\n    steps:\n"
         + "      - name: s\n        run: |\n          set -o pipefail\n"
         "          halmos --contract FooFormalSpec -v 2>&1 | tee x.log\n"
         "          ! grep -q 'loop unrolling bound' x.log\n", True),
        ("other job gates, this one masks", head + "  a:\n    continue-on-error: true\n"
         "    steps:\n" + step("halmos --contract FooFormalSpec") + "  b:\n    steps:\n"
         + step("halmos --contract BarSpec"), False),
    ]
    bad = 0
    for name, wf, want in cases:
        got = _is_run_by_ci(sol.name, [wf])
        ok = got == want
        bad += not ok
        print(("ok   " if ok else "FAIL ") + f"{name}: run by CI = {got}, expected {want}")
    os.unlink(sol.name)
    # An unrun spec beside two unit tests adds no tool, environment or confirmation.
    unit = ("production-lib", "literal", "forge", "unit", "example")
    unrun = ("hand-stated", "self", "unrun", "none", "example")
    for name, bodies, want in [
        ("unrun spec beside unit tests", [unit, unit, unrun], (2, [1, 1, 1, 1, 1])),
        ("only an unrun spec", [unrun], (0, [0] * 5)),
    ]:
        got = profile(bodies)
        ok = got == want
        bad += not ok
        cases.append(name)
        print(("ok   " if ok else "FAIL ") + f"{name}: profile = {got}, expected {want}")
    if bad:
        sys.exit("evidence_independence self-test: %d case(s) wrong" % bad)
    print("evidence_independence self-test: %d cases, each way to name a spec without "
          "enforcing it is refused" % len(cases))


if ROOT == "--self-test":
    _self_test()
    sys.exit(0)


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
    n, prof = profile([axes_of(p, t) for p, t in ev])
    rows.append({"guard": g, "n": n, "profile": prof, "min": min(prof)})

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
