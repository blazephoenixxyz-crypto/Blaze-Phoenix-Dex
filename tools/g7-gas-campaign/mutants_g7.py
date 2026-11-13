#!/usr/bin/env python3
"""Mutation check for test_g7.py: each mutant of g7.py must turn its named test red.
Run: python3 -I tools/g7-gas-campaign/mutants_g7.py (exit 1 if a mutant survives).
A 4th tuple field names the mutated file (default g7.py)."""
import os, shutil, subprocess, sys, tempfile
SRC = os.path.dirname(os.path.abspath(__file__))
M = [  # (test id, old, new)
 ("TreeLabel.test_state_of_another_tree_is_refused", 'if man["tree_commit"][:7] not in self.label:', 'if False:'),
 ("TreeLabel.test_every_row_carries_the_code_ceiling", '"max_hops_code": ch.max_hops, ', ''),
 ("FirstAtOrAfter.test_exact_timestamp_is_the_block_itself", "if ts(mid) >= t:", "if ts(mid) > t:"),
 ("FirstAtOrAfter.test_hi_grows_past_a_short_initial_bracket", "    while ts(hi) < t:\n        lo, hi = hi, hi + 2 * (hi - lo) + 1\n", ""),
 ("FirstAtOrAfter.test_gap_returns_the_first_block_after", "            lo = mid\n    return hi", "            lo = mid\n    return lo"),
 ("Abi.test_decode_preview_fields_by_declaration_order", '"estGas": f(8), "hops": f(9)', '"estGas": f(9), "hops": f(8)'),
 ("Abi.test_decode_preview_can_execute_false", '"canExecute": f(13) == 1', '"canExecute": f(12) != 0'),
 ("Abi.test_encode_batch_matches_hand_encoding", "heads, tails, off = [], [], 32 * n", "heads, tails, off = [], [], 32 * (n + 1)"),
 ("Abi.test_encode_batch_second_head_skips_first_tail", "off += len(t) // 2", "off += 32"),
 ("Abi.test_calldata_cost_and_7623_floor", "10 * (z + 4 * nz)", "10 * (z + nz)"),
 ("Abi.test_fits_2_10_boundaries", "hops <= max_hops", "hops < max_hops"),
 ("Segments.test_discover_frame_means_swept", '            seg["swept"] = 1\n', ""),
 ("Segments.test_gates_count_top_most_frames_once", "(to == gate or to in wr) and id(p) not in gated", "(to == gate or to in wr)"),
 ("Segments.test_sweep_excludes_callback_payments_inside_a_leg", "leg_end = i + subtree_size(n) - 1", "leg_end = i"),
 ("Segments.test_nested_swap_is_not_a_second_leg", "sel_of(n) in LEG_SELS and i > leg_end:", "sel_of(n) in LEG_SELS:"),
 ("Segments.test_router_gas_is_top_most_frames_only", "if to == router and not above:", "if to == router:"),
 ("Segments.test_record_is_hub_recordswap_under_the_router_only", 'if inside and hub and to == hub and sel_of(n) == SEL["record"]:', 'if hub and to == hub and sel_of(n) == SEL["record"]:'),
 ("Segments.test_record_is_hub_recordswap_under_the_router_only", 'if inside and hub and to == hub and sel_of(n) == SEL["record"]:', 'if inside and hub and to == hub:'),
 ("Stamp.test_rewrites_every_packed_occurrence", "i = b.find(pat, i + width)", "i = -1"),
 ("Stamp.test_absent_stamp_gives_zero_hits", "            if here:\n                hits += here", "            if True:\n                hits += here + 1"),
 ("Draws.test_deterministic_per_seed_and_distinct_across_seeds", 'f"{seed}:{sid}"', 'f"{sid}"'),
 ("Draws.test_ranges_counts_and_direction_amounts", 'st["amounts"]["A" if fwd else "B"]', 'st["amounts"]["A"]'),
 ("Draws.test_strata_streams_are_independent", "        rng = stratum_rng(seed.lower(), f\"{chain}/{st['id']}\")\n", ""),
 ("MeasureDraw.test_prereq_refuses_ts_b_minus_age_at_or_before_state_ts", "if ts_b - age <= ch.state_ts:", "if ts_b - age < ch.state_ts:"),
 ("MeasureDraw.test_mf_without_stamp_is_mf_unforced", "if not hits:", "if False:"),
 ("MeasureDraw.test_mf_that_still_sweeps_is_mf_unforced", 'if forced and row.get("swept") == 1', 'if False and row.get("swept") == 1'),
 ("MeasureDraw.test_resume_skips_done_rows_and_keeps_the_D_reference", 'ref = done[key].get("net_out") if', 'ref = None if'),
 ("Resume.test_load_done_retries_rpc_err_and_timeout_only", 'if smoke or r["outcome"] not in ("rpc_err", "timeout")', 'if True'),
 ("AcceptFams.test_avalanche_keeps_prereg_families_after_phase_a", 'FAMS="1 2 3 4$FAMS"', 'FAMS="1 2 3 4"', "deploy_state.sh"),
 ("AcceptFams.test_avalanche_without_prereg_accepts_phase_a", '  [ "$CHAIN" = avalanche ] && FAMS="1 2 3 4$FAMS"\n', "", "deploy_state.sh"),
 ("AcceptFams.test_other_chains_accept_only_prereg", '[ "$CHAIN" = avalanche ] && FAMS=', 'FAMS=', "deploy_state.sh"),
 ("TxFlags.test_tx_flags_are_legacy", 'TXF="--legacy"', 'TXF=""', "deploy_state.sh"),
 ("TxFlags.test_forge_script_carries_tx_flags", '--broadcast --slow $TXF 2>&1', '--broadcast --slow 2>&1', "deploy_state.sh"),
 ("TxFlags.test_forge_create_carries_tx_flags", '--private-key "$PK" --broadcast $TXF \\', '--private-key "$PK" --broadcast \\', "deploy_state.sh"),
 ("Vital.test_wrapper_resolved_by_gate_pool", 'w_ = ch.wrapper_of_pool.get(d["st"].get("gate_pool", "").lower())', 'w_ = d["st"].get("wrapper")'),
 ("Vital.test_wrapper_resolved_by_gate_pool", "{r[5].lower(): r[6].lower() for r", "{r[5]: r[6].lower() for r"),
 ("Vital.test_refused_create_has_no_vital_and_no_call", 'for r in rows if r[7] == "created"}', 'for r in rows}'),
 ("KeyHygiene.test_rpc_error_never_carries_the_url", "last, timed_out = type(ex).__name__,", "last, timed_out = str(ex),"),
 ("Segments.test_bridge_sweep_is_not_swept", "if set(frame_pair(n)) == want:", "if True:"),
 ("Segments.test_bridge_sweep_is_not_swept", '                seg["g_discovery_bridge"] += fgas(n)', "                pass"),
 ("Segments.test_bridge_sweep_is_not_swept", 'return "0x" + i[32:72].lower(), "0x" + i[96:136].lower()', 'return "0x" + i[32:72].lower(), "0x" + i[32:72].lower()'),
 ("QuoteRow.test_noquote_keeps_the_solver_error_and_the_pair", '(d["tin"], d["tout"]))', '(d["tout"], d["tout"]))'),
 ("QuoteRow.test_noquote_keeps_the_solver_error_and_the_pair", '[:40] + ":" + (tr.get("output") or "")[:74])', '[:60])'),
 ("BalanceSlot.test_balance_in_another_account_is_found_past_a_reverting_slot", "                except Reverted:\n                    continue\n", "                except KeyError:\n                    continue\n"),
 ("BalanceSlot.test_balance_in_another_account_is_found_past_a_reverting_slot", "            for s in (acc.get(\"storage\") or {}):\n                v = 987654321987654321", "            if acct.lower() != token:\n                continue\n            for s in (acc.get(\"storage\") or {}):\n                v = 987654321987654321"),
 ("BalanceSlot.test_override_funds_the_holder_account", "o.setdefault(acct.lower(), {})", "o.setdefault(self.probe, {})"),
 ("SeedOks.test_decode_bools", "for i in range(int(d[o:o + 64], 16))]", "for i in range(int(d[o:o + 64], 16) - 1)]"),
 ("MeasureDraw.test_mf_without_stamp_is_mf_unforced", "seeds_ok=sum(oks), seeds_n=len(oks)", "seeds_ok=len(oks), seeds_n=len(oks)"),
 ("Draws.test_native_sentinel_is_drawn_as_the_wrapped_token", "if int(t, 16) == 0 else t", "if False else t"),
]
# Draws.test_strata_streams: the mutant is one rng per chain, defined before the strata loop
fail = 0
for tid, old, new, *tgt in M:
    d = tempfile.mkdtemp()
    for f in ("g7.py", "test_g7.py", "deploy_state.sh"):
        shutil.copy(os.path.join(SRC, f), d)
    p = os.path.join(d, tgt[0] if tgt else "g7.py"); s = open(p).read()
    if s.count(old) != 1:
        print("BADPAT", tid, s.count(old)); fail += 1; continue
    s = s.replace(old, new)
    if "stratum_rng(seed.lower(), f\"{chain}/{st['id']}\")" not in s and tid.startswith("Draws.test_strata"):
        s = s.replace("    out = []\n    for st in spec[\"chains\"][chain][\"strata\"]:", "    out = []\n    rng = stratum_rng(seed.lower(), chain)\n    for st in spec[\"chains\"][chain][\"strata\"]:")
    open(p, "w").write(s)
    r = subprocess.run([sys.executable, "-I", "-W", "ignore", os.path.join(d, "test_g7.py"), tid], capture_output=True, text=True, timeout=120)
    red = r.returncode != 0
    print(("RED " if red else "GREEN!") + "\t" + tid)
    fail += 0 if red else 1
    shutil.rmtree(d)
print("survivors/bad:", fail, "of", len(M))
sys.exit(1 if fail else 0)
