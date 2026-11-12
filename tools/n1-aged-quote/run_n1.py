#!/usr/bin/env python3
"""N1: failure rate of an aged quote (quote at block b, executed Δ seconds later).

V2 is not deployed on any chain. Every call below is an eth_call at a REAL historical block of
the chain, with the V2 contracts (code + storage built by deploy_state.sh on an anvil fork)
injected by stateOverride. The swap runs from N1Probe, which measures delivery as the
balanceOf delta of tokenOut (the oracle is the token, not the Router's return value).

Pre-registered design: tools/n1-aged-quote/spec.json (committed before the seed existed).

  run_n1.py measure <spec.json> <statedir> <out.tsv> <seedhex> [-j 2]
  run_n1.py report  <spec.json> <out.tsv>

The RPC key is read from $DRPC_KEY_FILE (default ~/.drpc-key) and never printed or written.
"""
import concurrent.futures as cf
import hashlib
import json
import math
import os
import random
import subprocess
import sys
import threading
import time

import requests

SEL_PREVIEW = "30439d8c"  # previewAndEncode(address,address,uint256,address,uint256)
SEL_RUN = "3f1dde7a"      # run(address,address,address,uint256,bool,bytes)
SEL_BAL = "70a08231"      # balanceOf(address)
SEL_ROUTERE = "62b0a386"  # RouterE(uint16)
GAS = hex(30_000_000)
CALLER = "0x000000000000000000000000000000000000dEaD"
COLS = ["stratum", "idx", "b", "ts_b", "dir", "amount_in", "quote", "eff_min_out", "net_out",
        "delta", "e", "ts_e", "outcome", "detail", "delivered", "gas_used"]


class RpcError(Exception):
    pass


class Reverted(Exception):
    def __init__(self, data):
        super().__init__(data)
        self.data = data or "0x"


class Rpc:
    """JSON-RPC with the pre-registered retry policy: 3 attempts, backoff 2 s then 4 s."""

    def __init__(self, chain):
        key = open(os.path.expanduser(os.environ.get("DRPC_KEY_FILE", "~/.drpc-key"))).read().strip()
        self._url = f"https://lb.drpc.live/{chain}/{key}"
        self._s = requests.Session()
        self._hdr = {}
        self._lock = threading.Lock()

    def call(self, method, params):
        last = None
        for attempt in range(3):
            try:
                r = self._s.post(self._url, json={"jsonrpc": "2.0", "id": 1, "method": method, "params": params},
                                 timeout=90)
                j = r.json()
            except Exception as ex:  # network, HTTP body not JSON, timeout
                last = type(ex).__name__
            else:
                if "error" not in j:
                    return j["result"]
                err = j["error"]
                msg = str(err.get("message", ""))
                if err.get("code") == 3 or "revert" in msg.lower():
                    raise Reverted(err.get("data"))
                last = f"{err.get('code')}:{msg[:80]}"
            if attempt < 2:
                time.sleep(2 * (2 ** attempt))
        raise RpcError(last)

    def ts(self, n):
        with self._lock:
            if n in self._hdr:
                return self._hdr[n]
        h = self.call("eth_getBlockByNumber", [hex(n), False])
        if h is None:
            raise RpcError(f"no header {n}")
        t = int(h["timestamp"], 16)
        with self._lock:
            self._hdr[n] = t
        return t

    def first_at_or_after(self, t, lo, hi):
        """Smallest n in (lo, hi] with ts(n) >= t; hi is grown until ts(hi) >= t."""
        while self.ts(hi) < t:
            lo, hi = hi, hi + 2 * (hi - lo) + 1
        while hi - lo > 1:
            mid = (lo + hi) // 2
            if self.ts(mid) >= t:
                hi = mid
            else:
                lo = mid
        return hi


def w(x):
    return format(x, "064x")


def addr(a):
    return w(int(a, 16))


def words(hexdata):
    d = hexdata[2:] if hexdata.startswith("0x") else hexdata
    return d


def word(d, i):
    return int(d[64 * i:64 * i + 64], 16)


def dyn_bytes(d, off):
    n = int(d[2 * off:2 * off + 64], 16)
    return d[2 * off + 64:2 * off + 64 + 2 * n]


