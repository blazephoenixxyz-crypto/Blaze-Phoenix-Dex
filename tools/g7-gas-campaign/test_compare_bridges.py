#!/usr/bin/env python3
"""Offline tests of compare_bridges.py (paired A/B comparison of two results.tsv).
Run: python3 -I tools/g7-gas-campaign/test_compare_bridges.py"""
import io, os, sys, tempfile, unittest
from contextlib import redirect_stdout
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import compare_bridges as cb

COLS = ["chain", "stratum", "kind", "idx", "b", "mode", "tin", "tout", "amount_in", "outcome", "detail",
        "hops", "legs", "legs_detail", "g_quote", "g_discovery", "g_discovery_bridge", "g_solve", "g_exec",
        "g_record", "delivered"]


def row(chain="base", idx="1", mode="D", outcome="ok", hops="1", legs="1", pool="0xp", q=1000, e=500,
        dlv=10000, b="7", amount="5"):
    return dict(chain=chain, stratum="s", kind="major", idx=idx, b=b, mode=mode, tin="0xa", tout="0xb",
                amount_in=amount, outcome=outcome, detail="", hops=hops, legs=legs,
                legs_detail=pool + ":1", g_quote=str(q), g_discovery="0", g_discovery_bridge="0",
                g_solve="0", g_exec=str(e), g_record="0", delivered=str(dlv))


def write(rows):
    f = tempfile.NamedTemporaryFile("w", suffix=".tsv", delete=False)
    f.write("\t".join(COLS) + "\n")
    for r in rows:
        f.write("\t".join(r[c] for c in COLS) + "\n")
    f.close()
    return f.name


def run(a, b):
    out = io.StringIO()
    with redirect_stdout(out):
        cb.main(write(a), write(b))
    return out.getvalue()


def section(text, name):
    lines, on = [], False
    for l in text.splitlines():
        if l.startswith("# "):
            on = l.startswith("# " + name)
            continue
        if on:
            lines.append(l.split("\t"))
    return lines


def find(rows, *prefix):
    return [r for r in rows if r[:len(prefix)] == list(prefix)]


class Pairing(unittest.TestCase):
    def test_pairs_on_the_full_draw_key(self):
        # same draw except b: two draws, no pair
        t = run([row(b="1")], [row(b="2")])
        self.assertEqual(section(t, "pairing")[0], ["all", "1", "1", "0", "2"])

    def test_amount_is_part_of_the_key(self):
        t = run([row(amount="1")], [row(amount="2")])
        self.assertEqual(section(t, "pairing")[0][3], "0")

    def test_duplicate_key_is_refused(self):
        with self.assertRaises(SystemExit):
            run([row(), row()], [row()])


class Outcome(unittest.TestCase):
    def test_lost_and_won_are_counted_per_direction(self):
        a = [row(idx="1"), row(idx="2"), row(idx="3", outcome="noquote")]
        b = [row(idx="1", outcome="noquote"), row(idx="2", outcome="revert"), row(idx="3")]
        r = find(section(run(a, b), "outcome"), "base", "D")[0]
        self.assertEqual(r[2:], ["3", "2", "1", "2", "1"])

    def test_lost_draw_is_listed(self):
        t = run([row(idx="9")], [row(idx="9", outcome="revert")])
        self.assertEqual(len(section(t, "lost draws")), 1)
        self.assertEqual(section(t, "lost draws")[0][:6], ["base", "D", "s", "9", "7", "revert"])

    def test_aged_modes_group_apart_from_m0(self):
        t = run([row(mode="M0"), row(mode="M1h")], [row(mode="M0"), row(mode="M1h")])
        modes = {r[1] for r in section(t, "outcome") if r[0] == "base"}
        self.assertEqual(modes, {"M0", "M_aged", "all"})


class Gas(unittest.TestCase):
    def test_delta_is_b_minus_a(self):
        t = run([row(q=1000)], [row(q=700)])
        r = find(section(t, "gas"), "base", "D", "g_quote")[0]
        self.assertEqual(r[3:9], ["1", "1000", "700", "-300", "-300", "-300"])
        self.assertEqual(r[9:], ["1", "0", "0"])

    def test_only_pairs_ok_in_both_count(self):
        t = run([row(idx="1", q=10), row(idx="2", q=99)], [row(idx="1", q=20), row(idx="2", outcome="noquote", q=1)])
        r = find(section(t, "gas"), "base", "D", "g_quote")[0]
        self.assertEqual(r[3], "1")
        self.assertEqual(r[6], "10")

    def test_p50_is_nearest_rank(self):
        self.assertEqual(cb.pct([1, 2, 3, 4], 50), 2)
        self.assertEqual(cb.pct([5, 1, 3], 50), 3)
        self.assertEqual(cb.pct([1] * 19 + [100], 95), 1)
        self.assertEqual(cb.pct(list(range(1, 21)), 95), 19)

    def test_tails_are_p5_and_p95(self):
        self.assertEqual(cb.tails([3, -1, 7]), (-1, 7))
        xs = list(range(100))
        self.assertEqual(cb.tails(xs), (4, 94))


class RouteAndOutput(unittest.TestCase):
    def test_route_change_and_delivered_bps(self):
        a = [row(idx="1", dlv=10000), row(idx="2", dlv=10000, pool="0xp")]
        b = [row(idx="1", dlv=9990), row(idx="2", dlv=10000, pool="0xq")]
        r = find(section(run(a, b), "route and output"), "base", "D")[0]
        self.assertEqual(r[2:4], ["2", "1"])
        self.assertEqual(r[7:], ["1", "1", "0"])
        self.assertEqual(r[5], "-10")

    def test_bps_sign_and_floor(self):
        self.assertEqual(cb.bps(10000, 10001), 1)
        self.assertEqual(cb.bps(10000, 9999), -1)
        self.assertIsNone(cb.bps(0, 5))

    def test_delivered_changes_worst_and_best(self):
        a = [row(idx="1", dlv=10000), row(idx="2", dlv=10000), row(idx="3", dlv=10000), row(idx="4", dlv=10000)]
        b = [row(idx="1", dlv=9650), row(idx="2", dlv=10005), row(idx="3", dlv=10000), row(idx="4", dlv=9990)]
        r = find(section(run(a, b), "delivered changes"), "base")[0]
        self.assertEqual(r[1:], ["3", "-350", "5"])

    def test_shape_groups_by_hops_of_a(self):
        t = run([row(idx="1", hops="2", q=100)], [row(idx="1", hops="1", q=60)])
        self.assertEqual([r[1] for r in section(t, "by route shape") if r[0] == "base"], ["2"])
        r = find(section(t, "by route shape"), "base", "2")[0]
        self.assertEqual(r[2:], ["1", "-40", "0", "1"])


if __name__ == "__main__":
    unittest.main()
