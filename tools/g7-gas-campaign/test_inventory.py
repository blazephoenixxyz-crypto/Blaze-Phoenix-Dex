#!/usr/bin/env python3
"""Offline tests for inventory.py (no RPC, no key). Run: python3 -I tools/g7-gas-campaign/test_inventory.py

Each test names the mutant of inventory.py that turns it red; mutants_inventory.py applies
every one of them and checks that its test goes red. The three real creation logs below were
read from dRPC on 2026-11-13 (tx hash kept for re-checking).
"""
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import inventory as inv  # noqa: E402

# robinhood v3 factory 0x1f7d7550b1b028f7571e69a784071f0205fd2efa, tx 0x6489c237bc87c5bbb8da6ee8a51213711532d47d97e87fc70061b63618edc594
V3_REAL = {"topics": ["0x783cca1c0412dd0d695e784568c96da2e9c22ff989357a2e8b1d9b2b4e6b7118",
                      "0x0000000000000000000000000bd7d308f8e1639fab988df18a8011f41eacad73",
                      "0x0000000000000000000000005fc5360d0400a0fd4f2af552add042d716f1d168",
                      "0x0000000000000000000000000000000000000000000000000000000000000064"],
           "data": "0x0000000000000000000000000000000000000000000000000000000000000001"
                   "00000000000000000000000052e65b17fb6e5ba00ed806f37afcd2daa50271ca",
           "blockNumber": "0x16fbe9"}
# arbitrum Camelot V2 factory 0x6eccab422d763ac031210895c81787e87b43a652 (pair #4454), tx 0x6e5ba7b7f92cb185915cf5c18c8182aff7845b90dc121d60601d5335b00a2835
V2_REAL = {"topics": ["0x0d3648bd0f6ba80134a33ba9275ac585d9d315f0ad8355cddefde31afa28d0e9",
                      "0x00000000000000000000000082af49447d8a07e3bd95bd0d56f35241523fbab1",
                      "0x000000000000000000000000c819f084fd2dbc29d01f7e56185a17fb5f54f31d"],
           "data": "0x000000000000000000000000a415ff2397b9fa5fcd337c9320d93429b3ebd6c0"
                   "0000000000000000000000000000000000000000000000000000000000001166",
           "blockNumber": "0x1e5a467c"}
# arbitrum v4 PoolManager 0x360e68faccca8ca495c1b759fd9eee466db9fb32, tx 0x7a143f8dcc027d51037938e4708e5b563a2e3c8dbf49520479b7b565385ca2ba
V4_REAL = {"topics": ["0xdd466e674ea557f56295e2d0218a125ea4b4f0f6f3307b95f85e6110838d6438",
                      "0x5ea3ab53999435a47f21e07713cc9056852eef0e3d405e31c0c5b6f69c8c667c",
                      "0x0000000000000000000000000000000000000000000000000000000000000000",
                      "0x000000000000000000000000b46ad28a11d2006058d22a16b16902f8213bdc30"],
           "data": "0x00000000000000000000000000000000000000000000000000000000000009c4"
                   "0000000000000000000000000000000000000000000000000000000000000019"
                   "0000000000000000000000000000000000000000000000000000000000000000"
                   "000000000000000000000000000000000005acf2bf596e5af6228293ffffffff"
                   "fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffd252b",
           "blockNumber": "0x1f355904"}

A = "0x" + "a1" * 20
B = "0x" + "b2" * 20
C = "0x" + "c3" * 20
D = "0x" + "d4" * 20
P = "0x" + "e5" * 20
PID = "0x" + "f6" * 32


def tw(x):
    """topic word (0x + 64 hex) from an address or int (two's complement for negatives)."""
    if isinstance(x, str):
        return "0x" + x[2:].lower().rjust(64, "0")
    return "0x" + format(x % (1 << 256), "064x")


def mklog(kind, topics, data, blk=100):
    return {"topics": [inv.TOPICS[kind]] + [tw(t) for t in topics],
            "data": "0x" + "".join(tw(x)[2:] for x in data), "blockNumber": hex(blk)}


def row(family="v3", chain="base", factory=P, t0=A, t1=B, bal0=10, bal1=10, liq="", usd="", fee="", cls=""):
    return {"chain": chain, "family": family, "factory": factory, "pool": P, "token0": t0, "token1": t1,
            "bal0": bal0, "bal1": bal1, "liquidity_raw": liq, "liq_usd": usd, "fee": fee, "class": cls,
            "liq_method": ""}


