"""Self-test of the mutant instrument (.github/scripts/mutants.py). No forge: `main()` runs in a
scratch directory against a one-entry catalogue and a stand-in `forge` that is green while the
source is pristine and, with the mutant in, prints what a real run of that kind prints.

    python3 .github/scripts/test_mutants_instrument.py -v

WHAT IT PINS (2026-11-12, selar F01; MUT-2 of atq-1111, red at e6253a6 and at integ 2e4fdaa).
A kill is a [FAIL] line, or a snapshot difference, that names the paired test. Everything else
fails the guard under its own name: a run that never reached its test (137, 124, 101), a tree
that did not compile, a red setUp, another test failing, a name that also selects a longer name,
one name in two contracts. Every forge call carries the same fixed fuzz seed.

THE INSTRUMENT HAS ITS OWN MUTANTS. `DRIVER_MUTANTS` edits mutants.py in memory and loads the
copy; each edit must turn its named case red, or the case is decorative.
"""
import contextlib, importlib.util, io, os, re, shlex, stat, sys, tempfile, unittest

HERE = os.path.dirname(os.path.abspath(__file__))
DRIVER = os.path.join(HERE, "mutants.py")
CAUGHT = "1/1 guards with a test that catches them"
SEED = "0xb1a2ef00"
KILL = "ok %s"  # the label of a kill, by its route

# The stand-in: the tests it knows are test_x and test_xLonger (a longer name with the paired name
# as a prefix). It filters them with --match-test exactly as a regex on the signature, logs every
# call, and with the mutant in prints the output of FAKE_FORGE_MODE.
FAKE_FORGE = r'''#!PYTHON
import os, re, sys
argv = sys.argv[1:]
with open(os.environ["FAKE_FORGE_LOG"], "a") as f:
    f.write(" ".join(argv) + "\n")
mode = os.environ["FAKE_FORGE_MODE"]
mutated = "// MUTANT" in open("src/X.sol").read()
pat = argv[argv.index("--match-test") + 1] if "--match-test" in argv else None
known = ["test_x()", "test_xLonger()"]
sel = [s[:-2] for s in known if pat is None or re.search(pat, s)]
if not sel:  # what forge v1.8.5 prints, exit 0
    print("Warning: no tests match the provided pattern:\n\tmatch-test: `%s`" % pat); sys.exit(0)
def out(*lines, rc=1):
    print("\n".join(lines)); sys.exit(rc)
if not mutated:
    if mode == "basered":
        out("[FAIL: 2 != 1; counterexample: calldata=0x01 args=[26]] test_x(uint256) (runs: 3, μ: 1, ~: 1)")
    out(*["[PASS] %s() (gas: 1)" % t for t in sel], rc=0)
if os.environ.get("FAKE_FORGE_OUT"): out(*os.environ["FAKE_FORGE_OUT"].split("\n"))
if mode in ("assert", "inert"):  out("[FAIL: assertion failed: 1 != 2] test_x() (gas: 1)")
if mode == "halt":    out("[FAIL: panic: arithmetic underflow or overflow (0x11)] test_x() (gas: 1)")
if mode == "custom":  out("[FAIL: RouterE(5)] test_x() (gas: 1)")
if mode == "fuzz":    out("[FAIL: delivered: 1 != 2; counterexample: calldata=0x01 args=[[1, 2], 3]] test_x(uint256) (runs: 3, μ: 1, ~: 1)")
if mode == "invariant":
    out("[FAIL: paid <= distributed: 2 > 1]", "\t[Sequence] (original: 2, shrunk: 1)",
        "\t\tsender=0x01 addr=[test/X.t.sol:H]0x02 calldata=f() args=[]",
        " test_x() (runs: 1, calls: 1, reverts: 0)")
if mode == "invinline": out("[FAIL: held: 1 != 0] test_x", "\t[Sequence] (original: 1, shrunk: 1)")
if mode == "snapshot": out("[PASS] test_x() (gas: 1)", "[test_x] Failed to match snapshots:", "-test_x: 1", "+test_x: 2")
if mode == "snapother": out("[PASS] test_x() (gas: 1)", "[test_other] Failed to match snapshots:")
if mode == "pass":    out("[PASS] test_x() (gas: 1)", rc=0)
if mode == "compile": out("Compiler run failed:", "Error (7576): Undeclared identifier.")
if mode == "missing": out("Warning: no tests match the provided pattern:", "\tmatch-test: `^(test_x)(\\(.*)?$`", rc=0)
if mode == "silent":  sys.exit(0)
if mode == "message": out("[FAIL: door 3 refused] test_x() (gas: 1)")
if mode == "customword": out("[FAIL: Staking__DeltaTooBig()] test_x() (gas: 1)")
if mode == "setup":   out("[FAIL: AdapterE(3)] setUp() (gas: 0)")
if mode == "other":   out("[FAIL: assertion failed] test_other() (gas: 1)")
if mode in ("prefix", "tuple"):
    out(*[("[FAIL: assertion failed] %s() (gas: 1)" if t == "test_xLonger" else "[PASS] %s() (gas: 1)") % t for t in sel],
        rc=1 if "test_xLonger" in sel else 0)
if mode == "ambiguous": out("[PASS] test_x() (gas: 1)", "[FAIL: assertion failed] test_x() (gas: 1)")
if mode in ("hang", "hanginert"):
    import time; time.sleep(15); sys.exit(99)
if mode == "oom":     sys.exit(137)
if mode == "timeout": sys.exit(124)
if mode == "crash":   sys.stderr.write("thread 'main' panicked\n"); sys.exit(101)
sys.exit(99)
'''.replace("PYTHON", sys.executable)

