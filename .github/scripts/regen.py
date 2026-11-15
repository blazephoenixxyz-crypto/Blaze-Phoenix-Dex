#!/usr/bin/env python3
"""regen.py - regenerate every generated file in dependency order, or check that none is behind.

The generated files feed each other: covering_array.py writes a test file, the test count goes
into README.md and llms.txt (readme_stats.py), and llms-full.txt is README.md, llms.txt and the
other documents concatenated (llms_full.py). Running one generator alone, or two in the wrong
order, leaves the next one stale, and a branch that adds a single test turns three files red.
One command runs them all, in that order; `--check` runs every check and fails on any.

A merge conflict inside a generated region (the `repo-stats` block, llms-full.txt, the covering
array) is resolved by running this, never by taking either side: both sides carry the counts of
their own branch, and the merged tree has its own.

Usage:
  python3 .github/scripts/regen.py            # rewrite every generated file
  python3 .github/scripts/regen.py --check    # CI and pre-push: fail if any is behind the tree
  python3 .github/scripts/regen.py --self-test  # prove the order and the conflict check can go red
"""
import importlib.util, os, re, shutil, subprocess, sys, tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
# the corpus builder; its DOCS list is also the set of files the conflict check reads, named here
# and not taken from STEPS, so an edit to STEPS cannot blind the conflict check
LLMS_FULL = ".github/scripts/llms_full.py"
# producer before consumer: each step reads files the steps above it write
STEPS = [
    ".github/scripts/assurance/covering_array.py",
    ".github/scripts/readme_stats.py",
    LLMS_FULL,
]
CONFLICT = re.compile(r"^(<<<<<<<|>>>>>>>)( |$)", re.M)
CMD = "python3 .github/scripts/regen.py"


def run(script, check):
    args = [sys.executable, "-I", os.path.join(ROOT, script)] + (["--check"] if check else [])
    return subprocess.run(args, cwd=ROOT).returncode


def conflicted():
    # every document llms-full.txt carries (README.md and llms.txt among them), and the file itself
    spec = importlib.util.spec_from_file_location("bp_llms_full", os.path.join(ROOT, LLMS_FULL))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    files = [rel for rel, _ in mod.DOCS if os.path.exists(os.path.join(ROOT, rel))] + ["llms-full.txt"]
    return [f for f in files
            if CONFLICT.search(open(os.path.join(ROOT, f), encoding="utf-8").read())]


def self_test():
    # Runs this file, as it is in the working tree, on a scratch copy of the tracked tree. A step
    # dropped from STEPS, or moved before its producer, leaves a copy built from stale sources;
    # a conflict check that reads the wrong list, or crashes, misses a marker.
    tracked = subprocess.run(["git", "ls-files", "-s", "-z"], cwd=ROOT, capture_output=True,
                             check=True).stdout.decode().split("\0")
    # gitlinks (mode 160000) are submodules: no generator reads them
    paths = [e.split("\t", 1)[1] for e in tracked if e and not e.startswith("160000")]
    bad = []

    def scratch():
        d = tempfile.mkdtemp(prefix="regen-self-test-")
        for rel in paths:
            src = os.path.join(ROOT, rel)
            if os.path.isfile(src):
                os.makedirs(os.path.dirname(os.path.join(d, rel)), exist_ok=True)
                shutil.copy2(src, os.path.join(d, rel))
        return d

    def regen(d, *args):
        r = subprocess.run([sys.executable, "-I", os.path.join(d, ".github/scripts/regen.py"), *args],
                           cwd=d, capture_output=True, text=True)
        return r.returncode, r.stdout + r.stderr

    def read(d, rel):
        return open(os.path.join(d, rel), encoding="utf-8").read()

    # 1. a new test moves the README count, a new line in llms.txt moves the index; after one
    #    regen, every check passes and llms-full.txt carries both
    d = scratch()
    try:
        canary = "regen self-test canary line"
        with open(os.path.join(d, "llms.txt"), "a", encoding="utf-8") as f:
            f.write("\n" + canary + "\n")
        os.makedirs(os.path.join(d, "test"), exist_ok=True)
        with open(os.path.join(d, "test/RegenSelfTestCanary.t.sol"), "w", encoding="utf-8") as f:
            f.write("contract RegenSelfTestCanary {\n    function test_canary() public {}\n}\n")
        before = read(d, "README.md")
        rc, out = regen(d)
        rc2, out2 = regen(d, "--check")
        full = read(d, "llms-full.txt")
        if rc or rc2:
            bad.append(f"regen then --check on a changed tree exited {rc}/{rc2}: {(out + out2)[-400:]}")
        if read(d, "README.md") == before:
            bad.append("a new test did not move the README count")
        elif read(d, "README.md") not in full:
            bad.append("llms-full.txt carries a README older than the regenerated one (step order)")
        if canary not in full:
            bad.append("llms-full.txt did not pick up a change to llms.txt (a step is missing from STEPS)")
    finally:
        shutil.rmtree(d, ignore_errors=True)

    # 2. a conflict marker in prose fails --check with the conflict message, not a crash
    d = scratch()
    try:
        with open(os.path.join(d, "README.md"), "a", encoding="utf-8") as f:
            f.write("\n<<<<<<< ours\nprose\n=======\nprose\n>>>>>>> theirs\n")
        rc, out = regen(d, "--check")
        if rc == 0 or "merge conflict markers" not in out or "Traceback" in out:
            bad.append(f"a conflict marker in README.md was not reported as one (exit {rc}): {out[-400:]}")
    finally:
        shutil.rmtree(d, ignore_errors=True)

    for b in bad:
        print(f"::error::regen self-test: {b}")
    if bad:
        sys.exit(1)
    print("regen self-test: ok (changed tree regenerated in order; conflict marker caught)")


def main():
    if sys.argv[1:] == ["--self-test"]:
        return self_test()
    check = "--check" in sys.argv
    failed = []
    for s in STEPS:
        if run(s, check) != 0:
            failed.append(s)
            if not check:
                break  # a consumer must not be built from a producer that failed
    if not check and failed:
        sys.exit(f"regen: {', '.join(failed)} failed; nothing after it can be trusted")
    left = conflicted()
    if left:
        print(f"::error::merge conflict markers outside the generated blocks in {', '.join(left)}"
              " - resolve the prose by hand, then run: " + CMD)
        sys.exit(1)
    if failed:
        print(f"::error::generated files are behind the tree ({', '.join(os.path.basename(s) for s in failed)})"
              f" - run: {CMD} and commit what it rewrites")
        sys.exit(1)
    print("generated files agree with the tree" if check else "generated files regenerated")


if __name__ == "__main__":
    main()
