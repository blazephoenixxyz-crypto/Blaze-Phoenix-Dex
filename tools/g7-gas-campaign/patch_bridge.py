#!/usr/bin/env python3
"""Drop the Hub's bridge at index 2 (or, with <add>, addBridge(<add>)) from a G7 state.json: load the Hub (code + storage) into a
local anvil (no fork, no RPC), call removeBridge(2) as the admin, take every slot the tx wrote
(prestateTracer diffMode) and write its new value back (a zero is kept as an explicit zero). Prints the before/after check.

  patch_bridge.py <state_dir> <chain> <out_dir> [<add>]
"""
import json, os, subprocess, sys, time, urllib.request

ANVIL = os.path.expanduser("~/.foundry/bin/anvil")
PORT = 8599
URL = "http://127.0.0.1:%d" % PORT


def rpc(m, p):
    r = urllib.request.urlopen(urllib.request.Request(URL, json.dumps(
        {"jsonrpc": "2.0", "id": 1, "method": m, "params": p}).encode(),
        {"Content-Type": "application/json"}), timeout=30)
    j = json.load(r)
    if "error" in j:
        raise SystemExit("%s: %s" % (m, j["error"]))
    return j["result"]


def call(to, data):
    return rpc("eth_call", [{"to": to, "data": data}, "latest"])


def w(x):
    return "%064x" % x


def manifest(path):
    out = {}
    for line in open(path):
        k, _, v = line.rstrip("\n").partition("\t")
        out.setdefault(k, v)
    return out


def main(state_dir, chain, out_dir, add=None):
    man = manifest(os.path.join(state_dir, chain + ".manifest.tsv"))
    st = json.load(open(os.path.join(state_dir, chain + ".state.json")))
    hub, admin = man["hub"].lower(), man["admin"]
    acc = st["accounts"][hub]
    p = subprocess.Popen([ANVIL, "--port", str(PORT), "--chain-id", man["chainid"], "--silent"])
    try:
        for _ in range(50):
            try:
                rpc("eth_chainId", []); break
            except Exception:
                time.sleep(0.2)
        rpc("anvil_setCode", [hub, acc["code"]])
        for k, v in acc["storage"].items():
            rpc("anvil_setStorageAt", [hub, "0x" + w(int(k, 16)), "0x" + w(int(v, 16))])
        cnt = lambda: int(call(hub, "0x" + selector("bridgeCount()")), 16)
        br = lambda i: "0x" + call(hub, "0x" + selector("bridge(uint8)") + w(i))[-40:]
        isb = lambda t: int(call(hub, "0x" + selector("isBridgeToken(address)") + w(int(t, 16))), 16)
        before = [br(i) for i in range(cnt())]
        drop = add.lower() if add else before[2]
        print(chain, "before", cnt(), before, "isBridge(drop)", isb(drop))
        rpc("anvil_impersonateAccount", [admin])
        rpc("anvil_setBalance", [admin, "0x" + w(10**18)])
        tx = rpc("eth_sendTransaction", [{"from": admin, "to": hub, "gas": "0x100000",
                                          "data": "0x" + (selector("addBridge(address)") + w(int(add, 16)) if add
                                                  else selector("removeBridge(uint8)") + w(2))}])
        rc = None
        for _ in range(50):
            rc = rpc("eth_getTransactionReceipt", [tx])
            if rc:
                break
            time.sleep(0.2)
        if not rc or int(rc["status"], 16) != 1:
            raise SystemExit(chain + ": bridge tx reverted")
        after = [br(i) for i in range(cnt())]
        print(chain, "after ", cnt(), after, "isBridge(drop)", isb(drop))
        assert (after == before + [drop] and isb(drop) == 1) if add else (after == before[:2] and isb(drop) == 0)
        # every slot the tx wrote, new ones included (addBridge writes slots the state lacks)
        d = rpc("debug_traceTransaction", [tx, {"tracer": "prestateTracer", "tracerConfig": {"diffMode": True}}])
        touched = set(d.get("post", {}).get(hub, {}).get("storage", {})) | set(d.get("pre", {}).get(hub, {}).get("storage", {}))
        norm = {"0x" + w(int(k, 16)): k for k in acc["storage"]}
        changed = []
        for k in sorted(touched):
            k = "0x" + w(int(k, 16))
            nv = int(rpc("eth_getStorageAt", [hub, k, "latest"]), 16)
            old = acc["storage"].get(norm.get(k, k), "0x0")
            if nv != int(old, 16):
                changed.append((k, old, hex(nv)))
                acc["storage"][norm.get(k, k)] = "0x" + w(nv)
        print(chain, "slots changed", len(changed))
        for c in changed:
            print("  ", *c)
        os.makedirs(out_dir, exist_ok=True)
        with open(os.path.join(out_dir, chain + ".state.json"), "w") as f:
            json.dump(st, f, indent=1)
            f.write("\n")
        print(chain, "added" if add else "dropped", drop)
    finally:
        p.terminate(); p.wait()


def selector(sig):
    out = subprocess.run([os.path.expanduser("~/.foundry/bin/cast"), "sig", sig],
                         capture_output=True, text=True, check=True).stdout.strip()
    return out[2:]


if __name__ == "__main__":
    main(*sys.argv[1:5])