# mode -> how the run must be scored: (route of a kill, or None for no kill; the label printed)
CASES = {
    "assert":    ("assert", "ok assert"),
    "halt":      ("halt", "ok halt"),
    "custom":    ("halt", "ok halt"),
    "fuzz":      ("assert", "ok assert"),
    "invariant": ("assert", "ok assert"),
    "invinline": ("assert", "ok assert"),
    "snapshot":  ("snapshot", "ok snapshot"),
    "snapother": (None, "DECORATIVE"),
    "pass":      (None, "DECORATIVE"),
    "compile":   (None, "NO COMPILE"),
    "missing":   (None, "TEST MISSING"),
    # exit 0 and no result for the paired test: the line that decides a missing test on forge v1.8.5
    "silent":    (None, "TEST MISSING"),
    # a bare message (assertTrue with a message, or a require string): neither halt nor assert
    "message":   ("unread", "ok unread"),
    # a decoded custom error is a halt even when its name holds an assert word
    "customword": ("halt", "ok halt"),
    # a pairing with two tests: the kill is the named failure of either (last: it keeps the tuple)
    "tuple":     ("assert", "ok assert"),
    "setup":     (None, "NEIGHBOUR"),
    "other":     (None, "NEIGHBOUR"),
    "prefix":    (None, "DECORATIVE"),
    "ambiguous": (None, "AMBIGUOUS"),
    "oom":       (None, "NO EVIDENCE"),
    "timeout":   (None, "NO EVIDENCE"),
    "crash":     (None, "NO EVIDENCE"),
    "basered":   (None, "BASELINE RED"),
    # the run passed MUTANTS_TIMEOUT: killed, no kill, and read before INERT
    "hang":      (None, "TIMEOUT"),
    "hanginert": (None, "TIMEOUT"),
    # the target is gone from the source: one verdict for the mutant all the same
    "lost":      (None, "TARGET LOST"),
}

