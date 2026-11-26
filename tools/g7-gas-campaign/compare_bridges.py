#!/usr/bin/env python3
"""Paired comparison of two G7/G8 results.tsv runs that differ only in the Hub's bridge list.

  compare_bridges.py <results_A.tsv> <results_B.tsv>   (A = three bridges, B = two)

A pair is the same draw in both runs: (chain, stratum, kind, idx, b, mode, tin, tout, amount_in).
Every delta is B - A per pair, so a negative gas delta means two bridges cost less. Percentiles
are nearest-rank (below 20 values the p5 is the minimum and the p95 the maximum).
Output: TSV sections, each with a '# ' header line.
"""
import sys
from collections import defaultdict

KEY = ("chain", "stratum", "kind", "idx", "b", "mode", "tin", "tout", "amount_in")


def load(path):
    rows = {}
    with open(path) as f:
        head = f.readline().rstrip("\n").split("\t")
        for line in f:
            r = dict(zip(head, line.rstrip("\n").split("\t")))
            k = tuple(r.get(c, "") for c in KEY)
            if k in rows:
                raise SystemExit("duplicate draw key in %s: %s" % (path, k))
            rows[k] = r
    return rows


def num(r, c):
    try:
        return int(r.get(c, ""))
    except ValueError:
        return None


def pct(xs, q):
    if not xs:
        return ""
    s = sorted(xs)
    i = max(0, min(len(s) - 1, -(-q * len(s) // 100) - 1))
    return s[i]


def tails(xs):
    # nearest rank: below 20 values p5 is the minimum and p95 the maximum
    return pct(xs, 5), pct(xs, 95)


def route(r):
    return (r.get("hops", ""), r.get("legs", ""), r.get("legs_detail", "").split(":")[0])


def bps(a, b):
    return (b - a) * 10000 // a if a else None


def main(pa, pb):
    A, B = load(pa), load(pb)
    common = sorted(set(A) & set(B))
    only = len(set(A) ^ set(B))
    print("# pairing\trows_A\trows_B\tpaired\tunpaired")
    print("all\t%d\t%d\t%d\t%d" % (len(A), len(B), len(common), only))
    groups = defaultdict(list)
    for k in common:
        chain, mode = k[0], k[5]
        mg = "D" if mode == "D" else ("M0" if mode == "M0" else "M_aged" if mode.startswith("M") else mode)
        for g in ((chain, mg), (chain, "all"), ("all", mg), ("all", "all")):
            groups[g].append(k)

    print("# outcome: chain\tmode\tpairs\tok_A\tok_B\tok_to_notok\tnotok_to_ok")
    for g in sorted(groups):
        ks = groups[g]
        oa = sum(A[k]["outcome"] == "ok" for k in ks)
        ob = sum(B[k]["outcome"] == "ok" for k in ks)
        lost = sum(A[k]["outcome"] == "ok" and B[k]["outcome"] != "ok" for k in ks)
        won = sum(A[k]["outcome"] != "ok" and B[k]["outcome"] == "ok" for k in ks)
        print("%s\t%s\t%d\t%d\t%d\t%d\t%d" % (g + (len(ks), oa, ob, lost, won)))

    print("# lost draws (ok in A, not ok in B): chain\tmode\tstratum\tidx\tb\toutcome_B\tdetail_B\thops_A\tlegs_A")
    for k in common:
        if A[k]["outcome"] == "ok" and B[k]["outcome"] != "ok":
            print("\t".join([k[0], k[5], k[1], k[3], k[4], B[k]["outcome"], B[k].get("detail", "")[:80],
                             A[k].get("hops", ""), A[k].get("legs", "")]))

    segs = ("g_quote", "g_discovery", "g_discovery_bridge", "g_solve", "g_exec", "g_record")
    print("# gas, pairs ok in both: chain\tmode\tsegment\tn\tA_p50\tB_p50\tdelta_p50\tdelta_p5\tdelta_p95\tlower\tsame\thigher")
    for g in sorted(groups):
        ks = [k for k in groups[g] if A[k]["outcome"] == "ok" and B[k]["outcome"] == "ok"]
        for s in segs:
            xs = [(num(A[k], s), num(B[k], s)) for k in ks]
            xs = [(a, b) for a, b in xs if a is not None and b is not None]
            if not xs:
                continue
            d = [b - a for a, b in xs]
            lo, hi = tails(d)
            print("%s\t%s\t%s\t%d\t%s\t%s\t%s\t%s\t%s\t%d\t%d\t%d" % (
                g[0], g[1], s, len(xs), pct([a for a, _ in xs], 50), pct([b for _, b in xs], 50),
                pct(d, 50), lo, hi, sum(x < 0 for x in d), sum(x == 0 for x in d), sum(x > 0 for x in d)))

    print("# route and output, pairs ok in both: chain\tmode\tn\troute_changed\tdelivered_bps_p50\tdelivered_bps_p5\tdelivered_bps_p95\tworse\tsame\tbetter")
    for g in sorted(groups):
        ks = [k for k in groups[g] if A[k]["outcome"] == "ok" and B[k]["outcome"] == "ok"]
        if not ks:
            continue
        ch = sum(route(A[k]) != route(B[k]) for k in ks)
        d = [bps(num(A[k], "delivered"), num(B[k], "delivered")) for k in ks
             if num(A[k], "delivered") and num(B[k], "delivered") is not None]
        lo, hi = tails(d)
        print("%s\t%s\t%d\t%d\t%s\t%s\t%s\t%d\t%d\t%d" % (
            g[0], g[1], len(ks), ch, pct(d, 50), lo, hi,
            sum(x < 0 for x in d), sum(x == 0 for x in d), sum(x > 0 for x in d)))

    print("# delivered changes, pairs ok in both with A != B: chain\tn_changed\tworst_bps\tbest_bps")
    ch = defaultdict(list)
    for k in common:
        if A[k]["outcome"] == "ok" and B[k]["outcome"] == "ok":
            da, db = num(A[k], "delivered"), num(B[k], "delivered")
            if da and db is not None and da != db:
                for c in (k[0], "all"):
                    ch[c].append(bps(da, db))
    for c in sorted(ch):
        print("%s\t%d\t%d\t%d" % (c, len(ch[c]), min(ch[c]), max(ch[c])))

    print("# by route shape of A, pairs ok in both: chain\thops_A\tn\tg_quote_delta_p50\tg_exec_delta_p50\troute_changed")
    shape = defaultdict(list)
    for k in common:
        if A[k]["outcome"] == "ok" and B[k]["outcome"] == "ok":
            for c in (k[0], "all"):
                shape[(c, A[k].get("hops", ""))].append(k)
    for g in sorted(shape):
        ks = shape[g]
        dq = [num(B[k], "g_quote") - num(A[k], "g_quote") for k in ks]
        de = [num(B[k], "g_exec") - num(A[k], "g_exec") for k in ks]
        print("%s\t%s\t%d\t%s\t%s\t%d" % (g[0], g[1], len(ks), pct(dq, 50), pct(de, 50),
                                          sum(route(A[k]) != route(B[k]) for k in ks)))


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
