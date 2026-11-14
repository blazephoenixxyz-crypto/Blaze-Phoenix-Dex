#!/usr/bin/env python3
"""Gas case study 1114, rule market: live aggregator quotes for draw i = 0 of every cell.

  python3 -I tools/gas-case-study/market.py <chain> <prereg.tsv> <out.tsv> \
      [--sources kyberswap,odos,openocean,paraswap,cow,lifi] [--limit N] [--rate S]

Pre-registration (docs/prereg/gas-1114.tsv): `rule market: i = 0 of each cell is also quoted on
the market sources (market.tsv)`. Every `cell` line of the chain is quoted (an `out` cell has no
`cell` line and is never quoted); the request carries the draw's amount_in (raw units of
token_in) exactly. Quotes are LIVE, taken at quote_unix, not at the fork block: the first line
of the output says so, the second gives the fork block timestamp so the lag can be computed.

Sources (no API key; a source that needs one or does not list the chain -> `unsupported`):
  kyberswap  GET  aggregator-api.kyberswap.com/<chain>/api/v1/routes        data.routeSummary.amountOut, .gas
             docs.kyberswap.com/kyberswap-solutions/kyberswap-aggregator/aggregator-api-specification/evm-swaps
  odos       POST api.odos.xyz/sor/quote/v2                                outAmounts[0], gasEstimate
             docs.odos.xyz/build/api-docs
  openocean  GET  open-api.openocean.finance/v4/<chain>/quote (amount in token units, not raw)
             data.outAmount, data.estimatedGas; apis.openocean.finance/developer/apis/swap-api/api-v4
  paraswap   GET  api.paraswap.io/prices (side=SELL, version=6.2)          priceRoute.destAmount, .gasCost
             developers.velora.xyz/api/velora-api/velora-market-api/get-rate-for-a-token-pair
  cow        POST api.cow.fi/<network>/api/v1/quote (kind=sell, sellAmountBeforeFee)
             quote.buyAmount, quote.gasAmount; github.com/cowprotocol/services crates/orderbook/openapi.yml
  lifi       GET  li.quest/v1/quote (same chain)                           estimate.toAmount, gasCosts[].estimate
             docs.li.fi/api-reference/get-a-quote-for-a-token-transfer
`from` / userAddr for every source: QUOTER_ADDR, a fixed address chosen for this study, holding no
key and no funds (quotes only, nothing is signed or sent).

Status in {ok, noroute, unsupported, rate_limited, http_err, timeout, bad_json}; every status other
than ok leaves amount_out EMPTY (absent is never zero; a source answering 0 is noroute, detail says
so). gas_estimate is the source's own gas field, raw, named in gas_field.
Politeness: one thread per source, >= --rate seconds between requests of a source, timeout 20 s,
2 retries with backoff on 429/5xx/timeout. After CIRCUIT consecutive http_err rows a source is
paused: the next rows are http_err with an empty http_code and detail `not sent: circuit open`,
with one real probe every PROBE_EVERY rows.
latest_block: eth_blockNumber on dRPC (key in ~/.drpc-key; the key and the URL are never written).
Stdlib only.
"""
import argparse
import hashlib
import http.client
import json
import os
import socket
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from decimal import Decimal

COLUMNS = ("chain cell_id i token_in token_out amount_in source status amount_out gas_estimate "
           "gas_field quote_unix latest_block http_code latency_ms resp_sha256 detail").split()
STATUSES = ("ok", "noroute", "unsupported", "rate_limited", "http_err", "timeout", "bad_json")
ALL_SOURCES = ("kyberswap", "odos", "openocean", "paraswap", "cow", "lifi")
QUOTER_ADDR = "0x0000000000000000000000000000000000001114"
TIMEOUT_S = 20
RETRIES = 2
BACKOFF_S = (2.0, 4.0)
CIRCUIT = 3
PROBE_EVERY = 10
UA = "bp-dex gas-case-study/1114 (research; low rate)"

