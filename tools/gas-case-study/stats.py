#!/usr/bin/env python3
"""Gas case study 1114: the statistics of one chain's results (stdlib only).

  python3 -I tools/gas-case-study/stats.py <results.tsv> <stats.tsv> [--prereg P] [--nprime 8]

Every interval here is a pre-registered method, not a choice made after the data:
- percentiles are nearest-rank, the same producer as tools/g7-gas-campaign/g7.py:pct;
- the 95% interval of a median is a percentile bootstrap, B = 10000 resamples by default, from
  random.Random(seed) with seed = int(sha256("gas-1114-boot")) mod 2^32 unless the prereg carries
  `const BOOT_SEED` (and `const BOOT_B`); the same seed gives the same interval, byte for byte;
- the 95% interval of a rate (reverts, failures) is Wilson's score interval, exact at 0/n and n/n;
- the single reduction of N is a prefix: the draws with index i < N', N' in {8, 4, 2, 1}, the same
  on every chain (docs/prereg/gas-1114.tsv), so no draw is dropped after seeing its result;
- modes are compared only paired, on the same cell and temperature (b - a per cell).
An empty input is absent, never zero: n = 0 gives empty statistics.

stats.tsv: chain stratum metric n median p5 p95 ci95_lo ci95_hi boot_seed
worst.tsv: chain stratum metric n worst worst_key
"""
import hashlib
import math
import os
import random
import statistics
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "g7-gas-campaign"))
from g7 import pct  # noqa: E402  (one producer of the percentile)

BOOT_TAG = "gas-1114-boot"
BOOT_B = 10000
NPRIMES = (8, 4, 2, 1)
Z95 = 1.959963984540054  # the 0.975 normal quantile
STATS_COLS = "chain stratum metric n median p5 p95 ci95_lo ci95_hi boot_seed".split()
WORST_COLS = "chain stratum metric n worst worst_key".split()
METRICS = ("gas_real", "gas_est", "out_ours")


def boot_seed(const=None):
    """The bootstrap seed: the prereg's BOOT_SEED (hex or decimal) if given, else sha256 of the tag."""
    if const:
        return int(const, 0) % (1 << 32)
    return int(hashlib.sha256(BOOT_TAG.encode()).hexdigest(), 16) % (1 << 32)


def median(vals):
    return statistics.median(vals)


def wilson(k, n, z=Z95):
    """Wilson score interval of k successes in n; None when n = 0 (absent, not zero).
    The ends are exact at the boundaries: lo = 0 at k = 0 and hi = 1 at k = n."""
    if n <= 0:
        return None
    if not 0 <= k <= n:
        raise ValueError(f"k={k} outside [0, n={n}]")
    p = k / n
    z2 = z * z
    den = 1 + z2 / n
    mid = (p + z2 / (2 * n)) / den
    half = z * math.sqrt(p * (1 - p) / n + z2 / (4 * n * n)) / den
    lo = 0.0 if k == 0 else max(0.0, mid - half)
    hi = 1.0 if k == n else min(1.0, mid + half)
    return lo, hi


def bootstrap_ci(vals, seed, b=BOOT_B, stat=median, alpha=0.05):
    """Percentile bootstrap interval of stat(vals): B resamples with replacement from
    random.Random(seed); the ends are the nearest-rank alpha/2 and 1 - alpha/2 percentiles."""
    if not vals:
        return None
    rng = random.Random(seed)
    n = len(vals)
    reps = [stat([vals[rng.randrange(n)] for _ in range(n)]) for _ in range(b)]
    return pct(reps, 100 * alpha / 2), pct(reps, 100 * (1 - alpha / 2))


def reduce_prefix(rows, nprime, key="i"):
    """The one reduction rule: keep the draws with index i < N'. N' outside {8,4,2,1} is refused."""
    if nprime not in NPRIMES:
        raise ValueError(f"N'={nprime} is not one of {NPRIMES}")
    return [r for r in rows if int(r[key]) < nprime]


def summarize(chain, stratum, metric, vals, seed, b=BOOT_B):
    """One stats.tsv row; empty fields when there is no value (absent, not zero)."""
    row = dict(chain=chain, stratum=stratum, metric=metric, n=len(vals), median="", p5="", p95="",
               ci95_lo="", ci95_hi="", boot_seed=seed)
    if vals:
        lo, hi = bootstrap_ci(vals, seed, b)
        row.update(median=median(vals), p5=pct(vals, 5), p95=pct(vals, 95), ci95_lo=lo, ci95_hi=hi)
    return row


