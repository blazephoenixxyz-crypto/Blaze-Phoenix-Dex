#!/usr/bin/env python3
"""Gas snapshot guard: every committed group in snapshots/ is one this run wrote.

The gas ledgers in test/gas/ write one snapshot group per test, named after it
(snapshots/<test>.json). forge's snapshot check compares only the entries both sides hold, and a
run that passes rewrites every group it ran and no other. A committed group this run did not
write was therefore not checked: its numbers stand on an older run's word. That is the case when
its test was deleted or renamed, and also when the test still exists and wrote nothing - skipped
(vm.skip), left out by a filter, or with its snapshot calls removed.

The loop this replaces asked only whether a function of the group's name exists, and passed a
group whose test was skipped (red at b3c96bf, 2026-11-10: with vm.skip in one ledger the step
stayed green and that ledger's numbers went unread).

What the guard checks, for every snapshots/*.json:
  1. a function of exactly that name exists in test/gas/*.t.sol;
  2. the file was written after <marker>, a file the caller creates right before the forge run.

Exit 0 when every group holds, 1 with ::error:: lines otherwise.
Usage: gas_snapshot_guard.py <marker> [snapshots_dir [tests_dir]]
       gas_snapshot_guard.py --self-test
"""
import os
import re
import sys
import tempfile

FUNCTION = re.compile(r"\bfunction\s+(\w+)\s*\(")


def check(marker, snaps="snapshots", tests=os.path.join("test", "gas")):
    """(groups, errors): the committed groups, and (path, why) for each one this run left unchecked."""
    since = os.stat(marker).st_mtime_ns
    names = set()
    for f in sorted(os.listdir(tests)):
        if f.endswith(".t.sol"):
            names |= set(FUNCTION.findall(open(os.path.join(tests, f)).read()))
    groups = sorted(f for f in os.listdir(snaps) if f.endswith(".json"))
    errors = []
    for f in groups:
        p = os.path.join(snaps, f)
        if f[:-len(".json")] not in names:
            errors.append((p, f"no test in {tests} is named after this group"))
        elif os.stat(p).st_mtime_ns <= since:
            errors.append((p, "this run did not write this group, so its numbers were not checked"))
    return groups, errors


def self_test():
    # (group, written this many ns after the marker, the guard must pass it)
    cases = [
        ("test_Gas_Written", 1, True),
        # the test exists and wrote nothing: skipped, filtered out, snapshot calls removed
        ("test_Gas_Skipped", -1, False),
        ("test_Gas_WrittenWithTheMarker", 0, False),
        # the test was deleted, and nothing writes the group
        ("test_Gas_Deleted", -1, False),
        # written, but under a name no test has: a prefix of one, and another test's leftover
        ("test_Gas_Prefix", 1, False),
        ("test_Gas_WrittenByAnother", 1, False),
    ]
    with tempfile.TemporaryDirectory() as d:
        snaps, tests = os.path.join(d, "snapshots"), os.path.join(d, "test", "gas")
        os.makedirs(snaps)
        os.makedirs(tests)
        with open(os.path.join(tests, "Ledger.t.sol"), "w") as f:
            f.write("contract Ledger {\n"
                    "    function test_Gas_Written() public {}\n"
                    "    function test_Gas_Skipped() public {}\n"
                    "    function test_Gas_WrittenWithTheMarker() public {}\n"
                    "    function test_Gas_Prefix_OneAndTwoLegs() public {}\n"
                    "}\n")
        t = 1_700_000_000 * 10**9
        marker = os.path.join(d, "marker")
        open(marker, "w").close()
        os.utime(marker, ns=(t, t))
        for name, after, _ in cases:
            p = os.path.join(snaps, name + ".json")
            with open(p, "w") as f:
                f.write("{}")
            os.utime(p, ns=(t + after, t + after))
        groups, errors = check(marker, snaps, tests)
    refused = {p for p, _ in errors}
    fails = [name for name, _, ok in cases if (os.path.join(snaps, name + ".json") in refused) == ok]
    if len(groups) != len(cases):
        fails.append(f"{len(groups)} groups read of {len(cases)}")
    for name in fails:
        print(f"::error::gas snapshot guard self-test misjudged: {name}")
    if fails:
        sys.exit(1)
    print(f"gas snapshot guard self-test: {sum(not ok for _, _, ok in cases)} unchecked groups caught, "
          f"{sum(ok for _, _, ok in cases)} written group passed")


def main():
    if sys.argv[1:] == ["--self-test"]:
        self_test()
        return
    if not 2 <= len(sys.argv) <= 4:
        sys.exit(__doc__)
    groups, errors = check(*sys.argv[1:])
    for p, why in errors:
        print(f"::error::{p}: {why}")
    if errors:
        sys.exit(1)
    print(f"gas snapshot guard: {len(groups)} committed groups, each named after a test in test/gas "
          f"and written by this run")


if __name__ == "__main__":
    main()
