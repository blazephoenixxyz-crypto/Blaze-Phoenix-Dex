#!/usr/bin/env python3
"""Offline tests for g7.py (no RPC, no key). Run: python3 -I tools/g7-gas-campaign/test_g7.py

Each test names the mutant of g7.py that turns it red; mutants_g7.py applies every one of them
and checks that its test goes red (100/100 on 2026-11-14, 5 of them the named meta-mutants).
"""
import os
import sys
import tempfile
import threading
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


TOKEN2 = "0x" + "d2" * 20
POOL3 = "0x" + "b3" * 20
PM = "0x" + "f4" * 20


def tok(token, sel, *words, gas=5, value=0):
    """A token call frame with ABI words (addresses as hex, amounts as int)."""
    d = sel + "".join(wd(w) if isinstance(w, int) else "0" * 24 + w[2:] for w in words)
    return {"to": token, "input": "0x" + d, "gasUsed": hex(gas), "value": hex(value), "calls": []}


class LegAmt(unittest.TestCase):
    def trace(self):
        v3_leg = fr(POOL1, g7.SEL["v3swap"], 200, [
            tok(TOKEN, g7.SEL["transfer"], ROUTER, 650),  # the pool pays out: not an input
            fr(ROUTER, "fa461e33", 60, [tok(TOKEN2, g7.SEL["transferFrom"], A1, POOL1, 500)]),  # callback payment
        ])
        pm_leg = fr(PM, g7.SEL["unlock"], 150)
        pm_leg["value"] = hex(300)
        router = fr(ROUTER, "c0ffee00", 900, [
            tok(TOKEN, g7.SEL["transfer"], POOL2, 700),  # v2 pays the pair before swap()
            fr(POOL2, g7.SEL["v2swap"], 100),
            v3_leg,
            pm_leg,
            fr(POOL3, g7.SEL["v2swap"], 80),  # paid by no transfer in its window
        ])
        # a transfer to the first leg's pool outside the Router (probe setup): not a leg input
        return fr("0xprobe", g7.SEL["run"], 1000, [tok(TOKEN, g7.SEL["transfer"], POOL2, 9999), router])

    # Mutants: `if dst == to:` -> `if dst:` (the pool's payout to the Router counted as POOL1 input);
    # `if id(n) not in under: continue` removed (the probe's transfer counted as POOL2 input).
    def test_input_per_leg_from_transfers_into_the_target_under_the_router(self):
        e = g7.exec_segments(self.trace(), ROUTER)
        self.assertEqual(e["legs_detail"], f"{POOL2}:100;{POOL1}:200;{PM}:150;{POOL3}:80")
        self.assertEqual(e["leg_amt"], f"{POOL2}:{TOKEN}=700;{POOL1}:{TOKEN2}=500;{PM}:eth=300;{POOL3}:")

    def test_leg_amt_is_the_last_column(self):
        self.assertEqual(g7.COLS[-1], "leg_amt")


UNIV3_BASE = "0x33128a8fc17869897dce68ed026d694621f6fdfd"
V4_BASE = "0x498581ff718922c3f8e6a244956af099b2652b2b"
UNIV3_OP = "0x1f98431c8ad98523631ae4a59f267346ea31f984"
SUSHI_C35D = "0xc35dadb65012ec5796536bd9864ed8773abc74c4"


def dexrow(chain, legs, mode="D", outcome="ok", stratum="s1", idx=1, b=100, gate_used=0):
    return {"chain": chain, "stratum": stratum, "idx": idx, "b": b, "mode": mode, "outcome": outcome,
            "gate_used": gate_used, "legs_detail": ";".join(f"{t}:{g}" for t, g in legs)}


class DexUsage(unittest.TestCase):
    POOLS = {("base", POOL1): (UNIV3_BASE, "v3"), ("ethereum", POOL2): (UNIV3_OP, "v3"),
             ("arbitrum", POOL3): (SUSHI_C35D, "v2")}
    VENUES = {("base", UNIV3_BASE): "v3", ("base", V4_BASE): "v4", ("base", SUSHI_C35D): "v3",
              ("optimism", UNIV3_OP): "v3", ("ethereum", UNIV3_OP): "v3", ("arbitrum", SUSHI_C35D): "v2"}
    STRATA = {("base", "gate-1"): {"id": "gate-1", "gate_family": "curve_ng"},
              ("base", "s1"): {"id": "s1", "seed_pools": [{"pool": TOKEN, "kind": 5}]}}

    def usage(self):
        rows = [dexrow("base", [(POOL1, 100), (V4_BASE, 50)]),  # 2 legs: universe pool + the V4 PoolManager
                dexrow("base", [(POOL1, 110)], mode="M0"),  # same draw, another mode
                dexrow("base", [(WRAP, 70)], stratum="gate-1", gate_used=1),  # Gate wrapper
                dexrow("base", [(TOKEN, 30)]),  # seed pool of the stratum (Hub kind 5)
                dexrow("base", [(POOL1, 999)], outcome="revert"),  # not a settled route
                dexrow("optimism", [(A1, 40)]),  # no source
                dexrow("ethereum", [(POOL2, 60)]),  # 1f98 v3: no constant on ethereum
                dexrow("arbitrum", [(POOL3, 20)])]  # c35d v2: base names c35d only as a v3 factory
        return g7.dex_usage(rows, self.POOLS, self.VENUES, self.STRATA)

    # Mutants: `c[0] += 1` -> `+= 2`; a draw counted per row (`c[2].add(id(r))`); the outcome==ok
    # filter removed (the revert leg adds 1 leg and 999 gas).
    def test_legs_gas_draws_modes_over_ok_rows(self):
        b = self.usage()["base"]
        self.assertEqual(b[("Uniswap V3", "v3", "factory")], [2, 210, {("base", "s1", 1, 100)}, {"D", "M0"}])
        self.assertEqual(b[("Uniswap V4", "v4", "factory")][:2], [1, 50])
        self.assertEqual(b[("Curve NG", "curve_ng", "gate")][:2], [1, 70])
        self.assertEqual(b[("unknown", "solidly", "seed")][:2], [1, 30])
        self.assertEqual(sum(v[0] for v in b.values()), 5)

    # Mutant: `and k == kind and` -> `and` (arbitrum c35d v2 named SushiSwap V3 from base's v3 factory).
    def test_addr_basis_needs_the_same_kind_on_another_chain(self):
        u = self.usage()
        self.assertEqual(list(u["ethereum"]), [("Uniswap V3", "v3", "addr")])
        self.assertEqual(list(u["arbitrum"]), [("unknown", "v2", "unknown")])
        self.assertEqual(list(u["optimism"]), [("unknown", "", "unknown")])

    def test_report_sections_pct_of_the_chain(self):
        d = tempfile.mkdtemp()
        uni = os.path.join(d, "u.tsv")
        with open(uni, "w") as f:
            f.write("chain\tvenue\tkind\tpool\tadapter\n")
            f.write(f"base\t{UNIV3_BASE}\tv3\t{POOL1}\troutable:x\nbase\t{V4_BASE}\tv4\t{POOL2}\tnone\n")
        rows = [dexrow("base", [(POOL1, 150), (V4_BASE, 50)]), dexrow("base", [(POOL1, 100)], idx=2)]
        ls = g7.dex_lines({"chains": {}}, rows, uni)
        used = section(ls, [x for x in ls if x.startswith("# dex used")][0])
        self.assertEqual(used, ["base\tUniswap V3\tv3\tfactory\t2\t66.7\t250\t83.3\t2\tD",
                                "base\tUniswap V4\tv4\tfactory\t1\t33.3\t50\t16.7\t1\tD"])
        avail = section(ls, [x for x in ls if x.startswith("# dex available")][0])
        self.assertEqual(avail, [f"base\tUniswap V3\tv3\t{UNIV3_BASE}\t1\t1\t2",
                                 f"base\tUniswap V4\tv4\t{V4_BASE}\t1\t0\t1"])


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
        self.liq, self.b0 = {}, 0


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
        self.assertEqual((rows["MF1h"]["outcome"], rows["MF1h"].get("detail")), ("mf_unforced", "stamp not found"))
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
        self.assertEqual(rows["M0"].get("out_vs_D_bps"), 100.0)


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
    # account searched (`if acct.lower() != token: continue` restored: slot not found). Either one
    # raising out of the search is the guard failing, so it fails the test (not an error).
    def test_balance_in_another_account_is_found_past_a_reverting_slot(self):
        ch = self.chain()
        try:
            got = ch.balance_slot(self.TOK, 10)
        except (g7.Reverted, g7.RpcError) as e:
            self.fail("slot search raised %s: %s" % (type(e).__name__, e))
        self.assertEqual(got, (self.STATE, "0x99"))

    # Mutant: override() funds the token instead of the holder account it is given.
    def test_override_funds_the_holder_account(self):
        o = self.chain().override(fund={self.STATE: ("0x99", 5)})
        self.assertEqual(o.get(self.STATE, {}).get("stateDiff", {}).get("0x99"), "0x" + wd(5))
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


