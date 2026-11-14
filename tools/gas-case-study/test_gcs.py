#!/usr/bin/env python3
"""Offline tests of the gas case study tools (unittest, stdlib only, no network, no forge).

  python3 -I tools/gas-case-study/test_gcs.py [-v] [Class.test_name]

stats.py: Wilson's interval at 0/n, n/n and n = 0 (absent, never zero) and against published
values; the bootstrap is reproducible by seed and covers a known median; the prefix reduction
N' in {8, 4, 2, 1}; the paired b - a per (cell_id, temp). abi.py: round trips of the struct
types the harness reads and writes, field order against hand-encoded words, keccak-256 against
`cast keccak` and `cast sig`. harness.py: its guards on a simulated RPC (a class with
call(method, params) whose answers are abi.encode'd): pv.route is the FIRST return value of
previewPlan, out_ours is the user's balanceOf delta, best_single's out is gross of the 28 bps fee,
the forced:HxL shapes, the prereg lock and grid parsing.
Each test is named in mutants_gcs.py with the mutant that turns it red.
"""
import hashlib
import os
import random
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
for _p in (HERE, os.path.join(HERE, "..", "g7-gas-campaign"), os.path.join(HERE, "..", "fuzz-coverage")):
    if _p not in sys.path:
        sys.path.insert(0, _p)
import abi  # noqa: E402
import harness  # noqa: E402
import prereg  # noqa: E402
import stats  # noqa: E402
from g7 import Reverted, RpcError, strip0x  # noqa: E402

MAXU = (1 << 256) - 1
TIN = "0x" + "11" * 20
TOUT = "0x" + "22" * 20
MID = "0x" + "33" * 20
QUOTER = "0x" + "a1" * 20
ROUTER = "0x" + "a2" * 20
HUB = "0x" + "a3" * 20
ZERO32 = "0x" + "00" * 32


def w(v):
    """One ABI word (two's complement for a negative v)."""
    return format(v % (1 << 256), "064x")


def a(x):
    return w(int(x, 16))


# ── builders ──
def mk_leg(pool, amount_in, kind=0, fee=3000, ts=60, z41=True, stable=False, out=0, hooks=None, aux=ZERO32):
    return dict(pool=pool, hooks=hooks or "0x" + "00" * 20, kind=kind, fee=fee, tickSpacing=ts, zeroForOne=z41,
                stable=stable, amountIn=amount_in, expectedOut=out, auxId=aux)


def mk_hop(tin, tout, amount_in, legs, out=0):
    return dict(tokenIn=tin, tokenOut=tout, amountIn=amount_in, expectedOut=out, legs=legs)


def mk_route(hops, total=0):
    return dict(hops=hops, totalOut=total, singleOut=0, singleOutFloor=0, expectedImpactBps=0, confidenceWad=0,
                estGas=0, hasSurplus=False, isV4Bundle=False)


def mk_preview(route, net_out, eff_min, can=True, est_gas=150000):
    return dict(route=route, grossOut=net_out, protocolFee=0, safetyBuffer=0, netOut=net_out, ironFloor=0,
                userMinOut=0, effectiveMinOut=eff_min, estGas=est_gas, hops=len(route["hops"]),
                legs=sum(len(h["legs"]) for h in route["hops"]), topology=0, bridgeUsed="0x" + "00" * 20,
                canExecute=can)


def mk_pool(pool, kind, active=True):
    return dict(active=active, stable=False, kind=kind, fee=500, tickSpacing=10, token0=TIN, token1=TOUT, pool=pool,
                hooks="0x" + "00" * 20)


ROUTE_A = mk_route([mk_hop(TIN, TOUT, 1000, [mk_leg("0x" + "b1" * 20, 1000)])])
ROUTE_B = mk_route([mk_hop(TIN, MID, 1000, [mk_leg("0x" + "b2" * 20, 1000)]),
                    mk_hop(MID, TOUT, 0, [mk_leg("0x" + "b3" * 20, 0)])])


