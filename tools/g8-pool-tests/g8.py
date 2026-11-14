#!/usr/bin/env python3
"""G8 runner: the G7 measurement (g7.py: Chain, measure_draw, the same columns and segments) over
the pre-registered per-pool and bridge cases of spec.json, with a deterministic draw list.
  g8.py measure <spec.json> <statedir> <out.tsv> <seed> [-j N] [--chains a,b]
  g8.py report <spec.json> <out.tsv>

draws: per stratum one block (seeded, uniform in the G7 window), both directions, every amount
of the direction: idx 1..nA forward (tA -> tB), nA+1..nA+nB backward. Every mode of the spec
(D, the moonslot ages, the forced ages) runs on each draw, so M and D sit side by side per row.
The report prints the G7 tables, then one line per (chain, stratum, mode) and the per-case split:
one line per (chain, stratum, ms_case, segment) with n, p50 and p95, where est_gas is the quote's
own estimate (ABI preview) and the other segments are measured on chain."""
import concurrent.futures as cf
import json
import os
import sys
import threading
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "g7-gas-campaign"))
import g7  # noqa: E402

CASE_SEGS = ("net_out", "g_quote", "g_exec", "g_legs_sum", "dex_overhead", "g_record", "out_vs_D_bps")
CASE_SPLIT_SEGS = ("est_gas",) + g7.SPLIT_SEGS  # quote ABI estimate, then the on-chain segments


def draws(spec, seed, chain, b0, b1):
    out = []
    for st in spec["chains"][chain]["strata"]:
        rng = g7.stratum_rng(seed.lower(), f"{chain}/{st['id']}")
        b, idx = rng.randint(b0, b1), 0
        for fwd in (True, False):
            tin, tout = (st["tA"], st["tB"]) if fwd else (st["tB"], st["tA"])
            tin, tout = (g7.native(spec, chain, t) for t in (tin, tout))
            for amt in st["amounts"]["A" if fwd else "B"]:
                idx += 1
                out.append({"stratum": st["id"], "kind": st["kind"], "idx": idx, "b": b, "tin": tin, "tout": tout,
                            "amount": int(amt), "st": st})
    return out


def cmd_measure(spec_path, statedir, out_path, seed, jobs, only=None):
    spec = json.load(open(spec_path))
    done = g7.load_done(out_path)
    new = not os.path.exists(out_path)
    out = open(out_path, "a")
    if new:
        out.write("\t".join(g7.COLS) + "\n")
    lock, tasks, liq = threading.Lock(), [], g7.load_liq(spec_path)
    for cn in spec["chains"]:
        if only and cn not in only:
            continue
        ch = g7.Chain(cn, spec, statedir)
        ch.liq = liq.get(cn, {})
        b0, b1 = g7.window(ch.rpc, spec)
        ch.b0 = b0
        ds = draws(spec, seed, cn, b0, b1)
        print(f"{cn}: window {b0}..{b1}, {len(ds)} draws, label {ch.label}", flush=True)
        tasks += [(ch, d) for d in ds]
    with cf.ThreadPoolExecutor(jobs) as ex:
        futs = {ex.submit(g7.measure_draw, ch, d, done): (ch.name, d["stratum"], d["idx"]) for ch, d in tasks}
        for i, f in enumerate(cf.as_completed(futs), 1):
            g7.write_rows(out, lock, f.result())
            if i % 10 == 0:
                print(f"{time.strftime('%H:%M:%S')} {i}/{len(tasks)} {futs[f]}", flush=True)
    out.close()
    rows = g7.classify_rows(g7.load_rows(out_path))
    with open(out_path, "w") as f:
        f.write("\t".join(g7.COLS) + "\n")
        g7.write_rows(f, lock, rows)


def case_lines(spec, rows):
    """One line per (chain, stratum, mode): the counts per outcome, the p50 of each CASE_SEG over
    the ok rows and the ms_case tally; strata in spec order, modes in spec order (D first)."""
    for r in rows:
        if not r.get("ms_case"):
            r["ms_case"] = g7.ms_case(r)
    out = ["# per case: chain\tstratum\tkind\tfamily\tpool\tmode\tn\t" + "\t".join(g7.OUTCOMES) + "\t"
           + "\t".join(s + "_p50" for s in CASE_SEGS) + "\tms_cases"]
    for cn, c in spec["chains"].items():
        for st in c["strata"]:
            for m, _, _ in g7.modes(spec):
                rs = [r for r in rows if (r["chain"], r["stratum"], r["mode"]) == (cn, st["id"], m)]
                if not rs:
                    continue
                ok = [r for r in rs if r["outcome"] == "ok"]
                cells = []
                for s in CASE_SEGS:
                    v = [x for x in (g7.split_value(r, s) if s in g7.SPLIT_SEGS else _num(r.get(s)) for r in ok) if x is not None]
                    cells.append(str(g7.pct(v, 50)) if v else "")
                ms = ",".join(f"{k}:{sum(r['ms_case'] == k for r in ok)}" for k in g7.MS_CASES if any(r["ms_case"] == k for r in ok))
                out.append("\t".join([cn, st["id"], st["kind"], st.get("_family", ""), st.get("_pool", ""), m, str(len(rs))]
                                     + [str(sum(r["outcome"] == o for r in rs)) for o in g7.OUTCOMES] + cells + [ms]))
    return out


def case_split(spec, rows):
    """One line per (chain, stratum, ms_case, segment) over the ok rows: n, p50, p95. est_gas is the
    quote's own estimate (ABI preview); g_quote, g_exec, g_legs_sum, dex_overhead (= g_exec -
    g_legs_sum) and g_record are measured on chain. Strata in spec order, cases in g7.MS_CASES
    order (D / hit / partial / miss / expired); a segment without a value prints nothing."""
    for r in rows:
        if not r.get("ms_case"):
            r["ms_case"] = g7.ms_case(r)
    out = ["# per case split: chain\tstratum\tkind\tfamily\tpool\tms_case\tsegment\tn\tp50\tp95"]
    for cn, c in spec["chains"].items():
        for st in c["strata"]:
            for k in g7.MS_CASES:
                rs = [r for r in rows if (r["chain"], r["stratum"], r["ms_case"]) == (cn, st["id"], k) and r["outcome"] == "ok"]
                for s in CASE_SPLIT_SEGS:
                    v = [x for x in (g7.split_value(r, s) for r in rs) if x is not None]
                    if v:
                        out.append("\t".join([cn, st["id"], st["kind"], st.get("_family", ""), st.get("_pool", ""), k, s,
                                             str(len(v)), str(g7.pct(v, 50)), str(g7.pct(v, 95))]))
    return out


def _num(x):
    try:
        return int(x) if x not in ("", None) else None
    except ValueError:
        return float(x)


def cmd_report(spec_path, out_path):
    g7.cmd_report(spec_path, out_path)
    spec = json.load(open(spec_path))
    rows = g7.classify_rows(g7.load_rows(out_path))
    for ln in case_lines(spec, rows) + case_split(spec, rows):
        print(ln)


def main(a):
    if a[:1] == ["measure"] and len(a) >= 5:
        j = int(a[a.index("-j") + 1]) if "-j" in a else 2
        only = a[a.index("--chains") + 1].split(",") if "--chains" in a else None
        cmd_measure(a[1], a[2], a[3], a[4].lower(), j, only)
    elif a[:1] == ["report"] and len(a) == 3:
        cmd_report(a[1], a[2])
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main(sys.argv[1:])
