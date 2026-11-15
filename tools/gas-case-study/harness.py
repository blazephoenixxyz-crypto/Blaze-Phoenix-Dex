#!/usr/bin/env python3
"""Gas case study 1114: measure one chain's pre-registered cells on a local fork (stdlib + requests).

  python3 -I tools/gas-case-study/harness.py head <chain>
  python3 -I tools/gas-case-study/harness.py block <chain> <prereg.tsv>
  python3 -I tools/gas-case-study/harness.py cells <chain> <prereg.tsv> <outdir> <anvil_url> <addrs.tsv> \
      <block_fork> [--nprime 8] [--modes quoted,onchain,...] [--allow-unlocked]

The grid is docs/prereg/gas-1114.tsv, read only if its `lock` row is sha256 of every byte before it
(tools/fuzz-coverage/prereg.py); --allow-unlocked is for dry runs, never for data. Two layouts are
read: a TSV whose header starts with `chain`, or tagged rows (`const K V`, `mode m...`, `cols c...`,
`cell <values>` in the `cols` order, default GRID_COLS). Each cell is measured in its own snapshot
(evm_snapshot / evm_revert) by a fixed impersonated EOA, cold (first swap) then warm (re-quote and
repeat after the first one is mined), in each mode:
  quoted   Quoter.previewPlan -> pv.route (the FIRST return value; the second is the runner-up)
           -> Router.swapExactIn(pv.route, amountIn, pv.effectiveMinOut, user, deadline)
  onchain  Router.swapBestExactIn (the Solver runs inside the tx); legs from the Router's Swap event,
           hops and topology from the preview of the same state [derived]
  native   Router.swapExactInNative with msg.value = amountIn, only when tokenIn is the wrapped native
  forced:HxL  a route built off-chain on Hub.discoverFor pools (V2, V3, Solidly, Algebra), equal
           split, re-priced by Quoter.previewRouteExact, sent through swapExactIn with minOut = 1
           (H = 1: L in 1..5; H = 2 via a bridge: L in 2..10; 1 hop with 6..10 legs is absent by code,
           src/BlazePhoenixRouter.sol:1170, never a zero)
out_ours is the user's balanceOf delta of tokenOut (I2), never the Router's return value. Every pool
of the pair is also sent alone as a 1-leg route (best_single.tsv; its gas is the Router's 1-leg gas,
gas_src router_1leg, an upper bound of a direct swap [derived]). A failed read is absent (empty),
never zero. The RPC URL holds a key and is never printed or written.
"""
import hashlib
import os
import re
import resource
import sys
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
for _p in (HERE, os.path.join(HERE, "..", "g7-gas-campaign"), os.path.join(HERE, "..", "fuzz-coverage")):
    if _p not in sys.path:
        sys.path.insert(0, _p)
import abi  # noqa: E402
import prereg as _prereg  # noqa: E402
from g7 import Reverted, Rpc, RpcError, calldata_cost, revert_detail, strip0x  # noqa: E402

GRID_COLS = "chain cell_id pair token_in token_out amount_in size_usd seed".split()
GRID_REQ = ("chain", "cell_id", "token_in", "token_out", "amount_in")
RESULT_COLS = ("chain block cell_id pair token_in token_out amount_in size_usd seed mode temp hops legs topology "
               "gas_est gas_real out_ours out_best_single best_single_pool basefee_wei native_usd net_usd_ours "
               "net_usd_best status").split()
BEST_COLS = "chain block cell_id pool kind out out_router gas gas_src status".split()
ABSENT_COLS = "chain cell_id mode reason".split()
TIMING_COLS = ("chain cell_id mode temp wall_s est_node cd_bytes cd_zero cd_gas cd_floor l1_fee_wei "
               "anvil_vmhwm_kib harness_maxrss_kib").split()