class FakeNode:
    """The simulated RPC: eth_call answers by (to, selector); balances live in a dict; a tx to the
    Router runs on_send(tx). Anything not scripted is an RpcError (absent, never a zero)."""

    def __init__(self, ts=1_700_000_000):
        self.ts, self.answers, self.bal, self.sent = ts, {}, {}, []
        self.on_send, self.revert_ok, self.gas, self.snaps = None, True, 123456, 0

    def call(self, method, params):
        if method == "eth_getBlockByNumber":
            return {"timestamp": hex(self.ts)}
        if method == "eth_call":
            to, d = params[0]["to"].lower(), strip0x(params[0]["data"])
            if d[:8] == harness.fn("balanceOf"):
                return "0x" + w(self.bal.get((to, "0x" + d[32:72]), 0))
            h = self.answers.get((to, d[:8]))
            if h is None:
                raise RpcError(f"unscripted eth_call {to} {d[:8]}")
            if isinstance(h, Exception):
                raise h
            return h(d) if callable(h) else h
        if method == "eth_estimateGas":
            return hex(100000)
        if method == "eth_sendTransaction":
            tx = params[0]
            self.sent.append(tx)
            if tx["to"].lower() == ROUTER and self.on_send:
                self.on_send(tx)
            return "0x" + "ee" * 32
        if method == "eth_getTransactionReceipt":
            return {"status": "0x1", "gasUsed": hex(self.gas), "logs": []}
        if method == "anvil_dealERC20":
            self.bal[(params[0].lower(), params[1].lower())] = int(params[2], 16)
            return None
        if method in ("anvil_impersonateAccount", "anvil_setBalance"):
            return None
        if method == "evm_snapshot":
            self.snaps += 1
            return hex(self.snaps)
        if method == "evm_revert":
            return self.revert_ok
        raise RpcError(f"unscripted {method}")

    def router_txs(self):
        return [t for t in self.sent if t["to"].lower() == ROUTER]


def session(node, chain="ethereum", consts=None):
    c = {"WNATIVE_" + chain.upper(): "0x" + "44" * 20}
    c.update(consts or {})
    return harness.Session(node, None, chain, dict(quoter=QUOTER, router=ROUTER, hub=HUB), 100, c)


def args_of(name, data):
    return abi.decode(harness.ARGS[name], strip0x(data)[8:])


# ═════════════════════════════ stats.py ═════════════════════════════
class Wilson(unittest.TestCase):
    def test_zero_successes_lo_is_exactly_zero(self):
        # without the boundary rule, 0/7 gives lo = 5.55e-17 in floating point (0/10 happens to give 0.0)
        for n in (1, 3, 7, 10, 20):
            self.assertEqual(stats.wilson(0, n)[0], 0.0, n)
        self.assertAlmostEqual(stats.wilson(0, 10)[1], 0.2775328, places=6)  # z^2/(n+z^2)

    def test_all_successes_hi_is_exactly_one(self):
        # without the boundary rule, 10/10 gives hi = 0.9999999999999999
        for n in (1, 3, 7, 10, 20):
            self.assertEqual(stats.wilson(n, n)[1], 1.0, n)
        self.assertAlmostEqual(stats.wilson(10, 10)[0], 1 - 0.2775328, places=6)

    def test_n_zero_is_absent_not_zero(self):
        self.assertIsNone(stats.wilson(0, 0))
        r = stats.rate_row("base", "s", "revert_rate", 0, 0, "")
        self.assertEqual((r["n"], r["median"], r["ci95_lo"], r["ci95_hi"]), (0, "", "", ""))

    def test_reference_values_newcombe_1998(self):
        # Newcombe, Stat Med 17:857-872 (1998), table I, method 3 (score, no continuity correction)
        ref = {(81, 263): (0.2553, 0.3662), (15, 148): (0.0624, 0.1605), (0, 20): (0.0, 0.1611),
               (1, 29): (0.0061, 0.1718), (5, 10): (0.2366, 0.7634)}
        for (k, n), (lo, hi) in ref.items():
            got = stats.wilson(k, n)
            self.assertAlmostEqual(got[0], lo, places=4, msg=(k, n))
            self.assertAlmostEqual(got[1], hi, places=4, msg=(k, n))

    def test_k_outside_0_n_is_refused(self):
        for k, n in ((11, 10), (-1, 10), (2, 1)):
            with self.assertRaisesRegex(ValueError, "outside"):  # not math.sqrt's domain error
                stats.wilson(k, n)


