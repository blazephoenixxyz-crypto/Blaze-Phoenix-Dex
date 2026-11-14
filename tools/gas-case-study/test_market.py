#!/usr/bin/env python3
"""Tests for market.py (rule market of docs/prereg/gas-1114.tsv). No network: the HTTP transport
and the RPC are fakes injected into quote()/run_source().

  python3 -I tools/gas-case-study/test_market.py

Each test names the mutant of market.py that turns it red (SA6 ran them on a copy).
"""
import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import market as M  # noqa: E402

WETH = "0x4200000000000000000000000000000000000006"
USDC = "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913"
CTX = {"decimals": {WETH: 18, USDC: 6}, "gas_price_gwei": "0.006", "fork_unix": "1"}

OK = {
    "kyberswap": {"code": 0, "data": {"routeSummary": {"amountOut": "18914930", "gas": "1135270"}}},
    "odos": {"outAmounts": ["18914931"], "gasEstimate": 250000},
    "openocean": {"code": 200, "data": {"outAmount": "18914932", "estimatedGas": "190000"}},
    "paraswap": {"priceRoute": {"destAmount": "18914933", "gasCost": "206700"}},
    "cow": {"quote": {"buyAmount": "18914934", "gasAmount": "294871", "feeAmount": "1", "sellAmount": "2"}},
    "lifi": {"estimate": {"toAmount": "18914935", "gasCosts": [{"estimate": "820175"}, {"estimate": "5"}]},
             "tool": "fly"},
}
NOROUTE = {
    "kyberswap": (400, {"code": 4008, "message": "route not found"}),
    "odos": (400, {"detail": "Error getting quote, no viable path found"}),
    "openocean": (200, {"code": 201, "message": "no route"}),
    "paraswap": (404, {"error": "No routes found with enough liquidity"}),
    "cow": (404, {"errorType": "NoLiquidity", "description": "no route found"}),
    "lifi": (404, {"message": "No available quotes for the requested transfer", "code": 1002}),
}
GAS_FIELD = {"kyberswap": "data.routeSummary.gas", "odos": "gasEstimate", "openocean": "data.estimatedGas",
             "paraswap": "priceRoute.gasCost", "cow": "quote.gasAmount",
             "lifi": "sum(estimate.gasCosts[].estimate) n=2"}


def draw(amount="10000000000000000", cell="base:WETH/USDC:k1"):
    return {"cell_id": cell, "i": 0, "token_in": WETH, "token_out": USDC, "size_usd": "18.9", "amount_in": amount}


class FakeTransport:
    """Answers from a script of (code, body) or exceptions; records every request."""

    def __init__(self, answers):
        self.answers, self.calls = list(answers), []

    def __call__(self, method, url, headers, body, timeout):
        self.calls.append((method, url, headers, body, timeout))
        a = self.answers.pop(0) if len(self.answers) > 1 else self.answers[0]
        if isinstance(a, BaseException):
            raise a
        code, b = a
        return code, b if isinstance(b, bytes) else json.dumps(b).encode()


class Blocks:
    def get(self):
        return "123"


class Clock:
    def __init__(self):
        self.t = 1000.0

    def __call__(self):
        self.t += 0.01
        return self.t


def q(source, answers, d=None, chain="base"):
    t = FakeTransport(answers)
    sleeps = []
    row, sent = M.quote(source, chain, d or draw(), CTX, t, Blocks(), sleep=sleeps.append, clock=Clock())
    return row, sent, t, sleeps


