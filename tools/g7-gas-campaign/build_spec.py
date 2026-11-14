#!/usr/bin/env python3
"""G7 pre-registration builder.

  build_spec.py fetch <g7dir> <onchain.tsv>           on-chain facts (dRPC), each with its source
  build_spec.py build <g7dir> <onchain.tsv> <outdir> [--universe site_tokens.json] [--swaps N]
                                                      -> <outdir>/spec.json + <outdir>/prereg/*.tsv

Inputs are the S2 tables in <g7dir>: inventory.tsv, tokens.tsv, venues.tsv. Nothing here is
chosen by hand except the constants below, each with its source. Criteria:
  * gates stratum: the rows marked gate_top3 by inventory.finalize() (top 3 per chain x gate
    family by measured liquidity); one stratum per row; venueKey = family<<16 | slot, slot =
    liquidity rank inside (chain, adapter family) (Gate.sol: key 0 refused, family = key>>16).
  * other strata: distinct pairs per chain, by class (major, midtail, fee_high, fee_low,
    family_rep: deepest liq_usd first; shallow: shallowest liq_usd > 0 first). A row without
    liq_usd is not ranked (absent is not zero).
  * --universe: for the chains it lists, the pair strata are the site's token list instead of the
    classes (site_weth: every token vs tokens[0] = WETH; site_stable: every token vs the stable;
    site_major: pairs among featured tokens + SITE_MAJORS when listed), deduped by address pair;
    a pair with no pool or balance in the inventory goes to not_covered (absent is not zero).
    Chains outside the universe keep the classes; the gates strata never change.
  * amounts: measured balance of the input token in the pair's deepest pool x 1e-7 .. 1e-1.
  * seed_pools: <= 3 deepest seedable (non-gate) pools of the pair; mid_pool: deepest v2/v3/algebra.
A chain or family that cannot be covered gets a row in prereg/not_covered.tsv, never a number.

Liveness at b0 (H1/H1b, G7-COBERTURA 1c; an amendment to the criteria above, pending the owner):
fetch writes alive_b0 for every class candidate (eth_getCode(pool, b0) != 0x; V4 / Infinity:
the pool's state word at b0 != 0 and code at b0 for each non-native token), b0 = the first block
with ts >= window t0. When a chain has alive_b0 facts, a class candidate ranks only with
alive_b0 = 1; 0 or absent goes to not_covered. A chain without the facts keeps the classes.
"""
import json, os, sys

CHAINS = ["base", "optimism", "arbitrum", "robinhood", "ethereum", "avalanche", "bsc"]
# First block with ts >= 1790812800 (2026-10-01 00:00 UTC), dRPC 13/11 (S3.md, session 2).
STATE_FORK = {"base": 52011727, "optimism": 157607012, "arbitrum": 510496864, "robinhood": 76928651,
              "ethereum": 26093738, "avalanche": 96488900, "bsc": 125000755}
WINDOW = {"t0": 1793491200, "t1": 1794441600}  # 2026-11-01 .. 2026-11-12 00:00 UTC
AGES = {"M0": 0, "M1h": 3600, "M6h": 21600, "M24h": 86400, "M72h": 259200}
MF_AGES = ["M24h", "M72h"]
MAIN_LABEL = "fix123@2e4fdaa (selar), not main"
LABELS = {"avalanche": ("branch avax-adapters-1103@d3fbd88 (= avax-adapters-1106@1da5270), not main, MAX_HOPS=3", 3),
          "bsc": ("branch bsc-infinity-1106@7d7e40d, not main, MAX_HOPS=3", 3)}
