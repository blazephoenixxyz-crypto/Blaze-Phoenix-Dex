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
