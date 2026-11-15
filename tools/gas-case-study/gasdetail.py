#!/usr/bin/env python3
"""Gas case study 1114: the gas of one swap, split by call frame, plus its L1 fee and price (stdlib only).

Library (the harness imports it):
  trace(rpc, tx_hash)                                   -> callTracer dict
  split_gas(trace, hops, solver_addrs, router_addr)     -> dict(gas_tx, gas_discovery, gas_exec_hop,
                                                              gas_exec_leg, separable, note)
  l1_fee(remote_rpc, chain, tx_bytes, block)            -> (wei | None, method)
  gas_price(remote_rpc, block)                          -> (basefee_wei, priority_wei, method)
  usd(gas_tx, gas_price_wei, l1_fee_wei, native_usd)    -> (usd_gas, usd_l1, usd_total)

Live check (read only; the dRPC key in ~/.drpc-key is never printed or written):
  python3 -I tools/gas-case-study/gasdetail.py l1probe <chain> <block>

`rpc` is any object with .call(method, params) that returns the JSON-RPC result or raises.
Absent is never zero: a value that could not be read is None, and the method string says why.
"""
import hashlib
import os
import statistics
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import abi  # noqa: E402

GPO = "0x420000000000000000000000000000000000000f"             # OP-stack GasPriceOracle predeploy
NODE_INTERFACE = "0x00000000000000000000000000000000000000c8"  # Nitro virtual precompile (RPC only)
ARBSYS = "0x0000000000000000000000000000000000000064"          # Nitro ArbSys precompile
OP_STACK = ("base", "optimism")
NITRO = ("arbitrum",)
L1_NONE = ("ethereum", "bsc", "avalanche")
PROBED = ("robinhood",)                                        # family found by probe, never assumed
EXEC_TYPES = ("CALL", "DELEGATECALL", "CALLCODE")              # a STATICCALL cannot be a swap

_FAMILY = {}  # (id(rpc), chain) -> (family | None, method)


def _int(x):
    """int of a hex string / int; None for None, '' or '0x' (absent, not zero)."""
    if x is None or isinstance(x, bool):
        return None
    if isinstance(x, int):
        return x
    s = str(x).strip()
    if s in ("", "0x"):
        return None
    return int(s, 16) if s.lower().startswith("0x") else int(s)


def _addr(a):
    return (a or "").lower()


def trace(rpc, tx_hash):
    """The callTracer tree of a mined tx (debug_traceTransaction; anvil and geth both serve it)."""
    return rpc.call("debug_traceTransaction", [tx_hash, {"tracer": "callTracer"}])


# ── split ────────────────────────────────────────────────────────────────────────────────────────
def _children(f):
    return f.get("calls") or []


