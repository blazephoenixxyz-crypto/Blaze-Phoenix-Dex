#!/usr/bin/env python3
"""Offline tests of gasdetail.py, join.py and tables.py (unittest, no network).

  python3 -I tools/gas-case-study/test_gasdetail.py [-v] [Class.test_name]

Synthetic callTracer trees (1 hop 1 leg, 1 hop 3 legs, 2 hops 3+2, a reverting leg, frames that do
not match the legs), the L1 fee by chain family against a fake RPC (None is not 0), the joins with a
missing pair or market (empty, never 0), and the tables with a fixed seed (reproducible interval) at
n = 0, 1, 2.
"""
import os
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)
import abi  # noqa: E402
import gasdetail as gd  # noqa: E402
import join  # noqa: E402
import tables  # noqa: E402

R = "0x" + "aa" * 20       # router
S = "0x" + "55" * 20       # solver
P = ["0x%040x" % (0x1000 + k) for k in range(6)]  # pools / adapters
T = "0x" + "77" * 20       # a token


def fr(to, gas, calls=(), typ="CALL", frm=R, error=None):
    f = {"type": typ, "from": frm, "to": to, "gasUsed": hex(gas), "calls": list(calls)}
    if error:
        f["error"] = error
    return f


def root(gas, calls, error=None):
    f = fr(R, gas, calls, frm="0x" + "01" * 20)
    if error:
        f["error"] = error
    return f


