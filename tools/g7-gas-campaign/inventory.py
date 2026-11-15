#!/usr/bin/env python3
"""G7-S2: on-chain inventory of pools, tokens and venues for the gas campaign.

Every pool comes from a creation event emitted by a factory / PoolManager that the
repository wires (or from a repo constant, or from the deployed V1 registry), and is
ranked by liquidity measured at a fixed block B_inv. Nothing is taken from model
memory or third-party lists.

Rules encoded here:
  * absent is not zero: an RPC failure is recorded as the string ``rpc_err`` and
    never coerced to 0 (it sorts below every measured value and is never "shallow");
  * getLogs is scanned in adaptive windows (shrink on a range error, grow on
    success) and every window is logged;
  * at most two requests in flight; the RPC key is read from ~/.drpc-key and is
    never printed (errors are scrubbed).

Run with ``python3 -I inventory.py <chain> <outdir>``. Offline tests live in
test_inventory.py.
"""
import json
import os
import random
import re
import sys
import threading
import time
import urllib.error
import urllib.request

RPC_ERR = "rpc_err"

# --------------------------------------------------------------------------- keccak
_RC = [
    0x0000000000000001, 0x0000000000008082, 0x800000000000808A, 0x8000000080008000,
    0x000000000000808B, 0x0000000080000001, 0x8000000080008081, 0x8000000000008009,
    0x000000000000008A, 0x0000000000000088, 0x0000000080008009, 0x000000008000000A,
    0x000000008000808B, 0x800000000000008B, 0x8000000000008089, 0x8000000000008003,
    0x8000000000008002, 0x8000000000000080, 0x000000000000800A, 0x800000008000000A,
    0x8000000080008081, 0x8000000000008080, 0x0000000080000001, 0x8000000080008008,
]
_ROT = [[0, 36, 3, 41, 18], [1, 44, 10, 45, 2], [62, 6, 43, 15, 61],
        [28, 55, 25, 21, 56], [27, 20, 39, 8, 14]]
_M64 = (1 << 64) - 1


def _rol(x, n):
    return ((x << n) | (x >> (64 - n))) & _M64 if n else x


def _keccak_f(a):
    for rc in _RC:
        c = [a[x][0] ^ a[x][1] ^ a[x][2] ^ a[x][3] ^ a[x][4] for x in range(5)]
        d = [c[(x - 1) % 5] ^ _rol(c[(x + 1) % 5], 1) for x in range(5)]
        a = [[a[x][y] ^ d[x] for y in range(5)] for x in range(5)]
        b = [[0] * 5 for _ in range(5)]
        for x in range(5):
            for y in range(5):
                b[y][(2 * x + 3 * y) % 5] = _rol(a[x][y], _ROT[x][y])
        a = [[b[x][y] ^ ((~b[(x + 1) % 5][y]) & b[(x + 2) % 5][y]) for y in range(5)] for x in range(5)]
        a[0][0] ^= rc
    return a