class Bootstrap(unittest.TestCase):
    VALS = (lambda rng: [rng.uniform(100, 200) for _ in range(25)])(random.Random(7))

    def test_same_seed_same_interval_other_seed_differs(self):
        # B = 9: the ends move with the draws, so an unseeded stream would not repeat 5 times
        a1 = stats.bootstrap_ci(self.VALS, 1, b=9)
        for _ in range(4):
            self.assertEqual(a1, stats.bootstrap_ci(self.VALS, 1, b=9))
        self.assertNotEqual(a1, stats.bootstrap_ci(self.VALS, 2, b=9))

    def test_covers_a_known_median(self):
        # Uniform(0, 1): true median 0.5; 200 samples of n = 31, B = 400. Nominal 95%.
        hit = 0
        for t in range(200):
            rng = random.Random(1000 + t)
            lo, hi = stats.bootstrap_ci([rng.random() for _ in range(31)], t, b=400)
            hit += lo <= 0.5 <= hi
        self.assertGreaterEqual(hit, 176)  # >= 88%
        self.assertLessEqual(hit, 199)

    def test_ends_are_the_two_tails(self):
        lo, hi = stats.bootstrap_ci(self.VALS, 3, b=300)
        self.assertLess(lo, stats.median(self.VALS))
        self.assertGreater(hi, stats.median(self.VALS))

    def test_empty_is_absent_not_zero(self):
        self.assertIsNone(stats.bootstrap_ci([], 1))
        r = stats.summarize("base", "s", "gas_real", [], 1, b=10)
        self.assertEqual((r["n"], r["median"], r["p5"], r["ci95_lo"]), (0, "", "", ""))

    def test_seed_default_is_sha256_of_the_tag_and_const_is_mod_2_32(self):
        self.assertEqual(stats.boot_seed(), int(hashlib.sha256(b"gas-1114-boot").hexdigest(), 16) % 2 ** 32)
        self.assertEqual(stats.boot_seed("0xffffffff"), 0xFFFFFFFF)
        self.assertEqual(stats.boot_seed("0x100000001"), 1)
        self.assertEqual(stats.boot_seed("17"), 17)


class Reduce(unittest.TestCase):
    ROWS = [dict(i=str(i)) for i in range(10)]

    def test_prefix_keeps_i_below_nprime(self):
        for nprime in (8, 4, 2, 1):
            kept = stats.reduce_prefix(self.ROWS, nprime)
            self.assertEqual([int(r["i"]) for r in kept], list(range(nprime)))

    def test_other_nprime_is_refused(self):
        for bad in (0, 3, 5, 16, -1):
            with self.assertRaises(ValueError):
                stats.reduce_prefix(self.ROWS, bad)

    def test_cell_index_from_the_cell_id_tail(self):
        rows = stats.cell_index([dict(cell_id="base-weth-usdc-100-3", i=""), dict(cell_id="c/12", i=""),
                                 dict(cell_id="x-y", i="5")])
        self.assertEqual([r["i"] for r in rows], [3, 12, "5"])


def prow(cell, temp, mode, status="ok", gas="", out=""):
    return dict(cell_id=cell, temp=temp, mode=mode, status=status, gas_real=gas, out_ours=out)


class Paired(unittest.TestCase):
    def test_b_minus_a_per_cell(self):
        rows = [prow("c0", "cold", "quoted", gas="100"), prow("c0", "cold", "onchain", gas="130")]
        out, dropped = stats.paired(rows, "quoted", "onchain", "gas_real")
        self.assertEqual((out, dropped), ([("c0/cold", 30)], 0))

    def test_pairs_by_cell_and_temperature(self):
        rows = [prow("c0", "cold", "quoted", gas="100"), prow("c0", "warm", "quoted", gas="60"),
                prow("c0", "warm", "onchain", gas="70"), prow("c0", "cold", "onchain", gas="150")]
        out, _ = stats.paired(rows, "quoted", "onchain", "gas_real")
        self.assertEqual(out, [("c0/cold", 50), ("c0/warm", 10)])

    def test_unpaired_or_not_ok_are_dropped_and_counted(self):
        rows = [prow("c0", "cold", "quoted", gas="100"),  # no onchain row
                prow("c1", "cold", "quoted", gas="100"), prow("c1", "cold", "onchain", status="revert:mined", gas="90"),
                prow("c2", "cold", "quoted", gas=""), prow("c2", "cold", "onchain", gas="90"),  # absent value
                prow("c3", "cold", "quoted", gas="1"), prow("c3", "cold", "onchain", gas=str(MAXU))]
        out, dropped = stats.paired(rows, "quoted", "onchain", "gas_real")
        self.assertEqual(out, [("c3/cold", MAXU - 1)])
        self.assertEqual(dropped, 3)


