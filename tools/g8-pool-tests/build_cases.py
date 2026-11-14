#!/usr/bin/env python3
"""G8: isolated per-pool cases (quote + execution, moonslot and Discovery side by side) and the
bridge cases, pre-registered before any measurement.
  build_cases.py build <g7dir> <g7 spec.json> <outdir> [--bridges bridges.tsv] [--pairs pair_tokens.tsv]

Inputs: the G7 inventory (<g7dir>/inventory.tsv, S2) and the G7 spec (window, ages, chains, the
gate strata with their created wrappers). Nothing here touches an RPC.
  * pool-<family>: the deepest pool (liq_usd) of each family per chain, seeded ALONE (seed_pools =
    that pool); a gate family reuses the G7 gate stratum of the same pool (the wrapper exists only
    there); a gate pool without one is not_covered. Rows without liq_usd are not ranked.
  * xb-<family>-<bridge>-<token address>: exotic -> bridge (and back, the runner draws both directions):
    each non-bridge token of the pool vs each bridge of the chain, the deepest non-gate pool of
    that pair seeded alone; no pool = not_covered.
  * via-<family>-<bridge>: exotic -> exotic through one bridge at 2 hops: the two non-bridge tokens
    of the pool with ONLY the two hop pools seeded (the bridge is forced by the seed, not by a
    flag); a pair with no common bridge is not_covered (S9-P register). The direct case is the
    pool stratum itself.
  * xb-pair-<bridge>-<token address>: the same exotic -> bridge case for each pair token of
    pair_tokens.tsv (chain symbol address source; a pair token is not a bridge), the deepest
    non-gate pool of the token and each bridge seeded alone; no pool = not_covered.
  * amounts: pool balance of the input token // 10^5, 10^3, 10^1 (dust, mid, deep).
  * chains without a bridge list (bridges.tsv) get no bridge cases: not_covered, absent is not zero.
Every row of results.tsv then carries chain, label (tree commit), b, tin, tout, amount_in, mode,
calldata segments and gas by segment; README.md gives the exact command to redo it."""
import json
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "g7-gas-campaign"))
import build_spec as bs  # noqa: E402

STEPS = (5, 3, 1)  # balance // 10^k
COPY = ("window", "ages", "mf_ages", "deadline_s", "retries", "state_fork")
CHAIN_COPY = ("block_time_hint", "label", "max_hops", "native_wrap")


def read_bridges(path):
    """{chain: [(symbol, address)]} from bridges.tsv (chain symbol address source); chains absent
    from the file are absent (no bridge cases), never an empty list."""
    out = {}
    for r in bs.read_tsv(path):
        if r.get("address", "").startswith("0x") and len(r["address"]) == 42:
            out.setdefault(r["chain"], []).append((r["symbol"], r["address"].lower()))
    return out


def top_per_family(rows):
    """{family: deepest row by liq_usd}; a row without liq_usd is not ranked (absent is not zero)."""
    best = {}
    for r in rows:
        v = bs.liq(r)
        if v is None:
            continue
        if r["family"] not in best or v > bs.liq(best[r["family"]]):
            best[r["family"]] = r
    return best