def split_gas(trace, hops, solver_addrs, router_addr):
    """Split a swap tx's gas by call frame.

    trace        callTracer dict of the tx (root = the tx's call; root gasUsed = receipt gasUsed).
    hops         [[(target_addr, kind), ...] per hop]; target = the pool / adapter / PoolManager the
                 Router calls for that leg; kind is carried into the note only.
    solver_addrs addresses whose frames are on-chain route discovery (the Solver / Hub of
                 onchain@*); empty or None = discovery not asked (gas_discovery None).
    router_addr  the Router; only frames it opens count as legs (None = any caller).

    Definitions (by frame, never by apportioning):
    - gas_tx        = root gasUsed (None if absent).
    - gas_discovery = sum of gasUsed of the outermost non-root frames to a solver address. 0 when
                      solver addresses are given and the complete trace has no such frame (observed,
                      the quoted modes); None when solver_addrs is empty.
    - leg           = gasUsed of the outermost CALL/DELEGATECALL frame opened by the Router to the
                      leg's target, outside any discovery frame. It includes everything nested in that
                      frame (callbacks, token transfers, the V4 unlockCallback); it excludes what the
                      Router does around it (a V2 pre-transfer, accounting, the final transfer).
                      The k-th leg with target X takes the k-th such frame to X in call order.
    - hop           = sum of its legs.
    - separable     = False (and both lists empty) when frames and legs do not match 1:1: a target
                      with more or fewer frames than legs (a V4 bundle under one unlock, a target
                      nested inside another leg's frame), a frame without gasUsed, legs + discovery
                      above gas_tx, or a reverted tx (the note names the reverting leg if any).
    The remainder gas_tx - discovery - sum(legs) is overhead (intrinsic, calldata, Router
    bookkeeping); it is not given a name here.
    """
    out = dict(gas_tx=_int(trace.get("gasUsed")) if trace else None, gas_discovery=None,
               gas_exec_hop=[], gas_exec_leg=[], separable=False, note="")
    if not trace:
        out["note"] = "no trace"
        return out
    solvers = {_addr(a) for a in (solver_addrs or []) if a}
    router = _addr(router_addr) if router_addr else None
    legs = [(h, l, _addr(t), k) for h, hop in enumerate(hops or []) for l, (t, k) in enumerate(hop)]
    targets = {t for _, _, t, _ in legs}
    disc, frames, bad = [], {t: [] for t in targets}, []

    def walk(f, in_disc):
        for c in _children(f):
            to, typ = _addr(c.get("to")), (c.get("type") or "").upper()
            if not in_disc and to in solvers:
                disc.append(c)
                walk(c, True)
                continue
            if (not in_disc and to in targets and typ in EXEC_TYPES
                    and (router is None or _addr(c.get("from")) == router)):
                frames[to].append(c)          # outermost: nothing below it is a second frame
                continue
            walk(c, in_disc)

    walk(trace, False)
    notes = []
    if solvers:
        dg = [_int(c.get("gasUsed")) for c in disc]
        if None in dg:
            notes.append("discovery frame without gasUsed")
        else:
            out["gas_discovery"] = sum(dg)
            if not disc:
                notes.append("discovery:none-in-trace")
    leg_gas, leg_err = [], None
    for t in sorted(targets):
        want = sum(1 for x in legs if x[2] == t)
        if len(frames[t]) != want:
            kinds = ",".join(sorted({str(x[3]) for x in legs if x[2] == t}))
            bad.append(f"{t}(kind {kinds}): {len(frames[t])} frames for {want} legs")
    seen = {t: 0 for t in targets}
    if not bad:
        for h, l, t, k in legs:
            f = frames[t][seen[t]]
            seen[t] += 1
            g = _int(f.get("gasUsed"))
            if g is None:
                bad.append(f"leg {h}.{l} frame without gasUsed")
            if f.get("error") and leg_err is None:
                leg_err = f"leg {h}.{l} ({k}) {f.get('error')}"
            leg_gas.append(g)
    if trace.get("error"):
        notes.append("tx reverted: " + str(trace.get("error")) + (f"; at {leg_err}" if leg_err else ""))
    elif leg_err:
        notes.append("caught revert in " + leg_err)
    if not legs:
        bad.append("no legs given")
    if not bad and not trace.get("error") and out["gas_tx"] is not None:
        tot = sum(leg_gas) + (out["gas_discovery"] or 0)
        if tot > out["gas_tx"]:
            bad.append(f"legs+discovery {tot} > gas_tx {out['gas_tx']}")
    if out["gas_tx"] is None:
        bad.append("root without gasUsed")
    if bad or trace.get("error"):
        out["note"] = "; ".join(notes + bad)
        return out
    hop_gas = [0] * len(hops)
    for (h, _, _, _), g in zip(legs, leg_gas):
        hop_gas[h] += g
    out.update(gas_exec_hop=hop_gas, gas_exec_leg=leg_gas, separable=True, note="; ".join(notes))
    return out


# ── RLP (only to read to/data of a tx for Nitro's NodeInterface) ────────────────────────────────
def _rlp_item(b, i):
    """(item, next index) of the RLP item at b[i]; bytes for strings, list for lists."""
    p = b[i]
    if p < 0x80:
        return b[i:i + 1], i + 1
    if p < 0xb8:
        n = p - 0x80
        return b[i + 1:i + 1 + n], i + 1 + n
    if p < 0xc0:
        ll = p - 0xb7
        n = int.from_bytes(b[i + 1:i + 1 + ll], "big")
        return b[i + 1 + ll:i + 1 + ll + n], i + 1 + ll + n
    if p < 0xf8:
        n, s = p - 0xc0, i + 1
    else:
        ll = p - 0xf7
        n, s = int.from_bytes(b[i + 1:i + 1 + ll], "big"), i + 1 + ll
    items, j = [], s
    while j < s + n:
        it, j = _rlp_item(b, j)
        items.append(it)
    if j != s + n:
        raise ValueError("rlp list overrun")
    return items, s + n


