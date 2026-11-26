#!/usr/bin/env python3
"""Mutation check for test_usage_report.py: each mutant of usage_report.py must turn its named
test red by an assertion. Run: python3 -I tools/g7-gas-campaign/mutants_usage_report.py"""
import os, shutil, subprocess, sys, tempfile
SRC = os.path.dirname(os.path.abspath(__file__))
M = [  # (test id, old, new)
 ("Usage.test_delta_is_step_minus_first", "d = [b - a for a, b in xs]", "d = [a - b for a, b in xs]"),
 ("Usage.test_a_draw_counts_only_up_to_its_first_not_ok_step", 'if i not in steps or steps[i]["outcome"] != "ok":', "if i not in steps:"),
 ("Usage.test_a_missing_step_cuts_the_chain", "for i in range(1, max(steps) + 1):", "for i in sorted(steps):"),
 ("Usage.test_d_check_pairs_u1_with_d_of_the_same_draw", 'num(run[0], "g_exec") == num(d_rows[k], "g_exec")', 'num(run[0], "g_exec") == num(d_rows[k], "g_record")'),
 ("Usage.test_quote_case_is_counted_per_step", 'cs = [b.get("ms_case", "") for _, b in at[(c, i)]]', 'cs = [a.get("ms_case", "") for a, _ in at[(c, i)]]'),
 ("Usage.test_seeded_series_starts_at_u1_and_is_reported_apart", "            if 1 in u:\n                steps[1] = u[1]\n", ""),
]
fail = 0
for tid, old, new in M:
    d = tempfile.mkdtemp()
    for f in ("usage_report.py", "compare_bridges.py", "test_usage_report.py"):
        shutil.copy(os.path.join(SRC, f), d)
    p = os.path.join(d, "usage_report.py"); s = open(p).read()
    if s.count(old) != 1:
        print("BADPAT", tid, s.count(old)); fail += 1; continue
    open(p, "w").write(s.replace(old, new))
    r = subprocess.run([sys.executable, "-I", "-W", "ignore", os.path.join(d, "test_usage_report.py"), tid],
                       capture_output=True, text=True, timeout=120)
    # Killed only by an assertion: a test that errors proves nothing about the guard.
    red = r.returncode != 0 and "AssertionError" in r.stderr and "errors=" not in r.stderr
    tag = "RED " if red else ("CRASH!" if r.returncode else "GREEN!")
    print(tag + "\t" + tid)
    fail += 0 if red else 1
    shutil.rmtree(d)
print("survivors/bad:", fail, "of", len(M))
sys.exit(1 if fail else 0)
