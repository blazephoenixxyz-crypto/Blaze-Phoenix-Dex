#!/usr/bin/env python3
"""Gas case study 1114: add the paired output differences to the per-swap results (stdlib only).

  python3 -I tools/gas-case-study/join.py <results.tsv> [--market <market.tsv>] -o <out.tsv>

d_best_single_bps = (amount_out - amount_out[best_single]) * 10000 / amount_out[best_single], paired
  with the one row of mode=best_single that has the same chain, cell_id, i and temp.
d_market_bps      = (amount_out - M) * 10000 / M, M = the largest amount_out among the market.tsv rows
  with status=ok and the same chain, cell_id, i (and, when both sides carry them, the same token_in,
  token_out and amount_in: a quote for another trade is not a pair).
Empty, never 0, when the pair is missing, ambiguous (two best_single rows), or a side has no positive
amount_out. Both columns are overwritten if present, appended otherwise; every other cell is kept.
market.tsv: a first comment line '#...', then the header (chain cell_id i token_in token_out amount_in
source status amount_out gas_estimate gas_field quote_unix latest_block http_code latency_ms
resp_sha256 detail).
"""
import sys
from fractions import Fraction

NEW = ("d_best_single_bps", "d_market_bps")


def read(path):
    """(header, rows) of a TSV; lines starting with '#' and blank lines are skipped."""
    with open(path) as f:
        lines = [ln.rstrip("\n") for ln in f if ln.strip() and not ln.startswith("#")]
    if not lines:
        return [], []
    cols = lines[0].split("\t")
    return cols, [dict(zip(cols, ln.split("\t"))) for ln in lines[1:]]


def pos(x):
    """A positive integer amount, else None (absent, empty, zero or not an integer)."""
    try:
        v = int(str(x).strip())
    except (TypeError, ValueError):
        return None
    return v if v > 0 else None


def bps(out, ref):
    """(out - ref) * 10000 / ref, exact then rounded to 4 decimals; '' if either side is absent."""
    o, r = pos(out), pos(ref)
    if o is None or r is None:
        return ""
    return "%.4f" % float(Fraction((o - r) * 10000, r))


def _same(a, b, k):
    x, y = (a.get(k) or "").strip().lower(), (b.get(k) or "").strip().lower()
    return not x or not y or x == y


def join(rows, market=None):
    best = {}
    for r in rows:
        if r.get("mode") == "best_single":
            k = (r.get("chain"), r.get("cell_id"), r.get("i"), r.get("temp"))
            best.setdefault(k, []).append(r)
    mk = {}
    for m in market or []:
        if m.get("status") == "ok" and pos(m.get("amount_out")) is not None:
            mk.setdefault((m.get("chain"), m.get("cell_id"), m.get("i")), []).append(m)
    for r in rows:
        b = best.get((r.get("chain"), r.get("cell_id"), r.get("i"), r.get("temp")), [])
        r["d_best_single_bps"] = bps(r.get("amount_out"), b[0].get("amount_out")) if len(b) == 1 else ""
        cands = [pos(m["amount_out"]) for m in mk.get((r.get("chain"), r.get("cell_id"), r.get("i")), [])
                 if all(_same(r, m, k) for k in ("token_in", "token_out", "amount_in"))]
        r["d_market_bps"] = bps(r.get("amount_out"), max(cands)) if cands else ""
    return rows


def write(path, cols, rows):
    with open(path, "w") as f:
        f.write("\t".join(cols) + "\n")
        for r in rows:
            f.write("\t".join(str(r.get(c, "")) for c in cols) + "\n")


def main(argv):
    args, market, out = [], None, None
    it = iter(argv)
    for a in it:
        if a == "--market":
            market = next(it)
        elif a == "-o":
            out = next(it)
        else:
            args.append(a)
    if len(args) != 1 or not out:
        print(__doc__, file=sys.stderr)
        return 2
    cols, rows = read(args[0])
    mrows = read(market)[1] if market else None
    cols = cols + [c for c in NEW if c not in cols]
    write(out, cols, join(rows, mrows))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
