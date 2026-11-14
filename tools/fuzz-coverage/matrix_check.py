#!/usr/bin/env python3
"""The fuzz matrix (docs/assurance/fuzz-matrix) is checked, not trusted.

  dimensions.tsv  dimension vector mark families   mark in {min, mid, max, cat}
  seams.tsv       seam invariant families
  cells.tsv       family dimension vector seam test status   ('-' where unused)

Rules (each a function returning a list of error strings; the CLI exits 1 on any):
  check_cells       every declared (family, dimension, vector) has exactly one cell; a cell
                    that matches no declaration is an orphan; status is covered or gap, and a
                    covered cell names a test.
  check_seams       the seam list is exactly SEAMS, and every declared (family, seam) has
                    exactly one cell.
  check_dimensions  every dimension has at least two vectors, and an ordered dimension (any
                    vector marked min, mid or max) has both a min and a max: a range that is
                    sampled at one end only is not a range.
  check_tests       a covered cell names a test that exists: `function <name>(` under test/
                    for a Solidity family, `def <name>(` under tools/ for a Python one.

  python3 tools/fuzz-coverage/matrix_check.py [root]
"""
import csv
import os
import re
import sys

SEAMS = ["Router-Hub", "Hub-Core", "Core-Solver", "Solver-Quoter", "Gate-adapter",
         "quote-ABI-execution", "registry-moonslot-expiry", "hop1-hop2"]
PY_FAMILIES = {"an"}
MARKS = {"min", "mid", "max", "cat"}
STATUS = {"covered", "gap"}


def _tsv(root, name, cols):
    path = os.path.join(root, "docs", "assurance", "fuzz-matrix", name)
    with open(path, newline="") as fh:
        rows = list(csv.reader(fh, delimiter="\t"))
    if not rows or rows[0] != cols:
        raise ValueError(f"{name}: header must be {cols}, got {rows[:1]}")
    out = []
    for i, r in enumerate(rows[1:], start=2):
        if len(r) != len(cols):
            raise ValueError(f"{name}:{i}: {len(r)} columns, need {len(cols)}")
        out.append(dict(zip(cols, r)))
    return out


def _load(root):
    dims = _tsv(root, "dimensions.tsv", ["dimension", "vector", "mark", "families"])
    seams = _tsv(root, "seams.tsv", ["seam", "invariant", "families"])
    cells = _tsv(root, "cells.tsv", ["family", "dimension", "vector", "seam", "test", "status"])
    return dims, seams, cells


def _guard(fn):
    def wrapped(root):
        try:
            return fn(root, *_load(root))
        except (OSError, ValueError) as e:
            return [f"matrix unreadable: {e}"]
    wrapped.__name__ = fn.__name__
    wrapped.__doc__ = fn.__doc__
    return wrapped


def _fams(s):
    return [f for f in s.split(",") if f]


@_guard
def check_cells(root, dims, seams, cells):
    errs = []
    want = {(f, d["dimension"], d["vector"]) for d in dims for f in _fams(d["families"])}
    want_seam = {(f, s["seam"]) for s in seams for f in _fams(s["families"])}
    seen = {}
    for c in cells:
        if c["status"] not in STATUS:
            errs.append(f"cell {c}: status must be one of {sorted(STATUS)}")
        if c["status"] == "covered" and c["test"] == "-":
            errs.append(f"cell {c}: covered without a test")
        if c["seam"] == "-":
            key = (c["family"], c["dimension"], c["vector"])
            if key not in want:
                errs.append(f"orphan cell {key}: no such declared (family, dimension, vector)")
            seen[key] = seen.get(key, 0) + 1
        elif (c["family"], c["seam"]) not in want_seam or c["dimension"] != "-" or c["vector"] != "-":
            errs.append(f"orphan cell {c}: no such declared (family, seam)")
    for key in sorted(want):
        if seen.get(key, 0) != 1:
            errs.append(f"declared {key}: {seen.get(key, 0)} cells, need exactly 1")
    return errs


@_guard
def check_seams(root, dims, seams, cells):
    errs = []
    names = [s["seam"] for s in seams]
    if names != SEAMS:
        errs.append(f"seams must be exactly {SEAMS}, got {names}")
    for s in seams:
        if not _fams(s["families"]):
            errs.append(f"seam {s['seam']}: no family")
        for f in _fams(s["families"]):
            n = sum(1 for c in cells if c["family"] == f and c["seam"] == s["seam"])
            if n != 1:
                errs.append(f"seam ({f}, {s['seam']}): {n} cells, need exactly 1")
    return errs


@_guard
def check_dimensions(root, dims, seams, cells):
    errs = []
    by = {}
    for d in dims:
        if d["mark"] not in MARKS:
            errs.append(f"{d['dimension']}/{d['vector']}: mark must be one of {sorted(MARKS)}")
        by.setdefault(d["dimension"], []).append(d)
    for name, rows in by.items():
        if len(rows) < 2:
            errs.append(f"dimension {name}: {len(rows)} vector(s), need at least 2")
        marks = {r["mark"] for r in rows}
        if marks & {"min", "mid", "max"} and not {"min", "max"} <= marks:
            errs.append(f"dimension {name}: ordered but missing {sorted({'min', 'max'} - marks)}")
    return errs


def _test_exists(root, test, family):
    if family in PY_FAMILIES:
        base, pat, ext = "tools", re.compile(r"^\s*def " + re.escape(test) + r"\("), ".py"
    else:
        base, pat, ext = "test", re.compile(r"\bfunction " + re.escape(test) + r"\("), ".sol"
    for d, _, files in os.walk(os.path.join(root, base)):
        for f in files:
            if f.endswith(ext):
                with open(os.path.join(d, f), errors="replace") as fh:
                    if any(pat.search(line) for line in fh):
                        return True
    return False


@_guard
def check_tests(root, dims, seams, cells):
    errs = []
    for c in cells:
        if c["status"] == "covered":
            if not _test_exists(root, c["test"], c["family"]):
                errs.append(f"cell {c['family']}/{c['dimension']}/{c['vector']}/{c['seam']}: "
                            f"test {c['test']} not found")
    return errs


def main(root):
    errs = check_cells(root) + check_seams(root) + check_dimensions(root) + check_tests(root)
    for e in errs:
        print(e)
    if not errs:
        print("fuzz matrix: every declared cell present, every covered cell names a real test.")
    return 1 if errs else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else
                  os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))))
