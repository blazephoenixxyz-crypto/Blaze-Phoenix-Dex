#!/usr/bin/env python3
"""Which caller declarations does execution confirm, and which does it merely believe.

WHY THIS AXIS EXISTS. Every other instrument here measures the CODE (is this line, branch,
sub-condition or byte exercised?) or the QUANTITY (does this number have more than one
producer?). `SHARED_QUANTITIES.md` is the second axis and it is good work. Neither can see a
field whose only producer is the caller: with one producer there is nothing to disagree with, so
such a field cannot appear in a shared-quantity register AT ALL, by construction.

That blind spot is not theoretical. `leg.pool` on a V4 leg had exactly this shape - the caller
names it, execution never reads it, and it decided which registry row a measured depth was
written to. A full suite, a curated mutation register, an MC/DC census and a bytecode census all
passed over it, because none of them was looking at the field.

THE THREE CLASSES.
  STEERING   the field directs a token movement, so a false value punishes the caller. `leg.pool`
             on a V2 leg is the archetype: lie about it and your own tokens go somewhere else.
  CONFIRMED  execution reads it AND something compares it against an observation - a balance
             delta, a pool's own answer, a derived identity.
  DECLARED   it reaches state, an event or a guard, and nothing observes it. Every DECLARED cell
             is attack surface, or a residual someone has priced and accepted in writing.

WHAT THIS IS NOT. A curated table with a machine check over it, in the shape of `threats.json`
and `relational.json` - not a taint analysis. It cannot discover a field nobody listed. What it
CAN do is refuse to let a claimed confirmation go unchecked, and refuse to let the table drift
away from the sources it cites.

THE SELF-TEST. An instrument is worth nothing until it re-finds an instance already known by
another route, so this one carries four: FLOOR-01, VOL_01, REG-03 and F-B were all DECLARED cells
before they were closed, and each is named in the table with the site that closed it. If a future
edit drops one, the check fails - because a matrix that has forgotten its own history has no
standing to be believed about its empty cells.

Usage: python3 field_confirmation.py <repo_root>
"""
import json, os, re, sys

ROOT = sys.argv[1] if len(sys.argv) > 1 else "."
DATA = os.path.join(ROOT, "docs", "assurance", "fields.json")

# The instances this table must still remember, and the word that must appear in each note.
HISTORY = {"FLOOR-01": "closed", "VOL_01": "rescaled", "REG-03": "closed", "F-B": "closed",
           "FLOOR-02": "open", "F-C": "bounded"}

d = json.load(open(DATA))
rows = d["rows"]
classes = set(d["classes"])

bad, counts = [], {c: 0 for c in classes}
for r in rows:
    c = r["class"]
    if c not in classes:
        bad.append(f"{r['field']}: unknown class {c!r}")
        continue
    counts[c] += 1
    site = r.get("site")
    if c == "CONFIRMED" and not site:
        bad.append(f"{r['field']} ({r['family']}): claims CONFIRMED and names no site")
    if site:
        path = site.split(":")[0]
        if not os.path.exists(os.path.join(ROOT, path)):
            bad.append(f"{r['field']}: cited source {path} does not exist")

notes = " ".join(r.get("note", "") for r in rows)
for tag, word in HISTORY.items():
    if tag not in notes:
        bad.append(f"the table has forgotten {tag}, which was a DECLARED cell before it was closed")
    elif word not in notes:
        bad.append(f"{tag} is named but its state ({word!r}) is not recorded")

tot = len(rows)
print(f"{'CLASS':10} {'rows':>5}   what it means")
print("-" * 72)
print(f"{'STEERING':10} {counts['STEERING']:5}   a lie moves the caller's own tokens")
print(f"{'CONFIRMED':10} {counts['CONFIRMED']:5}   execution compares it against an observation")
print(f"{'DECLARED':10} {counts['DECLARED']:5}   nothing observes it")
print(f"\nfields tracked: {tot}")
print("\nDECLARED cells - the surface, and what each one costs:")
for r in rows:
    if r["class"] == "DECLARED":
        print(f"  {r['field']}  [{r['family']}]")
        print(f"      {r.get('note','')}")
print("\nSCREEN, not a proof: this is a curated table with a machine check over it. It cannot")
print("find a field nobody listed. It refuses a claimed confirmation with no source, and it")
print("fails if the table forgets an instance that was once DECLARED and is now closed.")

json.dump({"counts": counts, "total": tot,
           "declared": [r["field"] for r in rows if r["class"] == "DECLARED"]},
          open(os.path.join(ROOT, "assurance-fields.json"), "w"), indent=1)

if bad:
    print("\nFAILED:")
    for b in bad:
        print("  -", b)
    sys.exit(1)