def decode_preview(res):
    d = words(res)
    pv = 2 * word(d, 0)
    call = dyn_bytes(d, word(d, 1))
    f = lambda i: int(d[pv + 64 * i:pv + 64 * i + 64], 16)
    return {"netOut": f(4), "effectiveMinOut": f(7), "canExecute": f(13) == 1, "call": call}


def encode_run(router, tin, tout, amount, wrap, call_hex):
    n = len(call_hex) // 2
    pad = call_hex + "0" * ((64 - len(call_hex) % 64) % 64)
    return ("0x" + SEL_RUN + addr(router) + addr(tin) + addr(tout) + w(amount) + w(1 if wrap else 0)
            + w(6 * 32) + w(n) + pad)


def decode_run(res):
    d = words(res)
    ok = word(d, 0) == 1
    ret = dyn_bytes(d, word(d, 1))
    return ok, ret, word(d, 2), word(d, 3), word(d, 4)


def cast_index(owner, slot):
    out = subprocess.run([os.path.expanduser("~/.foundry/bin/cast"), "index", "address", owner, str(slot)],
                         capture_output=True, text=True, check=True)
    return "0x" + int(out.stdout.strip(), 16).to_bytes(32, "big").hex()


class Chain:
    def __init__(self, name, spec, statedir):
        self.name = name
        self.c = spec["chains"][name]
        st = json.load(open(os.path.join(statedir, f"{name}.state.json")))
        names = dict(line.split("\t") for line in open(os.path.join(statedir, f"{name}.addrs.tsv")).read().split("\n") if line)
        self.quoter, self.router, self.probe = names["quoter"], names["router"], names["probe"].lower()
        self.base_override = {}
        for a, acc in st["accounts"].items():
            self.base_override[a] = {"code": acc["code"], "nonce": hex(acc["nonce"]), "state": acc["storage"]}
        self.rpc = Rpc(name)
        self.usdc_slot = None

    def override(self, eth_wei=0, usdc=0):
        o = {k: dict(v) for k, v in self.base_override.items()}
        if eth_wei:
            o[self.probe]["balance"] = hex(eth_wei)
        if usdc:
            o[self.c["usdc"].lower()] = {"stateDiff": {self.usdc_slot: "0x" + w(usdc)}}
        return o

    def find_usdc_slot(self, blk):
        """Balance mapping slot of USDC, found by trying slots and verified by balanceOf."""
        probe_val = 123456789
        for p in range(0, 64):
            s = cast_index(self.probe, p)
            o = {self.c["usdc"].lower(): {"stateDiff": {s: "0x" + w(probe_val)}}}
            r = self.rpc.call("eth_call", [{"to": self.c["usdc"], "data": "0x" + SEL_BAL + addr(self.probe)}, hex(blk), o])
            if int(r, 16) == probe_val:
                self.usdc_slot = s
                return p
        raise RuntimeError(f"{self.name}: USDC balance slot not found")


def stratum_rng(seed, sid):
    return random.Random(int.from_bytes(hashlib.sha256(f"{seed}:{sid}".encode()).digest(), "big"))


def sprt_state(fails, n, p0, p1, alpha, beta):
    llr = fails * math.log(p1 / p0) + (n - fails) * math.log((1 - p1) / (1 - p0))
    if llr >= math.log((1 - beta) / alpha):
        return "H1"
    if llr <= math.log(beta / (1 - alpha)):
        return "H0"
    return "cont"


def window(ch, regime, spec):
    """[b0, b1]: every block whose timestamp is in [t0, t1) of the regime (binary search on headers)."""
    t0, t1 = spec["regimes"][regime]
    head = int(ch.rpc.call("eth_blockNumber", []), 16)
    b0 = ch.rpc.first_at_or_after(t0, 0, head)
    b1 = ch.rpc.first_at_or_after(t1, b0 - 1, head) - 1
    return b0, b1