SWAPS_PER_CHAIN = 100
CLASS_QUOTA = [("major", 5), ("midtail", 4), ("fee_high", 2), ("fee_low", 2), ("family_rep", 3), ("shallow", 3)]
SITE_MAJORS = ("USDT", "DAI", "WBTC", "wstETH", "cbBTC")  # site_major: featured + these, when the site lists them
FRACTIONS = [7, 5, 3, 2, 1]  # amount = depth // 10**k
# Kind passed to Hub.seedPool per inventory family (S3.md session 4; v4: pool = address(uint160(poolId))).
SEED_KIND = {"v2": 0, "v3": 1, "cl": 1, "v4": 4, "solidly": 5, "algebra": 6, "v4native": 8}
MID_FAM = {"v2": "v2", "solidly": "v2", "v3": "v3", "cl": "v3", "algebra": "algebra"}
# = inventory.GATE_FAMS (parity pinned by test_build_spec.py).
GATE_FAMS = {"curve_ng", "curve_crypto_ng", "balancer_v2", "balancer_v3", "lb", "algebra_integral", "inf_cl", "inf_bin"}
# Adapter family number per (chain, inventory family): GateAdapterGas.t.sol:105-108 (main),
# G7DeployAvax.s.sol:44-46,87 (LB per factory, 4 Algebra), bsc 6/7 (G7 choice, S3.md session 3).
GATE_NUM = {("base", "curve_ng"): 1, ("base", "balancer_v2"): 2, ("base", "balancer_v3"): 3,
            ("base", "curve_crypto_ng"): 4, ("avalanche", "algebra_integral"): 4,
            ("bsc", "inf_cl"): 6, ("bsc", "inf_bin"): 7}
LB_NUM = {"0x8e42f2f4101563bf679975178e880fd87d3efd4e": 1, "0xb43120c4745967fa9b93e79c149e66b0f2d6fe0c": 2,
          "0xeb480050b016f6c6d45203d2346b68bddda23d4d": 3}
Z = "0x" + "0" * 40
ZH = "0x" + "0" * 64
AD = "src/adapters/BlazePhoenixAdapter"
# forge create rows (ctor args after the gate), only with a source in the repo (S3.md session 3 (d)).
ADAPTERS = {
    ("base", 1): (AD + "CurveNG.sol:BlazePhoenixAdapterCurveNG", "0xd2002373543Ce3527023C75e7518C274A51ce712",
                  "test/fork/AdaptersFork.t.sol:35-46"),
    ("base", 2): (AD + "BalancerV2.sol:BlazePhoenixAdapterBalancerV2",
                  "0xBA12222222228d8Ba445958a75a0704d566BF2C8 [0x4C32a8a8fDa4E24139B51b456B42290f51d6A1c4,%s,%s,%s]" % (Z, Z, Z),
                  "test/fork/AdaptersFork.t.sol:94-131"),
    ("base", 3): (AD + "BalancerV3.sol:BlazePhoenixAdapterBalancerV3",
                  "0xbA1333333333a1BA1108E8412f11850A5C319bA9 [0x5cF4928a3205728bd12830E1840F7DB85c62a4B9,0x4fb47126Fa83A8734991E41B942Ac29A3266C968] [%s,%s]" % (ZH, ZH),
                  "test/fork/AdaptersFork.t.sol:94-131"),
    ("base", 4): (AD + "CurveCryptoNG.sol:BlazePhoenixAdapterCurveCryptoNG", "0xc9Fe0C63Af9A39402e8a5514f9c43Af0322b665F",
                  "test/fork/AdapterCurveCryptoNGFork.t.sol:16"),
    ("bsc", 6): (AD + "InfinityCL.sol:BlazePhoenixAdapterInfinityCL",
                 "0xa0FfB9c1CE1Fe56963B0321B32E7A0302114058b [0xb0BAa371b899950B4Ef6A27c21bAf5ef7c434d0f,0xb0bb171D333569CfD28a37F5c5DdDAAa90aD46af,%s]" % Z,
                 "bsc-infinity-1106:test/fork/bsc/BscInfinityCLFork.t.sol:24-26,_pins()"),
    ("bsc", 7): (AD + "InfinityBin.sol:BlazePhoenixAdapterInfinityBin",
                 "0xC697d2898e0D09264376196696c51D7aBbbAA4a9 [%s,%s,%s]" % (Z, Z, Z),
                 "bsc-infinity-1106:test/fork/bsc/BscInfinityBinFork.t.sol:21,39"),
}
# Adapters proposed by the chain's own deploy script (phase A), not by gate_adapters.tsv.
PHASE_A_FAMS = {"avalanche"}
ALGEBRA_DEPLOYERS = ["0x5D433A94A4a2aA8f9AA34D8D15692Dc2E9960584", "0xDcFccf2e8c4EfBba9127B80eAc76c5A122125d29"]
ALGEBRA_FACTORY = "0x512eb749541b7cf294be882d636218c84a5e9e5f"
FACTORY_TOPIC = "0x7b6dd8d5ecfd4872b6fe986eab1d044b3dca1eceb21817b5ba62084a6b9bd494"  # Factory_(address,uint8,uint8)
ADD_FACTORY_SEL = "fa1b58b0"
SEL_CUSTOM = "23da36cc"  # customPoolByPair(address,address,address)
ADD_FACTORY_SIG = "addFactory(address,uint8,uint8,bytes32,uint24[],int24[])"


