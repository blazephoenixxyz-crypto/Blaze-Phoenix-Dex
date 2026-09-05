#!/usr/bin/env python3
"""covering_array.py - the regime factors, a pairwise covering array over them, and the
generated test file that instantiates every row.

Coverage criteria index the code; mutation indexes an injected fault; neither indexes the
STATE a fixture fixes - which venue family, how many hops, whether the input or the
intermediate token is a bridge, whether the token taxes transfers, its decimals, which door
the value came in through, whether control has been renounced, whether the pair is full.
Every defect this repository has recorded was an interaction of two or three of those. A
covering array of strength t guarantees that EVERY combination of t factor values appears in
at least one row, so the question "did any fixture ever combine X with Y?" has the answer
"yes, by construction" for every pair.

The rows are executed by test/regime/RegimeCoverage.t.sol (generated here, committed) through
one harness with one assertion for every row: the swap settles inside its floors with the
delivered amount equal to the recipient's balance delta and the Router holding nothing, or it
is refused with a selector of ours. A panic, an empty revert, a silent under-delivery or a
stranded balance fails the row. Rows the fixture cannot build are reported as such and count
against the denominator.

Usage:
  python3 .github/scripts/assurance/covering_array.py            # regenerate the test + json
  python3 .github/scripts/assurance/covering_array.py --check    # fail if the committed file drifted
"""
import itertools, json, os, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
OUT_SOL = os.path.join(ROOT, "test", "regime", "RegimeCoverage.t.sol")
OUT_JSON = os.path.join(ROOT, "docs", "assurance", "regimes-covering.json")
STRENGTH = 2

# (factor, [values]) - the order is the harness's Row struct order. Values are the harness's
# enum names. Families and doors outside this list (V4, Algebra, the native door) are stated
# in the json as not yet in the array, which is the honest denominator.
FACTORS = [
    ("kind",        ["V2", "V3", "SOLIDLY"]),
    ("hops",        ["H1", "H2", "H3"]),
    ("legs",        ["L1", "L2"]),
    ("inBridge",    ["IN_PLAIN", "IN_BRIDGE"]),
    ("midBridge",   ["MID_PLAIN", "MID_BRIDGE"]),
    ("fot",         ["FOT_NONE", "FOT_PULL", "FOT_ALL"]),
    ("decimalsIn",  ["D18", "D6"]),
    ("door",        ["EXACT_IN", "BEST", "PERMIT2"]),
    ("control",     ["LIVE", "RENOUNCED"]),
    ("pairFull",    ["PAIR_OPEN", "PAIR_FULL"]),
]
# the harness's enum name for each factor (library F in test/regime/RegimeHarness.sol)
ENUMS = {"kind": "Kind", "hops": "Hops", "legs": "Legs", "inBridge": "InB", "midBridge": "MidB",
         "fot": "Fot", "decimalsIn": "Dec", "door": "Door", "control": "Ctl", "pairFull": "Full"}


