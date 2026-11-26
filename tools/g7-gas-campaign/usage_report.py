#!/usr/bin/env python3
"""Usage curve of a G7 results.tsv measured with spec "usage_steps": per chain and step k, the gas
of the k-th execution of the same draw in a row (mode U<k>) against the first one (U1).

  usage_report.py <results.tsv>

Spec "usage_seed" adds the S series (stratum's pools seedPool'ed after U1): its chain is U1, S2..Sk,
reported under "<chain>+seed".
A draw counts at step k only if U1..Uk are all ok (the chain of states is unbroken). Deltas are
Uk - U1 per draw, nearest-rank percentiles (compare_bridges.pct). U1 runs on the D state, so the
D check pairs U1 with D of the same draw: equal g_exec and delivered there mean the usage chain
starts where the campaign's own D row stands.
Output: TSV sections, each with a '# ' header line.
"""
import os
import sys
from collections import defaultdict

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from compare_bridges import num, pct, tails  # noqa: E402

SEGS = ("g_exec", "g_record", "g_quote", "g_discovery")
DRAW = ("chain", "stratum", "kind", "idx", "b", "tin", "tout", "amount_in")


def load(path):
    with open(path) as f:
        head = f.readline().rstrip("\n").split("\t")
        return [dict(zip(head, line.rstrip("\n").split("\t"))) for line in f]


def chains_of_draws(rows):
    """draw -> [U1 row, U2 row, ...] up to the first step that is missing or not ok; a seeded
    draw (S<k> rows) is keyed with chain "<chain>+seed" and starts at its U1."""
    by = defaultdict(dict)
    for r in rows:
        if r["mode"][:1] in "US" and r["mode"][1:].isdigit():
            k = tuple(r.get(c, "") for c in DRAW)
            if r["mode"][0] == "S":
                k = (k[0] + "+seed",) + k[1:]
            by[k][int(r["mode"][1:])] = r
    for k, steps in by.items():
        if k[0].endswith("+seed"):
            u = by.get((k[0][:-5],) + k[1:], {})
            if 1 in u:
                steps[1] = u[1]
    out = {}
    for k, steps in by.items():
        run = []
        for i in range(1, max(steps) + 1):
            if i not in steps or steps[i]["outcome"] != "ok":
                break
            run.append(steps[i])
        if run:
            out[k] = run
    return out


def main(path):
    rows = load(path)
    runs = chains_of_draws(rows)
    d_rows = {tuple(r.get(c, "") for c in DRAW): r for r in rows if r["mode"] == "D" and r["outcome"] == "ok"}

    print("# D check, draws with D and U1 ok: chain\tn\tg_exec_equal\tdelivered_equal")
    chk = defaultdict(lambda: [0, 0, 0])
    for k, run in runs.items():
        if k in d_rows:
            for c in (k[0], "all"):
                chk[c][0] += 1
                chk[c][1] += num(run[0], "g_exec") == num(d_rows[k], "g_exec")
                chk[c][2] += num(run[0], "delivered") == num(d_rows[k], "delivered")
    for c in sorted(chk):
        print("%s\t%d\t%d\t%d" % ((c,) + tuple(chk[c])))

    print("# usage, draws ok at U1..Uk: chain\tstep\tn\tsegment\tUk_p50\tdelta_vs_U1_p50\tdelta_p5\tdelta_p95\tlower\tsame\thigher")
    at = defaultdict(list)  # (chain, step) -> [(U1 row, Uk row)]
    for k, run in runs.items():
        for i, r in enumerate(run, 1):
            for c in (k[0], "all"):
                at[(c, i)].append((run[0], r))
    for c, i in sorted(at):
        for s in SEGS:
            xs = [(num(a, s), num(b, s)) for a, b in at[(c, i)]]
            xs = [(a, b) for a, b in xs if a is not None and b is not None]
            if not xs:
                continue
            d = [b - a for a, b in xs]
            lo, hi = tails(d)
            print("%s\t%d\t%d\t%s\t%s\t%s\t%s\t%s\t%d\t%d\t%d" % (
                c, i, len(xs), s, pct([b for _, b in xs], 50), pct(d, 50), lo, hi,
                sum(x < 0 for x in d), sum(x == 0 for x in d), sum(x > 0 for x in d)))

    print("# quote case by step (ms_case of Uk): chain\tstep\thit\tpartial\tmiss")
    for c, i in sorted(at):
        cs = [b.get("ms_case", "") for _, b in at[(c, i)]]
        print("%s\t%d\t%d\t%d\t%d" % (c, i, cs.count("hit"), cs.count("partial"), cs.count("miss")))


if __name__ == "__main__":
    main(sys.argv[1])