def measure_stratum(ch, sid, size, regime, spec, seed, out, outlock, done):
    p = spec["sprt"]
    deltas = spec["deltas"]
    b0, b1 = window(ch, regime, spec)
    rng = stratum_rng(seed, sid)
    fails = {d: 0 for d in deltas}
    n = 0
    idx = 0
    while n < p["n_max"]:
        b = rng.randint(b0, b1)
        weth_in = rng.random() < 0.5
        idx += 1
        if (sid, idx) in done:  # resume: replay the counters from the rows already measured
            rows = done[(sid, idx)]
            if rows[0]["quote"] == "ok" or rows[0]["quote"] == "rpc_err":
                n += 1
                for r in rows:
                    fails[int(r["delta"])] += r["outcome"] != "ok"
        else:
            rows = measure_one(ch, sid, idx, b, weth_in, size, spec)
            with outlock:
                for r in rows:
                    out.write("\t".join(str(r[k]) for k in COLS) + "\n")
                out.flush()
            if rows[0]["quote"] in ("ok", "rpc_err"):
                n += 1
                for r in rows:
                    fails[r["delta"]] += r["outcome"] != "ok"
        states = [sprt_state(fails[d], n, p["p0"], p["p1"], p["alpha"], p["beta"]) for d in deltas]
        if n and all(s != "cont" for s in states):
            break
    return sid, n, fails


def measure_one(ch, sid, idx, b, weth_in, size, spec):
    c = ch.c
    tin, tout = (c["weth"], c["usdc"]) if weth_in else (c["usdc"], c["weth"])
    amount = spec["sizes"][size]["weth" if weth_in else "usdc"]
    base = {"stratum": sid, "idx": idx, "b": b, "dir": "WETH>USDC" if weth_in else "USDC>WETH", "amount_in": amount,
            "eff_min_out": "", "net_out": "", "e": "", "ts_e": "", "delivered": "", "gas_used": "", "ts_b": ""}
    deltas = spec["deltas"]
    try:
        ts_b = ch.rpc.ts(b)
        base["ts_b"] = ts_b
        q = "0x" + SEL_PREVIEW + addr(tin) + addr(tout) + w(amount) + addr(ch.probe) + w(ts_b + spec["deadline_s"])
        res = ch.rpc.call("eth_call", [{"from": CALLER, "to": ch.quoter, "data": q, "gas": GAS}, hex(b), ch.override()])
        pv = decode_preview(res)
    except Reverted as r:
        return [dict(base, quote="noquote_revert", delta="", outcome="", detail=r.data[:10])]
    except RpcError as r:
        return [dict(base, quote="rpc_err", delta=d, outcome="rpc_err", detail=f"quote:{r}") for d in deltas]
    if not pv["canExecute"] or not pv["call"]:
        return [dict(base, quote="noquote", delta="", outcome="", detail="canExecute=0")]
    base.update(quote="ok", eff_min_out=pv["effectiveMinOut"], net_out=pv["netOut"])
    ov = ch.override(eth_wei=amount + 10**18, usdc=0) if weth_in else ch.override(eth_wei=10**18, usdc=amount)
    data = encode_run(ch.router, tin, tout, amount, weth_in, pv["call"])
    rows = []
    for d in deltas:
        r = dict(base, delta=d)
        try:
            e = ch.rpc.first_at_or_after(ts_b + d, b, b + max(2, int(d / c["block_time_hint"]) + 2))
            r.update(e=e, ts_e=ch.rpc.ts(e))
            res = ch.rpc.call("eth_call", [{"from": CALLER, "to": ch.probe, "data": data, "gas": GAS}, hex(e), ov])
            ok, ret, delivered, gas_used, _ = decode_run(res)
            r.update(delivered=delivered, gas_used=gas_used)
            if ok:
                if delivered >= pv["effectiveMinOut"]:
                    r.update(outcome="ok", detail="")
                else:
                    r.update(outcome="below_min", detail=f"short={pv['effectiveMinOut'] - delivered}")
            elif ret[:8] == SEL_ROUTERE and int(ret[8:72] or "0", 16) == 5:
                r.update(outcome="refuse5", detail="RouterE(5)")
            else:
                code = f"RouterE({int(ret[8:72], 16)})" if ret[:8] == SEL_ROUTERE else ("0x" + ret[:8] if ret else "empty")
                r.update(outcome="revert_other", detail=code)
        except Reverted as x:
            r.update(outcome="revert_other", detail="probe:" + x.data[:10])
        except RpcError as x:
            r.update(outcome="rpc_err", detail=str(x))
        rows.append(r)
    return rows


