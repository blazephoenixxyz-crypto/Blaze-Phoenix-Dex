# Blaze Phoenix — A Fully On-Chain DEX Router

**Version 1.0 · Technical Whitepaper**

> Status: unaudited research/engineering preview. This document describes the
> design as implemented and validated by the test campaign in `TESTING.md`. It is
> **not** a security attestation — see *Status & limitations*. Nothing here is an
> offer or financial advice.

---

## Abstract

Blaze Phoenix is a multi-venue DEX router whose **route solving runs on-chain**.
Where mainstream aggregators compute routes on off-chain infrastructure and submit
the result, Blaze Phoenix exposes the solver as an on-chain function: anyone can
obtain a trustless quote with a free `eth_call`, and execution **re-derives the
safety floor on-chain** so a submitted route cannot misrepresent its guarantees.
The result is a router with no trusted off-chain component, that prices across
V2/V3/V4/Solidly/Algebra/concentrated-liquidity venues, splits across them, and
bridges exotic↔exotic pairs — all from a single codebase deployed unchanged on
Ethereum, Arbitrum, Base and Optimism.

---

## 1. Design thesis

Three properties define the system:

1. **On-chain solving, off-chain-free.** `Solver.findBestRoutePlan` evaluates
   direct and bridged topologies and returns the best route plus a runner-up.
   Quoting is a `view` call — free over RPC — so users pay nothing to get a
   trustless route. No solver servers, no signing infrastructure, no relayers.

2. **The Router is an enforcer, not a trustee.** The Router executes the `Route`
   it is given but **does not trust it**. The protocol floor is recomputed on
   the *realised* output from *measured* price impact (`ironFloorBps`), never read
   from caller-supplied route fields. A route can only ever tighten protection,
   never relax it.

3. **Permissionless, ossifiable, stateless-at-rest.** Venues are discovered by
   deterministic CREATE2 derivation — no hardcoded pool addresses. The Router
   holds **zero token balance between swaps** (verified by stateful invariant
   fuzzing). Control powers can be permanently surrendered (`renounceControl`),
   after which the protocol keeps executing under a frozen configuration.

---

## 2. Architecture

| Component | Responsibility |
|---|---|
| **Hub** | Pool/venue registry, deterministic discovery, per-pool fitness (vitality), bridges, V4 registration, role model, ossification. |
| **Solver** | On-chain route construction: candidate selection, splitting, bridge topologies, conservative quoting. |
| **Router** | Execution + on-chain floor/fee enforcement; universal AMM callbacks (V3-shaped fallback, V4 unlock/flash); reentrancy guard. |
| **Quoter** | View-only quoting surface. |
| **Core** | Shared library: AMM math, floor derivation, safe transfers, the packed per-pool fitness codec. |

A swap is two phases. **Quote** (off-chain-free `eth_call`): the Solver returns a
`Route`. **Execute** (on-chain tx): the user submits that `Route`; the Router pulls
the input, runs each leg across the named venues, re-derives the floor from the
realised output, charges the fee, and pays the recipient — ending with zero
residual balance.

---

## 3. Deterministic discovery

The Hub never stores hardcoded pool addresses. Each registered factory carries a
*mode* (factory-call or CREATE2) and, for CREATE2 venues, an init-code hash. To
find venues for a pair, the Hub derives the candidate addresses on the fly and
keeps the ones with deployed code. A single `addFactory` coherence guard rejects
every structurally impossible `(kind, mode, initHash, fees)` combination, so a
mis-configured adapter reverts at registration rather than deriving wrong
addresses silently. One init-code hash works across all chains for Uniswap-V3-
shaped venues.

Supported venue families: Uniswap V2/V3/V4, SushiSwap V2/V3, PancakeSwap V2/V3,
Aerodrome & Velodrome (Solidly), Velodrome CL/Slipstream, Camelot (Algebra).
Curve/Stable adapters are present but **disabled in v1.0** (see §8).

### Freshness-gated discovery (gas)

