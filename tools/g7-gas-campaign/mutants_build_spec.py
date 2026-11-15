#!/usr/bin/env python3
"""Mutation check for test_build_spec.py: each mutant of build_spec.py must turn its named test red.
Run (never in the same command as the suite): python3 -I tools/g7-gas-campaign/mutants_build_spec.py
A 4th tuple field names the mutated file (default build_spec.py). Exit 1 if a mutant survives."""
import os, shutil, subprocess, sys, tempfile
SRC = os.path.dirname(os.path.abspath(__file__))
M = [  # (test id, old, new)
 ("Build.test_venue_key_is_family_shifted_or_liquidity_rank", "vkey = (fn << 16) | slots[fn]", "vkey = (fn << 16)"),
 ("Build.test_slot_follows_measured_liquidity_not_file_order", 'key=lambda r: (r["family"], -(liq(r) or 0),', 'key=lambda r: (r["family"], (liq(r) or 0),'),
 ("Build.test_only_gate_top3_rows_become_wrappers", 'r["family"] in GATE_FAMS and "gate_top3" in classes(r)]', 'r["family"] in GATE_FAMS]'),
 ("Build.test_hint_curve_and_balancer", 'if f in ("curve_ng", "curve_crypto_ng", "balancer_v3"):\n        return word(p), ""', 'if f in ("curve_ng", "curve_crypto_ng", "balancer_v3"):\n        return ZH, ""'),
 ("Build.test_hint_curve_and_balancer", 'return (v.lower(), "") if v else', 'return (word(p), "") if v else'),
 ("Build.test_hint_lb_is_bin_step", "word(hex(int(ts)))", 'word(r["factory"])'),
 ("Build.test_hint_algebra_is_deployer_or_no_hint", 'if d.startswith("0x") else', "if d else"),
 ("Build.test_hint_infinity_is_pool_id", 'if f in ("inf_cl", "inf_bin"):\n        return word(p), ""', 'if f in ("inf_cl", "inf_bin"):\n        return word(pool_addr(p)), ""'),
 ("Build.test_chain_without_gates_is_not_covered_without_a_number", '            notcov.append((chain, "gates", "not covered: no gate-family row in the inventory (absent, not zero)"))\n', "            pass\n"),
 ("Build.test_family_without_adapter_number_is_not_covered", "if fn is None:", "if False:"),
 ("Build.test_adapters_only_for_families_used", "for fn in sorted(fams_used):", "for fn in (1, 2, 3, 4, 5, 6, 7):"),
 ("Build.test_seed_pools_three_deepest_seedable_v4_by_last_20_bytes", "for r in ok[:3]]", "for r in ok[:4]]"),
 ("Build.test_seed_pools_three_deepest_seedable_v4_by_last_20_bytes", 'return p if len(p) == 42 else "0x" + p[-40:]', "return p if len(p) == 42 else p[:42]"),
 ("SeedGuards.test_seed_pools_unit_skips_gate_families", 'SEED_KIND = {"v2": 0,', 'SEED_KIND = {"curve_ng": 9, "v2": 0,'),
 ("SeedGuards.test_build_filters_gate_families_even_if_seedable", 'same = [x for x in by_pair.get(pair(r), []) if x["family"] not in GATE_FAMS]', 'same = by_pair.get(pair(r), [])'),
 ("SeedGuards.test_build_filters_gate_families_even_if_seedable", '"seed_pools": seed_pools([x for x in prs if x["family"] not in GATE_FAMS]),\n                               "mid_pool": mid_pool(prs), "_liq": r.get("liq_usd", "")', '"seed_pools": seed_pools(prs),\n                               "mid_pool": mid_pool(prs), "_liq": r.get("liq_usd", "")'),
 ("SeedGuards.test_site_strata_filter_gate_families_even_if_seedable", '"seed_pools": seed_pools([x for x in prs if x["family"] not in GATE_FAMS]),\n                               "mid_pool": mid_pool(prs), "_liq": deepest.get("liq_usd", "")', '"seed_pools": seed_pools(prs),\n                               "mid_pool": mid_pool(prs), "_liq": deepest.get("liq_usd", "")'),
 ("Build.test_mid_pool_is_deepest_direct", "key=lambda r: -liq(r))\n    if not ok:", "key=lambda r: liq(r))\n    if not ok:"),
 ("Build.test_amounts_increasing_and_positive", "FRACTIONS = [7, 5, 3, 2, 1]", "FRACTIONS = [1, 2, 3, 5, 7]"),
 ("Build.test_amounts_increasing_and_positive", "if a > 0 and a not in out:", "if a not in out:"),
 ("Build.test_swaps_per_chain_sum_to_100", 'st["n"] = n + (1 if j < rem else 0)', 'st["n"] = n'),
 ("Build.test_pair_strata_have_distinct_pairs", "if pk in used or (", "if ("),
 ("Build.test_family_rep_one_per_family", '(cls == "family_rep" and r["family"] in fams)', "False"),
 ("Build.test_shallow_ascending_and_absent_liq_never_chosen", '(lambda r: liq(r)) if cls == "shallow"', '(lambda r: -liq(r)) if cls == "shallow"'),
 ("Build.test_shallow_ascending_and_absent_liq_never_chosen", "    except (TypeError, ValueError):\n        return None", "    except (TypeError, ValueError):\n        return 0.5"),
 ("Build.test_spec_on_disk_matches_and_carries_the_labels", 'label, mh = LABELS.get(chain, (MAIN_LABEL, 2))', 'label, mh = LABELS.get(chain, (MAIN_LABEL, 3))'),
 ("CtorGuard.test_family_without_ctor_source_is_not_covered", "if chain not in PHASE_A_FAMS and (chain, fn) not in ADAPTERS:", "if False:"),
 ("Wiring.test_rebuild_keeps_the_addbridge_rows_of_wiring_tsv", "    wiring += [k for k in kept if len(k) == 3 and k[1] != ADD_FACTORY_SIG]\n", ""),
 ("Wiring.test_rebuild_keeps_the_addbridge_rows_of_wiring_tsv", "k[1] != ADD_FACTORY_SIG]", "True]"),
 ("AddFactory.test_real_uniswap_v3_registration", "(fac, w(1), w(2),", "(fac, w(2), w(1),"),
 ("AddFactory.test_real_uniswap_v3_registration", "d[192:256]", "d[128:192]"),
 ("AddFactory.test_real_uniswap_v3_registration", "i = off // 32", "i = off // 64"),
 ("AddFactory.test_negative_int24_is_signed", "if signed and v >= 1 << 255", "if False and v >= 1 << 255"),
 ("AddFactory.test_other_selector_refused", 'assert d[:8] == ADD_FACTORY_SEL, "not addFactory"', "pass"),
 ("Build.test_prereg_and_spec_are_ascii_english", '.replace(OLD_VIRTUAL_LABEL, NEW_VIRTUAL_LABEL)', ''),
 ("SiteUniverse.test_site_pairs_replace_the_classes_and_keep_the_gates", '    for t in toks:\n        add("site_stable", t, stable)\n', ""),
 ("SiteUniverse.test_site_pairs_replace_the_classes_and_keep_the_gates", 'if t[1] in featured or t[0] in SITE_MAJORS]', 'if t[1] in featured]'),
 ("SiteUniverse.test_pairs_are_deduped_by_address", "if x[1] == y[1] or key in seen:", "if x[1] == y[1]:"),
 ("SiteUniverse.test_site_pair_without_a_pool_is_not_covered", '                    notcov.append((chain, "site", "site pair without a pool in the inventory (absent, not zero): %s/%s" % (sa, sb)))\n', "                    pass\n"),
 ("SiteUniverse.test_amounts_come_from_the_inventory_balance", '"mid_pool": mid_pool(prs), "_liq": deepest.get("liq_usd", "")', '"mid_pool": mid_pool([]), "_liq": deepest.get("liq_usd", "")'),
 ("SiteUniverse.test_chain_outside_the_universe_keeps_the_classes", 'for cls, k in ([] if universe and chain in universe["chains"] else CLASS_QUOTA):', 'for cls, k in ([] if universe else CLASS_QUOTA):'),
 ("SiteUniverse.test_swaps_argument_sets_the_sample_size", "n, rem = divmod(swaps, len(strata))", "n, rem = divmod(SWAPS_PER_CHAIN, len(strata))"),
 ("Build.test_prereg_and_spec_are_ascii_english", '"bsc": ("branch bsc-infinity-1106@7d7e40d, not main', '"bsc": ("branch bsc-infinity-1106@7d7e40d, n\\u00e3o main'),
 ("Parity.test_gate_fams_equal_inventory", '"inf_cl", "inf_bin"}', '"inf_cl"}'),
 ("Criteria.test_spec_criteria_are_the_docstring_section", "x 1e-7 .. 1e-1.", "x 1e-6 .. 1e-1."),
 ("Criteria.test_spec_criteria_are_the_docstring_section", '.split("A chain or")[0].strip(), "chains"', '.split("* amounts")[0].strip(), "chains"'),
 ("AliveAtB0.test_dead_pool_at_b0_is_not_covered_not_a_stratum", 'if live_pass and alive != "1":', "if False:"),
 ("AliveAtB0.test_unmeasured_candidate_is_not_ranked_when_the_pass_ran", 'if live_pass and alive != "1":', 'if live_pass and alive == "0":'),
 ("AliveAtB0.test_chain_without_the_liveness_pass_keeps_the_classes", 'if live_pass and alive != "1":', 'if alive != "1":'),
 ("AliveProbe.test_v2_without_code_at_b0_is_dead", 'return ("0" if c in ("0x", "", None) else "1"), "eth_getCode', 'return "1", "eth_getCode'),
 ("AliveProbe.test_v4_with_slot0_zero_at_b0_is_dead", 'ok = int(s0[2:66] or "0", 16) != 0', "ok = True"),
 ("AliveProbe.test_v4_token_without_code_at_b0_is_dead", "if ok and t != Z:", "if False:"),
 ("AliveProbe.test_v4_reads_the_pools_slot_of_the_pool_manager", "w(V4_POOLS_SLOT)", "w(0)", "inventory.py"),
 ("ActiveAtB0.test_pool_without_liquidity_in_range_is_not_covered_not_a_stratum", 'if active_pass and r["family"] in ACTIVE_FAMS and active != "1":', "if False:"),
 ("ActiveAtB0.test_pool_without_liquidity_in_range_is_not_covered_not_a_stratum", 'if active_pass and r["family"] in ACTIVE_FAMS and active != "1":', 'if active_pass and active != "1":'),
 ("ActiveAtB0.test_unmeasured_liquidity_in_range_is_not_ranked_when_the_pass_ran", 'if active_pass and r["family"] in ACTIVE_FAMS and active != "1":', 'if active_pass and r["family"] in ACTIVE_FAMS and active == "0":'),
 ("ActiveAtB0.test_chain_without_the_active_pass_keeps_the_classes", 'if active_pass and r["family"] in ACTIVE_FAMS and active != "1":', 'if r["family"] in ACTIVE_FAMS and active != "1":'),
 ("ActiveProbe.test_v3_reads_liquidity_of_the_pool", 'inv.SEL["liquidity"][2:]', 'inv.SEL["slot0"][2:]'),
 ("ActiveProbe.test_v3_reads_liquidity_of_the_pool", 'return ("1" if L > 0 else "0"), src', 'return ("1" if L >= 0 else "0"), src'),
 ("ActiveProbe.test_v4_reads_the_liquidity_word_not_slot0", "inv.v4_state_slot(p) + inv.V4_LIQ_OFFSET", "inv.v4_state_slot(p)"),
]
fail = 0
for tid, old, new, *tgt in M:
    d = tempfile.mkdtemp()
    os.mkdir(os.path.join(d, "site"))
    for f in ("build_spec.py", "test_build_spec.py", "inventory.py", "g7.py", "spec.json", os.path.join("site", "spec.json")):
        shutil.copy(os.path.join(SRC, f), os.path.join(d, f))
    p = os.path.join(d, tgt[0] if tgt else "build_spec.py"); s = open(p).read()
    if s.count(old) != 1:
        print("BADPAT", tid, s.count(old)); fail += 1; continue
    open(p, "w").write(s.replace(old, new))
    r = subprocess.run([sys.executable, "-I", "-W", "ignore", os.path.join(d, "test_build_spec.py"), tid], capture_output=True, text=True, timeout=120)
    # Killed only by an assertion: a test that errors (exception, missing name) proves nothing about the guard.
    red = r.returncode != 0 and "AssertionError" in r.stderr and "errors=" not in r.stderr
    tag = "RED " if red else ("CRASH!" if r.returncode else "GREEN!")
    why = [ln for ln in r.stderr.splitlines() if ln[:1].isalpha() and ("Error" in ln or "Exception" in ln)][-1:]
    print(tag + "\t" + tid + ("" if red or not why else "\t" + why[0][:160]))
    fail += 0 if red else 1
    shutil.rmtree(d)
print("survivors/bad:", fail, "of", len(M))
sys.exit(1 if fail else 0)