# (mutant of the instrument, old, new, the case it must turn red). Each `old` occurs once.
DRIVER_MUTANTS = [
    ("MUT-2 back: the full reading only for snapshot owners, any other non-zero exit is a kill",
     '            verdict, how, detail = classify(m["teste"], rc, out)\n',
     '            verdict, how, detail = (classify(m["teste"], rc, out) if rc == 0 or os.path.exists(os.path.join("snapshots", m["teste"] + ".json")) else ("KILLED", "exit", ""))\n',
     "oom"),
    ("the paired name unanchored again", 'return "^(" + "|".join(names) + ")(\\\\(.*)?$"', 'return "|".join(names)', "pattern"),
    ("the mutant run drops the fixed seed", '["forge", "test", "--match-test", pattern(t), "--fuzz-seed", FUZZ_SEED]',
     '["forge", "test", "--match-test", pattern(t)]', "seed"),
    ("the baseline drops the fixed seed", '["forge", "test", "--fuzz-seed", FUZZ_SEED] + SNAPSHOT_FLAGS',
     '["forge", "test"] + SNAPSHOT_FLAGS', "seed"),
    ("a failed build is not told apart", '    if "Compiler run failed" in out:\n        return "NO COMPILE"',
     '    if False:\n        return "NO COMPILE"', "compile"),
    ("a red setUp credited to the paired test", "own = [r for r in recs if r[1] in names]",
     'own = [r for r in recs if r[1] in names or r[1] == "setUp"]', "setup"),
    ("one name in two contracts read as a kill", "        if len(st) > 1:\n", "        if False:\n", "ambiguous"),
    ("the invariant name after its sequence is not read", "                    m = NAME_LINE.match(nxt)\n",
     "                    m = None\n", "invariant"),
    ("a decoded revert not read as a halt", '    if REVERT_REASON.match(head):\n        return "halt"\n',
     '    if False:\n        return "halt"\n', "halt"),
    ("a bare message read as a halt", 'return "assert" if ASSERT_REASON.search(head) else "unread"',
     'return "assert" if ASSERT_REASON.search(head) else "halt"', "message"),
    ("the assert words read before the decoded revert",
     '    if REVERT_REASON.match(head):\n        return "halt"\n    return "assert" if ASSERT_REASON.search(head) else "unread"',
     '    if ASSERT_REASON.search(head):\n        return "assert"\n    return "halt" if REVERT_REASON.match(head) else "unread"', "customword"),
    ("forge v1.8.5's no-match warning not read", '    if NO_TESTS.search(out):\n', '    if "No tests match" in out:\n', "missing"),
    ("a clean run with no result for the paired test read as a kill",
     'return "TEST MISSING", "", "the run reported no result for the paired test"',
     'return "KILLED", "assert", "the run reported no result for the paired test"', "silent"),
    ("the split credits every test of the pairing", '        red = [r for r in mine if r[0] != "PASS"]\n',
     '        red = [r for r in recs if r[1] in names and r[0] != "PASS"]\n', "split"),
    ("a survivor whose run failed elsewhere scored as a kill", '    if own:\n        return "SURVIVED"',
     '    if own and rc == 0:\n        return "SURVIVED"', "snapother"),
    ("the baseline reads names with the old pattern", '    green = {n for st, n, _ in recs if st == "PASS"}\n    red = {n for st, n, _ in recs if st != "PASS"}',
     '    green = set(re.findall(r"\\[PASS\\]\\s+(\\w+)", out))\n    red = set(re.findall(r"\\[FAIL[^\\]]*\\]\\s+(\\w+)", out))', "basered"),
    ("an INERT row loses its split", 'm["nome"], detail, split))',
     'm["nome"], detail, split if verdict != "INERT" else []))', "inert"),
]