Full CREATE2 discovery is the dominant cost of the on-chain solve. The Solver
therefore skips the discovery sweep when a pair already has a healthy, **recently
active** registered set — at least three venues with activity inside a wall-clock
window (`DISCOVERY_TTL_SECONDS`, measured via `block.timestamp` so it is identical
on every chain). New, thin, or quiet pairs still run a full discovery, so
freshly-deployed pools are picked up after the window. This is a **gas/coverage
knob, never a safety parameter** — the floor protects every fill regardless of how
stale the registry is.

Measured effect (WETH/USDC quote, empty vs warm registry):

| Chain | Full discovery | Registry fresh | Saved |
|---|---|---|---|
| Ethereum | 715k | 199k | **−72%** |
| Arbitrum | 763k | 209k | **−73%** |
| Base | 790k | 207k | **−74%** |
| Optimism | 632k | 130k | **−80%** |

This is what makes an **atomic on-chain solve-then-swap in a single transaction**
economically viable — the distinctive capability off-chain aggregators cannot
offer.

---

## 4. Execution

The Router executes up to **five legs** total, across one or two hops. A direct
route splits the budget across venues of one pair; a bridged route (for
exotic↔exotic) routes through one of at most two **bridge** tokens, typically 3
legs into the bridge and 2 out. Per venue family:

- **V2 / Solidly** — push-then-swap with on-path output computation; the
  fee-on-transfer branch recomputes from *measured* received balance, robust even
  for tokens that trade mid-transfer.
- **V3 / Algebra / CL** — callback-style swap with the pool committed in transient
  storage; the callback may pull at most the current leg's budget.
- **V4** — `unlock → swap → sync → settle → take`, with hooks that return deltas
  rejected up front.

---

## 5. Safety model

- **Iron floor.** The minimum output is recomputed on-chain from realised impact
  and leg count (base 96%, loosened per extra leg and per bps of impact, hard
  floor 80%, raised from 75% in the 2026-08 reconstruction). It is the strictest
  of {user `minOut`, route floor, protocol floor}. A fill below it reverts.
- **Fee policy.** 0.28% on the realised output, split 30/70 between two
  treasuries. The fee base is clamped to the attested quote, so **surplus above
  the quote is fee-exempt** and a zero-quote cannot evade the fee.
- **Callback authentication.** Every AMM callback verifies the caller is the
  committed counterparty held in transient storage for the duration of the swap;
  an unsolicited callback (outside a swap) always reverts.
- **Reentrancy.** A transient-storage guard rejects re-entry into the swap entry
  points.
- **Fee-on-transfer.** Slippage is enforced on the recipient's *delivered* delta,
  so a deflationary token cannot be used to slip a user below their bound.
- **Ossification.** Treasuries, pause, Permit2 and admin transfer can be frozen
  forever; growth-only curator powers can remain.

---

## 6. Economics & gas

- **Quote (on-chain solve):** ~130–210k warm-registry, up to ~715k with a full
  discovery sweep — and **free** to users via `eth_call`.
- **Execution:** a single-leg swap is comparable to a direct AMM swap plus modest
  routing overhead; a five-leg split is ~950k cold / ~250–300k warm (it performs
  five swaps atomically, ≈190k/leg).
- **Quote vs realised:** across dozens of real pairs on four chains, realised
  output tracked the quote at ≈9,990–10,025 bps — the quote is conservative
  (never optimistic) for in-range sizes.

---

## 7. Validation

> This section previously claimed "51 offline tests" and "~85 fork cases, 4
> chains, no security bug found." Neither could be verified: no test source
> (`.t.sol`) exists anywhere in this repository's history, only this prose.
> It is replaced below with what is actually present as of the 2026-08
> reconstruction pass — a materially smaller surface. Treat any future
> re-expansion of this section with the same skepticism until the test files
> themselves are checked in and can be run.

The implementation is exercised by a from-scratch Foundry suite (see `test/`
and `TESTING.md`):

- **Core** — `vitality()` decay behaviour (incl. a regression for a previously
  shipped 128×-too-fast decay bug), `mulDiv`/`mulDivUp` correctness (incl. a
  property-based fuzz test), `ironFloorBps` bounds, `hookAltersDeltas` bit
  decoding, packed-slot encode/decode round-trips.
- **Hub** — a regression proving `addV4` registers a pool under the exact key
  `recordSwap` looks up later (previously a mismatched-preimage-width bug
  caused silent duplicate registry entries), `addFactory` coherence guards,
  `renounceControl` scope.