class Decoders(unittest.TestCase):
    def test_topic0_of_the_public_events(self):
        # mutant: EVENTS["v2"] = "PairCreated(address,address,address)"
        self.assertEqual(inv.TOPICS["v3"], V3_REAL["topics"][0])
        self.assertEqual(inv.TOPICS["v2"], V2_REAL["topics"][0])
        self.assertEqual(inv.TOPICS["v4"], V4_REAL["topics"][0])

    def test_v3_real_log(self):
        # mutant: pool and tick_spacing read from swapped data words
        r = inv.decode_log("v3", V3_REAL)
        self.assertEqual((r["token0"], r["token1"], r["fee"], r["tick_spacing"], r["pool"], r["block"]),
                         ("0x0bd7d308f8e1639fab988df18a8011f41eacad73", "0x5fc5360d0400a0fd4f2af552add042d716f1d168",
                          100, 1, "0x52e65b17fb6e5ba00ed806f37afcd2daa50271ca", 1506281))

    def test_v2_real_log_token_order(self):
        # mutant: v2 token0/token1 read from swapped topics
        r = inv.decode_log("v2", V2_REAL)
        self.assertEqual((r["token0"], r["token1"], r["pool"]),
                         ("0x82af49447d8a07e3bd95bd0d56f35241523fbab1", "0xc819f084fd2dbc29d01f7e56185a17fb5f54f31d",
                          "0xa415ff2397b9fa5fcd337c9320d93429b3ebd6c0"))

    def test_v4_real_log_rebuilds_its_pool_id(self):
        # mutant: v4 fee and tick_spacing read from swapped data words
        r = inv.decode_log("v4", V4_REAL)
        self.assertEqual((r["fee"], r["tick_spacing"], r["token0"]), (2500, 25, inv.ZERO))
        self.assertEqual(inv.v4_pool_id(r["token0"], r["token1"], r["fee"], r["tick_spacing"], r["hooks"]),
                         V4_REAL["topics"][1])
        self.assertEqual(r["pool_id"], V4_REAL["topics"][1])

    def test_solidly_stable_flag(self):
        # mutant: stable=False
        r = inv.decode_log("solidly", mklog("solidly", [A, B, 1], [P, 7]))
        self.assertIs(r["stable"], True)
        self.assertEqual(r["pool"], P)

    def test_cl_tick_spacing_from_topic3(self):
        # mutant: cl tick_spacing read from data word 0 (the pool)
        r = inv.decode_log("cl", mklog("cl", [A, B, 200], [P]))
        self.assertEqual((r["tick_spacing"], r["pool"]), (200, P))

    def test_algebra_custom_deployer_is_topic1(self):
        # mutant: deployer/token0/token1 rotated
        r = inv.decode_log("algebra_custom", mklog("algebra_custom", [C, A, B], [P]))
        self.assertEqual((r["deployer"], r["token0"], r["token1"], r["pool"]), (C, A, B, P))

    def test_lb_bin_step_is_the_tick_spacing(self):
        # mutant: lb tick_spacing read from data word 1 (the pair id)
        r = inv.decode_log("lb", mklog("lb", [A, B, 25], [P, 77]))
        self.assertEqual((r["bin_step"], r["tick_spacing"], r["pool"]), (25, 25, P))

    def test_inf_cl_tick_spacing_from_params_bits_16_39(self):
        # mutant: shift by 8 instead of 16
        params = (60 << 16) | 0x0055
        r = inv.decode_log("inf_cl", mklog("inf_cl", [PID, A, B], [D, 3000, params]))
        self.assertEqual((r["tick_spacing"], r["fee"], r["hooks"], r["pool"]), (60, 3000, D, PID))

    def test_inf_bin_bin_step_from_params_bits_16_31(self):
        # mutant: no shift (low 16 bits = hooks bitmap)
        params = (10 << 16) | 0x0055
        r = inv.decode_log("inf_bin", mklog("inf_bin", [PID, A, B], [D, 500, params]))
        self.assertEqual((r["tick_spacing"], r["pool_id"]), (10, PID))

    def test_wrong_topic0_is_refused(self):
        # mutant: topic check removed
        with self.assertRaises(ValueError):
            inv.decode_log("v2", V3_REAL)


class RankKey(unittest.TestCase):
    def test_deeper_usd_first(self):
        # mutant: (0, float(v))
        a, b = row(usd=100.0), row(usd=5.0)
        self.assertEqual(sorted([b, a], key=inv.rank_key), [a, b])

    def test_usd_ranks_above_raw_only(self):
        # mutant: raw-only rows in tier 0
        a, b = row(usd=5.0), row(liq=10 ** 30)
        self.assertLess(inv.rank_key(a), inv.rank_key(b))

    def test_true_zero_ranks_above_rpc_err(self):
        # mutant: zero raw liquidity treated as absent
        z, e = row(liq=0), row(liq=inv.RPC_ERR)
        self.assertLess(inv.rank_key(z), inv.rank_key(e))