# Result lines copied from real forge runs of these suites (the test renamed test_x, the rest
# verbatim). With the mutant in, the stand-in prints them instead of its own.
REAL = {
    "evmerror": ["[FAIL: EvmError: Revert] test_x() (gas: 47963990)"],
    "unknownerror": ["[FAIL: custom error 0x93dafdf1] test_x() (block: 131960000) (gas: 3849169)"],
    "customfuzz": ["[FAIL: Staking__CapExceeded(); counterexample: calldata=0x5df732e8"
                   "000000000000000000000000000000000000000000000000000000000000beef"
                   "000000000000000000000000000000000000000000000000000000000000003c"
                   "00000000000000000000000000000000000000000000000000000000000022d2"
                   "00000000000000000000000000000000000000000000000000000000000030d4"
                   " args=[48879 [4.887e4], 60, 8914, 12500 [1.25e4]]] test_x(uint256,uint256,uint256,uint256)"
                   " (runs: 0, \u03bc: 0, ~: 0)"],
    "expectmismatch": ["[FAIL: Error != expected error: Staking__InvariantBreached() != custom error 0xe327dc2a]"
                       " test_x() (gas: 3499611)"],
    "namedmessage": ["[FAIL: fee() was handed less than the budget: 99998 != 192286] test_x() (gas: 34111)"],
    # two contracts: test_x fails its assert, the contract of test_xLonger fails its setUp
    "tuplesetup": ["[FAIL: assertion failed: 0 != 10000] test_x() (gas: 7540)",
                   "[FAIL: vm.createSelectFork: could not instantiate forked environment with provider lb.drpc.live;"
                   " failed to retrieve chain ID from fork endpoint; HTTP error 403 with body:"
                   " {\"id\":1,\"jsonrpc\":\"2.0\",\"error\":{\"message\":\"User balance exceeded\",\"code\":10}}]"
                   " setUp() (gas: 0)"],
}
# pairings with two tests: test_x and test_xLonger
TUPLES = {"tuple", "tuplesetup"}
CASES.update({
    # the decoded revert forms: an EvmError, a custom error the run could not name, a custom error
    # of a fuzz test with its counterexample after it
    "evmerror": ("halt", KILL % "halt"),
    "unknownerror": ("halt", KILL % "halt"),
    "customfuzz": ("halt", KILL % "halt"),
    # an assert message that names a revert or a call is an assert, not a halt
    "expectmismatch": ("assert", KILL % "assert"),
    "namedmessage": ("assert", KILL % "assert"),
    "tuplesetup": ("assert", KILL % "assert"),
    # the source moved, the artefact did not
    "inert": (None, "INERT"),
})
# mode -> the MUTANTS_VERDICTS rows (test, verdict, route, test_verdict, detail) the run must write
ROWS = {
    "evmerror": [("test_x", "KILLED", "halt", "KILLED", "EvmError: Revert")],
    "tuple": [("test_x", "KILLED", "", "SURVIVED", "test_xLonger: assertion failed"),
              ("test_xLonger", "KILLED", "assert", "KILLED", "assertion failed")],
    "tuplesetup": [("test_x", "KILLED", "assert", "KILLED", "assertion failed: 0 != 10000"),
                   ("test_xLonger", "KILLED", "", "NOT RUN", "test_x: assertion failed: 0 != 10000")],
    "ambiguous": [("test_x", "AMBIGUOUS", "", "AMBIGUOUS", "passed in one contract and failed in another")],
    "inert": [("test_x", "INERT", "assert", "KILLED", "assertion failed: 1 != 2")],
    "missing": [("test_x", "TEST MISSING", "", "NOT RUN", "no test matches the paired name")],
    "silent": [("test_x", "TEST MISSING", "", "NOT RUN", "the run reported no result for the paired test")],
    "hanginert": [("test_x", "TIMEOUT", "", "NOT RUN", "the run passed MUTANTS_TIMEOUT and was killed")],
    "lost": [("test_x", "TARGET LOST", "", "NOT RUN", "the mutant target is not found exactly once")],
}
# mode -> what the console must print for the kill of a pairing with several tests
CONSOLE = {
    "tuple": "1/2 of the pairing red, survivor=test_x)",
    "tuplesetup": "1/2 of the pairing red, survivor=test_xLonger)",
}


