#!/usr/bin/env python3
"""Mutation check for test_inventory.py: each mutant of inventory.py must turn its named test red.
Run: python3 -I tools/g7-gas-campaign/mutants_inventory.py (exit 1 if a mutant survives)."""
import os, shutil, subprocess, sys, tempfile
SRC = os.path.dirname(os.path.abspath(__file__))
M = [  # (test id, old, new)
 ("Decoders.test_topic0_of_the_public_events", '"v2": "PairCreated(address,address,address,uint256)"', '"v2": "PairCreated(address,address,address)"'),
 ("Decoders.test_v3_real_log", "tick_spacing=s(d[0], 24), pool=addr_of(d[1])", "tick_spacing=s(d[1], 24), pool=addr_of(d[0])"),
 ("Decoders.test_v2_real_log_token_order", 'elif kind in ("v2",):\n        r.update(token0=addr_of(t[1]), token1=addr_of(t[2])', 'elif kind in ("v2",):\n        r.update(token0=addr_of(t[2]), token1=addr_of(t[1])'),
 ("Decoders.test_v4_real_log_rebuilds_its_pool_id", "fee=u(d[0]), tick_spacing=s(d[1], 24), hooks=addr_of(d[2])", "fee=u(d[1]), tick_spacing=s(d[0], 24), hooks=addr_of(d[2])"),
 ("Decoders.test_solidly_stable_flag", "stable=bool(u(t[3]))", "stable=False"),
 ("Decoders.test_cl_tick_spacing_from_topic3", "tick_spacing=s(t[3], 24)", "tick_spacing=s(d[0], 24)"),
 ("Decoders.test_algebra_custom_deployer_is_topic1", "deployer=addr_of(t[1]), token0=addr_of(t[2]), token1=addr_of(t[3])", "deployer=addr_of(t[3]), token0=addr_of(t[1]), token1=addr_of(t[2])"),
 ("Decoders.test_lb_bin_step_is_the_tick_spacing", "bin_step=u(t[3]),\n                 tick_spacing=u(t[3])", "bin_step=u(t[3]),\n                 tick_spacing=u(d[1])"),
 ("Decoders.test_inf_cl_tick_spacing_from_params_bits_16_39", "(u(d[2]) >> 16) & 0xFFFFFF", "(u(d[2]) >> 8) & 0xFFFFFF"),
 ("Decoders.test_inf_bin_bin_step_from_params_bits_16_31", "(u(d[2]) >> 16) & 0xFFFF,", "u(d[2]) & 0xFFFF,"),
 ("Decoders.test_wrong_topic0_is_refused", "if t[0].lower() != TOPICS[kind]:", "if False:"),
 ("RankKey.test_deeper_usd_first", "return (0, -float(v))", "return (0, float(v))"),
 ("RankKey.test_usd_ranks_above_raw_only", "return (1, -lq)", "return (0, -lq)"),
 ("RankKey.test_true_zero_ranks_above_rpc_err", "    if isinstance(lq, int):\n        return (1, -lq)", "    if isinstance(lq, int) and lq:\n        return (1, -lq)"),
 ("LiqUsd.test_absent_priced_side_is_absent_not_a_lower_sum", '        if not isinstance(b, int):\n            return ""', '        if not isinstance(b, int):\n            continue'),
 ("Classify.test_shallow_is_never_zero_or_rpc_err", "pos = [r for r in rows if is_measured_positive(r)]", "pos = list(rows)"),
 ("Classify.test_v4_positive_means_liquidity_not_virtual_balances", '    if row["family"] in ("v4", "v4native", "inf_cl", "inf_bin"):\n        lq = row.get("liquidity_raw")\n        return isinstance(lq, int) and lq > 0\n', ""),
 ("Classify.test_dynamic_fee_flag_is_not_fee_high", "if f >= FEE_HIGH and f != 0x800000:", "if f >= FEE_HIGH:"),
 ("Classify.test_fee_high_boundary", "if f >= FEE_HIGH and", "if f > FEE_HIGH and"),
 ("Classify.test_fee_low_boundary", "elif f <= FEE_LOW:", "elif f < FEE_LOW:"),
 ("Classify.test_family_rep_is_the_deepest_per_factory", "rank_key(r) < rank_key(fam_best[key])", "rank_key(r) > rank_key(fam_best[key])"),
 ("Classify.test_midtail_on_either_side", 'if r["token0"] in midtail or r["token1"] in midtail:', 'if r["token1"] in midtail:'),
 ("Classify.test_shallow_fallback_takes_the_lowest_raw", "sorted(pos, key=rank_key)[-n_shallow:]", "sorted(pos, key=rank_key)[:n_shallow]"),
 ("GateTop3.test_only_gate_families", 'if r["family"] in GATE_FAMS and gate_eligible(r):', "if gate_eligible(r):"),
 ("GateTop3.test_at_most_three_per_chain_family", "sorted(lst, key=rank_key)[:3]", "sorted(lst, key=rank_key)[:4]"),
 ("GateTop3.test_the_three_deepest", "sorted(lst, key=rank_key)[:3]", "sorted(lst, key=rank_key)[-3:]"),
 ("GateTop3.test_grouped_per_chain", 'groups.setdefault((r["chain"], r["family"]), [])', 'groups.setdefault(r["family"], [])'),
 ("GateTop3.test_rpc_err_and_zero_never_gate", "return is_measured_positive(row) or (isinstance(v, float) and v > 0)", "return True"),
 ("GateTop3.test_zero_usd_external_pool_is_not_gate", "(isinstance(v, float) and v > 0)", "isinstance(v, float)"),
 ("GateTop3.test_stale_mark_dropped_and_idempotent", 'if c and c != "gate_top3"', "if c"),
 ("GateTop3.test_virtual_label_on_v4_v4native_inf_cl_only", 'if r["family"] in VIRTUAL_FAMS and VIRTUAL_LABEL', 'if False and VIRTUAL_LABEL'),
 ("GateTop3.test_virtual_label_written_once", ' and VIRTUAL_LABEL not in str(r.get("liq_method", ""))', ""),
 ("GateTop3.test_refinalize_tsv_parses_numbers_and_keeps_rpc_err", "            r[c] = _num(r[c])", "            pass"),
 ("ScanLogs.test_range_error_shrinks_and_covers_everything", "if window > min_window and RANGE_ERR.search(msg):", "if False:"),
 ("ScanLogs.test_non_range_error_is_rpc_err_and_left_uncovered", '            log_rows.append((rpc.chain, emitter, topic0 or "*", lo, hi, "", RPC_ERR))', '            log_rows.append((rpc.chain, emitter, topic0 or "*", lo, hi, "", "ok"))'),
]
fail = 0
for tid, old, new in M:
    d = tempfile.mkdtemp()
    for f in ("inventory.py", "test_inventory.py"):
        shutil.copy(os.path.join(SRC, f), d)
    p = os.path.join(d, "inventory.py"); s = open(p).read()
    if s.count(old) != 1:
        print("BADPAT", tid, s.count(old)); fail += 1; continue
    open(p, "w").write(s.replace(old, new))
    # Killed only by an assertion: a test that errors (exception, missing name) or hangs proves nothing about the guard.
    try:
        r = subprocess.run([sys.executable, "-I", "-W", "ignore", os.path.join(d, "test_inventory.py"), tid],
                           capture_output=True, text=True, timeout=120)
        red = r.returncode != 0 and "AssertionError" in r.stderr and "errors=" not in r.stderr
        tag = "RED " if red else ("CRASH!" if r.returncode else "GREEN!")
        why = [ln for ln in r.stderr.splitlines() if ln[:1].isalpha() and ("Error" in ln or "Exception" in ln)][-1:]
    except subprocess.TimeoutExpired:
        red, tag, why = False, "TIMEOUT!", []
    print(tag + "\t" + tid + ("" if red or not why else "\t" + why[0][:160]))
    fail += 0 if red else 1
    shutil.rmtree(d)
print("survivors/bad:", fail, "of", len(M))
sys.exit(1 if fail else 0)