class RpcUrl(unittest.TestCase):
    # Mutant: `url = os.environ.get("G7_RPC_URL_" + chain.upper())` -> `url = None` (the override is ignored).
    def test_own_url_replaces_drpc_and_skips_the_key_file(self):
        with tempfile.TemporaryDirectory() as t:
            env = {"DRPC_KEY_FILE": os.path.join(t, "absent"), "G7_RPC_URL_BASE": "http://127.0.0.1:8545"}
            with mock.patch.dict(os.environ, env):
                try:  # the mutant reads the absent key file: report it as a failed assertion, not an error
                    url = g7.Rpc("base", attempts=1, backoff=0, timeout=1)._url
                except FileNotFoundError:
                    url = "the key file was read"
                self.assertEqual(url, "http://127.0.0.1:8545")
                with self.assertRaises(FileNotFoundError):  # another chain still needs the key file
                    g7.Rpc("optimism", attempts=1, backoff=0, timeout=1)


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


def err_string(txt):
    h = txt.encode().hex()
    return "0x" + g7.ERROR_SEL + wd(0x20) + wd(len(txt)) + h + "0" * ((64 - len(h) % 64) % 64)


class RevertDetail(unittest.TestCase):
    # Mutant: the Error(string) branch dropped (`if d[:8] == ERROR_SEL` -> `if False`): the reason is lost.
    def test_error_string_is_decoded_else_the_selector_is_kept(self):
        self.assertEqual(g7.revert_detail("exec:", err_string("Too little received")), "exec:Error:Too little received")
        self.assertEqual(g7.revert_detail("call:", "0x3d0ccdde" + wd(5)), "call:0x3d0ccdde")
        self.assertEqual(g7.revert_detail("exec:", ""), "exec:empty")


def by_method(table):
    return lambda method, params: table[method](params) if callable(table[method]) else table[method]


class PoolFee(unittest.TestCase):
    def chain(self, fee_pips):
        ch = mock.Mock()
        ch.lock, ch.fees = threading.Lock(), {}
        ch.rpc.call.side_effect = by_method({"eth_call": "0x" + wd(fee_pips)})
        return ch

    # Mutant: the seed fee in pips not divided by 100 (`known[pool] / 100` -> `known[pool]`).
    def test_seed_fee_first_then_fee_call_in_bps(self):
        d = dict(draw(), st={"seed_pools": [{"pool": POOL1, "kind": 1, "fee": 500}]})
        ch = self.chain(3000)
        self.assertEqual(g7.pool_fee_bps(ch, d, f"{POOL1}:100;{POOL2}:200", 2, 2), 35)
        self.assertEqual(ch.rpc.call.call_count, 1)  # POOL1 from the seed, POOL2 by fee()
        self.assertEqual(g7.pool_fee_bps(ch, d, f"{POOL1}:100;{POOL2}:200", 1, 2), "")  # hops != legs: unknown
        self.assertEqual(ch.fees[POOL2], 3000)


class NqClass(unittest.TestCase):
    def nq(self, amount, detail="quote:x", liq="100", chain="base"):
        return {"chain": chain, "stratum": "s", "tin": A1, "tout": A2, "amount_in": str(amount), "outcome": "noquote",
                "detail": detail, "liq_usd": liq}

    # Mutant: A' without the amount comparison (`oks[k] < int(r["amount_in"])` dropped): a smaller
    # amount that fails after a bigger one succeeded is not an amount effect.
    def test_classes_s_dust_a_aprime_b(self):
        ok = {"chain": "base", "stratum": "s", "tin": A1, "tout": A2, "amount_in": "10", "outcome": "ok", "detail": ""}
        rows = [ok, self.nq(100, "quote:out of gas"), self.nq(100, "canExecute=0"), self.nq(100, liq="0.5"),
                self.nq(100), self.nq(5), self.nq(100, chain="optimism")]
        got = [r["nq_class"] for r in g7.classify_rows(rows)]
        self.assertEqual(got, ["", "S", "dust", "A", "A'", "B", "B"])