def pinned(mode, out, rows):
    """Raises AssertionError unless the run of `mode` wrote the ROWS and printed the CONSOLE pinned
    for it."""
    if mode in CONSOLE:
        assert CONSOLE[mode] in out, f"{mode}: expected '{CONSOLE[mode]}' in:\n{out}"
    if mode in ROWS:
        cols = [rows[0].index(c) for c in ("test", "verdict", "route", "test_verdict", "detail")]
        got = sorted(tuple(r[c] for c in cols) for r in rows[1:] if r[0] != "-")
        assert got == sorted(ROWS[mode]), f"{mode}: verdict rows {got}"


DRIVER_MUTANTS += [
    ("a fuzz counterexample read as part of the revert", 'head = reason.split("; counterexample")[0].strip()',
     'head = reason.strip()', "customfuzz"),
    ("an EvmError not read as a halt", 'panic: |EvmError: |custom error |', 'panic: |custom error |', "evmerror"),
    ("an unnamed custom error not read as a halt", 'panic: |EvmError: |custom error |',
     'panic: |EvmError: |', "unknownerror"),
    ("a message that starts with a call read as a halt", '[A-Za-z_]\\w*\\([^()]*\\)$")', '[A-Za-z_]\\w*\\([^()]*\\)")',
     "namedmessage"),
    ("a revert named inside an assert message read as a halt", "    if REVERT_REASON.match(head):\n",
     "    if REVERT_REASON.search(head):\n", "expectmismatch"),
    ("the split reads one name in two contracts as a kill",
     '        if len({r[0] for r in mine if r[0] != "SNAPSHOT"}) > 1:\n', "        if False:\n", "ambiguous"),
    ("the split reads a test that never ran as a survivor", '"SURVIVED" if mine else "NOT RUN"', '"SURVIVED"', "tuplesetup"),
    ("the split reads a test that never ran as a kill", '"SURVIVED" if mine else "NOT RUN"',
     '"SURVIVED" if mine else "KILLED"', "tuplesetup"),
    ("the split loses how its test went red", 'rows.append((n, "KILLED", route(red[0][0], red[0][2]), red[0][2]))',
     'rows.append((n, "KILLED", "assert", red[0][2]))', "evmerror"),
    ("the verdict file gives every test the mutant's route",
     "    for i, verdict, _, _, nome, detail, split in rows:\n        for test, tv, how, reason in split:\n"
     "            r = (i, verdict, how, test, tv, nome, reason or detail)",
     "    for i, verdict, mh, _, nome, detail, split in rows:\n        for test, tv, how, reason in split:\n"
     "            r = (i, verdict, mh, test, tv, nome, reason or detail)", "tuple"),
    ("the verdict file drops each test's own reason", "r = (i, verdict, how, test, tv, nome, reason or detail)",
     "r = (i, verdict, how, test, tv, nome, detail)", "tuple"),
    ("the pairing count credits every test", 'red = sum(1 for r in split if r[1] == "KILLED")', "red = len(split)", "tuple"),
    ('a run past the timeout read as no evidence', '    if rc is None:\n        return "TIMEOUT"',
     '    if False:\n        return "TIMEOUT"', 'hang'),
    ('the run is never cut short', 'float(os.environ.get("MUTANTS_TIMEOUT", "300")))',
     'None)', 'hang'),
    ('a run cut short read as INERT', 'if verdict not in ("NO COMPILE", "TIMEOUT") and pristine',
     'if verdict != "NO COMPILE" and pristine', 'hanginert'),
    ('a lost target leaves no verdict', '            record((i, "TARGET LOST",',
     '            (lambda r: None)((i, "TARGET LOST",', 'lost'),
    ('the closing row drops a class from the tally', '    for r in rows:\n        classes',
     '    for r in rows[1:]:\n        classes', 'lost'),
    ('the verdict file written only at the end', '            ledger.writelines(ledger_lines([row]))\n',
     '            pass\n', 'assert'),
    ("the survivor of a pairing not named", '(", survivor=" + ",".join(rest) if rest else "")', '""', "tuple"),
]