# chain ids checked with eth_chainId on dRPC, 2026-11-14
CHAIN_ID = {"base": 8453, "ethereum": 1, "optimism": 10, "arbitrum": 42161, "robinhood": 4663,
            "avalanche": 43114, "bsc": 56}
# per-source network names; a chain absent from a map is `unsupported` for that source
KYBER_NET = {"base": "base", "ethereum": "ethereum", "optimism": "optimism", "arbitrum": "arbitrum",
             "avalanche": "avalanche", "bsc": "bsc", "robinhood": "robinhood"}
OO_NET = {"base": "base", "ethereum": "eth", "optimism": "optimism", "arbitrum": "arbitrum",
          "avalanche": "avax", "bsc": "bsc", "robinhood": "4663"}  # robinhood by chain id [unverified]
COW_NET = {"ethereum": "mainnet", "arbitrum": "arbitrum_one", "base": "base",
           "avalanche": "avalanche", "bsc": "bnb", "robinhood": "robinhood"}
# robinhood: KyberSwap answered a route, ParaSwap parsed network 4663, LI.FI lists chain 4663 (probed
# 2026-11-14); Odos (docs down) and OpenOcean (blocked) unverified, so they are asked and the answer kept
ODOS_CHAINS = {"base", "ethereum", "optimism", "arbitrum", "avalanche", "bsc", "robinhood"}
PARASWAP_CHAINS = {"base", "ethereum", "optimism", "arbitrum", "avalanche", "bsc", "robinhood"}
LIFI_CHAINS = {"base", "ethereum", "optimism", "arbitrum", "avalanche", "bsc", "robinhood"}


class Unsupported(Exception):
    pass


# ---------------------------------------------------------------- prereg

def read_prereg(path, chain, limit=None):
    """(fork_block, [draw dict]) for draw i = 0 of every `cell` of the chain not listed `out`."""
    fork_block, cells, outs, draws = None, [], set(), {}
    with open(path) as f:
        for line in f:
            p = line.rstrip("\n").split("\t")
            if p[0] == "block" and p[1] == chain:
                fork_block = int(p[2])
            elif p[0] == "cell" and p[2] == chain:
                cells.append(p[1])
            elif p[0] == "out":
                outs.add(p[1])
            elif p[0] == "draw" and p[2] == "0":
                draws[p[1]] = {"cell_id": p[1], "i": 0, "token_in": p[3], "token_out": p[4],
                               "size_usd": p[6], "amount_in": p[7]}
    if fork_block is None:
        raise SystemExit("no block line for chain %s" % chain)
    sel = []
    for c in cells:
        if c in outs:
            continue
        d = draws.get(c)
        if d is None:
            raise SystemExit("cell %s has no draw i=0" % c)
        int(d["amount_in"])  # raw integer or fail
        sel.append(d)
    if limit is not None:
        sel = sel[:limit]
    return fork_block, sel


# ---------------------------------------------------------------- requests per source

def human_amount(raw, decimals):
    return format(Decimal(int(raw)).scaleb(-int(decimals)), "f")