class LiqUsd(unittest.TestCase):
    def test_absent_priced_side_is_absent_not_a_lower_sum(self):
        # mutant: an rpc_err side is skipped (continue) instead of making the row absent
        r = row(bal0=inv.RPC_ERR, bal1=2 * 10 ** 6)
        self.assertEqual(inv.liq_usd(r, {A: 2000.0, B: 1.0}, {A: 18, B: 6}), "")


class Classify(unittest.TestCase):
    def test_shallow_is_never_zero_or_rpc_err(self):
        # mutant: pos = list(rows)
        z = row(bal0=0, bal1=0, usd=0.0)
        e = row(bal0=inv.RPC_ERR, bal1=inv.RPC_ERR)
        s = row(usd=10.0)
        inv.classify([z, e, s], set(), set())
        self.assertIn("shallow", s["class"])
        self.assertNotIn("shallow", z["class"])
        self.assertNotIn("shallow", e["class"])

    def test_v4_positive_means_liquidity_not_virtual_balances(self):
        # mutant: v4 branch of is_measured_positive removed
        self.assertFalse(inv.is_measured_positive(row(family="v4", liq=0, bal0=5, bal1=5)))
        self.assertTrue(inv.is_measured_positive(row(family="inf_cl", liq=1, bal0="", bal1="")))

    def test_dynamic_fee_flag_is_not_fee_high(self):
        # mutant: f != 0x800000 dropped
        r = row(family="v4", fee=0x800000, liq=1)
        inv.classify([r], set(), set())
        self.assertNotIn("fee_high", r["class"])

    def test_fee_high_boundary(self):
        # mutant: f > FEE_HIGH
        hi, below = row(fee=10000), row(fee=9999)
        inv.classify([hi, below], set(), set())
        self.assertIn("fee_high", hi["class"])
        self.assertNotIn("fee_high", below["class"])

    def test_fee_low_boundary(self):
        # mutant: f < FEE_LOW
        lo, above = row(fee=100), row(fee=101)
        inv.classify([lo, above], set(), set())
        self.assertIn("fee_low", lo["class"])
        self.assertNotIn("fee_low", above["class"])

    def test_family_rep_is_the_deepest_per_factory(self):
        # mutant: rank_key(r) > rank_key(best)
        a, b, c = row(usd=50.0), row(usd=5000.0), row(usd=9.0)
        inv.classify([a, b, c], set(), set())
        self.assertEqual([("family_rep" in x["class"]) for x in (a, b, c)], [False, True, False])

    def test_midtail_on_either_side(self):
        # mutant: only token1 checked
        r = row(t0=C, t1=A)
        inv.classify([r], set(), {C})
        self.assertIn("midtail", r["class"])

    def test_shallow_fallback_takes_the_lowest_raw(self):
        # mutant: [:n_shallow] (the deepest)
        rows = [row(family="v4", liq=x, bal0="", bal1="") for x in (5, 1, 9, 3, 7)]
        inv.classify(rows, set(), set(), n_shallow=2)
        self.assertEqual(sorted(r["liquidity_raw"] for r in rows if "shallow" in r["class"]), [1, 3])


def gates(rows):
    return [("gate_top3" in r["class"].split(",")) for r in rows]