def load_rows(path):
    if not os.path.exists(path):
        return []
    lines = open(path).read().split("\n")
    hdr = lines[0].split("\t")
    return [dict(zip(hdr, line.split("\t"))) for line in lines[1:] if line]


def cmd_measure(spec_path, statedir, out_path, seedhex, jobs):
    spec = json.load(open(spec_path))
    seed = seedhex.lower()
    done = {}
    for r in load_rows(out_path):
        done.setdefault((r["stratum"], int(r["idx"])), []).append(r)
    new = not os.path.exists(out_path)
    out = open(out_path, "a")
    if new:
        out.write("\t".join(COLS) + "\n")
    chains = {name: Chain(name, spec, statedir) for name in spec["chains"]}
    for ch in chains.values():
        b0, _ = window(ch, "recent", spec)
        print(f"{ch.name}: USDC balance slot {ch.find_usdc_slot(b0)}", flush=True)
    outlock = threading.Lock()
    tasks = [(cn, size, reg) for cn in spec["chains"] for size in spec["sizes"] for reg in spec["regimes"]]
    with cf.ThreadPoolExecutor(jobs) as ex:
        futs = [ex.submit(measure_stratum, chains[cn], f"{cn}/{size}/{reg}", size, reg, spec, seed, out, outlock, done)
                for cn, size, reg in tasks]
        for f in cf.as_completed(futs):
            sid, n, fails = f.result()
            print(f"done {sid} n={n} fails={fails}", flush=True)


def binom_cdf(k, n, p):
    return sum(math.comb(n, i) * p ** i * (1 - p) ** (n - i) for i in range(k + 1))


def clopper_pearson(k, n, a=0.05):
    if n == 0:
        return (0.0, 1.0)

    def solve(f, target):
        lo, hi = 0.0, 1.0
        for _ in range(60):
            mid = (lo + hi) / 2
            if f(mid) > target:
                lo = mid
            else:
                hi = mid
        return (lo + hi) / 2
    lower = 0.0 if k == 0 else solve(lambda p: binom_cdf(k - 1, n, p), 1 - a / 2)
    upper = 1.0 if k == n else solve(lambda p: binom_cdf(k, n, p), a / 2)
    return lower, upper


def cmd_report(spec_path, out_path):
    spec = json.load(open(spec_path))
    p = spec["sprt"]
    rows = load_rows(out_path)
    print("stratum\tdelta\tn\tfail\tfail_rate\tcp95_lo\tcp95_hi\tsprt\trefuse5\trevert_other\tbelow_min\trpc_err\tnoquote")
    for cn in spec["chains"]:
        for size in spec["sizes"]:
            for reg in spec["regimes"]:
                sid = f"{cn}/{size}/{reg}"
                rs = [r for r in rows if r["stratum"] == sid]
                nq = len({r["idx"] for r in rs if r["quote"].startswith("noquote")})
                for d in spec["deltas"]:
                    dr = [r for r in rs if r["delta"] == str(d)]
                    n = len(dr)
                    cnt = {o: sum(r["outcome"] == o for r in dr) for o in ("refuse5", "revert_other", "below_min", "rpc_err")}
                    k = sum(cnt.values())
                    lo, hi = clopper_pearson(k, n)
                    st = sprt_state(k, n, p["p0"], p["p1"], p["alpha"], p["beta"]) if n else "cont"
                    dec = {"H0": "<=1% (H0)", "H1": ">=5% (H1)"}.get(st, "not measured" if n >= p["n_max"] or n == 0 else "open")
                    rate = f"{k / n:.4f}" if n else ""
                    print(f"{sid}\t{d}\t{n}\t{k}\t{rate}\t{lo:.4f}\t{hi:.4f}\t{dec}\t{cnt['refuse5']}\t"
                          f"{cnt['revert_other']}\t{cnt['below_min']}\t{cnt['rpc_err']}\t{nq}")


if __name__ == "__main__":
    a = sys.argv[1:]
    if a[0] == "measure":
        j = int(a[a.index("-j") + 1]) if "-j" in a else 2
        cmd_measure(a[1], a[2], a[3], a[4], j)
    elif a[0] == "report":
        cmd_report(a[1], a[2])
    else:
        sys.exit(__doc__)