def build(source, chain, d, ctx):
    """(method, url, headers, body) for one quote; raises Unsupported."""
    cid = CHAIN_ID[chain]
    ti, to, a = d["token_in"], d["token_out"], d["amount_in"]
    jh = {"Content-Type": "application/json", "Accept": "application/json"}
    if source == "kyberswap":
        if chain not in KYBER_NET:
            raise Unsupported("chain not in KyberSwap aggregator list")
        q = urllib.parse.urlencode({"tokenIn": ti, "tokenOut": to, "amountIn": a})
        return ("GET", "https://aggregator-api.kyberswap.com/%s/api/v1/routes?%s" % (KYBER_NET[chain], q),
                {"x-client-id": "bp-dex-gas-case-study", "Accept": "application/json"}, None)
    if source == "odos":
        if chain not in ODOS_CHAINS:
            raise Unsupported("chain not in Odos list")
        body = {"chainId": cid, "inputTokens": [{"tokenAddress": ti, "amount": a}],
                "outputTokens": [{"tokenAddress": to, "proportion": 1}], "userAddr": QUOTER_ADDR,
                "slippageLimitPercent": 0.5, "compact": True}
        return ("POST", "https://api.odos.xyz/sor/quote/v2", jh, json.dumps(body).encode())
    if source == "openocean":
        if chain not in OO_NET:
            raise Unsupported("chain not in OpenOcean list")
        dec = ctx.get("decimals", {}).get(ti.lower())
        gp = ctx.get("gas_price_gwei")
        if dec is None or gp is None:
            raise Unsupported("decimals or gas price unavailable (needed: amount is in token units)")
        q = urllib.parse.urlencode({"inTokenAddress": ti, "outTokenAddress": to,
                                    "amount": human_amount(a, dec), "gasPrice": gp})
        return ("GET", "https://open-api.openocean.finance/v4/%s/quote?%s" % (OO_NET[chain], q),
                {"Accept": "application/json"}, None)
    if source == "paraswap":
        if chain not in PARASWAP_CHAINS:
            raise Unsupported("chain not in ParaSwap list")
        dm = ctx.get("decimals", {})
        if ti.lower() not in dm or to.lower() not in dm:
            raise Unsupported("token decimals unavailable (required by ParaSwap)")
        q = urllib.parse.urlencode({"srcToken": ti, "destToken": to, "amount": a,
                                    "srcDecimals": dm[ti.lower()], "destDecimals": dm[to.lower()],
                                    "side": "SELL", "network": cid, "version": "6.2"})
        return ("GET", "https://api.paraswap.io/prices?%s" % q, {"Accept": "application/json"}, None)
    if source == "cow":
        if chain not in COW_NET:
            raise Unsupported("network not in CoW orderbook servers")
        body = {"sellToken": ti, "buyToken": to, "from": QUOTER_ADDR, "receiver": QUOTER_ADDR,
                "kind": "sell", "sellAmountBeforeFee": a}
        return ("POST", "https://api.cow.fi/%s/api/v1/quote" % COW_NET[chain], jh, json.dumps(body).encode())
    if source == "lifi":
        if chain not in LIFI_CHAINS:
            raise Unsupported("chain not in LI.FI list")
        q = urllib.parse.urlencode({"fromChain": cid, "toChain": cid, "fromToken": ti, "toToken": to,
                                    "fromAmount": a, "fromAddress": QUOTER_ADDR})
        return ("GET", "https://li.quest/v1/quote?%s" % q, {"Accept": "application/json"}, None)
    raise ValueError("unknown source %s" % source)


def _uint(v):
    if isinstance(v, bool) or v is None:
        return None
    s = str(v)
    return s if s.isdigit() else None


def _msg(j):
    if isinstance(j, dict):
        for k in ("message", "error", "description", "errorType", "detail"):
            if j.get(k):
                return str(j.get(k))
    return ""


NOROUTE_WORDS = ("no route", "route not found", "not found route", "no routes", "no available quotes",
                 "noliquidity", "no liquidity", "insufficient liquidity", "no viable", "path not found",
                 "unsupportedtoken", "sellamountdoesnotcoverfee", "estimated_loss", "price impact",
                 "none of the available routes")
UNSUPPORTED_WORDS = ("unsupported chain", "chain not supported", "invalid network", "network not supported",
                     "chain is not supported", "unsupported network", "api key", "apikey", "unauthorized")


def classify_error(code, j):
    m = (_msg(j) + " " + json.dumps(j)[:400] if j is not None else "").lower()
    if any(w in m for w in UNSUPPORTED_WORDS) or code in (401,):
        return "unsupported"
    if any(w in m for w in NOROUTE_WORDS):
        return "noroute"
    return "http_err"


