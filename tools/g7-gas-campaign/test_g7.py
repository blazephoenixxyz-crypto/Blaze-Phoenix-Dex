#!/usr/bin/env python3
"""Offline tests for g7.py (no RPC, no key). Run: python3 -I tools/g7-gas-campaign/test_g7.py

Each test names the mutant of g7.py that turns it red; mutants_g7.py applies every one of them
and checks that its test goes red (25/25 on 2026-11-13).
"""
import os
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import g7  # noqa: E402

A1 = "0x" + "11" * 20
A2 = "0x" + "22" * 20
ROUTER = "0x" + "aa" * 20
POOL1 = "0x" + "b1" * 20
POOL2 = "0x" + "b2" * 20
WRAP = "0x" + "c1" * 20
TOKEN = "0x" + "d1" * 20
SOLVER = "0x" + "e1" * 20
HUB = "0x" + "e2" * 20
GATE = "0x" + "e3" * 20


def wd(x):
    return format(x, "064x")


def fr(to, sel, gas, calls=None):
    return {"to": to, "input": "0x" + sel + "00" * 4, "gasUsed": hex(gas), "calls": calls or []}


class FirstAtOrAfter(unittest.TestCase):
    # Mutant: `ts(mid) >= t` -> `ts(mid) > t` (an exact hit is skipped by one block).
    def test_exact_timestamp_is_the_block_itself(self):
        ts = lambda n: 100 + 2 * n  # noqa: E731
        self.assertEqual(g7.first_at_or_after(ts, 150, 0, 40), 25)

    # Mutant: drop the `while ts(hi) < t` growth loop (hi stays below the answer).
    def test_hi_grows_past_a_short_initial_bracket(self):
        ts = lambda n: 2 * n  # noqa: E731
        self.assertEqual(g7.first_at_or_after(ts, 1000, 0, 10), 500)

    # Mutant: return lo instead of hi (a gap in timestamps: no block has ts == t).
    def test_gap_returns_the_first_block_after(self):
        ts = lambda n: 10 * n  # noqa: E731
        self.assertEqual(g7.first_at_or_after(ts, 55, 0, 100), 6)


class Abi(unittest.TestCase):
    def preview_blob(self, call_hex, can=1):
        # (Preview pv, bytes call); Preview is dynamic (Route has Hop[]), so its head word 0 is the
        # route offset and the scalars follow in declaration order (BlazePhoenixQuoter.sol:186).
        fields = [0x1C0, 111, 2, 3, 444, 5, 6, 777, 888, 2, 7, 1, int(A1, 16), can]
        pv = "".join(wd(x) for x in fields)
        route = wd(0) * 9  # an empty route body, enough bytes for the offset to land inside
        pv_off, call_off = 0x40, 0x40 + len(pv + route) // 2
        n = len(call_hex) // 2
        tail = wd(n) + call_hex + "0" * ((64 - len(call_hex) % 64) % 64)
        return "0x" + wd(pv_off) + wd(call_off) + pv + route + tail

    # Mutant: f(8) (estGas) and f(9) (hops) swapped, or netOut read at f(1) (grossOut).
    def test_decode_preview_fields_by_declaration_order(self):
        p = g7.decode_preview(self.preview_blob("deadbeef01"))
        self.assertEqual((p["netOut"], p["effectiveMinOut"], p["estGas"], p["hops"], p["legs"]),
                         (444, 777, 888, 2, 7))
        self.assertTrue(p["canExecute"])
        self.assertEqual(p["call"], "deadbeef01")

    # Mutant: canExecute read as `f(12) != 0` (word 12 is bridgeUsed, non-zero).
    def test_decode_preview_can_execute_false(self):
        self.assertFalse(g7.decode_preview(self.preview_blob("", can=0))["canExecute"])

    # Mutant: heads start at 32 * (n + 1) (offset counted from the length word), or the
    # target/array head order swapped. Expected bytes written from the ABI spec by hand.
    def test_encode_batch_matches_hand_encoding(self):
        got = g7.encode_batch(A1, ["aabb"])
        want = ("0xb9d096b2" + wd(int(A1, 16)) + wd(0x40) + wd(1) + wd(0x20) + wd(2) + "aabb" + "0" * 60)
        self.assertEqual(got, want)

    # Mutant: `off += len(t) // 2` replaced by `off += 32` (second head wrong when call 1 > 0 bytes).
    def test_encode_batch_second_head_skips_first_tail(self):
        got = g7.strip0x(g7.encode_batch(A1, ["aa" * 40, "bb"]))[8:]
        words = [int(got[i:i + 64], 16) for i in range(0, len(got), 64)]
        # words: target, 0x40, n=2, head0, head1, len0, 2 words of call0, len1, call1
        self.assertEqual(words[3], 0x40)
        self.assertEqual(words[4], 0x40 + 32 + 64)
        self.assertEqual(words[5], 40)
        self.assertEqual(words[8], 1)

    # Mutant: tokens = z + nz (EIP-7623 counts 4 per non-zero byte), or 16/4 swapped.
    def test_calldata_cost_and_7623_floor(self):
        self.assertEqual(g7.calldata_cost("0x0001ff"), (3, 1, 4 + 2 * 16, 21000 + 10 * (1 + 4 * 2)))
        self.assertEqual(g7.calldata_cost("0x"), (0, 0, 0, 21000))

    # Mutant: `<=` -> `<` on either bound.
    def test_fits_2_10_boundaries(self):
        self.assertEqual(g7.fits(2, 10), 1)
        self.assertEqual(g7.fits(3, 10), 0)
        self.assertEqual(g7.fits(2, 11), 0)
        self.assertEqual(g7.fits(1, 1), 1)


