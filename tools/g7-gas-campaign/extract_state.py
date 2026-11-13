#!/usr/bin/env python3
"""G7: extract the V2 override state from an anvil_dumpState blob (copy of tools/n1-aged-quote).

Usage: extract_state.py <dump.hex> <deployer> <forkblock> <chain> <extra.txt> <run.json>...

Keeps only the accounts the deploy created: contractAddress and additionalContracts of every
transaction of every forge broadcast run given, plus the addresses listed in extra.txt (one per
line: the Gate adapters deployed by `forge create` and the wrappers the Gate created by CREATE2),
each with code, full storage and nonce.
Every kept account must carry code in the dump; otherwise the script fails loudly (an absent
account is a fact about the dump, not "no code").
Output (stdout): {"chain", "forkBlock", "deployer", "accounts": {addr: {code, nonce, storage}}}.
"""
import gzip
import json
import os
import sys


def load_dump(path):
    raw = open(path).read().strip().strip('"')
    if raw.startswith("0x"):
        raw = raw[2:]
    blob = bytes.fromhex(raw)
    try:
        blob = gzip.decompress(blob)
    except OSError:
        pass  # older anvil: plain JSON bytes
    return json.loads(blob)


def created(run_paths, extra_path):
    out = []
    for p in run_paths:
        run = json.load(open(p))
        for tx in run["transactions"]:
            if tx.get("contractAddress"):
                out.append(tx["contractAddress"])
            for extra in tx.get("additionalContracts") or []:
                out.append(extra["address"])
    out += [x.strip() for x in open(extra_path).read().split() if x.strip()]
    seen, uniq = set(), []
    for a in (x.lower() for x in out):
        if a not in seen:
            seen.add(a)
            uniq.append(a)
    return uniq


def main():
    dump_path, deployer, forkblk, chain, extra = sys.argv[1:6]
    runs = sys.argv[6:]
    dump = load_dump(dump_path)
    accounts = {k.lower(): v for k, v in dump["accounts"].items()}
    keep = {}
    for addr in created(runs, extra):
        acc = accounts.get(addr)
        if acc is None or acc.get("code") in (None, "", "0x"):
            sys.exit(f"extract_state: created account {addr} has no code in the dump")
        storage = {}
        for slot, val in (acc.get("storage") or {}).items():
            storage["0x" + int(slot, 16).to_bytes(32, "big").hex()] = "0x" + int(val, 16).to_bytes(32, "big").hex()
        nonce = acc.get("nonce", 0)
        keep[addr] = {"code": acc["code"], "nonce": int(nonce, 16) if isinstance(nonce, str) else int(nonce),
                      "storage": storage}
    json.dump({"chain": chain, "forkBlock": int(forkblk), "deployer": deployer.lower(), "accounts": keep},
              sys.stdout, indent=1, sort_keys=True)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