def pairwise(factors, seed=7):
    """Greedy in-parameter-order construction (IPOG-shaped) of a strength-2 covering array.
    Deterministic: the same factors give the same rows, so the generated file is stable."""
    names = [f for f, _ in factors]
    vals = [v for _, v in factors]
    n = len(factors)
    uncovered = set()
    for i, j in itertools.combinations(range(n), 2):
        for a in range(len(vals[i])):
            for b in range(len(vals[j])):
                uncovered.add((i, a, j, b))
    total_pairs = len(uncovered)
    rows = []
    # horizontal growth: start from the first two factors' full product
    for a in range(len(vals[0])):
        for b in range(len(vals[1])):
            rows.append([a, b] + [None] * (n - 2))
    for k in range(2, n):
        # extend every row with the value of factor k that covers the most uncovered pairs
        for row in rows:
            best, best_gain = None, -1
            for v in range(len(vals[k])):
                gain = sum(1 for i in range(k) if (i, row[i], k, v) in uncovered)
                if gain > best_gain:
                    best, best_gain = v, gain
            row[k] = best
        # vertical growth: any pair (i, k) still uncovered gets a new row or fills a hole
        for i in range(k):
            for a in range(len(vals[i])):
                for v in range(len(vals[k])):
                    if (i, a, k, v) not in uncovered:
                        continue
                    placed = False
                    for row in rows:
                        if row[i] == a and row[k] is None:
                            row[k] = v; placed = True; break
                        if row[i] is None and row[k] == v:
                            row[i] = a; placed = True; break
                    if not placed:
                        new = [None] * n
                        new[i], new[k] = a, v
                        rows.append(new)
        # book-keeping
        for row in rows:
            for i in range(k + 1):
                for j in range(i + 1, k + 1):
                    if row[i] is not None and row[j] is not None:
                        uncovered.discard((i, row[i], j, row[j]))
    # fill remaining holes deterministically with the first value
    for row in rows:
        for i in range(n):
            if row[i] is None:
                row[i] = 0
    for row in rows:
        for i, j in itertools.combinations(range(n), 2):
            uncovered.discard((i, row[i], j, row[j]))
    assert not uncovered, f"{len(uncovered)} pairs left uncovered"
    return names, vals, rows, total_pairs


def render(names, vals, rows):
    lines = [
        "// SPDX-License-Identifier: BUSL-1.1",
        "pragma solidity 0.8.36;",
        "",
        "// GENERATED by .github/scripts/assurance/covering_array.py - do not edit by hand.",
        "// A strength-%d covering array over the regime factors: every pair of factor values" % STRENGTH,
        "// appears in at least one row below. Each row is one fixture run through RegimeHarness,",
        "// which either settles inside its floors or is refused with a selector of ours.",
        "",
        'import {RegimeHarness, F} from "./RegimeHarness.sol";',
        "",
        "contract RegimeCoverageTest is RegimeHarness {",
    ]
    for idx, row in enumerate(rows):
        label = "_".join(vals[i][row[i]] for i in range(len(names)))
        args = ", ".join(f"F.{ENUMS[names[i]]}.{vals[i][row[i]]}" for i in range(len(names)))
        lines.append(f"    function test_Regime_{idx:02d}_{label}() public {{")
        lines.append(f"        _run({idx}, Row({args}));")
        lines.append("    }")
        lines.append("")
    lines.append("}")
    return "\n".join(lines) + "\n"


def main():
    names, vals, rows, total_pairs = pairwise(FACTORS)
    combos = 1
    for _, v in FACTORS:
        combos *= len(v)
    sol = render(names, vals, rows)
    doc = {
        "strength": STRENGTH,
        "factors": {f: v for f, v in FACTORS},
        "full_factorial": combos,
        "pairs": total_pairs,
        "rows": len(rows),
        "row_labels": ["_".join(vals[i][r[i]] for i in range(len(names))) for r in rows],
        "not_in_the_array": {
            "kind": ["V4", "V4_NATIVE", "ALGEBRA"],
            "door": ["NATIVE"],
            "hooks": ["inert", "alters deltas"],
            "why": "the harness builds these families from mocks that live in individual test files; "
                   "they enter the array when the mocks move to test/mocks/",
        },
    }
    if "--check" in sys.argv:
        cur = open(OUT_SOL).read() if os.path.exists(OUT_SOL) else ""
        curj = json.load(open(OUT_JSON)) if os.path.exists(OUT_JSON) else {}
        if cur != sol or curj != doc:
            print("regime covering array drifted - run: python3 .github/scripts/assurance/covering_array.py")
            sys.exit(1)
        print(f"regime covering array current: {len(rows)} rows cover {total_pairs} pairs of {combos} combinations")
        return
    os.makedirs(os.path.dirname(OUT_SOL), exist_ok=True)
    open(OUT_SOL, "w").write(sol)
    json.dump(doc, open(OUT_JSON, "w"), indent=1)
    print(f"{len(rows)} rows cover all {total_pairs} value pairs of {combos} combinations -> {OUT_SOL}")


if __name__ == "__main__":
    main()
