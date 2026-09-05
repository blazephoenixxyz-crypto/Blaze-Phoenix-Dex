#!/usr/bin/env python3
"""matrix_summary.py - read the CELL lines a HostileVenueMatrix run printed and print the matrix.

    forge test --match-contract HostileVenueMatrix -vv > hostile.log
    python3 .github/scripts/assurance/matrix_summary.py hostile.log

Each cell is a venue pathology crossed with a door; the outcome is SETTLED, REFUSED <selector>,
ADMISSION_REFUSED <selector>, or GAS_EXHAUSTED. A FAILED cell is a third way - a panic, a foreign
selector, an under-payment that settled, a re-entry that ran - and is listed by name.
"""
import collections, re, sys

log = open(sys.argv[1]).read() if len(sys.argv) > 1 else sys.stdin.read()
cells = {}
for m in re.finditer(r"CELL (\S+) (EXACT_IN|BEST) (\S+)\s*(.*)", log):
    cells[(m.group(1), m.group(2))] = (m.group(3), m.group(4).strip())
failed = re.findall(r"\[FAIL[^\]]*\] (test_Matrix_\S+)", log)
venues = sorted({v for v, _ in cells})
print(f"{'venue':22} {'EXACT_IN':34} {'BEST'}")
for v in venues:
    row = []
    for d in ("EXACT_IN", "BEST"):
        o = cells.get((v, d))
        row.append(f"{o[0]} {o[1]}".strip() if o else "-")
    print(f"{v:22} {row[0][:34]:34} {row[1][:40]}")
by = collections.Counter(o for o, _ in cells.values())
print(f"\ncells: {len(cells)}  {dict(by)}")
print(f"failed (third way): {len(failed)}")
for f in failed:
    print("   " + f)
sys.exit(1 if failed else 0)
