#!/usr/bin/env python3
"""Anvil comparison: what the quote promised against what the swap delivered.

Reads a G7 results.tsv (tools/g7-gas-campaign/g7.py on ci-draft/g7-quality): every row with
outcome == "ok" carries net_out (the published quote) and delivered (the balance delta of
tokenOut measured on the anvil fork). The rule is exact: delivered >= net_out, no tolerance
(src/BlazePhoenixQuoter.sol:436-440 rounds the safety buffer up so that netOut understates).
An ok row with no delivered value is an error, never a zero; a file with no measured row is an
error, never a pass. No bound on the over-delivery (delivered - net_out) is asserted here: the
owner decides that number.

  python3 tools/fuzz-coverage/anvil_compare.py <results.tsv>
"""
import csv
import sys


def compare_rows(path):
    errors, n = [], 0
    with open(path, newline="") as fh:
        rows = list(csv.DictReader(fh, delimiter="\t"))
    for i, r in enumerate(rows, start=2):
        if r.get("outcome") != "ok":
            continue
        tag = f"{path}:{i} {r.get('chain')}/{r.get('kind')}/{r.get('ms_case')}"
        if not r.get("delivered") or not r.get("net_out"):
            errors.append(f"{tag}: ok row without a measured delivery or quote (absent, not zero)")
            continue
        net_out = int(r["net_out"])
        delivered = int(r["delivered"])
        n += 1
        if delivered < net_out:
            errors.append(f"{tag}: delivered {delivered} < quoted {net_out}: the quote promised more")
    if n == 0:
        errors.append(f"{path}: no measured row: nothing was compared")
    return errors, n


def main(path):
    errors, n = compare_rows(path)
    for e in errors:
        print(e)
    print(f"anvil_compare: {n} measured rows, {len(errors)} errors")
    return 1 if errors else 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    sys.exit(main(sys.argv[1]))