def parse(source, code, body):
    """(status, amount_out, gas_estimate, gas_field, detail) from one final HTTP answer."""
    try:
        j = json.loads(body.decode("utf-8"))
    except (ValueError, UnicodeDecodeError):
        j = None
    if code == 429:
        return ("rate_limited", "", "", "", "429")
    if j is None:
        if code == 200:
            return ("bad_json", "", "", "", "200 body is not JSON")
        snippet = body[:80].decode("utf-8", "replace")
        return ("http_err", "", "", "", "non-JSON %d: %s" % (code, snippet))
    if code >= 500:
        return (classify_error(code, j) if classify_error(code, j) == "noroute" else "http_err",
                "", "", "", _msg(j))
    out, gas, gf = None, "", ""
    if code == 200 and isinstance(j, dict):
        try:
            if source == "kyberswap":
                if j.get("code") not in (0, None):
                    return (classify_error(code, j), "", "", "", "code %s %s" % (j.get("code"), _msg(j)))
                rs = j["data"]["routeSummary"]
                out, gas, gf = _uint(rs["amountOut"]), rs.get("gas", ""), "data.routeSummary.gas"
            elif source == "odos":
                out, gas, gf = _uint(j["outAmounts"][0]), j.get("gasEstimate", ""), "gasEstimate"
            elif source == "openocean":
                if j.get("code") not in (200, None):
                    return (classify_error(code, j), "", "", "", "code %s %s" % (j.get("code"), _msg(j)))
                dd = j["data"]
                out, gas, gf = _uint(dd["outAmount"]), dd.get("estimatedGas", ""), "data.estimatedGas"
            elif source == "paraswap":
                if "priceRoute" not in j and _msg(j):
                    return (classify_error(code, j), "", "", "", _msg(j))
                pr = j["priceRoute"]
                out, gas, gf = _uint(pr["destAmount"]), pr.get("gasCost", ""), "priceRoute.gasCost"
            elif source == "cow":
                qq = j["quote"]
                out, gas, gf = _uint(qq["buyAmount"]), qq.get("gasAmount", ""), "quote.gasAmount"
                extra = "feeAmount=%s sellAmount=%s" % (qq.get("feeAmount"), qq.get("sellAmount"))
            elif source == "lifi":
                e = j["estimate"]
                gc = e.get("gasCosts") or []
                ests = [_uint(g.get("estimate")) for g in gc]
                if ests and all(x is not None for x in ests):
                    gas = str(sum(int(x) for x in ests))
                    gf = "sum(estimate.gasCosts[].estimate) n=%d" % len(ests)
                out = _uint(e["toAmount"])
                extra = "tool=%s" % j.get("tool", "")
        except (KeyError, IndexError, TypeError) as ex:
            return ("bad_json", "", "", "", "200 missing field %s" % ex)
        if out is None:
            return ("bad_json", "", "", "", "200 amount_out not a non-negative integer")
        if int(out) == 0:
            return ("noroute", "", "", "", "source returned amount_out 0")
        det = extra if source in ("cow", "lifi") else ""
        return ("ok", out, "" if gas is None else str(gas), gf, det)
    if code == 200:
        return ("bad_json", "", "", "", "200 JSON is not an object")
    return (classify_error(code, j), "", "", "", "%d %s" % (code, _msg(j)))


# ---------------------------------------------------------------- transport and rpc

