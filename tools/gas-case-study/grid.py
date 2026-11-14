#!/usr/bin/env python3
"""Build docs/prereg/gas-1114.tsv and gas-1114-aged.tsv from the committed universe + token prices.
No RPC. Deterministic: same inputs -> same bytes."""
import hashlib
import math
import sys

sys.path.insert(0, "/home/blaze/bp-dex-wt-pr124-L6/tools/gas-case-study")
import universe as U  # noqa: E402  (select() and COLS only)

WT = "/home/blaze/bp-dex-wt-pr124-L6"
SC = "/tmp/claude-1001/-home-blaze-cofre/7ec5bc6d-a2bc-5b80-962c-426232415b7e/scratchpad/uni"
CHAINS = ["base", "ethereum", "optimism", "arbitrum", "robinhood", "avalanche", "bsc"]
WRAP = dict(arbitrum="0x82af49447d8a07e3bd95bd0d56f35241523fbab1", avalanche="0xb31f66aa3c1e785363f0875a1b74e27b85fd66c7",
            base="0x4200000000000000000000000000000000000006", bsc="0xbb4cdb9cbd36b01bd1cbaebf2de08d9173bc095c",
            ethereum="0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2", optimism="0x4200000000000000000000000000000000000006",
            robinhood="0x0bd7d308f8e1639fab988df18a8011f41eacad73")
MAXH = dict(arbitrum=2, avalanche=3, base=2, bsc=3, ethereum=2, optimism=2, robinhood=2)
ZERO = "0x" + "0" * 40
TAG = "gas-1114"
N = 8
KS = list(range(-2, 8))
NATIVE_AD = "routable: Hub kind V4_NATIVE (amendment SA1c: Hub.addV4 nat, Hub.sol:935-990; _scanV4 Hub.sol:1271-1314; Router.sol:1007,2083)"
MOON = ["D", "M0", "M1h", "M6h", "M24h", "M72h", "MF24h", "MF72h"]
AGES = [7, 10, 25]
AGED_KS = [2, 4, 6]
AGED_WINDOW_S = 86400
AGED_MIN_BACK_S = 60


def seed(*parts):
    return hashlib.sha256("|".join(str(p) for p in parts).encode()).hexdigest()


def frac(h):  # u in [0,1) from the low 64 bits
    return int(h[-16:], 16) / 2 ** 64