class TestParse(unittest.TestCase):
    # mutant P1: wrong JSON path for amount_out of any source -> red
    def test_ok_each_source(self):
        for s in M.ALL_SOURCES:
            with self.subTest(source=s):
                row, sent, t, _ = q(s, [(200, OK[s])])
                self.assertEqual(row["status"], "ok")
                self.assertEqual(row["amount_out"], str(1891493 * 10 + M.ALL_SOURCES.index(s)))
                self.assertEqual(row["gas_field"], GAS_FIELD[s])
                self.assertEqual(sent, 1)
                self.assertEqual(len(row["resp_sha256"]), 64)
                self.assertEqual(row["latest_block"], "123")

    # mutant P2: lifi gas = first gasCosts entry instead of the sum -> red
    def test_lifi_gas_is_sum_raw(self):
        row, *_ = q("lifi", [(200, OK["lifi"])])
        self.assertEqual(row["gas_estimate"], "820180")

    # mutant P3: noroute words removed / classify_error returns http_err -> red
    def test_noroute_each_source(self):
        for s in M.ALL_SOURCES:
            with self.subTest(source=s):
                row, *_ = q(s, [NOROUTE[s]])
                self.assertEqual(row["status"], "noroute")
                self.assertEqual(row.get("amount_out", ""), "")

    # mutant P4: 429 not retried, or 429 mapped to http_err -> red
    def test_429_retried_then_rate_limited(self):
        for s in M.ALL_SOURCES:
            with self.subTest(source=s):
                row, sent, t, sleeps = q(s, [(429, {"message": "Too Many Requests"})])
                self.assertEqual(row["status"], "rate_limited")
                self.assertEqual(sent, M.RETRIES + 1)
                self.assertEqual(sleeps, list(M.BACKOFF_S[:M.RETRIES]))
                self.assertEqual(row.get("amount_out", ""), "")

    # mutant P5: 5xx not retried -> red (sent == 1)
    def test_5xx_retried_then_http_err(self):
        for s in M.ALL_SOURCES:
            with self.subTest(source=s):
                row, sent, *_ = q(s, [(530, b"error code: 1033")])
                self.assertEqual(row["status"], "http_err")
                self.assertEqual(sent, M.RETRIES + 1)

    def test_5xx_then_ok_recovers(self):
        row, sent, *_ = q("kyberswap", [(502, b"bad gateway"), (200, OK["kyberswap"])])
        self.assertEqual((row["status"], sent), ("ok", 2))

    # mutant P6: non-JSON 200 treated as ok/http_err -> red
    def test_bad_json(self):
        for s in M.ALL_SOURCES:
            with self.subTest(source=s):
                row, *_ = q(s, [(200, b"<html>not json")])
                self.assertEqual(row["status"], "bad_json")
                row, *_ = q(s, [(200, {"unexpected": 1})])
                self.assertEqual(row["status"], "bad_json")
                self.assertEqual(row.get("amount_out", ""), "")

    # mutant P7: timeout mapped to http_err or not retried -> red
    def test_timeout(self):
        for s in M.ALL_SOURCES:
            with self.subTest(source=s):
                row, sent, *_ = q(s, [TimeoutError("t")])
                self.assertEqual(row["status"], "timeout")
                self.assertEqual(sent, M.RETRIES + 1)

    # mutant P8: connection error not retried -> red
    def test_connection_error_retried(self):
        row, sent, *_ = q("kyberswap", [OSError("url error: ConnectionResetError"), (200, OK["kyberswap"])])
        self.assertEqual((row["status"], sent), ("ok", 2))

    # mutant P9: amount_out "0" written as ok 0 -> red (absent is never zero)
    def test_zero_is_not_a_quote(self):
        z = {"code": 0, "data": {"routeSummary": {"amountOut": "0", "gas": "1"}}}
        row, *_ = q("kyberswap", [(200, z)])
        self.assertEqual(row["status"], "noroute")
        self.assertEqual(row.get("amount_out", ""), "")

    def test_non_integer_amount_is_bad_json(self):
        for v in ("-1", "1.5", "", None, True):
            z = {"priceRoute": {"destAmount": v, "gasCost": "1"}}
            row, *_ = q("paraswap", [(200, z)])
            self.assertEqual(row["status"], "bad_json", v)

    # mutant P10: html 403 (WAF) mapped to bad_json -> red
    def test_waf_403_is_http_err(self):
        row, sent, *_ = q("openocean", [(403, b"<!DOCTYPE html> blocked")])
        self.assertEqual((row["status"], row["http_code"], sent), ("http_err", "403", 1))

    def test_api_key_error_is_unsupported(self):
        row, *_ = q("lifi", [(401, {"message": "Unauthorized: api key required"})])
        self.assertEqual(row["status"], "unsupported")