class Run(unittest.TestCase):
    def test_revert_rate_counts_reverts_only_and_absent_metric_is_empty(self):
        cols = "chain cell_id pair size_usd mode temp status gas_real gas_est out_ours i".split()
        rows = [["base", "c0", "p", "100", "quoted", "cold", "ok", "100", "90", "5", "0"],
                ["base", "c1", "p", "100", "quoted", "cold", "revert:0x62b0a386", "", "", "", "1"],
                ["base", "c2", "p", "100", "quoted", "cold", "noquote", "", "", "", "2"],
                ["base", "c3", "q", "1", "quoted", "cold", "revert:mined", "", "", "", "0"]]
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "results.tsv")
            with open(p, "w") as f:
                f.write("\n".join("\t".join(r) for r in [cols] + rows) + "\n")
            st = stats.run(p, os.path.join(d, "stats.tsv"), 1, b=20)
            self.assertTrue(os.path.exists(os.path.join(d, "worst.tsv")))
        by = {(r["stratum"], r["metric"]): r for r in st}
        rr = by[("p|100|quoted|cold", "revert_rate")]
        self.assertEqual((rr["n"], rr["median"]), (3, 1 / 3))
        g = by[("q|1|quoted|cold", "gas_real")]
        self.assertEqual((g["n"], g["median"], g["ci95_lo"]), (0, "", ""))


# ═════════════════════════════ abi.py ═════════════════════════════
class Keccak(unittest.TestCase):
    # `cast keccak` (foundry) on the same bytes
    def test_empty_string(self):
        self.assertEqual(abi.keccak256(b"").hex(), "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470")

    def test_rate_edges_135_136_271_272(self):
        ref = {135: "34367dc248bbd832f4e3e69dfaac2f92638bd0bbd18f2912ba4ef454919cf446",
               136: "a6c4d403279fe3e0af03729caada8374b5ca54d8065329a3ebcaeb4b60aa386e",
               271: "132f47effd6c8b1b299efa53fe68aece77ec8ae4eb2e294f668eec94f76001e1",
               272: "cf7fcd4f705ee749930d19ca84561a9bf62516bd90a471545fa2f49fdc7e63c8"}
        for n, h in ref.items():
            self.assertEqual(abi.keccak256(b"a" * n).hex(), h, n)

    def test_public_selector_transfer(self):
        self.assertEqual(abi.selector("transfer(address,uint256)"), "a9059cbb")
        self.assertEqual(abi.selector("balanceOf(address)"), "70a08231")

    def test_calldata_is_selector_then_words(self):
        to = "0x" + "ab" * 20
        self.assertEqual(abi.calldata("0xa9059cbb", ["address", "uint256"], [to, 1]), "0xa9059cbb" + a(to) + w(1))
        self.assertEqual(abi.calldata("a9059cbb", ["uint256"], [MAXU]), "0xa9059cbb" + "f" * 64)