ADDR = re.compile(r"^0x[0-9a-fA-F]{40}$")
UINT = re.compile(r"^[0-9]+$")
ZERO = "0x" + "0" * 40
USER = "0x" + hashlib.sha256(b"gas-1114-user").hexdigest()[:40]  # a fixed EOA, impersonated
MAX_HOPS, MAX_LEGS_PER_HOP, BRIDGE_SLOTS = 2, 5, 3  # src/BlazePhoenixCore.sol:132,145; Solver:110
FORCED_KINDS = (0, 1, 5, 6)  # V2, V3, Solidly, Algebra (src/BlazePhoenixCore.sol:269-273)
KIND_EXTERNAL = 9  # Gate legs (Core:316): the Balancer wrappers' view port quotes 0
PROTOCOL_FEE_BPS = 28  # src/BlazePhoenixCore.sol:420
FORCED_SHAPES = [(1, n) for n in range(1, MAX_LEGS_PER_HOP + 1)] + [(2, n) for n in range(2, 2 * MAX_LEGS_PER_HOP + 1)]
MODES = ["quoted", "onchain", "native"] + [f"forced:{h}x{n}" for h, n in FORCED_SHAPES]
DEADLINE_S = 3600
OP_STACK = ("base", "optimism")
NITRO = ("arbitrum", "robinhood")
GPO = "0x420000000000000000000000000000000000000F"
NODE_INTERFACE = "0x00000000000000000000000000000000000000C8"
MAXU = (1 << 256) - 1

ARGS = {
    "previewPlan": ["address", "address", "uint256"],
    "previewRouteExact": [abi.ROUTE, "uint256"],
    "swapExactIn": [abi.ROUTE, "uint256", "uint256", "address", "uint256"],
    "swapBestExactIn": ["address", "address", "uint256", "uint256", "address", "uint256"],
    "swapExactInNative": [abi.ROUTE, "uint256", "address", "uint256"],
    "discoverFor": ["address", "address"],
    "bridge": ["uint8"],
    "balanceOf": ["address"],
    "approve": ["address", "uint256"],
    "decimals": [],
    "weth": [],
    "getL1Fee": ["bytes"],
    "gasEstimateL1Component": ["address", "bool", "bytes"],
    "RouterE": ["uint16"],
}
SWAP_EVENT = "Swap(address,address,address,uint256,uint256,uint256)"  # src/BlazePhoenixRouter.sol:265


class PreregError(Exception):
    pass


# ── ABI ──
def canon(t):
    if isinstance(t, str):
        return t
    if t[0] == "array":
        return canon(t[1]) + "[]"
    return "(" + ",".join(canon(ft) for _, ft in t[1]) + ")"


def sig(name):
    return name + "(" + ",".join(canon(t) for t in ARGS[name]) + ")"


def fn(name):
    return abi.selector(sig(name))


def cd(name, *vals):
    return abi.calldata(fn(name), ARGS[name], list(vals))


def err_class(data):
    """The revert class: minOut (RouterE(5), Router:1665), deadline (RouterE(4), Router:631),
    RouterE(n), Error:<text>, Panic(n), empty, or 0x<selector>."""
    d = strip0x(data or "")
    if d[:8] == fn("RouterE") and len(d) >= 72:
        code = int(d[8:72], 16)
        return {5: "minOut", 4: "deadline"}.get(code, f"RouterE({code})")
    if d[:8] == "4e487b71" and len(d) >= 72:
        return f"Panic({int(d[8:72], 16)})"
    return revert_detail("", data)


def topic(sig_):
    return "0x" + abi.keccak256(sig_.encode()).hex()