class TestRequest(unittest.TestCase):
    # mutant R1: amount_in rounded / formatted (int(float())) -> red: 1 wei changes the request
    def test_amount_exact_plus_minus_one_wei(self):
        big = "123456789012345678901234567"
        for s in M.ALL_SOURCES:
            with self.subTest(source=s):
                reqs = [M.build(s, "base", draw(a), CTX) for a in (str(int(big) - 1), big, str(int(big) + 1))]
                self.assertEqual(len({(r[1], r[3]) for r in reqs}), 3)
                if s != "openocean":
                    blob = reqs[1][1] + (reqs[1][3] or b"").decode()
                    self.assertIn(big, blob)

    # mutant R2: openocean amount with wrong decimals (dec - 1) -> red
    def test_openocean_amount_units(self):
        r = M.build("openocean", "base", draw("1"), CTX)
        self.assertIn("amount=0.000000000000000001&", r[1])
        r = M.build("openocean", "base", draw("10000000000000000"), CTX)
        self.assertIn("amount=0.010000000000000000&", r[1])

    # mutant R3: robinhood/optimism maps changed -> red
    def test_unsupported_is_status_not_zero(self):
        row, sent, t, _ = q("cow", [(200, OK["cow"])], chain="optimism")
        self.assertEqual((row["status"], sent, t.calls), ("unsupported", 0, []))
        self.assertEqual(row.get("amount_out", ""), "")
        for s in ("kyberswap", "paraswap", "lifi", "cow"):
            self.assertIsNotNone(M.build(s, "robinhood", draw(), CTX))

    def test_paraswap_needs_decimals(self):
        with self.assertRaises(M.Unsupported):
            M.build("paraswap", "base", draw(), {"decimals": {}})

    def test_chain_ids(self):
        self.assertEqual(M.CHAIN_ID, {"base": 8453, "ethereum": 1, "optimism": 10, "arbitrum": 42161,
                                      "robinhood": 4663, "avalanche": 43114, "bsc": 56})

    def test_direction_kept(self):
        for s in M.ALL_SOURCES:
            r = M.build(s, "base", draw(), CTX)
            blob = r[1] + (r[3] or b"").decode()
            self.assertLess(blob.index(WETH), blob.index(USDC), s)


PREREG = "\n".join([
    "block\tbase\t100\t10\t4\t%s\t2" % WETH,
    "block\tethereum\t200\t10\t4\t0xc02a\t2",
    "cell\tbase:A/B:k0\tbase\t100\ta\tb\tk0\t1\tbalances\t8\tm\tcold",
    "cell\tbase:A/B:k1\tbase\t100\ta\tb\tk1\t1\tbalances\t8\tm\tcold",
    "cell\tethereum:A/B:k0\tethereum\t200\ta\tb\tk0\t1\tbalances\t8\tm\tcold",
    "out\tbase:A/B:k7\tbucket floor 1e+07 USD >= whale 1 USD",
    "draw\tbase:A/B:k0\t0\t%s\t%s\ts\t1.0\t1000" % (WETH, USDC),
    "draw\tbase:A/B:k0\t1\t%s\t%s\ts\t1.0\t2000" % (USDC, WETH),
    "draw\tbase:A/B:k1\t0\t%s\t%s\ts\t10.0\t3000" % (WETH, USDC),
    "draw\tbase:A/B:k1\t2\t%s\t%s\ts\t10.0\t4000" % (WETH, USDC),
    "draw\tbase:A/B:k7\t0\t%s\t%s\ts\t1e7\t5000" % (WETH, USDC),
    "draw\tethereum:A/B:k0\t0\ta\tb\ts\t1.0\t6000",
]) + "\n"