class Codec(unittest.TestCase):
    LEG = mk_leg("0x" + "c1" * 20, 7, kind=1, fee=500, ts=-10, z41=True, stable=False, out=9,
                 hooks="0x" + "c2" * 20, aux="0x" + "0d" * 32)
    LEG_WORDS = [a("0x" + "c1" * 20), a("0x" + "c2" * 20), w(1), w(500), w(-10), w(1), w(0), w(7), w(9), "0d" * 32]

    def test_leg_field_order_against_hand_encoded_words(self):
        self.assertEqual(abi.encode([abi.LEG], [self.LEG]), "".join(self.LEG_WORDS))
        self.assertEqual(abi.decode([abi.LEG], "".join(self.LEG_WORDS))[0], self.LEG)

    def test_hop_offsets_against_hand_encoding(self):
        h = mk_hop(TIN, TOUT, 7, [self.LEG], out=5)
        hand = [w(0x20), a(TIN), a(TOUT), w(7), w(5), w(5 * 32), w(1)] + self.LEG_WORDS
        self.assertEqual(abi.encode([abi.HOP], [h]), "".join(hand))

    def test_roundtrip_preview_plan_out(self):
        big = mk_leg("0x" + "ff" * 20, MAXU, kind=255, fee=(1 << 24) - 1, ts=-(1 << 23), stable=True, out=MAXU)
        small = mk_leg("0x" + "01" * 20, 1, kind=0, fee=0, ts=(1 << 23) - 1, z41=False, out=0)
        r = mk_route([mk_hop(TIN, MID, MAXU, [big, small]), mk_hop(MID, TOUT, 1, [small])], total=MAXU)
        pv = mk_preview(r, 1, MAXU)
        vals = [pv, mk_route([]), True]
        try:
            back = abi.decode(abi.PREVIEW_PLAN_OUT, abi.encode(abi.PREVIEW_PLAN_OUT, vals))
        except (ValueError, IndexError) as e:  # an undecodable blob is a failed round trip
            self.fail(f"round trip does not decode: {e}")
        self.assertEqual(back, vals)
        pools = [mk_pool("0x" + "c1" * 20, 0), mk_pool("0x" + "c2" * 20, 9, active=False)]
        t = [("array", abi.POOLINFO)]
        self.assertEqual(abi.decode(t, abi.encode(t, [pools])), [pools])
        self.assertEqual(abi.decode(t, abi.encode(t, [[]])), [[]])

    def test_uint256_range_is_refused(self):
        self.assertEqual(abi.encode(["uint256"], [MAXU]), "f" * 64)
        self.assertEqual(abi.encode(["uint256"], [0]), "0" * 64)
        for bad in (MAXU + 1, -1):
            with self.assertRaises(ValueError):
                abi.encode(["uint256"], [bad])

    def test_signed_decode_at_the_sign_bit(self):
        self.assertEqual(abi.decode(["int24"], w((1 << 23) - 1)), [(1 << 23) - 1])
        self.assertEqual(abi.decode(["int24"], w(1 << 23)), [-(1 << 23)])
        self.assertEqual(abi.decode(["int24"], w(-1)), [-1])
        self.assertEqual(abi.decode(["int256"], w(1 << 255)), [-(1 << 255)])
        self.assertEqual(abi.decode(["int256"], w((1 << 255) - 1)), [(1 << 255) - 1])

    def test_bytes_length_and_padding(self):
        for n, words in ((0, 2), (1, 3), (32, 3), (33, 4)):
            v = "0x" + "ab" * n
            enc = abi.encode(["bytes"], [v])
            self.assertEqual(len(enc), 64 * words, n)
            self.assertEqual(abi.decode(["bytes"], enc), [v], n)

    @unittest.expectedFailure
    def test_narrow_types_out_of_range_are_refused(self):
        # abi.py:_base_enc checks only 0 <= v < 2^256: a uint8 of 256, a uint24 of 2^24, an int24
        # of 2^23 and a 161-bit address are encoded instead of refused (calldata the Router's
        # decoder would revert on). Recorded in SA2d-tests.md; abi.py is not edited here.
        for t, v in (("uint8", 256), ("uint24", 1 << 24), ("int24", 1 << 23), ("address", "0x1" + "00" * 20)):
            with self.assertRaises(ValueError, msg=t):
                abi.encode([t], [v])


