# Blaze Phoenix — DEX Routing

How Blaze Phoenix finds, scores, and executes a trade across many venues — all
on-chain. This document covers routing only; see `WHITEPAPER.md` for the full
system. A risk-ranked review scope (`../audit/SCOPE.md`) is referenced by prior
versions of this document but does not yet exist in this repository.

> [!NOTE]
> The four-chain gas table in §4 is carried over from an earlier measurement
> campaign whose harness isn't part of this repository, so treat those
> particular figures as indicative rather than reproducible. Gas, price
> impact and slippage measured by this repo's own suite are in
> `../REPORTS.md`; `../TESTING.md` covers what is tested today.

---

## 1. On-chain solving

Mainstream aggregators compute routes on off-chain infrastructure and submit the
result, introducing a trusted process and a staleness window. Blaze Phoenix puts
the solver **on-chain**: `Solver.findBestRoutePlan(tIn, tOut, amountIn)` is a
`view` function that returns the best route plus a runner-up. Because it is a
view, an ordinary trader obtains a trustless quote with a **free `eth_call`** —
no servers, relayers, or signing. The same on-chain function can be called inside
a transaction, making an **atomic on-chain solve-then-swap** possible with no
off-chain solver in the trust path.

The Router never trusts the route it is handed. The protocol floor is recomputed
on-chain from the *realised* output and *measured* price impact, never read from
caller-supplied route fields — a route can only tighten protection, never relax
it.

## 2. Route topologies

The Solver searches a deliberately small space, with a strict global budget of
**five legs**:

- **Direct** — `tIn → tOut` in one hop, splitting the input across up to five
  parallel pools of the pair.
- **Bridge** — for exotic↔exotic pairs with no single deep venue, route through a
  canonical intermediary (WETH or USDC), partitioning the five-leg budget between
  the two stages (typically 3 in, 2 out).

The Solver evaluates direct and both bridge candidates and returns the
highest-scoring route per trade — direct when a venue is deepest, composed when
splitting pays.

## 3. Capital-anchored split

Allocating a split on full-input rates conflates price *quality* with pool
*depth*: a small but healthy pool shows a poor full-input rate purely from its own
impact, and filtering on that rate discards good small pools on large trades. The
Solver separates the two signals:

1. **Quality filter** — quote each candidate with a small probe (≈ `x/100`, so the
   marginal rate is essentially spot) and keep only those within a tight band of a
   reference rate.
2. **Depth allocation** — allocate the survivors by capacity (the fitness/`Ψ`
   weight), so a well-priced small pool is kept but receives proportionally less.

The standing guarantee is `split ≥ best single venue`.

## 4. Deterministic discovery & the freshness gate

Venues are not hardcoded. Each registered factory carries a *mode* and, for
CREATE2 venues, an init-code hash; the Hub derives candidate pool addresses on the
fly and keeps those with deployed code. A coherence guard rejects structurally
impossible `(kind, mode, initHash, fees)` combinations at registration. One
init-code hash works across chains for Uniswap-V3-shaped venues.

The full CREATE2 sweep is the dominant cost of an on-chain solve. The registry
records the venues a pair actually trades through, so the Solver treats it as a
**warm cache**: it unions registered venues with a sweep, but **skips the sweep**
when the pair already has at least three registered venues active within a
wall-clock window (`block.timestamp`, so the window is identical real time on
every chain — no per-chain block-cadence assumption). New, thin, or dormant pairs
still run a full discovery, so freshly-deployed pools are picked up after the
window lapses. This is a **gas/coverage knob, never a safety one** — the on-chain
floor protects every fill regardless of registry staleness.

Fork-measured WETH/USDC quote gas, full discovery vs. warm registry:

| Chain | Full discovery | Warm registry | Reduction |
|---|---|---|---|
| Ethereum | 715k | 199k | −72% |
| Arbitrum | 763k | 209k | −73% |
| Base | 790k | 207k | −74% |
| Optimism | 632k | 130k | −80% |

## 5. Search quote vs. binding quote

Two quote regimes serve two purposes:

- **Search quote (Solver).** The route space is scored with the Core's closed-form
  output functions, including a current-tick branch for concentrated liquidity.
  This is cheap enough to score many candidates on-chain, but for a large trade
  that crosses ticks it can diverge from the realised fill. That divergence is
  bounded on-chain by the iron floor: a route whose realised output falls below
  the re-derived floor **reverts** rather than fills — the worst case is a failed
  transaction, never a silently bad one.
- **Binding quote (Quoter).** The trader-facing number is produced by the Quoter's
  exact pass — *revert-extraction*: the pool's own swap is run and rolled back, so
  the displayed number equals the executed number with no tick approximation.

Search is fast and approximate under a hard floor; the binding quote is exact.
Tightening the search itself to a tick-aware quote — shrinking the gap before the
floor engages — is the natural next refinement.

## 6. Execution

The Solver produces a route; the Router executes it atomically or reverts, and is
the only contract that moves funds. It walks the route's hops in sequence and
dispatches each leg to the venue-appropriate primitive by kind:

- **V2 / Solidly** — push-then-swap with on-path output; the fee-on-transfer
  branch recomputes from the *measured* received balance.
- **V3 / Algebra / CL** — callback swap with the pool committed in transient
  storage; the callback may pull at most the current leg's budget.
- **V4** — `unlock → swap → sync → settle → take`; hooks that return deltas are
  rejected up front.

A bridge route's second stage is rescaled against the **actual** balance the first
stage produced, not the quoted balance. After execution the floor is enforced on
the realised output, the fee is charged (surplus above the attested quote is
fee-exempt), and the Router ends with zero residual balance.

## 7. Validation summary

The claim of stateful invariant fuzzing and ~85 real-liquidity fork cases could
not be verified (no test source exists in this repository's history) and is
carried over from a prior version of this document. As of the 2026-08
reconstruction pass, routing logic itself (Solver's median filter, capital
anchor, capacity clamp, bridge topology) has no dedicated test coverage yet —
see `../TESTING.md` for what is actually tested (Core, Hub, and the Router's V2
execution path). The one known design limitation, independent of test coverage,
is the single-tick search approximation of §5; the on-chain floor is its
backstop regardless of how well-tested the search path is.