def ledger(mode, rows):
    """Raises AssertionError unless the verdict file has one verdict for the one mutant and closes
    with the SHARD row that counts it: the denominator the join adds up across shards."""
    assert rows[0] == ["idx", "verdict", "route", "test", "test_verdict", "mutant", "detail"], rows[0]
    if mode == "basered":
        assert any(r[:2] == ["-", "BASELINE RED"] for r in rows), f"{mode}: no BASELINE RED row: {rows}"
    verdicts = {(r[0], r[1]) for r in rows[1:] if r[0] != "-"}
    assert len(verdicts) == 1 and next(iter(verdicts))[0] == "1", f"{mode}: verdicts {verdicts}"
    assert rows[-1][:2] == ["-", "SHARD"] and rows[-1][5] == "1/1 of 1", f"{mode}: closing row {rows[-1]}"
    assert rows[-1][6] == f"judged=1 of 1; {next(iter(verdicts))[1]} 1", f"{mode}: closing row {rows[-1]}"


def load(text=None):
    """mutants.py as a module, or `text` in its place, with a one-entry catalogue."""
    with tempfile.TemporaryDirectory() as d:
        path = os.path.join(d, "mutants_under_test.py")
        if text is None:
            with open(DRIVER) as f:
                text = f.read()
        with open(path, "w") as f:
            f.write(text)
        spec = importlib.util.spec_from_file_location("mutants_under_test", path)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
    mod.M = [dict(nome="stand-in guard", f="src/X.sol", old="guard();", new="// MUTANT", teste="test_x")]
    return mod


def verdict(mod, mode, tsv=None):
    """(exit code, stdout, forge calls) of mod.main() on one mutant whose run ends as `mode`; with
    `tsv`, the run writes its MUTANTS_VERDICTS there."""
    mod.M[0]["teste"] = ("test_x", "test_xLonger") if mode in TUPLES else "test_x"
    mod.M[0]["old"] = "absent();" if mode == "lost" else "guard();"
    cwd, path = os.getcwd(), os.environ.get("PATH", "")
    with tempfile.TemporaryDirectory() as d:
        for sub in ("src", "bin", "snapshots"):
            os.makedirs(os.path.join(d, sub))
        forge, log = os.path.join(d, "bin", "forge"), os.path.join(d, "forge.log")
        files = [(os.path.join(d, "src", "X.sol"), "guard();\n"), (forge, FAKE_FORGE), (log, "")]
        if mode.startswith("snap"):
            # test_x owns a gas snapshot group only in the snapshot cases: the other cases are the
            # 1225 pairings whose kill MUT-2 read from the exit code alone.
            files.append((os.path.join(d, "snapshots", "test_x.json"), "{}\n"))
        for name, text in files:
            with open(name, "w") as f:
                f.write(text)
        os.chmod(forge, os.stat(forge).st_mode | stat.S_IEXEC)
        out, code = io.StringIO(), 0
        saved = {k: os.environ.get(k) for k in ("MUTANTS_SHARD", "MUTANTS_SHARDS", "MUTANTS_FUZZ_SEED", "MUTANTS_VERDICTS", "MUTANTS_TIMEOUT")}
        try:
            os.chdir(d)
            for k in saved:
                os.environ.pop(k, None)
            os.environ.update(PATH=os.path.join(d, "bin") + os.pathsep + path, FAKE_FORGE_MODE=mode,
                              FAKE_FORGE_LOG=log)
            if mode in REAL:
                os.environ["FAKE_FORGE_OUT"] = "\n".join(REAL[mode])
            if tsv:
                os.environ["MUTANTS_VERDICTS"] = tsv
            if mode.startswith("hang"):
                os.environ["MUTANTS_TIMEOUT"] = "2"
            with contextlib.redirect_stdout(out):
                try:
                    mod.main()
                except SystemExit as e:
                    code = e.code if isinstance(e.code, int) else 1
            with open(os.path.join(d, "src", "X.sol")) as f:
                restored = f.read()
            with open(log) as f:
                calls = [shlex.split(l) for l in f.read().splitlines()]
        finally:
            os.chdir(cwd)
            os.environ["PATH"] = path
            for k in ("FAKE_FORGE_MODE", "FAKE_FORGE_LOG", "FAKE_FORGE_OUT", "MUTANTS_VERDICTS", "MUTANTS_TIMEOUT"):
                os.environ.pop(k, None)
            for k, v in saved.items():
                if v is not None:
                    os.environ[k] = v
    assert restored == "guard();\n", "the instrument left the mutant in the source"
    return code, out.getvalue(), calls


