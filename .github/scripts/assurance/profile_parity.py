#!/usr/bin/env python3
"""The binary the suite runs against must be the binary that ships.

A test suite is evidence about the artefact it executed. If the profile used for testing and the
profile used for the release build differ in any setting that reaches code generation, then the
suite is evidence about a contract that will never be deployed, and the deployed one has never
been executed by a single test.

That was true here. The suite ran at one optimizer setting and the release build at another, and
nothing said so: both jobs were green, both were required, and neither was wrong on its own
terms. The release job built the shipped binary and only measured its SIZE.

The repair is not a second test run. It is to stop having two binaries: the settings are now
identical, so the artefact the suite executes IS the artefact that deploys. This script exists
to keep it that way, because a divergence reintroduced later would be invisible again - somebody
tunes one profile for a size margin, every check stays green, and the evidence quietly detaches
from the thing it is evidence about.

Settings that reach code generation, and are therefore compared: solc version, EVM version,
optimizer on/off, optimizer runs, and the IR pipeline. Fuzzing and invariant parameters are not
compared: they change how the suite is run, not what it is run against.

Usage: python3 profile_parity.py <repo_root>
"""
import re, os, sys

ROOT = sys.argv[1] if len(sys.argv) > 1 else "."
TOML = os.path.join(ROOT, "foundry.toml")

# profiles whose output is executed or deployed. `smt` is a model-checker profile that produces
# no artefact anyone runs, so it is deliberately out of scope.
COMPARED = ["default", "release"]
KEYS = ["solc_version", "evm_version", "optimizer", "optimizer_runs", "via_ir"]

text = open(TOML).read()
sections, cur = {}, None
for line in text.splitlines():
    line = line.split("#")[0].strip()
    m = re.match(r"^\[profile\.([\w.]+)\]$", line)
    if m:
        cur = m.group(1); sections.setdefault(cur, {}); continue
    if cur and "=" in line:
        k, v = [x.strip() for x in line.split("=", 1)]
        sections[cur][k] = v.strip('"')

missing = [p for p in COMPARED if p not in sections]
if missing:
    print(f"profiles not found in foundry.toml: {', '.join(missing)}")
    sys.exit(1)

diffs = []
for k in KEYS:
    vals = {p: sections[p].get(k) for p in COMPARED}
    if len({str(v) for v in vals.values()}) > 1:
        diffs.append((k, vals))

w = max(len(k) for k in KEYS)
print(f"{'SETTING':{w}}  " + "  ".join(f"{p:>12}" for p in COMPARED))
print("-" * (w + 2 + 14 * len(COMPARED)))
for k in KEYS:
    print(f"{k:{w}}  " + "  ".join(f"{str(sections[p].get(k)):>12}" for p in COMPARED))

if diffs:
    print(f"\n{len(diffs)} code-generating setting(s) differ between the profile the suite runs")
    print("under and the profile that builds the shipped contract. The suite is evidence about")
    print("an artefact that does not deploy:")
    for k, vals in diffs:
        print(f"  {k}: " + ", ".join(f"{p}={v}" for p, v in vals.items()))
    sys.exit(1)

print("\nEvery code-generating setting agrees: the artefact the suite executes is the artefact")
print("that deploys. There is one binary, and the tests ran against it.")