class MidGuard(unittest.TestCase):
    def chain(self, code, calls):
        ch = mock.Mock()
        ch.b0 = 7
        ch.rpc.call.side_effect = by_method({"eth_getCode": code, "eth_call": lambda p: calls[p[0]["data"][2:10]]})
        return ch

    # Mutant: the code check at b0 accepts "0x" (`in ("0x", "", None)` -> `in ("",)`): a pool born
    # inside the window would price the whole window (the no-code chain still answers getReserves
    # at b, so the mutant returns that price).
    def test_no_code_at_window_start_or_empty_pool_gives_no_mid(self):
        d = dict(draw(), st={"mid_pool": {"pool": POOL1, "family": "v2", "token0": A1}})
        self.assertEqual(g7.mid_price(self.chain("0x", {g7.SEL["reserves"]: "0x" + wd(5) + wd(10) + wd(1)}), d), "")
        res = {g7.SEL["reserves"]: "0x" + wd(5) + wd(0) + wd(1)}
        self.assertEqual(g7.mid_price(self.chain("0x6080", res), d), "")
        res = {g7.SEL["reserves"]: "0x" + wd(5) + wd(10) + wd(1)}
        self.assertEqual(g7.mid_price(self.chain("0x6080", res), d), 2.0)
        d["st"]["mid_pool"] = {"pool": POOL1, "family": "v3", "token0": A1}
        res = {g7.SEL["slot0"]: "0x" + wd(2 ** 96), g7.SEL["liquidity"]: "0x" + wd(0)}
        self.assertEqual(g7.mid_price(self.chain("0x6080", res), d), "")


class FundGuard(unittest.TestCase):
    # Mutant: `if bal != d["amount"]` -> `if False`: an unfunded probe goes on to an exec that
    # reverts for a reason that is not the Router's. The fake fails the test if the exec is traced.
    def test_unfunded_probe_is_prereq_not_revert(self):
        ch = mock.Mock()
        ch.solver, ch.hub, ch.gate, ch.wrappers, ch.quoter, ch.probe, ch.spec = SOLVER, HUB, GATE, [WRAP], ROUTER, TOKEN, SPEC
        ch.router = ROUTER
        ch.c = {"native_wrap": WRAP}
        ch.override.return_value = {}
        ch.balance_slot.return_value = (A1, "0x1")
        tr = fr("0xq", g7.SEL["preview"], 1000)
        tr["output"] = Abi("test_fits_2_10_boundaries").preview_blob("aabb")

        def trace(p):  # the quote goes to the quoter (ROUTER here), the exec to the probe
            if p[0]["to"] != ROUTER:
                self.fail("exec traced with an unfunded probe (to " + p[0]["to"] + ")")
            return tr
        ch.rpc.call.side_effect = by_method({"debug_traceCall": trace, "eth_call": "0x" + wd(0)})
        r = g7.measure_mode(ch, draw(), 1, "D", None)
        self.assertEqual((r["outcome"], r.get("detail")), ("prereq", "fund:0"))
        self.assertEqual(r["g_quote_cap"], int(g7.GAS, 16))



class ExecRevert(unittest.TestCase):
    # Mutant: the exec revert keeps the selector only (`revert_detail("exec:", ret, 72)` -> `ret)`):
    # the uint16 code of RouterE is lost and the report reads `RouterE(code not recorded)`.
    def test_exec_revert_keeps_the_selector_and_the_code_word(self):
        ch = mock.Mock()
        ch.solver, ch.hub, ch.gate, ch.wrappers, ch.quoter, ch.probe, ch.spec = SOLVER, HUB, GATE, [WRAP], ROUTER, TOKEN, SPEC
        ch.router = ROUTER
        ch.c = {"native_wrap": WRAP}
        ch.override.return_value = {}
        ch.balance_slot.return_value = (A1, "0x1")
        tr = fr("0xq", g7.SEL["preview"], 1000)
        tr["output"] = Abi("test_fits_2_10_boundaries").preview_blob("aabb")
        ch.rpc.call.side_effect = by_method({"debug_traceCall": tr, "eth_call": "0x" + wd(2)})  # funded: amount 2
        ret = "0x62b0a386" + wd(7)
        with mock.patch.object(g7, "decode_run", lambda out: (False, ret, 0, 0, None)), \
                mock.patch.object(g7, "exec_segments", lambda *a: {"legs_detail": ""}), \
                mock.patch.object(g7, "pool_fee_bps", lambda *a: ""):
            r = g7.measure_mode(ch, draw(), 1, "D", None)
        self.assertEqual((r["outcome"], r["detail"]), ("revert", "exec:" + ret))
        self.assertEqual(g7.decode_err(r["detail"]), ("RouterE", "RouterE(7)"))
        self.assertEqual(g7.oc_class(r), "RouterE")


class OutOfGas(unittest.TestCase):
    # Mutant: the retry keeps the same cap (`cap *= 2` -> `cap *= 1`).
    def test_out_of_gas_trace_is_retried_once_with_twice_the_cap(self):
        ch = mock.Mock()
        ch.rpc.call.side_effect = [{"error": "out of gas"}, {"error": "execution reverted", "output": "0x"}]
        tx = {"from": g7.CALLER, "to": ROUTER, "data": "0x", "gas": g7.GAS}
        tr, cap = g7.trace_call(ch, tx, 5, {"tracer": "callTracer"})
        self.assertEqual(cap, 2 * int(g7.GAS, 16))
        self.assertEqual(ch.rpc.call.call_args_list[1][0][1][0]["gas"], hex(2 * int(g7.GAS, 16)))
        self.assertEqual(tr["error"], "execution reverted")


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


def report_lines(rows, spec=None):
    """cmd_report over a results.tsv of `rows` (COLS, missing cells empty) and `spec`; the printed lines."""
    import contextlib
    import io
    import json
    d = tempfile.mkdtemp()
    sp, out = os.path.join(d, "spec.json"), os.path.join(d, "results.tsv")
    json.dump(spec or SPEC, open(sp, "w"))
    with open(out, "w") as f:
        f.write("\t".join(g7.COLS) + "\n")
        for r in rows:
            f.write("\t".join(str(r.get(k, "")) for k in g7.COLS) + "\n")
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        g7.cmd_report(sp, out)
    return buf.getvalue().split("\n")


def okrow(mode, kind="pairs", chain="base", **kw):
    r = {"chain": chain, "label": "L", "stratum": "s1", "kind": kind, "idx": 1, "mode": mode, "tin": A1, "tout": A2,
         "amount_in": 2, "outcome": "ok", "swept": 0, "g_quote": 2000000, "g_discovery": 0, "g_exec": 300000,
         "g_legs_sum": 200000, "g_record": 30000, "age_real_s": 10, "net_out": 1000, "delivered": 1000}
    r.update(kw)
    return r