# ── prereg ──
def read_prereg(path, chain=None, allow_unlocked=False, row_tags=("cell",), default_cols=GRID_COLS,
                required=GRID_REQ):
    """{consts, modes, rows}: rows of `chain` (all if None), validated; a malformed row is refused
    with its line number (fail closed), an unlocked file too unless allow_unlocked."""
    errs = _prereg.check_lock(path)
    if errs and not allow_unlocked:
        raise PreregError("; ".join(errs))
    text = open(path).read()
    body, _ = _prereg._split(text)
    lines = [(n, ln) for n, ln in enumerate(body.split("\n"), 1) if ln.strip()]
    consts, modes, raw, cols = {}, [], [], None
    if lines and lines[0][1].split("\t")[0] == "chain":
        cols = lines[0][1].split("\t")
        raw = [(n, ln.split("\t")) for n, ln in lines[1:]]
    else:
        for n, ln in lines:
            f = ln.split("\t")
            if f[0] == "const" and len(f) >= 3:
                consts[f[1]] = f[2]
            elif f[0] == "cols":
                cols = f[1:]
            elif f[0] == "mode":
                modes.extend(x for x in f[1:] if x)
            elif f[0] in row_tags:
                raw.append((n, f[1:]))
    cols = cols or default_cols
    rows, order = [], {}
    for n, f in raw:
        if len(f) != len(cols):
            raise PreregError(f"{path}:{n}: {len(f)} fields, {len(cols)} columns")
        r = dict(zip(cols, f))
        for c in required:
            if r.get(c, "") == "":
                raise PreregError(f"{path}:{n}: empty {c}")
        for c in ("token_in", "token_out"):
            if c in r and not ADDR.match(r[c]):
                raise PreregError(f"{path}:{n}: {c} is not 0x+40hex")
        if not UINT.match(r["amount_in"]) or int(r["amount_in"]) == 0:
            raise PreregError(f"{path}:{n}: amount_in is not a positive integer in wei")
        if chain is not None and r["chain"] != chain:
            continue
        if r.get("i", "") == "":
            k = (r["chain"], r.get("pair", ""), r.get("size_usd", ""), r.get("age_s_target", ""))
            r["i"] = order.get(k, 0)
            order[k] = r["i"] + 1
        r["i"] = int(r["i"])
        r["_line"] = n
        rows.append(r)
    return dict(consts=consts, modes=modes, rows=rows)


def block_of(grid, chain):
    """The pre-registered fork block: const BLOCK_<CHAIN>, else the rows' one `block` value."""
    c = grid["consts"].get("BLOCK_" + chain.upper())
    if c:
        return int(c)
    bs = {r["block"] for r in grid["rows"] if r.get("block")}
    if len(bs) != 1:
        raise PreregError(f"{chain}: {len(bs)} fork blocks in the grid, want exactly 1")
    return int(bs.pop())


def read_addrs(path):
    out = {}
    for ln in open(path):
        f = ln.split()
        if len(f) >= 2 and ADDR.match(f[-1]):
            out[f[-2] if len(f) > 2 else f[0]] = f[-1]
    return out


# ── RPC ──
class Node(Rpc):
    """g7.Rpc (same retry and revert policy) on an explicit URL: the local anvil."""

    def __init__(self, url, attempts=2, backoff=0.5, timeout=600):  # noqa: super is not called on purpose
        import requests
        self._url, self._s, self._hdr, self._lock = url, requests.Session(), {}, threading.Lock()
        self.attempts, self.backoff, self.timeout = attempts, backoff, timeout


