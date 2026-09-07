#!/usr/bin/env python3
"""Detection study for the fee seals: how often does each test notice each fee defect?

This is the producer of docs/assurance/fee-seal-detection.json. Every mutant is a
one-line change to the Router, applied to a copy of the tree in memory and written
to the working file; each test file is then run K times with K different fuzz seeds
(one run for deterministic files); the original line is written back before judging.

A KILL is a run whose output carries a `[FAIL` line: the test noticed the defect. A run
whose output carries `[PASS` and no `[FAIL` is a MISS. Anything else (a compiler error,
a missing tree, no output) is NO ANSWER and is excluded from the count, never scored
as a kill. Per (mutant, test) the script reports kills/runs with a Wilson 95 % interval
on the detection probability and, when nothing was missed, the rule-of-three bound on
the miss probability (3/n).

Usage (from the repository root, foundry installed):
  python3 .github/scripts/assurance/fee_seal_detection.py                # K=20, all mutants, all tests
  K=5 python3 .github/scripts/assurance/fee_seal_detection.py            # fewer seeds
  python3 .github/scripts/assurance/fee_seal_detection.py --only "fee doubled" --tests FeeSeals --out /tmp/x.json
  FOUNDRY_PROFILE=release python3 ...                                    # the profile the study was measured under

The working tree must be clean for src/BlazePhoenixRouter.sol: the script refuses to
start otherwise, and restores the file from its in-memory copy after every mutant
(and on interrupt).
"""
import argparse, json, math, os, signal, subprocess, sys, time

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
os.chdir(ROOT)
R = "src/BlazePhoenixRouter.sol"
OUT_DEFAULT = "docs/assurance/fee-seal-detection.json"

MUT = [
 dict(id="exhaustion charges hop 0 only (junk-prefix escape)", f=R,
      old="            if (!feeOnOut && (feeHop == type(uint256).max || h == feeHop)) {",
      new="            if (!feeOnOut && (feeHop == type(uint256).max ? h == 0 : h == feeHop)) { // MUTANT"),
 dict(id="exhaustion skips hop 0", f=R,
      old="            if (!feeOnOut && (feeHop == type(uint256).max || h == feeHop)) {",
      new="            if (!feeOnOut && (feeHop == type(uint256).max ? h != 0 : h == feeHop)) { // MUTANT"),
 dict(id="commitment counts the first leg only", f=R,
      old="        for (uint256 i; i < hop.legs.length; ) { c += hop.legs[i].amountIn; unchecked { ++i; } }\n    }",
      new="        c = hop.legs[0].amountIn; // MUTANT\n    }"),
 dict(id="fee doubled", f=R,
      old="uint256 feeH = BPC.mulDivUp(baseH, BPC.PROTOCOL_FEE_BPS, BPC.BPS);",
      new="uint256 feeH = BPC.mulDivUp(baseH, BPC.PROTOCOL_FEE_BPS * 2, BPC.BPS); // MUTANT"),
 dict(id="input-side fee never charged", f=R,
      old="if (feeH == 0) return amountIn;", new="if (feeH != 0) return amountIn; // MUTANT"),
 dict(id="fee charged on both sides", f=R,
      old="if (feeOnOut) {", new="if (feeOnOut || true) { // MUTANT"),
 dict(id="BELT ledger: settlement without a fee no longer refused", f=R,
      old="            if (paid == 0) revert RouterE(15);", new="            paid; // MUTANT"),
 dict(id="BELT ledger: anchored double payment no longer refused", f=R,
      old="            if (paid > 1 && feeHop != type(uint256).max) revert RouterE(16);", new="            // MUTANT"),
]

# (column name, test file, fuzzed?) — a fuzzed file is run once per seed, a deterministic one once.
TESTS = [
 ("FeeSeals (fuzz, every shape)", "test/FeeSeals.t.sol", True),
 ("Router fee invariants (campaign)", "test/BlazePhoenixRouter.invariant.t.sol", True),
 ("Regime covering array (deterministic)", "test/regime/RegimeCoverage.t.sol", False),
 ("Junk-prefix escape (deterministic)", "test/FeeEscapeViaJunkPrefix.t.sol", False),
 ("Exhaustion preview parity (deterministic)", "test/ExhaustionRegimePreviewParity.t.sol", False),
]


def wilson(k, n, z=1.96):
    if n == 0:
        return (0.0, 0.0)
    p = k / n
    d = 1 + z * z / n
    c = p + z * z / (2 * n)
    m = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n))
    return (round(max(0.0, (c - m) / d), 3), round(min(1.0, (c + m) / d), 3))