def disc(ta, tb, gas):
    """A Hub.discoverFor(tA, tB) frame."""
    return {"to": HUB, "input": "0x" + g7.SEL["discover"] + g7.addr(ta) + g7.addr(tb), "gasUsed": hex(gas), "calls": []}


class Segments(unittest.TestCase):
    def quote_trace(self, discover=True, bridge=False):
        inner = [fr(GATE, g7.SEL["wrappers"], 50, [fr(WRAP, "c0ffee00", 20)]), fr(WRAP, "c0ffee00", 30)]
        if discover:
            inner.insert(0, disc(A2, A1, 300))  # the measured pair, in the Solver's (sorted) order
        if bridge:
            inner.insert(0, disc(A1, TOKEN, 150))  # a 2-hop bridge leg: never seeded
        return fr("0xq", g7.SEL["preview"], 1000, [fr(SOLVER, g7.SEL["solve"], 800, inner)])

    # Mutant: `seg["swept"] = 1` deleted, or the discover selector check dropped.
    def test_discover_frame_means_swept(self):
        s = g7.quote_segments(self.quote_trace(True), SOLVER, HUB, GATE, [WRAP], (A1, A2))
        self.assertEqual((s["swept"], s["g_discovery"], s["g_discovery_bridge"], s["g_solve"], s["g_quote"]),
                         (1, 300, 0, 800, 1000))
        s = g7.quote_segments(self.quote_trace(False), SOLVER, HUB, GATE, [WRAP], (A1, A2))
        self.assertEqual((s["swept"], s["g_discovery"]), (0, 0))

    # Run 43364491522, optimism major-5 idx3 M0: the seeded direct pair is fresh (its frame is gone)
    # but the bridge pairs still sweep; counting those as `swept` made every MF row mf_unforced.
    # Mutant: the pair test dropped (`set(frame_pair(n)) == want` -> True), or the bridge gas not added.
    def test_bridge_sweep_is_not_swept(self):
        s = g7.quote_segments(self.quote_trace(False, True), SOLVER, HUB, GATE, [WRAP], (A1, A2))
        self.assertEqual((s["swept"], s["g_discovery"], s["g_discovery_bridge"]), (0, 150, 150))
        s = g7.quote_segments(self.quote_trace(True, True), SOLVER, HUB, GATE, [WRAP], (A2, A1))
        self.assertEqual((s["swept"], s["g_discovery"], s["g_discovery_bridge"]), (1, 450, 150))

    # Mutant: `and id(p) not in gated` dropped (the wrapper nested in the Gate counted twice: 100).
    def test_gates_count_top_most_frames_once(self):
        s = g7.quote_segments(self.quote_trace(), SOLVER, HUB, GATE, [WRAP], (A1, A2))
        self.assertEqual(s["g_gates"], 80)

    def exec_trace(self):
        v3_leg = fr(WRAP, g7.SEL["v3swap"], 200, [
            fr(POOL1, g7.SEL["v3swap"], 120, [fr(TOKEN, g7.SEL["transfer"], 9)]),  # nested: not a leg
            fr(ROUTER, "fa461e33", 60, [fr(TOKEN, g7.SEL["transfer"], 30)]),  # callback payment
        ])
        router = fr(ROUTER, "c0ffee00", 500, [
            fr(POOL2, g7.SEL["v2swap"], 100),
            v3_leg,
            fr(TOKEN, g7.SEL["transfer"], 25),  # the sweep
        ])
        return fr("0xprobe", g7.SEL["run"], 600, [router])

    # Mutant: leg_end = i (subtree ignored): the callback transfer is counted as sweep (55).
    def test_sweep_excludes_callback_payments_inside_a_leg(self):
        self.assertEqual(g7.exec_segments(self.exec_trace(), ROUTER)["g_sweep"], 25)

    # Mutant: `and i > leg_end` dropped from the leg test (the pool under the wrapper is a 3rd leg).
    def test_nested_swap_is_not_a_second_leg(self):
        e = g7.exec_segments(self.exec_trace(), ROUTER)
        self.assertEqual(e["legs_detail"], f"{POOL2}:100;{WRAP}:200")
        self.assertEqual(e["g_legs_sum"], 300)

    # Mutants: `inside and` dropped (the Probe's own recordSwap call counts: 77), or the selector
    # check dropped (the Hub read under the Router counts: 75).
    def test_record_is_hub_recordswap_under_the_router_only(self):
        router = fr(ROUTER, "c0ffee00", 500, [
            fr(POOL2, g7.SEL["v2swap"], 100), fr(HUB, "e9008d5b", 5), fr(TOKEN, g7.SEL["transfer"], 25),
            fr(HUB, g7.SEL["record"], 70),
        ])
        t = fr("0xprobe", g7.SEL["run"], 700, [fr(HUB, g7.SEL["record"], 7), router])
        e = g7.exec_segments(t, ROUTER, HUB)
        self.assertEqual((e["g_record"], e["g_exec"], e["g_sweep"]), (70, 500, 25))
        self.assertEqual(g7.exec_segments(t, ROUTER)["g_record"], 0)

    # Mutant: Router gas summed over every Router frame (the callback adds 60: 560).
    def test_router_gas_is_top_most_frames_only(self):
        self.assertEqual(g7.exec_segments(self.exec_trace(), ROUTER)["g_exec"], 500)


