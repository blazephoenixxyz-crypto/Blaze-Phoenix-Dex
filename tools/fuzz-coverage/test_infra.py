#!/usr/bin/env python3
"""Tests of the fuzz-matrix infrastructure: the matrix, the pre-registrations and the anvil
comparison. Every test here is the guard of a named meta-mutant in meta_mutants.py, which
proves the test can go red (a guard that cannot fire is worse than none).

  python3 -m unittest tools/fuzz-coverage/test_infra.py      (from the repo root)
  python3 tools/fuzz-coverage/meta_mutants.py                (baseline green, each mutant red)
"""
import os
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, HERE)

import anvil_compare  # noqa: E402
import matrix_check  # noqa: E402
import prereg  # noqa: E402

MC = os.path.join(ROOT, "docs", "prereg", "mc-1113.tsv")
WF = os.path.join(ROOT, "docs", "prereg", "wf-1113.tsv")


class Matrix(unittest.TestCase):
    """docs/assurance/fuzz-matrix: every declared cell is present and names a real test."""

    def test_matrix_every_declared_cell_is_present(self):
        self.assertEqual(matrix_check.check_cells(ROOT), [])

    def test_matrix_every_seam_has_its_cells(self):
        self.assertEqual(matrix_check.check_seams(ROOT), [])

    def test_matrix_dimensions_span_min_and_max(self):
        self.assertEqual(matrix_check.check_dimensions(ROOT), [])

    def test_matrix_covered_cells_name_existing_tests(self):
        self.assertEqual(matrix_check.check_tests(ROOT), [])


class Prereg(unittest.TestCase):
    """docs/prereg: the body carries its lock, and the tests carry exactly what was registered."""

    def test_prereg_mc_lock_matches_body(self):
        self.assertEqual(prereg.check_lock(MC), [])

    def test_prereg_wf_lock_matches_body(self):
        self.assertEqual(prereg.check_lock(WF), [])

    def test_prereg_mc_binds_the_test(self):
        self.assertEqual(prereg.check_sol(MC, ROOT), [])

    def test_prereg_wf_binds_the_test(self):
        self.assertEqual(prereg.check_sol(WF, ROOT), [])

    def test_prereg_results_must_carry_the_registered_lock(self):
        lock = prereg.read(MC)["lock"]
        self.assertEqual(prereg.check_results(MC, f"  PREREG_LOCK: 0x{lock}\n"), [])
        other = "0x" + ("0" * 64)
        self.assertNotEqual(prereg.check_results(MC, f"  PREREG_LOCK: {other}\n"), [])
        self.assertNotEqual(prereg.check_results(MC, "no lock line at all\n"), [])

    def test_prereg_wf_block_rule_takes_the_first_block_at_the_target(self):
        ts = [100, 102, 104, 104, 106, 108]           # block -> timestamp, two blocks share 104
        f = ts.__getitem__
        self.assertEqual(prereg.first_block_at(f, 0, 5, 104), 2)
        self.assertEqual(prereg.first_block_at(f, 0, 5, 103), 2)
        self.assertEqual(prereg.first_block_at(f, 0, 5, 100), 0)
        self.assertEqual(prereg.first_block_at(f, 0, 5, 108), 5)
        with self.assertRaises(ValueError):
            prereg.first_block_at(f, 0, 5, 109)       # past the head: absent, never the head


def _rows(*rows):
    head = "chain\tkind\tms_case\toutcome\tnet_out\tdelivered\n"
    return head + "".join("\t".join(map(str, r)) + "\n" for r in rows)


class Anvil(unittest.TestCase):
    """anvil_compare: delivered (balance delta) against quoted, never the quote against itself."""

    def _run(self, text):
        with tempfile.NamedTemporaryFile("w", suffix=".tsv", delete=False) as fh:
            fh.write(text)
        try:
            return anvil_compare.compare_rows(fh.name)
        finally:
            os.unlink(fh.name)

    def test_anvil_compare_passes_honest_rows(self):
        errs, n = self._run(_rows(("base", "v2", "D", "ok", 1000, 1000), ("base", "v3", "hit", "ok", 10_000, 10_005)))
        self.assertEqual((errs, n), ([], 2))

    def test_anvil_compare_catches_short_delivery(self):
        errs, _ = self._run(_rows(("base", "v2", "D", "ok", 1000, 999)))
        self.assertNotEqual(errs, [])

    def test_anvil_compare_reads_an_absent_delivery_as_an_error(self):
        errs, n = self._run(_rows(("base", "v2", "D", "ok", 1000, "")))       # absent is not zero
        self.assertEqual(n, 0)
        self.assertNotEqual(errs, [])

    def test_anvil_compare_refuses_zero_measured_rows(self):
        errs, n = self._run(_rows(("base", "v2", "D", "revert", 1000, 0)))
        self.assertEqual(n, 0)
        self.assertNotEqual(errs, [])


if __name__ == "__main__":
    unittest.main()
