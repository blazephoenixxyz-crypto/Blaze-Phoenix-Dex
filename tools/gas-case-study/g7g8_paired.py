#!/usr/bin/env python3
"""Gas case study 1114: the paired comparison of two modes in a G7/G8 results.tsv (stdlib only).

  python3 -I tools/gas-case-study/g7g8_paired.py <results.tsv> <out.tsv> [--seed S] [--boot-b B]
      [--pairs D:M0,D:M1h,D:MF*]

Input: the results.tsv of tools/g7-gas-campaign/g7.py (COLS) or of tools/g8-pool-tests/g8.py, which
writes the same schema. Columns are read by name; the ones used are chain, stratum, idx, b, mode,
outcome, net_out, g_quote, g_exec, g_record.

A pair A:B compares mode B against mode A on the same key (chain, stratum, idx, b):
- gas metrics g_quote, g_exec, g_record: d = g_B - g_A (gas units, signed);
- out_bps: (net_out_B - net_out_A) * 1e4 / net_out_A (basis points of A's output, signed).
A mode B ending in '*' is a glob over the modes present in the file (D:MF* -> D:MF24h, D:MF72h, ...).

Every key that either side carries is in the denominator (n_keys). A key pairs only when both rows
exist, both outcomes are ok and both values are present; every other key is counted in n_dropped and
published by reason in drop_reasons (missing_<mode>, <mode>:<outcome>, <mode>:<metric>_absent,
<mode>:net_out_nonpos). net_out_A = 0 is a reason, never a division: absent is not zero. A pair or a
chain with no key gives a row with n = 0 and empty statistics.

Intervals reuse tools/gas-case-study/stats.py: the 95% interval of the median is its percentile
bootstrap (B resamples from random.Random(seed); seed = stats.boot_seed(--seed), by default
int(sha256("gas-1114-boot")) mod 2^32); the pairing rate n_pairs/n_keys carries Wilson's interval.
The worst case is the largest gas increase (max d) or the largest output loss (min out_bps).

out.tsv (header once): chain mode_a mode_b metric n_keys n_pairs n_dropped median p5 p95 ci95_lo
ci95_hi worst worst_key pair_rate pair_rate_lo pair_rate_hi boot_seed boot_b drop_reasons
"""
import fnmatch
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from stats import BOOT_B, boot_seed, bootstrap_ci, median, pct, read_tsv, wilson  # noqa: E402

KEY = ("chain", "stratum", "idx", "b")
GAS_METRICS = ("g_quote", "g_exec", "g_record")
METRICS = GAS_METRICS + ("out_bps",)
NEEDED = KEY + ("mode", "outcome", "net_out") + GAS_METRICS
DEFAULT_PAIRS = "D:M0,D:M1h,D:MF*"
OUT_COLS = ("chain mode_a mode_b metric n_keys n_pairs n_dropped median p5 p95 ci95_lo ci95_hi worst "
            "worst_key pair_rate pair_rate_lo pair_rate_hi boot_seed boot_b drop_reasons").split()


def ival(x):
    """An integer cell, or None when the cell is empty (absent, not zero)."""
    return None if x in ("", None) else int(x)


def parse_pairs(spec, modes):
    """'D:M0,D:MF*' -> [(D, M0), (D, MF24h), ...]; a glob that matches nothing stays literal (n = 0)."""
    out = []
    for item in spec.split(","):
        item = item.strip()
        if not item:
            continue
        a, sep, b = item.partition(":")
        if not sep or not a or not b:
            raise ValueError(f"pair {item!r} is not A:B")
        bs = sorted(m for m in modes if fnmatch.fnmatchcase(m, b)) if "*" in b else [b]
        for bm in bs or [b]:
            if (a, bm) not in out and a != bm:
                out.append((a, bm))
    return out


def index(rows):
    """{chain: {mode: {(stratum, idx, b): row}}}; a duplicated key in one mode is refused."""
    idx = {}
    for r in rows:
        k = tuple(r[c] for c in KEY[1:])
        by = idx.setdefault(r["chain"], {}).setdefault(r["mode"], {})
        if k in by:
            raise ValueError(f"duplicate key {r['chain']}/{'/'.join(k)} in mode {r['mode']}")
        by[k] = r
    return idx