class Stamp(unittest.TestCase):
    # Mutant: `rep` replaced by `pat` (no rewrite), or `i = b.find(pat, i + width)` replaced by -1.
    def test_rewrites_every_packed_occurrence(self):
        old, new = 1793500000, 1793503600
        v = "00" * 3 + old.to_bytes(5, "big").hex() + "ff" * 8 + old.to_bytes(5, "big").hex() + "00" * 11
        out, hits = g7.rewrite_stamp({"0x01": "0x" + v, "0x02": "0x" + "ab" * 32}, old, new)
        self.assertEqual(hits, 2)
        self.assertEqual(out["0x01"], "0x" + v.replace(old.to_bytes(5, "big").hex(), new.to_bytes(5, "big").hex()))
        self.assertEqual(out["0x02"], "0x" + "ab" * 32)

    # Mutant: a word with no match still adds to hits (`if True: hits += here + 1`).
    def test_absent_stamp_gives_zero_hits(self):
        _, hits = g7.rewrite_stamp({"0x01": "0x" + "00" * 32}, 1793500000, 1793503600)
        self.assertEqual(hits, 0)


SPEC = {
    "deadline_s": 600, "ages": {"M0": 0, "M1h": 3600}, "mf_ages": ["M1h"],
    "retries": {"attempts": 1, "backoff_s": 0, "timeout_s": 1},
    "chains": {"base": {"label": "2e4fdaa (selar), not main", "max_hops": 2, "native_wrap": A1, "block_time_hint": 2, "strata": [
        {"id": "s1", "kind": "pairs", "tA": A1, "tB": A2, "n": 20, "amounts": {"A": [1, 2, 3], "B": [7, 8]},
         "seed_pools": []},
        {"id": "s2", "kind": "gates", "tA": A2, "tB": A1, "n": 5, "amounts": {"A": [10], "B": [20]}, "seed_pools": []},
    ]}},
}