class GateTop3(unittest.TestCase):
    def test_only_gate_families(self):
        # mutant: GATE_FAMS filter dropped
        v3, v4, lb = row(family="v3", usd=1e9), row(family="v4", usd=1e9, liq=1), row(family="lb", usd=1.0)
        inv.finalize([v3, v4, lb])
        self.assertEqual(gates([v3, v4, lb]), [False, False, True])

    def test_at_most_three_per_chain_family(self):
        # mutant: [:4]
        rows = [row(family="lb", usd=float(x)) for x in range(1, 6)]
        inv.finalize(rows)
        self.assertEqual(sum(gates(rows)), 3)

    def test_the_three_deepest(self):
        # mutant: [-3:]
        rows = [row(family="inf_cl", liq=1, usd=float(x)) for x in (5, 1, 9, 3, 7)]
        inv.finalize(rows)
        self.assertEqual(sorted(r["liq_usd"] for r in rows if "gate_top3" in r["class"]), [5.0, 7.0, 9.0])

    def test_grouped_per_chain(self):
        # mutant: grouped by family only
        rows = [row(family="balancer_v2", chain=c, usd=float(x)) for c in ("base", "ethereum") for x in (1, 2, 3)]
        inv.finalize(rows)
        self.assertEqual(sum(gates(rows)), 6)

    def test_rpc_err_and_zero_never_gate(self):
        # mutant: gate_eligible returns True
        g = row(family="lb", usd=10.0)
        e = row(family="lb", bal0=inv.RPC_ERR, bal1=inv.RPC_ERR)
        z = row(family="lb", bal0=0, bal1=0)
        inv.finalize([g, e, z])
        self.assertEqual(gates([g, e, z]), [True, False, False])

    def test_zero_usd_external_pool_is_not_gate(self):
        # mutant: isinstance(v, float) without v > 0
        r = row(family="curve_ng", bal0="", bal1="", usd=0.0)
        inv.finalize([r])
        self.assertEqual(gates([r]), [False])

    def test_stale_mark_dropped_and_idempotent(self):
        # mutant: existing gate_top3 kept (class not filtered)
        v3 = row(family="v3", usd=1e9, cls="major,gate_top3")
        lb = row(family="lb", usd=1.0)
        inv.finalize([v3, lb])
        inv.finalize([v3, lb])
        self.assertEqual((v3["class"], lb["class"]), ("major", "gate_top3"))

    def test_virtual_label_on_v4_v4native_inf_cl_only(self):
        # mutant: label never written
        rows = [row(family=f, liq=1) for f in ("v4", "v4native", "inf_cl", "inf_bin", "v3")]
        inv.finalize(rows)
        self.assertEqual([inv.VIRTUAL_LABEL in r["liq_method"] for r in rows], [True, True, True, False, False])

    def test_virtual_label_written_once(self):
        # mutant: no "already labelled" check
        r = row(family="inf_cl", liq=1)
        r["liq_method"] = "CLPoolManager.getLiquidity(id);bal=virtual(L,sqrtP)"
        inv.finalize([r])
        inv.finalize([r])
        self.assertEqual(r["liq_method"].count(inv.VIRTUAL_LABEL), 1)

    def test_refinalize_tsv_parses_numbers_and_keeps_rpc_err(self):
        # mutant: TSV cells left as strings
        d = tempfile.mkdtemp()
        p = os.path.join(d, "inventory.tsv")
        r1 = dict(row(family="v3", usd=1e16, cls="gate_top3"), b_inv=1)
        r2 = dict(row(family="lb", bal0=7, bal1=8, usd=12.5), b_inv=1)
        r3 = dict(row(family="lb", bal0=inv.RPC_ERR, bal1=inv.RPC_ERR), b_inv=1)
        inv.append_tsv(p, inv.INV_COLS, [r1, r2, r3])
        out = inv.refinalize_tsv(p)
        self.assertEqual([("gate_top3" in r["class"]) for r in out], [False, True, False])
        self.assertEqual(out[2]["bal0"], inv.RPC_ERR)
        self.assertTrue(os.path.exists(p + ".prev"))
        with open(p) as f:
            self.assertEqual(f.readline().rstrip("\n").split("\t"), inv.INV_COLS)


class FakeRpc(inv.Rpc):
    def __init__(self, fail):
        super().__init__("test", transport=self._t)
        self.fail = fail

    def _t(self, payload):
        f = payload["params"][0]
        lo, hi = int(f["fromBlock"], 16), int(f["toBlock"], 16)
        msg = self.fail(lo, hi)
        return {"error": {"message": msg}} if msg else {"result": []}


class ScanLogs(unittest.TestCase):
    def test_range_error_shrinks_and_covers_everything(self):
        # mutant: range errors not recognised (recorded as rpc_err)
        rpc = FakeRpc(lambda lo, hi: "block range too large" if hi - lo + 1 > 1000 else None)
        rows = []
        _, cov = inv.scan_logs(rpc, P, inv.TOPICS["v2"], 0, 9999, rows, window=4000)
        self.assertEqual(sum(h - l + 1 for l, h in cov), 10000)
        self.assertNotIn(inv.RPC_ERR, [x[6] for x in rows])

    def test_non_range_error_is_rpc_err_and_left_uncovered(self):
        # mutant: failed window recorded as ok
        rpc = FakeRpc(lambda lo, hi: "internal error" if lo == 0 else None)
        rows = []
        _, cov = inv.scan_logs(rpc, P, inv.TOPICS["v2"], 0, 199, rows, window=100, min_window=100)
        self.assertEqual([(x[3], x[6]) for x in rows], [(0, inv.RPC_ERR), (100, "ok")])
        self.assertEqual(cov, [(100, 199)])


if __name__ == "__main__":
    unittest.main(verbosity=1)