rows_all = [ln.rstrip("\n").split("\t") for ln in open(WT + "/docs/prereg/gas-1114-universe.tsv")][1:]
out, aged = [], []
changes, summary = [], []
for ch in CHAINS:
    tok = {}
    for ln in open(f"{SC}/{ch}.tsv.tokens"):
        p = ln.rstrip("\n").split("\t")
        if p[0] != ch:
            continue
        tok[p[2]] = dict(sym=p[3], dec=int(p[4]), px=float(p[5]) if p[5] else None, role=p[8])
    A = [t for t in tok if tok[t]["role"] == "A"]
    tok[ZERO] = dict(tok[WRAP[ch]])
    rows = [dict(zip(U.COLS, r)) for r in rows_all if r[0] == ch]
    block = rows[0]["block"]
    before = {r["pool"] for r in rows if r["selected"] == "yes"}
    for r in rows:
        r["selected"], r["reason"] = "no", ""
        if r["kind"] == "v4" and r["token0"] == ZERO:
            r["adapter"] = NATIVE_AD
    U.select(ch, rows)
    sel = [r for r in rows if r["selected"] == "yes"]
    after = {r["pool"] for r in sel}
    for p in sorted(before - after):
        changes.append(f"{ch}\tdropped\t{p}")
    for p in sorted(after - before):
        r = next(x for x in sel if x["pool"] == p)
        changes.append(f"{ch}\tadded\t{p}\t{r['kind']}\t{r['token0']}\t{r['token1']}\t{r['fee_or_param']}\t{r['tvl_usd']}\t{r['reason']}")

    def pk(r):
        a, b = (WRAP[ch] if r["token0"] == ZERO else r["token0"]), r["token1"]
        return tuple(sorted((a, b)))
    route = [r for r in rows if not r["adapter"].startswith("out:") and r["tvl_usd"] and float(r["tvl_usd"]) > 0]
    routable_pairs = {pk(r) for r in route}
    pairs = sorted({pk(r) for r in sel})
    out.append(["block", ch, block, str(len(sel)), str(len(pairs)), WRAP[ch], str(MAXH[ch])])
    for r in sel:
        out.append(["pool", ch, block, r["pool"], r["kind"], r["token0"], r["token1"], r["fee_or_param"], r["tvl_usd"],
                    r["tvl_method"], r["reason"]])
    ncell = ndraw = nout = 0
    for a, b in pairs:
        ps = [r for r in sel if pk(r) == (a, b)]
        pb = [r for r in ps if r["tvl_method"].startswith("balances")]
        W = 0.25 * sum(float(r["tvl_usd"]) for r in (pb or ps))
        basis = "balances" if pb else "v4-inrange-virtual (upper bound, not TVL)"
        pname = f"{tok[a]['sym']}/{tok[b]['sym']}"
        modes = ["quoted@M0"] + [f"onchain@{m}" for m in MOON] + ["best_single"]
        nat = WRAP[ch] in (a, b)
        modes.append("native@M0(draws with token_in=wrapped native)" if nat else "native:out(pair has no wrapped native)")
        br = next((x for x in A if x not in (a, b) and tuple(sorted((a, x))) in routable_pairs
                   and tuple(sorted((x, b))) in routable_pairs), None)
        modes.append(f"forced2hop@M0 via {br}" if br else "forced2hop:out(no bridge with routable pools on both hops)")
        buckets = ["dust"] + [f"k{k}" for k in KS] + ["whale"]
        for bk in buckets:
            cid = f"{ch}:{pname}:{bk}"
            lo = None if bk in ("dust", "whale") else 10.0 ** int(bk[1:])
            if lo is not None and lo >= W:
                out.append(["out", cid, f"bucket floor {lo:g} USD >= whale {W:.2f} USD"])
                nout += 1
                continue
            if any(tok[t]["px"] is None for t in (a, b)) and bk != "dust":
                out.append(["out", cid, "absent price (no priced pool): size in USD undefined"])
                nout += 1
                continue
            out.append(["cell", cid, ch, block, a, b, bk, f"{W:.2f}", basis, str(N), ";".join(modes), "cold;warm"])
            ncell += 1
            for i in range(N):
                tin, tout = (a, b) if i % 2 == 0 else (b, a)
                h = seed(TAG, ch, a, b, bk, i)
                f = frac(h)
                if bk == "dust":
                    amt, usd = 1 + int(h, 16) % 1000, None
                else:
                    usd = W * 2 ** (-f) if bk == "whale" else 10.0 ** (int(bk[1:]) + f)
                    amt = max(1, math.floor(usd / tok[tin]["px"] * 10 ** tok[tin]["dec"]))
                out.append(["draw", cid, str(i), tin, tout, h, "" if usd is None else f"{usd:.6f}", str(amt)])
                ndraw += 1
        # aged: same pair, sizes k2/k4/k6 + whale, ages paired on one quote block and one amount per draw
        for bk in [f"k{k}" for k in AGED_KS] + ["whale"]:
            cid = f"{ch}:{pname}:{bk}"
            lo = None if bk == "whale" else 10.0 ** int(bk[1:])
            if (lo is not None and lo >= W) or any(tok[t]["px"] is None for t in (a, b)):
                aged.append(["out", cid, "bucket floor >= whale" if lo is not None and lo >= W else "absent price"])
                continue
            aged.append(["cell", cid, ch, block, a, b, bk, f"{W:.2f}", str(N), ",".join(map(str, AGES))])
            for i in range(N):
                tin, tout = (a, b) if i % 2 == 0 else (b, a)
                h = seed(TAG + "-aged", ch, a, b, bk, i)
                hb = seed(TAG + "-aged-block", ch, a, b, bk, i)
                back = AGED_MIN_BACK_S + frac(hb) * (AGED_WINDOW_S - AGED_MIN_BACK_S)
                usd = W * 2 ** (-frac(h)) if bk == "whale" else 10.0 ** (int(bk[1:]) + frac(h))
                amt = max(1, math.floor(usd / tok[tin]["px"] * 10 ** tok[tin]["dec"]))
                aged.append(["draw", cid, str(i), tin, tout, h, hb, f"{back:.3f}", f"{usd:.6f}", str(amt)])
    summary.append(f"{ch}\tblock {block}\tpairs {len(pairs)}\tcells {ncell}\tout {nout}\tdraws {ndraw}")

with open(sys.argv[1], "w") as f:
    f.write("\n".join("\t".join(r) for r in out) + "\n")
with open(sys.argv[2], "w") as f:
    f.write("\n".join("\t".join(r) for r in aged) + "\n")
print("\n".join(summary))
print("\n".join(changes))