class Draws(unittest.TestCase):
    # Mutant: rng seeded without the seed (or with time): the two seeds give the same draws.
    def test_deterministic_per_seed_and_distinct_across_seeds(self):
        a = g7.draws(SPEC, "ab12", "base", 1000, 2000)
        b = g7.draws(SPEC, "AB12".lower(), "base", 1000, 2000)
        c = g7.draws(SPEC, "ab13", "base", 1000, 2000)
        strip = lambda ds: [(d["stratum"], d["b"], d["tin"], d["amount"]) for d in ds]  # noqa: E731
        self.assertEqual(strip(a), strip(b))
        self.assertNotEqual(strip(a), strip(c))

    # Mutant: amounts drawn from the "A" list in both directions, or b outside [b0, b1].
    def test_ranges_counts_and_direction_amounts(self):
        ds = g7.draws(SPEC, "ab12", "base", 1000, 2000)
        self.assertEqual(len(ds), 25)
        self.assertEqual([d["idx"] for d in ds if d["stratum"] == "s2"], [1, 2, 3, 4, 5])
        for d in ds:
            self.assertTrue(1000 <= d["b"] <= 2000)
            st = d["st"]
            self.assertIn(d["amount"], st["amounts"]["A" if d["tin"] == st["tA"] else "B"])

    # Run 43364491522: V4-native strata (tA or tB = address(0)) all died in SolverE(4) at the Solver
    # door, which takes WETH for native (Core.nativeMapVerified). Mutant: the sentinel not translated.
    def test_native_sentinel_is_drawn_as_the_wrapped_token(self):
        z = "0x" + "00" * 20
        st = {**SPEC["chains"]["base"]["strata"][0], "tA": z}
        spec2 = {**SPEC, "chains": {"base": {**SPEC["chains"]["base"], "strata": [st]}}}
        ds = g7.draws(spec2, "ab12", "base", 1000, 2000)
        self.assertTrue(all(z not in (d["tin"], d["tout"]) for d in ds))
        self.assertEqual({d["tin"] for d in ds} | {d["tout"] for d in ds}, {A1, A2})
        self.assertEqual(st["tA"], z)  # the stratum (seedPool's key) keeps the pool's own currency

    # Mutant: one rng for the whole chain (adding a stratum would shift the draws of the others).
    def test_strata_streams_are_independent(self):
        spec2 = {**SPEC, "chains": {"base": {**SPEC["chains"]["base"],
                                             "strata": SPEC["chains"]["base"]["strata"][1:]}}}
        a = [d["b"] for d in g7.draws(SPEC, "ab12", "base", 1000, 2000) if d["stratum"] == "s2"]
        b = [d["b"] for d in g7.draws(spec2, "ab12", "base", 1000, 2000)]
        self.assertEqual(a, b)


class FakeRpc:
    def __init__(self, tsb):
        self.tsb = tsb

    def ts(self, n):
        return self.tsb


class FakeChain:
    def __init__(self, tsb, state_ts):
        self.name, self.spec, self.label, self.state_ts = "base", SPEC, SPEC["chains"]["base"]["label"], state_ts
        self.max_hops = 2
        self.c = SPEC["chains"]["base"]
        self.rpc = FakeRpc(tsb)


def draw():
    st = SPEC["chains"]["base"]["strata"][0]
    return {"stratum": "s1", "kind": "pairs", "idx": 3, "b": 500, "tin": A1, "tout": A2, "amount": 2, "st": st}