def check(mod, mode):
    """Raises AssertionError unless `mod` scores a run of `mode` as CASES says (or, for `seed`,
    unless every forge call carries the fixed seed)."""
    if mode == "pattern":
        for t, sig, hit in (("test_x", "test_x()", True), ("test_x", "test_xLonger()", False),
                            ("test_x", "test_x(uint256)", True), ("test_x", "test_x", True),
                            ("test_x", "not_test_x()", False), (("a", "b"), "b()", True), (("a", "b"), "ab()", False)):
            assert bool(re.search(mod.pattern(t), sig)) == hit, f"pattern({t!r}) on {sig}: expected {hit}"
        return
    if mode == "seed":
        _, out, calls = verdict(mod, "assert")
        assert len(calls) == 2, calls
        for c in calls:
            assert "--fuzz-seed" in c and c[c.index("--fuzz-seed") + 1] == SEED, f"a forge call without the seed: {c}"
        return
    if mode == "split":
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "verdicts.tsv")
            code, out, _ = verdict(mod, "tuple", tsv=path)
            with open(path) as f:
                rows = [l.rstrip("\n").split("\t") for l in f]
        head = rows[0]
        got = sorted((r[head.index("test")], r[head.index("verdict")], r[head.index("test_verdict")]) for r in rows[1:] if r[0] != "-")
        assert got == [("test_x", "KILLED", "SURVIVED"), ("test_xLonger", "KILLED", "KILLED")], f"split rows: {rows}"
        return
    kill, label = CASES[mode]
    fingerprint = mod.artefact_fingerprint
    if mode in ("inert", "hanginert"):  # the build left the artefact as it was
        mod.artefact_fingerprint = lambda *a, **k: {"x": 1}
    try:
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "verdicts.tsv")
            code, out, _ = verdict(mod, mode, tsv=path)
            with open(path) as f:
                rows = [l.rstrip("\n").split("\t") for l in f]
    finally:
        mod.artefact_fingerprint = fingerprint
    pinned(mode, out, rows)
    ledger(mode, rows)
    assert label in out, f"{mode}: expected '{label}' in:\n{out}"
    if kill:
        assert code == 0 and CAUGHT in out and f"{kill} 1" in out, f"{mode}: not scored as a kill:\n{out}"
    else:
        assert code != 0 and CAUGHT not in out, f"{mode}: scored as a kill:\n{out}"


class MutantInstrument(unittest.TestCase):
    def test_EveryKindOfRunIsScoredUnderItsOwnName(self):
        mod = load()
        for mode in CASES:
            with self.subTest(mode=mode):
                check(mod, mode)

    def test_EveryForgeCallCarriesTheFixedSeed(self):
        check(load(), "seed")

    def test_TheVerdictFileSplitsATupleByMeasuredKill(self):
        check(load(), "split")

    def test_ThePairedNameIsAnchored(self):
        check(load(), "pattern")

    def test_EveryDriverMutantIsCaughtByItsCase(self):
        with open(DRIVER) as f:
            text = f.read()
        for name, old, new, mode in DRIVER_MUTANTS:
            with self.subTest(mutant=name):
                self.assertEqual(text.count(old), 1, f"target of '{name}' not found exactly once")
                with self.assertRaises(AssertionError, msg=f"'{name}' survived its case '{mode}'"):
                    check(load(text.replace(old, new)), mode)



