#!/usr/bin/env python3
"""Mutation check for test_g7.py: each mutant of g7.py must turn its named test red.
Run: python3 -I tools/g7-gas-campaign/mutants_g7.py (exit 1 if a mutant survives).
A 4th tuple field names the mutated file (default g7.py). META: the named meta-mutants."""
import os, shutil, subprocess, sys, tempfile
SRC = os.path.dirname(os.path.abspath(__file__))
M = [  # (test id, old, new)
 ("RpcUrl.test_own_url_replaces_drpc_and_skips_the_key_file", 'url = os.environ.get("G7_RPC_URL_" + chain.upper())', "url = None"),
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
 ("Segments.test_discover_frame_means_swept", '                seg["swept"] = 1\n', "                pass\n"),
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
 ("RevertDetail.test_error_string_is_decoded_else_the_selector_is_kept", "if d[:8] == ERROR_SEL and len(d) >= 8 + 128:", "if False:"),
 ("PoolFee.test_seed_fee_first_then_fee_call_in_bps", "total += known[pool] / 100", "total += known[pool]"),
 ("NqClass.test_classes_s_dust_a_aprime_b", 'elif k in oks and oks[k] < int(r["amount_in"]):', "elif k in oks:"),
 ("MidGuard.test_no_code_at_window_start_or_empty_pool_gives_no_mid", 'in ("0x", "", None):\n        return ""', 'in ("",):\n        return ""'),
 ("MidGuard.test_no_code_at_window_start_or_empty_pool_gives_no_mid", "        if word(lq, 0) == 0:\n            return \"\"\n", ""),
 ("FundGuard.test_unfunded_probe_is_prereq_not_revert", 'if bal != d["amount"]:', "if False:"),
 ("OutOfGas.test_out_of_gas_trace_is_retried_once_with_twice_the_cap", "        cap *= 2\n", "        cap *= 1\n"),
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
 ("QuoteRow.test_noquote_keeps_the_solver_error_and_the_pair", '[:40] + ":" + revert_detail("", tr.get("output"), 72))', '[:60])'),
 ("BalanceSlot.test_balance_in_another_account_is_found_past_a_reverting_slot", "                except Reverted:\n                    continue\n", "                except KeyError:\n                    continue\n"),
 ("BalanceSlot.test_balance_in_another_account_is_found_past_a_reverting_slot", "            for s in (acc.get(\"storage\") or {}):\n                v = 987654321987654321", "            if acct.lower() != token:\n                continue\n            for s in (acc.get(\"storage\") or {}):\n                v = 987654321987654321"),
 ("BalanceSlot.test_override_funds_the_holder_account", "o.setdefault(acct.lower(), {})", "o.setdefault(self.probe, {})"),
 ("SeedOks.test_decode_bools", "for i in range(int(d[o:o + 64], 16))]", "for i in range(int(d[o:o + 64], 16) - 1)]"),
 ("MeasureDraw.test_mf_without_stamp_is_mf_unforced", "seeds_ok=sum(oks), seeds_n=len(oks)", "seeds_ok=len(oks), seeds_n=len(oks)"),
 ("Draws.test_native_sentinel_is_drawn_as_the_wrapped_token", "if int(t, 16) == 0 else t", "if False else t"),
 ("MsCase.test_cases", '    if int(row.get("g_discovery") or 0) > 0:\n        return "partial"\n', ""),
 ("MsCase.test_cases", "int(age) > ttl", "int(age) >= ttl"),
 ("MsCase.test_measure_draw_sets_the_case", '        row["ms_case"] = ms_case(row)\n', ""),
 ("ReportSplit.test_exec_split_per_chain_kind", 'return int(r["g_exec"]) - int(r["g_legs_sum"])', 'return int(r["g_exec"]) + int(r["g_legs_sum"])'),
 ("ReportSplit.test_exec_split_per_chain_kind", 'return int(r["g_exec"]) - int(r["g_legs_sum"])', 'return int(r["g_exec"]) - int(r["g_legs_sum"]) - int(r["g_record"]) - int(r["g_sweep"])'),
 ("ReportSplit.test_exec_split_per_chain_kind", 'return round(int(r["g_record"]) / int(r["g_exec"]), 4)', 'return round(int(r["g_record"]) / int(r["g_legs_sum"]), 4)'),
 ("ReportSplit.test_moonslot_effect_D_vs_each_natural_mode", 'r["mode"] == m and r["outcome"] == "ok" and r.get(s) not in ("", None)]', 'r["mode"] == m and r.get(s) not in ("", None)]'),
 ("Universe.test_universe_input_and_spec_branch", '          [ "$UNIVERSE" = site ] && SPEC="$D/site/spec.json"\n          if [ "$MODE" = measure ]; then', '          if [ "$MODE" = measure ]; then', "g7-gas-campaign.yml"),
 ("Universe.test_universe_input_and_spec_branch", 'report "$SPEC" out/results.tsv', 'report "$D/spec.json" out/results.tsv', "g7-gas-campaign.yml"),
 ("MsCase.test_report_table_per_chain_kind_case", 'for r in rows if r["outcome"] == "ok" and r["ms_case"]})', 'for r in rows if r["ms_case"]})'),
 ("PairedVsD.test_pairs_by_draw_not_by_stratum", 'd = {draw_key(r): int(r[s]) for r in rows if r["mode"] == "D" and r["outcome"] == "ok" and', 'd = {draw_key(r): int(r[s]) for r in rows if r["mode"] == "D" and'),
 ("PairedVsD.test_p95_only_from_the_declared_minimum", "if len(v) >= PAIRED_MIN_N else", "if len(v) > PAIRED_MIN_N else"),
 ("GRecordShape.test_split_by_hops_and_legs_per_mode_over_ok_rows", 'shape = lambda r: (r["chain"], r["hops"], r["legs"])', 'shape = lambda r: (r["chain"], r["hops"], r["hops"])'),
 ("GRecordShape.test_split_by_hops_and_legs_per_mode_over_ok_rows", 'if shape(r) == k and r["mode"] == m]', "if shape(r) == k]"),
 ("GRecordShape.test_split_by_hops_and_legs_per_mode_over_ok_rows", 'rec = [r for r in rows if r["outcome"] == "ok" and r["mode"] in gm and', 'rec = [r for r in rows if r["mode"] in gm and'),
 ("GRecordShape.test_p95_only_from_the_declared_minimum", "if len(g) >= PAIRED_MIN_N else", "if len(g) > PAIRED_MIN_N else"),
 ("SwapCoverage.test_draw_with_swap_ok_and_mf_unforced_counts_8_of_8", 'elif r["outcome"] == "mf_unforced" and oc.get(', 'elif False and oc.get('),
 ("SwapCoverage.test_report_counts_mf_unforced_as_its_twin_over_every_row", '"M" + r["mode"][2:])) == "ok":', '"M" + r["mode"][2:])) != "x":'),
 ("SwapCoverage.test_report_counts_mf_unforced_as_its_twin_over_every_row", '"M" + r["mode"][2:])) == "ok":', '"D")) == "ok":'),
 ("LegAmt.test_input_per_leg_from_transfers_into_the_target_under_the_router", "if dst == to:", "if dst:"),
 ("LegAmt.test_input_per_leg_from_transfers_into_the_target_under_the_router", "            if id(n) not in under:\n                continue\n", ""),
 ("DexUsage.test_legs_gas_draws_modes_over_ok_rows", "            c[0] += 1\n            c[1] += int(g)", "            c[0] += 2\n            c[1] += int(g)"),
 ("DexUsage.test_legs_gas_draws_modes_over_ok_rows", "c[2].add(draw_key(r))", "c[2].add(id(r))"),
 ("DexUsage.test_legs_gas_draws_modes_over_ok_rows", 'if r.get("outcome") != "ok":\n            continue', "pass"),
 ("DexUsage.test_addr_basis_needs_the_same_kind_on_another_chain", "and k == kind and", "and"),
 ("ExecRevert.test_exec_revert_keeps_the_selector_and_the_code_word", 'revert_detail("exec:", ret, 72)', 'revert_detail("exec:", ret)'),
 ("Detail.test_keccak_matches_cast_at_the_padding_edges_and_the_src_selectors", "if (len(data) + 1) % 136 else", "if True else"),
 ("Detail.test_wilson_interval_and_share_only_below_100", "c, h = (p + z * z / (2 * n)) / d", "c, h = (p + z * z / n) / d"),
 ("Detail.test_wilson_interval_and_share_only_below_100", "if n < 100 else", "if True else"),
 ("Detail.test_8_1_legs_by_kind_and_top_pools_over_ok_rows", 'legs = [(r, *x) for r in rows if r["outcome"] == "ok" for x in', 'legs = [(r, *x) for r in rows for x in'),
 ("Detail.test_8_1_block_range_skips_absent_b", 'return [min(bs), max(bs)] if bs else ["", ""]', 'return [min(bs), max(bs)] if bs else [0, 0]'),
 ("Detail.test_8_2_topology_hops_legs", "int(l) == int(h)", "int(l) != int(h)"),
 ("Detail.test_8_3_token_class_and_decimals", '< int(r["net_out"])', '<= int(r["net_out"])'),
 ("Detail.test_8_4_usd_bucket_edges_and_basis", "if usd < hi)", "if usd <= hi)"),
 ("Detail.test_8_5_causes_decoded_with_their_code", "ERR_BY_SEL = {keccak256(s.encode())[:4]", "ERR_BY_SEL = {keccak256(s.encode())[:3]"),
 ("Detail.test_8_6_gas_by_segment_and_estimate_delta", "mx = max(vals)", "mx = min(vals)"),
 ("Detail.test_8_7_absent_columns_say_no_data", 'out += nodata("8.7a fallback to the runner-up (f82bc67)", "fb_used") if "fb_used" not in cols else []', "out += []"),
 ("Detail.test_index_names_every_section_whole_with_its_line_count", '"8.3a token class (measured, delivered < net_out or leg_amt < amount_in)"', '"8.3a token class (measured: delivered < net_out, or leg_amt < amount_in)"'),
]
# Meta-mutants of the paired comparison and of the draw (name, test id, old, new[, file]): each one
# must turn its named test red.
META = [
 ("unpaired", "PairedVsD.test_pairs_by_draw_not_by_stratum", 'return r["chain"], r["stratum"], r["idx"], r["b"]', 'return r["chain"], r["stratum"]'),
 ("p95-below-min-n", "PairedVsD.test_p95_only_from_the_declared_minimum", "if len(v) >= PAIRED_MIN_N else", "if True else"),
 ("mode-summed", "PairedVsD.test_a_mode_is_never_summed_into_another", 'out.setdefault((r["chain"], r["mode"]), [])', 'out.setdefault((r["chain"], r["mode"].replace("F", "")), [])'),
 ("declared-cell-gone", "PairedVsD.test_every_declared_cell_is_printed", 'if c != "all" and not v:', "if not v:"),
 ("seed-chosen", "Seed.test_seed_is_the_committed_block_hash_never_an_input", 'SEED=$(cat "$D/seed.txt")', 'SEED="${{ inputs.seed }}"', "g7-gas-campaign.yml"),
]
# Draws.test_strata_streams: the mutant is one rng per chain, defined before the strata loop
fail = 0
for name, tid, old, new, *tgt in [("",) + m for m in M] + META:
    d = tempfile.mkdtemp()
    for f in ("g7.py", "test_g7.py", "deploy_state.sh", "seed.txt"):
        shutil.copy(os.path.join(SRC, f), d)
    shutil.copy(os.path.join(SRC, "..", "..", ".github", "workflows", "g7-gas-campaign.yml"), d)
    p = os.path.join(d, tgt[0] if tgt else "g7.py"); s = open(p).read()
    if s.count(old) != 1:
        print("BADPAT", tid, s.count(old)); fail += 1; continue
    s = s.replace(old, new)
    if "stratum_rng(seed.lower(), f\"{chain}/{st['id']}\")" not in s and tid.startswith("Draws.test_strata"):
        s = s.replace("    out = []\n    for st in spec[\"chains\"][chain][\"strata\"]:", "    out = []\n    rng = stratum_rng(seed.lower(), chain)\n    for st in spec[\"chains\"][chain][\"strata\"]:")
    open(p, "w").write(s)
    r = subprocess.run([sys.executable, "-I", "-W", "ignore", os.path.join(d, "test_g7.py"), tid], capture_output=True, text=True, timeout=120)
    # Killed only by an assertion: a test that errors (exception, missing name) proves nothing about the guard.
    red = r.returncode != 0 and "AssertionError" in r.stderr and "errors=" not in r.stderr
    tag = "RED " if red else ("CRASH!" if r.returncode else "GREEN!")
    why = [ln for ln in r.stderr.splitlines() if ln[:1].isalpha() and ("Error" in ln or "Exception" in ln)][-1:]
    print(tag + "\t" + (name + "\t" if name else "") + tid + ("" if red or not why else "\t" + why[0][:160]))
    fail += 0 if red else 1
    shutil.rmtree(d)
print("survivors/bad:", fail, "of", len(M) + len(META))
sys.exit(1 if fail else 0)
