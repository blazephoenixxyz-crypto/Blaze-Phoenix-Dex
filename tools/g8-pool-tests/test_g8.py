#!/usr/bin/env python3
"""Offline tests for build_cases.py and g8.py (no RPC, no key). Run: python3 -I tools/g8-pool-tests/test_g8.py

Each test names the mutant that turns it red; mutants_g8.py applies every one of them and checks
that its test goes red. The inventory is synthetic (test_build_spec.row, the S2 columns) and the
G7 spec is a fake one with a single gate stratum.
"""
import contextlib
import io
import json
import os
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "..", "g7-gas-campaign"))
import build_cases as bc  # noqa: E402
import g7  # noqa: E402
import g8  # noqa: E402
from test_build_spec import INV_COLS, a, row  # noqa: E402

WETH, USDC = a(0xE), a(0xC)  # the chain's bridges
X, Y, Z = a(0x51), a(0x52), a(0x53)  # exotic tokens
GP = a(0x9A)  # the gate pool that has a G7 wrapper
P1, P2, P3, P4, P5, P7, P8, P9 = (a(0xA1), a(0xA2), a(0xA3), a(0xA4), a(0xA5), a(0xA7), a(0xA8), a(0xA9))
BR = {"base": [("WETH", WETH), ("USDC", USDC)]}
INV = [
    row("base", "v3", P1, X, USDC, 5000, "x"),      # X/USDC hop
    row("base", "v3", P2, X, Y, 9000, "x"),         # the deepest v3 pool: the pool stratum
    row("base", "v3", P4, Y, USDC, 50, "x"),        # shallower Y/USDC, listed BEFORE the deepest one
    row("base", "solidly", P3, Y, USDC, 100, "x"),  # the deepest Y/USDC hop
    row("base", "lb", P7, Y, USDC, 10, "x"),        # gate family, no wrapper: not ranked for hops, not_covered
    row("base", "v2", P5, Z, USDC, None, "x"),      # no liq_usd: not ranked
    row("base", "curve_ng", GP, X, USDC, 7000, "x"),  # gate family with a G7 wrapper
    row("base", "algebra", P9, Y, Z, 300, "x"),     # two exotics without a common bridge (Z has no hop)
    row("nobr", "v3", P8, X, Y, 10, "x"),           # chain without a bridge list
]
G7SPEC = {
    "window": {"from": 1, "to": 2}, "ages": {"M0": 0, "M1h": 3600}, "mf_ages": ["M1h"], "deadline_s": 600,
    "retries": {"attempts": 1, "backoff_s": 0, "timeout_s": 1}, "state_fork": {"base": 1}, "swaps_per_chain": 7,
    "chains": {
        "base": {"block_time_hint": 2, "label": "L", "max_hops": 2, "native_wrap": WETH, "strata": [
            {"id": "gate-1-1", "kind": "gates", "gate_pool": GP, "gate_family": "curve_ng", "venue_key": "k", "tA": X,
             "tB": USDC, "amounts": {"A": [1], "B": [2]}, "n": 6, "seed_pools": [], "mid_pool": None}]},
        "nobr": {"block_time_hint": 2, "label": "L", "max_hops": 2, "native_wrap": WETH, "strata": []},
    },
}


def build(inv=INV, bridges=BR, g7spec=G7SPEC):
    d = tempfile.mkdtemp()
    with open(os.path.join(d, "inventory.tsv"), "w") as f:
        f.write("\t".join(INV_COLS) + "\n")
        for r in inv:
            f.write("\t".join(r[c] for c in INV_COLS) + "\n")
    out = os.path.join(d, "out")
    spec, nc = bc.build(d, g7spec, out, bridges)
    return spec, nc, out


def strata(spec, chain="base"):
    return {st["id"]: st for st in spec["chains"][chain]["strata"]}