class MeasureDraw(unittest.TestCase):
    TSB = 1793500000

    def run_draw(self, state_ts, seed_ret, mm, done=None):
        calls = {"seed": 0, "mm": []}

        def seed(ch, d, age, ts_b):
            calls["seed"] += 1
            return seed_ret(age)

        def measure(ch, d, ts_b, m, hub_state):
            calls["mm"].append((m, hub_state))
            return mm(m)

        with mock.patch.object(g7, "seed_memory", seed), mock.patch.object(g7, "measure_mode", measure), \
                mock.patch.object(g7, "mid_price", lambda ch, d: ""), mock.patch.object(g7, "vital", lambda ch, d: {}):
            rows = g7.measure_draw(FakeChain(self.TSB, state_ts), draw(), done or {})
        return {r["mode"]: r for r in rows}, calls

    def ok(self, swept=0, net=1000):
        return lambda m: {"outcome": "ok", "swept": swept, "net_out": net, "delivered": net}

    # Mutant: `ts_b - age <= ch.state_ts` -> `<` (the equality case is seeded at or before the state).
    def test_prereq_refuses_ts_b_minus_age_at_or_before_state_ts(self):
        seeded = lambda age: (400, self.TSB - age, {}, {"0x1": "0x" + wd(self.TSB - age)}, [True, False])  # noqa: E731
        rows, calls = self.run_draw(self.TSB - 3600, seeded, self.ok())
        self.assertEqual(rows["M1h"]["outcome"], "prereq")
        self.assertEqual(rows["MF1h"]["outcome"], "prereq")
        self.assertEqual(rows["M0"]["outcome"], "ok")
        self.assertEqual(calls["seed"], 1)  # only M0 was seeded

    # Mutant: `if not hits:` -> `if False:` (an MF row measured without its forced stamp).
    def test_mf_without_stamp_is_mf_unforced(self):
        seeded = lambda age: (400, self.TSB - age, {}, {"0x1": "0x" + wd(5)}, [True, False])  # noqa: E731
        rows, _ = self.run_draw(0, seeded, self.ok())
        self.assertEqual((rows["MF1h"]["outcome"], rows["MF1h"]["detail"]), ("mf_unforced", "stamp not found"))
        self.assertEqual(rows["M1h"]["outcome"], "ok")
        # a refused seedPool (G7Probe.batch swallows it) is visible in the row, not silent
        self.assertEqual((rows["MF1h"]["seeds_ok"], rows["MF1h"]["seeds_n"]), (1, 2))

    # Mutant: the swept check after measure_mode removed (a forced row that swept counts as moonslot).
    def test_mf_that_still_sweeps_is_mf_unforced(self):
        seeded = lambda age: (400, self.TSB - age, {}, {"0x1": "0x" + wd(self.TSB - age)}, [True, False])  # noqa: E731
        rows, calls = self.run_draw(0, seeded, self.ok(swept=1))
        self.assertEqual(rows["MF1h"]["outcome"], "mf_unforced")
        self.assertEqual(rows["M1h"]["outcome"], "ok")  # natural mode: sweeping is a legal result
        hub = dict(calls["mm"])["MF1h"]
        self.assertEqual(hub["0x1"], "0x" + wd(self.TSB))  # the stamp was rewritten to ts(b)

    # Mutant: out_vs_D_bps against the mode's own output, or the D reference not taken from `done`.
    def test_resume_skips_done_rows_and_keeps_the_D_reference(self):
        seeded = lambda age: (400, self.TSB - age, {}, {"0x1": "0x" + wd(self.TSB - age)}, [True, False])  # noqa: E731
        done = {("base", "s1", "3", "D"): {"outcome": "ok", "net_out": "1000"}}
        rows, calls = self.run_draw(0, seeded, self.ok(net=1010), done)
        self.assertNotIn("D", rows)
        self.assertNotIn("D", [m for m, _ in calls["mm"]])
        self.assertEqual(rows["M0"]["out_vs_D_bps"], 100.0)