def _rlp_enc(x):
    if isinstance(x, list):
        body = b"".join(_rlp_enc(i) for i in x)
        return _rlp_len(len(body), 0xc0) + body
    if isinstance(x, int):
        x = x.to_bytes((x.bit_length() + 7) // 8, "big") if x else b""
    if len(x) == 1 and x[0] < 0x80:
        return x
    return _rlp_len(len(x), 0x80) + x


def _rlp_len(n, off):
    if n < 56:
        return bytes([off + n])
    nb = n.to_bytes((n.bit_length() + 7) // 8, "big")
    return bytes([off + 55 + len(nb)]) + nb


def _bytes(tx_bytes):
    if isinstance(tx_bytes, (bytes, bytearray)):
        return bytes(tx_bytes)
    s = str(tx_bytes)
    return bytes.fromhex(s[2:] if s.startswith("0x") else s)


def tx_to_data(tx_bytes):
    """(to, data) of a legacy (RLP list) or typed (0x01 / 0x02 || RLP) tx; signed or unsigned."""
    b = _bytes(tx_bytes)
    if not b:
        raise ValueError("empty tx")
    if b[0] >= 0xc0:
        f, _ = _rlp_item(b, 0)
        to, data = f[3], f[5]
    elif b[0] in (1, 2):
        f, _ = _rlp_item(b, 1)
        to, data = (f[4], f[6]) if b[0] == 1 else (f[5], f[7])
    else:
        raise ValueError(f"tx type {b[0]} not read")
    return ("0x" + to.hex()) if to else None, "0x" + data.hex()


def unsigned_1559(chain_id, to, data, gas, max_fee, prio, value=0, nonce=0):
    """0x02 || rlp([chainId, nonce, prio, maxFee, gas, to, value, data, []]) as hex (for getL1Fee)."""
    t = bytes.fromhex(to[2:] if to.startswith("0x") else to)
    d = _bytes(data)
    return "0x02" + _rlp_enc([chain_id, nonce, prio, max_fee, gas, t, value, d, []]).hex()


# ── L1 fee ───────────────────────────────────────────────────────────────────────────────────────
def _call(rpc, to, data, block):
    return rpc.call("eth_call", [{"to": to, "data": data}, hex(block)])


def family(remote_rpc, chain, block):
    """('op' | 'nitro' | 'l1' | None, method). Known chains by name; robinhood by probe at `block`:
    code at the GasPriceOracle predeploy -> OP-stack; ArbSys.arbChainID() answering -> Nitro."""
    if chain in L1_NONE:
        return "l1", "l1:none"
    if chain in OP_STACK:
        return "op", "family:op-stack(named)"
    if chain in NITRO:
        return "nitro", "family:nitro(named)"
    if chain not in PROBED:
        return None, "family:unknown-chain"
    key = (id(remote_rpc), chain)
    if key in _FAMILY:
        return _FAMILY[key]
    res = None, "family:probe-failed"
    try:
        code = remote_rpc.call("eth_getCode", [GPO, hex(block)])
        if _int(code):
            res = "op", "family:op-stack(probe:code@GasPriceOracle)"
    except Exception as e:  # noqa: BLE001  (a failed probe is a fact about the source)
        res = None, f"family:probe-failed(getCode {type(e).__name__})"
    if res[0] is None:
        try:
            cid = abi.decode(["uint256"], _call(remote_rpc, ARBSYS, "0x" + abi.selector("arbChainID()"), block))[0]
            if cid:
                res = "nitro", f"family:nitro(probe:ArbSys.arbChainID={cid})"
        except Exception as e:  # noqa: BLE001
            res = None, res[1] + f";arbsys {type(e).__name__}"
    if res[0] is not None:
        _FAMILY[key] = res
    return res


def l1_fee(remote_rpc, chain, tx_bytes, block):
    """(L1 data fee in wei | None, method) of `tx_bytes` at `block`, on the REMOTE rpc.
    OP-stack: GasPriceOracle.getL1Fee(bytes) (the tx bytes as given; post-Fjord the oracle adds the
    signature's bytes itself). Nitro: NodeInterface.gasEstimateL1Component(to, false, data) ->
    gasEstimateForL1 * baseFee (a virtual precompile: only the remote node answers, never anvil).
    ethereum / bsc / avalanche: (0, 'l1:none'), a real zero. Any failure: (None, reason)."""
    fam, how = family(remote_rpc, chain, block)
    if fam == "l1":
        return 0, how
    if fam is None:
        return None, how
    if remote_rpc is None:
        return None, "l1:no-rpc"
    try:
        if fam == "op":
            raw = "0x" + _bytes(tx_bytes).hex()
            v = abi.decode(["uint256"], _call(remote_rpc, GPO, abi.calldata(abi.selector("getL1Fee(bytes)"),
                                                                            ["bytes"], [raw]), block))[0]
            return v, "l1:op-GasPriceOracle.getL1Fee;" + how
        to, data = tx_to_data(tx_bytes)
        cd = abi.calldata(abi.selector("gasEstimateL1Component(address,bool,bytes)"), ["address", "bool", "bytes"],
                          [to or "0x" + "00" * 20, to is None, data])
        g, bf, _ = abi.decode(["uint64", "uint256", "uint256"], _call(remote_rpc, NODE_INTERFACE, cd, block))
        return g * bf, "l1:nitro-NodeInterface.gasEstimateL1Component(gasForL1*baseFee);" + how
    except Exception as e:  # noqa: BLE001
        return None, f"l1:{fam}-error({type(e).__name__});" + how


# ── price and USD ────────────────────────────────────────────────────────────────────────────────
GAS_PRICE_METHOD = "basefee=block.baseFeePerGas;priority=median_low(eth_feeHistory(1,block,[50]).reward[*][0])"


def gas_price(remote_rpc, block):
    """(basefee_wei | None, priority_wei | None, method) at `block`: the block's baseFeePerGas and the
    median (low, so an integer) of the p50 rewards eth_feeHistory gives for that one block."""
    base = prio = None
    why = []
    try:
        blk = remote_rpc.call("eth_getBlockByNumber", [hex(block), False])
        base = _int((blk or {}).get("baseFeePerGas"))
        if base is None:
            why.append("basefee absent")
    except Exception as e:  # noqa: BLE001
        why.append(f"block error {type(e).__name__}")
    try:
        fh = remote_rpc.call("eth_feeHistory", ["0x1", hex(block), [50]])
        r = [_int(x[0]) for x in ((fh or {}).get("reward") or []) if x]
        r = [x for x in r if x is not None]
        if r:
            prio = statistics.median_low(r)
        else:
            why.append("reward absent")
    except Exception as e:  # noqa: BLE001
        why.append(f"feeHistory error {type(e).__name__}")
    return base, prio, GAS_PRICE_METHOD + ("" if not why else ";" + ",".join(why))


def usd(gas_tx, gas_price_wei, l1_fee_wei, native_usd):
    """(usd_gas, usd_l1, usd_total); any None input makes the terms that use it None."""
    ug = None if None in (gas_tx, gas_price_wei, native_usd) else gas_tx * gas_price_wei * native_usd / 1e18
    ul = None if None in (l1_fee_wei, native_usd) else l1_fee_wei * native_usd / 1e18
    return ug, ul, (None if None in (ug, ul) else ug + ul)


# ── live check ───────────────────────────────────────────────────────────────────────────────────
class HttpRpc:
    """JSON-RPC over HTTP to dRPC; the URL (with the key) is kept private and never printed."""

    def __init__(self, chain):
        import json
        import urllib.request
        self._j, self._u = json, urllib.request
        key = open(os.path.expanduser(os.environ.get("DRPC_KEY_FILE", "~/.drpc-key"))).read().strip()
        self.__url = f"https://lb.drpc.live/{chain}/{key}"

    def call(self, method, params):
        body = self._j.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
        req = self._u.Request(self.__url, body, {"Content-Type": "application/json"})
        with self._u.urlopen(req, timeout=30) as r:
            res = self._j.loads(r.read())
        if "error" in res:
            raise RuntimeError(str(res["error"].get("message", ""))[:120])
        return res["result"]


def main(argv):
    if len(argv) != 3 or argv[0] != "l1probe":
        print(__doc__, file=sys.stderr)
        return 2
    chain, block = argv[1], int(argv[2])
    rpc = HttpRpc(chain)
    cid = int(rpc.call("eth_chainId", []), 16)
    base, prio, how = gas_price(rpc, block)
    # a fixed swap-sized tx: 4 + 10 * 32 bytes of calldata, half zero, to a fixed address
    data = "0x" + hashlib.sha256(b"gas-1114-l1probe").hexdigest()[:8] + ("00" * 32 + "11" * 32) * 5
    tx = unsigned_1559(cid, "0x" + "42" * 20, data, 300000, (base or 0) + (prio or 0), prio or 0)
    fee, m = l1_fee(rpc, chain, tx, block)
    print("\t".join(map(str, [chain, block, cid, base, prio, fee, m, how])))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