def value(ra, rb, metric):
    """(value, None) for a paired key, else (None, reason)."""
    if metric == "out_bps":
        oa, ob = ival(ra["net_out"]), ival(rb["net_out"])
        absent = [f"{r['mode']}:net_out_absent" for r, v in ((ra, oa), (rb, ob)) if v is None]
        if absent:
            return None, "+".join(absent)
        if oa <= 0:
            return None, f"{ra['mode']}:net_out_nonpos"
        return (ob - oa) * 10000 / oa, None
    va, vb = ival(ra[metric]), ival(rb[metric])
    absent = [f"{r['mode']}:{metric}_absent" for r, v in ((ra, va), (rb, vb)) if v is None]
    if absent:
        return None, "+".join(absent)
    return vb - va, None


def compare(side_a, side_b, mode_a, mode_b, metric):
    """Pair two {key: row} maps; ([(key, d)], {reason: count}, n_keys)."""
    keyed, reasons = [], {}
    keys = sorted(set(side_a) | set(side_b))
    for k in keys:
        ra, rb = side_a.get(k), side_b.get(k)
        if ra is None or rb is None:
            why = f"missing_{mode_a if ra is None else mode_b}"
        else:
            bad = [f"{r['mode']}:{r['outcome'] or 'outcome_absent'}" for r in (ra, rb) if r["outcome"] != "ok"]
            why = "+".join(bad) if bad else None
            if why is None:
                v, why = value(ra, rb, metric)
                if why is None:
                    keyed.append(("|".join(k), v))
                    continue
        reasons[why] = reasons.get(why, 0) + 1
    return keyed, reasons, len(keys)


def row(chain, mode_a, mode_b, metric, keyed, reasons, n_keys, seed, b):
    vals = [v for _, v in keyed]
    out = dict(chain=chain, mode_a=mode_a, mode_b=mode_b, metric=metric, n_keys=n_keys, n_pairs=len(vals),
               n_dropped=sum(reasons.values()), boot_seed=seed, boot_b=b,
               drop_reasons=";".join(f"{k}={reasons[k]}" for k in sorted(reasons)))
    if n_keys != out["n_pairs"] + out["n_dropped"]:
        raise AssertionError("denominator lost a key")
    w = wilson(len(vals), n_keys)
    if w:
        out.update(pair_rate=len(vals) / n_keys, pair_rate_lo=w[0], pair_rate_hi=w[1])
    if vals:
        lo, hi = bootstrap_ci(vals, seed, b)
        wk, wv = (min if metric == "out_bps" else max)(keyed, key=lambda kv: kv[1])
        out.update(median=median(vals), p5=pct(vals, 5), p95=pct(vals, 95), ci95_lo=lo, ci95_hi=hi,
                   worst=wv, worst_key=wk)
    return out


def run(rows, pairs_spec=DEFAULT_PAIRS, seed=None, b=BOOT_B):
    if rows:
        missing = [c for c in NEEDED if c not in rows[0]]
        if missing:
            raise ValueError(f"results.tsv lacks columns {missing}")
    seed = boot_seed() if seed is None else seed
    idx = index(rows)
    pairs = parse_pairs(pairs_spec, {r["mode"] for r in rows})
    out = []
    for chain in sorted(idx):
        for a, bm in pairs:
            side_a, side_b = idx[chain].get(a, {}), idx[chain].get(bm, {})
            for m in METRICS:
                keyed, reasons, n_keys = compare(side_a, side_b, a, bm, m)
                out.append(row(chain, a, bm, m, keyed, reasons, n_keys, seed, b))
    return out


def write(path, rows):
    with open(path, "w") as f:
        f.write("\t".join(OUT_COLS) + "\n")
        for r in rows:
            f.write("\t".join(str(r.get(c, "")) for c in OUT_COLS) + "\n")


def main(argv):
    if len(argv) < 2 or argv[0].startswith("--") or argv[1].startswith("--"):
        sys.exit(__doc__)

    def opt(name, default=None):
        return argv[argv.index(name) + 1] if name in argv else default

    seed = boot_seed(opt("--seed"))
    b = int(opt("--boot-b", BOOT_B))
    write(argv[1], run(read_tsv(argv[0]), opt("--pairs", DEFAULT_PAIRS), seed, b))


if __name__ == "__main__":
    main(sys.argv[1:])