class Cases(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.spec, cls.nc, cls.out = build()
        cls.st = strata(cls.spec)
        cls.scopes = [(c, s) for c, s, _ in cls.nc]

    def test_top_pool_per_family_is_the_deepest(self):
        # mutant: top_per_family "v > bs.liq(best[...])" -> "v <" (the shallowest wins)
        self.assertEqual(self.st["pool-v3"]["_pool"], P2)
        self.assertEqual([p["pool"] for p in self.st["pool-v3"]["seed_pools"]], [P2])
        self.assertEqual((self.st["pool-v3"]["tA"], self.st["pool-v3"]["tB"]), (X, Y))

    def test_rows_without_liq_are_not_ranked(self):
        # mutant: top_per_family "v = bs.liq(r); if v is None: continue" -> "v = bs.liq(r) or 0"
        self.assertNotIn("pool-v2", self.st)
        self.assertEqual(bc.top_per_family([row("base", "v2", P5, Z, USDC, None, "x")]), {})

    def test_gate_pool_reuses_the_g7_stratum_or_is_not_covered(self):
        # mutant: "if not g:" -> "if False:" (a gate pool without a wrapper would be built from None)
        st = self.st["pool-curve_ng"]
        self.assertEqual((st["kind"], st["n"], st["gate_pool"], st["venue_key"], st["_pool"]), ("pool", 1, GP, "k", GP))
        self.assertEqual(st["amounts"], {"A": [1], "B": [2]})  # the G7 stratum's amounts, wrapper included
        self.assertNotIn("pool-lb", self.st)
        self.assertIn(("base", "lb"), self.scopes)

    def test_exotic_bridge_seeds_the_deepest_non_gate_pool_alone(self):
        # mutant: deepest "max(ok, key=bs.liq)" -> "ok[0]" (inventory order: P4 before P3)
        st = self.st["xb-v3-USDC-" + Y[:10]]
        self.assertEqual([p["pool"] for p in st["seed_pools"]], [P3])
        self.assertEqual((st["kind"], st["tA"], st["tB"], st["_pool"]), ("exotic_bridge", Y, USDC, P3))
        self.assertEqual(self.st["xb-v3-USDC-" + X[:10]]["_pool"], P1)
        self.assertIn(("base", "xb-v3-WETH"), self.scopes)  # no X/WETH nor Y/WETH pool

    def test_via_bridge_seeds_both_hop_pools(self):
        # mutant: pool_stratum(..., [p1, p2], fam) -> [p1]
        st = self.st["via-v3-USDC"]
        self.assertEqual({p["pool"] for p in st["seed_pools"]}, {P1, P3})
        self.assertEqual(st["_hops"], [P1, P3])
        self.assertEqual((st["kind"], st["tA"], st["tB"], st["_pool"]), ("exotic_via_bridge", X, Y, P2))
        self.assertNotIn("via-v3-WETH", self.st)

    def test_pair_without_a_common_bridge_is_not_covered(self):
        # mutant: "if not common:" -> "if False:"
        self.assertIn(("base", "via-algebra"), self.scopes)
        self.assertFalse([k for k in self.st if k.startswith("via-algebra")])
        self.assertIn(("base", "xb-algebra-USDC"), self.scopes)  # Z/USDC has no ranked pool

    def test_chain_without_a_bridge_list_has_no_bridge_cases(self):
        # mutants: build "if br is None: notcov.append(...)" -> "if False:"; read_bridges keeps rows without an address
        self.assertIn(("nobr", "bridge"), self.scopes)
        self.assertEqual(list(strata(self.spec, "nobr")), ["pool-v3"])
        d = tempfile.mkdtemp()
        p = os.path.join(d, "bridges.tsv")
        with open(p, "w") as f:
            f.write("chain\tsymbol\taddress\tsource\nbase\tWETH\t%s\ts\nethereum\t-\t\tabsent\n" % WETH.upper())
        br = bc.read_bridges(p)
        self.assertEqual(br, {"base": [("WETH", WETH)]})
        self.assertNotIn("ethereum", br)

    def test_amounts_are_dust_mid_deep(self):
        # mutant: STEPS = (5, 3, 1) -> (5, 3, 2)
        self.assertEqual(bc.amounts("1000000"), [10, 1000, 100000])
        self.assertEqual(bc.amounts("10000"), [10, 1000])  # balance // 10^5 == 0 is dropped
        self.assertEqual(bc.amounts(""), [])
        self.assertEqual(self.st["pool-v3"]["amounts"], {"A": bc.amounts(10 ** 18), "B": bc.amounts(10 ** 18)})

    def test_spec_copies_window_and_modes_from_g7(self):
        # mutant: COPY without "mf_ages"
        for k in ("window", "ages", "mf_ages", "deadline_s", "retries", "state_fork"):
            self.assertEqual(self.spec[k], G7SPEC[k], k)
        self.assertEqual(g7.modes(self.spec), g7.modes(G7SPEC))
        self.assertNotIn("swaps_per_chain", self.spec)
        c = self.spec["chains"]["base"]
        self.assertEqual({k: c[k] for k in bc.CHAIN_COPY}, {k: G7SPEC["chains"]["base"][k] for k in bc.CHAIN_COPY})
        self.assertEqual(json.load(open(os.path.join(self.out, "spec.json")))["window"], G7SPEC["window"])


class Draws(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.spec = build()[0]

    def test_both_directions_every_amount(self):
        # mutant: "for fwd in (True, False):" -> "(True,)"
        ds = [d for d in g8.draws(self.spec, "s", "base", 100, 200) if d["stratum"] == "pool-v3"]
        st = strata(self.spec)["pool-v3"]
        na, nb = len(st["amounts"]["A"]), len(st["amounts"]["B"])
        self.assertEqual(len(ds), na + nb)
        self.assertEqual([d["idx"] for d in ds], list(range(1, na + nb + 1)))
        self.assertEqual([(d["tin"], d["tout"], d["amount"]) for d in ds[:na]], [(X, Y, v) for v in st["amounts"]["A"]])
        self.assertEqual([(d["tin"], d["tout"], d["amount"]) for d in ds[na:]], [(Y, X, v) for v in st["amounts"]["B"]])
        self.assertTrue(all(d["kind"] == "pool" for d in ds))

    def test_seed_fixes_the_block(self):
        # mutant: "b, idx = rng.randint(b0, b1), 0" -> "b, idx = b0, 0"
        d1 = g8.draws(self.spec, "seed-a", "base", 0, 10 ** 9)
        d2 = g8.draws(self.spec, "SEED-A", "base", 0, 10 ** 9)
        d3 = g8.draws(self.spec, "seed-b", "base", 0, 10 ** 9)
        self.assertEqual([(d["stratum"], d["idx"], d["b"]) for d in d1], [(d["stratum"], d["idx"], d["b"]) for d in d2])
        self.assertTrue(all(0 <= d["b"] <= 10 ** 9 for d in d1))
        self.assertEqual(len({d["b"] for d in d1 if d["stratum"] == "pool-v3"}), 1)  # one block per stratum
        self.assertNotEqual({d["stratum"]: d["b"] for d in d1}, {d["stratum"]: d["b"] for d in d3})


def okrow(mode, **kw):
    r = {"chain": "base", "label": "L", "stratum": "pool-v3", "kind": "pool", "idx": 1, "mode": mode, "tin": X, "tout": Y,
         "amount_in": 2, "outcome": "ok", "swept": 0, "est_gas": 250000, "g_quote": 2000000, "g_discovery": 0,
         "g_exec": 300000, "g_legs_sum": 200000, "g_record": 30000, "age_real_s": 10, "net_out": 1000, "delivered": 1000}
    r.update(kw)
    return r


def report(spec, rows):
    d = tempfile.mkdtemp()
    sp, out = os.path.join(d, "spec.json"), os.path.join(d, "results.tsv")
    json.dump(spec, open(sp, "w"))
    with open(out, "w") as f:
        f.write("\t".join(g7.COLS) + "\n")
        for r in rows:
            f.write("\t".join(str(r.get(k, "")) for k in g7.COLS) + "\n")
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        g8.cmd_report(sp, out)
    return buf.getvalue().split("\n")


class Report(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.spec = build()[0]

    def test_per_case_line_counts_only_ok_rows(self):
        # mutant: case_lines 'ok = [r for r in rs if r["outcome"] == "ok"]' -> "ok = rs"
        rows = [okrow("D", idx=1, g_quote=100), okrow("D", idx=2, g_quote=300),
                okrow("D", idx=3, outcome="revert", g_quote=999999)]
        ln = [l for l in report(self.spec, rows) if l.startswith("base\tpool-v3\tpool\tv3\t%s\tD\t" % P2)]
        self.assertEqual(len(ln), 1)
        c = ln[0].split("\t")
        self.assertEqual(c[6:9], ["3", "2", "0"])  # n, ok, noquote
        self.assertEqual(c[8 + g7.OUTCOMES.index("revert")], "1")
        self.assertEqual(c[7 + len(g7.OUTCOMES) + g8.CASE_SEGS.index("g_quote")], "100")  # p50 of 100, 300

    def test_per_case_split_has_n_p50_p95_per_ms_case(self):
        # mutants: case_split drops the ok filter; p95 column printed as p50
        rows = [okrow("M0", idx=i, g_exec=g, g_legs_sum=100) for i, g in ((1, 100), (2, 200), (3, 300))]
        rows += [okrow("M0", idx=4, swept=1, g_exec=5000), okrow("D", idx=5, g_exec=777, est_gas=700),
                 okrow("M0", idx=6, outcome="revert", g_exec=10 ** 6), okrow("M0", idx=7, outcome="noquote", swept="")]
        pre = "base\tpool-v3\tpool\tv3\t%s\t" % P2
        got = {tuple(l[len(pre):].split("\t")[:2]): l[len(pre):].split("\t")[2:] for l in report(self.spec, rows) if l.startswith(pre)}
        self.assertEqual(got[("hit", "g_exec")], ["3", "200", "300"])
        self.assertEqual(got[("hit", "dex_overhead")], ["3", "100", "200"])
        self.assertEqual(got[("miss", "g_exec")], ["1", "5000", "5000"])
        self.assertEqual(got[("D", "g_exec")], ["1", "777", "777"])
        self.assertEqual(got[("D", "est_gas")], ["1", "700", "700"])
        self.assertEqual(got[("hit", "g_record")], ["3", "30000", "30000"])
        self.assertNotIn(("partial", "g_exec"), got)
        hdr = [l for l in report(self.spec, rows) if l.startswith("# per case split:")]
        self.assertEqual(hdr, ["# per case split: chain\tstratum\tkind\tfamily\tpool\tms_case\tsegment\tn\tp50\tp95"])


def workflow_text():
    return open(os.path.join(HERE, "..", "..", ".github", "workflows", "g8-pool-tests.yml")).read()


class Workflow(unittest.TestCase):
    def test_dispatch_only_masked_key_and_g8_commands(self):
        # mutant: the add-mask line removed from g8-pool-tests.yml
        t = workflow_text()
        self.assertIn('echo "::add-mask::$DRPC_KEY"', t)
        self.assertIn("unset DRPC_KEY", t)
        self.assertNotIn("\n  push:", t)
        self.assertIn("permissions:\n  contents: read", t)
        self.assertIn('"$D/g8.py" measure "$D/spec.json" "$G7/state"', t)
        self.assertIn('"$D/g8.py" report "$D/spec.json" out/results.tsv', t)
        self.assertIn('"$D/test_g8.py"', t)
        self.assertIn('"$D/mutants_g8.py"', t)
        self.assertNotIn("echo \"$DRPC_KEY\"", t)


if __name__ == "__main__":
    unittest.main()