def read_tsv(path):
    lines = [ln for ln in open(path).read().split("\n") if ln]
    cols = lines[0].split("\t")
    return [dict(zip(cols, ln.split("\t"))) for ln in lines[1:]]


def num(v):
    try:
        return float(v)
    except (TypeError, ValueError):
        return None


def liq(r):
    return num(r.get("liq_usd"))


# inventory.tsv rows written before inventory.VIRTUAL_LABEL was put in English carry the old
# wording; the prereg copy (gate_wrappers.tsv liq_method) is written in English.
OLD_VIRTUAL_LABEL = "liq_virtual_at_price, n\u00e3o TVL"
NEW_VIRTUAL_LABEL = "liq_virtual_at_price, not TVL"


def liq_method(r):
    return r.get("liq_method", "").replace(OLD_VIRTUAL_LABEL, NEW_VIRTUAL_LABEL)


def pair(r):
    return tuple(sorted((r["token0"].lower(), r["token1"].lower())))


def classes(r):
    return set(c for c in r.get("class", "").split(",") if c)


def pool_addr(p):
    """v4 / Infinity rows carry the PoolId (bytes32); the Hub keys them by address(uint160(id))."""
    p = p.lower()
    return p if len(p) == 42 else "0x" + p[-40:]


def word(x):
    return "0x" + x[2:].lower().rjust(64, "0")


def depth_of(rows, token):
    """Measured balance (raw units) of `token` in the deepest pool of these rows that has it."""
    for r in sorted(rows, key=lambda r: -(liq(r) or 0)):
        side = "bal0" if r["token0"].lower() == token else "bal1" if r["token1"].lower() == token else None
        v = num(r.get(side)) if side else None
        if v and v > 0:
            return int(v)
    return 0


def amounts(depth):
    out = []
    for k in FRACTIONS:
        a = depth // 10 ** k
        if a > 0 and a not in out:
            out.append(a)
    return out


def seed_pools(rows):
    ok = [r for r in rows if r["family"] in SEED_KIND and liq(r)]
    ok.sort(key=lambda r: -liq(r))
    return [{"pool": pool_addr(r["pool"]), "kind": SEED_KIND[r["family"]], "fee": int(num(r.get("fee")) or 0),
             "hooks": (r.get("hooks") or Z).lower()} for r in ok[:3]]


V4_FAMS = {"v4", "v4native"}
ID_FAMS = V4_FAMS | {"inf_bin", "inf_cl"}  # pool column is a PoolId; the manager is the factory column


def alive_at(rpc, r, block):
    """("1" | "0", source): does the row's pool exist at `block`? Address pools: code at block.
    PoolId pools: the manager's state word (V4 extsload(keccak(id, 6)) = slot0; Infinity getSlot0)
    != 0 and code for each non-native token. An RPC error raises: no fact is written (absent)."""
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import inventory as inv
    b, p = hex(block), r["pool"].lower()
    if r["family"] not in ID_FAMS:
        c = rpc.call("eth_getCode", [p, b])
        return ("0" if c in ("0x", "", None) else "1"), "eth_getCode(pool)@%d" % block
    pm = r["factory"].lower()
    if r["family"] in V4_FAMS:
        slot = inv.w(hex(inv.v4_state_slot(p)))
        data, src = "0x" + inv.SEL["extsload"][2:] + slot, "extsload(%s)" % slot
    else:
        data, src = "0x" + inv.SEL["getSlot0"][2:] + inv.w(p), "getSlot0(id)"
    s0 = rpc.call("eth_call", [{"to": pm, "data": data}, b])
    ok = int(s0[2:66] or "0", 16) != 0
    for t in (r["token0"].lower(), r["token1"].lower()):
        if ok and t != Z:
            ok = rpc.call("eth_getCode", [t, b]) not in ("0x", "", None)
    return ("1" if ok else "0"), "%s@%d on %s;eth_getCode(tokens)" % (src, block, pm)


