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
if not sel:
    print("No tests match the provided pattern"); sys.exit(1)
def out(*lines, rc=1):
    print("\n".join(lines)); sys.exit(rc)
if not mutated:
    if mode == "basered":
        out("[FAIL: 2 != 1; counterexample: calldata=0x01 args=[26]] test_x(uint256) (runs: 3, μ: 1, ~: 1)")
    out(*["[PASS] %s() (gas: 1)" % t for t in sel], rc=0)
if mode == "assert":  out("[FAIL: assertion failed: 1 != 2] test_x() (gas: 1)")
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
if mode == "missing": out("No tests match the provided pattern", rc=0)
if mode == "setup":   out("[FAIL: AdapterE(3)] setUp() (gas: 0)")
if mode == "other":   out("[FAIL: assertion failed] test_other() (gas: 1)")
if mode == "prefix":
    out(*[("[FAIL: assertion failed] %s() (gas: 1)" if t == "test_xLonger" else "[PASS] %s() (gas: 1)") % t for t in sel],
        rc=1 if "test_xLonger" in sel else 0)
if mode == "ambiguous": out("[PASS] test_x() (gas: 1)", "[FAIL: assertion failed] test_x() (gas: 1)")
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
    "setup":     (None, "NEIGHBOUR"),
    "other":     (None, "NEIGHBOUR"),
    "prefix":    (None, "DECORATIVE"),
    "ambiguous": (None, "AMBIGUOUS"),
    "oom":       (None, "NO EVIDENCE"),
    "timeout":   (None, "NO EVIDENCE"),
    "crash":     (None, "NO EVIDENCE"),
    "basered":   (None, "BASELINE RED"),
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
    ("a halt scored as an assert", 'return "assert" if ASSERT_REASON.search(reason) else "halt"', 'return "assert"', "halt"),
    ("a survivor whose run failed elsewhere scored as a kill", '    if own:\n        return "SURVIVED"',
     '    if own and rc == 0:\n        return "SURVIVED"', "snapother"),
    ("the baseline reads names with the old pattern", '    green = {n for st, n, _ in recs if st == "PASS"}\n    red = {n for st, n, _ in recs if st != "PASS"}',
     '    green = set(re.findall(r"\\[PASS\\]\\s+(\\w+)", out))\n    red = set(re.findall(r"\\[FAIL[^\\]]*\\]\\s+(\\w+)", out))', "basered"),
]


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


def verdict(mod, mode):
    """(exit code, stdout, forge calls) of mod.main() on one mutant whose run ends as `mode`."""
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
        saved = {k: os.environ.get(k) for k in ("MUTANTS_SHARD", "MUTANTS_SHARDS", "MUTANTS_FUZZ_SEED", "MUTANTS_VERDICTS")}
        try:
            os.chdir(d)
            for k in saved:
                os.environ.pop(k, None)
            os.environ.update(PATH=os.path.join(d, "bin") + os.pathsep + path, FAKE_FORGE_MODE=mode,
                              FAKE_FORGE_LOG=log)
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
            for k in ("FAKE_FORGE_MODE", "FAKE_FORGE_LOG"):
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
    kill, label = CASES[mode]
    code, out, _ = verdict(mod, mode)
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


if __name__ == "__main__":
    unittest.main()