def keccak256(data: bytes) -> bytes:
    rate = 136
    p = bytearray(data) + b"\x01"
    while len(p) % rate:
        p += b"\x00"
    p[-1] |= 0x80
    a = [[0] * 5 for _ in range(5)]
    for off in range(0, len(p), rate):
        blk = p[off:off + rate]
        for i in range(rate // 8):
            a[i % 5][i // 5] ^= int.from_bytes(blk[8 * i:8 * i + 8], "little")
        a = _keccak_f(a)
    out = b"".join(a[i % 5][i // 5].to_bytes(8, "little") for i in range(4))
    return out


def k256hex(data: bytes) -> str:
    return "0x" + keccak256(data).hex()


def topic(sig: str) -> str:
    return k256hex(sig.encode())


def selector(sig: str) -> str:
    return k256hex(sig.encode())[:10]


# --------------------------------------------------------------------------- abi helpers
def w(x):
    """32-byte word (hex, no 0x) for an int / address / bool."""
    if isinstance(x, bool):
        x = int(x)
    if isinstance(x, str):
        x = int(x, 16)
    return format(x & ((1 << 256) - 1), "064x")


def addr_of(word: str) -> str:
    h = word[2:] if word.startswith("0x") else word
    return "0x" + h[-40:].lower()


def u(word: str) -> int:
    h = word[2:] if word.startswith("0x") else word
    return int(h or "0", 16)


def s(word: str, bits: int) -> int:
    v = u(word) & ((1 << bits) - 1)
    return v - (1 << bits) if v >> (bits - 1) else v


def words(data: str):
    h = data[2:] if data.startswith("0x") else data
    return [h[i:i + 64] for i in range(0, len(h), 64)]


def checksum(a: str) -> str:
    a = a.lower().replace("0x", "")
    hh = keccak256(a.encode()).hex()
    return "0x" + "".join(c.upper() if int(hh[i], 16) >= 8 else c for i, c in enumerate(a))


def decode_string(ret: str):
    """ABI string or bytes32 (MKR-style). None when undecodable."""
    h = ret[2:] if ret and ret.startswith("0x") else (ret or "")
    if not h:
        return None
    try:
        if len(h) >= 128 and u(h[:64]) == 32:
            n = u(h[64:128])
            return bytes.fromhex(h[128:128 + 2 * n]).decode("utf-8", "replace")
        if len(h) == 64:
            return bytes.fromhex(h).rstrip(b"\x00").decode("utf-8", "replace")
    except ValueError:
        return None
    return None


# --------------------------------------------------------------------------- events
# Signatures are not written anywhere in the repo, so each one is confirmed on a real
# log (decode, then the factory's getPool/getPair or the V4 poolId must reproduce it);
# see S2.md "Topics".
EVENTS = {
    "v3": "PoolCreated(address,address,uint24,int24,address)",
    "v2": "PairCreated(address,address,address,uint256)",
    "solidly": "PoolCreated(address,address,bool,address,uint256)",
    "cl": "PoolCreated(address,address,int24,address)",
    "algebra": "Pool(address,address,address)",
    "algebra_custom": "CustomPool(address,address,address,address)",
    "v4": "Initialize(bytes32,address,address,uint24,int24,address,uint160,int24)",
    "lb": "LBPairCreated(address,address,uint256,address,uint256)",
    "inf_cl": "Initialize(bytes32,address,address,address,uint24,bytes32,uint160,int24)",
    "inf_bin": "Initialize(bytes32,address,address,address,uint24,bytes32,uint24)",
}
TOPICS = {k: topic(v) for k, v in EVENTS.items()}


def decode_log(kind: str, log: dict) -> dict:
    """Decode a creation log into a uniform record. Raises on a malformed log."""
    t = log["topics"]
    d = words(log.get("data", "0x"))
    if t[0].lower() != TOPICS[kind]:
        raise ValueError("topic mismatch for " + kind)
    r = {"block": int(log["blockNumber"], 16), "fee": "", "tick_spacing": "", "hooks": "",
         "pool_id": ""}
    if kind == "v3":
        r.update(token0=addr_of(t[1]), token1=addr_of(t[2]), fee=u(t[3]),
                 tick_spacing=s(d[0], 24), pool=addr_of(d[1]))
    elif kind in ("v2",):
        r.update(token0=addr_of(t[1]), token1=addr_of(t[2]), pool=addr_of(d[0]))
    elif kind == "solidly":
        r.update(token0=addr_of(t[1]), token1=addr_of(t[2]), stable=bool(u(t[3])),
                 pool=addr_of(d[0]))
    elif kind == "cl":
        r.update(token0=addr_of(t[1]), token1=addr_of(t[2]), tick_spacing=s(t[3], 24),
                 pool=addr_of(d[0]))
    elif kind == "algebra":
        r.update(token0=addr_of(t[1]), token1=addr_of(t[2]), pool=addr_of(d[0]))
    elif kind == "algebra_custom":
        r.update(deployer=addr_of(t[1]), token0=addr_of(t[2]), token1=addr_of(t[3]),
                 pool=addr_of(d[0]))
    elif kind == "v4":
        r.update(pool_id="0x" + t[1][2:].lower(), token0=addr_of(t[2]), token1=addr_of(t[3]),
                 fee=u(d[0]), tick_spacing=s(d[1], 24), hooks=addr_of(d[2]), pool="0x" + t[1][2:].lower())
    elif kind == "lb":
        r.update(token0=addr_of(t[1]), token1=addr_of(t[2]), bin_step=u(t[3]),
                 tick_spacing=u(t[3]), pool=addr_of(d[0]))
    elif kind == "inf_cl":
        r.update(pool_id="0x" + t[1][2:].lower(), token0=addr_of(t[2]), token1=addr_of(t[3]),
                 hooks=addr_of(d[0]), fee=u(d[1]), params="0x" + d[2],
                 tick_spacing=s(w((u(d[2]) >> 16) & 0xFFFFFF), 24),
                 pool="0x" + t[1][2:].lower())
    elif kind == "inf_bin":
        r.update(pool_id="0x" + t[1][2:].lower(), token0=addr_of(t[2]), token1=addr_of(t[3]),
                 hooks=addr_of(d[0]), fee=u(d[1]), params="0x" + d[2],
                 tick_spacing=(u(d[2]) >> 16) & 0xFFFF, pool="0x" + t[1][2:].lower())
    else:
        raise ValueError("unknown kind " + kind)
    return r


def v4_pool_id(c0, c1, fee, ts, hooks) -> str:
    return k256hex(bytes.fromhex(w(c0) + w(c1) + w(fee) + w(ts) + w(hooks)))


# --------------------------------------------------------------------------- rpc
class RpcError(Exception):
    pass


class Rpc:
    """JSON-RPC over urllib, <=2 in flight, retries with backoff, key never surfaced."""
    _sem = threading.Semaphore(2)

    def __init__(self, chain, key=None, timeout=40, transport=None):
        self.chain = chain
        if transport is None:
            key = key or open(os.path.expanduser("~/.drpc-key")).read().strip()
            self._key = key
            self._url = "https://lb.drpc.live/%s/%s" % (chain, key)
        else:
            self._key = "\x00nokey"
            self._url = None
        self.timeout = timeout
        self.transport = transport
        self.calls = 0

    def scrub(self, msg):
        return str(msg).replace(self._key, "<KEY>")

    def _post(self, payload):
        if self.transport:
            return self.transport(payload)
        req = urllib.request.Request(self._url, data=json.dumps(payload).encode(),
                                     headers={"Content-Type": "application/json",
                                              "User-Agent": "g7-inventory"})
        with self._sem:
            with urllib.request.urlopen(req, timeout=self.timeout) as r:
                return json.loads(r.read())

    def call(self, method, params, retries=5):
        last = None
        for i in range(retries):
            self.calls += 1
            try:
                res = self._post({"jsonrpc": "2.0", "id": 1, "method": method, "params": params})
            except (urllib.error.URLError, TimeoutError, OSError, ValueError) as e:
                last = self.scrub(e)
                time.sleep(min(20, 0.7 * 2 ** i) + random.random() * 0.3)
                continue
            if "error" in res:
                msg = self.scrub(json.dumps(res["error"]))
                if method == "eth_getLogs" or "execution reverted" in msg or "revert" in msg.lower():
                    raise RpcError(msg)
                last = msg
                time.sleep(min(20, 0.7 * 2 ** i) + random.random() * 0.3)
                continue
            return res.get("result")
        raise RpcError(self.scrub(last))

    # convenience
    def eth_call(self, to, data, block):
        return self.call("eth_call", [{"to": to, "data": data}, hex(block) if isinstance(block, int) else block])

    def try_call(self, to, data, block):
        """eth_call result hex, or RPC_ERR. A revert returns the string 'revert'."""
        try:
            return self.eth_call(to, data, block)
        except RpcError as e:
            return "revert" if "revert" in str(e).lower() else RPC_ERR


# --------------------------------------------------------------------------- getLogs
RANGE_ERR = re.compile(r"(range|too many|limit|exceed|10000|block range|query returned more|"
                       r"response size|timeout|max|HTTP Error 5|413)", re.I)


def scan_logs(rpc, emitter, topic0, start, end, log_rows, window=10000, min_window=50,
              max_window=500000, max_logs=None, newest_first=False):
    """Adaptive getLogs over [start, end]. Shrinks on a range/size error, grows x2 on a
    success. Every window is appended to log_rows as
    (chain, emitter, topic, from, to, n_logs, status). Returns (logs, covered_ranges).
    A window that keeps failing at min_window is recorded as rpc_err and skipped; the
    caller sees it in covered_ranges as missing (absent is not zero)."""
    out, covered = [], []
    cur_end = end
    cur = start
    while (cur <= end) if not newest_first else (cur_end >= start):
        if newest_first:
            lo, hi = max(start, cur_end - window + 1), cur_end
        else:
            lo, hi = cur, min(end, cur + window - 1)
        flt = {"address": emitter, "fromBlock": hex(lo), "toBlock": hex(hi)}
        if topic0:
            flt["topics"] = [topic0]
        try:
            logs = rpc.call("eth_getLogs", [flt], retries=3)
        except RpcError as e:
            msg = str(e)
            if window > min_window and RANGE_ERR.search(msg):
                log_rows.append((rpc.chain, emitter, topic0 or "*", lo, hi, "", "shrink"))
                window = max(min_window, window // 4)
                continue
            log_rows.append((rpc.chain, emitter, topic0 or "*", lo, hi, "", RPC_ERR))
            if newest_first:
                cur_end = lo - 1
            else:
                cur = hi + 1
            continue
        logs = logs or []
        log_rows.append((rpc.chain, emitter, topic0 or "*", lo, hi, len(logs), "ok"))
        covered.append((lo, hi))
        out.extend(logs)
        if max_logs and len(out) >= max_logs:
            break
        if newest_first:
            cur_end = lo - 1
        else:
            cur = hi + 1
        window = min(max_window, window * 2)
    return out, covered


# --------------------------------------------------------------------------- measurement
SEL = {
    "balanceOf": selector("balanceOf(address)"),
    "liquidity": selector("liquidity()"),
    "slot0": selector("slot0()"),
    "getReserves": selector("getReserves()"),
    "symbol": selector("symbol()"),
    "decimals": selector("decimals()"),
    "token0": selector("token0()"),
    "token1": selector("token1()"),
    "extsload": selector("extsload(bytes32)"),
    "getPool3": selector("getPool(address,address,uint24)"),
    "getPoolCl": selector("getPool(address,address,int24)"),
    "getPair": selector("getPair(address,address)"),
    "getPoolS": selector("getPool(address,address,bool)"),
    "poolByPair": selector("poolByPair(address,address)"),
    "customPoolByPair": selector("customPoolByPair(address,address,address)"),
    "getLiquidity": selector("getLiquidity(bytes32)"),
    "getSlot0": selector("getSlot0(bytes32)"),
    "getReservesLB": selector("getReserves()"),
    "getActiveId": selector("getActiveId()"),
    "poolIdToPoolKey": selector("poolIdToPoolKey(bytes32)"),
    "globalState": selector("globalState()"),
}
V4_POOLS_SLOT = 6        # v4-core StateLibrary.POOLS_SLOT
V4_LIQ_OFFSET = 3        # v4-core StateLibrary.LIQUIDITY_OFFSET


def v4_state_slot(pool_id: str) -> int:
    return int.from_bytes(keccak256(bytes.fromhex(w(pool_id) + w(V4_POOLS_SLOT))), "big")


def as_int(ret):
    """eth_call result -> int; RPC_ERR / revert / empty propagate as RPC_ERR or None."""
    if ret == RPC_ERR:
        return RPC_ERR
    if ret in (None, "revert") or ret == "0x":
        return None
    return u(ret[2:66])


def _virtual(out):
    """In-range virtual reserves from L and sqrtP (x = L*2^96/sqrtP, y = L*sqrtP/2^96).
    Depth at the current price, not TVL; absent L or price stays absent."""
    lq, sp = out["liq"], out["sqrtp"]
    if lq == RPC_ERR:
        out["bal0"] = out["bal1"] = RPC_ERR
    elif isinstance(lq, int) and sp:
        out["bal0"], out["bal1"] = (lq << 96) // sp, (lq * sp) >> 96


def measure_pool(rpc, fam, rec, block, pm=None):
    """bal0, bal1, liquidity_raw, sqrtPriceX96 (or None). Absent stays absent."""
    p, t0, t1 = rec["pool"], rec["token0"], rec["token1"]
    out = {"bal0": "", "bal1": "", "liq": "", "sqrtp": None, "liq_method": ""}
    if fam in ("v4", "v4native"):
        sl = v4_state_slot(rec["pool_id"])
        s0 = as_int(rpc.try_call(pm, SEL["extsload"] + w(sl), block))
        lq = as_int(rpc.try_call(pm, SEL["extsload"] + w(sl + V4_LIQ_OFFSET), block))
        out["liq"] = RPC_ERR if lq == RPC_ERR else ("" if lq is None else lq & ((1 << 128) - 1))
        out["sqrtp"] = None if s0 in (RPC_ERR, None) else s0 & ((1 << 160) - 1)
        out["liq_method"] = "extsload(keccak(id,6)+3);bal=virtual(L,sqrtP)"
        _virtual(out)
        return out
    if fam in ("inf_cl", "inf_bin"):
        if fam == "inf_cl":
            lq = as_int(rpc.try_call(pm, SEL["getLiquidity"] + w(rec["pool_id"]), block))
            s0 = as_int(rpc.try_call(pm, SEL["getSlot0"] + w(rec["pool_id"]), block))
            out["liq"] = RPC_ERR if lq == RPC_ERR else ("" if lq is None else lq)
            out["sqrtp"] = None if s0 in (RPC_ERR, None) else s0
            out["liq_method"] = "CLPoolManager.getLiquidity(id);bal=virtual(L,sqrtP)"
            _virtual(out)
        else:
            a = as_int(rpc.try_call(pm, SEL["getSlot0"] + w(rec["pool_id"]), block))
            if a == RPC_ERR:
                out["bal0"] = out["bal1"] = RPC_ERR
            elif isinstance(a, int):
                r = rpc.try_call(pm, selector("getBin(bytes32,uint24)") + w(rec["pool_id"]) + w(a & 0xFFFFFF), block)
                if r == RPC_ERR:
                    out["bal0"] = out["bal1"] = RPC_ERR
                elif r not in ("revert", None, "0x"):
                    d = words(r)
                    out["bal0"], out["bal1"], out["liq"] = u(d[0]), u(d[1]), u(d[2])
            out["liq_method"] = "BinPoolManager.getBin(id,activeId):active-bin reserves"
        return out
    for i, t in ((0, t0), (1, t1)):
        if t == "0x" + "0" * 40:
            try:
                out["bal%d" % i] = u(rpc.call("eth_getBalance", [p, hex(block)]))
            except RpcError:
                out["bal%d" % i] = RPC_ERR
            continue
        v = as_int(rpc.try_call(t, SEL["balanceOf"] + w(p), block))
        out["bal%d" % i] = RPC_ERR if v == RPC_ERR else ("" if v is None else v)
    if fam in ("v3", "cl", "algebra", "algebra_integral", "pharaoh"):
        lq = as_int(rpc.try_call(p, SEL["liquidity"], block))
        out["liq"] = RPC_ERR if lq == RPC_ERR else ("" if lq is None else lq)
        out["liq_method"] = "pool.liquidity()"
        sel = SEL["globalState"] if fam.startswith("algebra") else SEL["slot0"]
        s0 = as_int(rpc.try_call(p, sel, block))
        out["sqrtp"] = None if s0 in (RPC_ERR, None) else s0 & ((1 << 160) - 1)
    return out


# --------------------------------------------------------------------------- pricing / rank / class
def mid_from_sqrtp(sqrtp, dec0, dec1):
    """price of token0 in token1 units (human)."""
    if not sqrtp:
        return None
    return (sqrtp / 2 ** 96) ** 2 * 10 ** (dec0 - dec1)


def mid_from_balances(b0, b1, dec0, dec1):
    if not isinstance(b0, int) or not isinstance(b1, int) or b0 == 0 or b1 == 0:
        return None
    return (b1 / 10 ** dec1) / (b0 / 10 ** dec0)


# liq_usd is the token balances, not liquidity in range: build_spec.py active_b0 filters
# the concentrated-liquidity candidates (a balance is not depth).
def liq_usd(row, prices, decs):
    """USD (numeraire) value of the sides whose token has a measured price; sides with an
    unpriced token add nothing (lower bound). Empty when no side is priced or a priced
    side is absent (rpc_err / missing): absent is not zero."""
    tot, priced = 0.0, False
    for side in (0, 1):
        t = row["token%d" % side]
        if t not in prices:
            continue
        b = row["bal%d" % side]
        if not isinstance(b, int):
            return ""
        priced = True
        tot += b / 10 ** decs[t] * prices[t]
    return round(tot, 2) if priced else ""


def rank_key(row):
    """Sort key, deepest first. Measured USD > measured raw > absent. rpc_err never
    ranks as zero: it sorts after every measured row, including true zeros."""
    v = row.get("liq_usd", "")
    if isinstance(v, (int, float)):
        return (0, -float(v))
    lq = row.get("liquidity_raw", "")
    if isinstance(lq, int):
        return (1, -lq)
    return (2, 0)


def is_measured_positive(row):
    """Both balances measured and > 0 (or, for V4-like, liquidity measured > 0)."""
    if row["family"] in ("v4", "v4native", "inf_cl", "inf_bin"):
        lq = row.get("liquidity_raw")
        return isinstance(lq, int) and lq > 0
    return all(isinstance(row["bal%d" % i], int) and row["bal%d" % i] > 0 for i in (0, 1))


FEE_HIGH = 10000   # >= 1.00 %  (V3-style pips)
FEE_LOW = 100      # <= 0.01 %


def classify(rows, majors, midtail, shallow_usd=1000.0, n_shallow=3):
    """Adds row['class'] (comma list). majors: set of frozenset({a,b}); midtail: set of
    tokens. shallow = measured >0 but below shallow_usd (or the n_shallow lowest
    measured-positive when no USD), never an rpc_err or a zero row."""
    fam_best = {}
    for r in rows:
        r["_cls"] = []
        pair = frozenset((r["token0"], r["token1"]))
        if pair in majors:
            r["_cls"].append("major")
        if r["token0"] in midtail or r["token1"] in midtail:
            r["_cls"].append("midtail")
        f = r.get("fee")
        if isinstance(f, int) and r["family"] not in ("v2", "solidly", "lb", "inf_bin"):
            if f >= FEE_HIGH and f != 0x800000:
                r["_cls"].append("fee_high")
            elif f <= FEE_LOW:
                r["_cls"].append("fee_low")
        key = (r["family"], r["factory"])
        if is_measured_positive(r) and (key not in fam_best or rank_key(r) < rank_key(fam_best[key])):
            fam_best[key] = r
    for r in fam_best.values():
        r["_cls"].append("family_rep")
    pos = [r for r in rows if is_measured_positive(r)]
    usd = [r for r in pos if isinstance(r.get("liq_usd"), (int, float))]
    sh = [r for r in usd if r["liq_usd"] < shallow_usd]
    if not sh:
        sh = sorted(pos, key=rank_key)[-n_shallow:] if pos else []
    for r in sh[:max(n_shallow, len(sh))]:
        if "shallow" not in r["_cls"]:
            r["_cls"].append("shallow")
    for r in rows:
        r["class"] = ",".join(r.pop("_cls"))
    return rows


# Families with a Gate adapter (src/adapters/ at 2e4fdaa; + LB, AlgebraIntegral on
# avax-adapters-1106; + InfinityCL, InfinityBin on bsc-infinity-1106). gate_top3 is marked
# only there: top 3 per chain x family by rank_key, measured rows only.
GATE_FAMS = {"curve_ng", "curve_crypto_ng", "balancer_v2", "balancer_v3", "lb",
             "algebra_integral", "inf_cl", "inf_bin"}
# liq_usd of these comes from virtual(L, sqrtP): depth at the current price, not TVL.
VIRTUAL_FAMS = {"v4", "v4native", "inf_cl"}
VIRTUAL_LABEL = "liq_virtual_at_price, not TVL"


def gate_eligible(row):
    v = row.get("liq_usd")
    return is_measured_positive(row) or (isinstance(v, float) and v > 0)


def finalize(rows):
    """Label virtual liq_usd and mark gate_top3 (gate families only, <=3 per chain x
    family). Idempotent: an existing gate_top3 is dropped first."""
    groups = {}
    for r in rows:
        r["class"] = ",".join(c for c in str(r.get("class", "")).split(",") if c and c != "gate_top3")
        if r["family"] in VIRTUAL_FAMS and VIRTUAL_LABEL not in str(r.get("liq_method", "")):
            r["liq_method"] = (str(r.get("liq_method", "")) + ";" + VIRTUAL_LABEL).strip(";")
        if r["family"] in GATE_FAMS and gate_eligible(r):
            groups.setdefault((r["chain"], r["family"]), []).append(r)
    for lst in groups.values():
        for r in sorted(lst, key=rank_key)[:3]:
            r["class"] = (r["class"] + ",gate_top3").strip(",")
    return rows


def _num(v):
    """TSV cell -> int / float / str (rpc_err and empty stay strings: absent is not zero)."""
    if re.fullmatch(r"-?\d+", v):
        return int(v)
    try:
        return float(v) if re.fullmatch(r"-?[\d.]+(e[-+]?\d+)?", v) else v
    except ValueError:
        return v


def refinalize_tsv(path):
    """Re-apply finalize() to a written inventory.tsv in place (rows from runs that marked
    gate_top3 in every family)."""
    with open(path) as f:
        lines = f.read().split("\n")
    cols = lines[0].split("\t")
    rows = [dict(zip(cols, ln.split("\t"))) for ln in lines[1:] if ln]
    for r in rows:
        for c in ("bal0", "bal1", "liquidity_raw", "liq_usd"):
            r[c] = _num(r[c])
    finalize(rows)
    os.replace(path, path + ".prev")
    append_tsv(path, cols, rows)
    return rows


# --------------------------------------------------------------------------- tsv
INV_COLS = ["chain", "family", "factory", "pool", "token0", "token1", "fee", "tick_spacing",
            "hooks", "created_block", "code_len", "codehash", "b_inv", "bal0", "bal1",
            "liquidity_raw", "liq_usd", "class", "source", "liq_method", "ref", "note"]
TOK_COLS = ["chain", "token", "symbol", "decimals", "code_len", "source", "ref"]
VEN_COLS = ["chain", "family", "factory_or_manager", "init_code_hash", "code_len", "codehash",
            "source", "on_main"]
SCAN_COLS = ["chain", "emitter", "topic", "from", "to", "n_logs", "status"]


def tsv_clean(v):
    return str(v).replace("\t", " ").replace("\n", " ")


def append_tsv(path, cols, rows):
    new = not os.path.exists(path) or os.path.getsize(path) == 0
    with open(path, "a") as f:
        if new:
            f.write("\t".join(cols) + "\n")
        for r in rows:
            if isinstance(r, dict):
                r = [r.get(c, "") for c in cols]
            f.write("\t".join(tsv_clean(x) for x in r) + "\n")




# =========================================================================== config
# Every address below carries its repo source (file:line). Branch files are read with
# `git show <branch>:<path>`; their source is written "<branch>:<path>:<line>".
BTD, MP, TS = "test/fork/BaseTestDeploy.sol", "test/fork/MultichainProbe.t.sol", "test/fork/TokenSweep.t.sol"
T100B, AF = "test/fork/Top100BaseTokens.sol", "test/fork/AdaptersFork.t.sol"
AVB, BSB = "avax-adapters-1106:test/fork/avax/", "bsc-infinity-1106:test/fork/bsc/"
RHV = "test/fork/RobinhoodV4"
UNIV3_INIT = "0xe34f199b19b2b4f47f68442619d555527d244f78a3297ea89325f843f87b8b54"
V3F = [100, 500, 3000, 10000]
PCKF = [100, 500, 2500, 10000]
CLTS = [1, 50, 100, 200, 2000]
LBSTEPS = [1, 2, 5, 10, 15, 20, 25, 50, 100]
ZERO = "0x" + "0" * 40


def V(fam, addr, src, on_main="yes", init="", **kw):
    d = dict(fam=fam, addr=addr.lower(), src=src, on_main=on_main, init=init)
    d.update(kw)
    return d


CHAINS = {
    "base": dict(
        native=("0x4200000000000000000000000000000000000006", BTD + ":48"),
        num=("0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913", BTD + ":49"),
        roles=dict(lst=[("0xc1CBa3fCea344f92D9239c08C0568f6F2F0ee452", BTD + ":50")]),
        midtail=[("0x88Fb150BDc53A65fe94Dea0c9BA0a6dAf8C6e196", T100B + ":16"),
                 ("0x940181a94A35A4569E4529A3CDfB74e38FD98631", T100B + ":31"),
                 ("0x0b3e328455c4059EEb9e3f84b5543F74E24e7E1b", T100B + ":33"),
                 ("0x4ed4E862860beD51a9570b96d89aF5E1B0Efefed", T100B + ":98"),
                 ("0x532f27101965dd16442E59d40670FaF5eBB142E4", T100B + ":110")],
        venues=[V("v2", "0x8909Dc15e40173Ff4699343b6eB8132c65e18eC6", BTD + ":38"),
                V("v3", "0x33128a8fC17869897dcE68Ed026d694621f6FDfD", BTD + ":39", init=UNIV3_INIT, fees=V3F),
                V("solidly", "0x420DD381b31aEf6683db6B902084cB0FFECe40Da", BTD + ":40"),
                V("v3", "0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865", BTD + ":42", fees=PCKF),
                V("v3", "0xc35DADB65012eC5796536bD9864eD8773aBc74C4", BTD + ":43", fees=V3F),
                V("v2", "0xFDa619b6d20975be80A10332cD39b9a4b0FAa8BB", BTD + ":44"),
                V("v2", "0x71524B4f93c58fcbF659783284E38825f0622859", BTD + ":45"),
                V("cl", "0x5e7BB104d84c7CB9B682AaC2F3d509f5F406809A", BTD + ":46"),
                V("v2", "0x02a84c1b3BBD7401a5f7fa98a384EBC70bB5749E", BTD + ":47")],
        pm=("0x498581fF718922c3f8e6A244956aF099B2652b2b", BTD + ":41"),
        ext=[("curve_ng", "0xd2002373543Ce3527023C75e7518C274A51ce712", "0x3df1658e3E76d14eF3C4d410829EA7575bB83B9B", AF + ":36", AF + ":35"),
             ("curve_ng", "0xd2002373543Ce3527023C75e7518C274A51ce712", "0x63Eb7846642630456707C3efBb50A03c79B89D81", AF + ":37", AF + ":35"),
             ("balancer_v2", "0xBA12222222228d8Ba445958a75a0704d566BF2C8", "0x5332584890d6e415a6dc910254d6430b8aab7e69", AF + ":41", AF + ":39"),
             ("balancer_v3", "0xbA1333333333a1BA1108E8412f11850A5C319bA9", "0x7b4c560f33A71A9f7a500aF3C4c65b46fBBafdB7", AF + ":46", AF + ":43"),
             ("balancer_v3", "0xbA1333333333a1BA1108E8412f11850A5C319bA9", "0x7AB124EC4029316c2A42F713828ddf2a192B36db", AF + ":47", AF + ":43")],
        span=1_500_000),
    "optimism": dict(
        native=("0x4200000000000000000000000000000000000006", MP + ":236"),
        num=("0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85", MP + ":237"),
        roles=dict(lst=[("0x1F32b1c2345538c0c6f582fCB022739c4A194Ebb", MP + ":238")],
                   usdt=[("0x94b008aA00579c1307B0EF2c499aD98a8ce58e58", MP + ":288")],
                   btc=[("0x68f180fcCe6836688e9084f035309E29Bf0A2095", MP + ":290")]),
        midtail=[("0x4200000000000000000000000000000000000042", MP + ":291"),
                 ("0x9560e827aF36c94D2Ac33a39bCE1Fe78631088Db", MP + ":292"),
                 ("0x8700dAec35aF8Ff88c16BdF0418774CB3D7599B4", MP + ":293"),
                 ("0x350a791Bfc2C21F9Ed5d10980Dad2e2638ffa7f6", MP + ":294")],
        venues=[V("v3", "0x1F98431c8aD98523631AE4a59f267346ea31F984", MP + ":229", init=UNIV3_INIT, fees=V3F),
                V("v2", "0x0c3c1c532F1e39EdF36BE9Fe0bE1410313E074Bf", MP + ":230"),
                V("solidly", "0xF1046053aa5682b4F9a81b5481394DA16BE5FF5a", MP + ":233"),
                V("v3", "0x9c6522117e2ed1fE5bdb72bb0eD5E3f2bdE7DBe0", MP + ":234", fees=V3F),
                V("cl", "0xCc0bDDB707055e04e497aB22a59c2aF4391cd12F", TS + ":455"),
                V("solidly", "0x25CbdDb98b35ab1FF77413456B31EC81A6B6B746", TS + ":456"),
                V("v2", "0xFbc12984689e5f15626Bad03Ad60160Fe98B303C", TS + ":459")],
        pm=("0x9a13F98Cb987694C9F086b1F5eB990EeA8264Ec3", MP + ":231"),
        repo_pools=[("0xc1738D90E2E26C35784A0d3E3d8A9f795074bcA4", MP + ":241")],
        span=1_500_000),
    "arbitrum": dict(
        native=("0x82aF49447D8a07e3bd95BD0d56f35241523fBab1", MP + ":318"),
        num=("0xaf88d065e77c8cC2239327C5EDb3A432268e5831", MP + ":319"),
        roles=dict(lst=[("0x5979D7b546E38E414F7E9822514be443A4800529", MP + ":320")],
                   usdt=[("0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9", MP + ":365")],
                   btc=[("0x2f2a2543B76A4166549F7aaB2e75Bef0aefC5B0f", MP + ":367")]),
        midtail=[("0x912CE59144191C1204E64559FE8253a0e49E6548", MP + ":368"),
                 ("0xf97f4df75117a78c1A5a0DBb814Af92458539FB4", MP + ":369"),
                 ("0xfc5A1A6EB076a2C7aD06eD22C90d7E710E35ad0a", MP + ":370"),
                 ("0x0c880f6761F1af8d9Aa9C466984b80DAb9a8c9e8", MP + ":371"),
                 ("0x11cDb42B0EB46D95f990BeDD4695A6e3fA034978", MP + ":372")],
        venues=[V("v3", "0x1F98431c8aD98523631AE4a59f267346ea31F984", MP + ":306", init=UNIV3_INIT, fees=V3F),
                V("v2", "0xf1D7CC64Fb4452F05c498126312eBE29f30Fbcf9", MP + ":307"),
                V("v3", "0x1af415a1EbA07a4986a52B6f2e7dE7003D82231e", MP + ":309", fees=V3F),
                V("v3", "0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865", MP + ":313", fees=PCKF),
                V("v2", "0x6EcCab422D763aC031210895C81787E87B43A652", MP + ":316"),
                V("algebra", "0x1a3c9B1d2F0529D97f2afC5136Cc23e58f1FD35B", TS + ":407"),
                V("v2", "0xc35DADB65012eC5796536bD9864eD8773aBc74C4", TS + ":411")],
        pm=("0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32", MP + ":308"),
        repo_pools=[("0xC6962004f452bE9203591991D15f6b388e09E8D0", MP + ":322")],
        span=8_000_000),
    "robinhood": dict(
        native=("0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73", MP + ":389"),
        num=("0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168", MP + ":390"),
        roles=dict(),
        midtail=[("0x5d3a1Ff2b6BAb83b63cd9AD0787074081a52ef34", MP + ":454"),
                 ("0x020bfC650A365f8BB26819deAAbF3E21291018b4", MP + ":455"),
                 ("0xe934e36A439C94017B64a3FecE66AF12099aBF50", MP + ":456"),
                 ("0x616bcd920e1e1F354750BBaf2FB3b3fa3B4aAE16", RHV + "Derive.t.sol:46"),
                 ("0x6b711B581aDDe09158B5B26Df9ed428cAf8479B1", RHV + "Discovery.t.sol:30"),
                 ("0xe37E4a8b3D14274a3fdE3D841dE65E83E2a943aC", RHV + "Discovery.t.sol:31")],
        venues=[V("v3", "0x1f7d7550B1b028f7571E69A784071F0205FD2EfA", MP + ":385", fees=V3F),
                V("v2", "0x8bcEaA40B9AcdfAedF85AdF4FF01F5Ad6517937f", MP + ":386")],
        pm=("0x8366a39CC670B4001A1121B8F6A443A643e40951", MP + ":387"),
        repo_pools=[("0x52e65B17fB6E5BA00Ed806f37Afcd2DaA50271Ca", MP + ":393")],
        span=8_000_000),
    "avalanche": dict(
        native=("0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7", AVB + "AvaxForkBase.sol:26"),
        num=("0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E", AVB + "AvaxForkBase.sol:27"),
        roles=dict(btc=[("0x152b9d0FdC40C096757F570A51E494bd4b943E50", AVB + "AvaxForkBase.sol:28")],
                   lst=[("0x2b2C81e08f1Af8835a78Bb2A90AE924ACE0eA4bE", AVB + "AvaxS9Battery.t.sol:41")]),
        midtail=[("0x420FcA0121DC28039145009570975747295f2329", AVB + "AvaxS9Battery.t.sol:40"),
                 ("0x6e84a6216eA6dACC71eE8E6b0a5B7322EEbC0fDd", AVB + "AvaxS9Battery.t.sol:42"),
                 ("0xB8d7710f7d8349A506b75dD184F05777c82dAd0C", AVB + "AvaxS9Battery.t.sol:43"),
                 ("0x8729438EB15e2C8B576fCc6AeCdA6A148776C0F5", AVB + "AvaxS9Battery.t.sol:44"),
                 ("0xcd94a87696FAC69Edae3a70fE5725307Ae1c43f6", AVB + "AvaxS9Battery.t.sol:46")],
        venues=[V("v3", "0x740b1c1de25031C31FF4fC9A62f554A55cdC1baD", AVB + "AvaxForkBase.sol:31", "branch:avax-adapters-1106", init=UNIV3_INIT, fees=V3F),
                V("pharaoh", "0xAE6E5c62328ade73ceefD42228528b70c8157D0d", AVB + "AvaxForkBase.sol:37", "branch:avax-adapters-1106",
                  init="0x892f127ed4b26ca352056c8fb54585a3268f76f97fdd84d5836ef4bda8d8c685"),
                V("algebra_integral", "0x512eb749541B7cf294be882D636218c84a5e9E5F", AVB + "AvaxAlgebraIntegral.t.sol:95", "branch:avax-adapters-1106"),
                V("lb", "0x8e42f2F4101563bF679975178e880FD87d3eFd4e", AVB + "AvaxLB.t.sol:82", "branch:avax-adapters-1106"),
                V("lb", "0xb43120c4745967fa9b93E79C149E66B0f2D6Fe0c", AVB + "AvaxLB.t.sol:83", "branch:avax-adapters-1106"),
                V("lb", "0xEb480050b016f6c6d45203D2346B68bDDDa23D4D", AVB + "AvaxLB.t.sol:84", "branch:avax-adapters-1106")],
        repo_pools=[("0xfAe3f424a0a47706811521E3ee268f00cFb5c45E", AVB + "AvaxCoreV3.t.sol:62"),
                    ("0xf01449C0bA930B6e2CaCA3DEF3CCBd7a3E589534", AVB + "AvaxCoreV3.t.sol:63"),
                    ("0x61c48716F6e03229B1e250aeFddF429c48E75165", AVB + "AvaxBlackholeCore.t.sol:92"),
                    ("0x41100C6D2c6920B10d12Cd8D59c8A9AA2eF56fC7", AVB + "AvaxAlgebraIntegral.t.sol:101"),
                    ("0x7789fA308147Eae364e3BCfa35351F2b9E0bd012", AVB + "AvaxAlgebraIntegral.t.sol:105"),
                    ("0xD446eb1660F766d533BeCeEf890Df7A69d26f7d1", AVB + "AvaxLB.t.sol:86"),
                    ("0x864d4e5Ee7318e97483DB7EB0912E09F161516EA", AVB + "AvaxLB.t.sol:87"),
                    ("0x8aC5707f8D4BDe1d771d34c7AfD81c3922b73379", AVB + "AvaxLB.t.sol:88")],
        span=3_000_000),
    "bsc": dict(
        native=("0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c", BSB + "BscForkBase.sol:27"),
        num=("0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d", BSB + "BscForkBase.sol:29"),
        roles=dict(usdt=[("0x55d398326f99059fF775485246999027B3197955", BSB + "BscForkBase.sol:28")]),
        midtail=[("0x0782b6d8c4551B9760e74c0545a9bCD90bdc41E5", BSB + "BscInfinityBinFork.t.sol:22"),
                 ("0x8d0D000Ee44948FC98c9B98A4FA4921476f08B0d", BSB + "BscInfinityBinFork.t.sol:23"),
                 ("0xcE24439F2D9C6a2289F741120FE202248B666666", BSB + "BscInfinityCLFork.t.sol:28"),
                 ("0xA991F61940095AEA0724ef54077223B048c5CF7b", BSB + "BscInfinityCLFork.t.sol:29"),
                 ("0x097acf27503753e77bCA940277806156C5925B81", BSB + "BscInfinityCLFork.t.sol:30")],
        venues=[V("v3", "0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865", BSB + "BscForkBase.sol:32", "branch:bsc-infinity-1106", fees=PCKF),
                V("v3", "0xdB1d10011AD0Ff90774D0C6Bb92e5C5c8b4461F7", BSB + "BscForkBase.sol:33", "branch:bsc-infinity-1106", fees=V3F),
                V("v2", "0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73", BSB + "BscForkBase.sol:34", "branch:bsc-infinity-1106")],
        pm=("0x28e2Ea090877bF75740558f6BFB36A5ffeE9e9dF", BSB + "BscForkBase.sol:36"),
        inf=[("inf_cl", "0xa0FfB9c1CE1Fe56963B0321B32E7A0302114058b", BSB + "BscInfinityCLFork.t.sol:24",
              [("0x1e923c7179135a0c9ff76d0d8b1b75decf58f8a1ef5088320d8e743bdc043d6e", BSB + "BscInfinityCLFork.t.sol:31"),
               ("0xd0949ad5874cee7991ccd4cc2c5f7f80a7be4a220689cf5947ccb12a946fa50d", BSB + "BscInfinityCLFork.t.sol:32"),
               ("0x24993d0e8ef738b3bac36a753c00b39793e416e05db87c2bafbb25c4351b34fd", BSB + "BscInfinityCLFork.t.sol:33")]),
             ("inf_bin", "0xC697d2898e0D09264376196696c51D7aBbbAA4a9", BSB + "BscInfinityBinFork.t.sol:21",
              [("0x87a668dbac7951c7a5ccd91c4c817da7de4f32bdc714c58eacc376eb41b64ee4", BSB + "BscInfinityBinFork.t.sol:26"),
               ("0xa859b22e97f32d4c7b1d9788044697712cb7183d294ed7aa1832799c1739e5cf", BSB + "BscInfinityBinFork.t.sol:27")])],
        repo_pools=[("0x172fcD41E0913e95784454622d1c3724f546f849", BSB + "BscCoveredVenues.t.sol:27"),
                    ("0x36696169C63e42cd08ce11f5deeBbCeBae652050", BSB + "BscCoveredVenues.t.sol:28"),
                    ("0x1401ff943D08a7E098328C1d3a9d388923B115D2", BSB + "BscCoveredVenues.t.sol:29"),
                    ("0x47a90A2d92A8367A91EfA1906bFc8c1E05bf10c4", BSB + "BscCoveredVenues.t.sol:30"),
                    ("0x6fe9E9de56356F7eDBfcBB29FAB7cd69471a4869", BSB + "BscCoveredVenues.t.sol:31"),
                    ("0x7862D9B4bE2156B15d54F41ee4EDE2d5b0b455e4", BSB + "BscCoveredVenues.t.sol:32"),
                    ("0x16b9a82891338f9bA80E2D6970FddA79D1eb0daE", BSB + "BscCoveredVenues.t.sol:33")],
        span=3_000_000),
    "ethereum": dict(
        native=("0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2", "test/fork/RpcProbe.t.sol:18"),
        num=None, roles=dict(), midtail=[],
        v1_router=("0xE1aE5f49013920CF71De8CED4043e14C4d63416b", "test/fork/DeployedParity.t.sol:70"),
        venues=[], span=300_000),
}
FAM_EVENT = {"v2": "v2", "v3": "v3", "solidly": "solidly", "cl": "cl", "algebra": "algebra",
             "algebra_integral": "algebra", "pharaoh": "v3", "lb": "lb", "v4": "v4",
             "inf_cl": "inf_cl", "inf_bin": "inf_bin"}
# V1 Hub row kind -> family (kind numbers: src/BlazePhoenixCore.sol:236-240)
V1_KIND = {0: "v2", 1: "v3", 5: "solidly", 6: "algebra"}


# =========================================================================== driver
from concurrent.futures import ThreadPoolExecutor  # noqa: E402

ROLE_SYMS = {"usdt": {"USDT", "USDT0", "USD₮0", "USD₮", "BSC-USD"},
             "btc": {"WBTC", "CBBTC", "BTCB", "BTC.B", "TBTC", "LBTC"},
             "lst": {"WSTETH", "CBETH", "RETH", "WEETH", "SAVAX", "SLISBNB", "WBETH", "STETH", "BNBX"},
             "num": {"USDC"}}
V4_TIERS = [(100, 1), (500, 10), (3000, 60), (10000, 200)]


def pmap(fn, items):
    with ThreadPoolExecutor(max_workers=2) as ex:
        return list(ex.map(fn, items))


class Ctx:
    def __init__(self, chain, outdir, rpc=None):
        self.chain, self.out = chain, outdir
        self.cfg = CHAINS[chain]
        self.rpc = rpc or Rpc(chain)
        self.scan_rows, self.notes = [], []
        self.pools = {}      # pool(or id) -> row
        self.tok = {}        # token -> (symbol, decimals, code_len, source)
        self.tok_src = {}
        self.ven = []        # venue dicts actually used

    def note(self, msg):
        self.notes.append(msg)
        print("[%s] %s" % (self.chain, msg), flush=True)

    def call(self, to, data):
        return self.rpc.try_call(to, data, self.b)

    def code(self, a, block=None):
        try:
            c = self.rpc.call("eth_getCode", [a, hex(block if block is not None else self.b)])
        except RpcError:
            return RPC_ERR, RPC_ERR
        h = (c or "0x")[2:]
        return len(h) // 2, (k256hex(bytes.fromhex(h)) if h else "")


def sort2(a, b):
    a, b = a.lower(), b.lower()
    return (a, b) if a < b else (b, a)


def lookup(ctx, ven, a, b):
    """Pools of (a, b) on one venue via the venue's own getter. [(pool, extra)]."""
    t0, t1 = sort2(a, b)
    f, out = ven["fam"], []
    qs = []
    if f == "v3":
        qs = [(SEL["getPool3"] + w(t0) + w(t1) + w(x), {"fee": x}) for x in ven.get("fees", V3F)]
    elif f in ("cl", "pharaoh"):
        qs = [(SEL["getPoolCl"] + w(t0) + w(t1) + w(x), {"tick_spacing": x})
              for x in (CLTS if f == "cl" else [1, 5, 10, 50, 100, 200])]
    elif f == "solidly":
        qs = [(SEL["getPoolS"] + w(t0) + w(t1) + w(x), {"stable": x}) for x in (False, True)]
    elif f == "v2":
        qs = [(SEL["getPair"] + w(t0) + w(t1), {})]
    elif f in ("algebra", "algebra_integral"):
        qs = [(SEL["poolByPair"] + w(t0) + w(t1), {})]
    elif f == "lb":
        qs = [(selector("getLBPairInformation(address,address,uint256)") + w(t0) + w(t1) + w(x),
               {"tick_spacing": x, "_w": 1}) for x in LBSTEPS]
    for data, ex in qs:
        r = ctx.call(ven["addr"], data)
        if r in (RPC_ERR, "revert", None) or len(r) < 66:
            continue
        p = addr_of(words(r)[ex.pop("_w", 0)])
        if p != ZERO:
            out.append((p, dict(ex, token0=t0, token1=t1)))
    return out


def v4_lookup(ctx, pm, a, b):
    out = []
    pairs = [sort2(a, b)]
    nat = ctx.cfg["native"][0].lower()
    if a.lower() == nat or b.lower() == nat:
        other = b if a.lower() == nat else a
        pairs.append(sort2(ZERO, other))
    for c0, c1 in pairs:
        for fee, ts in V4_TIERS:
            pid = v4_pool_id(c0, c1, fee, ts, ZERO)
            s0 = as_int(ctx.call(pm, SEL["extsload"] + w(v4_state_slot(pid))))
            if isinstance(s0, int) and s0 & ((1 << 160) - 1):
                out.append((pid, dict(token0=c0, token1=c1, fee=fee, tick_spacing=ts, hooks=ZERO, pool_id=pid)))
    return out


def bisect_first(pred, lo, hi):
    """Smallest block in (lo, hi] where pred(block) is True; pred(hi) must be True.
    Returns RPC_ERR if a probe fails."""
    while hi - lo > 1:
        m = (lo + hi) // 2
        v = pred(m)
        if v == RPC_ERR:
            return RPC_ERR
        if v:
            hi = m
        else:
            lo = m
    return hi


def created_block(ctx, fam, row, pm=None):
    if fam in ("v4", "inf_cl", "inf_bin"):
        def pred(bk):
            if fam == "v4":
                r = ctx.rpc.try_call(pm, SEL["extsload"] + w(v4_state_slot(row["pool_id"])), bk)
            else:
                r = ctx.rpc.try_call(pm, SEL["getSlot0"] + w(row["pool_id"]), bk)
            if r == RPC_ERR:
                return RPC_ERR
            return r not in ("revert", None, "0x") and int(r[2:66] or "0", 16) != 0
    else:
        def pred(bk):
            n, _ = ctx.code(row["pool"], bk)
            return RPC_ERR if n == RPC_ERR else n > 0
    return bisect_first(pred, 0, ctx.b)


def confirm_event(ctx, emitter, kind, blk, row):
    """The creation log at blk that decodes to this pool, or None."""
    flt = {"address": emitter, "fromBlock": hex(blk), "toBlock": hex(blk), "topics": [TOPICS[kind]]}
    if kind in ("v4", "inf_cl", "inf_bin"):
        flt["topics"].append(row["pool_id"])
    try:
        logs = ctx.rpc.call("eth_getLogs", [flt], retries=3)
    except RpcError:
        ctx.scan_rows.append((ctx.chain, emitter, TOPICS[kind], blk, blk, "", RPC_ERR))
        return None
    ctx.scan_rows.append((ctx.chain, emitter, TOPICS[kind], blk, blk, len(logs or []), "ok"))
    for lg in logs or []:
        d = decode_log(kind, lg)
        if d["pool"].lower() == row["pool"].lower():
            return d
    return None


def verify_getter(ctx, fam, emitter, d):
    """Bind a decoded log to the factory's own getter (or the V4 id)."""
    t0, t1 = d["token0"], d["token1"]
    if fam == "v3":
        q = SEL["getPool3"] + w(t0) + w(t1) + w(d["fee"])
    elif fam in ("cl", "pharaoh"):
        q = SEL["getPoolCl"] + w(t0) + w(t1) + w(d["tick_spacing"])
    elif fam == "solidly":
        q = SEL["getPoolS"] + w(t0) + w(t1) + w(d["stable"])
    elif fam == "v2":
        q = SEL["getPair"] + w(t0) + w(t1)
    elif fam in ("algebra", "algebra_integral"):
        q = SEL["poolByPair"] + w(t0) + w(t1)
    elif fam == "lb":
        r = ctx.call(emitter, selector("getLBPairInformation(address,address,uint256)") + w(t0) + w(t1) + w(d["bin_step"]))
        return r not in (RPC_ERR, "revert", None) and addr_of(words(r)[1]) == d["pool"]
    elif fam == "v4":
        return v4_pool_id(t0, t1, d["fee"], d["tick_spacing"], d["hooks"]) == d["pool_id"]
    elif fam in ("inf_cl", "inf_bin"):
        r = ctx.call(emitter, SEL["poolIdToPoolKey"] + w(d["pool_id"]))
        return r not in (RPC_ERR, "revert", None) and addr_of(words(r)[0]) == t0 and addr_of(words(r)[1]) == t1
    else:
        return False
    r = ctx.call(emitter, q)
    return r not in (RPC_ERR, "revert", None) and addr_of(r) == d["pool"]


def mk_row(ctx, fam, factory, rec, source):
    r = {c: "" for c in INV_COLS}
    r.update(chain=ctx.chain, family=fam, factory=factory.lower(), b_inv=ctx.b, source=source)
    for k in ("pool", "token0", "token1", "fee", "tick_spacing", "hooks", "pool_id"):
        if k in rec and rec[k] != "":
            r[k] = rec[k] if not isinstance(rec[k], str) else rec[k].lower()
    if "stable" in rec and fam == "solidly":
        r["tick_spacing"] = "stable" if rec["stable"] else "volatile"
    if "block" in rec:
        r["created_block"] = rec["block"]
    return r


def scan_emitter(ctx, fam, emitter, max_logs=15):
    kind = FAM_EVENT[fam]
    logs, cov = scan_logs(ctx.rpc, emitter, TOPICS[kind], max(0, ctx.b - ctx.cfg["span"]), ctx.b,
                          ctx.scan_rows, window=20000, max_window=1_000_000, max_logs=max_logs,
                          newest_first=True)
    ctx.scan_rows.append((ctx.chain, emitter, TOPICS[kind], max(0, ctx.b - ctx.cfg["span"]), ctx.b,
                          len(logs), "summary"))
    recs = []
    for lg in logs[:max_logs]:
        try:
            recs.append(decode_log(kind, lg))
        except (ValueError, IndexError):
            ctx.note("undecodable log %s on %s" % (lg.get("transactionHash", "?"), emitter))
    if recs:
        ok = verify_getter(ctx, fam, emitter, recs[0])
        ctx.note("topic %s %s on %s: %d logs, getter-bound=%s (pool %s blk %s)"
                 % (kind, TOPICS[kind][:10], emitter, len(recs), ok, recs[0]["pool"], recs[0]["block"]))
        if not ok:
            return []
    else:
        smp, _ = scan_logs(ctx.rpc, emitter, None, max(0, ctx.b - 200000), ctx.b, ctx.scan_rows,
                           window=5000, max_window=50000, max_logs=5, newest_first=True)
        ctx.note("NO %s logs on %s in [%d,%d]; topic0 seen unfiltered: %s"
                 % (kind, emitter, ctx.b - ctx.cfg["span"], ctx.b, sorted({x["topics"][0][:10] for x in smp})))
    return [mk_row(ctx, fam, emitter, d, "event:%s@%d-%d" % (TOPICS[kind], d["block"], d["block"])) for d in recs]


# =========================================================================== driver part 2
import subprocess  # noqa: E402

V3LIKE = ("v3", "cl", "pharaoh", "algebra", "algebra_integral", "v4", "v4native", "inf_cl")
V1_HUB_SIGS = {"hub": selector("hub()"), "bridgeCount": selector("bridgeCount()"),
               "bridge": selector("bridge(uint256)"), "v4pm": selector("v4PoolManager()")}
FACTORY_EV = topic("Factory_(address,uint8,uint8)")   # src/BlazePhoenixHub.sol:396
OLD_SCAN = 1500       # oldest creation logs per venue for role / midtail discovery
NEW_SCAN = 15


def ref_label(chain):
    repo = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))

    def sha(r):
        try:
            return subprocess.run(["git", "-C", repo, "rev-parse", "--short", r],
                                  capture_output=True, text=True).stdout.strip() or "?"
        except OSError:
            return "?"
    if chain == "avalanche":
        return "branch avax-adapters-1106@%s (src/ = avax-adapters-1103@%s), not main" % (
            sha("avax-adapters-1106"), sha("avax-adapters-1103"))
    if chain == "bsc":
        return "branch bsc-infinity-1106@%s, not main" % sha("bsc-infinity-1106")
    if chain == "ethereum":
        return "main@%s; venues of the deployed V1 registry" % sha("origin/main")
    return "main@%s" % sha("origin/main")


def tok_info(ctx, t, src=""):
    t = t.lower()
    if t in ctx.tok:
        if src and not ctx.tok[t][3]:
            ctx.tok[t] = ctx.tok[t][:3] + (src,)
        return ctx.tok[t]
    if t == ZERO:
        info = ("NATIVE", 18, 0, src or "native-currency(0x0)")
    else:
        r = ctx.call(t, SEL["symbol"])
        sym = RPC_ERR if r == RPC_ERR else (decode_string(r) if r not in ("revert", None) else None)
        dec = as_int(ctx.call(t, SEL["decimals"]))
        n, _ = ctx.code(t)
        info = ("" if sym is None else sym, dec if dec is not None else "", n, src)
    ctx.tok[t] = info
    return info


def dec_of(ctx, t):
    d = tok_info(ctx, t)[1]
    return d if isinstance(d, int) else None


def creation_block_of(ctx, a):
    return bisect_first(lambda bk: (lambda n: RPC_ERR if n == RPC_ERR else n > 0)(ctx.code(a, bk)[0]), 0, ctx.b)


def oldest_tokens(ctx, ven, emitter, kind):
    """Tokens of the oldest OLD_SCAN creation logs of a venue (role/midtail discovery)."""
    c0 = creation_block_of(ctx, emitter)
    if c0 == RPC_ERR:
        ctx.note("creation block of %s: rpc_err" % emitter)
        return []
    logs, _ = scan_logs(ctx.rpc, emitter, TOPICS[kind], max(0, c0 - 1), ctx.b, ctx.scan_rows,
                        window=20000, max_window=1_000_000, max_logs=OLD_SCAN)
    ctx.scan_rows.append((ctx.chain, emitter, TOPICS[kind], c0, ctx.b, len(logs), "summary-oldest"))
    out = []
    for lg in logs:
        try:
            d = decode_log(kind, lg)
        except (ValueError, IndexError, KeyError):
            continue
        out += [(d["token0"], d["block"], emitter), (d["token1"], d["block"], emitter)]
    return out


def native_depth(ctx, t, venues):
    """Native balance held by t's getter pools with native (score for role choice)."""
    nat = ctx.cfg["native"][0].lower()
    tot = 0
    for v in venues:
        if v["fam"] not in ("v2", "v3", "solidly", "cl", "pharaoh", "algebra", "algebra_integral"):
            continue
        for p, _ in lookup(ctx, v, t, nat):
            b = as_int(ctx.call(nat, SEL["balanceOf"] + w(p)))
            if isinstance(b, int):
                tot += b
    return tot


def discover_roles(ctx, venues):
    """Fill roles (and num/midtail on ethereum) the repo does not wire, by on-chain symbol
    over tokens of the oldest creation logs; candidate with the most native in getter pools."""
    cfg = ctx.cfg
    want = [r for r in ("usdt", "btc", "lst") if not cfg["roles"].get(r)]
    if cfg.get("num") is None:
        want = ["num"] + want
    need_mid = not cfg["midtail"]
    if not want and not need_mid:
        return
    seen = {}
    for v in venues:
        if v["fam"] in ("v2", "v3", "cl", "solidly", "algebra", "algebra_integral", "pharaoh", "lb"):
            for t, blk, em in oldest_tokens(ctx, v, v["addr"], FAM_EVENT[v["fam"]]):
                seen.setdefault(t, [0, blk, em])[0] += 1
    cands = [t for t, x in seen.items() if x[0] >= 3]
    ctx.note("discovery: %d tokens in oldest logs, %d with >=3 pools" % (len(seen), len(cands)))
    syms = dict(zip(cands, pmap(lambda t: tok_info(ctx, t)[0], cands)))
    known = {cfg["native"][0].lower()} | ({cfg["num"][0].lower()} if cfg.get("num") else set())
    for r, lst in cfg["roles"].items():
        known |= {a.lower() for a, _ in lst}
    for role in want:
        cs = [t for t in cands if isinstance(syms[t], str) and syms[t].upper() in ROLE_SYMS[role]]
        if not cs:
            ctx.note("role %s: no candidate by symbol among %d tokens [inferred: absent, not zero]" % (role, len(cands)))
            continue
        sc = pmap(lambda t: native_depth(ctx, t, venues), cs)
        best = max(zip(sc, cs))
        x = seen[best[1]]
        src = "derived:symbol=%s,max-native-depth(%s);first-seen event:%s@%d" % (
            syms[best[1]], ",".join("%s=%d" % (c[:10], s_) for s_, c in zip(sc, cs)), x[2], x[1])
        if role == "num":
            cfg["num"] = (best[1], src)
        else:
            cfg["roles"][role] = [(best[1], src)]
        known.add(best[1])
        ctx.note("role %s -> %s (%s)" % (role, best[1], syms[best[1]]))
    if need_mid:
        rest = [t for t in sorted(cands, key=lambda t: -seen[t][0])[:60] if t not in known]
        sc = pmap(lambda t: native_depth(ctx, t, venues), rest)
        ranked = [t for s_, t in sorted(zip(sc, rest), reverse=True) if s_ > 0]
        mid = ranked[5:10]       # mid tail: ranks 6-10 by native depth, not the top 5
        cfg["midtail"] = [(t, "derived:native-depth rank %d of %d; first-seen event:%s@%d"
                           % (ranked.index(t) + 1, len(ranked), seen[t][2], seen[t][1])) for t in mid]
        ctx.note("midtail -> %s" % [syms.get(t) for t in mid])


def eth_venues(ctx):
    """Ethereum: factories from the deployed V1 Hub (Factory_ events) + its v4 PoolManager."""
    rt, rsrc = ctx.cfg["v1_router"]
    hub = as_int(ctx.call(rt, V1_HUB_SIGS["hub"]))
    if not isinstance(hub, int):
        ctx.note("router.hub(): %s" % hub)
        return []
    hub = addr_of(w(hub))
    c0 = creation_block_of(ctx, hub)
    logs, _ = scan_logs(ctx.rpc, hub, FACTORY_EV, c0, ctx.b, ctx.scan_rows, window=50000,
                        max_window=1_000_000)
    vs = []
    for lg in logs:
        ws_ = [x[2:] for x in lg["topics"][1:]] + words(lg["data"])
        fac, kind, mode = addr_of(ws_[0]), u(ws_[1]), u(ws_[2])
        fam = V1_KIND.get(kind)
        src = "v1reg:%s Factory_@%d (hub from %s.hub() %s)" % (hub, int(lg["blockNumber"], 16), rt, rsrc)
        if fam:
            vs.append(V(fam, fac, src, "v1-deployed", fees=sorted(set(V3F + PCKF)), mode=mode))
        else:
            ctx.note("v1 factory %s kind %d mode %d: no family map" % (fac, kind, mode))
    pm = as_int(ctx.call(hub, V1_HUB_SIGS["v4pm"]))
    if isinstance(pm, int) and pm:
        ctx.cfg["pm"] = (addr_of(w(pm)), "v1reg:%s.v4PoolManager()" % hub)
    n = as_int(ctx.call(hub, V1_HUB_SIGS["bridgeCount"]))
    for i in range(n if isinstance(n, int) else 0):
        bt = as_int(ctx.call(hub, V1_HUB_SIGS["bridge"] + w(i)))
        if isinstance(bt, int):
            tok_info(ctx, addr_of(w(bt)), "v1reg:%s.bridge(%d)" % (hub, i))
    ctx.note("v1 hub %s: %d factories, pm %s" % (hub, len(vs), ctx.cfg.get("pm")))
    return vs


def repo_pool_row(ctx, p, src, fam_by_addr):
    """Repo-cited pool: family from its factory() (or getFactory for LB) matched to a venue."""
    t0 = as_int(ctx.call(p, SEL["token0"]))
    t1 = as_int(ctx.call(p, SEL["token1"]))
    if not isinstance(t0, int):
        t0 = as_int(ctx.call(p, selector("getTokenX()")))
        t1 = as_int(ctx.call(p, selector("getTokenY()")))
    fac = as_int(ctx.call(p, selector("factory()")))
    if not isinstance(fac, int):
        fac = as_int(ctx.call(p, selector("getFactory()")))
    fac = addr_of(w(fac)) if isinstance(fac, int) else ""
    fam = fam_by_addr.get(fac)
    note = ""
    if not fam:
        if as_int(ctx.call(p, SEL["globalState"])) not in (None, RPC_ERR):
            fam = "algebra"
        elif as_int(ctx.call(p, SEL["slot0"])) not in (None, RPC_ERR):
            fam = "v3"
        elif as_int(ctx.call(p, SEL["getReserves"])) not in (None, RPC_ERR):
            fam = "v2"
        else:
            fam = "unknown"
        note = "factory %s not a repo venue; family by probe" % (fac or "?")
    if not isinstance(t0, int) or not isinstance(t1, int):
        return None
    r = mk_row(ctx, fam, fac or "", dict(pool=p, token0=addr_of(w(t0)), token1=addr_of(w(t1))), "repo:" + src)
    fee = as_int(ctx.call(p, selector("fee()")))
    if isinstance(fee, int) and fam in V3LIKE:
        r["fee"] = fee
    r["note"] = note
    return r


def ext_rows(ctx):
    """Base external venues (Curve NG, Balancer V2/V3) from test/fork/AdaptersFork.t.sol."""
    out = []
    for fam, vault, pool, src, vsrc in ctx.cfg.get("ext", []):
        toks, bals, meth = [], [], ""
        if fam == "curve_ng":
            for i in range(8):
                c = ctx.call(pool, selector("coins(uint256)") + w(i))
                if c in (RPC_ERR, "revert", None, "0x"):
                    break
                toks.append(addr_of(c))
                bals.append(as_int(ctx.call(pool, selector("balances(uint256)") + w(i))))
            meth = "pool.balances(i)"
        elif fam == "balancer_v2":
            pid = ctx.call(pool, selector("getPoolId()"))
            r = ctx.call(vault, selector("getPoolTokens(bytes32)") + (pid[2:66] if pid not in (RPC_ERR, "revert", None) else "0" * 64))
            if r not in (RPC_ERR, "revert", None, "0x"):
                d = words(r)
                a0, a1 = u(d[0]) // 32, u(d[1]) // 32
                n = u(d[a0])
                toks = [addr_of(d[a0 + 1 + i]) for i in range(n)]
                bals = [u(d[a1 + 1 + i]) for i in range(u(d[a1]))]
            meth = "vault.getPoolTokens(poolId)"
        elif fam == "balancer_v3":
            r = ctx.call(vault, selector("getPoolTokens(address)") + w(pool))
            q = ctx.call(vault, selector("getCurrentLiveBalances(address)") + w(pool))
            if r not in (RPC_ERR, "revert", None, "0x"):
                d = words(r)
                toks = [addr_of(d[2 + i]) for i in range(u(d[1]))]
            if q not in (RPC_ERR, "revert", None, "0x"):
                d = words(q)
                bals = [("s18", u(d[2 + i])) for i in range(u(d[1]))]
            meth = "vault.getCurrentLiveBalances(pool):scaled18"
        if len(toks) < 2:
            ctx.note("ext %s %s: tokens unreadable" % (fam, pool))
            continue
        r = mk_row(ctx, fam, vault, dict(pool=pool, token0=toks[0], token1=toks[1]), "repo:" + src)
        r.update(liq_method=meth, note="ntokens=%d;vault src %s" % (len(toks), vsrc))
        r["_toks"], r["_bals"] = toks, bals
        out.append(r)
    return out


def anchor_price(ctx, rows):
    nat, num = ctx.cfg["native"][0].lower(), ctx.cfg["num"][0].lower()
    best = None
    for r in rows:
        if {r["token0"], r["token1"]} != {nat, num} or r["family"] not in V3LIKE or not r.get("_sqrtp"):
            continue
        side = 0 if r["token0"] == num else 1
        b = r["bal%d" % side]
        if isinstance(b, int) and (best is None or b > best[0]):
            best = (b, r)
    if not best:
        return None, None
    r = best[1]
    m = mid_from_sqrtp(r["_sqrtp"], dec_of(ctx, r["token0"]), dec_of(ctx, r["token1"]))
    return (m if r["token0"] == nat else 1 / m), r["pool"]


def price_all(ctx, rows):
    nat, num = ctx.cfg["native"][0].lower(), ctx.cfg["num"][0].lower()
    pn, apool = anchor_price(ctx, rows)
    prices = {num: 1.0}
    if pn:
        prices[nat] = pn
        prices[ZERO] = pn
    ctx.note("anchor native price %s num from pool %s" % (pn, apool))
    for _ in range(2):
        best = {}
        for r in rows:
            if r["family"] in ("lb", "inf_bin", "curve_ng", "balancer_v2", "balancer_v3") or r.get("tick_spacing") == "stable":
                continue
            d0, d1 = dec_of(ctx, r["token0"]), dec_of(ctx, r["token1"])
            if d0 is None or d1 is None:
                continue
            m = mid_from_sqrtp(r.get("_sqrtp"), d0, d1) if r["family"] in V3LIKE else \
                mid_from_balances(r["bal0"], r["bal1"], d0, d1)
            if not m:
                continue
            for side, q in ((0, r["token1"]), (1, r["token0"])):
                t = r["token%d" % side]
                if t in prices or q not in prices or not isinstance(r["bal%d" % (1 - side)], int):
                    continue
                qv = r["bal%d" % (1 - side)] / 10 ** dec_of(ctx, q) * prices[q]
                p = m * prices[q] if side == 0 else prices[q] / m
                if qv > best.get(t, (0, 0))[0]:
                    best[t] = (qv, p)
        for t, (qv, p) in best.items():
            if qv >= 1000:          # price only from a pool with >= 1000 num on the priced side
                prices[t] = p
    return prices


def run(chain, outdir):
    ctx = Ctx(chain, outdir)
    cfg = ctx.cfg
    ref = ref_label(chain)
    ctx.b = int(ctx.rpc.call("eth_blockNumber", []), 16) - 64
    ctx.note("B_inv=%d ref=%s" % (ctx.b, ref))
    venues = list(cfg["venues"]) + (eth_venues(ctx) if chain == "ethereum" else [])
    pm = cfg.get("pm")
    # (1) venues.tsv
    vrows = []
    allv = [(v["fam"], v["addr"], v["init"], v["src"]) for v in venues]
    if pm:
        allv.append(("v4", pm[0].lower(), "", pm[1]))
    for fam, mgr, src, _ in cfg.get("inf", []):
        allv.append((fam, mgr.lower(), "", src))
    for fam, vault, _, _, vsrc in cfg.get("ext", []):
        if (fam, vault.lower()) not in {(a, b) for a, b, _, _ in allv}:
            allv.append((fam, vault.lower(), "", vsrc))
    for fam, a, init, src in allv:
        n, h = ctx.code(a)
        vrows.append(dict(chain=chain, family=fam, factory_or_manager=a, init_code_hash=init,
                          code_len=n, codehash=h, source=src, on_main=ref))
    append_tsv(os.path.join(outdir, "venues.tsv"), VEN_COLS, vrows)
    # (2) roles the repo does not wire (on-chain discovery)
    discover_roles(ctx, venues)
    nat = cfg["native"][0].lower()
    num = cfg["num"][0].lower() if cfg.get("num") else None
    tok_info(ctx, nat, cfg["native"][1])
    if num:
        tok_info(ctx, num, cfg["num"][1])
    roles = {r: lst[0][0].lower() for r, lst in cfg["roles"].items() if lst}
    for r, lst in cfg["roles"].items():
        for a, s_ in lst:
            tok_info(ctx, a, s_)
    mids = [a.lower() for a, _ in cfg["midtail"]]
    for a, s_ in cfg["midtail"]:
        tok_info(ctx, a, s_)
    # (3) newest creation events per emitter
    rows = []
    for v in venues:
        rows += scan_emitter(ctx, v["fam"], v["addr"], NEW_SCAN)
    if pm:
        rows += scan_emitter(ctx, "v4", pm[0].lower(), NEW_SCAN)
    for fam, mgr, src, _ in cfg.get("inf", []):
        rows += scan_emitter(ctx, fam, mgr.lower(), NEW_SCAN)
    for r in rows:
        r["note"] = "newest-%d" % NEW_SCAN
    # (4) majors and midtail by getter
    majors = set()
    pairs = []
    for a, b in ((nat, num), (nat, roles.get("usdt")), (num, roles.get("usdt")), (roles.get("btc"), nat),
                 (roles.get("btc"), num), (roles.get("lst"), nat)):
        if a and b:
            majors.add(frozenset((a, b)))
            pairs.append((a, b))
    for m in mids:
        pairs += [(m, nat)] + ([(m, num)] if num else [])
    have = {r["pool"] for r in rows}
    got = []
    for a, b in pairs:
        for v in venues:
            for p, ex in lookup(ctx, v, a, b):
                if p not in have:
                    have.add(p)
                    got.append((v["fam"], v["addr"], dict(ex, pool=p)))
        if pm:
            for pid, ex in v4_lookup(ctx, pm[0].lower(), a, b):
                if pid not in have:
                    have.add(pid)
                    got.append(("v4native" if ex["token0"] == ZERO else "v4", pm[0].lower(), dict(ex, pool=pid)))
    # (5) creation block + creation log for every getter pool
    def confirm(item):
        fam, em, rec = item
        row = mk_row(ctx, fam, em, rec, "")
        row["pool_id"] = rec.get("pool_id", "")
        efam = "v4" if fam == "v4native" else fam
        blk = created_block(ctx, efam, row, pm[0].lower() if pm and efam == "v4" else None)
        if blk == RPC_ERR:
            return row, None
        d = confirm_event(ctx, em, FAM_EVENT[efam], blk, row)
        if d:
            row["created_block"] = blk
            row["source"] = "getter+event:%s@%d-%d" % (TOPICS[FAM_EVENT[efam]], blk, blk)
            if fam == "solidly":
                row["tick_spacing"] = "stable" if d.get("stable") else "volatile"
            if fam in ("v3", "pharaoh") and d.get("fee") != "":
                row["fee"] = d["fee"]
            if fam == "lb":
                row["tick_spacing"] = d.get("bin_step", row["tick_spacing"])
        return row, d
    unconf = 0
    for row, d in pmap(confirm, got):
        if d:
            rows.append(row)
        else:
            unconf += 1
            ctx.note("unconfirmed getter pool %s %s (no creation log at bisected block)" % (row["family"], row["pool"]))
    # repo pools and repo Infinity pool ids
    fam_by_addr = {v["addr"]: v["fam"] for v in venues}
    for p, src in cfg.get("repo_pools", []):
        if p.lower() not in have:
            r = repo_pool_row(ctx, p.lower(), src, fam_by_addr)
            if r:
                rows.append(r)
                have.add(p.lower())
    for fam, mgr, src, ids in cfg.get("inf", []):
        for pid, ps in ids:
            if pid.lower() in have:
                continue
            k = ctx.call(mgr, SEL["poolIdToPoolKey"] + w(pid))
            if k in (RPC_ERR, "revert", None, "0x"):
                ctx.note("inf id %s: poolIdToPoolKey %s" % (pid, k))
                continue
            d = words(k)
            rows.append(mk_row(ctx, fam, mgr, dict(pool=pid, pool_id=pid, token0=addr_of(d[0]), token1=addr_of(d[1]),
                                                    hooks=addr_of(d[2]), fee=u(d[4])), "repo:" + ps))
            have.add(pid.lower())
    rows += ext_rows(ctx)
    for r in rows:
        if r["family"] in ("inf_cl", "inf_bin", "v4") and not r.get("pool_id"):
            r["pool_id"] = r["pool"]
        if r["family"] == "v4" and r["token0"] == ZERO:
            r["family"] = "v4native"
    # (6) measure at B_inv
    def meas(r):
        if r["family"] in ("curve_ng", "balancer_v2", "balancer_v3"):
            return r, None
        f = r["family"]
        mgr = pm[0].lower() if f in ("v4", "v4native") else (r["factory"] if f in ("inf_cl", "inf_bin") else None)
        return r, measure_pool(ctx.rpc, f, r, ctx.b, mgr)
    for r, m in pmap(meas, rows):
        if m is None:
            continue
        r["bal0"], r["bal1"], r["liquidity_raw"], r["_sqrtp"] = m["bal0"], m["bal1"], m["liq"], m["sqrtp"]
        r["liq_method"] = m["liq_method"] or "balanceOf(pool)"
    for r in rows:
        if r["family"] not in ("v4", "v4native", "inf_cl", "inf_bin", "curve_ng", "balancer_v2", "balancer_v3"):
            n, h = ctx.code(r["pool"])
            r["code_len"], r["codehash"] = n, h
        r["ref"] = ref
        for t in [r["token0"], r["token1"]] + r.get("_toks", []):
            tok_info(ctx, t, "")
    prices = price_all(ctx, rows) if num else {}
    decs = {t: v[1] for t, v in ctx.tok.items() if isinstance(v[1], int)}
    for r in rows:
        if "_toks" in r:            # multi-token external pool: sum priced coins
            tot, ok = 0.0, False
            for i, t in enumerate(r["_toks"]):
                b = r["_bals"][i] if i < len(r["_bals"]) else None
                if isinstance(b, tuple):
                    b, dd = b[1], 18
                else:
                    dd = decs.get(t)
                if i < 2:
                    r["bal%d" % i] = b if b is not None else ""
                if t in prices and isinstance(b, int) and dd is not None:
                    tot += b / 10 ** dd * prices[t]
                    ok = True
            r["liq_usd"] = round(tot, 2) if ok else ""
        else:
            r["liq_usd"] = liq_usd(r, prices, decs)
    classify(rows, majors, set(mids))
    finalize(rows)
    rows.sort(key=lambda r: (r["family"], rank_key(r)))
    append_tsv(os.path.join(outdir, "inventory.tsv"), INV_COLS, rows)
    trows = [dict(chain=chain, token=t, symbol=v[0], decimals=v[1], code_len=v[2], source=v[3] or "pool-token",
                  ref=ref) for t, v in sorted(ctx.tok.items())]
    append_tsv(os.path.join(outdir, "tokens.tsv"), TOK_COLS, trows)
    append_tsv(os.path.join(outdir, "scan_log.tsv"), SCAN_COLS, ctx.scan_rows)
    ctx.note("DONE rows=%d unconfirmed=%d priced_tokens=%d rpc_calls=%d" % (len(rows), unconf, len(prices), ctx.rpc.calls))
    return rows


if __name__ == "__main__":
    if sys.argv[1] == "--refinalize":
        refinalize_tsv(sys.argv[2])
        sys.exit(0)
    os.makedirs(sys.argv[2], exist_ok=True)
    run(sys.argv[1], sys.argv[2])
