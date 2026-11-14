#!/usr/bin/env python3
"""G7: gas and swap campaign over 7 chains, moonslot (registry memory) vs Discovery.

V2 is not deployed on any chain. Every measurement is an eth_call / debug_traceCall at a REAL
block of the chain with the V2 code + storage (built by deploy_state.sh on an anvil fork at
spec["state_fork"]) injected by stateOverride. Method of tools/n1-aged-quote, extended.

Modes per draw (chain, stratum, idx, block b, tIn, tOut, amountIn):
  D       registry as built (its rows are older than DISCOVERY_TTL): the Solver sweeps (Discovery).
  M<age>  natural moonslot: Hub.seedPool of the stratum's pools traced at the first block with
          ts >= ts(b) - age (prestateTracer diffMode gives the Hub's storage), injected at b; the
          contract decides whether it sweeps (Solver._registryFresh).
  MF<age> counterfactual: as M<age>, with the seed stamp ts(b - age) rewritten to ts(b) in the
          seeded words, so the registry reads fresh; verified in the trace (no discoverFor frame),
          else outcome mf_unforced.
Segments (callTracer frames): quote total, solve (Quoter -> Solver.findBestRoutePlan), discovery
(Hub.discoverFor frames), gates (frames to the Gate or its wrappers inside the quote), exec per leg
(frames under the Router to pools/wrappers/PoolManager with a swap/unlock selector), sweep
(token transfers by the Router after the last leg); calldata bytes, 16/4 intrinsic and the EIP-7623
floor; cold/warm (EIP-2929) as the Probe's gasUsed without and with an access list
(eth_createAccessList, fallback: prestateTracer accounts and slots; source in column al_src).
Outcomes: ok | noquote | revert | rpc_err | timeout | prereq | mf_unforced. All of them stay in
the denominator of the report. Swap coverage counts an mf_unforced row as its twin M<age>.

  g7.py blockat <chain> <unix_ts>
  g7.py draws   <spec.json> <seedhex> [chain]
  g7.py measure <spec.json> <statedir> <out.tsv> <seedhex> [-j 2] [--chains a,b] [--max N]
  g7.py smoke   <spec.json> <statedir> <out.tsv>
  g7.py report  <spec.json> <out.tsv>

The RPC key is read from $DRPC_KEY_FILE (default ~/.drpc-key) and never printed or written.
"""
import concurrent.futures as cf
import hashlib
import json
import os
import random
import sys
import threading
import time

SEL = {
    "preview": "30439d8c", "run": "3f1dde7a", "bal": "70a08231", "solve": "8e9d0a6c",
    "seed": "4c779596", "vital": "a35f8b8a", "wrappers": "ab0a1b3f", "discover": "4d400985",
    "active": "bf827fdb", "batch": "b9d096b2", "v2swap": "022c0d9f", "v3swap": "128acb08",
    "unlock": "48c89491", "transfer": "a9059cbb", "reserves": "0902f1ac", "slot0": "3850c7bd",
    "gstate": "e76c01e4", "record": "abc75427", "fee": "ddca3f43", "liquidity": "1a686502",
}
PROTOCOL_FEE_BPS = 28  # src/BlazePhoenixCore.sol:420
ERROR_SEL = "08c379a0"  # Error(string)
NQ_CLASSES = ("S", "dust", "A", "A'", "B")  # noquote classes, classify_rows()
MS_CASES = ("D", "hit", "partial", "miss", "expired")  # where the route came from, ms_case()
SPLIT_SEGS = ("g_quote", "g_exec", "g_legs_sum", "dex_overhead", "g_record")  # the ms_case table
PAIRED_SEGS = ("g_quote", "g_exec", "g_record")  # the paired vs D table
PAIRED_MIN_N = 20  # p95 of a paired cell only from here: nearest-rank ceil(0.95 n) < n, i.e. not the maximum, iff n >= 20
LEG_SELS = {SEL["v2swap"], SEL["v3swap"], SEL["unlock"]}
GAS = hex(30_000_000)
CALLER = "0x000000000000000000000000000000000000dEaD"
OUTCOMES = ("ok", "noquote", "revert", "rpc_err", "timeout", "prereq", "mf_unforced")
SEGS = ("g_quote", "g_solve", "g_discovery", "g_discovery_bridge", "g_gates", "g_exec", "g_legs_sum", "g_sweep", "g_record",
        "cd_intrinsic", "cd_floor7623", "g_cold", "g_warm", "g_coldpart")
COLS = ["chain", "label", "max_hops_code", "stratum", "kind", "idx", "b", "ts_b", "mode", "age_nom_s", "age_real_s",
        "b_seed", "seeds_ok", "seeds_n", "tin", "tout", "amount_in", "outcome", "detail", "swept", "net_out", "eff_min_out",
        "hops", "legs", "fits_2_10", "est_gas", "g_quote", "g_solve", "g_discovery", "g_discovery_bridge", "g_gates", "g_exec",
        "g_legs_sum", "legs_detail", "g_sweep", "g_record", "cd_bytes", "cd_zero", "cd_intrinsic", "cd_floor7623",
        "g_cold", "g_warm", "g_coldpart", "al_src", "delivered", "out_vs_D_bps", "mid", "out_vs_mid_bps",
        "pool_fee_bps", "vs_mid_net_bps", "liq_usd", "nq_class", "g_quote_cap", "ms_case",
        "gate_used", "vital_v", "vital_depth18", "vital_psi"]
TTL = 3600  # Solver DISCOVERY_TTL_SECONDS (src/BlazePhoenixSolver.sol:133)


class RpcError(Exception):
    pass


class RpcTimeout(RpcError):
    pass


class Reverted(Exception):
    def __init__(self, data):
        super().__init__(data)
        self.data = data or "0x"


class Rpc:
    """JSON-RPC over dRPC with the pre-registered retry policy (spec["retries"]). Own node:
    G7_RPC_URL_<CHAIN> (e.g. G7_RPC_URL_BASE) replaces the dRPC URL and the key file is not read."""

    def __init__(self, chain, attempts=3, backoff=2.0, timeout=90):
        import requests
        url = os.environ.get("G7_RPC_URL_" + chain.upper())
        if not url:
            key = open(os.path.expanduser(os.environ.get("DRPC_KEY_FILE", "~/.drpc-key"))).read().strip()
            url = f"https://lb.drpc.live/{chain}/{key}"
        self._url = url
        self._s = requests.Session()
        self._hdr = {}
        self._lock = threading.Lock()
        self.attempts, self.backoff, self.timeout = attempts, backoff, timeout

    def call(self, method, params):
        last, timed_out = None, False
        for attempt in range(self.attempts):
            try:
                r = self._s.post(self._url, json={"jsonrpc": "2.0", "id": 1, "method": method, "params": params},
                                 timeout=self.timeout)
                j = r.json()
            except Exception as ex:  # network, body not JSON, timeout; never echo the URL (it holds the key)
                last, timed_out = type(ex).__name__, "Timeout" in type(ex).__name__
            else:
                if "error" not in j:
                    return j["result"]
                err = j["error"]
                msg = str(err.get("message", ""))
                if err.get("code") == 3 or "revert" in msg.lower():
                    raise Reverted(err.get("data"))
                last, timed_out = f"{err.get('code')}:{msg[:80]}", "timeout" in msg.lower()
            if attempt < self.attempts - 1:
                time.sleep(self.backoff * (2 ** attempt))
        raise (RpcTimeout if timed_out else RpcError)(last)

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
        return first_at_or_after(self.ts, t, lo, hi)


