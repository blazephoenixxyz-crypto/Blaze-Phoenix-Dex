#!/usr/bin/env python3
"""Unit tests of g7g8_paired.py (stdlib unittest, no network).

  python3 -I tools/gas-case-study/test_g7g8_paired.py

Each test names the mutant of g7g8_paired.py that turns it red.
"""
import os
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import g7g8_paired as gp  # noqa: E402
from stats import boot_seed  # noqa: E402


def mk(mode, idx="0", chain="base", stratum="major-1", b="100", outcome="ok", net_out="10000",
       g_quote="1000", g_exec="2000", g_record="3000"):
    return dict(chain=chain, stratum=stratum, idx=idx, b=b, mode=mode, outcome=outcome, net_out=net_out,
                g_quote=g_quote, g_exec=g_exec, g_record=g_record)


def pick(out, metric, mode_b="M0", chain="base"):
    rows = [r for r in out if r["metric"] == metric and r["mode_b"] == mode_b and r["chain"] == chain]
    assert len(rows) == 1, rows
    return rows[0]


class Paired(unittest.TestCase):
    def test_missing_key_is_counted_not_silently_dropped(self):
        # mutant: keys = set(side_a) & set(side_b) (intersection) -> n_keys 1
        rows = [mk("D", "0"), mk("M0", "0"), mk("D", "1"), mk("M0", "2")]
        r = pick(gp.run(rows, "D:M0", b=50), "g_exec")
        self.assertEqual((r["n_keys"], r["n_pairs"], r["n_dropped"]), (3, 1, 2))
        self.assertEqual(r["drop_reasons"], "missing_D=1;missing_M0=1")

    def test_pairs_by_key_not_by_row_order(self):
        # mutant: rows paired by their position within the mode, not by (stratum, idx, b)
        rows = [mk("D", "0", g_exec="100"), mk("D", "1", g_exec="500"),
                mk("M0", "1", g_exec="510"), mk("M0", "0", g_exec="90")]
        r = pick(gp.run(rows, "D:M0", b=50), "g_exec")
        self.assertEqual(r["n_pairs"], 2)
        self.assertEqual((r["worst"], r["worst_key"]), (10, "major-1|1|100"))
        self.assertEqual(r["median"], 0)

    def test_out_bps_zero_base_is_absent_not_a_division(self):
        # mutant: the guard `if oa <= 0` removed -> ZeroDivisionError
        rows = [mk("D", "0", net_out="0"), mk("M0", "0", net_out="5")]
        r = pick(gp.run(rows, "D:M0", b=50), "out_bps")
        self.assertEqual((r["n_keys"], r["n_pairs"]), (1, 0))
        self.assertNotIn("median", r)
        self.assertEqual(r["drop_reasons"], "D:net_out_nonpos=1")

    def test_empty_cell_is_absent_not_zero(self):
        # mutant: ival("") returns 0 -> the key pairs with d = 0 - 1000
        rows = [mk("D", "0", g_quote="1000"), mk("M0", "0", g_quote=""), mk("D", "1", net_out=""),
                mk("M0", "1")]
        out = gp.run(rows, "D:M0", b=50)
        q = pick(out, "g_quote")
        self.assertEqual((q["n_pairs"], q["drop_reasons"]), (1, "M0:g_quote_absent=1"))
        o = pick(out, "out_bps")
        self.assertEqual((o["n_pairs"], o["drop_reasons"]), (1, "D:net_out_absent=1"))

    def test_non_ok_outcome_stays_in_denominator(self):
        # mutant: index() skips rows whose outcome is not ok -> reason missing_M0, not M0:revert
        rows = [mk("D", "0"), mk("M0", "0", outcome="revert", g_exec=""),
                mk("D", "1", outcome="noquote"), mk("M0", "1", outcome="noquote"),
                mk("D", "2"), mk("M0", "2")]
        r = pick(gp.run(rows, "D:M0", b=50), "g_exec")
        self.assertEqual((r["n_keys"], r["n_pairs"], r["n_dropped"]), (3, 1, 2))
        self.assertEqual(r["drop_reasons"], "D:noquote+M0:noquote=1;M0:revert=1")
        self.assertAlmostEqual(r["pair_rate"], 1 / 3)
        self.assertLess(r["pair_rate_lo"], 1 / 3)
        self.assertGreater(r["pair_rate_hi"], 1 / 3)

    def test_bootstrap_is_deterministic_by_seed(self):
        # mutant: bootstrap_ci(vals, None, b) -> a fresh OS-seeded generator on each call
        rows = []
        for i, (gd, gm) in enumerate([(1000, 1000 + 37 * i * i - 11 * i) for i in range(15)]):
            rows += [mk("D", str(i), g_exec=str(gd)), mk("M0", str(i), g_exec=str(gm))]
        ci = [(r["ci95_lo"], r["ci95_hi"]) for r in [pick(gp.run(rows, "D:M0", seed=7, b=300), "g_exec")
                                                     for _ in range(4)]]
        self.assertEqual(len(set(ci)), 1)
        self.assertEqual(pick(gp.run(rows, "D:M0", b=10), "g_exec")["boot_seed"], boot_seed())

    def test_plus_minus_one_wei_boundaries(self):
        # mutant: the guard `if oa <= 0` becomes `if oa <= 1` -> net_out_D = 1 wei is refused
        rows = [mk("D", "0", net_out="10000", g_exec="2000"), mk("M0", "0", net_out="10001", g_exec="2001"),
                mk("D", "1", net_out="10000", g_exec="2000"), mk("M0", "1", net_out="9999", g_exec="1999"),
                mk("D", "2", net_out="1"), mk("M0", "2", net_out="2"),
                mk("D", "3", net_out="1"), mk("M0", "3", net_out="0")]
        out = gp.run(rows, "D:M0", b=50)
        o = pick(out, "out_bps")
        self.assertEqual(o["n_pairs"], 4)
        self.assertEqual((o["worst"], o["worst_key"]), (-10000.0, "major-1|3|100"))
        self.assertEqual(sorted([o["p5"], o["p95"]]), [-10000.0, 10000.0])
        g = pick(out, "g_exec")
        self.assertEqual((g["worst"], g["worst_key"]), (1, "major-1|0|100"))

    def test_sign_and_worst_direction(self):
        # mutant: worst out_bps taken with max (largest gain) instead of min (largest loss)
        rows = [mk("D", "0", net_out="10000"), mk("M0", "0", net_out="10100"),
                mk("D", "1", net_out="10000"), mk("M0", "1", net_out="9800")]
        o = pick(gp.run(rows, "D:M0", b=50), "out_bps")
        self.assertEqual((o["worst"], o["worst_key"]), (-200.0, "major-1|1|100"))

    def test_glob_expands_over_present_modes(self):
        # mutant: a glob is kept literal (bs = [b]) -> one row with mode_b 'MF*' and no pair
        rows = [mk("D", "0"), mk("MF24h", "0", g_exec="1900"), mk("MF72h", "0", g_exec="2100"),
                mk("M0", "0")]
        out = gp.run(rows, "D:MF*", b=50)
        self.assertEqual(sorted({r["mode_b"] for r in out}), ["MF24h", "MF72h"])
        self.assertEqual(pick(out, "g_exec", "MF24h")["median"], -100)
        self.assertEqual(gp.parse_pairs("D:M0,D:MF*", {"D", "M0"}), [("D", "M0"), ("D", "MF*")])

    def test_absent_mode_gives_an_n0_row_per_chain(self):
        # mutant: run() skips a (chain, pair, metric) with no pair -> the arbitrum rows vanish
        rows = [mk("D", "0"), mk("M0", "0"), mk("D", "0", chain="arbitrum")]
        out = gp.run(rows, "D:M0", b=50)
        self.assertEqual(len(out), 2 * len(gp.METRICS))
        r = pick(out, "g_exec", chain="arbitrum")
        self.assertEqual((r["n_keys"], r["n_pairs"], r["drop_reasons"]), (1, 0, "missing_M0=1"))

    def test_cli_header_once_and_byte_identical(self):
        # mutant: write() emits the header before every row -> the header appears 3 times
        rows = [mk("D", str(i), g_exec=str(2000 + i)) for i in range(3)] + \
               [mk("M0", str(i), g_exec=str(1990 + 3 * i)) for i in range(3)]
        with tempfile.TemporaryDirectory() as d:
            src = os.path.join(d, "results.tsv")
            cols = list(rows[0])
            with open(src, "w") as f:
                f.write("\t".join(cols) + "\n")
                f.writelines("\t".join(r[c] for c in cols) + "\n" for r in rows)
            outs = []
            for n in (1, 2):
                p = os.path.join(d, f"out{n}.tsv")
                gp.main([src, p, "--seed", "42", "--boot-b", "100", "--pairs", "D:M0"])
                with open(p, "rb") as f:
                    outs.append(f.read())
            self.assertEqual(outs[0], outs[1])
            lines = outs[0].decode().splitlines()
            self.assertEqual(sum(ln.startswith("chain\tmode_a") for ln in lines), 1)
            self.assertEqual(len(lines), 1 + len(gp.METRICS))

    def test_duplicate_key_and_missing_column_are_refused(self):
        # mutant: index() overwrites a duplicated key silently
        with self.assertRaises(ValueError):
            gp.run([mk("D", "0"), mk("D", "0")], "D:M0", b=10)
        bad = mk("D", "0")
        del bad["g_record"]
        with self.assertRaises(ValueError):
            gp.run([bad], "D:M0", b=10)


if __name__ == "__main__":
    unittest.main()