- **Router** — a regression proving the protocol fee is charged on an
  on-chain-verified quote of the legs as executed, not on a caller-suppliable
  `route.totalOut` (previously a real fee-base leak), and that a plain ETH
  transfer reverts instead of being silently trapped.

- **Solver** — the median-rate filter excluding a stale-priced outlier, the
  capital anchor overriding a naive dust-majority median, the two-tier
  concentrated-liquidity capacity clamp, depth-weighted split proportionality,
  bridge-topology ranking, and the registry-freshness discovery gate.
- **Quoter** — preview packing math, the documented fee-vs-floor divergence
  from the Router's real execution path, `batchQuote`, and
  `previewPlanExact`'s revert-extraction dry-run against both a V3 leg and a
  plain V2 leg.
- **Reentrancy** — proven via a malicious token whose `transferFrom` attempts
  a nested swap mid-pull: the outer swap completes, the nested attempt is
  blocked by the transient-storage lock.
- **Stateful (Monte Carlo) invariant fuzzing** — a handler-driven suite
  running thousands of random swaps per invocation, checking the Router
  never retains a residual token balance and never collects more than its
  stated protocol fee.
- **Real mainnet liquidity** — fork tests that deploy the full stack and
  execute real swaps against live Base (Uniswap V3, Aerodrome) and Ethereum
  (Curve 3pool) state, plus a discovery sweep across the top-100 real Base
  tokens by market-cap rank and a literal standalone `anvil` deployment
  verified via `cast`, not just in-test fork cheatcodes.

Gas, price-impact, and slippage figures are *measured* from these tests, not
estimated — see `REPORTS.md`, including a comparison against published
external benchmarks (Uniswap's own cited gas ranges, academic measurement of
DEX swap costs). See `TESTING.md` for the authoritative, current coverage
list and the remaining known gaps (Balancer V2 is not a real integration
yet; Arbitrum/Optimism fork tests do not exist yet; Curve's meta-registry
discovery path is unexercised, though its execution adapter is verified
against the real pool).

---

## 7.1 Upgrades over the pre-reconstruction baseline

The contracts in this repository are not new code with new bugs — they are
the same five canonical contracts with issues found by cross-referencing the
implementation, line by line, against an accumulated internal research
series, then fixed and verified by the test suite in §7. Nothing below was
caught by any prior "validation campaign" this document used to cite; that
claim could not be verified (§7's opening note) and is treated as
non-existent evidence rather than a baseline to improve on.

**Fixed bugs (previously shipped silently):**

1. **V4 pool-registry key collision** — `Hub.addV4` hashed a different
   preimage width than `recordSwap`'s lookup (`abi.encodePacked` of a
   72-byte vs. a 60-byte tuple), so a V4 pool's first real swap could never
   find the key `addV4` registered it under. Result: a silent duplicate
   registry entry per V4 pool, the original left permanently orphaned.
2. **Router fee-base leak** — the protocol fee was computed from the
   caller-supplied `route.totalOut`. A crafted `Route` understating that
   figure shrank the fee toward the output floor (a mere fraction of real
   proceeds) instead of ~100% of the true output, for free. Fixed by
   re-deriving the fee base from an on-chain quote of the legs as actually
   executed, reusing state already read for impact measurement (no extra
   staticcalls).
3. **Vitality decay ~128× too fast, and counted in blocks.** The decay
   window shifted every 16 blocks instead of every ~2,048, and used block
   count rather than wall-clock time — the same pool's registry "memory"
   varied by up to ~40× across chains with different block times for
   identical market activity. Fixed: decay now runs on a wall-clock-seconds
   step, chain-agnostic by construction (same discipline the Solver's
   discovery-freshness gate already used).
4. **V4 pool depth always read as zero.** `Router._recordHits` staticcalled
   `getLiquidity` on `leg.pool` for V4 legs — but a V4 leg's `pool` field
   holds the *truncated poolId*, not a contract address, so every V4 pool
   was permanently scored at the bottom of the fitness ranking regardless of
   real liquidity. Fixed: V4 depth is now read from the PoolManager
   singleton directly, via the same key construction execution uses.