def first_at_or_after(ts, t, lo, hi):
    """Smallest n in (lo, hi] with ts(n) >= t; hi grows until ts(hi) >= t (ts non-decreasing)."""
    while ts(hi) < t:
        lo, hi = hi, hi + 2 * (hi - lo) + 1
    while hi - lo > 1:
        mid = (lo + hi) // 2
        if ts(mid) >= t:
            hi = mid
        else:
            lo = mid
    return hi


# ── ABI helpers ──
def w(x):
    return format(x, "064x")


def addr(a):
    return w(int(a, 16))


def strip0x(h):
    return h[2:] if h.startswith("0x") else h


def word(d, i):
    return int(d[64 * i:64 * i + 64], 16)


def dyn_bytes(d, off):
    n = int(d[2 * off:2 * off + 64], 16)
    return d[2 * off + 64:2 * off + 64 + 2 * n]


def revert_detail(prefix, data, n=8):
    """prefix + the revert reason of Error(string), else prefix + the first n hex chars of the data
    (the selector); "empty" when there is no data. Capped at 40 chars for the Error text."""
    d = strip0x(data or "")
    if not d:
        return prefix + "empty"
    if d[:8] == ERROR_SEL and len(d) >= 8 + 128:
        try:
            txt = bytes.fromhex(dyn_bytes(d[8:], word(d[8:], 0))).decode("utf-8", "replace")
            return (prefix + "Error:" + txt)[:40]
        except ValueError:
            pass
    return prefix + "0x" + d[:n]


def decode_preview(res):
    d = strip0x(res)
    pv = 2 * word(d, 0)
    call = dyn_bytes(d, word(d, 1))
    f = lambda i: int(d[pv + 64 * i:pv + 64 * i + 64], 16)
    return {"netOut": f(4), "effectiveMinOut": f(7), "estGas": f(8), "hops": f(9), "legs": f(10),
            "canExecute": f(13) == 1, "call": call}


def encode_bytes_tail(h):
    n = len(h) // 2
    return w(n) + h + "0" * ((64 - len(h) % 64) % 64)


def encode_run(router, tin, tout, amount, wrap, call_hex):
    return ("0x" + SEL["run"] + addr(router) + addr(tin) + addr(tout) + w(amount) + w(1 if wrap else 0)
            + w(6 * 32) + encode_bytes_tail(call_hex))


def decode_run(res):
    d = strip0x(res)
    return word(d, 0) == 1, dyn_bytes(d, word(d, 1)), word(d, 2), word(d, 3), word(d, 4)


def decode_bools(res):
    """abi.decode(res, (bool[]))."""
    d = strip0x(res)
    o = word(d, 0) * 2
    return [word(d[o + 64:], i) == 1 for i in range(int(d[o:o + 64], 16))]


def encode_seed(pool, kind, fee, hooks, ta, tb):
    return SEL["seed"] + addr(pool) + w(kind) + w(fee) + addr(hooks) + addr(ta) + addr(tb)


def encode_batch(target, calls):
    """batch(address,bytes[]): head (target, offset 0x40), then the bytes[] array."""
    n = len(calls)
    heads, tails, off = [], [], 32 * n
    for c in calls:
        heads.append(w(off))
        t = encode_bytes_tail(c)
        tails.append(t)
        off += len(t) // 2
    return "0x" + SEL["batch"] + addr(target) + w(64) + w(n) + "".join(heads) + "".join(tails)


def calldata_cost(h):
    """(bytes, zero bytes, 16/4 intrinsic data gas, EIP-7623 floor = 21000 + 10 * tokens)."""
    b = bytes.fromhex(strip0x(h))
    z = b.count(0)
    nz = len(b) - z
    return len(b), z, 16 * nz + 4 * z, 21000 + 10 * (z + 4 * nz)


def fits(hops, legs, max_hops=2, max_legs=10):
    return int(hops <= max_hops and legs <= max_legs)


def bps(x, ref):
    return "" if not ref else round((x / ref - 1) * 1e4, 2)


