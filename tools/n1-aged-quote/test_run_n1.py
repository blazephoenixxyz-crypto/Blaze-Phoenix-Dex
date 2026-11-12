#!/usr/bin/env python3
"""Offline tests for run_n1.py (no RPC). Run: python3 -I tools/n1-aged-quote/test_run_n1.py

Each test names the mutant of run_n1.py that turns it red.
"""
import math
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import run_n1 as r  # noqa: E402

P = dict(p0=0.01, p1=0.05, alpha=0.05, beta=0.05)


def bump(n):
    return format(n, "064x")


class Sprt(unittest.TestCase):
    # Mutant: swap the H0/H1 thresholds, or drop the (n - fails) term.
    def test_zero_failures_accepts_h0_exactly_at_72(self):
        self.assertEqual(r.sprt_state(0, 71, **P), "cont")
        self.assertEqual(r.sprt_state(0, 72, **P), "H0")

    # Mutant: log(p1/p0) replaced by log(p0/p1).
    def test_two_early_failures_accept_h1(self):
        self.assertEqual(r.sprt_state(2, 2, **P), "H1")
        self.assertEqual(r.sprt_state(1, 1, **P), "cont")

    # Boundary: the smallest n with 2 failures that accepts H0 (derived: 152).
    def test_two_failures_boundary(self):
        self.assertEqual(r.sprt_state(2, 151, **P), "cont")
        self.assertEqual(r.sprt_state(2, 152, **P), "H0")

    # Gamma: 4 failures never reach H0 within n_max = 200 -> "not measured" territory.
    def test_four_failures_undecided_at_nmax(self):
        self.assertEqual(r.sprt_state(4, 200, **P), "cont")


class ClopperPearson(unittest.TestCase):
    # Mutant: lower bound solved against 1 - a/2 replaced by a/2.
    def test_known_values(self):
        lo, hi = r.clopper_pearson(0, 72)
        self.assertEqual(lo, 0.0)
        self.assertAlmostEqual(hi, 1 - 0.025 ** (1 / 72), places=6)
        lo, hi = r.clopper_pearson(10, 10)
        self.assertAlmostEqual(lo, 0.025 ** (1 / 10), places=6)
        self.assertEqual(hi, 1.0)

    def test_interval_contains_point_estimate(self):
        for k, n in [(1, 50), (3, 100), (7, 200), (199, 200)]:
            lo, hi = r.clopper_pearson(k, n)
            self.assertLess(lo, k / n)
            self.assertGreater(hi, k / n)


class Abi(unittest.TestCase):
    # Mutant: read effectiveMinOut from field 6 (userMinOut) or canExecute from field 12.
    def test_decode_preview_fields(self):
        call = "ab" * 37
        pv_words = [0] * 14
        pv_words[0] = 14 * 32  # route offset (content irrelevant to the decoder)
        pv_words[4], pv_words[6], pv_words[7], pv_words[13] = 900, 1, 850, 1
        pv = "".join(bump(x) for x in pv_words) + bump(0)
        head = bump(64) + bump(64 + len(pv) // 2)
        body = pv + bump(37) + call + "0" * (64 - (74 % 64))
        out = r.decode_preview("0x" + head + body)
        self.assertEqual(out["netOut"], 900)
        self.assertEqual(out["effectiveMinOut"], 850)
        self.assertTrue(out["canExecute"])
        self.assertEqual(out["call"], call)

    # Mutant: wrong bytes offset (5*32) in encode_run, or no right-padding.
    def test_encode_run_layout(self):
        a = "0x" + "11" * 20
        data = r.encode_run(a, a, a, 7, True, "cd" * 33)
        d = data[2:]
        self.assertEqual(d[:8], r.SEL_RUN)
        body = d[8:]
        self.assertEqual(r.word(body, 5), 6 * 32)
        self.assertEqual(r.word(body, 6), 33)
        self.assertEqual(len(body) % 64, 0)
        self.assertEqual(r.word(body, 4), 1)

    # Mutant: decode_run returns word 4 as delivered.
    def test_decode_run(self):
        ret = "62b0a386" + bump(5)
        n = len(ret) // 2
        enc = bump(0) + bump(5 * 32) + bump(123) + bump(456) + bump(0) + bump(n) + ret + "0" * (64 - len(ret) % 64)
        ok, got, delivered, gas, rr = r.decode_run("0x" + enc)
        self.assertFalse(ok)
        self.assertEqual(got, ret)
        self.assertEqual((delivered, gas, rr), (123, 456, 0))


class Sampling(unittest.TestCase):
    # Mutant: rng seeded without the stratum id (all strata draw the same blocks).
    def test_strata_streams_are_distinct_and_reproducible(self):
        a = [r.stratum_rng("0xabc", "base/small/recent").randint(0, 10**9) for _ in range(1)]
        b = [r.stratum_rng("0xabc", "base/small/stress").randint(0, 10**9) for _ in range(1)]
        c = [r.stratum_rng("0xabc", "base/small/recent").randint(0, 10**9) for _ in range(1)]
        self.assertNotEqual(a, b)
        self.assertEqual(a, c)


if __name__ == "__main__":
    unittest.main()
