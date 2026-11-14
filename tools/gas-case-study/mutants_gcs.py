#!/usr/bin/env python3
"""Mutation check for test_gcs.py: each mutant must turn its named test red, by an assertion.
Run: python3 -I tools/gas-case-study/mutants_gcs.py (exit 1 if a mutant survives).
Tuples are (test id, old, new, file). Every mutant is applied to a COPY of the modules in a fresh
temporary directory (TMPDIR decides where), never in place; the sources are snapshotted once at start.
The suite must be green first: a red suite stops the run before any mutant."""
import os, shutil, subprocess, sys, tempfile
SRC = os.path.dirname(os.path.abspath(__file__))
TOOLS = os.path.dirname(SRC)
FILES = [("gas-case-study", f) for f in ("abi.py", "stats.py", "harness.py", "test_gcs.py")] + \
        [("g7-gas-campaign", "g7.py"), ("fuzz-coverage", "prereg.py")]
M = [  # (test id, old, new, file)
 # stats.py
 ("Wilson.test_zero_successes_lo_is_exactly_zero", "lo = 0.0 if k == 0 else max(0.0, mid - half)", "lo = max(0.0, mid - half)", "stats.py"),
 ("Wilson.test_all_successes_hi_is_exactly_one", "hi = 1.0 if k == n else min(1.0, mid + half)", "hi = min(1.0, mid + half)", "stats.py"),
 ("Wilson.test_n_zero_is_absent_not_zero", "    if n <= 0:\n        return None\n    if not", "    if n <= 0:\n        return 0.0, 0.0\n    if not", "stats.py"),
 ("Wilson.test_reference_values_newcombe_1998", "z2 / (4 * n * n)", "z2 / (4 * n)", "stats.py"),
 ("Wilson.test_k_outside_0_n_is_refused", "if not 0 <= k <= n:", "if not 0 <= k:", "stats.py"),
 ("Bootstrap.test_same_seed_same_interval_other_seed_differs", "rng = random.Random(seed)", "rng = random.Random()", "stats.py"),
 ("Bootstrap.test_covers_a_known_median", "for _ in range(n)]) for _ in range(b)", "for _ in range(4 * n)]) for _ in range(b)", "stats.py"),
 ("Bootstrap.test_ends_are_the_two_tails", "pct(reps, 100 * (1 - alpha / 2))", "pct(reps, 100 * alpha / 2)", "stats.py"),
 ("Bootstrap.test_empty_is_absent_not_zero", "    if not vals:\n        return None\n    rng", "    if not vals:\n        return 0, 0\n    rng", "stats.py"),
 ("Bootstrap.test_seed_default_is_sha256_of_the_tag_and_const_is_mod_2_32", "return int(const, 0) % (1 << 32)", "return int(const, 0) % (1 << 31)", "stats.py"),
 ("Reduce.test_prefix_keeps_i_below_nprime", "if int(r[key]) < nprime]", "if int(r[key]) <= nprime]", "stats.py"),
 ("Reduce.test_other_nprime_is_refused", "NPRIMES = (8, 4, 2, 1)", "NPRIMES = (8, 4, 3, 2, 1)", "stats.py"),
 ("Reduce.test_cell_index_from_the_cell_id_tail", 'tail = r["cell_id"].rsplit("-", 1)[-1]', 'tail = r["cell_id"].rsplit("-", 1)[0]', "stats.py"),
 ("Paired.test_b_minus_a_per_cell", "num(b[metric]) - num(a[metric])", "num(a[metric]) - num(b[metric])", "stats.py"),
 ("Paired.test_pairs_by_cell_and_temperature", 'by.setdefault((r["cell_id"], r["temp"]), {})', 'by.setdefault((r["cell_id"], "cold"), {})', "stats.py"),
 ("Paired.test_unpaired_or_not_ok_are_dropped_and_counted", 'if a and b and a["status"] == "ok" and b["status"] == "ok" and', "if a and b and", "stats.py"),
 ("Run.test_revert_rate_counts_reverts_only_and_absent_metric_is_empty", 'r["status"].startswith("revert") for r in rs', 'r["status"] != "ok" for r in rs', "stats.py"),
 # abi.py
 ("Keccak.test_empty_string", 'bytearray(data) + b"\\x01" + b"\\x00"', 'bytearray(data) + b"\\x06" + b"\\x00"', "abi.py"),
 ("Keccak.test_rate_edges_135_136_271_272", 'p = bytearray(data) + b"\\x81"', 'p = bytearray(data) + b"\\x01\\x80"', "abi.py"),
 ("Keccak.test_public_selector_transfer", "return keccak256(sig.encode()).hex()[:8]", "return keccak256(sig.encode()).hex()[-8:]", "abi.py"),
 ("Keccak.test_calldata_is_selector_then_words", 's = selector[2:] if selector.startswith("0x") else selector', "s = selector", "abi.py"),
 ("Codec.test_leg_field_order_against_hand_encoded_words", '("hooks", "address"), ("kind", "uint8"), ("fee", "uint24"),', '("hooks", "address"), ("fee", "uint24"), ("kind", "uint8"),', "abi.py"),
 ("Codec.test_hop_offsets_against_hand_encoding", "    if _dynamic(t):\n        return 1\n    if isinstance(t, str):", "    if _dynamic(t):\n        return 2\n    if isinstance(t, str):", "abi.py"),
 ("Codec.test_roundtrip_preview_plan_out", 'heads.append(format(head_len + sum(len(x) // 2 for x in tails), "064x"))', 'heads.append(format(head_len, "064x"))', "abi.py"),
 ("Codec.test_uint256_range_is_refused", "if not 0 <= v < (1 << 256):", "if not 0 <= v <= (1 << 256):", "abi.py"),
 ("Codec.test_signed_decode_at_the_sign_bit", "return v - (1 << bits) if v >> (bits - 1) else v", "return v - (1 << bits) if v >> bits else v", "abi.py"),
 ("Codec.test_bytes_length_and_padding", '"0" * ((64 - len(h) % 64) % 64)', '"0" * (64 - len(h) % 64)', "abi.py"),
 # harness.py
 ("Selectors.test_selectors_against_cast_sig", 'return "(" + ",".join(canon(ft) for _, ft in t[1]) + ")"', 'return "(" + ", ".join(canon(ft) for _, ft in t[1]) + ")"', "harness.py"),
 ("Selectors.test_err_class", '{5: "minOut", 4: "deadline"}', '{4: "minOut", 5: "deadline"}', "harness.py"),
 ("Shapes.test_forced_shapes_and_their_edges", "return (legs, 0) if 1 <= legs <= MAX_LEGS_PER_HOP else None", "return (legs, 0) if 1 <= legs <= MAX_LEGS_PER_HOP + 1 else None", "harness.py"),
 ("Shapes.test_split_sums_to_the_amount", "return [q] * (n - 1) + [amount - q * (n - 1)]", "return [q] * n", "harness.py"),
 ("Prereg.test_bad_lock_is_refused", "if errs and not allow_unlocked:", "if False:", "harness.py"),
 ("Prereg.test_tsv_with_a_header", 'if lines and lines[0][1].split("\\t")[0] == "chain":', "if False:", "harness.py"),
 ("Prereg.test_tagged_rows_follow_cols", "                cols = f[1:]\n", "                pass\n", "harness.py"),
 ("Prereg.test_amount_in_must_be_a_positive_integer_in_wei", 'int(r["amount_in"]) == 0:', 'int(r["amount_in"]) < 0:', "harness.py"),
 ("Prereg.test_i_is_the_ordinal_within_chain_pair_size", 'k = (r["chain"], r.get("pair", ""), r.get("size_usd", ""), r.get("age_s_target", ""))', 'k = (r["chain"],)', "harness.py"),
 ("Prereg.test_two_fork_blocks_are_refused", "if len(bs) != 1:", "if len(bs) > 2:", "harness.py"),
 ("Guards.test_quote_takes_pv_route_the_first_return_value", "        return out[0], None", '        return dict(out[0], route=out[1]), None', "harness.py"),
 ("Guards.test_quote_revert_is_classified_not_zero", "            return None, err_class(e.data)\n        return out[0], None", '            return None, ""\n        return out[0], None', "harness.py"),
 ("Guards.test_quoted_sends_pv_route_and_effective_min_out", 'data = cd("swapExactIn", r, amt, pv["effectiveMinOut"], self.user, self.deadline)', 'data = cd("swapExactIn", r, amt, 1, self.user, self.deadline)', "harness.py"),
 ("Guards.test_out_ours_is_the_balance_delta_not_the_quote", "out = self.balance(tout) - b0  # I2", "out = self.balance(tout)  # I2", "harness.py"),
 ("Guards.test_cannot_execute_is_noroute_and_nothing_is_sent", 'if not pv["canExecute"] or not pv["route"]["hops"]:', 'if not pv["route"]["hops"]:', "harness.py"),
 ("Guards.test_forced_shape_absent_by_code_is_a_reason_not_a_row", '                return self._absent(cell, mode, "absent_by_code")\n        base, _', "                return [], []\n        base, _", "harness.py"),
 ("Guards.test_topology_is_the_bridge_slot_or_absent", "                return 1 + i\n        return \"\"", "                return 1 + i\n        return 0", "harness.py"),
 ("Guards.test_refused_evm_revert_raises", 'if self.node.call("evm_revert", [snap]) is not True:', 'if self.node.call("evm_revert", [snap]) is None:', "harness.py"),
 ("Guards.test_best_single_out_is_gross_of_the_28_bps_fee", "got * 10000 // (10000 - PROTOCOL_FEE_BPS)", "got * 10000 // (10000 + PROTOCOL_FEE_BPS)", "harness.py"),
]
# Codec.test_narrow_types_out_of_range_are_refused is an expectedFailure (abi.py has no narrow-range
# guard yet): it has no mutant until the guard exists.