def pct(vals, q):
    """Nearest-rank percentile (q in (0,100]) of a non-empty list."""
    s = sorted(vals)
    k = max(1, -(-len(s) * q // 100))
    return s[int(k) - 1]


# ── trace walking ──
def frames(node, depth=0, parent=None):
    yield node, depth, parent
    for c in node.get("calls") or []:
        yield from frames(c, depth + 1, node)


def fgas(n):
    return int(n.get("gasUsed", "0x0"), 16)


def sel_of(n):
    return strip0x(n.get("input") or "")[:8]


def frame_pair(n):
    """The (tA, tB) of a discoverFor(address,address) frame, lower-case."""
    i = strip0x(n.get("input") or "")
    return "0x" + i[32:72].lower(), "0x" + i[96:136].lower()


def quote_segments(trace, solver, hub, gate, wrappers, pair):
    """Gas of the quote trace by segment. Discovery = Hub.discoverFor frames (the Core calls it
    only when the Solver asks for a sweep, Core.discoverWithGate); g_discovery is all of them,
    g_discovery_bridge the part on pairs other than {tin, tout} (the 2-hop search's bridge legs,
    which seedPool never seeds). swept = a frame on the measured pair itself: a bridge sweep is
    not the moonslot failing. gates = top-most frames to the Gate or one of its wrappers."""
    solver, hub, gate = solver.lower(), hub.lower(), (gate or "").lower()
    wr = {x.lower() for x in wrappers}
    want = {pair[0].lower(), pair[1].lower()}
    seg = {"g_quote": fgas(trace), "g_solve": 0, "g_discovery": 0, "g_discovery_bridge": 0, "g_gates": 0, "swept": 0}
    gated = set()
    for n, _, p in frames(trace):
        to = (n.get("to") or "").lower()
        if to == solver and sel_of(n) == SEL["solve"]:
            seg["g_solve"] += fgas(n)
        if to == hub and sel_of(n) == SEL["discover"]:
            seg["g_discovery"] += fgas(n)
            if set(frame_pair(n)) == want:
                seg["swept"] = 1
            else:
                seg["g_discovery_bridge"] += fgas(n)
        if (to == gate or to in wr) and id(p) not in gated:
            seg["g_gates"] += fgas(n)
            gated.add(id(n))
        elif p is not None and id(p) in gated:
            gated.add(id(n))
    return seg


def subtree_size(n):
    return 1 + sum(subtree_size(c) for c in n.get("calls") or [])


def exec_segments(trace, router, hub=None):
    """Legs = frames under the Router (any depth) with a swap/unlock selector, not nested in another
    leg; sweep = Router transfers after the last leg's whole subtree (in call order), so the
    callback payments made inside a leg are not counted as sweep; record = Hub.recordSwap frames
    under the Router (registry feedback: a pool not yet in the registry is ADMITTED there, measured
    710573 of g_exec 1011096 on base, against 12706 once the pool is registered)."""
    router = router.lower()
    hub = (hub or "").lower()
    under, legs, order, leg_end, router_gas, record = set(), [], [], -1, 0, 0
    for i, (n, _, p) in enumerate(frames(trace)):
        to = (n.get("to") or "").lower()
        above = p is not None and id(p) in under
        if to == router and not above:  # top-most Router frames only: a callback into it is inside
            router_gas += fgas(n)
        inside = to == router or above
        if inside:
            under.add(id(n))
        order.append((n, p))
        if inside and hub and to == hub and sel_of(n) == SEL["record"]:
            record += fgas(n)
        if inside and to != router and sel_of(n) in LEG_SELS and i > leg_end:
            legs.append((n, to))
            leg_end = i + subtree_size(n) - 1
    sweep = 0
    for i, (n, p) in enumerate(order):
        if i > leg_end and p is not None and (p.get("to") or "").lower() == router and sel_of(n) == SEL["transfer"]:
            sweep += fgas(n)
    return {"g_exec": router_gas, "g_legs_sum": sum(fgas(n) for n, _ in legs),
            "legs_detail": ";".join(f"{to}:{fgas(n)}" for n, to in legs), "g_sweep": sweep, "g_record": record}


# ── memory (moonslot) storage ──
def merge_storage(base, diff_post):
    out = dict(base)
    out.update({k.lower(): v for k, v in diff_post.items()})
    return out


def rewrite_stamp(words, old_ts, new_ts):
    """Rewrite every byte-aligned big-endian occurrence of old_ts (as uint32, uint40 or uint64,
    whichever width holds it exactly) in the given storage words. Returns (new_words, hits)."""
    out, hits = {}, 0
    for slot, val in words.items():
        b = bytearray(bytes.fromhex(strip0x(val).rjust(64, "0")))
        for width in (4, 5, 8):
            pat, rep = old_ts.to_bytes(width, "big"), new_ts.to_bytes(width, "big")
            i, here = b.find(pat), 0
            while i != -1:
                b[i:i + width] = rep
                here += 1
                i = b.find(pat, i + width)
            if here:
                hits += here
                break
        out[slot] = "0x" + b.hex()
    return out, hits


# ── draws (deterministic from the seed) ──
def stratum_rng(seed, sid):
    return random.Random(int.from_bytes(hashlib.sha256(f"{seed}:{sid}".encode()).digest(), "big"))


def native(spec, chain, t):
    return spec["chains"][chain]["native_wrap"] if int(t, 16) == 0 else t


def draws(spec, seed, chain, b0, b1):
    """Every draw of one chain: per stratum, n draws of (b uniform in [b0, b1], direction,
    amount uniform over the stratum's list for that direction)."""
    out = []
    for st in spec["chains"][chain]["strata"]:
        rng = stratum_rng(seed.lower(), f"{chain}/{st['id']}")
        for idx in range(1, st["n"] + 1):
            b = rng.randint(b0, b1)
            fwd = rng.random() < 0.5
            tin, tout = (st["tA"], st["tB"]) if fwd else (st["tB"], st["tA"])
            # Native is address(0) in a V4 pool key but WETH at the Solver door (Solver.sol:230
            # refuses address(0); Core.nativeMapVerified maps WETH -> address(0) per V4-native key).
            tin, tout = (native(spec, chain, t) for t in (tin, tout))
            amt = rng.choice(st["amounts"]["A" if fwd else "B"])
            out.append({"stratum": st["id"], "kind": st["kind"], "idx": idx, "b": b, "tin": tin, "tout": tout,
                        "amount": int(amt), "st": st})
    return out


def window(rpc, spec):
    t0, t1 = spec["window"]["t0"], spec["window"]["t1"]
    head = int(rpc.call("eth_blockNumber", []), 16)
    b0 = rpc.first_at_or_after(t0, 0, head)
    b1 = rpc.first_at_or_after(t1, b0 - 1, head) - 1
    return b0, b1


# ── chain state ──
class Chain:
    def __init__(self, name, spec, statedir, rpc=None):
        self.name = name
        self.spec = spec
        self.c = spec["chains"][name]
        man = dict(l.split("\t", 1) for l in open(os.path.join(statedir, f"{name}.manifest.tsv")).read().split("\n")[1:] if l)
        self.man = man
        self.hub, self.solver, self.router = man["hub"].lower(), man["solver"].lower(), man["router"].lower()
        self.quoter, self.probe, self.admin = man["quoter"].lower(), man["probe"].lower(), man["admin"].lower()
        self.gate = man.get("gate", "").lower()
        self.state_ts = int(man["stateTs"])
        st = json.load(open(os.path.join(statedir, f"{name}.state.json")))
        self.base = {a: {"code": acc["code"], "nonce": hex(acc["nonce"]), "state": acc["storage"]}
                     for a, acc in st["accounts"].items()}
        g = os.path.join(statedir, f"{name}.gates.tsv")
        # gates.tsv (deploy_state.sh): family adapter venue_key tA tB pool wrapper status. The spec names
        # the gate pool; the wrapper address exists only after Gate.create (CREATE2), so it is read here.
        rows = [l.split("\t") for l in open(g).read().split("\n")[1:] if l] if os.path.exists(g) else []
        self.wrapper_of_pool = {r[5].lower(): r[6].lower() for r in rows if r[7] == "created"}
        self.wrappers = list(self.wrapper_of_pool.values())
        self.label = self.c["label"]
        # The row label names the tree measured; a state built from another tree is refused.
        if man["tree_commit"][:7] not in self.label:
            raise SystemExit(f"{name}: label {self.label!r} does not name tree {man['tree_commit'][:7]}")
        self.max_hops = int(self.c["max_hops"])  # the code's ceiling of that tree, per row
        r = spec["retries"]
        self.rpc = rpc or Rpc(name, r["attempts"], r["backoff_s"], r["timeout_s"])
        self.slots = {}
        self.fees = {}  # pool -> fee() pips, None when the call fails (unknown, not zero)
        self.liq = {}  # stratum id -> liq_usd (prereg/strata.tsv), set by cmd_measure
        self.b0 = None  # window start, set by cmd_measure (mid_price code check)
        self.lock = threading.Lock()

    def override(self, hub_state=None, fund=None, eth_wei=0, admin_code=False):
        o = {k: dict(v) for k, v in self.base.items()}
        if hub_state is not None:
            o[self.hub]["state"] = hub_state
        if eth_wei:
            o[self.probe]["balance"] = hex(eth_wei)
        if admin_code:
            o[self.admin] = {"code": self.base[self.probe]["code"]}
        for acct, (slot, val) in (fund or {}).items():
            o.setdefault(acct.lower(), {}).setdefault("stateDiff", {})[slot] = "0x" + w(val)
        return o

    def balance_slot(self, token, blk):
        """(holder account, slot) of the word holding balanceOf(probe): every slot of every account
        a balanceOf read touches (prestateTracer; a proxy keeps balances in another contract, e.g.
        sUSD's TokenState), each tried by override and verified by balanceOf. An override that
        breaks the read (a proxy's target slot) reverts or empties the return: not a match."""
        token = token.lower()
        with self.lock:
            if token in self.slots:
                return self.slots[token]
        call = {"to": token, "data": "0x" + SEL["bal"] + addr(self.probe)}
        pre = self.rpc.call("debug_traceCall", [call, hex(blk), {"tracer": "prestateTracer"}])
        found = None
        for acct, acc in sorted(pre.items(), key=lambda kv: kv[0].lower() != token):
            for s in (acc.get("storage") or {}):
                v = 987654321987654321
                o = {acct.lower(): {"stateDiff": {s: "0x" + w(v)}}}
                try:
                    r = self.rpc.call("eth_call", [call, hex(blk), o])
                except Reverted:
                    continue
                if r not in ("0x", "") and int(r, 16) == v:
                    found = (acct.lower(), s)
                    break
            if found:
                break
        if found is None:
            # a zero balance word may not appear in the prestate: derive the Solidity mapping slots
            raise RpcError(f"balance slot not found for {token}")
        with self.lock:
            self.slots[token] = found
        return found


def seed_memory(ch, d, age, ts_b):
    """Trace Hub.seedPool of the stratum's pools at the first block with ts >= ts(b) - age.
    Returns (b_seed, ts_seed, hub_storage, changed_words, oks): oks = the batch's per-call
    success (G7Probe.batch swallows a refused seedPool), read by an eth_call of the same tx."""
    b = d["b"]
    bs = ch.rpc.first_at_or_after(ts_b - age, b - 1 - int(age / ch.c["block_time_hint"]) - 2, b) if age else b
    ts_s = ch.rpc.ts(bs)
    calls = [encode_seed(p["pool"], p["kind"], p["fee"], p.get("hooks", "0x" + "0" * 40), d["st"]["tA"], d["st"]["tB"])
             for p in d["st"]["seed_pools"]]
    tx = {"from": CALLER, "to": ch.admin, "data": encode_batch(ch.hub, calls), "gas": GAS}
    tr = ch.rpc.call("debug_traceCall", [tx, hex(bs), {"tracer": "prestateTracer", "tracerConfig": {"diffMode": True},
                                                        "stateOverrides": ch.override(admin_code=True)}])
    post = (tr.get("post") or {}).get(ch.hub) or next((v for k, v in (tr.get("post") or {}).items() if k.lower() == ch.hub), {})
    changed = {k.lower(): v for k, v in (post.get("storage") or {}).items()}
    oks = decode_bools(ch.rpc.call("eth_call", [tx, hex(bs), ch.override(admin_code=True)]))
    return bs, ts_s, merge_storage(ch.base[ch.hub]["state"], changed), changed, oks


def trace_call(ch, tx, b, cfg):
    """debug_traceCall; a trace that ran out of gas is retried once with twice the cap, so a quote
    refused for gas is told apart from a quote refused by the Solver. Returns (trace, cap used)."""
    cap = int(tx["gas"], 16)
    tr = ch.rpc.call("debug_traceCall", [tx, hex(b), cfg])
    if "out of gas" in str(tr.get("error") or ""):
        cap *= 2
        tr = ch.rpc.call("debug_traceCall", [dict(tx, gas=hex(cap)), hex(b), cfg])
    return tr, cap


def pool_fee_bps(ch, d, legs_detail, hops, legs):
    """Sum of the legs' pool fees in bps: the pre-registered seed_pools fee (pips > 0) first, else
    fee() of the pool at b (cached per pool); "" unless hops == legs and every leg's fee is known."""
    pools = [x.split(":")[0] for x in legs_detail.split(";") if x]
    if not pools or hops != legs or len(pools) != legs:
        return ""
    known = {sp["pool"].lower(): sp["fee"] for sp in d["st"].get("seed_pools", []) if sp.get("fee", 0) > 0}
    total = 0
    for pool in pools:
        if pool in known:
            total += known[pool] / 100
            continue
        with ch.lock:
            cached = pool in ch.fees
        if not cached:
            try:
                res = strip0x(ch.rpc.call("eth_call", [{"to": pool, "data": "0x" + SEL["fee"]}, hex(d["b"])]))
                fee = word(res, 0) if len(res) >= 64 else None
            except (RpcError, Reverted, ValueError):
                fee = None
            with ch.lock:
                ch.fees[pool] = fee
        if ch.fees[pool] is None:
            return ""
        total += ch.fees[pool] / 100
    return total


def measure_mode(ch, d, ts_b, mode, hub_state):
    """Quote trace + preview + exec trace + cold/warm for one mode. Returns a row fragment."""
    r = {}
    q = "0x" + SEL["preview"] + addr(d["tin"]) + addr(d["tout"]) + w(d["amount"]) + addr(ch.probe) + w(ts_b + ch.spec["deadline_s"])
    tx = {"from": CALLER, "to": ch.quoter, "data": q, "gas": GAS}
    ov = ch.override(hub_state=hub_state)
    tr, r["g_quote_cap"] = trace_call(ch, tx, d["b"], {"tracer": "callTracer", "stateOverrides": ov})
    seg = quote_segments(tr, ch.solver, ch.hub, ch.gate, ch.wrappers, (d["tin"], d["tout"]))
    r.update(seg)
    if tr.get("error"):
        # the revert data (selector + first word: SolverE(5) = no route, SolverE(4) = bad params; Error(string) decoded)
        r.update(outcome="noquote", detail=("quote:" + str(tr.get("error")))[:40] + ":" + revert_detail("", tr.get("output"), 72))
        return r
    pv = decode_preview(tr["output"])
    r.update(net_out=pv["netOut"], eff_min_out=pv["effectiveMinOut"], hops=pv["hops"], legs=pv["legs"],
             fits_2_10=fits(pv["hops"], pv["legs"]), est_gas=pv["estGas"])
    if not pv["canExecute"] or not pv["call"]:
        r.update(outcome="noquote", detail="canExecute=0")
        return r
    nb, nz, intr, floor = calldata_cost(pv["call"])
    r.update(cd_bytes=nb, cd_zero=nz, cd_intrinsic=intr, cd_floor7623=floor)
    wrap = d["tin"].lower() == ch.c["native_wrap"].lower()
    if wrap:
        fund = {}
    else:
        holder, slot = ch.balance_slot(d["tin"], d["b"])
        fund = {holder: (slot, d["amount"])}
    ovx = ch.override(hub_state=hub_state, fund=fund, eth_wei=(d["amount"] if wrap else 0) + 10 ** 18)
    if not wrap:
        # the funding override is verified before the exec: a slot that does not hold the probe's
        # balance would make every exec a revert that is not the Router's (prereq, not revert)
        bal = word(strip0x(ch.rpc.call("eth_call", [{"to": d["tin"], "data": "0x" + SEL["bal"] + addr(ch.probe)}, hex(d["b"]), ovx])), 0)
        if bal != d["amount"]:
            r.update(outcome="prereq", detail=f"fund:{bal}")
            return r
    run = {"from": CALLER, "to": ch.probe, "data": encode_run(ch.router, d["tin"], d["tout"], d["amount"], wrap, pv["call"]), "gas": GAS}
    xt = ch.rpc.call("debug_traceCall", [run, hex(d["b"]), {"tracer": "callTracer", "stateOverrides": ovx}])
    ok, ret, delivered, gas_used, _ = decode_run(xt["output"])
    r.update(exec_segments(xt, ch.router, ch.hub))
    r["gate_used"] = int(any(f"{x.lower()}:" in r["legs_detail"] for x in ch.wrappers))
    r.update(delivered=delivered, g_cold=gas_used, pool_fee_bps=pool_fee_bps(ch, d, r["legs_detail"], pv["hops"], pv["legs"]))
    if not ok:
        r.update(outcome="revert", detail=revert_detail("exec:", ret))
        return r
    # warm: same call with the access list of the same call
    al, src = None, "createAccessList"
    try:
        al = ch.rpc.call("eth_createAccessList", [run, hex(d["b"]), ovx])["accessList"]
    except (RpcError, Reverted, KeyError, TypeError):
        src = "prestate"
        pre = ch.rpc.call("debug_traceCall", [run, hex(d["b"]), {"tracer": "prestateTracer", "stateOverrides": ovx}])
        al = [{"address": a, "storageKeys": list((v.get("storage") or {}).keys())} for a, v in pre.items()
              if a.lower() not in (CALLER.lower(), ch.probe)]
    res = ch.rpc.call("eth_call", [dict(run, accessList=al), hex(d["b"]), ovx])
    ok2, _, _, gas_warm, _ = decode_run(res)
    r.update(g_warm=gas_warm if ok2 else "", g_coldpart=(gas_used - gas_warm) if ok2 else "", al_src=src,
             outcome="ok" if delivered >= pv["effectiveMinOut"] else "revert",
             detail="" if delivered >= pv["effectiveMinOut"] else f"below_min:{pv['effectiveMinOut'] - delivered}")
    return r


def mid_price(ch, d):
    """Spot tokenOut-per-tokenIn (raw units) of the stratum's pre-registered deepest direct pool."""
    mp = d["st"].get("mid_pool")
    if not mp:
        return ""
    pool, fam, t0 = mp["pool"], mp["family"], mp["token0"].lower()
    # a pool created after the window start, emptied, or at an absurd price gives no mid (absent, not zero)
    if ch.rpc.call("eth_getCode", [pool, hex(ch.b0)]) in ("0x", "", None):
        return ""
    if fam == "v2":
        dd = strip0x(ch.rpc.call("eth_call", [{"to": pool, "data": "0x" + SEL["reserves"]}, hex(d["b"])]))
        r0, r1 = word(dd, 0), word(dd, 1)
        if r0 == 0 or r1 == 0:
            return ""
        p01 = r1 / r0
    elif fam in ("v3", "algebra"):
        dd = strip0x(ch.rpc.call("eth_call", [{"to": pool, "data": "0x" + SEL["slot0" if fam == "v3" else "gstate"]}, hex(d["b"])]))
        lq = strip0x(ch.rpc.call("eth_call", [{"to": pool, "data": "0x" + SEL["liquidity"]}, hex(d["b"])]))
        if word(lq, 0) == 0:
            return ""
        p01 = (word(dd, 0) / 2 ** 96) ** 2
    else:
        return ""
    if not (1e-30 <= p01 <= 1e30):
        return ""
    return p01 if d["tin"].lower() == t0 else 1 / p01


def vital(ch, d):
    """Gate.vitalOf(wrapper) at b for a gates stratum; the wrapper is the one created for the
    stratum's gate_pool (a refused create has no wrapper: the columns stay empty, absent is not zero)."""
    w_ = ch.wrapper_of_pool.get(d["st"].get("gate_pool", "").lower())
    if not w_ or not ch.gate:
        return {}
    dd = strip0x(ch.rpc.call("eth_call", [{"to": ch.gate, "data": "0x" + SEL["vital"] + addr(w_)}, hex(d["b"]), ch.override()]))
    return {"vital_v": word(dd, 0), "vital_depth18": word(dd, 1), "vital_psi": word(dd, 2)}


def modes(spec):
    out = [("D", None, False)]
    for m, age in spec["ages"].items():
        out.append((m, age, False))
    for m in spec["mf_ages"]:
        out.append(("MF" + m[1:], spec["ages"][m], True))
    return out


def measure_draw(ch, d, done):
    """All modes of one draw; rows already in `done` (chain, stratum, idx, mode) are skipped."""
    rows, ref = [], None
    base = {"chain": ch.name, "label": ch.label, "max_hops_code": ch.max_hops, "stratum": d["stratum"], "kind": d["kind"], "idx": d["idx"],
            "b": d["b"], "tin": d["tin"], "tout": d["tout"], "amount_in": d["amount"], "liq_usd": ch.liq.get(d["stratum"], "")}
    try:
        ts_b = ch.rpc.ts(d["b"])
    except RpcError as e:
        return [dict(base, mode=m, outcome="timeout" if isinstance(e, RpcTimeout) else "rpc_err", detail=f"ts:{e}"[:60])
                for m, _, _ in modes(ch.spec) if (ch.name, d["stratum"], str(d["idx"]), m) not in done]
    base["ts_b"] = ts_b
    try:
        mid = mid_price(ch, d)
    except (RpcError, Reverted, ValueError):
        mid = ""
    try:
        vt = vital(ch, d)
    except (RpcError, Reverted):
        vt = {}
    for m, age, forced in modes(ch.spec):
        key = (ch.name, d["stratum"], str(d["idx"]), m)
        row = dict(base, mode=m, age_nom_s=age if age is not None else "", mid=mid, **vt)
        if key in done:
            if m == "D":
                ref = done[key].get("net_out") if done[key].get("outcome") == "ok" else None
            continue
        try:
            hub_state = None
            if age is not None:
                if ts_b - age <= ch.state_ts:
                    row.update(outcome="prereq", detail="ts(b-age)<=stateTs")
                    rows.append(row)
                    continue
                bs, ts_s, hub_state, changed, oks = seed_memory(ch, d, age, ts_b)
                row.update(b_seed=bs, age_real_s=ts_b - ts_s, seeds_ok=sum(oks), seeds_n=len(oks))
                if forced:
                    neww, hits = rewrite_stamp(changed, ts_s, ts_b)
                    hub_state = merge_storage(hub_state, neww)
                    if not hits:
                        row.update(outcome="mf_unforced", detail="stamp not found")
                        rows.append(row)
                        continue
            row.update(measure_mode(ch, d, ts_b, m, hub_state))
            if forced and row.get("swept") == 1 and row.get("outcome") == "ok":
                row.update(outcome="mf_unforced", detail="discoverFor frame present")
        except Reverted as x:
            row.update(outcome="revert", detail=revert_detail("call:", x.data))
        except RpcTimeout as x:
            row.update(outcome="timeout", detail=str(x)[:60])
        except RpcError as x:
            row.update(outcome="rpc_err", detail=str(x)[:60])
        if m == "D":
            ref = row.get("net_out") if row.get("outcome") == "ok" else None
        if row.get("outcome") == "ok":
            if ref:
                row["out_vs_D_bps"] = bps(int(row["net_out"]), int(ref))
            if mid:
                row["out_vs_mid_bps"] = bps(int(row["delivered"]), d["amount"] * mid)
                if row.get("pool_fee_bps") not in ("", None):
                    row["vs_mid_net_bps"] = row["out_vs_mid_bps"] + row["pool_fee_bps"] + PROTOCOL_FEE_BPS
        row["ms_case"] = ms_case(row)
        rows.append(row)
    return rows


def load_rows(path):
    if not os.path.exists(path):
        return []
    lines = open(path).read().split("\n")
    hdr = lines[0].split("\t")
    return [dict(zip(hdr, l.split("\t"))) for l in lines[1:] if l]


def load_done(path, smoke=False):
    """Rows already measured, keyed (chain, stratum, idx, mode). rpc_err/timeout rows are not
    done: a retry on relaunch is the pre-registered rule (the smoke keeps them as they are)."""
    return {(r["chain"], r["stratum"], r["idx"], r["mode"]): r for r in load_rows(path)
            if smoke or r["outcome"] not in ("rpc_err", "timeout")}


def classify_rows(rows, liq=None):
    """nq_class of every noquote row (pure): S = the quote ran out of gas; dust = canExecute=0;
    A = the stratum's pool holds <= 1 USD (liq from the row, or `liq[(chain, stratum)]`);
    A' = a smaller amount of the same (chain, tin, tout) did get an ok row; B = the rest."""
    oks = {}
    for r in rows:
        if r.get("outcome") == "ok":
            k = (r["chain"], r["tin"].lower(), r["tout"].lower())
            oks[k] = min(oks.get(k, int(r["amount_in"])), int(r["amount_in"]))
    for r in rows:
        if r.get("outcome") != "noquote":
            r["nq_class"] = ""
            continue
        lq = (liq or {}).get((r["chain"], r["stratum"]), r.get("liq_usd", ""))
        det = r.get("detail", "")
        k = (r["chain"], r["tin"].lower(), r["tout"].lower())
        if "out of gas" in det:
            r["nq_class"] = "S"
        elif det == "canExecute=0":
            r["nq_class"] = "dust"
        elif lq not in ("", None) and float(lq) <= 1:
            r["nq_class"] = "A"
        elif k in oks and oks[k] < int(r["amount_in"]):
            r["nq_class"] = "A'"
        else:
            r["nq_class"] = "B"
    return rows


def ms_case(row, ttl=TTL):
    """Where the quote's route came from (pure). D = the Discovery mode. For a moonslot row:
    expired when the record is older than the TTL (age_real_s > ttl; a forced stamp, MF, is fresh
    by construction); miss when the quote swept the measured pair (nothing came from the record);
    partial when it did not sweep but still paid discovery gas (record + residual g_discovery > 0);
    hit when no discovery ran. "" when the quote did not run (no swept)."""
    mode = row.get("mode", "")
    if mode == "D":
        return "D"
    if row.get("swept") in ("", None):
        return ""
    age = row.get("age_real_s", "")
    if not mode.startswith("MF") and age not in ("", None) and int(age) > ttl:
        return "expired"
    if int(row["swept"]) == 1:
        return "miss"
    if int(row.get("g_discovery") or 0) > 0:
        return "partial"
    return "hit"


def split_value(r, s):
    """One value of the exec split for a row (None when a term is absent): dex_overhead =
    g_exec - g_legs_sum (the Router, Hub and record above the legs), rec_frac = g_record / g_exec."""
    try:
        if s == "dex_overhead":
            return int(r["g_exec"]) - int(r["g_legs_sum"])
        if s == "rec_frac":
            return round(int(r["g_record"]) / int(r["g_exec"]), 4)
        return int(r[s])
    except (KeyError, ValueError, ZeroDivisionError):
        return None


def draw_key(r):
    """The draw a row belongs to: every mode of one draw shares it (chain, stratum, idx, block b)."""
    return r["chain"], r["stratum"], r["idx"], r["b"]


def pairs_vs_d(rows, s):
    """Paired by draw (pure): (chain, mode) -> [(ms_case, D value, mode value)], one entry per draw
    whose D row and mode row are both ok with segment `s`. A draw missing either side is in
    neither column, so no marginal leaks into a paired cell."""
    d = {draw_key(r): int(r[s]) for r in rows if r["mode"] == "D" and r["outcome"] == "ok" and r.get(s) not in ("", None)}
    out = {}
    for r in rows:
        k = draw_key(r)
        if r["mode"] != "D" and r["outcome"] == "ok" and r.get(s) not in ("", None) and k in d:
            out.setdefault((r["chain"], r["mode"]), []).append((r.get("ms_case", ""), d[k], int(r[s])))
    return out


def paired_cells(v):
    """n, D p50, mode p50, delta p50, delta p95 of a list of (ms_case, D, mode) pairs; delta = mode - D
    per draw. The p95 is empty below PAIRED_MIN_N (there it would be the maximum)."""
    if not v:
        return [0, "", "", "", ""]
    dl = [m - d for _, d, m in v]
    return [len(v), pct([d for _, d, _ in v], 50), pct([m for _, _, m in v], 50), pct(dl, 50),
            pct(dl, 95) if len(v) >= PAIRED_MIN_N else ""]


def load_liq(spec_path):
    """(stratum id -> liq_usd) per chain from prereg/strata.tsv next to the spec; {} when absent."""
    p = os.path.join(os.path.dirname(os.path.abspath(spec_path)), "prereg", "strata.tsv")
    out = {}
    for r in load_rows(p):
        out.setdefault(r["chain"], {})[r["id"]] = r.get("liq_usd", "")
    return out


def write_rows(out, lock, rows):
    with lock:
        for r in rows:
            out.write("\t".join(str(r.get(k, "")) for k in COLS) + "\n")
        out.flush()


def cmd_measure(spec_path, statedir, out_path, seed, jobs, only=None, max_per_chain=None, smoke=False):
    spec = json.load(open(spec_path))
    done = load_done(out_path, smoke)
    new = not os.path.exists(out_path)
    out = open(out_path, "a")
    if new:
        out.write("\t".join(COLS) + "\n")
    lock = threading.Lock()
    tasks = []
    liq = load_liq(spec_path)
    for cn in spec["chains"]:
        if only and cn not in only:
            continue
        ch = Chain(cn, spec, statedir)
        ch.liq = liq.get(cn, {})
        b0, b1 = window(ch.rpc, spec)
        ch.b0 = b0
        ds = draws(spec, seed, cn, b0, b1) if not smoke else smoke_draws(spec, cn, b0)
        if max_per_chain:
            ds = ds[:max_per_chain]
        print(f"{cn}: window {b0}..{b1}, {len(ds)} draws, label {ch.label}", flush=True)
        tasks += [(ch, d) for d in ds]
    with cf.ThreadPoolExecutor(jobs) as ex:
        futs = {ex.submit(measure_draw, ch, d, done): (ch.name, d["stratum"], d["idx"]) for ch, d in tasks}
        for i, f in enumerate(cf.as_completed(futs), 1):
            rows = f.result()
            write_rows(out, lock, rows)
            if i % 10 == 0 or smoke:
                print(f"{time.strftime('%H:%M:%S')} {i}/{len(tasks)} {futs[f]}", flush=True)
    out.close()
    # post-pass: nq_class needs every row of the chain (A' looks at the other amounts of the pair)
    rows = classify_rows(load_rows(out_path))
    with open(out_path, "w") as f:
        f.write("\t".join(COLS) + "\n")
        write_rows(f, lock, rows)


def smoke_draws(spec, cn, b0):
    """Outside the sample: the first stratum's first amount, forward, at block b0 - 1 (the block
    just before the sampling window, so it can never coincide with a draw)."""
    st = spec["chains"][cn]["strata"][0]
    return [{"stratum": "smoke", "kind": "smoke", "idx": 1, "b": b0 - 1, "tin": st["tA"], "tout": st["tB"],
             "amount": int(st["amounts"]["A"][0]), "st": st}]


def swap_coverage(rows):
    """{chain: (n, ok, mf_unforced_twin_ok)} over every row. An mf_unforced row says the MF
    counterfactual was not forced, not that the swap failed: it counts as swap-ok when its natural
    twin M<age> (same chain, stratum, idx) is ok. Every other outcome but ok counts as a failure."""
    out = {r["chain"]: [0, 0, 0] for r in rows}
    oc = {(r["chain"], r["stratum"], str(r["idx"]), r["mode"]): r["outcome"] for r in rows}
    for r in rows:
        c = out[r["chain"]]
        c[0] += 1
        if r["outcome"] == "ok":
            c[1] += 1
        elif r["outcome"] == "mf_unforced" and oc.get((r["chain"], r["stratum"], str(r["idx"]), "M" + r["mode"][2:])) == "ok":
            c[2] += 1
    return {k: tuple(v) for k, v in out.items()}


def cmd_report(spec_path, out_path):
    spec = json.load(open(spec_path))
    rows = classify_rows(load_rows(out_path))
    print("# outcomes: chain\tkind\tmode\tn\t" + "\t".join(OUTCOMES))
    keys = sorted({(r["chain"], r["kind"], r["mode"]) for r in rows})
    for k in keys:
        rs = [r for r in rows if (r["chain"], r["kind"], r["mode"]) == k]
        print("\t".join(k) + f"\t{len(rs)}\t" + "\t".join(str(sum(r["outcome"] == o for r in rs)) for o in OUTCOMES))
    print("# swap coverage (mf_unforced counts as its twin M<age>; denominator = every row): "
          "chain\tn\tok\tmf_unforced_twin_ok\tswap_ok\tswap_ok_pct")
    for cn, (n, ok, mf) in sorted(swap_coverage(rows).items()):
        print(f"{cn}\t{n}\t{ok}\t{mf}\t{ok + mf}\t{100 * (ok + mf) / n:.1f}")
    print("# gas: chain\tkind\tmode\tsegment\tn_ok\tp50\tp95\tp99")
    for k in keys:
        rs = [r for r in rows if (r["chain"], r["kind"], r["mode"]) == k and r["outcome"] == "ok"]
        for s in SEGS:
            v = [int(r[s]) for r in rs if r.get(s) not in ("", None)]
            if v:
                print("\t".join(k) + f"\t{s}\t{len(v)}\t{pct(v, 50)}\t{pct(v, 95)}\t{pct(v, 99)}")
    print("# noquote classes: chain\tkind\tmode\tn_noquote\t" + "\t".join(NQ_CLASSES))
    for k in keys:
        rs = [r for r in rows if (r["chain"], r["kind"], r["mode"]) == k and r["outcome"] == "noquote"]
        if rs:
            print("\t".join(k) + f"\t{len(rs)}\t" + "\t".join(str(sum(r["nq_class"] == c for r in rs)) for c in NQ_CLASSES))
    for r in rows:
        if not r.get("ms_case"):  # a results.tsv from before the column
            r["ms_case"] = ms_case(r)
    print("# moonslot cases: chain\tkind\tms_case\tsegment\tn\tp50\tp95")
    for k in sorted({(r["chain"], r["kind"], r["ms_case"]) for r in rows if r["outcome"] == "ok" and r["ms_case"]}):
        rs = [r for r in rows if (r["chain"], r["kind"], r["ms_case"]) == k and r["outcome"] == "ok"]
        for s in SPLIT_SEGS:
            v = [x for x in (split_value(r, s) for r in rs) if x is not None]
            print("\t".join(k) + f"\t{s}\t{len(v)}\t{pct(v, 50) if v else ''}\t{pct(v, 95) if v else ''}")
    print("# exec split: chain\tkind\tn_ok\tlegs_p50\tlegs_p95\tdex_overhead_p50\tdex_overhead_p95\trec_frac_p50\trec_frac_p95")
    for k in sorted({(r["chain"], r["kind"]) for r in rows}):
        rs = [r for r in rows if (r["chain"], r["kind"]) == k and r["outcome"] == "ok"]
        cells = []
        for s in ("g_legs_sum", "dex_overhead", "rec_frac"):
            v = [x for x in (split_value(r, s) for r in rs) if x is not None]
            cells += [pct(v, 50), pct(v, 95)] if v else ["", ""]
        if rs:
            print("\t".join(k) + f"\t{len(rs)}\t" + "\t".join(str(c) for c in cells))
    nat = [m for m, _, forced in modes(spec) if not forced]
    print("# moonslot effect: chain\tsegment\t" + "\t".join(f"{m}_n\t{m}_p50\t{m}_p95" for m in nat))
    for cn in spec["chains"]:
        for s in ("g_quote", "g_exec", "g_discovery"):
            cells = []
            for m in nat:
                v = [int(r[s]) for r in rows if r["chain"] == cn and r["mode"] == m and r["outcome"] == "ok" and r.get(s) not in ("", None)]
                cells += [len(v), pct(v, 50), pct(v, 95)] if v else [0, "", ""]
            if any(c for c in cells):
                print(f"{cn}\t{s}\t" + "\t".join(str(c) for c in cells))
    print("# moonslot vs Discovery vs market: chain\tmode\tn_ok\tswept\tfits_2_10\tvsD_p50_bps\tvsmid_p50_bps\tvsmid_net_p50_bps\tlabel")
    for cn in spec["chains"]:
        for m, _, _ in modes(spec):
            rs = [r for r in rows if r["chain"] == cn and r["mode"] == m and r["outcome"] == "ok"]
            if not rs:
                continue
            vd = [float(r["out_vs_D_bps"]) for r in rs if r.get("out_vs_D_bps")]
            vm = [float(r["out_vs_mid_bps"]) for r in rs if r.get("out_vs_mid_bps")]
            vn = [float(r["vs_mid_net_bps"]) for r in rs if r.get("vs_mid_net_bps")]
            print(f"{cn}\t{m}\t{len(rs)}\t{sum(r['swept'] == '1' for r in rs)}\t{sum(r['fits_2_10'] == '1' for r in rs)}\t"
                  f"{pct(vd, 50) if vd else ''}\t{pct(vm, 50) if vm else ''}\t{pct(vn, 50) if vn else ''}\t{rs[0]['label']}")
    # Declared cells: every chain x mode (but D) x segment, with ms_case "all", printed even at n 0;
    # the per-case lines follow only where a pair exists.
    print(f"# paired vs D (same chain, stratum, idx, b; both ok; delta = mode - D per draw; delta_p95 only at n >= {PAIRED_MIN_N}): "
          "chain\tmode\tms_case\tsegment\tn_pairs\tD_p50\tM_p50\tdelta_p50\tdelta_p95")
    prs = {s: pairs_vs_d(rows, s) for s in PAIRED_SEGS}
    for cn in spec["chains"]:
        for m in [m for m, _, _ in modes(spec) if m != "D"]:
            for s in PAIRED_SEGS:
                ps = prs[s].get((cn, m), [])
                for c in ("all",) + MS_CASES[1:]:
                    v = ps if c == "all" else [p for p in ps if p[0] == c]
                    if c != "all" and not v:
                        continue
                    print(f"{cn}\t{m}\t{c}\t{s}\t" + "\t".join(str(x) for x in paired_cells(v)))
    # g_record per route shape: D (cold registry, the venue admitted by recordSwap) vs M0 (the route
    # registered at age 0). Unpaired marginals over ok rows with a g_record; a line per (chain, hops,
    # legs) present in either mode; an empty hops or legs stays its own key (absent is not a value).
    gm = ("D", "M0")
    print(f"# g_record by hops x legs (ok rows; D vs M0 unpaired; p95 only at n >= {PAIRED_MIN_N}): chain\thops\tlegs\t"
          + "\t".join(f"{m}_n\t{m}_p50\t{m}_p95" for m in gm))
    rec = [r for r in rows if r["outcome"] == "ok" and r["mode"] in gm and r.get("g_record") not in ("", None)]
    shape = lambda r: (r["chain"], r["hops"], r["legs"])
    for k in sorted({shape(r) for r in rec}, key=lambda k: (k[0], len(k[1]), k[1], len(k[2]), k[2])):
        cells = []
        for m in gm:
            g = [int(r["g_record"]) for r in rec if shape(r) == k and r["mode"] == m]
            cells += [len(g), pct(g, 50) if g else "", pct(g, 95) if len(g) >= PAIRED_MIN_N else ""]
        print("\t".join(k) + "\t" + "\t".join(str(c) for c in cells))


def main(a):
    if not a:
        sys.exit(__doc__)
    if a[0] == "blockat":
        rpc = Rpc(a[1])
        head = int(rpc.call("eth_blockNumber", []), 16)
        n = rpc.first_at_or_after(int(a[2]), 0, head)
        print(n, rpc.ts(n))
    elif a[0] == "draws":
        spec = json.load(open(a[1]))
        for cn in ([a[3]] if len(a) > 3 else spec["chains"]):
            b0, b1 = window(Rpc(cn), spec)
            for d in draws(spec, a[2], cn, b0, b1):
                print(cn, d["stratum"], d["idx"], d["b"], d["tin"], d["tout"], d["amount"], sep="\t")
    elif a[0] in ("measure", "smoke"):
        j = int(a[a.index("-j") + 1]) if "-j" in a else 2
        only = a[a.index("--chains") + 1].split(",") if "--chains" in a else None
        mx = int(a[a.index("--max") + 1]) if "--max" in a else None
        if a[0] == "measure":
            cmd_measure(a[1], a[2], a[3], a[4].lower(), j, only, mx)
        else:
            cmd_measure(a[1], a[2], a[3], "smoke", j, only, None, smoke=True)
    elif a[0] == "report":
        cmd_report(a[1], a[2])
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main(sys.argv[1:])
