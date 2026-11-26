#!/usr/bin/env python3
"""Offline tests of usage_report.py (usage curve U1..Uk of one results.tsv).
Run: python3 -I tools/g7-gas-campaign/test_usage_report.py"""
import io, os, sys, tempfile, unittest
from contextlib import redirect_stdout
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import usage_report as ur

COLS = ["chain", "stratum", "kind", "idx", "b", "mode", "tin", "tout", "amount_in", "outcome",
        "g_quote", "g_discovery", "g_exec", "g_record", "delivered", "ms_case"]


def row(mode, idx="1", chain="base", outcome="ok", e=500, rec=100, q=1000, dlv=10000, case="miss"):
    return dict(chain=chain, stratum="s", kind="major", idx=idx, b="7", mode=mode, tin="0xa", tout="0xb",
                amount_in="5", outcome=outcome, g_quote=str(q), g_discovery="0", g_exec=str(e),
                g_record=str(rec), delivered=str(dlv), ms_case=case)


def run(rows):
    f = tempfile.NamedTemporaryFile("w", suffix=".tsv", delete=False)
    f.write("\t".join(COLS) + "\n")
    for r in rows:
        f.write("\t".join(r[c] for c in COLS) + "\n")
    f.close()
    out = io.StringIO()
    with redirect_stdout(out):
        ur.main(f.name)
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


class Usage(unittest.TestCase):
    # Mutant: the delta taken as U1 - Uk (a cheaper second swap would read as dearer).
    def test_delta_is_step_minus_first(self):
        t = run([row("U1", e=900, rec=700), row("U2", e=300, rec=20)])
        rec = {(l[1], l[3]): l for l in section(t, "usage") if l[0] == "base"}
        self.assertEqual(rec[("2", "g_exec")][4:8], ["300", "-600", "-600", "-600"])
        self.assertEqual(rec[("2", "g_record")][4:6], ["20", "-680"])
        self.assertEqual(rec[("1", "g_exec")][5], "0")

    # Mutant: the chain not cut at the first step that is not ok (U3 after a reverted U2 counts).
    def test_a_draw_counts_only_up_to_its_first_not_ok_step(self):
        t = run([row("U1"), row("U2", outcome="revert"), row("U3", e=100)])
        steps = sorted({l[1] for l in section(t, "usage") if l[0] == "base"})
        self.assertEqual(steps, ["1"])

    # Mutant: a missing step not cut (a draw with U1 and U3 but no U2 reaches step 3).
    def test_a_missing_step_cuts_the_chain(self):
        t = run([row("U1"), row("U3", e=100)])
        steps = sorted({l[1] for l in section(t, "usage") if l[0] == "base"})
        self.assertEqual(steps, ["1"])

    # Mutant: the D check compares g_exec with g_record of D.
    def test_d_check_pairs_u1_with_d_of_the_same_draw(self):
        t = run([row("D", e=500, rec=100), row("U1", e=500, rec=100, dlv=9999),
                 row("D", idx="2", e=400), row("U1", idx="2", e=401)])
        chk = {l[0]: l[1:] for l in section(t, "D check")}
        self.assertEqual(chk["base"], ["2", "1", "1"])

    # Mutant: the case counts read from U1 instead of Uk.
    def test_quote_case_is_counted_per_step(self):
        t = run([row("U1", case="miss"), row("U2", case="hit"), row("U1", idx="2", case="miss"),
                 row("U2", idx="2", case="partial")])
        cs = {l[1]: l[2:] for l in section(t, "quote case") if l[0] == "base"}
        self.assertEqual(cs, {"1": ["0", "0", "2"], "2": ["1", "1", "0"]})

    # Mutant: the seeded chain not started at its U1 (no step 1, every S draw dropped).
    def test_seeded_series_starts_at_u1_and_is_reported_apart(self):
        t = run([row("U1", e=900), row("U2", e=400), row("S2", e=300, q=200, case="hit")])
        rec = {(l[0], l[1], l[3]): l for l in section(t, "usage")}
        self.assertEqual(rec.get(("base+seed", "2", "g_exec"), [])[4:6], ["300", "-600"])
        self.assertEqual(rec[("base", "2", "g_exec")][4:6], ["400", "-500"])
        cs = {(l[0], l[1]): l[2:] for l in section(t, "quote case")}
        self.assertEqual(cs.get(("base+seed", "2")), ["1", "0", "0"])


if __name__ == "__main__":
    unittest.main()
