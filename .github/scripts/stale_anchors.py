#!/usr/bin/env python3
"""
stale_anchors.py — does the closure matrix still point at the code it was read from?

The matrix asserts, for each of its 107 security surfaces, that a guard exists at a
`path:line` and that named tests exercise it. Code moves. A `path:line` that has moved is
a false claim with a citation attached (imago Law V), and nothing in the artefact knows.

This tool answers one question per row: **is the evidence in this row still anchored to the
code it was read from?**  It does NOT judge the code, only the citation.

Verdicts, weakest to strongest consequence:

  FRESH         no cited file changed since the row's anchored_at revision
  SHIFTED       the cited line's content is untouched, but earlier edits moved it.
                Evidence still valid; only the coordinate rotted.  ==> AUTO-REPINNABLE
  TOUCHED       the cited line falls inside a changed hunk. The evidence rests on code that
                has since changed and a human must revalidate it.
  MISSING_TEST  a test/invariant/check function the row cites no longer exists at HEAD.
                A CLOSED row whose test was deleted is unsupported, not closed.
  MISSING_FILE  a cited source file no longer exists.
  UNANCHORED    the row cites nothing mechanically checkable. Not a defect in itself, but it
                means this tool can say nothing about it — reported so the denominator is honest.

Owner decision, 2026-09-03: a stale row fails **the closure claim, never the build**.
Therefore this script exits 0 by default. Only `--gate` exits non-zero, and `--gate` belongs
in the PUBLICATION step, never in the build job.
"""

import argparse, json, os, re, subprocess, sys
from collections import OrderedDict

CONTRACTS = {
    "Core":   "src/BlazePhoenixCore.sol",
    "Hub":    "src/BlazePhoenixHub.sol",
    "Router": "src/BlazePhoenixRouter.sol",
    "Solver": "src/BlazePhoenixSolver.sol",
    "Quoter": "src/BlazePhoenixQuoter.sol",
}

# Bare English words the citation regex would otherwise mistake for a test name.
PROSE = {"test", "tests", "tested", "testing", "tester", "testable"}

ROW_RE     = re.compile(r"^\|\s*(\d+)\s*\|")
ANCHOR_RE  = re.compile(r"\b(Core|Hub|Router|Solver|Quoter):(\d+(?:\s*,\s*\d+)*)")
TESTFN_RE  = re.compile(r"\b((?:test|invariant_|check_)[A-Za-z0-9_]+)")
HUNK_RE    = re.compile(r"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@")
REV_RE     = re.compile(r"\b([0-9a-f]{7,40})\b")


def git(repo, *args):
    r = subprocess.run(["git", "-C", repo, *args],
                       capture_output=True, text=True)
    if r.returncode != 0:
        return None
    return r.stdout


# ---------------------------------------------------------------- diff mechanics

def hunks(repo, rev, path):
    """Old-side hunks between rev..HEAD for one file. None if git could not answer."""
    out = git(repo, "diff", "-U0", f"{rev}..HEAD", "--", path)
    if out is None:
        return None
    hs = []
    for line in out.splitlines():
        m = HUNK_RE.match(line)
        if m:
            a = int(m.group(1))
            b = 1 if m.group(2) is None else int(m.group(2))
            d = 1 if m.group(4) is None else int(m.group(4))
            hs.append((a, b, d))
    return hs


def relocate(line, hs):
    """(verdict, new_line) for an old-coordinate `line` given old-side hunks."""
    shift = 0
    for a, b, d in hs:
        if b > 0 and a <= line < a + b:
            return "TOUCHED", None          # its own content changed
        if a + b <= line:
            shift += d - b                  # hunk entirely above it
    return ("SHIFTED", line + shift) if shift else ("FRESH", line)


# ---------------------------------------------------------------- test index

def test_files(repo):
    """Stems of every *.t.sol under test/ at HEAD, so we can tell a file name from a function."""
    out = git(repo, "ls-tree", "-r", "--name-only", "HEAD", "test/")
    if out is None:
        return set()
    return {os.path.basename(x)[:-6] for x in out.splitlines() if x.endswith(".t.sol")}


def disk_index(repo):
    """Function names present on DISK under test/, tracked or not.

    The matrix was written by reading the working tree. Git is what CI can run. The difference
    between the two sets is evidence that exists for its author and for nobody else.
    """
    out = subprocess.run(["grep", "-rhoE",
                          r"function +(test|invariant_|check_)[A-Za-z0-9_]+",
                          os.path.join(repo, "test")],
                         capture_output=True, text=True)
    return {l.split()[-1] for l in out.stdout.splitlines() if l.strip()}