def amounts(bal):
    bal = int(bs.num(bal) or 0)
    return [bal // 10 ** k for k in STEPS if bal // 10 ** k > 0]


def deepest(rows):
    ok = [r for r in rows if r["family"] not in bs.GATE_FAMS and bs.liq(r)]
    return max(ok, key=bs.liq) if ok else None


def bal_of(r, token):
    return r["bal0"] if r["token0"].lower() == token else r["bal1"]


def pool_stratum(sid, kind, r, ta, tb, pools, fam):
    a, b = amounts(bal_of(r, ta)), amounts(bal_of(r, tb))
    if not a or not b:
        return None
    return {"id": sid, "kind": kind, "tA": ta, "tB": tb, "amounts": {"A": a, "B": b}, "n": 1,
            "seed_pools": bs.seed_pools(pools), "mid_pool": bs.mid_pool([r]), "_pool": r["pool"].lower(),
            "_family": fam, "_liq": r.get("liq_usd", "")}


def build(g7dir, g7spec, outdir, bridges, pairs=None):
    inv = bs.read_tsv(os.path.join(g7dir, "inventory.tsv"))
    spec = {k: g7spec[k] for k in COPY}
    spec["criteria"] = __doc__.split("Inputs:")[1].strip()
    spec["chains"], notcov, cases = {}, [], []
    for chain, c7 in g7spec["chains"].items():
        rows = [r for r in inv if r["chain"] == chain]
        by_pair = {}
        for r in rows:
            by_pair.setdefault(bs.pair(r), []).append(r)
        gate_by_pool = {st["gate_pool"].lower(): st for st in c7["strata"] if st["kind"] == "gates"}
        strata = []
        br = bridges.get(chain)
        if br is None:
            notcov.append((chain, "bridge", "no bridge list for the chain in bridges.tsv (absent, not zero)"))
        baddr = {a for _, a in (br or [])}
        for fam, r in sorted(top_per_family(rows).items()):
            ta, tb = r["token0"].lower(), r["token1"].lower()
            if fam in bs.GATE_FAMS:
                g = gate_by_pool.get(r["pool"].lower())
                if not g:
                    notcov.append((chain, fam, "gate pool without a created wrapper in the G7 prereg (absent, not zero): %s" % r["pool"]))
                    continue
                st = dict(g, id="pool-" + fam, kind="pool", n=1, _pool=r["pool"].lower(), _family=fam, _liq=r.get("liq_usd", ""))
            else:
                st = pool_stratum("pool-" + fam, "pool", r, ta, tb, [r], fam)
                if not st:
                    notcov.append((chain, fam, "pool without a measured balance (absent, not zero): %s" % r["pool"]))
                    continue
            strata.append(st)
            if br is None:
                continue
            ex = [t for t in (ta, tb) if t not in baddr]
            hop = {}
            for x in ex:
                for sym, b in br:
                    p = deepest(by_pair.get(tuple(sorted((x, b))), []))
                    if not p:
                        notcov.append((chain, "xb-%s-%s" % (fam, sym), "no non-gate pool for %s/%s (absent, not zero)" % (x, b)))
                        continue
                    hop[(x, b)] = p
                    s2 = pool_stratum("xb-%s-%s-%s" % (fam, sym, x), "exotic_bridge", p, x, b, [p], p["family"])
                    if s2:
                        strata.append(s2)
            if len(ex) == 2:
                x, y, common = ex[0], ex[1], 0
                for sym, b in br:
                    p1, p2 = hop.get((x, b)), hop.get((y, b))
                    if not (p1 and p2):
                        continue
                    common += 1
                    s3 = pool_stratum("via-%s-%s" % (fam, sym), "exotic_via_bridge", r, x, y, [p1, p2], fam)
                    if s3:
                        s3["_hops"] = [p1["pool"].lower(), p2["pool"].lower()]
                        strata.append(s3)
                if not common:
                    notcov.append((chain, "via-" + fam, "pair without a common bridge (S9-P): %s/%s" % (x, y)))
        for _, x in (pairs or {}).get(chain, []) if br else []:
            for sym, b in br:
                p = deepest(by_pair.get(tuple(sorted((x, b))), []))
                if not p:
                    notcov.append((chain, "xb-pair-" + sym, "no non-gate pool for pair token %s/%s (absent, not zero)" % (x, b)))
                    continue
                s2 = pool_stratum("xb-pair-%s-%s" % (sym, x), "exotic_bridge", p, x, b, [p], p["family"])
                if s2:
                    strata.append(s2)
        spec["chains"][chain] = dict({k: c7[k] for k in CHAIN_COPY}, strata=strata)
        cases += [(chain, st) for st in strata]
    pre = os.path.join(outdir, "prereg")
    os.makedirs(pre, exist_ok=True)
    with open(os.path.join(outdir, "spec.json"), "w") as f:
        json.dump(spec, f, indent=1, sort_keys=True)
    with open(os.path.join(pre, "strata.tsv"), "w") as f:
        f.write("chain\tid\tkind\tfamily\tpool\ttA\ttB\tnA\tnB\tliq_usd\tseed_pools\thops\n")
        for chain, st in cases:
            f.write("\t".join([chain, st["id"], st["kind"], st["_family"], st["_pool"], st["tA"], st["tB"],
                               str(len(st["amounts"]["A"])), str(len(st["amounts"]["B"])), str(st["_liq"]),
                               ",".join(p["pool"] for p in st["seed_pools"]), ",".join(st.get("_hops", []))]) + "\n")
    with open(os.path.join(pre, "not_covered.tsv"), "w") as f:
        f.write("chain\tscope\treason\n")
        for row in notcov:
            f.write("\t".join(row) + "\n")
    return spec, notcov


if __name__ == "__main__":
    a = sys.argv[1:]
    if a[:1] == ["build"] and len(a) >= 4:
        here = os.path.dirname(os.path.abspath(__file__))
        bp = a[a.index("--bridges") + 1] if "--bridges" in a else os.path.join(here, "bridges.tsv")
        pp = a[a.index("--pairs") + 1] if "--pairs" in a else os.path.join(here, "pair_tokens.tsv")
        s, nc = build(a[1], json.load(open(a[2])), a[3], read_bridges(bp), read_bridges(pp) if os.path.exists(pp) else {})
        print("chains=%d strata=%d not_covered=%d" % (len(s["chains"]), sum(len(c["strata"]) for c in s["chains"].values()), len(nc)))
    else:
        sys.exit(__doc__)