def mid_pool(rows):
    ok = sorted((r for r in rows if r["family"] in MID_FAM and liq(r)), key=lambda r: -liq(r))
    if not ok:
        return None
    r = ok[0]
    return {"pool": r["pool"].lower(), "family": MID_FAM[r["family"]], "token0": r["token0"].lower()}


def gate_num(chain, r):
    if r["family"] == "lb":
        return LB_NUM.get(r["factory"].lower())
    return GATE_NUM.get((chain, r["family"]))


def gate_hint(r, onchain):
    """Gate.create hint (32 bytes) per family, or (None, reason). Sources: S3.md session 3."""
    f, p = r["family"], r["pool"].lower()
    if f in ("curve_ng", "curve_crypto_ng", "balancer_v3"):
        return word(p), ""
    if f == "balancer_v2":
        v = onchain.get(("balv2_poolid", p))
        return (v.lower(), "") if v else (None, "no_hint: getPoolId() not read")
    if f == "lb":
        ts = r.get("tick_spacing", "")
        return (word(hex(int(ts))), "") if ts.isdigit() else (None, "no_hint: binStep absent")
    if f == "algebra_integral":
        d = onchain.get(("algebra_deployer", p), "")
        return (word(d), "") if d.startswith("0x") else (None, "no_hint: pool is not customPoolByPair of the G7DeployAvax deployers")
    if f in ("inf_cl", "inf_bin"):
        return word(p), ""
    return None, "no_hint: family without a known hint"


def decode_add_factory(data):
    """addFactory(address,uint8,uint8,bytes32,uint24[],int24[]) calldata -> cast args string."""
    d = data[2:] if data.startswith("0x") else data
    assert d[:8] == ADD_FACTORY_SEL, "not addFactory"
    d = d[8:]
    w = lambda i: int(d[64 * i:64 * i + 64], 16)

    def arr(off, signed):
        i = off // 32
        n = w(i)
        out = []
        for k in range(n):
            v = w(i + 1 + k)
            out.append(v - (1 << 256) if signed and v >= 1 << 255 else v)
        return "[" + ",".join(str(x) for x in out) + "]"
    fac = "0x" + d[24:64]
    return "%s %d %d 0x%s %s %s" % (fac, w(1), w(2), d[192:256], arr(w(4), False), arr(w(5), True))


def site_pairs(universe, chain):
    """[(kind, (symA, addrA), (symB, addrB))] of the site's list for `chain`, deduped by address pair:
    every token vs WETH (tokens[0]), every token vs the stable, then the pairs among the majors."""
    toks = [(t["symbol"], t["address"].lower()) for t in universe["chains"][chain]["tokens"]]
    weth = toks[0]
    stable = next(t for t in toks if t[0] == universe["stable"][chain])
    featured = {t["address"].lower() for t in universe["chains"][chain]["tokens"] if t.get("featured")}
    majors = [t for t in toks if t[1] in featured or t[0] in SITE_MAJORS]
    out, seen = [], set()

    def add(kind, x, y):
        key = tuple(sorted((x[1], y[1])))
        if x[1] == y[1] or key in seen:
            return
        seen.add(key)
        out.append((kind, x, y))
    for t in toks:
        add("site_weth", t, weth)
    for t in toks:
        add("site_stable", t, stable)
    for i, x in enumerate(majors):
        for y in majors[i + 1:]:
            add("site_major", x, y)
    return out