def resolve_test(name, index, stems, on_disk=frozenset()):
    """How does this cited identifier resolve against the suite at HEAD?

    The matrix cites tests in prose, so a raw name-not-in-index check cries wolf. Three of the
    ways it is legitimately written are not defects, and conflating them with a genuinely
    dangling citation is how a tool earns the right to be ignored:
      UNTRACKED_TEST    the function exists on disk but not in git at HEAD. CI has never run it
                        and no reviewer can. Evidence that is real for its author alone.
      TRUNCATED         a prefix of a real function (`test_L289c1` -> `test_L289c1_EmptySlot0...`)
      FILE_NOT_FUNCTION names a *.t.sol file rather than a function inside it
      MISSING_TEST      resolves to nothing at all. This is the only one that is evidence loss.
    """
    if name in PROSE:
        return None
    if name in index:
        return "FRESH"
    if name in on_disk:
        return "UNTRACKED_TEST"
    if any(n.startswith(name) for n in index):
        return "TRUNCATED"
    stripped = re.sub(r"^(test_|test|invariant_|check_)", "", name).rstrip("_")
    if stripped and stripped in stems:
        return "FILE_NOT_FUNCTION"
    return "MISSING_TEST"


def test_index(repo):
    """Every test/invariant/check function declared under test/ at HEAD."""
    out = git(repo, "grep", "-h", "-oE",
              r"function +(test|invariant_|check_)[A-Za-z0-9_]+", "HEAD", "--", "test/")
    if out is None:
        return set()
    return {l.split()[-1] for l in out.splitlines() if l.strip()}


# ---------------------------------------------------------------- row parsing

def parse_rows(matrix_path):
    """[(row_no, raw_line, line_index)] plus the file's declared default revision."""
    with open(matrix_path, encoding="utf-8") as f:
        lines = f.read().splitlines()
    default_rev = None
    for l in lines[:5]:
        if "@" in l:
            m = REV_RE.search(l)
            if m:
                default_rev = m.group(1)
                break
    rows = []
    for i, l in enumerate(lines):
        m = ROW_RE.match(l)
        if m:
            rows.append((int(m.group(1)), l, i))
    return lines, rows, default_rev


def row_anchor_rev(raw, default_rev):
    """The row's own anchored_at cell, if the column exists; else the file default."""
    cells = [c.strip().strip("`") for c in raw.split("|")]
    if len(cells) > 2 and re.fullmatch(r"[0-9a-f]{7,40}", cells[2]):
        return cells[2], True
    return default_rev, False


def row_citations(raw):
    anchors = []
    for m in ANCHOR_RE.finditer(raw):
        short = m.group(1)
        for n in re.findall(r"\d+", m.group(2)):
            anchors.append((short, int(n)))
    tests = set(TESTFN_RE.findall(raw))
    return anchors, tests


# ---------------------------------------------------------------- policy

BLOCKING = {"TOUCHED", "MISSING_TEST", "MISSING_FILE", "UNTRACKED_TEST"}

def blocks_publication(verdicts):
    """Which verdicts forbid quoting this row's closure status.

    Default: TOUCHED / MISSING_TEST / MISSING_FILE block; SHIFTED does not, because it is
    arithmetic and `--repin` fixes it; UNANCHORED does not, because it was never a claim
    this tool could check. See the owner-decision block in the module docstring.
    """
    return bool(verdicts & BLOCKING)


# ---------------------------------------------------------------- main

