#!/usr/bin/env python3
"""readme_stats.py - the numbers in README.md and llms.txt, computed from the tree instead of typed by hand.

A count written by hand is true on the day it is written and false some time after, with nothing
to say when. Every figure between the `repo-stats` markers in README.md, and the researcher roll
between the `researchers` markers, in both files, is produced here from the files themselves, and CI runs this
with `--check`: a file that no longer agrees with its own repository fails the build.

Usage: python3 .github/scripts/readme_stats.py [--check]
"""
import glob, importlib.util, os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
TARGETS = [os.path.join(ROOT, "README.md"), os.path.join(ROOT, "llms.txt")]


def files(pattern):
    return sorted(glob.glob(os.path.join(ROOT, pattern), recursive=True))


def count_decls(regex):
    pat = re.compile(regex, re.M)
    return sum(len(pat.findall(open(f, encoding="utf-8").read())) for f in files("test/**/*.sol"))


def mutants():
    path = os.path.join(ROOT, ".github", "scripts", "mutants.py")
    spec = importlib.util.spec_from_file_location("bp_mutants", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)  # module-level code only builds the list; main() is guarded
    return len(mod.M)


def researchers():
    text = open(os.path.join(ROOT, "SECURITY_HALL_OF_FAME.md"), encoding="utf-8").read()
    return re.findall(r"^- \*\*(.+?)\*\*\s*$", text, re.M)


def stats_block():
    rows = [
        ("Contracts in `src/`", len(files("src/*.sol")), "`src/*.sol`"),
        ("Test declarations", count_decls(r"^\s*function (?:test|invariant|check)\w*"),
         "`function test*` / `invariant*` / `check*` under `test/`"),
        ("Test files", len(files("test/**/*.t.sol")), "`test/**/*.t.sol`"),
        ("Fork suites against live liquidity", len(files("test/fork/*.t.sol")), "`test/fork/*.t.sol`"),
        ("Stateful invariants", count_decls(r"^\s*function invariant\w*"), "`function invariant*`"),
        ("Symbolic properties (Halmos)", count_decls(r"^\s*function check\w*"), "`function check*`"),
        ("Curated mutants, each paired with the test that must kill it", mutants(),
         "entries in `.github/scripts/mutants.py`"),
        ("Certora Prover specifications", len(files("certora/**/*.spec")), "`certora/**/*.spec`"),
        ("CI workflows", len(files(".github/workflows/*.yml")), "`.github/workflows/*.yml`"),
        ("Researchers credited", len(researchers()), "`SECURITY_HALL_OF_FAME.md`"),
    ]
    out = ["| Apparatus | At this commit | Counted from |", "|---|---:|---|"]
    out += [f"| {name} | {n:,} | {src} |" for name, n, src in rows]
    return "\n".join(out)


def researchers_block():
    return " · ".join(researchers())


def render(text, name):
    for tag, body in (("repo-stats", stats_block()), ("researchers", researchers_block())):
        begin, end = f"<!-- {tag}:begin -->", f"<!-- {tag}:end -->"
        pat = re.compile(re.escape(begin) + r".*?" + re.escape(end), re.S)
        if len(pat.findall(text)) != 1:
            sys.exit(f"{name} must carry exactly one {begin} ... {end} block")
        text = pat.sub(lambda _: f"{begin}\n{body}\n{end}", text)
    return text


def main():
    stale = []
    for path in TARGETS:
        name = os.path.basename(path)
        cur = open(path, encoding="utf-8").read()
        new = render(cur, name)
        if new == cur:
            continue
        if "--check" in sys.argv:
            stale.append(name)
        else:
            open(path, "w", encoding="utf-8").write(new)
            print(f"{name}: numbers regenerated")
    if stale:
        print(f"{', '.join(stale)}: numbers are behind the tree - run: python3 .github/scripts/readme_stats.py")
        sys.exit(1)
    if "--check" in sys.argv:
        print("README.md and llms.txt numbers agree with the tree")


if __name__ == "__main__":
    main()