def joined(shards, explained="", names=("a", "b", "c", "d")):
    """(exit code, printed) of mutants_join.main on verdict files given as {name: [rows]}."""
    spec = importlib.util.spec_from_file_location("mutants_join", os.path.join(HERE, "mutants_join.py"))
    mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
    with tempfile.TemporaryDirectory() as d:
        paths = []
        for name, rows in shards.items():
            paths.append(os.path.join(d, name))
            with open(paths[-1], "w") as f:
                f.write("idx\tverdict\troute\ttest\ttest_verdict\tmutant\tdetail\n")
                f.writelines("\t".join(r) + "\n" for r in rows)
        with open(os.path.join(d, "explained.tsv"), "w") as f:
            f.write("mutant\tverdict\treason\n" + explained)
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = mod.main([os.path.join(d, "explained.tsv")] + paths, names=list(names))
    return code, out.getvalue()


def row(i, verdict, name):
    return [str(i), verdict, "", "t", "", name, ""]


def done(k, n=2, total=4, judged=2):
    return ["-", "SHARD", "", "", "", f"{k}/{n} of {total}", f"judged={judged} of {judged}"]


# shard 1 holds mutants 1 and 3, shard 2 holds 2 and 4: (i - 1) % n == k - 1
GOOD = {"v1.tsv": [row(1, "KILLED", "a"), row(3, "KILLED", "c"), done(1)],
        "v2.tsv": [row(2, "KILLED", "b"), row(4, "KILLED", "d"), done(2)]}


class MutantJoin(unittest.TestCase):
    def test_AllKilledOnceAcrossTheShardsPasses(self):
        code, out = joined(GOOD)
        self.assertEqual(code, 0, out)
        self.assertIn("total: 4 killed of 4 mutants", out)

    def test_EveryGapFailsTheJoin(self):
        cases = {
            "survivor": ({**GOOD, "v2.tsv": [row(2, "SURVIVED", "b"), row(4, "KILLED", "d"), done(2)]}, "[2] SURVIVED"),
            "timeout": ({**GOOD, "v2.tsv": [row(2, "TIMEOUT", "b"), row(4, "KILLED", "d"), done(2)]}, "[2] TIMEOUT"),
            "cut short": ({**GOOD, "v2.tsv": [row(2, "KILLED", "b")]}, "no closing SHARD row"),
            "unjudged": ({**GOOD, "v2.tsv": [row(2, "KILLED", "b"), done(2)]}, "[4] UNJUDGED"),
            "shard lost": ({"v1.tsv": GOOD["v1.tsv"]}, "shard 2/2: no verdict file"),
            "twice": ({**GOOD, "v3.tsv": [row(1, "KILLED", "a"), done(1)]}, "judged twice"),
            "baseline": ({**GOOD, "v1.tsv": [["-", "BASELINE RED", "", "t", "FAIL", "", "red"]] + GOOD["v1.tsv"]}, "BASELINE RED"),
            "other catalogue": ({**GOOD, "v1.tsv": GOOD["v1.tsv"][:2] + [done(1, total=5)]}, "the catalogue has 4"),
        }
        for name, (shards, why) in cases.items():
            with self.subTest(case=name):
                code, out = joined(shards)
                self.assertEqual(code, 1, out)
                self.assertIn(why, out)

    def test_AnExplainedVerdictPassesOnlyForItsOwnVerdict(self):
        shards = {**GOOD, "v2.tsv": [row(2, "SURVIVED", "b"), row(4, "KILLED", "d"), done(2)]}
        self.assertEqual(joined(shards, "b\tSURVIVED\tequivalent: the branch is unreachable\n")[0], 0)
        self.assertEqual(joined(shards, "b\tTIMEOUT\tslow\n")[0], 1)
        self.assertEqual(joined(shards, "b\tSURVIVED\t\n")[0], 1)


if __name__ == "__main__":
    unittest.main()