5. **`balanceOf` could return scratch-memory garbage instead of 0** for a
   codeless "token" address (an EOA, or an unset address) — a staticcall to
   a codeless address succeeds trivially with empty returndata, and the EVM
   does not zero unwritten destination memory. Not independently
   exploitable (every path that could pay out real value is still guarded
   by `safeTransfer`/`safeTransferFrom`'s `extcodesize` check), but a real
   divergence from the primitive's documented "silently returns 0"
   contract. Fixed with a `returndatasize()==32` guard, matching the pattern
   already used two functions away in the same file.
6. **Fee-on-transfer `tokenIn` reverted on every attempt.** The Router's
   first hop spent `leg.amountIn` exactly as the Solver planned it — the
   *pre-fee* amount — while every later (bridge) hop already rescaled
   against the real measured balance received. A fee-on-transfer token used
   as the swap's entry token made the first leg try to spend more than the
   Router actually held, reverting the whole transaction every time (a
   denial-of-service on that specific input shape, never a fund-loss path —
   the transaction fails atomically). Fixed by applying the same
   real-balance-ratio scaling primitive to every hop uniformly, using the
   already-measured post-pull amount for hop 0 at zero extra staticcall
   cost.

**Sealed design-parameter changes** (deliberate decisions, not bugs):

- `MEDIAN_FILTER_BPS`: 200 → 400 (±2% → ±4% band around the capital-anchored
  median rate).
- `FLOOR_HARD_MAX_LOSS_BPS`: 2,500 → 2,000 (the hard output-floor cap rose
  from 75% to 80% of the attested quote).
- `Router.receive()` deleted (not replaced with a sweep function): a plain
  ETH transfer now reverts immediately via the existing fallback's
  `msg.value > 0` guard, instead of being silently trapped with no rescue
  path.

**Verifiability, not just code**: the pre-reconstruction state of this
repository had zero `.t.sol` test files anywhere in its history — every
correctness claim was prose. This version ships the suite summarized in §7:
unit coverage for all five contracts, stateful invariant fuzzing, and fork
tests that execute real swaps against live Base and Ethereum liquidity. That
gap — not any single bug — is the largest single upgrade over the prior
baseline.

---

## 8. Status & limitations

This is **unaudited**. The following are explicit and, where noted, by design for
v1.0:

1. **Single-tick quote approximation.** Concentrated-liquidity quotes (V3 and V4)
   use a current-tick formula that ignores tick crossing. On large, tick-crossing
   swaps the quote diverges from execution; the on-chain floor then correctly
   rejects an over-optimistic fill (observed on large V4 and large exotic V3
   trades). The floor protects the user, but affected large swaps can fail and
   routing quality can degrade. A tick-aware quote (e.g. an on-chain Quoter
   staticcall) is the recommended improvement.
2. **Curve/Stable disabled.** Registration rejects these kinds in v1.0 pending a
   proper `coins()` resolution and dedicated tests.
3. **Admin is a single key** until a multisig/timelock is wired or control is
   renounced.
4. **Requires external audit and formal verification** of the floor/fee math and
   the V4 settle/take accounting before custodying material value. A risk-ranked
   review scope (`audit/SCOPE.md`) is referenced by prior versions of this
   document but does not yet exist in this repository.
5. **This reconstruction pass found and fixed six bugs that had shipped
   silently**, discovered by cross-referencing the implementation against
   accumulated research notes and by writing the test suite in §7, rather
   than by the validation campaign §7 used to claim. See §7.1 for the full
   list, the sealed design-parameter changes alongside it, and why the test
   suite itself is the largest single upgrade over the prior baseline. See
   `git log` on the `dev-v2` branch for the exact commits.

---

## 9. Summary

Blaze Phoenix demonstrates that **trustless, multi-venue route solving can live
fully on-chain** at a cost compatible with a single swap once a pair's registry is
warm, with execution that enforces its own safety floor and never holds user
funds at rest. It removes the off-chain solver from the trust model and, with
freshness-gated discovery, makes atomic on-chain solve-and-swap practical. What
remains before production is not more testing but the formal-assurance work any
serious protocol passes: external audit, formal verification, and timelocked
governance.