# ═════════════════════════════ harness.py ═════════════════════════════
class Selectors(unittest.TestCase):
    # `cast sig` on harness.sig(name), foundry, 2026-11-14
    CAST = dict(previewPlan="49d5f197", previewRouteExact="3f0c8c2c", swapExactIn="36457c51",
                swapBestExactIn="d631c8e7", swapExactInNative="a6a9fa25", discoverFor="4d400985", bridge="d80b21d7",
                balanceOf="70a08231", approve="095ea7b3", decimals="313ce567", weth="3fc8cef3",
                getL1Fee="49948e0e", gasEstimateL1Component="77d488a2", RouterE="62b0a386")

    def test_selectors_against_cast_sig(self):
        for name, sel in self.CAST.items():
            self.assertEqual(harness.fn(name), sel, name)
        self.assertEqual(harness.topic(harness.SWAP_EVENT),
                         "0xd6d34547c69c5ee3d2667625c188acf1006abb93e0ee7cf03925c67cf7760413")

    def test_err_class(self):
        re_ = "0x62b0a386"
        self.assertEqual(harness.err_class(re_ + w(5)), "minOut")
        self.assertEqual(harness.err_class(re_ + w(4)), "deadline")
        self.assertEqual(harness.err_class(re_ + w(8)), "RouterE(8)")
        self.assertEqual(harness.err_class("0x4e487b71" + w(0x11)), "Panic(17)")
        self.assertEqual(harness.err_class("0x"), "empty")
        self.assertEqual(harness.err_class(None), "empty")
        self.assertEqual(harness.err_class("0x08c379a0" + abi.encode(["bytes"], ["0x" + b"STF".hex()])), "Error:STF")


class Shapes(unittest.TestCase):
    def test_forced_shapes_and_their_edges(self):
        want = {(1, 0): None, (1, 1): (1, 0), (1, 5): (5, 0), (1, 6): None, (2, 1): None, (2, 2): (1, 1),
                (2, 3): (2, 1), (2, 10): (5, 5), (2, 11): None, (3, 3): None}
        for (h, n), sh in want.items():
            self.assertEqual(harness.shape_legs(h, n), sh, (h, n))
        forced = [m for m in harness.MODES if m.startswith("forced:")]
        self.assertEqual(forced, [f"forced:1x{n}" for n in range(1, 6)] + [f"forced:2x{n}" for n in range(2, 11)])

    def test_split_sums_to_the_amount(self):
        self.assertEqual(harness.split(10, 3), [3, 3, 4])
        self.assertEqual(harness.split(1, 1), [1])
        self.assertEqual(harness.split(4, 5), [0, 0, 0, 0, 4])  # dust: zero legs, measured as they revert
        for amt, n in ((MAXU, 5), (MAXU, 1), (10 ** 18 + 1, 10)):
            self.assertEqual(sum(harness.split(amt, n)), amt)


