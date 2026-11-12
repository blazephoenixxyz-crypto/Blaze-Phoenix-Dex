#!/usr/bin/env python3
"""Two property guards for the Router (2026-10-20).

1. Custody guard: the Router moves only this call's delta.
   Every read of the Router's own balance is pinned here, per enclosing function, with the
   baseline that makes it a delta. A new read, or one in another function, goes red until it
   is reviewed against the property and added to CENSUS with its reason. Without this, "the
   Router never pays out a balance it did not receive in this call" is an accident of nobody
   writing such a read (the H11 vector T and the 3086 bridge sweep were exactly that read).
   The other contracts hold no funds in flight, so a self-balance read there is an error unless
   it is pinned in OTHERS_CENSUS with the reason nothing it holds survives the call. Reads are
   attributed to the enclosing function, fallback() and receive() included: a read inside
   fallback() must not be booked to the last named function above it.

2. Delegated-frame guard: the swap never executes at an address other than the Router's own.
   `SELF = address(this)` is an immutable, and the first statement of `_execute` compares
   against it (RouterE(18)). Under an EIP-7702 delegation `address(this)` is the delegating
   account, so every balance baseline above would measure that account's funds.

Exit 0 when both hold, 1 with ::error:: lines otherwise. Usage: frame_custody_guard.py [router.sol]
"""
import re
import sys

ROUTER = sys.argv[1] if len(sys.argv) > 1 else "src/BlazePhoenixRouter.sol"
OTHERS = ["src/BlazePhoenixHub.sol", "src/BlazePhoenixSolver.sol", "src/BlazePhoenixMath.sol",
          "src/BlazePhoenixQuoter.sol", "src/BlazePhoenixCore.sol"]

# (file, function) -> (number of self-balance reads, why nothing it holds or pays survives)
OTHERS_CENSUS = {
    ("src/BlazePhoenixQuoter.sol", "fallback"): (1, "the input probe (bounty uid 3984): the frame "
        "measures what the venue, run backwards, paid it and pays it back; it always ends in "
        "`revert InputProbe`, so nothing it holds or pays survives the call"),
}

# function -> (number of self-balance reads, the baseline that makes each one a delta)
CENSUS = {
    "executeRescue": (1, "onlyControl after the rescue timelock; not reachable from a swap; "
                         "pays the balance less the owed fees"),
    "_bal": (1, "the one producer of a swap-path self-balance: raw less this transaction's "
                "TSLOT_KEPT; every caller below subtracts its own baseline"),
    "_push": (2, "gone = before - after around one fee push; only the undelivered rest is booked"),
    "swapExactInWithPermit2": (1, "balBefore, the baseline _received subtracts"),
    "swapExactInNative": (2, "received = after - balBefore"),
    "_pull": (1, "balBefore, taken before the transferFrom; _received subtracts it"),
    "_received": (1, "received = after - balBefore, the baseline its caller took before its pull "
                     "(the one producer of the measured pull since 2026-10-28)"),
    "_chargeHopFee": (1, "bal - foreignBase (foreignBase = this call's baseline)"),
    "_hopScaleImpactAndQuote": (1, "bal - foreignBase"),
    "_execute": (8, "tinStart/toutStart/bridgeBase are the baselines; refunds pay resid - baseIn "
                    "and rb - bridgeBase; output is total - toutStart; the last-leg read is a "
                    "min() clamp, never a payout"),
    "_execScaled": (2, "got = after - balBefore"),
}

# `_bal(t)` (seal 2026-10-21) is the Router's balance less the fee shares booked as owed in
# this transaction; each call is a self-balance read and is pinned like the raw ones.
SELF_READ = re.compile(r"balanceOf\([^;]*address\(this\)\)|address\(this\)\.balance|selfbalance\(\)"
                       r"|(?<!function )\b_bal\(")
FUNC = re.compile(r"^\s*(?:function\s+([A-Za-z_0-9]+)|(fallback|receive))\s*\(")
COMMENT = re.compile(r"^\s*(///|//|\*|/\*)")

errors = []


def reads_by_function(path):
    found, fn = {}, None
    with open(path) as f:
        for n, line in enumerate(f, 1):
            m = FUNC.match(line)
            if m:
                fn = m.group(1) or m.group(2)
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
        pinned = OTHERS_CENSUS.get((p, fn))
        if pinned is None:
            errors.append(f"Custody guard: {p}:{lines[0]} ({fn}) reads its own balance; only the Router "
                          f"holds funds in flight.")
        elif len(lines) != pinned[0]:
            errors.append(f"Custody guard: {p} {fn} reads its own balance {len(lines)}x (pinned "
                          f"{pinned[0]}) at line(s) {','.join(map(str, lines))}; review the new read "
                          f"against the reason in OTHERS_CENSUS and update it.")
    for (path, fn), (want, _) in OTHERS_CENSUS.items():
        if path == p and fn not in other:
            errors.append(f"Custody guard: {p} {fn} no longer reads its own balance (pinned {want}); "
                          f"if the read moved, the census must move with it.")

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
print(f"frame/custody guard: {sum(len(v) for v in seen.values())} Router self-balance reads and "
      f"{sum(n for n, _ in OTHERS_CENSUS.values())} elsewhere, all pinned; _execute opens with the SELF check")
