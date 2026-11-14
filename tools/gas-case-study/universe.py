#!/usr/bin/env python3
"""Gas case study 1114: the pool universe of one chain, measured on-chain at one fixed block.

  python3 -I tools/gas-case-study/universe.py <chain> <out.tsv> [--block N]

Candidates are never picked by hand. Tokens: A = the chain's bridge tokens and the tokens the
brief names; E = the site token list (eth/base/op/arb/rh) or the G7 inventory midtail and roles
(avax/bsc, rh for its named tokens), each with its repo source. Pairs: {a, b}, a in A, b in A u E.
Pools: every factory lookup of every wired venue for every pair (getPair, getPool per fee or tick
spacing, poolByPair; V4 pool ids derived with hooks = 0; Curve stableswap-ng find_pool_for_coins;
Balancer V2 pools from the Vault's TokensRegistered logs). Value: TVL = sum of balanceOf(pool) x
price over the priced tokens (tvl_method "balances"); V4 has no per-pool balance (singleton), so
its value is the in-range virtual liquidity in USD (tvl_method "v4-inrange-virtual (not TVL)") and
it is ranked apart. Price: the chain's stable = 1 USD (stated assumption); every other token takes
the mid of the measured pool that joins it to a priced token with the deepest priced side.
Selection: up to 10 pools; one guaranteed slot to the best pool of each required family, the rest
by TVL among the routable pools. A failed call is absent, never zero (an absent value stays empty).
The RPC key is read from $DRPC_KEY_FILE (default ~/.drpc-key) and is never printed or written.
"""
import concurrent.futures as cf
import json
import os
import sys
import time
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
G7 = os.path.join(HERE, "..", "g7-gas-campaign")
ZERO = "0x" + "0" * 40
COLS = "chain block venue kind pool token0 token1 fee_or_param tvl_usd tvl_method adapter selected reason".split()
TOP = 10
BLOCK_TIME = dict(base=0.2, ethereum=12.04, optimism=2.0, arbitrum=0.303, robinhood=0.104, avalanche=1.0, bsc=0.45)
MARGIN_S = 120  # the fixed block is the head minus ~2 minutes, so every provider has it

# ------------------------------------------------------------------ keccak-256 (no dependency)
_RC = [0x1, 0x8082, 0x800000000000808A, 0x8000000080008000, 0x808B, 0x80000001, 0x8000000080008081,
       0x8000000000008009, 0x8A, 0x88, 0x80008009, 0x8000000A, 0x8000808B, 0x800000000000008B,
       0x8000000000008089, 0x8000000000008003, 0x8000000000008002, 0x8000000000000080, 0x800A,
       0x800000008000000A, 0x8000000080008081, 0x8000000000008080, 0x80000001, 0x8000000080008008]
_ROT = [[0, 36, 3, 41, 18], [1, 44, 10, 45, 2], [62, 6, 43, 15, 61], [28, 55, 25, 21, 56], [27, 20, 39, 8, 14]]
_M = (1 << 64) - 1


def _rol(x, n):
    return ((x << n) | (x >> (64 - n))) & _M if n else x