class Prereg(unittest.TestCase):
    def write(self, d, body, lock=None):
        p = os.path.join(d, "g.tsv")
        with open(p, "w") as f:
            f.write(body + "lock\t" + (lock or prereg.lock_of(body)) + "\n")
        return p

    def test_bad_lock_is_refused(self):
        body = "tag\tgas-1114\ncell\tbase\tc-0\tp\t%s\t%s\t1000\t100\t7\n" % (TIN, TOUT)
        with tempfile.TemporaryDirectory() as d:
            p = self.write(d, body, lock="0" * 64)
            with self.assertRaises(harness.PreregError):
                harness.read_prereg(p)
            self.assertEqual(len(harness.read_prereg(p, allow_unlocked=True)["rows"]), 1)
            self.assertEqual(len(harness.read_prereg(self.write(d, body))["rows"]), 1)

    def test_tsv_with_a_header(self):
        body = ("chain\tcell_id\tpair\ttoken_in\ttoken_out\tamount_in\tsize_usd\tseed\tblock\n"
                f"base\tb-0\tp\t{TIN}\t{TOUT}\t1\t1\t0\t500\n"
                f"optimism\to-0\tp\t{TIN}\t{TOUT}\t{MAXU}\t1\t0\t600\n")
        with tempfile.TemporaryDirectory() as d:
            g = harness.read_prereg(self.write(d, body), chain="base")
        self.assertEqual([(r["cell_id"], r["amount_in"], r["i"]) for r in g["rows"]], [("b-0", "1", 0)])
        self.assertEqual(harness.block_of(g, "base"), 500)

    def test_tagged_rows_follow_cols(self):
        cols = ["chain", "cell_id", "pair", "token_out", "token_in", "amount_in", "size_usd", "seed"]
        body = ("const\tBLOCK_BASE\t777\nmode\tquoted\tonchain\ncols\t" + "\t".join(cols) + "\n"
                f"cell\tbase\tc-0\tp\t{TOUT}\t{TIN}\t1000\t100\t7\n")
        with tempfile.TemporaryDirectory() as d:
            g = harness.read_prereg(self.write(d, body))
        r = g["rows"][0]
        self.assertEqual((r["token_in"], r["token_out"], r["_line"]), (TIN, TOUT, 4))
        self.assertEqual((g["modes"], g["consts"]), (["quoted", "onchain"], {"BLOCK_BASE": "777"}))
        self.assertEqual(harness.block_of(g, "base"), 777)

    def test_amount_in_must_be_a_positive_integer_in_wei(self):
        with tempfile.TemporaryDirectory() as d:
            for bad in ("0", "1.5", "1e18", "-1", "0x10", " 1"):
                body = f"cell\tbase\tc-0\tp\t{TIN}\t{TOUT}\t{bad}\t100\t7\n"
                with self.assertRaises(harness.PreregError, msg=bad):
                    harness.read_prereg(self.write(d, body))
            for good in ("1", str(MAXU)):
                body = f"cell\tbase\tc-0\tp\t{TIN}\t{TOUT}\t{good}\t100\t7\n"
                self.assertEqual(harness.read_prereg(self.write(d, body))["rows"][0]["amount_in"], good)

    def test_i_is_the_ordinal_within_chain_pair_size(self):
        cells = [("base", "p", "100"), ("base", "p", "100"), ("base", "q", "100"), ("base", "p", "1"),
                 ("base", "p", "100"), ("optimism", "p", "100")]
        body = "".join(f"cell\t{c}\tx-{k}\t{p}\t{TIN}\t{TOUT}\t1\t{s}\t0\n" for k, (c, p, s) in enumerate(cells))
        with tempfile.TemporaryDirectory() as d:
            g = harness.read_prereg(self.write(d, body))
        self.assertEqual([r["i"] for r in g["rows"]], [0, 1, 0, 0, 2, 0])

    def test_two_fork_blocks_are_refused(self):
        g = dict(consts={}, rows=[dict(block="1"), dict(block="2")])
        with self.assertRaises(harness.PreregError):
            harness.block_of(g, "base")


def preview_answer(node, pv, fallback=ROUTE_B):
    node.answers[(QUOTER, harness.fn("previewPlan"))] = "0x" + abi.encode(abi.PREVIEW_PLAN_OUT, [pv, fallback, True])


CELL = dict(chain="ethereum", cell_id="e-0", pair="p", token_in=TIN, token_out=TOUT, amount_in="1000", size_usd="1",
            seed="0")