class MsCase(unittest.TestCase):
    """ms_case: where a quote's route came from (D / hit / partial / miss / expired)."""
    def case(self, mode, swept=0, disc=0, age=10):
        return g7.ms_case({"mode": mode, "swept": swept, "g_discovery": disc, "age_real_s": age})

    # Mutants: `if int(row.get("g_discovery") or 0) > 0: return "partial"` dropped (partial folded
    # into hit); `int(age) > ttl` -> `>=` (a record exactly at the TTL counted as expired).
    def test_cases(self):
        self.assertEqual(self.case("D", swept=1, disc=1700000), "D")
        self.assertEqual(self.case("M0"), "hit")
        self.assertEqual(self.case("M0", disc=500), "partial")
        self.assertEqual(self.case("M1h", swept=1, disc=1700000, age=g7.TTL), "miss")  # at the TTL: still live
        self.assertEqual(self.case("M1h", swept=1, disc=1700000, age=g7.TTL + 1), "expired")
        self.assertEqual(self.case("M1h", age=g7.TTL + 1), "expired")  # age decides, even without a sweep
        self.assertEqual(self.case("MF1h", age=g7.TTL + 1), "hit")  # a forced stamp is fresh by construction
        self.assertEqual(g7.ms_case({"mode": "M0", "outcome": "prereq"}), "")  # the quote did not run
        self.assertEqual(g7.ms_case({"mode": "M0", "swept": "0", "g_discovery": "", "age_real_s": "10"}), "hit")  # tsv strings

    # Mutant: `row["ms_case"] = ms_case(row)` removed from measure_draw.
    def test_measure_draw_sets_the_case(self):
        seeded = lambda age: (400, MeasureDraw.TSB - age, {}, {"0x1": "0x" + wd(MeasureDraw.TSB - age)}, [True])  # noqa: E731
        mm = lambda m: {"outcome": "ok", "swept": 0, "g_discovery": 0 if m == "M0" else 7, "net_out": 1, "delivered": 1}  # noqa: E731
        with mock.patch.object(g7, "seed_memory", lambda ch, d, age, ts_b: seeded(age)), \
                mock.patch.object(g7, "measure_mode", lambda ch, d, ts_b, m, h: mm(m)), \
                mock.patch.object(g7, "mid_price", lambda ch, d: ""), mock.patch.object(g7, "vital", lambda ch, d: {}):
            rows = {r["mode"]: r for r in g7.measure_draw(FakeChain(MeasureDraw.TSB, 0), draw(), {})}
        self.assertEqual({m: r.get("ms_case") for m, r in rows.items()}, {"D": "D", "M0": "hit", "M1h": "partial", "MF1h": "partial"})
        self.assertIn("ms_case", g7.COLS)

    # Mutant: the ok filter of the table's key set dropped (`and r["ms_case"]` alone): a noquote row
    # whose case has no ok row (the swept M1h miss) opens an empty cell (n 0, no percentiles).
    def test_report_table_per_chain_kind_case(self):
        rows = [okrow("D", swept=1, g_discovery=1700000), okrow("M0"), okrow("M0", g_exec=320000),
                okrow("M0", outcome="noquote", g_exec="", g_legs_sum="", g_record=""),
                okrow("M1h", outcome="noquote", swept=1, g_discovery=1700000, g_exec="", g_legs_sum="", g_record=""),
                okrow("M1h", swept=1, g_discovery=1700000, age_real_s=g7.TTL + 1, g_exec=310000)]
        for r in rows:
            r["ms_case"] = g7.ms_case(r)
        lines = report_lines(rows)
        self.assertIn("# moonslot cases: chain\tkind\tms_case\tsegment\tn\tp50\tp95", lines)
        self.assertIn("base\tpairs\thit\tg_quote\t2\t2000000\t2000000", lines)
        self.assertIn("base\tpairs\thit\tdex_overhead\t2\t100000\t120000", lines)
        self.assertIn("base\tpairs\thit\tg_record\t2\t30000\t30000", lines)
        self.assertIn("base\tpairs\texpired\tg_exec\t1\t310000\t310000", lines)
        self.assertIn("base\tpairs\tD\tg_legs_sum\t1\t200000\t200000", lines)
        self.assertEqual(g7.ms_case(rows[4]), "miss")
        self.assertFalse([ln for ln in lines if ln.startswith("base\tpairs\tmiss\t")], "a case with no ok row has no cell")
        # a results.tsv from before the column is classified on the fly
        for r in rows:
            r["ms_case"] = ""
        self.assertIn("base\tpairs\texpired\tg_exec\t1\t310000\t310000", report_lines(rows))


class ReportSplit(unittest.TestCase):
    """cmd_report: the exec split (legs / DEX overhead / record fraction) and the moonslot effect
    (D vs each natural mode) tables."""
    def rows(self):
        return [okrow("D", swept=1, g_discovery=1700000, g_quote=2000000), okrow("M0", g_quote=1000000),
                okrow("M0", g_exec=320000, g_record=32000, g_quote=1100000),
                okrow("M1h", swept=1, g_discovery=1500000, g_quote=1900000, outcome="revert"),
                okrow("M1h", kind="major", g_exec=400000, g_legs_sum=250000, g_record=40000, g_quote=1800000)]

    # Mutants: dex_overhead = g_exec + g_legs_sum; dex_overhead = g_exec - g_legs_sum - g_record - g_sweep
    # (the overhead holds the record and the sweep); rec_frac = g_record / g_legs_sum.
    def test_exec_split_per_chain_kind(self):
        lines = report_lines(self.rows())
        self.assertIn("# exec split: chain\tkind\tn_ok\tlegs_p50\tlegs_p95\tdex_overhead_p50\tdex_overhead_p95\trec_frac_p50\trec_frac_p95", lines)
        # pairs: ok rows D, M0, M0 (the revert is out): legs 200000 x3; overhead 100000, 100000, 120000; rec 0.1, 0.1, 0.1
        self.assertIn("base\tpairs\t3\t200000\t200000\t100000\t120000\t0.1\t0.1", lines)
        self.assertIn("base\tmajor\t1\t250000\t250000\t150000\t150000\t0.1\t0.1", lines)

    # Mutant: the moonslot effect table over every row (the revert row joins M1h g_quote).
    def test_moonslot_effect_D_vs_each_natural_mode(self):
        lines = report_lines(self.rows())
        self.assertIn("# moonslot effect: chain\tsegment\tD_n\tD_p50\tD_p95\tM0_n\tM0_p50\tM0_p95\tM1h_n\tM1h_p50\tM1h_p95", lines)
        self.assertIn("base\tg_quote\t1\t2000000\t2000000\t2\t1000000\t1100000\t1\t1800000\t1800000", lines)
        self.assertIn("base\tg_discovery\t1\t1700000\t1700000\t2\t0\t0\t1\t0\t0", lines)
        self.assertFalse([l for l in lines if l.startswith("base\tg_quote\t") and "MF1h" in l])


