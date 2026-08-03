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
  floor 75%). It is the strictest of {user `minOut`, route floor, protocol floor}.
  A fill below it reverts.
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

The implementation is exercised by (see `TESTING.md`):

- **Offline (51 tests):** Core math, Hub registry fuzzing & invariants, Router
  admin/ossification, differential equivalence vs. a reference solver, callback
  authentication, reentrancy and V4-hook guards, and **stateful invariant
  fuzzing** over single-leg / multi-hop / intra-hop-split routes asserting the
  Router is a pass-through (zero residual balance) and per-token conservation.
- **Fork (~85 cases, 4 chains):** real-liquidity metrics across direct, stable,
  exotic and exotic↔exotic pairs at small/large/whale sizes, exercising every
  venue family, plus property fuzzing of the execution path (truthful reporting,
  slippage honoured, unreachable `minOut` reverts, no trapped funds, fee cap,
  surplus fee-exemption, treasury split).

No security bug was found across the campaign; the only finding was a known
quote-accuracy limitation (§8).

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
   the V4 settle/take accounting before custodying material value. See
   `audit/SCOPE.md` for a risk-ranked review scope.

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