def rate_row(chain, stratum, metric, k, n, seed):
    """A rate in the stats.tsv frame: median = k/n, the interval is Wilson's, p5/p95 empty."""
    w = wilson(k, n)
    row = dict(chain=chain, stratum=stratum, metric=metric, n=n, median="", p5="", p95="",
               ci95_lo="", ci95_hi="", boot_seed="")
    if w:
        row.update(median=k / n, ci95_lo=w[0], ci95_hi=w[1])
    return row


def worst(chain, stratum, metric, keyed, higher_is_worse=True):
    """The worst case and the key of the row that carries it ((key, value) pairs)."""
    if not keyed:
        return None
    k, v = (max if higher_is_worse else min)(keyed, key=lambda kv: kv[1])
    return dict(chain=chain, stratum=stratum, metric=metric, n=len(keyed), worst=v, worst_key=k)


def num(x):
    return None if x in ("", None) else int(x)


def stratum_of(r):
    return f"{r['pair']}|{r['size_usd']}|{r['mode']}|{r['temp']}"


def paired(rows, mode_a, mode_b, metric):
    """b - a per (cell_id, temp), both ok and both present; the rows that do not pair are counted."""
    by = {}
    for r in rows:
        if r["mode"] in (mode_a, mode_b):
            by.setdefault((r["cell_id"], r["temp"]), {})[r["mode"]] = r
    out, dropped = [], 0
    for key in sorted(by):
        d = by[key]
        a, b = d.get(mode_a), d.get(mode_b)
        if a and b and a["status"] == "ok" and b["status"] == "ok" and num(a[metric]) is not None \
                and num(b[metric]) is not None:
            out.append(("/".join(key), num(b[metric]) - num(a[metric])))
        else:
            dropped += 1
    return out, dropped


def read_tsv(path):
    with open(path) as f:
        lines = [ln.rstrip("\n") for ln in f if ln.strip()]
    if not lines:
        return []
    cols = lines[0].split("\t")
    return [dict(zip(cols, ln.split("\t"))) for ln in lines[1:]]


def write_tsv(path, cols, rows):
    with open(path, "w") as f:
        f.write("\t".join(cols) + "\n")
        for r in rows:
            f.write("\t".join(str(r.get(c, "")) for c in cols) + "\n")


def cell_index(rows):
    """The draw index i of each row: its column if present, else the cell_id's trailing integer."""
    for r in rows:
        if r.get("i", "") == "":
            tail = r["cell_id"].rsplit("-", 1)[-1].rsplit("/", 1)[-1]
            r["i"] = int(tail) if tail.isdigit() else 0
    return rows


def run(results, out_stats, seed, b=BOOT_B, nprime=8):
    rows = reduce_prefix(cell_index(read_tsv(results)), nprime)
    chain = rows[0]["chain"] if rows else ""
    stats, worsts = [], []
    strata = {}
    for r in rows:
        strata.setdefault(stratum_of(r), []).append(r)
    for st in sorted(strata):
        rs = strata[st]
        ok = [r for r in rs if r["status"] == "ok"]
        stats.append(rate_row(chain, st, "revert_rate", sum(r["status"].startswith("revert") for r in rs),
                              len(rs), ""))
        for m in METRICS:
            keyed = [(r["cell_id"], num(r[m])) for r in ok if num(r.get(m)) is not None]
            stats.append(summarize(chain, st, m, [v for _, v in keyed], seed, b))
            w = worst(chain, st, m, keyed, higher_is_worse=m != "out_ours")
            if w:
                worsts.append(w)
    modes = sorted({r["mode"] for r in rows})
    for i, a in enumerate(modes):
        for bm in modes[i + 1:]:
            for m in ("gas_real", "out_ours"):
                keyed, dropped = paired(rows, a, bm, m)
                st = f"paired:{bm}-minus-{a}|dropped={dropped}"
                stats.append(summarize(chain, st, "d_" + m, [v for _, v in keyed], seed, b))
                w = worst(chain, st, "d_" + m, keyed, higher_is_worse=m == "gas_real")
                if w:
                    worsts.append(w)
    write_tsv(out_stats, STATS_COLS, stats)
    write_tsv(os.path.join(os.path.dirname(os.path.abspath(out_stats)), "worst.tsv"), WORST_COLS, worsts)
    return stats


def main(argv):
    if len(argv) < 2:
        sys.exit(__doc__)
    consts = {}
    if "--prereg" in argv:
        sys.path.insert(0, HERE)
        from harness import read_prereg
        consts = read_prereg(argv[argv.index("--prereg") + 1], allow_unlocked=True)["consts"]
    nprime = int(argv[argv.index("--nprime") + 1]) if "--nprime" in argv else 8
    seed = boot_seed(consts.get("BOOT_SEED"))
    b = int(consts.get("BOOT_B", BOOT_B))
    run(argv[0], argv[1], seed, b, nprime)


if __name__ == "__main__":
    main(sys.argv[1:])