def audit(repo, matrix_path):
    lines, rows, default_rev = parse_rows(matrix_path)
    head = (git(repo, "rev-parse", "HEAD") or "").strip()
    tests_at_head = test_index(repo)
    stems = test_files(repo)
    on_disk = disk_index(repo)
    hunk_cache = {}
    results = []

    for row_no, raw, idx in rows:
        rev, from_column = row_anchor_rev(raw, default_rev)
        anchors, tests = row_citations(raw)
        detail, verdicts = [], set()

        for short, line in anchors:
            path = CONTRACTS[short]
            key = (rev, path)
            if key not in hunk_cache:
                hunk_cache[key] = hunks(repo, rev, path)
            hs = hunk_cache[key]
            if hs is None:
                v, new = "MISSING_FILE", None
            elif not hs:
                v, new = "FRESH", line
            else:
                v, new = relocate(line, hs)
            verdicts.add(v)
            detail.append({"kind": "anchor", "cite": f"{short}:{line}",
                           "path": path, "verdict": v, "now": new})

        for t in sorted(tests):
            v = resolve_test(t, tests_at_head, stems, on_disk)
            if v is None or v == "FRESH":
                continue
            verdicts.add(v)
            detail.append({"kind": "test", "cite": t, "verdict": v})

        if not anchors and not tests:
            verdicts.add("UNANCHORED")

        order = ["MISSING_FILE", "MISSING_TEST", "UNTRACKED_TEST", "TOUCHED",
                 "FILE_NOT_FUNCTION", "TRUNCATED", "SHIFTED", "UNANCHORED"]
        worst = next((v for v in order if v in verdicts), "FRESH")

        results.append({
            "row": row_no, "anchored_at": rev, "from_column": from_column,
            "verdict": worst, "blocks": blocks_publication(verdicts),
            "n_anchors": len(anchors), "n_tests": len(tests),
            "detail": [d for d in detail if d["verdict"] != "FRESH"],
        })

    return {"head": head, "default_rev": default_rev,
            "matrix": os.path.basename(matrix_path),
            "tests_at_head": len(tests_at_head), "rows": results}


def add_column(matrix_path, rev, out_path):
    """Backfill the anchored_at column: every row was read at the file's declared revision."""
    with open(matrix_path, encoding="utf-8") as f:
        lines = f.read().splitlines()
    out, done_header, done_sep = [], False, False
    for l in lines:
        if not done_header and l.startswith("| # |"):
            out.append(l.replace("| # |", "| # | Anchored at |", 1)); done_header = True
        elif done_header and not done_sep and re.match(r"^\|[-\s|]+\|$", l):
            out.append(l.replace("|---|", "|---|---|", 1)); done_sep = True
        elif ROW_RE.match(l):
            i = l.index("|", 1)
            out.append(l[:i + 1] + f" `{rev}` |" + l[i + 1:])
        else:
            out.append(l)
    with open(out_path, "w", encoding="utf-8") as f:
        f.write("\n".join(out) + "\n")
    return done_header and done_sep


