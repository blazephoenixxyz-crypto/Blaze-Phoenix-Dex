# BlazePhoenix Protocol — V2 Contracts

On-chain multi-venue DEX router/aggregator for the EVM (Uniswap V2/V3/V4,
Solidly/Aerodrome, Algebra/Camelot, Curve — see `docs/WHITEPAPER.md`). Route
solving runs entirely on-chain (`Solver.findBestRoutePlan`, a free `view`
call, no oracle, no off-chain solver); the Router never trusts the route it
is handed and re-derives its safety floor and protocol-fee base from
realised execution, not caller-supplied calldata.

> [!WARNING]
> **Unaudited. Experimental. Not deployed to a chain with real value.**
> `dev-v2` is a reconstruction pass over the canonical V2 contracts that
> applies fixes derived from an internal research series, adds a
> from-scratch Foundry test suite (unit, stateful invariant fuzzing, and
> tests against live mainnet liquidity), and measures its own gas/impact/
> slippage rather than repeating unverified prior claims. See
> `docs/WHITEPAPER.md` §7-8, `TESTING.md`, and `REPORTS.md` for exactly what
> has and has not been verified. Do not deploy this to a chain where it will
> custody real value without an independent external security review.

## What this is

- **Router** (`BlazePhoenixRouter.sol`) — executes a route leg by leg across
  five auth entry points (classic, Permit2, EIP-7702) and five AMM kinds
  (V2-style push-swap, V3-style callback, Solidly, Curve `exchange`, V4
  unlock/settle), re-deriving its output floor and protocol-fee base from
  what actually executed on-chain, never from the caller's claim.
- **Solver** (`BlazePhoenixSolver.sol`) — a pure `view` route optimizer:
  depth-weighted splitting across up to 5 legs, a median-rate filter with a
  capital-anchor override (dust pools with a stale price can't out-vote a
  deep pool with the true one), a two-tier capacity clamp for concentrated
  liquidity, and direct/via-bridge topology ranking.
- **Hub** (`BlazePhoenixHub.sol`) — the on-chain pool registry: a single
  packed 256-bit slot per pool (one SLOAD for its fitness score),
  permissionless CREATE2/factory-call discovery, and automatic
  registration with vitality-weighted eviction once a pair's slot table is
  full.
- **Quoter** (`BlazePhoenixQuoter.sol`) — the read-only mirror of the
  Router, plus a revert-extraction "exact" preview mode that dry-runs real
  V3/V4 pool swaps for a truth-corrected quote (the same technique the
  official QuoterV2/V4Quoter use).
- **Core** (`BlazePhoenixCore.sol`) — the shared library: AMM quote math for
  every supported kind, CREATE2/factory pool-address derivation, the packed
  pool-state encoding, and the output-floor formula.

## Layout

```
src/            the 5 canonical contracts (Core, Hub, Quoter, Router, Solver)
script/         forge scripts (the operational multi-chain deploy config is
                not published here — see "Deploying" below); includes an
                anvil demo swap script
test/           Foundry test suite + mocks — unit, invariant fuzzing, and
                fork tests against live mainnet liquidity (see TESTING.md)
docs/           architecture (WHITEPAPER.md) and routing internals (DEX_ROUTING.md)
TESTING.md      what is and isn't covered, file by file
REPORTS.md      measured gas / price-impact / slippage numbers, and how they
                compare to published external benchmarks — not estimates
```

## Build & test

```bash
forge install                                  # first time only — pulls forge-std into lib/
forge build
forge test -vvv                                # unit + invariant (no network needed)
forge test --match-path "test/fork/*" -vvv     # fork tests — need RPC access, see foundry.toml
```

`foundry.toml` ships two profiles: `default` (fast local iteration,
`optimizer_runs = 1000`) and `release` (`FOUNDRY_PROFILE=release forge build`,
`optimizer_runs = 999999` — the real gas-optimized build to use before an
actual deploy).

## Deploying

The operational deploy scripts (per-chain venue wiring, treasury
configuration) are intentionally not part of this public repository. The
fork tests under `test/fork/` use a test-only helper
(`test/fork/BaseTestDeploy.sol`) that wires the same public, well-known
factory/bridge addresses a real deploy would, with placeholder test
treasuries, so the test suite exercises real discovery and execution
without depending on the actual deploy configuration.

## License

[Business Source License 1.1](./LICENSE) (BUSL-1.1). Converts to
GPL-2.0-or-later on 2030-06-01. Copyright (c) 2026 BlazePhoenix Protocol.
Test/mock files under `test/` are MIT-licensed individually (see their SPDX
headers) — only the contracts in `src/` are BUSL-1.1.