def build(g7dir, onchain_rows, outdir, universe=None, swaps=SWAPS_PER_CHAIN):
    inv = read_tsv(os.path.join(g7dir, "inventory.tsv"))
    toks = read_tsv(os.path.join(g7dir, "tokens.tsv"))
    onchain = {(o["key"], o["subject"].lower()): o["value"] for o in onchain_rows}
    pre = os.path.join(outdir, "prereg")
    os.makedirs(pre, exist_ok=True)
    spec = {"state_fork": STATE_FORK, "window": WINDOW, "ages": AGES, "mf_ages": MF_AGES, "deadline_s": 600,
            "retries": {"attempts": 3, "backoff_s": 2, "timeout_s": 90}, "swaps_per_chain": swaps,
            "criteria": __doc__.split("Criteria:")[1].split("A chain or")[0].strip(), "chains": {}}
    adapters, wrappers, notcov, strata_rows = [], [], [], []
    for chain in CHAINS:
        rows = [r for r in inv if r["chain"] == chain]
        live_pass = any(o["chain"] == chain and o["key"] == "alive_b0" for o in onchain_rows)
        by_pair = {}
        for r in rows:
            by_pair.setdefault(pair(r), []).append(r)
        label, mh = LABELS.get(chain, (MAIN_LABEL, 2))
        wraps = [t["token"].lower() for t in toks if t["chain"] == chain and t["symbol"] in ("WETH", "WAVAX", "WBNB")
                 and not t["source"].startswith(("pool-token", "derived", "native-currency"))]
        bt = onchain.get(("block_time", chain))
        if len(wraps) != 1 or not bt:
            notcov.append((chain, "*", "not covered: native_wrap with a source in the repo=%d, block_time=%s" % (len(wraps), bt or "absent")))
            continue
        strata = []
        # gates
        gate_rows = [r for r in rows if r["family"] in GATE_FAMS and "gate_top3" in classes(r)]
        if not gate_rows:
            notcov.append((chain, "gates", "not covered: no gate-family row in the inventory (absent, not zero)"))
        fams_used, slots = set(), {}
        for r in sorted(gate_rows, key=lambda r: (r["family"], -(liq(r) or 0), -(num(r.get("bal0")) or 0))):
            fn = gate_num(chain, r)
            if fn is None:
                notcov.append((chain, r["family"], "not covered: no adapter number (%s)" % r["pool"]))
                continue
            if chain not in PHASE_A_FAMS and (chain, fn) not in ADAPTERS:
                notcov.append((chain, r["family"], "not covered: no ctor source in the repo"))
                continue
            hint, why = gate_hint(r, onchain)
            if hint is None:
                notcov.append((chain, r["family"], "%s (%s)" % (why, r["pool"])))
                continue
            slots[fn] = slots.get(fn, 0) + 1
            vkey = (fn << 16) | slots[fn]
            fams_used.add(fn)
            ta, tb = r["token0"].lower(), r["token1"].lower()
            wrappers.append((chain, fn, vkey, ta, tb, hint, r["pool"].lower(), r["family"], r.get("liq_usd", ""),
                             liq_method(r), "gate_top3 rank %d in %s" % (slots[fn], r["family"])))
            same = [x for x in by_pair.get(pair(r), []) if x["family"] not in GATE_FAMS]
            strata.append({"id": "gate-%d-%d" % (fn, slots[fn]), "kind": "gates", "tA": ta, "tB": tb,
                           "amounts": {"A": amounts(depth_of([r], ta)), "B": amounts(depth_of([r], tb))},
                           "seed_pools": seed_pools(same), "mid_pool": mid_pool(same),
                           "gate_pool": r["pool"].lower(), "venue_key": vkey, "gate_family": r["family"],
                           "_liq": r.get("liq_usd", ""), "_pool": r["pool"].lower()})
        for fn in sorted(fams_used):
            if (chain, fn) in ADAPTERS:
                c, a, src = ADAPTERS[(chain, fn)]
                adapters.append((chain, fn, c, a, src))
        if chain == "base" and not any(r["family"] == "curve_crypto_ng" for r in rows):
            notcov.append((chain, "curve_crypto_ng", "not covered: no pool in the inventory (absent, not zero)"))
        # pair strata: the site's universe for the chains it lists, the classes otherwise
        used = set()
        if universe and chain in universe["chains"]:
            for kind, (sa, ta), (sb, tb) in site_pairs(universe, chain):
                prs = by_pair.get(tuple(sorted((ta, tb))), [])
                if not prs:
                    notcov.append((chain, "site", "site pair without a pool in the inventory (absent, not zero): %s/%s" % (sa, sb)))
                    continue
                a, b = amounts(depth_of(prs, ta)), amounts(depth_of(prs, tb))
                if not a or not b:
                    notcov.append((chain, "site", "site pair without a measured balance (absent, not zero): %s/%s" % (sa, sb)))
                    continue
                deepest = max(prs, key=lambda r: liq(r) or 0)
                strata.append({"id": "site-%s-%s" % (sa, sb), "kind": kind, "tA": ta, "tB": tb, "amounts": {"A": a, "B": b},
                               "seed_pools": seed_pools([x for x in prs if x["family"] not in GATE_FAMS]),
                               "mid_pool": mid_pool(prs), "_liq": deepest.get("liq_usd", ""), "_pool": deepest["pool"].lower()})
        for cls, k in ([] if universe and chain in universe["chains"] else CLASS_QUOTA):
            cand = [r for r in rows if cls in classes(r) and liq(r) and liq(r) > 0]
            cand.sort(key=(lambda r: liq(r)) if cls == "shallow" else (lambda r: -liq(r)))
            fams, i = set(), 0
            for r in cand:
                if i == k:
                    break
                pk = pair(r)
                if pk in used or (cls == "family_rep" and r["family"] in fams):
                    continue
                alive = onchain.get(("alive_b0", r["pool"].lower()))
                if live_pass and alive != "1":
                    notcov.append((chain, cls, ("pool not alive at b0 (created after the window start): %s" if alive == "0" else
                                                "liveness at b0 not measured (absent, not zero): %s") % r["pool"].lower()))
                    continue
                prs = by_pair[pk]
                ta, tb = r["token0"].lower(), r["token1"].lower()
                a, b = amounts(depth_of(prs, ta)), amounts(depth_of(prs, tb))
                if not a or not b:
                    notcov.append((chain, cls, "pair without a measured balance (%s)" % r["pool"]))
                    continue
                used.add(pk)
                fams.add(r["family"])
                i += 1
                strata.append({"id": "%s-%d" % (cls, i), "kind": cls, "tA": ta, "tB": tb, "amounts": {"A": a, "B": b},
                               "seed_pools": seed_pools([x for x in prs if x["family"] not in GATE_FAMS]),
                               "mid_pool": mid_pool(prs), "_liq": r.get("liq_usd", ""), "_pool": r["pool"].lower()})
        n, rem = divmod(swaps, len(strata)) if strata else (0, 0)
        for j, st in enumerate(strata):
            st["n"] = n + (1 if j < rem else 0)
            strata_rows.append((chain, st["id"], st["kind"], st["tA"], st["tB"], st["n"], st.pop("_pool"), st.pop("_liq"),
                                len(st["seed_pools"]), (st["mid_pool"] or {}).get("pool", "")))
            if st["mid_pool"] is None:
                del st["mid_pool"]
        spec["chains"][chain] = {"label": label, "max_hops": mh, "native_wrap": wraps[0],
                                 "block_time_hint": float(bt), "strata": strata}
    wiring = [(o["subject"], ADD_FACTORY_SIG, o["value"]) for o in onchain_rows if o["key"] == "wiring"]
    wp = os.path.join(pre, "wiring.tsv")  # the hand-added rows (addBridge) survive a rebuild
    kept = [tuple(ln.split("\t")) for ln in open(wp).read().split("\n") if ln] if os.path.exists(wp) else []
    wiring += [k for k in kept if len(k) == 3 and k[1] != ADD_FACTORY_SIG]
    _w(os.path.join(pre, "gate_adapters.tsv"), None, adapters)
    _w(os.path.join(pre, "gate_wrappers.tsv"), None, wrappers)
    _w(os.path.join(pre, "wiring.tsv"), None, wiring)
    _w(os.path.join(pre, "not_covered.tsv"), "chain\tscope\treason", notcov)
    _w(os.path.join(pre, "strata.tsv"), "chain\tid\tkind\ttA\ttB\tn\tpool_ranked\tliq_usd\tseed_pools\tmid_pool", strata_rows)
    _w(os.path.join(pre, "gate_wrappers.cols"), None, [("chain\tfamily_num\tvenue_key\ttA\ttB\thint\tpool\tfamily\tliq_usd\tliq_method\tcriterion",)])
    _w(os.path.join(pre, "onchain.tsv"), "chain\tkey\tsubject\tvalue\tsource",
       [(o["chain"], o["key"], o["subject"], o["value"], o["source"]) for o in onchain_rows])
    with open(os.path.join(outdir, "spec.json"), "w") as f:
        json.dump(spec, f, indent=1, sort_keys=True)
    return spec, adapters, wrappers, notcov