def forge(args, timeout=1800):
    """Run forge; return (exit code or None, combined output)."""
    try:
        r = subprocess.run(["forge"] + args, capture_output=True, text=True, timeout=timeout)
        return r.returncode, (r.stdout or "") + (r.stderr or "")
    except subprocess.TimeoutExpired:
        return None, "TIMEOUT"


def judge(code, out):
    """kill / miss / none — on the evidence in the output, never on the exit code alone."""
    if code is None or "Compiler run failed" in out or "No tests match" in out or "Error:" in out and "[FAIL" not in out:
        return "none"
    if "[FAIL" in out:
        return "kill"
    if code == 0 and "[PASS" in out:
        return "miss"
    return "none"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", action="append", default=[], help="mutant id substring (repeatable)")
    ap.add_argument("--tests", action="append", default=[], help="test column substring (repeatable)")
    ap.add_argument("--out", default=OUT_DEFAULT)
    ap.add_argument("--k", type=int, default=int(os.environ.get("K", "20")))
    a = ap.parse_args()
    seeds = [hex(0x5EED0000 + 7919 * i) for i in range(a.k)]

    # refuse to run on a dirty Router: the restore would otherwise erase someone's work
    st = subprocess.run(["git", "status", "--porcelain", R], capture_output=True, text=True).stdout.strip()
    if st:
        print(f"refusing to start: {R} has uncommitted changes", file=sys.stderr)
        sys.exit(2)
    pristine = open(R).read()

    def restore(*_):
        open(R, "w").write(pristine)
    signal.signal(signal.SIGINT, lambda *x: (restore(), sys.exit(130)))
    signal.signal(signal.SIGTERM, lambda *x: (restore(), sys.exit(143)))

    muts = [m for m in MUT if not a.only or any(s.lower() in m["id"].lower() for s in a.only)]
    tests = [t for t in TESTS if not a.tests or any(s.lower() in t[0].lower() for s in a.tests)]
    res = {}
    t0 = time.time()
    for m in muts:
        if pristine.count(m["old"]) != 1:
            print(f"TARGET LOST: {m['id']}", flush=True)
            res[m["id"]] = {"status": "target_lost"}
            continue
        row = {}
        try:
            open(R, "w").write(pristine.replace(m["old"], m["new"]))
            code, out = forge(["build"], timeout=2400)   # compile once under the mutant
            if code != 0 or "Compiler run failed" in out:
                row["compile"] = "failed"
                print(f"COMPILE FAILED under mutant: {m['id']}", flush=True)
            else:
                for name, path, fuzzy in tests:
                    kills = misses = 0
                    for s in (seeds if fuzzy else seeds[:1]):
                        if os.path.isdir("cache/invariant"):
                            subprocess.run(["rm", "-rf", "cache/invariant"])   # a persisted failure would replay
                        code, out = forge(["test", "--match-path", path, "--fuzz-seed", s])
                        v = judge(code, out)
                        kills += v == "kill"
                        misses += v == "miss"
                    n = kills + misses
                    lo, hi = wilson(kills, n)
                    row[name] = dict(kills=kills, runs=n, detection_ci95=[lo, hi],
                                     miss_upper_bound_95=(round(3 / n, 3) if n and kills == n else None))
                    print(f"  {m['id'][:46]:46} | {name[:38]:38} | {kills}/{n}  CI95 [{lo}, {hi}]", flush=True)
        finally:
            restore()
        res[m["id"]] = row

    doc = {
        "measured": time.strftime("%Y-%m-%d") + f", {os.environ.get('FOUNDRY_PROFILE', 'default')} profile; "
                    f"{a.k} fuzz seeds per fuzzed test (0x5EED0000 + 7919*i), one run per deterministic test; "
                    "a kill is a run whose output carries a [FAIL line, a miss one that passes, anything else is "
                    "excluded; Wilson 95% interval on the detection probability; rule-of-three bound on the miss "
                    "probability where nothing was missed. Producer: .github/scripts/assurance/fee_seal_detection.py",
        "question": "how often does each test notice each fee defect? A test that fits the code passes; a test "
                    "that catches is one whose detection rate of a named defect is measured.",
        "tests": [t[0] for t in tests],
        "mutants": res,
    }
    json.dump(doc, open(a.out, "w"), indent=1)
    open(a.out, "a").write("\n")
    print(f"wrote {a.out} in {int(time.time() - t0)} s; Router restored: {open(R).read() == pristine}")


if __name__ == "__main__":
    main()