def http_transport(method, url, headers, body, timeout):
    """(code, body_bytes); raises TimeoutError on timeout, OSError on connection failure."""
    h = dict(headers)
    h.setdefault("User-Agent", UA)
    req = urllib.request.Request(url, data=body, headers=h, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, r.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()
    except urllib.error.URLError as e:
        if isinstance(e.reason, (socket.timeout, TimeoutError)):
            raise TimeoutError(str(e.reason))
        raise OSError("url error: %s" % type(e.reason).__name__)
    except socket.timeout as e:
        raise TimeoutError(str(e))
    except http.client.HTTPException as e:  # e.g. IncompleteRead: a broken answer, retried like a reset
        raise OSError("http error: %s" % type(e).__name__)


def make_rpc(chain, transport=http_transport):
    path = os.path.expanduser("~/.drpc-key")
    if not os.path.exists(path):
        return None
    url = "https://lb.drpc.live/%s/%s" % (chain, open(path).read().strip())

    def rpc(method, params):
        body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
        try:
            code, b = transport("POST", url, {"Content-Type": "application/json"}, body, TIMEOUT_S)
            return json.loads(b).get("result") if code == 200 else None
        except Exception:  # never surface the URL (it holds the key)
            return None
    return rpc


class BlockCache:
    def __init__(self, rpc, ttl=1.0):
        self.rpc, self.ttl, self.lock, self.t, self.v = rpc, ttl, threading.Lock(), 0.0, ""

    def get(self):
        if self.rpc is None:
            return ""
        with self.lock:
            if time.time() - self.t > self.ttl:
                r = self.rpc("eth_blockNumber", [])
                self.v = str(int(r, 16)) if isinstance(r, str) and r.startswith("0x") else ""
                self.t = time.time()
            return self.v


def chain_context(rpc, draws, fork_block):
    ctx = {"decimals": {}, "gas_price_gwei": None, "fork_unix": ""}
    if rpc is None:
        return ctx
    for t in sorted({d["token_in"].lower() for d in draws} | {d["token_out"].lower() for d in draws}):
        r = rpc("eth_call", [{"to": t, "data": "0x313ce567"}, "latest"])
        if isinstance(r, str) and len(r) >= 3:
            ctx["decimals"][t] = int(r, 16)
    gp = rpc("eth_gasPrice", [])
    if isinstance(gp, str) and gp.startswith("0x"):
        ctx["gas_price_gwei"] = format(Decimal(int(gp, 16)).scaleb(-9), "f")
    b = rpc("eth_getBlockByNumber", [hex(fork_block), False])
    if isinstance(b, dict) and b.get("timestamp"):
        ctx["fork_unix"] = str(int(b["timestamp"], 16))
    return ctx


# ---------------------------------------------------------------- one quote

def quote(source, chain, d, ctx, transport, blocks, sleep=time.sleep, clock=time.time):
    row = {"chain": chain, "cell_id": d["cell_id"], "i": str(d["i"]), "token_in": d["token_in"],
           "token_out": d["token_out"], "amount_in": d["amount_in"], "source": source}
    try:
        method, url, headers, body = build(source, chain, d, ctx)
    except Unsupported as e:
        row.update(status="unsupported", quote_unix=str(int(clock())), detail=str(e))
        return row, 0
    sent = 0
    for attempt in range(RETRIES + 1):
        t0 = clock()
        sent += 1
        try:
            code, resp = transport(method, url, headers, body, TIMEOUT_S)
        except TimeoutError:
            code, resp = None, b""
        except OSError as e:
            if attempt < RETRIES:
                sleep(BACKOFF_S[attempt])
                continue
            row.update(status="http_err", quote_unix=str(int(t0)), latency_ms=str(int((clock() - t0) * 1000)),
                       latest_block=blocks.get(), detail="%s after %d tries" % (str(e)[:120], sent))
            return row, sent
        lat = int((clock() - t0) * 1000)
        retry = code is None or code == 429 or code >= 500
        if retry and attempt < RETRIES:
            sleep(BACKOFF_S[attempt])
            continue
        row.update(quote_unix=str(int(t0)), latency_ms=str(lat), latest_block=blocks.get())
        if code is None:
            row.update(status="timeout", detail="no answer in %d s after %d tries" % (TIMEOUT_S, sent))
            return row, sent
        st, out, gas, gf, det = parse(source, code, resp)
        row.update(status=st, amount_out=out, gas_estimate=gas, gas_field=gf, http_code=str(code),
                   resp_sha256=hashlib.sha256(resp).hexdigest(), detail=det)
        return row, sent
    raise AssertionError("unreachable")


def clean(v):
    return str(v).replace("\t", " ").replace("\n", " ").replace("\r", " ")[:240]


def fmt(row):
    assert row["status"] in STATUSES, row["status"]
    if row["status"] != "ok":
        assert row.get("amount_out", "") == "", "absent must stay empty"
    return "\t".join(clean(row.get(c, "")) for c in COLUMNS)


def header_lines(fork_block, fork_unix):
    return ["# market quotes are taken at quote_unix (live), not at fork_block %d; "
            "lag = quote time − fork block time" % fork_block,
            "# fork_block_unix %s" % fork_unix,
            "\t".join(COLUMNS)]


def run_source(source, chain, draws, ctx, transport, blocks, rate, emit, sleep=time.sleep, clock=time.time):
    fails, since_probe, last_t = 0, 0, 0.0
    for d in draws:
        if fails >= CIRCUIT and since_probe < PROBE_EVERY - 1:
            since_probe += 1
            emit({"chain": chain, "cell_id": d["cell_id"], "i": str(d["i"]), "token_in": d["token_in"],
                  "token_out": d["token_out"], "amount_in": d["amount_in"], "source": source,
                  "status": "http_err", "quote_unix": str(int(clock())),
                  "detail": "not sent: circuit open after %d consecutive http_err" % fails})
            continue
        since_probe = 0
        wait = rate - (clock() - last_t)
        if wait > 0:
            sleep(wait)
        last_t = clock()
        try:
            row, sent = quote(source, chain, d, ctx, transport, blocks, sleep, clock)
        except Exception as e:  # one broken quote never loses the row nor the rest of the source
            row = {"chain": chain, "cell_id": d["cell_id"], "i": str(d["i"]), "token_in": d["token_in"],
                   "token_out": d["token_out"], "amount_in": d["amount_in"], "source": source,
                   "status": "http_err", "quote_unix": str(int(last_t)),
                   "detail": "unexpected %s" % type(e).__name__}
        fails = fails + 1 if row["status"] == "http_err" else 0
        emit(row)


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("chain", choices=sorted(CHAIN_ID))
    ap.add_argument("prereg")
    ap.add_argument("out")
    ap.add_argument("--sources", default=",".join(ALL_SOURCES))
    ap.add_argument("--limit", type=int)
    ap.add_argument("--rate", type=float, default=1.0)
    a = ap.parse_args(argv)
    sources = [s for s in a.sources.split(",") if s]
    bad = [s for s in sources if s not in ALL_SOURCES]
    if bad:
        raise SystemExit("unknown sources %s" % bad)
    fork_block, draws = read_prereg(a.prereg, a.chain, a.limit)
    rpc = make_rpc(a.chain)
    ctx = chain_context(rpc, draws, fork_block)
    blocks = BlockCache(rpc)
    rows, lock = [], threading.Lock()
    os.makedirs(os.path.dirname(os.path.abspath(a.out)), exist_ok=True)
    part = a.out + ".part"
    with open(part, "w") as pf:
        pf.write("\n".join(header_lines(fork_block, ctx["fork_unix"])) + "\n")

        def emit(row):
            line = fmt(row)
            with lock:
                rows.append(row)
                pf.write(line + "\n")
                pf.flush()
        th = [threading.Thread(target=run_source, args=(s, a.chain, draws, ctx, http_transport, blocks,
                                                        a.rate, emit), daemon=True) for s in sources]
        for t in th:
            t.start()
        for t in th:
            t.join()
    order = {d["cell_id"]: k for k, d in enumerate(draws)}
    rows.sort(key=lambda r: (order[r["cell_id"]], ALL_SOURCES.index(r["source"])))
    with open(a.out, "w") as f:
        f.write("\n".join(header_lines(fork_block, ctx["fork_unix"])) + "\n")
        for r in rows:
            f.write(fmt(r) + "\n")
    os.remove(part)
    n = {}
    for r in rows:
        n[(r["source"], r["status"])] = n.get((r["source"], r["status"]), 0) + 1
    sys.stderr.write("%s cells=%d rows=%d %s\n" % (a.chain, len(draws), len(rows),
                     " ".join("%s:%s=%d" % (k[0], k[1], v) for k, v in sorted(n.items()))))


if __name__ == "__main__":
    main()
