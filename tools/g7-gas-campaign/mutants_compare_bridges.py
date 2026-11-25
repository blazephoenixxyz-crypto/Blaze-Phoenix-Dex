#!/usr/bin/env python3
"""Mutation check for test_compare_bridges.py: each mutant of compare_bridges.py must turn its
named test red by an assertion. Run: python3 -I tools/g7-gas-campaign/mutants_compare_bridges.py"""
import os, shutil, subprocess, sys, tempfile
SRC = os.path.dirname(os.path.abspath(__file__))
M = [  # (test id, old, new)
 ("Pairing.test_pairs_on_the_full_draw_key", '"idx", "b", "mode"', '"idx", "mode"'),
 ("Pairing.test_amount_is_part_of_the_key", ', "tout", "amount_in")', ', "tout")'),
 ("Pairing.test_duplicate_key_is_refused", '            if k in rows:\n                raise', '            if False:\n                raise'),
 ("Outcome.test_lost_and_won_are_counted_per_direction", 'A[k]["outcome"] != "ok" and B[k]["outcome"] == "ok" for k in ks)', 'A[k]["outcome"] == "ok" and B[k]["outcome"] != "ok" for k in ks)'),
 ("Outcome.test_lost_draw_is_listed", '        if A[k]["outcome"] == "ok" and B[k]["outcome"] != "ok":\n            print', '        if False:\n            print'),
 ("Outcome.test_aged_modes_group_apart_from_m0", '"M_aged" if mode.startswith("M")', '"M0" if mode.startswith("M")'),
 ("Gas.test_delta_is_b_minus_a", "d = [b - a for a, b in xs]", "d = [a - b for a, b in xs]"),
 ("Gas.test_only_pairs_ok_in_both_count", 'ks = [k for k in groups[g] if A[k]["outcome"] == "ok" and B[k]["outcome"] == "ok"]\n        for s in segs:', 'ks = [k for k in groups[g] if A[k]["outcome"] == "ok"]\n        for s in segs:'),
 ("Gas.test_p50_is_nearest_rank", "-(-q * len(s) // 100) - 1", "q * len(s) // 100"),
 ("Gas.test_tails_are_p5_and_p95", "return pct(xs, 5), pct(xs, 95)", "return min(xs), max(xs)"),
 ("RouteAndOutput.test_route_change_and_delivered_bps", 'r.get("legs_detail", "").split(":")[0])', 'r.get("legs", ""))'),
 ("RouteAndOutput.test_bps_sign_and_floor", "(b - a) * 10000 // a", "(a - b) * 10000 // a"),
 ("RouteAndOutput.test_delivered_changes_worst_and_best", "if da and db is not None and da != db:", "if da and db is not None:"),
 ("RouteAndOutput.test_delivered_changes_worst_and_best", "len(ch[c]), min(ch[c]), max(ch[c])", "len(ch[c]), max(ch[c]), min(ch[c])"),
 ("RouteAndOutput.test_shape_groups_by_hops_of_a", 'shape[(c, A[k].get("hops", ""))]', 'shape[(c, B[k].get("hops", ""))]'),
]
fail = 0
for tid, old, new in M:
    d = tempfile.mkdtemp()
    for f in ("compare_bridges.py", "test_compare_bridges.py"):
        shutil.copy(os.path.join(SRC, f), d)
    p = os.path.join(d, "compare_bridges.py"); s = open(p).read()
    if s.count(old) != 1:
        print("BADPAT", tid, s.count(old)); fail += 1; continue
    open(p, "w").write(s.replace(old, new))
    r = subprocess.run([sys.executable, "-I", "-W", "ignore", os.path.join(d, "test_compare_bridges.py"), tid],
                       capture_output=True, text=True, timeout=120)
    # Killed only by an assertion: a test that errors proves nothing about the guard.
    red = r.returncode != 0 and "AssertionError" in r.stderr and "errors=" not in r.stderr
    tag = "RED " if red else ("CRASH!" if r.returncode else "GREEN!")
    print(tag + "\t" + tid)
    fail += 0 if red else 1
    shutil.rmtree(d)
print("survivors/bad:", fail, "of", len(M))
sys.exit(1 if fail else 0)
