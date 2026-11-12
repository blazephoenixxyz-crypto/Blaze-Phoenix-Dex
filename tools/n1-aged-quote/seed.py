#!/usr/bin/env python3
"""N1 seed: hash of the first Ethereum block whose timestamp is > commit_ts + 60.

Usage: seed.py <commit_unix_ts>   (git log -1 --format=%ct <pre-registration commit>)
Prints "<block> <timestamp> <hash>" once that block exists; exits 75 if it does not yet.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import run_n1  # noqa: E402

t = int(sys.argv[1]) + 60
rpc = run_n1.Rpc("ethereum")
head = int(rpc.call("eth_blockNumber", []), 16)
if rpc.ts(head) <= t:
    sys.exit(75)
n = rpc.first_at_or_after(t + 1, head - 100_000, head)
h = rpc.call("eth_getBlockByNumber", [hex(n), False])
assert int(h["timestamp"], 16) > t and rpc.ts(n - 1) <= t
print(n, int(h["timestamp"], 16), h["hash"].lower())