class QuoteRow(unittest.TestCase):
    """measure_mode up to a reverted quote (no exec): segments on the drawn pair, revert data kept."""
    def chain(self, trace):
        ch = mock.Mock()
        ch.solver, ch.hub, ch.gate, ch.wrappers, ch.quoter, ch.probe, ch.spec = SOLVER, HUB, GATE, [WRAP], ROUTER, TOKEN, SPEC
        ch.override.return_value = {}
        ch.rpc.call.return_value = trace
        return ch

    # Mutant: the pair passed to quote_segments is not (tin, tout); or the detail drops the revert data
    # (SolverE(5) = no route vs SolverE(4) = bad parameters were indistinguishable in run 43364491522).
    def test_noquote_keeps_the_solver_error_and_the_pair(self):
        tr = fr("0xq", g7.SEL["preview"], 1000, [fr(SOLVER, g7.SEL["solve"], 800, [disc(A1, A2, 300)])])
        tr.update(error="execution reverted", output="0x3d0ccdde" + wd(5))
        r = g7.measure_mode(self.chain(tr), draw(), 1, "D", None)
        self.assertEqual(r["outcome"], "noquote")
        self.assertEqual(r["detail"], "quote:execution reverted:0x3d0ccdde" + wd(5))
        self.assertEqual(r["swept"], 1)


class BalanceSlot(unittest.TestCase):
    """sUSD (optimism shallow-1, run 43364491522): the token is a proxy, the balance lives in a
    TokenState contract; overriding the proxy's target slot makes balanceOf revert."""
    TOK, STATE, V = "0x" + "5a" * 20, "0x" + "5b" * 20, 987654321987654321

    def chain(self):
        tok, state, v = self.TOK, self.STATE, self.V

        class R:
            def call(self, method, params):
                if method == "debug_traceCall":
                    return {tok: {"storage": {"0x02": "0x" + wd(1)}}, state: {"storage": {"0x99": "0x0"}}}
                (acct, o), = params[2].items()
                if acct == tok:
                    raise g7.Reverted(None)
                return "0x" + wd(v if "0x99" in o["stateDiff"] else 0)
        ch = g7.Chain.__new__(g7.Chain)
        ch.probe, ch.slots, ch.lock, ch.rpc = TOKEN, {}, __import__("threading").Lock(), R()
        ch.base = {TOKEN: {"code": "0x00"}}
        return ch

    # Mutants: `except Reverted: continue` dropped (the revert escapes), or only the token's own
    # account searched (`if acct.lower() != token: continue` restored: slot not found).
    def test_balance_in_another_account_is_found_past_a_reverting_slot(self):
        ch = self.chain()
        self.assertEqual(ch.balance_slot(self.TOK, 10), (self.STATE, "0x99"))

    # Mutant: override() funds the token instead of the holder account it is given.
    def test_override_funds_the_holder_account(self):
        o = self.chain().override(fund={self.STATE: ("0x99", 5)})
        self.assertEqual(o[self.STATE]["stateDiff"]["0x99"], "0x" + wd(5))
        self.assertNotIn(self.TOK, o)


class SeedOks(unittest.TestCase):
    # Mutant: the length word off by one (a refused last seed vanishes) or `== 1` -> `!= 0` on a dirty word.
    def test_decode_bools(self):
        self.assertEqual(g7.decode_bools("0x" + wd(32) + wd(3) + wd(1) + wd(0) + wd(1)), [True, False, True])
        self.assertEqual(g7.decode_bools("0x" + wd(32) + wd(0)), [])


class Resume(unittest.TestCase):
    # Mutant: rpc_err/timeout rows kept as done (a transient failure would never be retried).
    def test_load_done_retries_rpc_err_and_timeout_only(self):
        with tempfile.TemporaryDirectory() as t:
            p = os.path.join(t, "r.tsv")
            hdr = ["chain", "stratum", "idx", "mode", "outcome"]
            rows = [["base", "s1", "1", "D", "ok"], ["base", "s1", "1", "M0", "rpc_err"],
                    ["base", "s1", "1", "M1h", "timeout"], ["base", "s1", "2", "D", "revert"],
                    ["base", "s1", "2", "M0", "noquote"]]
            open(p, "w").write("\n".join("\t".join(r) for r in [hdr] + rows) + "\n")
            self.assertEqual(sorted(g7.load_done(p)), [("base", "s1", "1", "D"), ("base", "s1", "2", "D"),
                                                       ("base", "s1", "2", "M0")])
            self.assertEqual(len(g7.load_done(p, smoke=True)), 5)
            self.assertEqual(g7.load_done(os.path.join(t, "absent.tsv")), {})