def tree(root):
    for sub, f in FILES:
        os.makedirs(os.path.join(root, sub), exist_ok=True)
        shutil.copy(os.path.join(TOOLS, sub, f), os.path.join(root, sub, f))


def run(root, tid=None):
    cmd = [sys.executable, "-I", "-W", "ignore", os.path.join(root, "gas-case-study", "test_gcs.py")] + ([tid] if tid else [])
    return subprocess.run(cmd, capture_output=True, text=True, timeout=300)


base = tempfile.mkdtemp(prefix="gcs-base-")
tree(base)
r = run(base)
if r.returncode:
    print("suite red before the mutants:\n" + r.stderr[-2000:])
    sys.exit(2)
print("suite green:", r.stderr.strip().splitlines()[-1])
fail = 0
for tid, old, new, f in M:
    d = tempfile.mkdtemp(prefix="gcs-mut-")
    shutil.copytree(base, d, dirs_exist_ok=True)
    p = os.path.join(d, "gas-case-study", f)
    s = open(p).read()
    if s.count(old) != 1:
        print("BADPAT\t" + tid + "\t" + str(s.count(old))); fail += 1; shutil.rmtree(d); continue
    open(p, "w").write(s.replace(old, new))
    r = run(d, tid)
    # Killed only by an assertion: a test that errors (exception, missing name) proves nothing about the guard.
    red = r.returncode != 0 and "AssertionError" in r.stderr and "errors=" not in r.stderr
    tag = "RED " if red else ("CRASH!" if r.returncode else "GREEN!")
    why = [ln for ln in r.stderr.splitlines() if ln[:1].isalpha() and ("Error" in ln or "Exception" in ln)][-1:]
    print(tag + "\t" + tid + ("" if red or not why else "\t" + why[0][:160]))
    fail += 0 if red else 1
    shutil.rmtree(d)
shutil.rmtree(base)
print("survivors/bad:", fail, "of", len(M))
sys.exit(1 if fail else 0)