def keccak(b):
    b = bytearray(b) + b"\x01"
    b += b"\x00" * ((-len(b)) % 136)
    b[-1] |= 0x80
    A = [[0] * 5 for _ in range(5)]
    for off in range(0, len(b), 136):
        for i in range(17):
            A[i % 5][i // 5] ^= int.from_bytes(b[off + 8 * i:off + 8 * i + 8], "little")
        for rc in _RC:
            C = [A[x][0] ^ A[x][1] ^ A[x][2] ^ A[x][3] ^ A[x][4] for x in range(5)]
            D = [C[(x - 1) % 5] ^ _rol(C[(x + 1) % 5], 1) for x in range(5)]
            B = [[0] * 5 for _ in range(5)]
            for x in range(5):
                for y in range(5):
                    B[y][(2 * x + 3 * y) % 5] = _rol(A[x][y] ^ D[x], _ROT[x][y])
            A = [[B[x][y] ^ ((~B[(x + 1) % 5][y]) & B[(x + 2) % 5][y]) for y in range(5)] for x in range(5)]
            A[0][0] ^= rc
    return b"".join(A[i % 5][i // 5].to_bytes(8, "little") for i in range(4))


def sel(sig):
    return keccak(sig.encode())[:4].hex()


def w(x):  # one ABI word
    if isinstance(x, str):
        return x.lower().replace("0x", "").rjust(64, "0")
    return (x % (1 << 256)).to_bytes(32, "big").hex()


def words(h):
    h = (h or "").replace("0x", "")
    return [int(h[i:i + 64], 16) for i in range(0, len(h) - 63, 64)]


def a20(n):
    return "0x" + format(n % (1 << 160), "040x")


# ------------------------------------------------------------------ RPC
class RPC:
    def __init__(self, chain):
        url = os.environ.get("RPC_URL_" + chain.upper())
        if not url:
            key = open(os.path.expanduser(os.environ.get("DRPC_KEY_FILE", "~/.drpc-key"))).read().strip()
            url = f"https://lb.drpc.live/{chain}/{key}"
        self.url, self.calls = url, 0

    def _post(self, body):
        for t in range(4):
            try:
                req = urllib.request.Request(self.url, json.dumps(body).encode(), {"Content-Type": "application/json"})
                with urllib.request.urlopen(req, timeout=60) as r:
                    return json.loads(r.read())
            except Exception as e:  # noqa: BLE001 - the message may carry the URL: never print it
                err = type(e).__name__
                time.sleep(1.5 * (t + 1))
        raise RuntimeError("rpc failed: " + err)

    def one(self, method, params):
        self.calls += 1
        r = self._post({"jsonrpc": "2.0", "id": 1, "method": method, "params": params})
        if "error" in r:
            raise RuntimeError(str(r["error"].get("message", ""))[:120])
        return r["result"]

    def calls_at(self, block, reqs, chunk=40):
        """reqs: [(to, data)]; returns hex results, None where the call failed (absent)."""
        tag, out = hex(block), [None] * len(reqs)

        def run(i0):
            body = [{"jsonrpc": "2.0", "id": i0 + j, "method": "eth_call",
                     "params": [{"to": t, "data": "0x" + d}, tag]} for j, (t, d) in enumerate(reqs[i0:i0 + chunk])]
            res = self._post(body)
            for r in (res if isinstance(res, list) else []):
                v = r.get("result")
                out[r["id"]] = v if v not in (None, "0x") else None
        self.calls += len(reqs)
        with cf.ThreadPoolExecutor(2) as ex:
            list(ex.map(run, range(0, len(reqs), chunk)))
        return out


# ------------------------------------------------------------------ chain config (repo sources only)
def _inv():
    sys.path.insert(0, G7)
    import inventory  # noqa: E402  (the G7 inventory: every address carries its file:line)
    return inventory.CHAINS


def config(chain):
    """Venues [(fam, factory, params, adapter, src)], A, E [(addr, src)], extra (pm, curve, balancer)."""
    inv = _inv().get(chain, {})
    site = json.load(open(os.path.join(G7, "site_tokens.json")))["chains"].get(chain, {}).get("tokens", [])
    V, A, E, X = [], [], [], {}
    kind = dict(v2="V2", v3="V3", cl="V3 (CL mode)", pharaoh="V3 (CL mode)", solidly="SOLIDLY",
                algebra="ALGEBRA", algebra_integral="ALGEBRA")
    if chain == "ethereum":  # wiring.tsv: the addFactory and addBridge rows of the G7 prereg
        for ln in open(os.path.join(G7, "prereg", "wiring.tsv")):
            c, f, args = (ln.rstrip("\n").split("\t") + ["", ""])[:3]
            if c != "ethereum":
                continue
            p = args.split()
            if f.startswith("addFactory"):
                fees = [int(x) for x in p[4].strip("[]").split(",") if x]
                V.append(("v3" if p[1] == "1" else "v2", p[0], fees, "routable: Hub kind " + ("V3" if p[1] == "1" else "V2"),
                          "tools/g7-gas-campaign/prereg/wiring.tsv"))
            elif f.startswith("addBridge"):
                A.append((p[0], "tools/g7-gas-campaign/prereg/wiring.tsv"))
        X["pm"] = ("0x000000000004444c5dc75cB358380D2e3dE08A90", "Uniswap V4 deployments, read 2026-11-12")
        X["curve_ng"] = "0x6A8cbed756804B16E05E741eDaBd5cB544AE21bf"
        X["balancer_v2"] = ("0xBA12222222228d8Ba445958a75a0704d566BF2C8", 12272146)
    else:
        for v in inv.get("venues", []):
            fam = v["fam"]
            prm = v.get("fees") or ([1, 5, 10, 50, 100, 200] if fam == "pharaoh" else
                                    [1, 50, 100, 200, 2000] if fam == "cl" else [])
            ad = "out: no adapter at bb4cdbb" if fam == "lb" else "routable: Hub kind " + kind.get(fam, fam)
            V.append((fam, v["addr"], prm, ad, v["src"]))
        for k in ("native", "num"):
            if inv.get(k):
                A.append(inv[k])
        roles = inv.get("roles", {})
        for k in ("lst", "usdt", "btc"):
            if chain in ("base", "optimism", "arbitrum") and k != "lst":
                continue
            if chain == "avalanche" and k != "btc":
                continue
            for r in roles.get(k, []):
                A.append(r)
        if inv.get("pm"):
            X["pm"] = inv["pm"]
        if chain == "avalanche":
            X["balancer_v2"] = ("0xBA12222222228d8Ba445958a75a0704d566BF2C8", 0)
            # The brief names WETH on avalanche; no repo file holds its address: verified by symbol().
            A.append(("0x49D5c2BdFfac6CE2BFdB6640F4F80f226bc10bAB", "brief (named WETH); symbol() checked"))
        for ln in open(os.path.join(G7, "prereg", "wiring.tsv")):
            c, f, args = (ln.rstrip("\n").split("\t") + ["", ""])[:3]
            if c == chain and f.startswith("addBridge"):
                A.append((args.split()[0], "tools/g7-gas-campaign/prereg/wiring.tsv"))
    if chain in ("ethereum", "base", "optimism", "arbitrum", "robinhood"):
        E += [(t["address"], "tools/g7-gas-campaign/site_tokens.json") for t in site]
    if chain in ("avalanche", "bsc", "robinhood"):
        E += [tuple(m) for m in inv.get("midtail", [])]
        E += [r for k, rs in inv.get("roles", {}).items() for r in rs]
    return V, A, E, X


# ------------------------------------------------------------------ discovery
S = {k: sel(k) for k in ["getPair(address,address)", "getPool(address,address,uint24)",
                         "getPool(address,address,bool)", "getPool(address,address,int24)",
                         "poolByPair(address,address)", "find_pool_for_coins(address,address,uint256)",
                         "balanceOf(address)", "decimals()", "symbol()", "slot0()", "globalState()",
                         "getReserves()", "stable()", "coins(uint256)", "extsload(bytes32)",
                         "getPoolTokens(bytes32)"]}
V4_KEYS = [(100, 1), (500, 10), (3000, 60), (10000, 200)]


def lookups(V, pairs):
    """[(fam, factory, param, a, b, adapter, src, to, data)] for every wired venue x pair x param."""
    out = []
    for fam, fac, prm, ad, src in V:
        for a, b in pairs:
            if fam == "v2":
                out.append((fam, fac, "", a, b, ad, src, fac, S["getPair(address,address)"] + w(a) + w(b)))
            elif fam == "v3" and prm:
                for f in prm:
                    out.append((fam, fac, f, a, b, ad, src, fac, S["getPool(address,address,uint24)"] + w(a) + w(b) + w(f)))
            elif fam in ("cl", "pharaoh", "lb"):
                for t in (prm or [1, 2, 5, 10, 15, 20, 25, 50, 100]):
                    s = S["getPool(address,address,int24)"] if fam != "lb" else sel("getLBPairInformation(address,address,uint256)")
                    out.append((fam, fac, t, a, b, ad, src, fac, s + w(a) + w(b) + w(t)))
            elif fam == "solidly":
                for st in (0, 1):
                    out.append((fam, fac, "stable" if st else "volatile", a, b, ad, src, fac,
                                S["getPool(address,address,bool)"] + w(a) + w(b) + w(st)))
            elif fam in ("algebra", "algebra_integral"):
                out.append((fam, fac, "", a, b, ad, src, fac, S["poolByPair(address,address)"] + w(a) + w(b)))
    return out


def v4_id(c0, c1, fee, ts):
    return keccak(bytes.fromhex(w(c0) + w(c1) + w(fee) + w(ts) + w(ZERO)))


def balancer_v2_pools(rpc, vault, start, block, want):
    """Pools whose TokensRegistered tokens hold >= 2 wanted tokens. Returns ([(poolId, tokens)], note)."""
    topic = "0x" + keccak(b"TokensRegistered(bytes32,address[],address[])").hex()
    span, lo, found, n = 2_000_000, start, [], 0
    while lo <= block:
        hi = min(block, lo + span - 1)
        try:
            logs = rpc.one("eth_getLogs", [{"address": vault, "topics": [topic], "fromBlock": hex(lo), "toBlock": hex(hi)}])
        except RuntimeError:
            if span <= 50_000:
                return found, f"not enumerated: the log range limit stopped the scan at block {lo}"
            span //= 4
            continue
        n += 1
        for lg in logs:
            ws = words(lg["data"])
            k = ws[0] // 32
            toks = [a20(x).lower() for x in ws[k + 1:k + 1 + ws[k]]]
            if sum(t in want for t in toks) >= 2:
                found.append((lg["topics"][1], toks))
        lo = hi + 1
    return found, f"TokensRegistered logs {start}..{block} ({n} queries)"


# ------------------------------------------------------------------ main
def main():
    chain, out = sys.argv[1], sys.argv[2]
    rpc = RPC(chain)
    head = int(rpc.one("eth_blockNumber", []), 16)
    block = int(sys.argv[sys.argv.index("--block") + 1]) if "--block" in sys.argv else head - int(MARGIN_S / BLOCK_TIME[chain])
    ts = int(rpc.one("eth_getBlockByNumber", [hex(block), False])["timestamp"], 16)
    V, A, E, X = config(chain)
    toks = {}
    for t, src in A + E:
        toks.setdefault(t.lower(), src)
    tl = list(toks)
    meta = rpc.calls_at(block, [(t, S["decimals()"]) for t in tl] + [(t, S["symbol()"]) for t in tl])
    dec, sym = {}, {}
    for i, t in enumerate(tl):
        if meta[i]:
            dec[t] = words(meta[i])[0]
        h = (meta[len(tl) + i] or "").replace("0x", "")
        try:
            sym[t] = bytes.fromhex(h[128:128 + 2 * int(h[64:128], 16)]).decode() if len(h) > 128 else bytes.fromhex(h).rstrip(b"\0").decode()
        except Exception:  # noqa: BLE001
            sym[t] = ""
    Aset = {t.lower() for t, _ in A if t.lower() in dec}
    if chain == "robinhood":  # the brief names VIRTUAL: resolved by symbol among the repo candidates
        Aset |= {t for t in tl if sym.get(t) == "VIRTUAL"}
    tl = [t for t in tl if t in dec]
    pairs = sorted({tuple(sorted((a, b))) for a in Aset for b in tl if a != b})
    L = lookups(V, pairs)
    res = rpc.calls_at(block, [(x[7], x[8]) for x in L])
    pools = {}  # pool -> dict
    for x, r in zip(L, res):
        if not r:
            continue
        p = a20(words(r)[0] if x[0] != "lb" else (words(r)[1] if len(words(r)) > 1 else 0))
        if p == ZERO:
            continue
        pools.setdefault(p.lower(), dict(fam=x[0], venue=x[1], param=x[2], t=[x[3], x[4]], adapter=x[5], src=x[6]))
    # V4: derived ids, hooks = 0; native-currency variants are kind 8 (not routable)
    if X.get("pm"):
        pm = X["pm"][0]
        native = (A[0][0].lower() if A else "")
        for a, b in pairs:
            for c0, c1, nat in [(a, b, False)] + ([(ZERO, b if a == native else a, True)] if native in (a, b) else []):
                c0, c1 = sorted((c0, c1))
                for fee, sp in V4_KEYS:
                    pid = v4_id(c0, c1, fee, sp)
                    pools["v4:" + pid.hex()] = dict(fam="v4", venue=pm, param=f"{fee}/{sp}", t=[c0, c1], id=pid,
                                                   adapter=("out: V4 native-currency pool, kind 8 is executable only "
                                                            "(Hub.sol:27-28)" if nat else "routable: Hub kind V4 (MODE_V4_DERIVE)"),
                                                   src=X["pm"][1])
    # Curve stableswap-ng (ethereum)
    if X.get("curve_ng"):
        f = X["curve_ng"]
        q = [(a, b, i) for a, b in pairs for i in range(3)]
        rr = rpc.calls_at(block, [(f, S["find_pool_for_coins(address,address,uint256)"] + w(a) + w(b) + w(i)) for a, b, i in q])
        for (a, b, i), r in zip(q, rr):
            if r and words(r)[0]:
                pools.setdefault(a20(words(r)[0]).lower(), dict(fam="curve-ng", venue=f, param="", t=[a, b],
                                                              adapter="AdapterCurveNG (Gate, EXTERNAL)", src="venues-infra"))
    notes = []
    if X.get("balancer_v2"):
        vault, start = X["balancer_v2"]
        bal, note = balancer_v2_pools(rpc, vault, start, block, set(tl))
        notes.append("balancer_v2: " + note + f", {len(bal)} pools with >= 2 candidate tokens")
        for pid, tk in bal:
            pools.setdefault("bal:" + pid, dict(fam="balancer-v2", venue=vault, param=pid, t=tk, id=pid,
                                                adapter="AdapterBalancerV2: quoted 0 by the view port (AdapterBalancerV2.sol:115-121)",
                                                src="Vault TokensRegistered"))
    # state: balances, mid prices
    keys = list(pools)
    reqs, idx = [], []
    for k in keys:
        P = pools[k]
        if P["fam"] == "v4":
            sl = keccak(P["id"] + bytes.fromhex(w(6)))
            reqs += [(P["venue"], S["extsload(bytes32)"] + sl.hex()),
                     (P["venue"], S["extsload(bytes32)"] + w(int.from_bytes(sl, "big") + 3))]
            idx.append((k, "v4", 2))
        elif P["fam"] == "balancer-v2":
            reqs.append((P["venue"], S["getPoolTokens(bytes32)"] + w(P["id"])))
            idx.append((k, "bal", 1))
        else:
            if P["fam"] == "curve-ng":
                P["t"] = None
                reqs += [(k, S["coins(uint256)"] + w(i)) for i in range(4)]
                idx.append((k, "coins", 4))
            else:
                reqs += [(t, S["balanceOf(address)"] + w(k)) for t in P["t"]]
                m = S["slot0()"] if P["fam"] in ("v3", "cl", "pharaoh") else S["globalState()"] if "algebra" in P["fam"] else S["getReserves()"]
                reqs.append((k, m))
                idx.append((k, "bal2", 3))
    rr, j = rpc.calls_at(block, reqs), 0
    for k, how, n in idx:
        P, r = pools[k], rr[j:j + n]
        j += n
        if how == "v4":
            sp = words(r[0])[0] % (1 << 160) if r[0] else 0
            P.update(sqrtp=sp or None, liq=(words(r[1])[0] % (1 << 128)) if r[1] else None, bal={})
        elif how == "bal":
            ws = words(r[0]) if r[0] else []
            if ws:
                o1, o2 = ws[0] // 32, ws[1] // 32
                P["bal"] = {a20(ws[o1 + 1 + i]).lower(): ws[o2 + 1 + i] for i in range(ws[o1])}
        elif how == "coins":
            P["t"] = [a20(words(x)[0]).lower() for x in r if x]
        else:
            P["bal"] = {t: (words(b)[0] if b else None) for t, b in zip(P["t"], r[:2])}
            P["mid"] = words(r[2])[:2] if r[2] else None
    cn = [k for k in keys if pools[k]["fam"] == "curve-ng" and pools[k]["t"]]
    rr = rpc.calls_at(block, [(t, S["balanceOf(address)"] + w(k)) for k in cn for t in pools[k]["t"]])
    j = 0
    for k in cn:
        P = pools[k]
        P["bal"] = {t: (words(rr[j + i])[0] if rr[j + i] else None) for i, t in enumerate(P["t"])}
        j += len(P["t"])
    # prices: stable = 1 USD; then the deepest priced side, 4 rounds
    stable = {t for t in tl if sym.get(t) in ("USDC", "USDG", "USDT")}
    num = [t for t in tl if t == (A[1][0].lower() if len(A) > 1 else "")]
    px = {t: 1.0 for t in (num or stable)}
    psrc = {t: "stable = 1 USD (assumed)" for t in px}
    for _ in range(4):
        best = {}
        for k in keys:
            P = pools[k]
            if P["fam"] not in ("v2", "v3", "cl", "pharaoh", "algebra", "algebra_integral", "solidly", "v4") or P["param"] == "stable":
                continue
            t0, t1 = sorted(P["t"])
            if P["fam"] == "v4":
                sp = P.get("sqrtp")
                ratio = (sp / 2 ** 96) ** 2 if sp else None
                dep = {t0: (P.get("liq") or 0) * 2 ** 96 / sp if sp else 0, t1: (P.get("liq") or 0) * sp / 2 ** 96 if sp else 0}
            else:
                m, b = P.get("mid"), P.get("bal", {})
                if not m:
                    continue
                ratio = (m[0] % (1 << 160) / 2 ** 96) ** 2 if P["fam"] not in ("v2", "solidly") else (m[1] / m[0] if m[0] else None)
                dep = {t: b.get(t) or 0 for t in (t0, t1)}
            if not ratio or t0 not in dec or t1 not in dec:
                continue
            r01 = ratio * 10 ** (dec[t0] - dec[t1])  # token1 per token0, human units
            for have, need, conv in ((t0, t1, lambda p: p / r01), (t1, t0, lambda p: p * r01)):
                if have in px and need not in px:
                    d = dep[have] / 10 ** dec[have] * px[have]
                    if d > best.get(need, (0,))[0]:
                        best[need] = (d, conv(px[have]), f"mid of {P['fam']} {k[:42]} vs {sym.get(have, have)}")
        for t, (d, p, s) in best.items():
            px[t], psrc[t] = p, s
    rows = []
    for k in keys:
        P = pools[k]
        if P["fam"] == "v4":
            if not P.get("liq") or not P.get("sqrtp"):
                continue
            t0, t1 = P["t"]
            pu = {t: px.get(t if t != ZERO else (A[0][0].lower())) for t in (t0, t1)}
            x, y = P["liq"] * 2 ** 96 / P["sqrtp"], P["liq"] * P["sqrtp"] / 2 ** 96
            d0, d1 = dec.get(t0, 18) if t0 != ZERO else 18, dec.get(t1, 18)
            v = (x / 10 ** d0 * pu[t0] + y / 10 ** d1 * pu[t1]) if None not in pu.values() else None
            meth = "v4-inrange-virtual (not TVL)"
            tk, pool = (t0, t1), "0x" + P["id"].hex()
        else:
            b = P.get("bal") or {}
            if not b:
                continue
            parts = [b[t] / 10 ** dec[t] * px[t] for t in b if b[t] is not None and t in px and t in dec]
            unpriced = [t for t in b if t not in px]
            v = sum(parts) if parts else None
            meth = "balances" + (f" (priced tokens only, {len(unpriced)} unpriced)" if unpriced else "")
            tk = [t for t in P["t"] if t in dec][:2] if P["fam"] != "curve-ng" else [t for t in P["t"] if t in dec][:2]
            pool = k if not k.startswith("bal:") else P["id"][:42]
        if len(tk) < 2:
            continue
        rows.append(dict(chain=chain, block=block, venue=P["venue"].lower(), kind=P["fam"], pool=pool.lower(),
                         token0=tk[0], token1=tk[1], fee_or_param=str(P["param"]),
                         tvl_usd=("%.2f" % v) if v is not None else "", tvl_method=meth, adapter=P["adapter"],
                         selected="no", reason=""))
    select(chain, rows)
    with open(out, "w") as f:
        f.write("\t".join(COLS) + "\n")
        for r in rows:
            f.write("\t".join(str(r[c]).replace("\t", " ") for c in COLS) + "\n")
    with open(out + ".tokens", "w") as f:
        f.write("chain\tblock\ttoken\tsymbol\tdecimals\tprice_usd\tprice_src\tsource\trole\n")
        for t in tl:
            f.write(f"{chain}\t{block}\t{t}\t{sym.get(t, '')}\t{dec[t]}\t{px.get(t, '')}\t{psrc.get(t, 'absent: no priced pool')}"
                    f"\t{toks[t]}\t{'A' if t in Aset else 'E'}\n")
    print(json.dumps(dict(chain=chain, block=block, ts=ts, head=head, tokens=len(tl), A=len(Aset), pairs=len(pairs),
                          lookups=len(L), pools=len(keys), rows=len(rows), selected=sum(r["selected"] == "yes" for r in rows),
                          rpc_calls=rpc.calls, notes=notes)))


def select(chain, rows):
    """Up to TOP pools: one guaranteed slot per required family (best of its own metric), then TVL."""
    def val(r):
        return float(r["tvl_usd"]) if r["tvl_usd"] else -1.0
    route = [r for r in rows if not r["adapter"].startswith("out:") and val(r) > 0]
    fams = {"v2": "V2", "v3": "V3", "cl": "V3", "pharaoh": "V3", "v4": "V4", "solidly": "SOLIDLY",
            "algebra": "ALGEBRA", "algebra_integral": "ALGEBRA", "curve-ng": "Curve", "balancer-v2": "Balancer"}
    need = sorted({fams[r["kind"]] for r in route if r["kind"] not in ("curve-ng", "balancer-v2")})
    if chain == "ethereum":
        need += ["Curve", "Balancer"]
    chosen = []
    for fam in need:
        c = sorted((r for r in route if fams[r["kind"]] == fam and r not in chosen), key=val, reverse=True)
        if c:
            c[0]["reason"] = f"guaranteed slot: best {fam} by {c[0]['tvl_method'].split(' (')[0]}"
            chosen.append(c[0])
    by_tvl = sorted((r for r in route if r["tvl_method"].startswith("balances") and r not in chosen
                     and (chain in ("ethereum", "avalanche") or fams[r["kind"]] not in ("Curve", "Balancer"))), key=val, reverse=True)
    seen = {r["pool"] for r in chosen}
    for r in by_tvl:
        if len(seen) >= TOP:
            break
        if r["pool"] not in seen:
            r["reason"] = f"TVL rank {len(seen) + 1}"
            seen.add(r["pool"])
            chosen.append(r)
    for r in chosen:
        r["selected"] = "yes"
    tenth = min((val(r) for r in chosen if r["tvl_method"].startswith("balances")), default=0.0)
    for r in rows:
        if r["selected"] == "no":
            r["reason"] = (r["adapter"] if r["adapter"].startswith("out:") else
                           "absent value" if val(r) < 0 else f"below the selection (10th selected TVL {tenth:.2f})")
    return tenth


if __name__ == "__main__":
    if sys.argv[1:2] == ["selftest"]:
        assert keccak(b"").hex() == "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470"
        assert sel("getPair(address,address)") == "e6a43905" and sel("balanceOf(address)") == "70a08231"
        print("ok", {k: v for k, v in S.items()})
        sys.exit(0)
    main()