def repin(matrix_path, rep, head):
    """Rewrite SHIFTED coordinates in place and bump those rows' anchored_at to HEAD.

    Refuses any row carrying a blocking verdict: bumping the revision on a row that still needs a
    human review would erase the only record that it does. Arithmetic only, never judgement.
    """
    with open(matrix_path, encoding="utf-8") as f:
        lines = f.read().splitlines()
    by_row = {r["row"]: r for r in rep["rows"]}
    moved = 0
    rows_done = []
    for i, l in enumerate(lines):
        m = ROW_RE.match(l)
        if not m:
            continue
        r = by_row.get(int(m.group(1)))
        if not r or r["blocks"]:
            continue
        shifts = [d for d in r["detail"] if d["verdict"] == "SHIFTED"]
        if not shifts:
            continue
        new = l
        for d in shifts:
            short, old = d["cite"].split(":")
            new = re.sub(r"\b" + short + r":" + old + r"\b",
                         f"{short}:{d['now']}", new)
            moved += 1
        cells = new.split("|")
        if len(cells) > 2 and re.fullmatch(r"\s*`?[0-9a-f]{7,40}`?\s*", cells[2]):
            cells[2] = f" `{head[:7]}` "
            new = "|".join(cells)
        lines[i] = new
        rows_done.append(r["row"])
    with open(matrix_path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
    return moved, rows_done


def render(rep):
    by = OrderedDict((k, 0) for k in
                     ["FRESH", "SHIFTED", "TRUNCATED", "FILE_NOT_FUNCTION", "TOUCHED",
                      "UNTRACKED_TEST", "MISSING_TEST", "MISSING_FILE", "UNANCHORED"])
    for r in rep["rows"]:
        by[r["verdict"]] += 1
    blocking = [r for r in rep["rows"] if r["blocks"]]
    per_cite = OrderedDict((k, 0) for k in by)
    for r in rep["rows"]:
        for d in r["detail"]:
            per_cite[d["verdict"]] = per_cite.get(d["verdict"], 0) + 1
    L = [f"# ANCHOR FRESHNESS — {rep['matrix']} vs `{rep['head'][:7]}`", "",
         f"Rows: **{len(rep['rows'])}**  ·  test functions in git at HEAD: **{rep['tests_at_head']}**",
         "",
         "Two different denominators, kept apart on purpose: a **row** carries its worst verdict,",
         "so one bad citation hides every other verdict in that row. Read the citation column when",
         "you want to know what actually happened.", "",
         "| Verdict | Rows (worst-of) | Citations |", "|---|---|---|"]
    L += [f"| {k} | {v} | {per_cite.get(k, 0)} |" for k, v in by.items()]
    L += ["", f"**Blocks the closure claim: {len(blocking)} rows.** "
              "Build is unaffected by design (owner decision 2026-09-03).", ""]
    if blocking:
        L += ["| Row | Verdict | Citation | Now at |", "|---|---|---|---|"]
        for r in blocking:
            for d in r["detail"]:
                L.append(f"| {r['row']} | {d['verdict']} | `{d['cite']}` | "
                         f"{d.get('now') or '—'} |")
    weak = [(r["row"], d) for r in rep["rows"] for d in r["detail"]
            if d["verdict"] in ("TRUNCATED", "FILE_NOT_FUNCTION")]
    if weak:
        L += ["", f"## Weak citations ({len(weak)}) — non-blocking", "",
              "These resolve, but only by fuzzy match: the matrix named a prefix or a file where a",
              "function was meant. Not evidence loss; a reader can still be misled.", "",
              "| Row | Verdict | Citation |", "|---|---|---|"]
        L += [f"| {row} | {d['verdict']} | `{d['cite']}` |" for row, d in weak]

    shifted = [r for r in rep["rows"] if r["verdict"] == "SHIFTED"]
    if shifted:
        L += ["", f"## Auto-repinnable ({len(shifted)} rows)", "",
              "Content unchanged; coordinate moved. `--repin` fixes these without human review.",
              "", "| Row | Citation | Now at |", "|---|---|---|"]
        for r in shifted:
            for d in r["detail"]:
                if d["verdict"] == "SHIFTED":
                    L.append(f"| {r['row']} | `{d['cite']}` | {d['now']} |")
    return "\n".join(L) + "\n"


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--repo", default=".")
    p.add_argument("--matrix", required=True)
    p.add_argument("--json", help="write the machine-readable verdict here")
    p.add_argument("--out", help="write the markdown report here (default: stdout)")
    p.add_argument("--add-column", metavar="REV",
                   help="backfill the anchored_at column with REV and exit")
    p.add_argument("--column-out", help="where --add-column writes (default: in place)")
    p.add_argument("--repin", action="store_true",
                   help="rewrite SHIFTED coordinates and bump those rows to HEAD. Refuses any row "
                        "with a blocking verdict.")
    p.add_argument("--gate", action="store_true",
                   help="exit 1 if any row blocks the closure claim. "
                        "PUBLICATION step only — never the build job.")
    a = p.parse_args()

    if a.add_column:
        dst = a.column_out or a.matrix
        ok = add_column(a.matrix, a.add_column, dst)
        print(f"anchored_at column {'added' if ok else 'FAILED (header/separator not matched)'} -> {dst}")
        return 0 if ok else 2

    if not os.path.exists(a.matrix):
        print(f"MATRIX NOT FOUND: {a.matrix}\n"
              f"Cannot verify the closure claim without the artefact it is a claim about. "
              f"This is a refusal to answer, not an answer.", file=sys.stderr)
        return 2

    rep = audit(a.repo, a.matrix)
    if a.repin:
        moved, rows = repin(a.matrix, rep, rep["head"])
        print(f"repinned {moved} coordinates across {len(rows)} rows -> {rep['head'][:7]}")
        rep = audit(a.repo, a.matrix)
    md = render(rep)
    if a.out:
        open(a.out, "w", encoding="utf-8").write(md)
        print(f"report -> {a.out}")
    else:
        print(md)
    if a.json:
        json.dump(rep, open(a.json, "w", encoding="utf-8"), indent=2)
        print(f"json -> {a.json}")
    n = sum(1 for r in rep["rows"] if r["blocks"])
    print(f"blocking rows: {n}/{len(rep['rows'])}")
    return 1 if (a.gate and n) else 0


if __name__ == "__main__":
    sys.exit(main())
