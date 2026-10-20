#!/usr/bin/env python3
"""Two property guards for the Router (2026-10-20).

1. Custody guard: the Router moves only this call's delta.
   Every read of the Router's own balance is pinned here, per enclosing function, with the
   baseline that makes it a delta. A new read, or one in another function, goes red until it
   is reviewed against the property and added to CENSUS with its reason. Without this, "the
   Router never pays out a balance it did not receive in this call" is an accident of nobody
   writing such a read (the H11 vector T and the 3086 bridge sweep were exactly that read).

2. Delegated-frame guard: the swap never executes at an address other than the Router's own.
   `SELF = address(this)` is an immutable, and the first statement of `_execute` compares
   against it (RouterE(18)). Under an EIP-7702 delegation `address(this)` is the delegating
   account, so every balance baseline above would measure that account's funds.

Exit 0 when both hold, 1 with ::error:: lines otherwise. Usage: frame_custody_guard.py [router.sol]
"""
import re
import sys

ROUTER = sys.argv[1] if len(sys.argv) > 1 else "src/BlazePhoenixRouter.sol"
OTHERS = ["src/BlazePhoenixHub.sol", "src/BlazePhoenixSolver.sol",
          "src/BlazePhoenixQuoter.sol", "src/BlazePhoenixCore.sol"]

# function -> (number of self-balance reads, the baseline that makes each one a delta)
CENSUS = {
    "executeRescue": (1, "onlyControl after the rescue timelock; not reachable from a swap"),
    "swapExactInWithPermit2": (2, "received = after - balBefore"),
    "swapExactInNative": (2, "received = after - balBefore"),
    "swapBestExactIn": (2, "received = after - balBefore"),
    "_swap": (2, "received = after - balBefore"),
    "_chargeHopFee": (1, "bal - foreignBase (foreignBase = this call's baseline)"),
    "_hopScaleImpactAndQuote": (1, "bal - foreignBase"),
    "_execute": (8, "tinStart/toutStart/bridgeBase are the baselines; refunds pay resid - baseIn "
                    "and rb - bridgeBase; output is total - toutStart; the last-leg read is a "
                    "min() clamp, never a payout"),
    "_execScaled": (2, "got = after - balBefore"),
}

SELF_READ = re.compile(r"balanceOf\([^;]*address\(this\)\)|address\(this\)\.balance|selfbalance\(\)")
FUNC = re.compile(r"^\s*function\s+([A-Za-z_0-9]+)\s*\(")
COMMENT = re.compile(r"^\s*(///|//|\*|/\*)")

errors = []


def reads_by_function(path):
    found, fn = {}, None
    with open(path) as f:
        for n, line in enumerate(f, 1):
            m = FUNC.match(line)
            if m:
                fn = m.group(1)
            if COMMENT.match(line) or not SELF_READ.search(line):
                continue
            found.setdefault(fn, []).append(n)
    return found


# --- 1. custody census -------------------------------------------------------------------
seen = reads_by_function(ROUTER)
for fn, lines in seen.items():
    want = CENSUS.get(fn, (0, ""))[0]
    if len(lines) != want:
        errors.append(f"Custody guard: {fn} reads the Router's own balance {len(lines)}x "
                      f"(pinned {want}) at line(s) {','.join(map(str, lines))}. Each such read must "
                      f"subtract a baseline taken in this call; review it and update CENSUS.")
for fn, (want, _) in CENSUS.items():
    if fn not in seen:
        errors.append(f"Custody guard: {fn} no longer reads the Router's own balance (pinned {want}); "
                      f"if the read moved, the census must move with it.")
for p in OTHERS:
    try:
        other = reads_by_function(p)
    except FileNotFoundError:
        continue
    for fn, lines in other.items():
        errors.append(f"Custody guard: {p}:{lines[0]} ({fn}) reads its own balance; only the Router "
                      f"holds funds in flight.")

# --- 2. delegated frame -----------------------------------------------------------------
src = open(ROUTER).read()
if not re.search(r"address\s+private\s+immutable\s+SELF\s*=\s*address\(this\)\s*;", src):
    errors.append("Delegated-frame guard: `address private immutable SELF = address(this);` is gone.")
m = re.search(r"function\s+_execute\s*\([^{]*\{", src)
if not m:
    errors.append("Delegated-frame guard: _execute not found.")
else:
    body = src[m.end():]
    first = next((ln.strip() for ln in body.splitlines()
                  if ln.strip() and not COMMENT.match(ln)), "")
    if first != "if (address(this) != SELF) revert RouterE(18);":
        errors.append(f"Delegated-frame guard: the first statement of _execute is `{first[:90]}`, "
                      f"not the SELF check. Nothing that reads a balance may run before it.")

if errors:
    for e in errors:
        print(f"::error::{e}")
    sys.exit(1)
print(f"frame/custody guard: {sum(len(v) for v in seen.values())} self-balance reads, all pinned; "
      f"_execute opens with the SELF check")