def _w(path, header, rows):
    # deploy_state.sh reads gate_adapters / gate_wrappers / wiring without a header line.
    with open(path, "w") as f:
        if header:
            f.write(header + "\n")
        for r in rows:
            f.write("\t".join(str(x) for x in r) + "\n")


def fetch(g7dir, out):
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    from g7 import Rpc
    inv = read_tsv(os.path.join(g7dir, "inventory.tsv"))
    ven = read_tsv(os.path.join(g7dir, "venues.tsv"))
    rows = []
    for chain in CHAINS:
        rpc = Rpc(chain)
        latest = int(rpc.call("eth_blockNumber", []), 16)
        f0 = STATE_FORK[chain]
        bt = (rpc.ts(latest) - rpc.ts(f0)) / (latest - f0)
        rows.append({"chain": chain, "key": "block_time", "subject": chain, "value": "%.4f" % bt,
                     "source": "(ts(%d)-ts(%d))/(%d-%d)" % (latest, f0, latest, f0)})
        b0 = rpc.first_at_or_after(WINDOW["t0"], f0, latest)
        for r in inv:
            if r["chain"] == chain and classes(r) - {"gate_top3"} and liq(r) and liq(r) > 0:
                v, src = alive_at(rpc, r, b0)
                rows.append({"chain": chain, "key": "alive_b0", "subject": r["pool"].lower(), "value": v, "source": src})
        for r in inv:
            if r["chain"] != chain or "gate_top3" not in classes(r):
                continue
            p = r["pool"].lower()
            if r["family"] == "balancer_v2":
                v = rpc.call("eth_call", [{"to": p, "data": "0x38fff2d0"}, hex(f0)])
                rows.append({"chain": chain, "key": "balv2_poolid", "subject": p, "value": v, "source": "getPoolId()@%d" % f0})
            if r["family"] == "algebra_integral":
                hit = "none"
                for d in ALGEBRA_DEPLOYERS:
                    data = "0x" + SEL_CUSTOM + word(d)[2:] + word(r["token0"])[2:] + word(r["token1"])[2:]
                    v = rpc.call("eth_call", [{"to": ALGEBRA_FACTORY, "data": data}, hex(f0)])
                    if "0x" + v[-40:].lower() == p:
                        hit = d
                rows.append({"chain": chain, "key": "algebra_deployer", "subject": p, "value": hit,
                             "source": "customPoolByPair(d,t0,t1)@%d d in G7DeployAvax:42-43" % f0})
        if chain == "ethereum":
            for v in ven:
                s = v["source"]
                if v["chain"] != chain or "Factory_@" not in s:
                    continue
                reg, blk = s.split()[0].split(":")[1], int(s.split("Factory_@")[1].split()[0])
                logs = rpc.call("eth_getLogs", [{"address": reg, "fromBlock": hex(blk), "toBlock": hex(blk),
                                                 "topics": [FACTORY_TOPIC, word(v["factory_or_manager"])]}])
                assert len(logs) == 1, (v["factory_or_manager"], len(logs))
                tx = rpc.call("eth_getTransactionByHash", [logs[0]["transactionHash"]])
                rows.append({"chain": chain, "key": "wiring", "subject": chain, "value": decode_add_factory(tx["input"]),
                             "source": "%s@%d" % (logs[0]["transactionHash"], blk)})
    with open(out, "w") as f:
        f.write("chain\tkey\tsubject\tvalue\tsource\n")
        for r in rows:
            f.write("\t".join(r[c] for c in ("chain", "key", "subject", "value", "source")) + "\n")


def read_onchain(path):
    return read_tsv(path)


if __name__ == "__main__":
    a = sys.argv[1:]
    if a[:1] == ["fetch"] and len(a) == 3:
        fetch(a[1], a[2])
    elif a[:1] == ["build"] and len(a) >= 4:
        uni = json.load(open(a[a.index("--universe") + 1])) if "--universe" in a else None
        swaps = int(a[a.index("--swaps") + 1]) if "--swaps" in a else SWAPS_PER_CHAIN
        s, ad, wr, nc = build(a[1], read_onchain(a[2]), a[3], uni, swaps)
        print("chains=%d strata=%d adapters=%d wrappers=%d not_covered=%d" % (
            len(s["chains"]), sum(len(c["strata"]) for c in s["chains"].values()), len(ad), len(wr), len(nc)))
    else:
        sys.exit(__doc__)
