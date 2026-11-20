"""Selection guard of mutants_fork.py: an index outside 1..len(M_FORK) must not pass as "0/0 killed".

Run: python3 -I -m unittest discover -s .github/scripts -p 'test_mutants_fork.py'
Mutant: drop the out-of-range check in main() -> both tests red (exit 0, "0/0 ... pairs killed").
"""
import os
import subprocess
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "mutants_fork.py")


def run(only):
    env = dict(os.environ, FORGE_CMD="true", MUTANTS_FORK_ONLY=only)
    env.pop("MUTANTS_FORK_LOGS", None)
    return subprocess.run([sys.executable, "-I", SCRIPT], capture_output=True, text=True,
                          env=env, cwd=os.path.dirname(os.path.dirname(HERE)), timeout=120)


class SelectionGuard(unittest.TestCase):
    def test_an_index_past_the_list_is_refused(self):
        r = run("999999")
        self.assertNotEqual(r.returncode, 0, r.stdout)
        self.assertNotIn("pairs killed", r.stdout)
        self.assertIn("999999", r.stdout + r.stderr)

    def test_index_zero_is_refused(self):
        r = run("0")
        self.assertNotEqual(r.returncode, 0, r.stdout)
        self.assertNotIn("pairs killed", r.stdout)


if __name__ == "__main__":
    unittest.main()
