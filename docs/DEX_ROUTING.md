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

> **CORRIGIDO 2026-08-21 — esta secção estava desactualizada.**
> A afirmação "the full CREATE2 sweep is the dominant cost of an on-chain solve"
> e a tabela de −72% a −80% abaixo foram **refutadas por medição**:
>
> | onde | descoberta / solve |
> |---|---|
> | harness local (mock) | 95.663 de 208.844 |
> | **fork da Base @49.800.000** | **75k de 2,17M = 3,4%** |
>
> O custo dominante é a **cotação** — até 8 candidatos por par (`MAX_CANDIDATES`),
> 3 pares por solve, cada um com `universalQuote` (delegatecall + staticcalls à
> pool). E o portão de frescura que saltaria a descoberta **quase nunca dispara**:
> `MIN_FRESH_VENUES = 3` por par, mas o `recordSwap` só regista as pernas
> **executadas** (1-2 por par desde o colapso single-leg), logo `rn < 3` sempre.
> Ver `test/fork/DiscoveryCostBreakdown.t.sol` e `test/fork/OnchainDiscoveryCost.t.sol`.


~~The full CREATE2 sweep is the dominant cost of an on-chain solve. The registry
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

- **Search quote (Solver).** The route space is scored with the Core's output
  functions. A V4 pool is quoted by walking its own book: the Core reads the
  pool's price, liquidity, tick bitmap and ticks from the PoolManager through
  `extsload` and applies the manager's own step arithmetic over up to sixteen
  stretches (`Core.v4WalkOut`), so the figure that ranks a V4 venue is the
  figure its leg promises and the Router re-quotes in frame. V3-family pools are
  scored on the current tick's liquidity under a capacity clamp against the
  pool's real balance. Any divergence from the realised fill is bounded on-chain
  by the iron floor: a route whose realised output falls below the re-derived
  floor **reverts** rather than fills — the worst case is a failed transaction,
  never a silently bad one.
- **Binding quote (Quoter).** The trader-facing number is produced by the Quoter's
  exact pass — *revert-extraction*: the pool's own swap is run and rolled back, so
  the displayed number equals the executed number with no tick approximation.

Search is fast under a hard floor, tick-aware for V4; the binding quote is exact.

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

Measured on this tree (2026-09-24), by the commands in [`../TESTING.md`](../TESTING.md):
236 `.t.sol` files — 209 local, 27 on forked live liquidity — holding 1,609
`test*` / `invariant*` / `check*` declarations, 43 of them stateful `invariant_*`
campaigns; and 268 curated mutants, each paired with the named test that must fail
when it is applied. The routing logic this document describes is tested by name:
the split gate against every survivor (`test/SplitGateSeesEverySurvivor.t.sol`),
the capacity clamp (`test/RouterPhysicalMassCap.t.sol`), the bridge term of the
registry (`test/FrozenAtWriteProbes.t.sol`), the V4 walk against a specification
swap (`test/V4TickWalk.t.sol`), and a hostile-venue matrix
(`test/regime/HostileVenueMatrix.t.sol`). Every merge is gated by the suite, the
mutation guard, fork tests on an archive RPC, Halmos and Certora proofs, Slither,
Aderyn, and an EIP-170 size guard with margin. The on-chain floor bounds any
divergence between a search quote and the realised fill (§5).