def rlp(x):
    """RLP of bytes / int / list (yellow paper, appendix B)."""
    if isinstance(x, list):
        body = b"".join(rlp(i) for i in x)
        return _rlp_len(len(body), 0xc0) + body
    if isinstance(x, int):
        x = x.to_bytes((x.bit_length() + 7) // 8, "big") if x else b""
    if len(x) == 1 and x[0] < 0x80:
        return x
    return _rlp_len(len(x), 0x80) + x


def _rlp_len(n, off):
    if n < 56:
        return bytes([off + n])
    b = n.to_bytes((n.bit_length() + 7) // 8, "big")
    return bytes([off + 55 + len(b)]) + b


def vmhwm(pid):
    try:
        for ln in open(f"/proc/{pid}/status"):
            if ln.startswith("VmHWM:"):
                return int(ln.split()[1])
    except (OSError, ValueError):
        pass
    return ""


# ── route builders ──
def split(amount, n):
    q = amount // n
    return [q] * (n - 1) + [amount - q * (n - 1)]


def leg(p, tin, amount):
    return dict(pool=p["pool"], hooks=p["hooks"], kind=p["kind"], fee=p["fee"], tickSpacing=p["tickSpacing"],
                zeroForOne=tin.lower() == p["token0"].lower(), stable=p["stable"], amountIn=amount,
                expectedOut=0, auxId=0)


def hop(tin, tout, pools, amount):
    return dict(tokenIn=tin, tokenOut=tout, amountIn=amount, expectedOut=0,
                legs=[leg(p, tin, a) for p, a in zip(pools, split(amount, len(pools)))])


def route(hops):
    return dict(hops=hops, totalOut=0, singleOut=0, singleOutFloor=0, expectedImpactBps=0, confidenceWad=0,
                estGas=0, hasSurplus=False, isV4Bundle=False)


def shape_legs(hops, legs):
    """(legs of hop 1, legs of hop 2) of a forced shape, None when absent by code (Router:1039,1170)."""
    if hops == 1:
        return (legs, 0) if 1 <= legs <= MAX_LEGS_PER_HOP else None
    if hops == 2:
        a = -(-legs // 2)
        return (a, legs - a) if 2 <= legs and a <= MAX_LEGS_PER_HOP and legs - a >= 1 else None
    return None


def route_shape(r):
    return len(r["hops"]), sum(len(h["legs"]) for h in r["hops"])


class Session:
    """One chain's fork: node = the anvil, real = the chain's RPC (fees, L1 component), or None."""

    def __init__(self, node, real, chain, addrs, block, consts=None, anvil_pid=None):
        self.node, self.real, self.chain, self.a, self.block = node, real, chain, addrs, block
        self.consts = consts or {}
        self.anvil_pid = anvil_pid
        self.user = USER
        self._dec, self._usd, self._bridges, self._fees = {}, {}, None, None
        self._native_usd, self.wnative, self.absent = "unset", None, []
        self.ts = int(node.call("eth_getBlockByNumber", ["latest", False])["timestamp"], 16)
        self.deadline = self.ts + int(self.consts.get("DEADLINE_S", DEADLINE_S))

    # reads
    def call(self, to, data, value=0):
        return self.node.call("eth_call", [{"from": self.user, "to": to, "data": data, "value": hex(value)}, "latest"])

    def balance(self, token, who=None):
        return abi.decode(["uint256"], self.call(token, cd("balanceOf", who or self.user)))[0]

    def decimals(self, token):
        if token not in self._dec:
            try:
                self._dec[token] = abi.decode(["uint8"], self.call(token, cd("decimals")))[0]
            except (Reverted, RpcError, ValueError):
                self._dec[token] = None
        return self._dec[token]

    def quote(self, tin, tout, amount):
        """(preview, None) or (None, error class) from Quoter.previewPlan; the route is out[0].route."""
        try:
            out = abi.decode(abi.PREVIEW_PLAN_OUT, self.call(self.a["quoter"], cd("previewPlan", tin, tout, amount)))
        except Reverted as e:
            return None, err_class(e.data)
        return out[0], None

    def exact(self, r, amount):
        try:
            rr, out = abi.decode(abi.ROUTE_EXACT_OUT, self.call(self.a["quoter"], cd("previewRouteExact", r, amount)))
        except Reverted as e:
            return None, err_class(e.data)
        return rr, out

    def pools(self, ta, tb, kinds=FORCED_KINDS):
        try:
            ps = abi.decode([("array", abi.POOLINFO)], self.call(self.a["hub"], cd("discoverFor", ta, tb)))[0]
        except (Reverted, RpcError):
            return []
        return [p for p in ps if p["active"] and (kinds is None or p["kind"] in kinds)]

    def bridges(self):
        if self._bridges is None:
            self._bridges = []
            for i in range(BRIDGE_SLOTS):
                try:
                    self._bridges.append(abi.decode(["address"], self.call(self.a["hub"], cd("bridge", i)))[0])
                except (Reverted, RpcError):
                    self._bridges.append(ZERO)
        return self._bridges

    def topology(self, r):
        """0 for 1 hop, else 1 + the Hub bridge slot of the intermediate token (Solver:110,435)."""
        if len(r["hops"]) <= 1:
            return 0
        mid = r["hops"][0]["tokenOut"].lower()
        for i, b in enumerate(self.bridges()):
            if b.lower() == mid:
                return 1 + i
        return ""

    # writes
    def fund(self, token, amount, native=False):
        n = self.node
        n.call("anvil_impersonateAccount", [self.user])
        n.call("anvil_setBalance", [self.user, hex(10 ** 24 + (amount if native else 0) * 2)])
        if native:
            return True
        try:
            n.call("anvil_dealERC20", [token, self.user, hex(amount)])
            ok = self.balance(token) == amount
        except (RpcError, Reverted):
            ok = False
        if not ok:
            ok = self._fund_by_slot(token, amount)
        if ok:
            self.send(token, cd("approve", self.a["router"], MAXU))
        return ok

    def _fund_by_slot(self, token, amount, max_slot=64):
        u = format(int(self.user, 16), "064x")
        for s in range(max_slot):
            sl = format(s, "064x")
            for key in (u + sl, sl + u):  # Solidity mapping(address => uint), then Vyper
                k = "0x" + abi.keccak256(bytes.fromhex(key)).hex()
                old = self.node.call("eth_getStorageAt", [token, k, "latest"])
                self.node.call("anvil_setStorageAt", [token, k, "0x" + format(amount, "064x")])
                try:
                    if self.balance(token) == amount:
                        return True
                except (Reverted, RpcError):
                    pass
                self.node.call("anvil_setStorageAt", [token, k, "0x" + format(int(old, 16), "064x")])
        return False

    def send(self, to, data, value=0):
        tx = {"from": self.user, "to": to, "data": data, "value": hex(value)}
        try:
            est = int(self.node.call("eth_estimateGas", [tx]), 16)
        except Reverted as e:
            return dict(status="revert:0x" + strip0x(e.data or "")[:8], err=err_class(e.data), gas="", est="")
        tx["gas"] = hex(est * 3 // 2 + 100_000)
        h = self.node.call("eth_sendTransaction", [tx])
        rc = self.node.call("eth_getTransactionReceipt", [h])
        if rc is None or int(rc["status"], 16) != 1:
            return dict(status="revert:mined", err="mined_status_0", gas="", est=est)
        return dict(status="ok", err="", gas=int(rc["gasUsed"], 16), est=est, logs=rc.get("logs", []))

    def snapshot(self):
        return self.node.call("evm_snapshot", [])

    def revert(self, snap):
        if self.node.call("evm_revert", [snap]) is not True:
            raise RpcError("evm_revert refused: the next cell would start on a dirty state")

    # prices
    def fees(self):
        """(basefee, priority) at the fork block from eth_feeHistory (the real RPC if given)."""
        if self._fees is None:
            src = self.real or self.node
            try:
                fh = src.call("eth_feeHistory", [1, hex(self.block), [50]])
                self._fees = (int(fh["baseFeePerGas"][0], 16), int((fh.get("reward") or [["0x0"]])[0][0], 16))
            except (RpcError, Reverted, KeyError, IndexError):
                self._fees = (None, None)
        return self._fees

    def usd_of(self, token):
        """USD per whole token: 1 for the chain's stable (stated), else the gross preview of 10^dec
        token -> stable [derived]; None when there is no stable or no quote (absent)."""
        usd = self.consts.get("USD_" + self.chain.upper())
        if not usd:
            return None
        if token.lower() == usd.lower():
            return 1.0
        if token not in self._usd:
            d, du = self.decimals(token), self.decimals(usd)
            pv = self.quote(token, usd, 10 ** d)[0] if d is not None and du is not None else None
            self._usd[token] = pv["grossOut"] / 10 ** du if pv and pv["grossOut"] else None
        return self._usd[token]

    def native_usd(self):
        if self._native_usd == "unset":
            w = self.consts.get("WNATIVE_" + self.chain.upper())
            if not w:
                try:
                    w = abi.decode(["address"], self.call(self.a["router"], cd("weth")))[0]
                except (Reverted, RpcError):
                    w = None
            self._native_usd = self.usd_of(w) if w and w != ZERO else None
            self.wnative = w
        return self._native_usd

    def l1_fee(self, to, data, gas, value=0):
        """The L1 data fee of the tx: OP-stack GasPriceOracle.getL1Fee over the unsigned EIP-1559 RLP
        (Fjord adds the signature's 68 bytes itself) [derived]; Nitro NodeInterface
        gasEstimateL1Component on the real RPC [derived, not validated]; 0 on an L1."""
        base, prio = self.fees()
        try:
            if self.chain in OP_STACK:
                cid = int(self.node.call("eth_chainId", []), 16)
                tx = [cid, 0, prio or 0, (base or 0) + (prio or 0), gas or 0, bytes.fromhex(strip0x(to)), value,
                      bytes.fromhex(strip0x(data)), []]
                raw = "0x02" + rlp(tx).hex()
                return abi.decode(["uint256"], self.call(GPO, cd("getL1Fee", raw)))[0]
            if self.chain in NITRO:
                if not self.real:
                    return ""
                res = self.real.call("eth_call", [{"to": NODE_INTERFACE, "data": cd("gasEstimateL1Component", to, False, data)},
                                                  hex(self.block)])
                g, bf, _ = abi.decode(["uint64", "uint256", "uint256"], res)
                return g * bf
            return 0
        except (RpcError, Reverted, ValueError):
            return ""

    def net_usd(self, token, out, gas, l1):
        base, prio = self.fees()
        p, nu, d = self.usd_of(token), self.native_usd(), self.decimals(token)
        if None in (p, nu, d, base) or out in ("", None) or gas in ("", None) or l1 == "":
            return ""
        return round(out * p / 10 ** d - (gas * (base + (prio or 0)) + l1) * nu / 1e18, 6)

    # measurement
    def forced_route(self, tin, tout, amount, hops, legs):
        """(route', exactOut) of a forced shape, or (None, reason). Hop 2's legs split hop 1's
        exact output (the Quoter rescales each hop pro rata on its legs' sum, Quoter:829-870)."""
        sh = shape_legs(hops, legs)
        if sh is None:
            return None, "absent_by_code"
        if hops == 1:
            ps = self.pools(tin, tout)[:sh[0]]
            if len(ps) < sh[0]:
                return None, "too_few_pools"
            return self.exact(route([hop(tin, tout, ps, amount)]), amount)
        for b in self.bridges():
            if b == ZERO or b.lower() in (tin.lower(), tout.lower()):
                continue
            p1, p2 = self.pools(tin, b)[:sh[0]], self.pools(b, tout)[:sh[1]]
            if len(p1) < sh[0] or len(p2) < sh[1]:
                continue
            _, mid = self.exact(route([hop(tin, b, p1, amount)]), amount)
            if not isinstance(mid, int) or mid == 0:
                continue
            return self.exact(route([hop(tin, b, p1, amount), hop(b, tout, p2, mid)]), amount)
        return None, "too_few_pools"

    def best_single(self, cell):
        """Every pool of the pair alone as a 1-leg route: (rows, best row or None)."""
        tin, tout, amt = cell["token_in"], cell["token_out"], int(cell["amount_in"])
        rows = []
        for p in self.pools(tin, tout, kinds=None):
            snap = self.snapshot()
            try:
                row = dict(chain=self.chain, block=self.block, cell_id=cell["cell_id"], pool=p["pool"], kind=p["kind"],
                           out="", out_router="", gas="", gas_src="router_1leg", status="noquote")
                rr, out = self.exact(route([hop(tin, tout, [p], amt)]), amt)
                if rr is not None and out == 0 and p["kind"] == KIND_EXTERNAL:
                    row["status"] = "quoted_zero_by_view_port"
                elif rr is not None and out > 0 and self.fund(tin, amt):
                    data = cd("swapExactIn", rr, amt, 1, self.user, self.deadline)
                    b0 = self.balance(tout)
                    res = self.send(self.a["router"], data)
                    row["status"] = res["status"]
                    if res["status"] == "ok":
                        got = self.balance(tout) - b0
                        row.update(out_router=got, out=got * 10000 // (10000 - PROTOCOL_FEE_BPS), gas=res["gas"])
                        row["_data"] = data
                rows.append(row)
            finally:
                self.revert(snap)
        ok = [r for r in rows if r["status"] == "ok"]
        return rows, (max(ok, key=lambda r: r["out"]) if ok else None)

    def measure(self, cell, mode, best=None):
        """The cold and warm rows of one cell in one mode, and their timing rows; [] if the mode does
        not apply to the cell (native off the wrapped native, a shape absent by code)."""
        tin, tout, amt = cell["token_in"], cell["token_out"], int(cell["amount_in"])
        native = mode == "native"
        if native:
            self.native_usd()
            if tin.lower() != (self.wnative or "").lower():
                return self._absent(cell, mode, "native_needs_wrapped_native_in")
        if mode.startswith("forced:"):
            h, n = (int(x) for x in mode.split(":")[1].split("x"))
            if shape_legs(h, n) is None:
                return self._absent(cell, mode, "absent_by_code")
        base, _ = self.fees()
        rows, timing = [], []
        snap = self.snapshot()
        try:
            funded = self.fund(tin, 2 * amt, native=native)
            for temp in ("cold", "warm"):
                t0 = time.monotonic()
                row = {c: cell.get(c, "") for c in RESULT_COLS}
                row.update(chain=self.chain, block=self.block, mode=mode, temp=temp, basefee_wei=base if base else "",
                           native_usd=self.native_usd() or "", gas_est="", gas_real="", out_ours="",
                           hops="", legs="", topology="", net_usd_ours="")
                if best:
                    row.update(out_best_single=best["out"], best_single_pool=best["pool"],
                               net_usd_best=self.net_usd(tout, best["out"], best["gas"],
                                                         self.l1_fee(self.a["router"], best["_data"], best["gas"])))
                else:
                    row.update(out_best_single="", best_single_pool="", net_usd_best="")
                if not funded:
                    row["status"] = "noquote"
                    rows.append(row)
                    break
                value, data, r = 0, None, None
                if mode.startswith("forced:"):
                    h, n = (int(x) for x in mode.split(":")[1].split("x"))
                    r, x = self.forced_route(tin, tout, amt, h, n)
                    if r is None:
                        if x in ("absent_by_code", "too_few_pools"):
                            return self._absent(cell, mode, x)
                        row["status"] = "noquote"
                        rows.append(row)
                        break
                    if route_shape(r) != (h, n):
                        row["status"] = "noroute"
                        rows.append(row)
                        break
                    row.update(gas_est=r["estGas"])
                    data = cd("swapExactIn", r, amt, 1, self.user, self.deadline)
                else:
                    pv, _ = self.quote(tin, tout, amt)
                    if pv is None:
                        row["status"] = "noquote"
                        rows.append(row)
                        break
                    if not pv["canExecute"] or not pv["route"]["hops"]:
                        row["status"] = "noroute"
                        rows.append(row)
                        break
                    r = pv["route"]
                    row.update(gas_est=pv["estGas"])
                    if mode == "quoted":
                        data = cd("swapExactIn", r, amt, pv["effectiveMinOut"], self.user, self.deadline)
                    elif mode == "onchain":
                        data = cd("swapBestExactIn", tin, tout, amt, pv["effectiveMinOut"], self.user, self.deadline)
                    elif native:
                        data, value = cd("swapExactInNative", r, pv["effectiveMinOut"], self.user, self.deadline), amt
                    else:
                        raise ValueError(f"unknown mode {mode}")
                hops, legs = route_shape(r)
                row.update(hops=hops, legs=legs, topology=self.topology(r))
                to = self.a["router"]
                b0 = self.balance(tout)
                res = self.send(to, data, value)
                row["status"] = res["status"]
                l1 = ""
                if res["status"] == "ok":
                    out = self.balance(tout) - b0  # I2: the delivered amount, measured
                    if mode == "onchain":
                        row["legs"] = self.swap_legs(res["logs"], row["legs"])
                    l1 = self.l1_fee(to, data, res["gas"], value)
                    row.update(gas_real=res["gas"], out_ours=out, net_usd_ours=self.net_usd(tout, out, res["gas"], l1))
                rows.append(row)
                c = calldata_cost(data)
                timing.append(dict(chain=self.chain, cell_id=cell["cell_id"], mode=mode, temp=temp,
                                   wall_s=round(time.monotonic() - t0, 3), est_node=res.get("est", ""),
                                   cd_bytes=c[0], cd_zero=c[1], cd_gas=c[2], cd_floor=c[3], l1_fee_wei=l1,
                                   anvil_vmhwm_kib=vmhwm(self.anvil_pid) if self.anvil_pid else "",
                                   harness_maxrss_kib=resource.getrusage(resource.RUSAGE_SELF).ru_maxrss))
                if res["status"] != "ok":
                    break
        finally:
            self.revert(snap)
        return rows, timing

    def _absent(self, cell, mode, reason):
        self.absent.append(dict(chain=self.chain, cell_id=cell["cell_id"], mode=mode, reason=reason))
        return [], []

    def swap_legs(self, logs, default):
        """legs of the Router's own Swap event (src/BlazePhoenixRouter.sol:265,1706) [conferido]."""
        t0 = topic(SWAP_EVENT)
        for lg in logs:
            if lg["address"].lower() == self.a["router"].lower() and lg["topics"] and lg["topics"][0] == t0:
                return abi.decode(["uint256", "uint256", "uint256"], lg["data"])[2]
        return default


# ── output ──
def read_done(path, key=("cell_id", "mode")):
    if not os.path.exists(path):
        return set()
    with open(path) as f:
        cols = f.readline().rstrip("\n").split("\t")
        return {tuple(dict(zip(cols, ln.rstrip("\n").split("\t"))).get(k) for k in key) for ln in f if ln.strip()}


def append(path, cols, rows):
    new = not os.path.exists(path)
    with open(path, "a") as f:
        if new:
            f.write("\t".join(cols) + "\n")
        for r in rows:
            f.write("\t".join(str(r.get(c, "")) for c in cols) + "\n")


def cmd_cells(chain, prereg_path, outdir, node, real, addrs, block, nprime=8, modes=None, allow_unlocked=False,
              anvil_pid=None):
    grid = read_prereg(prereg_path, chain, allow_unlocked)
    os.makedirs(outdir, exist_ok=True)
    cells = [c for c in grid["rows"] if c["i"] < nprime]
    modes = modes or grid["modes"] or MODES
    s = Session(node, real, chain, addrs, block, grid["consts"], anvil_pid)
    res_p, best_p, tim_p = (os.path.join(outdir, f) for f in ("results.tsv", "best_single.tsv", "timing.tsv"))
    done = read_done(res_p)
    n = 0
    for cell in cells:
        todo = [m for m in modes if (cell["cell_id"], m) not in done]
        if not todo:
            continue
        brows, best = s.best_single(cell)
        append(best_p, BEST_COLS, brows)
        for m in todo:
            rows, timing = s.measure(cell, m, best)
            append(res_p, RESULT_COLS, rows)
            append(tim_p, TIMING_COLS, timing)
            append(os.path.join(outdir, "absent.tsv"), ABSENT_COLS, s.absent)
            s.absent = []
            n += len(rows)
    return n


def main(argv):
    if not argv:
        sys.exit(__doc__)
    cmd = argv[0]
    allow = "--allow-unlocked" in argv
    if cmd == "head":
        print(int(Rpc(argv[1]).call("eth_blockNumber", []), 16))
    elif cmd == "block":
        print(block_of(read_prereg(argv[2], argv[1], allow), argv[1]))
    elif cmd == "cells":
        chain, pre, outdir, url, addrs, block = argv[1:7]
        nprime = int(argv[argv.index("--nprime") + 1]) if "--nprime" in argv else 8
        modes = argv[argv.index("--modes") + 1].split(",") if "--modes" in argv else None
        real = None if os.environ.get("GCS_NO_REAL_RPC") else Rpc(chain)
        n = cmd_cells(chain, pre, outdir, Node(url), real, read_addrs(addrs), int(block), nprime, modes, allow,
                      os.environ.get("ANVIL_PID"))
        print(f"rows {n}")
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main(sys.argv[1:])