class TestSelection(unittest.TestCase):
    def setUp(self):
        fd, self.p = tempfile.mkstemp()
        with os.fdopen(fd, "w") as f:
            f.write(PREREG)

    def tearDown(self):
        os.remove(self.p)

    # mutant S1: draws of every i selected / S2: chain filter dropped / S3: out cells quoted -> red
    def test_only_i0_of_non_out_cells_of_chain(self):
        fb, ds = M.read_prereg(self.p, "base")
        self.assertEqual(fb, 100)
        self.assertEqual([(d["cell_id"], d["amount_in"]) for d in ds], [("base:A/B:k0", "1000"), ("base:A/B:k1", "3000")])

    def test_out_cell_with_cell_line_is_skipped(self):
        with open(self.p, "a") as f:
            f.write("cell\tbase:A/B:k7\tbase\t100\ta\tb\tk7\t1\tbalances\t8\tm\tcold\n")
        _, ds = M.read_prereg(self.p, "base")
        self.assertNotIn("base:A/B:k7", [d["cell_id"] for d in ds])

    def test_limit(self):
        _, ds = M.read_prereg(self.p, "base", limit=1)
        self.assertEqual(len(ds), 1)


class TestOutput(unittest.TestCase):
    # mutant O1: column added/reordered -> red
    def test_header_and_columns_fixed(self):
        self.assertEqual(M.COLUMNS, ["chain", "cell_id", "i", "token_in", "token_out", "amount_in", "source",
                                     "status", "amount_out", "gas_estimate", "gas_field", "quote_unix",
                                     "latest_block", "http_code", "latency_ms", "resp_sha256", "detail"])
        h = M.header_lines(57207430, "1794631861")
        self.assertEqual(h[0], "# market quotes are taken at quote_unix (live), not at fork_block 57207430; "
                               "lag = quote time − fork block time")
        self.assertEqual(h[2].split("\t"), M.COLUMNS)

    # mutant O2: fmt drops the absent-is-empty assertion and writes 0 -> red
    def test_absent_never_zero_in_line(self):
        for s in M.ALL_SOURCES:
            for ans in ([(429, b"x")], [(530, b"x")], [(200, b"x")], [TimeoutError()], [NOROUTE[s]]):
                row, *_ = q(s, ans)
                cols = M.fmt(row).split("\t")
                self.assertEqual(len(cols), len(M.COLUMNS))
                self.assertEqual(cols[M.COLUMNS.index("amount_out")], "")
        with self.assertRaises(AssertionError):
            M.fmt({"status": "noroute", "amount_out": "0"})
        with self.assertRaises(AssertionError):
            M.fmt({"status": "weird"})

    def test_detail_has_no_tab_or_newline(self):
        row, *_ = q("paraswap", [(404, {"error": "No routes\tfound\nwith enough liquidity"})])
        self.assertEqual(len(M.fmt(row).split("\t")), len(M.COLUMNS))


class TestRunSource(unittest.TestCase):
    # mutant C1: circuit never opens (CIRCUIT huge) or opens on noroute -> red
    def test_circuit_opens_after_consecutive_http_err_and_probes(self):
        t, rows, sleeps = FakeTransport([(403, b"<html>")]), [], []
        ds = [draw(cell="c%d" % k) for k in range(15)]
        M.run_source("openocean", "base", ds, CTX, t, Blocks(), 0.0, rows.append, sleep=sleeps.append, clock=Clock())
        self.assertEqual(len(rows), 15)
        self.assertEqual(len(t.calls), M.CIRCUIT + 1 + (15 - M.CIRCUIT - M.PROBE_EVERY) // M.PROBE_EVERY)
        self.assertTrue(all(r["status"] == "http_err" and r.get("amount_out", "") == "" for r in rows))
        self.assertTrue(rows[M.CIRCUIT]["detail"].startswith("not sent: circuit open"))

    def test_noroute_does_not_open_circuit(self):
        t, rows = FakeTransport([NOROUTE["paraswap"]]), []
        ds = [draw(cell="c%d" % k) for k in range(6)]
        M.run_source("paraswap", "base", ds, CTX, t, Blocks(), 0.0, rows.append, sleep=lambda s: None, clock=Clock())
        self.assertEqual(len(t.calls), 6)

    # mutant C2: rate wait removed -> red
    def test_rate_spacing(self):
        t, rows, sleeps = FakeTransport([(200, OK["cow"])]), [], []
        ds = [draw(cell="c%d" % k) for k in range(3)]
        M.run_source("cow", "base", ds, CTX, t, Blocks(), 1.0, rows.append, sleep=sleeps.append, clock=Clock())
        self.assertEqual(len([s for s in sleeps if s > 0.9]), 2)


if __name__ == "__main__":
    unittest.main()