class KeyHygiene(unittest.TestCase):
    # Mutant: `last = type(ex).__name__` -> `last = str(ex)` (the URL with the key reaches the TSV).
    def test_rpc_error_never_carries_the_url(self):
        with tempfile.TemporaryDirectory() as t:
            kf = os.path.join(t, "k")
            open(kf, "w").write("SECRETKEY123\n")
            with mock.patch.dict(os.environ, {"DRPC_KEY_FILE": kf}):
                rpc = g7.Rpc("base", attempts=2, backoff=0, timeout=1)

            def boom(url, **kw):
                raise ConnectionError(f"cannot reach {url}")

            rpc._s.post = boom
            with self.assertRaises(g7.RpcError) as cm:
                rpc.call("eth_blockNumber", [])
            self.assertNotIn("SECRETKEY123", str(cm.exception))
            self.assertNotIn("SECRETKEY123", repr(cm.exception.args))


class TreeLabel(unittest.TestCase):
    def make(self, t, commit):
        open(os.path.join(t, "base.manifest.tsv"), "w").write(
            "key\tvalue\n" + "".join(f"{k}\t{v}\n" for k, v in [("tree_commit", commit), ("stateTs", "1"),
            ("hub", A1), ("solver", A1), ("router", A1), ("quoter", A1), ("probe", A1), ("admin", A1)]))
        open(os.path.join(t, "base.state.json"), "w").write('{"accounts": {}}')
        return g7.Chain("base", SPEC, t, rpc=object())

    # Mutant: the tree_commit check in Chain.__init__ removed (a state of another tree measured
    # under this tree's label).
    def test_state_of_another_tree_is_refused(self):
        with tempfile.TemporaryDirectory() as t:
            with self.assertRaises(SystemExit):
                self.make(t, "e01b5030000000000000000000000000000000000")

    def test_state_of_the_labelled_tree_loads_with_its_ceiling(self):
        with tempfile.TemporaryDirectory() as t:
            ch = self.make(t, "2e4fdaa0000000000000000000000000000000000")
            self.assertEqual(ch.max_hops, 2)

    # Mutant: base row without max_hops_code (the column is empty in every row).
    def test_every_row_carries_the_code_ceiling(self):
        with mock.patch.object(g7, "seed_memory", lambda *a: (_ for _ in ()).throw(g7.RpcError("x"))), \
                mock.patch.object(g7, "measure_mode", lambda *a: {"outcome": "ok", "swept": 0, "net_out": 1, "delivered": 1}), \
                mock.patch.object(g7, "mid_price", lambda ch, d: ""), mock.patch.object(g7, "vital", lambda ch, d: {}):
            rows = g7.measure_draw(FakeChain(1793500000, 1), draw(), {})
        self.assertTrue(rows)
        self.assertTrue(all(r.get("max_hops_code") == 2 for r in rows))


class CallRpc:
    def __init__(self):
        self.calls = []

    def call(self, method, params):
        self.calls.append((method, params))
        return "0x" + wd(7) + wd(8) + wd(9)