class PairedVsD(unittest.TestCase):
    """cmd_report "# paired vs D": per draw (chain, stratum, idx, b) the D row and the mode row, both
    ok; delta = mode - D per draw; p95 only from PAIRED_MIN_N; every declared cell printed."""
    HDR = ("# paired vs D (same chain, stratum, idx, b; both ok; delta = mode - D per draw; delta_p95 only at n >= 20): "
           "chain\tmode\tms_case\tsegment\tn_pairs\tD_p50\tM_p50\tdelta_p50\tdelta_p95")

    def draw(self, mode, idx, gq, b=None, **kw):
        return okrow(mode, idx=idx, b=b if b is not None else 100 * idx, g_quote=gq, **kw)

    def paired(self, lines):
        return section(lines, self.HDR)

    # Meta-mutant "unpaired": draw_key -> (chain, stratum), so an M row meets another draw's D.
    # Mutant: the ok filter of the D side dropped (a noquote D still pairs).
    def test_pairs_by_draw_not_by_stratum(self):
        rows = [self.draw("D", 1, 1000), self.draw("M0", 1, 900),
                self.draw("D", 2, 5000), self.draw("M0", 2, 4000),
                self.draw("D", 3, 2500000, outcome="noquote"), self.draw("M0", 3, 700),  # D not ok: out
                self.draw("D", 4, 3000), self.draw("M0", 4, 600, outcome="revert")]  # mode not ok: out
        p = self.paired(report_lines(rows))
        # deltas -100 and -1000: the per-draw median is -1000; the marginal medians would give 900 - 1000 = -100
        self.assertIn("base\tM0\tall\tg_quote\t2\t1000\t900\t-1000\t", p)
        self.assertIn("base\tM0\thit\tg_quote\t2\t1000\t900\t-1000\t", p)

    # Meta-mutant "p95 below the minimum": `if len(v) >= PAIRED_MIN_N else ""` -> `if True else ""`.
    # Mutant: `>=` -> `>` (n = 20 loses its p95).
    def test_p95_only_from_the_declared_minimum(self):
        # the minimum is derived, not chosen: the smallest n whose nearest-rank p95 is not the maximum
        self.assertEqual(min(n for n in range(1, 100) if g7.pct(list(range(n)), 95) != n - 1), g7.PAIRED_MIN_N)
        rows = []
        for i in range(1, 21):
            rows += [self.draw("D", i, 1000), self.draw("M1h", i, 1000 - i)]
            if i < 20:
                rows.append(self.draw("M0", i, 1000 - i))
        p = self.paired(report_lines(rows))
        self.assertIn("base\tM0\tall\tg_quote\t19\t1000\t990\t-10\t", p)  # n 19: no p95
        self.assertIn("base\tM1h\tall\tg_quote\t20\t1000\t989\t-11\t-2", p)  # n 20: rank 19 of 20

    # Meta-mutant "mode summed": the cell key (chain, mode) -> (chain, mode.replace("F", "")), so MF1h
    # folds into M1h.
    def test_a_mode_is_never_summed_into_another(self):
        rows = [self.draw("D", 1, 1000), self.draw("M1h", 1, 900), self.draw("MF1h", 1, 500)]
        p = self.paired(report_lines(rows))
        self.assertIn("base\tM1h\tall\tg_quote\t1\t1000\t900\t-100\t", p)
        self.assertIn("base\tMF1h\tall\tg_quote\t1\t1000\t500\t-500\t", p)

    # Meta-mutant "cell disappears": `if c != "all" and not v: continue` -> `if not v: continue`.
    def test_every_declared_cell_is_printed(self):
        import copy
        spec = copy.deepcopy(SPEC)
        spec["chains"]["bsc"] = copy.deepcopy(spec["chains"]["base"])
        p = self.paired(report_lines([self.draw("D", 1, 1000), self.draw("M0", 1, 900)], spec))
        alls = [ln for ln in p if ln.split("\t")[2] == "all"]
        self.assertEqual(len(alls), 2 * 3 * len(g7.PAIRED_SEGS))  # chains x (M0, M1h, MF1h) x segments
        self.assertIn("bsc\tMF1h\tall\tg_record\t0\t\t\t\t", p)
        self.assertIn("base\tM1h\tall\tg_quote\t0\t\t\t\t", p)
        self.assertFalse([ln for ln in p if ln.split("\t")[2] not in ("all", "hit")], "a case without a pair has no line")


def section(lines, hdr):
    """The non-empty lines of the report section headed `hdr`, up to the next section header."""
    out = []
    for ln in lines[lines.index(hdr) + 1:]:
        if ln.startswith("#"):
            break
        if ln:
            out.append(ln)
    return out


class GRecordShape(unittest.TestCase):
    """cmd_report "# g_record by hops x legs": per chain x hops x legs, the D (cold registry) and M0
    g_record marginals over ok rows; p95 only from PAIRED_MIN_N."""
    HDR = ("# g_record by hops x legs (ok rows; D vs M0 unpaired; p95 only at n >= 20): chain\thops\tlegs\t"
           "D_n\tD_p50\tD_p95\tM0_n\tM0_p50\tM0_p95")

    def row(self, mode, idx, g, hops=1, legs=1, **kw):
        return okrow(mode, idx=idx, b=100 * idx, hops=hops, legs=legs, g_record=g, **kw)

    # Mutant "legs folded": shape (chain, hops, legs) -> (chain, hops, hops) (the 1x2 row joins 1x1).
    # Mutant "modes merged": the cell filter drops `r["mode"] == m` (D and M0 get the same cells).
    # Mutant "not ok counted": the ok filter dropped (the noquote row joins D 1x1).
    def test_split_by_hops_and_legs_per_mode_over_ok_rows(self):
        rows = [self.row("D", 1, 600000), self.row("D", 2, 500000), self.row("M0", 1, 12000),
                self.row("D", 3, 1000000, legs=2),
                self.row("D", 4, 9999999, outcome="noquote"),  # not ok: out
                self.row("M1h", 1, 77),  # neither D nor M0: out
                self.row("D", 5, "", hops=2, legs=2)]  # no g_record: out (absent is not a value)
        s = section(report_lines(rows), self.HDR)
        # nearest-rank p50 of two values is the lower one; n < 20: no p95
        self.assertEqual(s, ["base\t1\t1\t2\t500000\t\t1\t12000\t", "base\t1\t2\t1\t1000000\t\t0\t\t"])

    # Mutant "p95 below the minimum": `>= PAIRED_MIN_N` -> `> PAIRED_MIN_N` (n = 20 loses its p95).
    def test_p95_only_from_the_declared_minimum(self):
        rows = [self.row("D", i, 1000 * i) for i in range(1, 21)] + [self.row("M0", i, 10 * i) for i in range(1, 20)]
        s = section(report_lines(rows), self.HDR)
        self.assertEqual(s, ["base\t1\t1\t20\t10000\t19000\t19\t100\t"])  # D rank 19 of 20; M0 n 19: none