def leg(pool, gas):
    """A V3-like leg: Router -> pool.swap -> token.transfer + Router callback -> token.transfer."""
    cb = fr(R, gas // 4, [fr(T, gas // 8)], frm=pool)
    return fr(pool, gas, [fr(T, gas // 8, frm=pool), cb])


class Rpc:
    """Fake RPC: eth_call by (to, selector) -> result or exception; other methods by name."""

    def __init__(self, calls=None, other=None):
        self.calls, self.other, self.log = calls or {}, other or {}, []

    def call(self, method, params):
        self.log.append(method)
        if method == "eth_call":
            k = (params[0]["to"].lower(), params[0]["data"][2:10])
            h = self.calls.get(k)
        else:
            h = self.other.get(method)
        if h is None:
            raise RuntimeError("unscripted " + method)
        if isinstance(h, Exception):
            raise h
        return h


def w(*xs):
    return "0x" + "".join("%064x" % x for x in xs)


class SplitGas(unittest.TestCase):
    def test_one_hop_one_leg(self):
        t = root(150000, [leg(P[0], 80000)])
        s = gd.split_gas(t, [[(P[0], "v3")]], [S], R)
        self.assertTrue(s["separable"], s["note"])
        self.assertEqual((s["gas_tx"], s["gas_exec_leg"], s["gas_exec_hop"]), (150000, [80000], [80000]))
        self.assertEqual(s["gas_discovery"], 0)  # solver asked, none in the complete trace: observed 0

    def test_discovery_not_asked_is_none(self):
        s = gd.split_gas(root(150000, [leg(P[0], 80000)]), [[(P[0], "v3")]], [], R)
        self.assertIsNone(s["gas_discovery"])

    def test_one_hop_three_legs(self):
        t = root(400000, [leg(P[0], 70000), fr(T, 9000), leg(P[1], 60000), leg(P[2], 50000)])
        s = gd.split_gas(t, [[(P[0], "v3"), (P[1], "v2"), (P[2], "v3")]], [S], R)
        self.assertTrue(s["separable"])
        self.assertEqual(s["gas_exec_leg"], [70000, 60000, 50000])
        self.assertEqual(s["gas_exec_hop"], [180000])

    def test_two_hops_three_plus_two_with_discovery(self):
        quotes = [fr(p, 5000, typ="STATICCALL", frm=S) for p in P[:5]]   # the Solver reads the same pools
        disc = fr(S, 90000, quotes, typ="CALL")
        legs = [leg(P[k], 40000 + 1000 * k) for k in range(5)]
        t = root(600000, [disc] + legs)
        hops = [[(P[0], "v3"), (P[1], "v3"), (P[2], "v2")], [(P[3], "v3"), (P[4], "v4")]]
        s = gd.split_gas(t, hops, [S], R)
        self.assertTrue(s["separable"], s["note"])
        self.assertEqual(s["gas_discovery"], 90000)
        self.assertEqual(s["gas_exec_leg"], [40000, 41000, 42000, 43000, 44000])
        self.assertEqual(s["gas_exec_hop"], [123000, 87000])

    def test_discovery_subtree_is_never_a_leg_even_without_router_filter(self):
        quotes = [fr(p, 5000, typ="CALL", frm=S) for p in P[:2]]   # quoting by a (reverting) CALL
        t = root(300000, [fr(S, 30000, quotes), leg(P[0], 50000), leg(P[1], 40000)])
        s = gd.split_gas(t, [[(P[0], "v3"), (P[1], "v3")]], [S], None)
        self.assertTrue(s["separable"], s["note"])
        self.assertEqual((s["gas_discovery"], s["gas_exec_leg"]), (30000, [50000, 40000]))

    def test_reverting_leg_is_not_separable_and_named(self):
        t = root(200000, [leg(P[0], 50000), fr(P[1], 30000, error="execution reverted")], error="execution reverted")
        s = gd.split_gas(t, [[(P[0], "v3"), (P[1], "v2")]], [S], R)
        self.assertFalse(s["separable"])
        self.assertEqual((s["gas_exec_leg"], s["gas_exec_hop"]), ([], []))
        self.assertIn("leg 0.1", s["note"])
        self.assertEqual(s["gas_tx"], 200000)

    def test_v4_bundle_one_unlock_for_two_legs_is_not_separable(self):
        pm = P[5]
        unlock = fr(pm, 120000, [fr(R, 100000, [fr(pm, 40000), fr(pm, 40000)], frm=pm)])
        s = gd.split_gas(root(200000, [unlock]), [[(pm, "v4"), (pm, "v4")]], [S], R)
        self.assertFalse(s["separable"])
        self.assertIn("1 frames for 2 legs", s["note"])

    def test_extra_frame_or_missing_frame_not_separable(self):
        t = root(300000, [leg(P[0], 50000), leg(P[0], 50000)])
        self.assertFalse(gd.split_gas(t, [[(P[0], "v2")]], [S], R)["separable"])
        self.assertFalse(gd.split_gas(root(9000, []), [[(P[0], "v2")]], [S], R)["separable"])

    def test_staticcall_and_foreign_caller_are_not_legs(self):
        t = root(300000, [fr(P[0], 3000, typ="STATICCALL"), fr(P[0], 7000, frm=T), leg(P[0], 50000)])
        s = gd.split_gas(t, [[(P[0], "v3")]], [S], R)
        self.assertEqual(s["gas_exec_leg"], [50000])

    def test_legs_above_gas_tx_not_separable(self):
        s = gd.split_gas(root(1000, [leg(P[0], 50000)]), [[(P[0], "v3")]], [S], R)
        self.assertFalse(s["separable"])

    def test_trace_calls_calltracer(self):
        rpc = Rpc(other={"debug_traceTransaction": {"gasUsed": "0x1"}})
        self.assertEqual(gd.trace(rpc, "0x" + "00" * 32), {"gasUsed": "0x1"})


class L1Fee(unittest.TestCase):
    TX = gd.unsigned_1559(10, "0x" + "42" * 20, "0x" + "ab" * 100, 300000, 7, 1)

    def setUp(self):
        gd._FAMILY.clear()

    def test_rlp_roundtrip(self):
        self.assertEqual(gd.tx_to_data(self.TX), ("0x" + "42" * 20, "0x" + "ab" * 100))

    def test_op_stack(self):
        rpc = Rpc({(gd.GPO, abi.selector("getL1Fee(bytes)")): w(12345)})
        self.assertEqual(gd.l1_fee(rpc, "base", self.TX, 1)[0], 12345)

    def test_op_stack_error_is_none_not_zero(self):
        rpc = Rpc({(gd.GPO, abi.selector("getL1Fee(bytes)")): RuntimeError("x")})
        v, m = gd.l1_fee(rpc, "optimism", self.TX, 1)
        self.assertIsNone(v)
        self.assertIn("error", m)

    def test_nitro(self):
        rpc = Rpc({(gd.NODE_INTERFACE, abi.selector("gasEstimateL1Component(address,bool,bytes)")): w(693, 20024000, 9)})
        self.assertEqual(gd.l1_fee(rpc, "arbitrum", self.TX, 1)[0], 693 * 20024000)

    def test_nitro_absent_answer_is_none(self):
        rpc = Rpc({(gd.NODE_INTERFACE, abi.selector("gasEstimateL1Component(address,bool,bytes)")): "0x"})
        self.assertIsNone(gd.l1_fee(rpc, "arbitrum", self.TX, 1)[0])

    def test_l1_chains_are_a_real_zero_without_rpc(self):
        for c in ("ethereum", "bsc", "avalanche"):
            self.assertEqual(gd.l1_fee(None, c, self.TX, 1), (0, "l1:none"))

    def test_unknown_chain_none(self):
        self.assertIsNone(gd.l1_fee(Rpc(), "mars", self.TX, 1)[0])

    def test_robinhood_probe_nitro(self):
        rpc = Rpc({(gd.ARBSYS, abi.selector("arbChainID()")): w(4663),
                   (gd.NODE_INTERFACE, abi.selector("gasEstimateL1Component(address,bool,bytes)")): w(0, 20000000, 0)},
                  {"eth_getCode": "0x"})
        v, m = gd.l1_fee(rpc, "robinhood", self.TX, 1)
        self.assertEqual(v, 0)
        self.assertIn("nitro(probe", m)

    def test_robinhood_probe_op(self):
        rpc = Rpc({(gd.GPO, abi.selector("getL1Fee(bytes)")): w(5)}, {"eth_getCode": "0x6080"})
        v, m = gd.l1_fee(rpc, "robinhood", self.TX, 1)
        self.assertEqual(v, 5)
        self.assertIn("op-stack(probe", m)

    def test_robinhood_probe_fails_is_none(self):
        v, m = gd.l1_fee(Rpc(other={"eth_getCode": "0x"}), "robinhood", self.TX, 1)
        self.assertIsNone(v)
        self.assertIn("probe-failed", m)


class PriceUsd(unittest.TestCase):
    def test_gas_price(self):
        rpc = Rpc(other={"eth_getBlockByNumber": {"baseFeePerGas": "0x64"},
                         "eth_feeHistory": {"reward": [["0x3"], ["0x1"], ["0x2"], ["0x9"]]}})
        b, p, _ = gd.gas_price(rpc, 7)
        self.assertEqual((b, p), (100, 2))

    def test_gas_price_absent_is_none(self):
        rpc = Rpc(other={"eth_getBlockByNumber": {}, "eth_feeHistory": {"reward": []}})
        b, p, m = gd.gas_price(rpc, 7)
        self.assertEqual((b, p), (None, None))
        self.assertIn("absent", m)

    def test_gas_price_zero_basefee_is_zero(self):
        rpc = Rpc(other={"eth_getBlockByNumber": {"baseFeePerGas": "0x0"}, "eth_feeHistory": {"reward": [["0x0"]]}})
        self.assertEqual(gd.gas_price(rpc, 7)[:2], (0, 0))

    def test_usd(self):
        ug, ul, ut = gd.usd(100000, 10 ** 9, 10 ** 12, 2000.0)
        self.assertAlmostEqual(ug, 0.2)
        self.assertAlmostEqual(ul, 0.002)
        self.assertAlmostEqual(ut, 0.202)
        self.assertEqual(gd.usd(100000, 10 ** 9, None, 2000.0)[1:], (None, None))
        self.assertEqual(gd.usd(None, 10 ** 9, 0, 2000.0), (None, 0.0, None))


def wtsv(d, name, cols, rows, comment=False):
    p = os.path.join(d, name)
    with open(p, "w") as f:
        if comment:
            f.write("# market quotes\n")
        f.write("\t".join(cols) + "\n")
        for r in rows:
            f.write("\t".join(str(r.get(c, "")) for c in cols) + "\n")
    return p


RCOLS = "chain fork_block cell_id i temp mode token_in token_out amount_in amount_out status gas_tx usd_total hops legs_per_hop exotic_in exotic_out".split()
MCOLS = "chain cell_id i token_in token_out amount_in source status amount_out".split()


def rrow(mode, out, i="0", temp="cold", cell="c1", status="ok", gas=100000, usd=0.1, **kw):
    r = dict(chain="base", fork_block="1", cell_id=cell, i=i, temp=temp, mode=mode, token_in="0xa", token_out="0xb",
             amount_in="1000", amount_out=out, status=status, gas_tx=gas, usd_total=usd, hops="1",
             legs_per_hop="1", exotic_in="0", exotic_out="0")
    r.update(kw)
    return r


class Join(unittest.TestCase):
    def run_join(self, rows, market=None):
        with tempfile.TemporaryDirectory() as d:
            res = wtsv(d, "r.tsv", RCOLS, rows)
            args = [res, "-o", os.path.join(d, "o.tsv")]
            if market is not None:
                args += ["--market", wtsv(d, "m.tsv", MCOLS, market, comment=True)]
            self.assertEqual(join.main(args), 0)
            return join.read(os.path.join(d, "o.tsv"))

    def test_best_single_and_market(self):
        m = [dict(chain="base", cell_id="c1", i="0", token_in="0xa", token_out="0xb", amount_in="1000",
                  source="x", status="ok", amount_out="2000"),
             dict(chain="base", cell_id="c1", i="0", token_in="0xa", token_out="0xb", amount_in="1000",
                  source="y", status="ok", amount_out="2050"),
             dict(chain="base", cell_id="c1", i="0", token_in="0xa", token_out="0xb", amount_in="1000",
                  source="z", status="error", amount_out="9999")]
        cols, rows = self.run_join([rrow("best_single", "2000"), rrow("quoted@M0", "2010")], m)
        self.assertEqual(cols[-2:], ["d_best_single_bps", "d_market_bps"])
        q = [r for r in rows if r["mode"] == "quoted@M0"][0]
        self.assertEqual(q["d_best_single_bps"], "50.0000")
        self.assertEqual(q["d_market_bps"], "%.4f" % ((2010 - 2050) * 10000 / 2050))

    def test_no_pair_and_no_market_are_empty(self):
        cols, rows = self.run_join([rrow("best_single", "2000", temp="warm"), rrow("quoted@M0", "2010")])
        q = [r for r in rows if r["mode"] == "quoted@M0"][0]
        self.assertEqual((q["d_best_single_bps"], q["d_market_bps"]), ("", ""))

    def test_market_of_another_trade_and_zero_outputs_are_empty(self):
        m = [dict(chain="base", cell_id="c1", i="0", token_in="0xa", token_out="0xb", amount_in="999",
                  source="x", status="ok", amount_out="2000")]
        _, rows = self.run_join([rrow("best_single", "0"), rrow("quoted@M0", "2010")], m)
        q = [r for r in rows if r["mode"] == "quoted@M0"][0]
        self.assertEqual((q["d_best_single_bps"], q["d_market_bps"]), ("", ""))

    def test_two_best_single_rows_are_ambiguous(self):
        _, rows = self.run_join([rrow("best_single", "2000"), rrow("best_single", "2001"), rrow("quoted@M0", "2010")])
        self.assertEqual([r for r in rows if r["mode"] == "quoted@M0"][0]["d_best_single_bps"], "")

    def test_one_wei_difference(self):
        self.assertEqual(join.bps("10001", "10000"), "1.0000")
        self.assertEqual(join.bps("9999", "10000"), "-1.0000")
        self.assertEqual(join.bps("1", "1"), "0.0000")


class Tables(unittest.TestCase):
    def run_tables(self, rows, b=200):
        with tempfile.TemporaryDirectory() as d:
            res = wtsv(d, "r.tsv", RCOLS, rows)
            self.assertEqual(tables.main([res, "-o", os.path.join(d, "t.tsv"), "--b", str(b)]), 0)
            return tables.read(os.path.join(d, "t.tsv"))[1]

    def pick(self, rows, metric, mode, vs=""):
        return [r for r in rows if r["metric"] == metric and r["mode"] == mode and r["vs"] == vs]

    def test_seed_is_the_prereg_rule(self):
        import hashlib
        self.assertEqual(tables.seed_of("x"), int(hashlib.sha256(b"gas-1114-boot|x").hexdigest(), 16))
        self.assertEqual(tables.prereg_b(tables.PREREG), 10000)

    def test_reproducible_interval(self):
        rows = [rrow("quoted@M0", "1", i=str(k), gas=100000 + 37 * k * k) for k in range(9)]
        a, b = self.run_tables(rows), self.run_tables(rows)
        ga, gb = self.pick(a, "gas_tx", "quoted@M0")[0], self.pick(b, "gas_tx", "quoted@M0")[0]
        self.assertEqual((ga["ci95_lo"], ga["ci95_hi"], ga["boot_seed"]), (gb["ci95_lo"], gb["ci95_hi"], gb["boot_seed"]))
        self.assertEqual(ga["median"], str(100000 + 37 * 16))
        self.assertLessEqual(int(ga["ci95_lo"]), int(ga["median"]))
        self.assertGreaterEqual(int(ga["ci95_hi"]), int(ga["median"]))

    def test_n_zero_one_two(self):
        rows = [rrow("quoted@M0", "", status="noroute", gas="")]                         # n = 0 values
        rows += [rrow("onchain@M0", "1", gas=90000)]                                    # n = 1
        rows += [rrow("native@M0", "1", i=str(k), gas=g) for k, g in ((0, 80000), (1, 80002))]  # n = 2
        t = self.run_tables(rows)
        z = self.pick(t, "gas_tx", "quoted@M0")[0]
        self.assertEqual((z["n"], z["median"], z["ci95_lo"]), ("0", "", ""))
        o = self.pick(t, "gas_tx", "onchain@M0")[0]
        self.assertEqual((o["n"], o["median"], o["ci95_lo"], o["ci95_hi"]), ("1", "90000", "90000", "90000"))
        two = self.pick(t, "gas_tx", "native@M0")[0]
        self.assertEqual((two["n"], two["median"]), ("2", "80001.0"))
        nr = self.pick(t, "rate_noroute", "quoted@M0")[0]
        self.assertEqual((nr["n"], nr["k"], nr["ci95_hi"]), ("1", "1", "1.0"))
        rv = self.pick(t, "rate_revert", "onchain@M0")[0]
        self.assertEqual((rv["k"], rv["ci95_lo"]), ("0", "0.0"))

    def test_revert_rate_counts_prefix(self):
        rows = [rrow("quoted@M0", "", status="revert:0x12345678", gas=50000), rrow("quoted@M0", "1", i="1")]
        t = self.run_tables(rows)
        rv = self.pick(t, "rate_revert", "quoted@M0")[0]
        self.assertEqual((rv["n"], rv["k"]), ("2", "1"))
        g = self.pick(t, "gas_tx", "quoted@M0")[0]          # the gas of a revert is not a swap's gas
        self.assertEqual((g["n"], g["median"]), ("1", "100000"))

    def test_paired_by_draw(self):
        rows = [rrow("best_single", "1", i=str(k), gas=100000 + k) for k in range(3)]
        rows += [rrow("quoted@M0", "1", i=str(k), gas=90000 + k, hops="2", legs_per_hop="3+2") for k in range(3)]
        rows += [rrow("quoted@M0", "1", i="9", gas=1)]                           # unpaired draw: left out
        d = self.pick(self.run_tables(rows), "d_gas_tx", "best_single", "quoted@M0")[0]
        self.assertEqual((d["n"], d["median"]), ("3", "10000"))

    def test_exotic_stratum(self):
        rows = [rrow("quoted@M0", "1"), rrow("quoted@M0", "1", i="1", exotic_out="1")]
        ex = sorted(r["exotic"] for r in self.pick(self.run_tables(rows), "gas_tx", "quoted@M0"))
        self.assertEqual(ex, ["n", "s"])


if __name__ == "__main__":
    unittest.main()