class Vital(unittest.TestCase):
    """vital() reads Gate.vitalOf(wrapper) for the wrapper created for the stratum's gate_pool."""
    P_OK, P_REF, W_OK = "0x" + "f1" * 20, "0x" + "f2" * 20, "0x" + "a7" * 20

    def chain(self, t, rpc):
        open(os.path.join(t, "base.manifest.tsv"), "w").write(
            "key\tvalue\n" + "".join(f"{k}\t{v}\n" for k, v in [("tree_commit", "2e4fdaa" + "0" * 33), ("stateTs", "1"),
            ("hub", A1), ("solver", A1), ("router", A1), ("quoter", A1), ("probe", A1), ("admin", A1), ("gate", GATE)]))
        open(os.path.join(t, "base.state.json"), "w").write('{"accounts": {}}')
        # Pool of the created row in upper case (lookup is case-blind); the refused row carries an
        # address in its wrapper column, so dropping the status filter makes it callable.
        open(os.path.join(t, "base.gates.tsv"), "w").write(
            "family\tadapter\tvenue_key\ttA\ttB\tpool\twrapper\tstatus\n"
            f"1\t-\t65537\t{A1}\t{A2}\t{self.P_OK.upper().replace('0X', '0x')}\t{self.W_OK}\tcreated\n"
            f"1\t-\t65538\t{A1}\t{A2}\t{self.P_REF}\t{self.P_OK}\trefused\n")
        return g7.Chain("base", SPEC, t, rpc=rpc)

    def d(self, pool):
        return {"b": 500, "st": {"gate_pool": pool}}

    # Mutant: wrapper taken from the spec (st["wrapper"], never present) instead of gates.tsv.
    def test_wrapper_resolved_by_gate_pool(self):
        with tempfile.TemporaryDirectory() as t:
            rpc = CallRpc()
            v = g7.vital(self.chain(t, rpc), self.d(self.P_OK))
            self.assertEqual(v, {"vital_v": 7, "vital_depth18": 8, "vital_psi": 9})
            self.assertEqual(len(rpc.calls), 1)
            call = rpc.calls[0][1][0]
            self.assertEqual(call["to"], GATE)
            self.assertEqual(call["data"], "0x" + g7.SEL["vital"] + g7.addr(self.W_OK))

    # Mutant: the status filter dropped (a refused row maps its pool to a non-wrapper).
    def test_refused_create_has_no_vital_and_no_call(self):
        with tempfile.TemporaryDirectory() as t:
            rpc = CallRpc()
            self.assertEqual(g7.vital(self.chain(t, rpc), self.d(self.P_REF)), {})
            self.assertEqual(rpc.calls, [])

    def test_non_gate_stratum_has_no_vital(self):
        with tempfile.TemporaryDirectory() as t:
            rpc = CallRpc()
            self.assertEqual(g7.vital(self.chain(t, rpc), {"b": 500, "st": {}}), {})
            self.assertEqual(rpc.calls, [])


class AcceptFams(unittest.TestCase):
    """deploy_state.sh accepts phase A's families (avalanche 1..4) AND the prereg ones."""
    def fams(self, chain, pre):
        import subprocess
        sh = os.path.join(os.path.dirname(os.path.abspath(__file__)), "deploy_state.sh")
        r = subprocess.run(["bash", sh, "--accept-fams", chain, pre], capture_output=True, text=True, timeout=30)
        self.assertEqual(r.returncode, 0, r.stderr)
        return r.stdout.split()

    def test_avalanche_keeps_prereg_families_after_phase_a(self):
        # mutant: FAMS="1 2 3 4" (the old line, prereg families dropped)
        self.assertEqual(self.fams("avalanche", " 5 6"), ["1", "2", "3", "4", "5", "6"])

    def test_avalanche_without_prereg_accepts_phase_a(self):
        # mutant: the avalanche line removed
        self.assertEqual(self.fams("avalanche", ""), ["1", "2", "3", "4"])

    def test_other_chains_accept_only_prereg(self):
        # mutant: the chain test removed (every chain gets 1..4)
        self.assertEqual(self.fams("base", " 1 2 3 4 5"), ["1", "2", "3", "4", "5"])
        self.assertEqual(self.fams("bsc", ""), [])


class TxFlags(unittest.TestCase):
    """Every forge broadcast in deploy_state.sh is legacy: no eth_feeHistory forwarded to the fork RPC."""
    SH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "deploy_state.sh")

    def test_tx_flags_are_legacy(self):
        # mutant: TXF="" (EIP-1559 fees again)
        import subprocess
        r = subprocess.run(["bash", self.SH, "--tx-flags"], capture_output=True, text=True, timeout=30)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("--legacy", r.stdout.split())

    def broadcast_lines(self, verb):
        lines = open(self.SH).read().split("\n")
        rows = [i for i, l in enumerate(lines) if verb in l and not l.lstrip().startswith("#")]
        self.assertTrue(rows, verb)
        # a command continued with a trailing backslash spans the next line too
        return [lines[i] + (lines[i + 1] if lines[i].rstrip().endswith("\\") else "") for i in rows]

    def test_forge_script_carries_tx_flags(self):
        # mutant: $TXF dropped from the phase A forge script
        for l in self.broadcast_lines("forge script"):
            self.assertIn("$TXF", l)

    def test_forge_create_carries_tx_flags(self):
        # mutant: $TXF dropped from the adapters' forge create
        for l in self.broadcast_lines("forge create"):
            self.assertIn("$TXF", l)


if __name__ == "__main__":
    unittest.main()