class SwapCoverage(unittest.TestCase):
    """H2 (G7-COBERTURA 1c): mf_unforced says the MF counterfactual could not be forced, not that the
    swap failed. Swap coverage counts an mf_unforced row as its natural twin M<age> (same draw, same
    seeded memory, unforced): ok if the twin is ok. The denominator stays every row. In
    results-bb4cdbb 366 of 534 mf_unforced rows were of draws whose 6 other modes were ok.
    Red at a1849b4 (before the fix)."""
    SPEC8 = dict(SPEC, ages={"M0": 0, "M1h": 3600, "M6h": 21600, "M24h": 86400, "M72h": 259200},
                 mf_ages=["M24h", "M72h"])
    HDR = ("# swap coverage (mf_unforced counts as its twin M<age>; denominator = every row): "
           "chain\tn\tok\tmf_unforced_twin_ok\tswap_ok\tswap_ok_pct")
    NAT = ("D", "M0", "M1h", "M6h", "M24h", "M72h")

    def draw(self, idx, nat, mf=("mf_unforced", "mf_unforced")):
        rows = [okrow(m, idx=idx, b=100 * idx, outcome=o) for m, o in zip(self.NAT, nat)]
        return rows + [okrow(m, idx=idx, b=100 * idx, outcome=o) for m, o in zip(("MF24h", "MF72h"), mf)]

    def rows(self):
        return (self.draw(1, ["ok"] * 6) +                                     # oooooouu: 8/8
                self.draw(2, ["noquote"] * 6) +                                # nnnnnnuu: 0/8
                self.draw(3, ["ok", "ok", "ok", "ok", "noquote", "ok"]))       # MF24h twin noquote: 6/8

    # Mutant "mf_unforced is a swap failure": the twin rule dropped (oooooouu counts 6/8, not 8/8).
    def test_draw_with_swap_ok_and_mf_unforced_counts_8_of_8(self):
        cov = g7.swap_coverage(self.draw(1, ["ok"] * 6))
        self.assertEqual(cov, {"base": (8, 6, 2)})

    # Mutant "any mf_unforced is ok": the twin's outcome not checked (draws 2 and 3 gain 3 rows).
    # Mutant "twin is D": the twin taken as the draw's D row (draw 3 MF24h counts ok).
    def test_report_counts_mf_unforced_as_its_twin_over_every_row(self):
        lines = report_lines(self.rows(), self.SPEC8)
        self.assertIn(self.HDR, lines)
        self.assertEqual(section(lines, self.HDR), ["base\t24\t11\t3\t14\t58.3"])
        # the outcomes table still counts mf_unforced as its own outcome
        self.assertIn("base\tpairs\tMF24h\t3\t0\t0\t0\t0\t0\t0\t3", lines)


class Seed(unittest.TestCase):
    """The measure takes the pre-registered seed (seed.txt, a block hash fixed after the
    pre-registration commit, seed.py); no dispatch input can choose it."""
    # Meta-mutant "seed chosen" (yml): SEED=$(cat "$D/seed.txt") -> SEED="${{ inputs.seed }}".
    def test_seed_is_the_committed_block_hash_never_an_input(self):
        import re
        y = workflow_text()
        self.assertEqual(y.count('SEED=$(cat "$D/seed.txt")'), 1)
        self.assertEqual(y.count("SEED="), 1)
        self.assertIn('measure "$SPEC" "$D/state" "$OUT" "$SEED"', y)
        self.assertNotIn("inputs.seed", y)
        self.assertNotIn("      seed:\n", y)
        txt = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "seed.txt")).read()
        self.assertRegex(txt, re.compile(r"\A0x[0-9a-f]{64}\n?\Z"))


def workflow_text():
    """The campaign workflow: a copy next to this file (the mutant runner) or the repo's."""
    here = os.path.dirname(os.path.abspath(__file__))
    for p in (os.path.join(here, "g7-gas-campaign.yml"), os.path.join(here, "..", "..", ".github", "workflows", "g7-gas-campaign.yml")):
        if os.path.exists(p):
            return open(p).read()
    raise FileNotFoundError("g7-gas-campaign.yml")


class Universe(unittest.TestCase):
    """The workflow's `universe` input picks the spec (prereg/spec.json or site/spec.json) for the
    measure, the smoke and the report alike."""
    def test_universe_input_and_spec_branch(self):
        y = workflow_text()
        self.assertIn("      universe:\n", y)
        self.assertIn("        options: [prereg, site]\n", y)
        self.assertIn("        default: prereg\n", y)
        # mutant (yml): the site branch of the run step removed (the site universe would measure spec.json)
        run, report = y.split("      - name: Join and report")
        self.assertEqual(run.count('[ "$UNIVERSE" = site ] && SPEC="$D/site/spec.json"'), 1)
        self.assertIn('measure "$SPEC" "$D/state"', run)
        self.assertIn('smoke "$SPEC" "$D/state"', run)
        self.assertNotIn('"$D/spec.json" "$D/state"', run)
        # mutant (yml): the report takes spec.json whatever the universe (liq_usd and strata of the wrong spec)
        self.assertEqual(report.count('[ "$UNIVERSE" = site ] && SPEC="$D/site/spec.json"'), 1)
        self.assertIn('report "$SPEC" out/results.tsv', report)
        self.assertEqual(y.count("UNIVERSE: ${{ github.event_name == 'workflow_dispatch' && inputs.universe || 'prereg' }}"), 2)


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


USDC = "0x" + "f6" * 20  # 6 decimals, a stable of the site list
WETH = "0x" + "f1" * 20  # 18 decimals
POOL4 = "0x" + "b4" * 20


def drow(chain, idx, outcome="ok", **kw):
    r = {"chain": chain, "stratum": "s1", "kind": "pairs", "idx": idx, "b": 1000 + idx, "mode": "D", "tin": USDC,
         "tout": WETH, "amount_in": 5000000000, "outcome": outcome}
    r.update(kw)
    return r


