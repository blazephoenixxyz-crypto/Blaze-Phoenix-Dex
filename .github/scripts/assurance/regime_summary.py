#!/usr/bin/env python3
"""regime_summary.py - read the ROW lines a RegimeCoverage run printed and state the outcome
of the covering array beside its denominator.

    forge test --match-contract RegimeCoverage -vv > regime.log
    python3 .github/scripts/assurance/regime_summary.py regime.log

Prints rows settled / refused (by selector) / not constructible, the pairs the array covers,
and the full factorial it stands in for. A row that FAILED is a third way - a panic, a foreign
selector, a delivered amount that is not the balance delta, a balance left on the Router - and
is listed by name.
"""
import collections, json, os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
log = open(sys.argv[1]).read() if len(sys.argv) > 1 else sys.stdin.read()
JSON = os.path.join(ROOT, "docs", "assurance", "regimes-covering.json")
if "--strength" in sys.argv:                       # the t=3 array has its own file
    t = int(sys.argv[sys.argv.index("--strength") + 1])
    if t != 2:
        JSON = os.path.join(ROOT, "docs", "assurance", "regimes-covering-t%d.json" % t)
doc = json.load(open(JSON))
labels = doc["row_labels"]

rows = {}
for m in re.finditer(r"ROW (\d+) (SETTLED|REFUSED|NOT_CONSTRUCTIBLE)\s*(.*)", log):
    rows[int(m.group(1))] = (m.group(2), m.group(3).strip())
failed = re.findall(r"\[FAIL[^\]]*\] (test_Regime_\d+_\S+)", log)

by = collections.Counter(o for o, _ in rows.values())
refusals = collections.Counter(w.split(" ")[0] for o, w in rows.values() if o == "REFUSED")
print(f"regime covering array: strength {doc['strength']}, {doc['rows']} rows, {doc.get('pairs', doc.get('tuples'))} value {'pairs' if doc['strength'] == 2 else '%d-tuples' % doc['strength']}, "
      f"standing in for {doc['full_factorial']} combinations")
print(f"  settled            : {by['SETTLED']}")
print(f"  refused, ours      : {by['REFUSED']}   {dict(refusals)}")
print(f"  not constructible  : {by['NOT_CONSTRUCTIBLE']}")
for i, (o, w) in sorted(rows.items()):
    if o == "NOT_CONSTRUCTIBLE":
        print(f"     row {i:02d} {labels[i]}: {w}")
print(f"  failed (third way) : {len(failed)}")
for f in failed:
    print(f"     {f}")
missing = [i for i in range(doc["rows"]) if i not in rows]
if missing:
    print(f"  rows with no outcome line: {missing} (compile failure or the run did not reach them)")
print(f"  not in the array   : {doc['not_in_the_array']}")
sys.exit(1 if failed or missing else 0)