class Guards(unittest.TestCase):
    def test_quote_takes_pv_route_the_first_return_value(self):
        n = FakeNode()
        preview_answer(n, mk_preview(ROUTE_A, 990, 980))
        pv, err = session(n).quote(TIN, TOUT, 1000)
        self.assertIsNone(err)
        self.assertEqual(pv["route"], ROUTE_A)

    def test_quote_revert_is_classified_not_zero(self):
        n = FakeNode()
        n.answers[(QUOTER, harness.fn("previewPlan"))] = Reverted("0x62b0a386" + w(8))
        self.assertEqual(session(n).quote(TIN, TOUT, 1000), (None, "RouterE(8)"))

    def test_quoted_sends_pv_route_and_effective_min_out(self):
        n = FakeNode()
        preview_answer(n, mk_preview(ROUTE_A, 990, 980))
        session(n).measure(CELL, "quoted")
        txs = n.router_txs()
        self.assertEqual(len(txs), 2)  # cold, warm
        route, amt, min_out, user, _ = args_of("swapExactIn", txs[0]["data"])
        self.assertEqual((route, amt, min_out, user), (ROUTE_A, 1000, 980, harness.USER.lower()))

    def test_out_ours_is_the_balance_delta_not_the_quote(self):
        n = FakeNode()
        preview_answer(n, mk_preview(ROUTE_A, 990, 980))
        n.bal[(TOUT, harness.USER.lower())] = 5000  # tokenOut already held: a level is not a delta

        def deliver(tx):
            n.bal[(TOUT, harness.USER.lower())] += 977

        n.on_send = deliver
        rows, timing = session(n).measure(CELL, "quoted")
        self.assertEqual([(r["temp"], r["status"], r["out_ours"], r["gas_real"]) for r in rows],
                         [("cold", "ok", 977, 123456), ("warm", "ok", 977, 123456)])
        self.assertEqual(len(timing), 2)

    def test_cannot_execute_is_noroute_and_nothing_is_sent(self):
        n = FakeNode()
        preview_answer(n, mk_preview(ROUTE_A, 990, 980, can=False))
        n.on_send = lambda tx: None
        rows, _ = session(n).measure(CELL, "quoted")
        self.assertEqual([r["status"] for r in rows], ["noroute"])
        self.assertEqual(n.router_txs(), [])

    def test_forced_shape_absent_by_code_is_a_reason_not_a_row(self):
        n = FakeNode()
        s = session(n)
        self.assertEqual(s.measure(CELL, "forced:1x6"), ([], []))
        self.assertEqual(s.absent, [dict(chain="ethereum", cell_id="e-0", mode="forced:1x6", reason="absent_by_code")])

    def test_topology_is_the_bridge_slot_or_absent(self):
        n = FakeNode()
        slots = ["0x" + "55" * 20, MID, "0x" + "00" * 20]
        n.answers[(HUB, harness.fn("bridge"))] = lambda d: "0x" + a(slots[int(d[8:72], 16)])
        s = session(n)
        self.assertEqual(s.topology(ROUTE_A), 0)
        self.assertEqual(s.topology(ROUTE_B), 2)
        other = mk_route([mk_hop(TIN, "0x" + "66" * 20, 1, []), mk_hop("0x" + "66" * 20, TOUT, 1, [])])
        self.assertEqual(s.topology(other), "")

    def test_refused_evm_revert_raises(self):
        n = FakeNode()
        n.revert_ok = False
        with self.assertRaises(RpcError):
            session(n).revert("0x1")

    def test_best_single_out_is_gross_of_the_28_bps_fee(self):
        # out = out_router * 10000 // (10000 - 28): 9972 -> 10000, 9971 -> 9998 (floor), 1 -> 1, 2^255 -> 2^255*10000//9972
        got = {"0x" + "d1" * 20: 9972, "0x" + "d2" * 20: 9971, "0x" + "d3" * 20: 1, "0x" + "d4" * 20: 1 << 255}
        ext = "0x" + "d5" * 20
        pools = [mk_pool(p, 0) for p in got] + [mk_pool(ext, harness.KIND_EXTERNAL)]
        n = FakeNode()
        n.answers[(HUB, harness.fn("discoverFor"))] = "0x" + abi.encode([("array", abi.POOLINFO)], [pools])

        def exact(d):
            r = abi.decode(harness.ARGS["previewRouteExact"], d[8:])[0]
            p = r["hops"][0]["legs"][0]["pool"]
            return "0x" + abi.encode(abi.ROUTE_EXACT_OUT, [r, 0 if p == ext else 1])

        def deliver(tx):
            p = args_of("swapExactIn", tx["data"])[0]["hops"][0]["legs"][0]["pool"]
            n.bal[(TOUT, harness.USER.lower())] = n.bal.get((TOUT, harness.USER.lower()), 0) + got[p]

        n.answers[(QUOTER, harness.fn("previewRouteExact"))] = exact
        n.on_send = deliver
        rows, best = session(n).best_single(CELL)
        by = {r["pool"]: r for r in rows}
        for p, g in got.items():
            self.assertEqual((by[p]["status"], by[p]["out_router"], by[p]["out"]), ("ok", g, g * 10000 // 9972), p)
        self.assertEqual((by["0x" + "d1" * 20]["out"], by["0x" + "d2" * 20]["out"], by["0x" + "d3" * 20]["out"]),
                         (10000, 9998, 1))
        self.assertEqual(by[ext]["status"], "quoted_zero_by_view_port")
        self.assertEqual(best["pool"], "0x" + "d4" * 20)


if __name__ == "__main__":
    unittest.main()
