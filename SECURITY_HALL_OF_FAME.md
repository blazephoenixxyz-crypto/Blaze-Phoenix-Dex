# Security Hall of Fame — BlazePhoenix DEX (V2)

BlazePhoenix runs an open, permissive bug-bounty: read the verified source, find
a real issue, report it, and — if it holds up — you go here, with our thanks.
Every listed finding was reproduced against this repo's own code and closed with
a regression test that fails on the old code and passes on the fix.

> Private disclosure: **security@blazephoenix.xyz** / blazephoenixxyz@proton.me.
> Non-critical reports may be filed as a GitHub issue. Responsible disclosure is
> credited here and, once the bounty pool is funded, paid. We keep fix internals
> brief in public — the verified source is the record.

---

## 🏆 Researchers

| Researcher | Ref | Severity | Status |
|---|---|---|---|
| **[NetGakarot (Gakarot)](https://github.com/NetGakarot)** | #1 — route input-scaling vs. the capacity clamp | **High** | ✅ Fixed & regression-tested |
| **duxun** (private) | #2 — `v4Entries` unbounded scan in `claimV4` | **High** | ✅ Fixed & regression-tested |
| **duxun** (private) | #3 — forged `leg.fee` zeroes `outV3`, evading the fee floor | **Medium** | ✅ Fixed |
| **duxun** (private) | #4 — V4 leg never capacity-clamped on V4-only routes | **Medium** | ✅ Fixed |
| **Anonymous researcher** (private) | #5 — per-hop input scaling uncapped vs. foreign-bridge balance | **Medium** | ✅ Fixed |
| **llen** (private) | #6 — fee floor inert when a venue quotes zero (C1b) | **Medium** (shared) | ✅ Fixed |

Private disclosers on this round are credited here with the program owner's
thanks; consent to public naming was requested by email, and handles are shown
as reported. All of the above were fixed in the v4-hardening merge and are
covered by the regression suite.

---

## Findings (summary only)

### #1 — Router input-scaling could override the Solver's capacity clamp
**Reporter:** NetGakarot (Gakarot) · **Severity:** High

A precise, well-reproduced report: under a specific single-venue condition the
Router's per-hop input scaling could override the Solver's capacity clamp, so a
route the Solver intended as a safe partial fill would either fail or over-fill.
Excellent root-cause analysis and a clean proof-of-concept.

**Resolution.** Fixed by enforcing, at execution, the invariant the clamp already
intended (a hop cannot spend beyond what its legs committed; the remainder is
returned to the caller), plus honest plan reporting. Fee-on-transfer behaviour is
unchanged. Details live in the verified source and the regression test
`test/RouterUndoesSolverCapacityClamp.t.sol`; we deliberately keep the public
write-up high-level.

*Thank you, NetGakarot — this is exactly the kind of report the bounty is for.*

### #2 — `v4Entries` unbounded O(n) scan in `claimV4`
**Reporter:** duxun (private) · **Severity:** High

`claimV4` walked an unbounded `v4Entries` set on the hot solve path, so the cost
of the scan grew with the number of entries — a gas-griefing vector that could
make the intended fast path arbitrarily expensive to execute.

**Resolution.** Fixed and regression-tested; the hot path no longer carries an
unbounded scan. Per policy the public write-up stays high-level and the verified
source is the record.

*Thank you, duxun — a sharp catch on the hot path.*

### #3 — Forged `leg.fee` zeroes `outV3`, evading the fee floor
**Reporter:** duxun (private) · **Severity:** Medium

A forged `leg.fee` could drive `outV3` to zero, letting a route slip under the
fee/floor accounting. This shares a root cause with llen's C1b (fee floor left
inert when a venue quotes zero) and both were closed together.

**Resolution.** Fixed as a single hardening of the fee-floor path so that a
zero-quote or forged-fee leg can no longer evade the floor.

*Thank you, duxun.*

### #4 — V4 leg never capacity-clamped on V4-only routes
**Reporter:** duxun (private) · **Severity:** Medium

On V4-only routes the V4 leg was never capacity-clamped, so the anchor collapsed
to a pure median rather than the intended capacity-aware value.

**Resolution.** Fixed so the V4 leg is clamped like the others and the anchor
behaves correctly on V4-only routes. Regression-tested.

*Thank you, duxun.*

### #5 — Per-hop input scaling uncapped against foreign-bridge balance
**Reporter:** Anonymous researcher (private) · **Severity:** Medium

Per-hop input scaling was not capped against the foreign-bridge balance, which
opened arbitrary-pool registration via a dust-swap.

**Resolution.** Fixed by capping per-hop scaling against the real available
balance so a dust-swap can no longer register an arbitrary pool.

*Thank you to the anonymous reporter.*

### #6 — Fee floor left inert when an on-chain venue quotes zero (C1b)
**Reporter:** llen (private) · **Severity:** Medium (shared root with #3)

When an on-chain venue quoted zero, the fee floor was left inert. This is the
shared root of duxun's forged-fee finding (#3) and was folded into the same fix.

**Resolution.** Fixed together with #3 as one hardening of the fee-floor path.

*Thank you, llen.*