class Detail(unittest.TestCase):
    """detail_lines (report section 8) over a small fixture: 2 chains, 1 SolverE noquote, RouterE
    with and without its code, a short_out row, a 6-decimal stable tin, a 2-hop split route."""
    ROWS = [
        # base 1: 5000 USDC in (tin stable) -> 1k-10k; 1 hop 1 leg; delivered == net_out (normal)
        drow("base", 1, hops=1, legs=1, legs_detail=f"{POOL1}:100000", g_exec=300000, g_legs_sum=100000,
             est_gas=280000, g_quote=900000, delivered=1000, net_out=1000),
        # base 2: WETH -> USDC, delivered 999.999999 USD (tout stable, ok) -> <1k; 2 hops 3 legs; short_out
        drow("base", 2, tin=WETH, tout=USDC, amount_in=10 ** 18, hops=2, legs=3,
             legs_detail=f"{POOL1}:50000;{POOL2}:60000;{V4_BASE}:70000", g_exec=400000, g_legs_sum=180000,
             est_gas=420000, g_quote=1100000, delivered=999999999, net_out=1000000000),
        # base 3: noquote SolverE(5); 1 USDC in: the bucket edge (1.0 is <1k, not dust)
        drow("base", 3, "noquote", amount_in=1000000, detail="0x3d0ccdde" + wd(5)),
        # base 4: RouterE with its code; base 5: a V2 revert string; both carry legs that must not count
        drow("base", 4, "revert", detail="RouterE:0x62b0a386" + wd(7), legs_detail=f"{POOL1}:777777"),
        drow("base", 5, "revert", detail="UniswapV2: TRANSFER_FAILED", legs_detail=f"{POOL1}:888888"),
        # optimism 6: unlisted tokens (unpriced, decimals unknown); 1 hop 2 legs; under-estimated
        drow("optimism", 6, tin=TOKEN, tout=WRAP, hops=1, legs=2, legs_detail=f"{POOL3}:90000;{POOL3}:60000",
             g_exec=250000, g_legs_sum=150000, est_gas=200000, g_quote=800000, delivered=5, net_out=5),
        drow("optimism", 7, "mf_unforced", tin=TOKEN, tout=WRAP),
        # optimism 8: RouterE whose code was not recorded (selector only)
        drow("optimism", 8, "revert", tin=TOKEN, tout=WRAP, detail="0x62b0a386"),
    ]

    @classmethod
    def lines(cls, rows=None):
        import copy
        import json
        d = tempfile.mkdtemp()
        uni, tok = os.path.join(d, "u.tsv"), os.path.join(d, "t.json")
        with open(uni, "w") as f:
            f.write("chain\tvenue\tkind\tpool\tadapter\n")
            f.write(f"base\t{UNIV3_BASE}\tv3\t{POOL1}\tx\nbase\t{UNIV3_BASE}\tv3\t{POOL2}\tx\nbase\t{V4_BASE}\tv4\t{POOL4}\tx\n")
        json.dump({"chains": {"base": {"tokens": [{"address": USDC, "symbol": "USDC", "decimals": 6},
                                                  {"address": WETH, "symbol": "WETH", "decimals": 18}]}}}, open(tok, "w"))
        rows = copy.deepcopy(rows or cls.ROWS)
        cols = set().union(*rows)
        for r in rows:  # a results.tsv row: every column present, absent cells empty
            for k in cols:
                r[k] = str(r.get(k, ""))
        return g7.detail_lines({"chains": {}}, rows, uni, tok)

    def sec(self, ls, num):
        return section(ls, [x for x in ls if x.startswith(f"# {num} ")][0])

    # Mutant "padding": the one-byte 0x81 pad dropped (`if (len(data) + 1) % 136 else` -> `if True else`).
    # Expected values from `cast keccak` / `cast sig` (foundry), not from g7.py.
    def test_keccak_matches_cast_at_the_padding_edges_and_the_src_selectors(self):
        self.assertEqual(g7.keccak256(b"").hex(), "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470")
        self.assertEqual(g7.keccak256(b"a" * 135).hex(), "34367dc248bbd832f4e3e69dfaac2f92638bd0bbd18f2912ba4ef454919cf446")
        self.assertEqual(g7.keccak256(b"a" * 136).hex(), "a6c4d403279fe3e0af03729caada8374b5ca54d8065329a3ebcaeb4b60aa386e")
        self.assertEqual(g7.ERR_BY_SEL, {"3d0ccdde": "SolverE", "765afc20": "QuoterE", "9a3fb915": "HubE", "62b0a386": "RouterE"})

    # Mutant "wilson centre": `z * z / (2 * n)` -> `z * z / n`; mutant "share": `if n < 100 else` -> `if True else`.
    def test_wilson_interval_and_share_only_below_100(self):
        self.assertEqual(g7.wilson(0, 10), ("0.0", "27.8"))  # 3.8416 / 13.8416
        self.assertEqual(g7.wilson(5, 10), ("23.7", "76.3"))
        self.assertEqual(g7.wilson(0, 0), ("", ""))
        self.assertEqual(g7.share(1, 4), ["25.0", "4.6", "69.9"])
        self.assertEqual(g7.share(50, 100), ["50.0", "", ""])

    # Mutant "8.1 not ok": the ok filter of the legs dropped (the revert rows add 777777 and 888888).
    def test_8_1_legs_by_kind_and_top_pools_over_ok_rows(self):
        ls = self.lines()
        a = self.sec(ls, "8.1a")
        self.assertIn("base\tv3\t3\t75.0\t30.1\t95.4\t3\t60000\t100000\t100000\t100000\trow:2", a)
        self.assertIn("base\tv4\t1\t25.0\t4.6\t69.9\t1\t70000\t70000\t70000\t70000\trow:3", a)
        self.assertIn("optimism\t?\t2\t100.0\t34.2\t100.0\t2\t60000\t90000\t90000\t90000\trow:7", a)
        c = self.sec(ls, "8.1c")
        self.assertEqual(c[0], f"base\t1\t{POOL1}\tUniswap V3\tv3\t2\t50.0\t1001\t1002\t50000\t100000\trow:2")
        d = self.sec(ls, "8.1d")
        self.assertIn(f"base\t1\t{USDC}\t{WETH}\t4\t1\t25.0\t4.6\t69.9\t1001\t1005", d)

    # Mutant "absent b is 0": `else ["", ""]` -> `else [0, 0]` (a fixture without b printed block 0).
    def test_8_1_block_range_skips_absent_b(self):
        self.assertEqual(g7.b_range([{"b": ""}, {"b": "7"}, {"b": "3"}, {}]), [3, 7])
        self.assertEqual(g7.b_range([{"b": ""}]), ["", ""])

    # Mutant "topology": `int(l) == int(h)` -> `!=` (single and split swap).
    def test_8_2_topology_hops_legs(self):
        c = self.sec(self.lines(), "8.2c")
        vals = {(x.split("\t")[0], x.split("\t")[1]): x.split("\t")[2] for x in c}
        self.assertEqual(vals, {("base", "(absent)"): "3", ("base", "1h-single"): "1", ("base", "2h-split"): "1",
                                ("optimism", "(absent)"): "2", ("optimism", "1h-split"): "1",
                                ("all", "(absent)"): "5", ("all", "1h-single"): "1", ("all", "1h-split"): "1",
                                ("all", "2h-split"): "1"})

    # Mutant "short_out at equality": `< int(r["net_out"])` -> `<=` (rows 1 and 6 deliver exactly net_out).
    def test_8_3_token_class_and_decimals(self):
        ls = self.lines()
        a = {tuple(x.split("\t")[:3]) for x in self.sec(ls, "8.3a")}
        self.assertTrue({("base", "normal", "1"), ("base", "short_out", "1"), ("optimism", "normal", "1"),
                         ("all", "normal", "2"), ("all", "short_out", "1")} <= a)
        b = {tuple(x.split("\t")[:3]) for x in self.sec(ls, "8.3b")}
        self.assertEqual(b, {("base", "non18", "5"), ("optimism", "unknown", "3"), ("all", "non18", "5"), ("all", "unknown", "3")})

    # Mutant "bucket edge": `if usd < hi` -> `<=` (1.0 USD becomes dust, 5000 stays 1k-10k).
    def test_8_4_usd_bucket_edges_and_basis(self):
        self.assertEqual([g7.usd_bucket(x) for x in (None, 0.999999, 1.0, 999.999999, 1000.0, 1e6)],
                         ["unpriced", "dust", "<1k", "<1k", "1k-10k", ">=1M"])
        ls = self.lines()
        a = {tuple(x.split("\t")[:3]) for x in self.sec(ls, "8.4a")}
        self.assertEqual(a, {("base", "1k-10k", "3"), ("base", "<1k", "2"), ("optimism", "unpriced", "3"),
                             ("all", "1k-10k", "3"), ("all", "<1k", "2"), ("all", "unpriced", "3")})
        b = {tuple(x.split("\t")[:3]) for x in self.sec(ls, "8.4b")}
        self.assertIn(("base", "tout_delivered", "1"), b)
        self.assertIn(("base", "tin", "4"), b)
        c = self.sec(ls, "8.4c")
        self.assertIn("base\t<1k\t1\t60000\t60000\t60000\t60000\trow:3", c)  # 180000 // 3
        self.assertIn("# 8.4d input per leg (volume share per DEX): no data (column leg_amt missing)", ls)

    # Mutant "selector": ERR_BY_SEL keyed on `[:3]` (no error of src decodes).
    def test_8_5_causes_decoded_with_their_code(self):
        ls = self.lines()
        b = [x.split("\t")[:6] for x in self.sec(ls, "8.5b")]
        self.assertIn(["base", "noquote", "SolverE", "SolverE(5)", "1", "row:4"], b)
        self.assertIn(["base", "revert", "RouterE", "RouterE(7)", "1", "row:5"], b)
        self.assertIn(["base", "revert", "revert", "UniswapV2: TRANSFER_FAILED", "1", "row:6"], b)
        self.assertIn(["optimism", "revert", "RouterE", "RouterE(code not recorded)", "1", "row:9"], b)
        self.assertIn(["optimism", "mf_unforced", "mf_unforced", "", "1", "row:8"], b)
        a = self.sec(ls, "8.5a")
        # ok noquote SolverE RouterE revert mf_unforced other, then ok pct with its Wilson interval
        self.assertIn("base\tpairs\t<1k\t2\t1\t0\t1\t0\t0\t0\t0\t50.0\t9.5\t90.5", a)

    # Mutant "max is min": `mx = max(vals)` -> `mx = min(vals)` (the max column and its row move).
    def test_8_6_gas_by_segment_and_estimate_delta(self):
        ls = self.lines()
        a = self.sec(ls, "8.6a")
        self.assertIn("base\tg_exec\t2\t300000\t400000\t400000\t400000\trow:3", a)
        self.assertIn("base\trouter_overhead\t2\t200000\t220000\t220000\t220000\trow:3", a)
        self.assertIn("base\twalk (g_solve)\t0\t\t\t\t\t", a)  # absent column: n 0, never a zero gas
        self.assertIn("all\tper_leg\t6\t60000\t100000\t100000\t100000\trow:2", a)
        b = self.sec(ls, "8.6b")
        # base: deltas +20000 (row 2), -20000 (row 3); optimism +50000
        self.assertIn("base\t2\t280000\t300000\t-20000\t20000\t20000\t20000\trow:2\t1\t50.0", b)
        self.assertIn("all\t3\t280000\t300000\t20000\t50000\t50000\t50000\trow:7\t2\t66.7", b)

    # Mutant "nodata dropped": the 8.7a no-data line replaced by [] (an absent column must say so).
    def test_8_7_absent_columns_say_no_data(self):
        ls = self.lines()
        self.assertIn("# 8.7a fallback to the runner-up (f82bc67): no data (column fb_used missing)", ls)
        self.assertIn("# 8.7b aged route executed at the current block (7, 10, 25 s): no data (column route_age_s missing)", ls)
        rows = [dict(r, fb_used="0", route_age_s="0") for r in self.ROWS]
        ls = self.lines(rows)
        self.assertFalse([x for x in ls if x.startswith("# 8.7")])

    # Mutant "8.3a title": the title gets its old `(measured: ...` back (the index cuts the name at the colon).
    def test_index_names_every_section_whole_with_its_line_count(self):
        ls = self.lines()
        i = ls.index("# 8.0 index: section\tdata_lines")
        idx = [x.split("\t") for x in ls[i + 1:]]
        hdrs = [x for x in ls[:i] if x.startswith("# ")]
        self.assertEqual([n for n, _ in idx], [h[2:h.index(": ")] for h in hdrs])
        self.assertTrue(all(h.count(":") == 1 for h in hdrs), [h for h in hdrs if h.count(":") != 1])
        for n, c in idx:
            self.assertEqual(len(section(ls[:i], [h for h in hdrs if h.startswith(f"# {n}: ")][0])), int(c), n)

if __name__ == "__main__":
    unittest.main()
