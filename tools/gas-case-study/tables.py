#!/usr/bin/env python3
"""Gas case study 1114: per-stratum tables from the joined per-swap rows (stdlib only).

  python3 -I tools/gas-case-study/tables.py <joined.tsv>... -o <tables.tsv> [--b B] [--prereg P]

Strata: chain x hops x legs_per_hop x mode x temp x exotic (s if exotic_in or exotic_out is set).
Per stratum (docs/prereg/gas-1114.tsv, rules bootstrap, proportions, pairing; const B):
- gas_tx, usd_total: n, median and its percentile-bootstrap 95 % interval over the rows with
  status=ok and a numeric value; B resamples (const B of the prereg, 10000) from
  random.Random(seed), seed = int(sha256(utf8('gas-1114-boot|' + stratum_id))) (full 256 bits);
- rate_revert (status revert*), rate_noroute, rate_noquote: k/n over every row, Wilson 95 %.
Paired differences (rule pairing): for each chain x temp x exotic and each pair of modes A < B
(sorted), the draws present in both with status=ok, matched by cell_id, i, amount_in and
fork_block; d = A - B per draw for gas_tx and usd_total; median and bootstrap interval as above.
A draw with two rows of one mode is ambiguous and left out. n = 0 gives empty statistics, never 0.

tables.tsv: chain hops legs_per_hop mode vs temp exotic metric n k median ci95_lo ci95_hi stratum_id
            boot_seed b
"""
import hashlib
import os
import sys
from itertools import combinations

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import stats  # noqa: E402  (one producer of the bootstrap and of Wilson)
from join import read, write  # noqa: E402

COLS = "chain hops legs_per_hop mode vs temp exotic metric n k median ci95_lo ci95_hi stratum_id boot_seed b".split()
METRICS = (("gas_tx", int), ("usd_total", float))
RATES = (("rate_revert", lambda s: s.startswith("revert")), ("rate_noroute", lambda s: s == "noroute"),
         ("rate_noquote", lambda s: s == "noquote"))
TRUE = {"1", "s", "y", "yes", "true", "sim"}
PREREG = os.path.join(HERE, "..", "..", "docs", "prereg", "gas-1114.tsv")


def seed_of(stratum_id):
    return int(hashlib.sha256(("gas-1114-boot|" + stratum_id).encode("utf-8")).hexdigest(), 16)


def prereg_b(path):
    """const B of the prereg; stats.BOOT_B if the file or the line is absent."""
    try:
        with open(path) as f:
            for ln in f:
                p = ln.rstrip("\n").split("\t")
                if p[:2] == ["const", "B"]:
                    return int(p[2])
    except OSError:
        pass
    return stats.BOOT_B


def exotic(r):
    return "s" if any((r.get(k) or "").strip().lower() in TRUE for k in ("exotic_in", "exotic_out")) else "n"


def val(r, metric, typ):
    if r.get("status") != "ok":
        return None
    try:
        return typ(r.get(metric, ""))
    except (TypeError, ValueError):
        return None


def stat_row(base, metric, vals, sid, b):
    row = dict(base, metric=metric, n=len(vals), k="", median="", ci95_lo="", ci95_hi="", stratum_id=sid,
               boot_seed="0x%064x" % seed_of(sid), b=b)
    if vals:
        lo, hi = stats.bootstrap_ci(vals, seed_of(sid), b)
        row.update(median=stats.median(vals), ci95_lo=lo, ci95_hi=hi)
    return row


def tables(rows, b):
    out, strata = [], {}
    for r in rows:
        key = (r.get("chain", ""), r.get("hops", ""), r.get("legs_per_hop", ""), r.get("mode", ""),
               r.get("temp", ""), exotic(r))
        strata.setdefault(key, []).append(r)
    for key in sorted(strata):
        rs = strata[key]
        chain, hops, legs, mode, temp, ex = key
        sid = "|".join(key)
        base = dict(chain=chain, hops=hops, legs_per_hop=legs, mode=mode, vs="", temp=temp, exotic=ex)
        for m, typ in METRICS:
            out.append(stat_row(base, m, [v for v in (val(r, m, typ) for r in rs) if v is not None], sid, b))
        for m, pred in RATES:
            k, n = sum(1 for r in rs if pred(r.get("status") or "")), len(rs)
            w = stats.wilson(k, n)
            out.append(dict(base, metric=m, n=n, k=k, median=(k / n if n else ""), ci95_lo=w[0] if w else "",
                            ci95_hi=w[1] if w else "", stratum_id=sid, boot_seed="", b=""))
    out.extend(paired(rows, b))
    return out


def paired(rows, b):
    out, by = [], {}
    for r in rows:
        g = (r.get("chain", ""), r.get("temp", ""), exotic(r))
        d = (r.get("cell_id"), r.get("i"), r.get("amount_in"), r.get("fork_block"))
        by.setdefault(g, {}).setdefault(r.get("mode", ""), {}).setdefault(d, []).append(r)
    for g in sorted(by):
        modes = by[g]
        for a, bm in combinations(sorted(modes), 2):
            sid = "|".join(g + (a, bm))
            base = dict(chain=g[0], hops="", legs_per_hop="", mode=a, vs=bm, temp=g[1], exotic=g[2])
            for m, typ in METRICS:
                ds = []
                for d in sorted(set(modes[a]) & set(modes[bm]), key=str):
                    ra, rb = modes[a][d], modes[bm][d]
                    if len(ra) != 1 or len(rb) != 1:
                        continue
                    x, y = val(ra[0], m, typ), val(rb[0], m, typ)
                    if x is not None and y is not None:
                        ds.append(x - y)
                out.append(stat_row(base, "d_" + m, ds, sid, b))
    return out


def main(argv):
    ins, out, b, prereg = [], None, None, PREREG
    it = iter(argv)
    for a in it:
        if a == "-o":
            out = next(it)
        elif a == "--b":
            b = int(next(it))
        elif a == "--prereg":
            prereg = next(it)
        else:
            ins.append(a)
    if not ins or not out:
        print(__doc__, file=sys.stderr)
        return 2
    rows = [r for p in ins for r in read(p)[1]]
    write(out, COLS, tables(rows, b or prereg_b(prereg)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
