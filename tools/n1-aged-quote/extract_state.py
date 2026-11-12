#!/usr/bin/env python3
"""N1: extract the V2 override state from an anvil_dumpState blob.

Usage: extract_state.py <dump.hex> <deployer> <forkblock> <chain> <broadcastdir/chainid>

Keeps only the accounts the N1Deploy broadcast created (contractAddress of every transaction,
linked libraries included, plus additionalContracts), each with code, full storage and nonce.
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


def created(broadcastdir):
    run = json.load(open(os.path.join(broadcastdir, "run-latest.json")))
    out = []
    for tx in run["transactions"]:
        if tx.get("contractAddress"):
            out.append(tx["contractAddress"])
        for extra in tx.get("additionalContracts") or []:
            out.append(extra["address"])
    return [a.lower() for a in out]


def main():
    dump_path, deployer, forkblk, chain, bdir = sys.argv[1:6]
    dump = load_dump(dump_path)
    accounts = {k.lower(): v for k, v in dump["accounts"].items()}
    keep = {}
    for addr in created(bdir):
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
