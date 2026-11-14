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
"""
import importlib.util, os, re, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
# producer before consumer: each step reads files the steps above it write
STEPS = [
    ".github/scripts/assurance/covering_array.py",
    ".github/scripts/readme_stats.py",
    ".github/scripts/llms_full.py",
]
CONFLICT = re.compile(r"^(<<<<<<<|>>>>>>>)( |$)", re.M)
CMD = "python3 .github/scripts/regen.py"


def run(script, check):
    args = [sys.executable, "-I", os.path.join(ROOT, script)] + (["--check"] if check else [])
    return subprocess.run(args, cwd=ROOT).returncode


def conflicted():
    # every document llms-full.txt carries (README.md and llms.txt among them), and the file itself
    spec = importlib.util.spec_from_file_location("bp_llms_full", os.path.join(ROOT, STEPS[-1]))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    files = [rel for rel, _ in mod.DOCS if os.path.exists(os.path.join(ROOT, rel))] + ["llms-full.txt"]
    return [f for f in files
            if CONFLICT.search(open(os.path.join(ROOT, f), encoding="utf-8").read())]


def main():
    check = "--check" in sys.argv
    failed = [s for s in STEPS if run(s, check) != 0]
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
