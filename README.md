# BlazePhoenix Protocol — V2 Contracts

On-chain multi-venue DEX router/aggregator for the EVM (Uniswap V2/V3/V4,
Solidly/Aerodrome, Algebra/Camelot, Curve — see `docs/WHITEPAPER.md`). Route
solving runs entirely on-chain (`Solver.findBestRoutePlan`, a free `view`
call, no oracle, no off-chain solver); the Router never trusts the route it
is handed and re-derives its safety floor and protocol-fee base from
realised execution, not caller-supplied calldata.

> [!NOTE]
> **Status: pre-audit.** The contracts are feature-complete and verified in
> depth in-house: 183 passing offline tests — unit coverage plus stateful
> invariant fuzzing against hostile pools, tokens and V4 managers — alongside
> fork tests that execute real swaps against live mainnet liquidity. Gas,
> price impact and slippage are measured directly rather than asserted
> (`REPORTS.md`), and `docs/WHITEPAPER.md` §7-8 and `TESTING.md` document
> precisely what is and isn't covered so far. An independent external
> security review is the remaining gate before the protocol custodies real
> value on a production chain.

## What this is

- **Router** (`BlazePhoenixRouter.sol`) — executes a route leg by leg across
  four entry points (classic, Permit2, native-ETH, and a fully-on-chain
  solve+execute; EIP-7702 flows use the classic path unchanged) and five AMM kinds
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
`optimizer_runs = 999999`).

> [!WARNING]
> **Deploy with the default profile, not `release`.** At 999,999 runs the Yul
> optimizer inlines aggressively enough to push `BlazePhoenixSolver` to 25,326
> bytes — 750 bytes over the EIP-170 limit, so the artifact cannot be deployed.
> `forge build` still exits 0 and writes it, so the failure only surfaces on
> chain. The default profile builds every contract within the limit (Solver
> 21,922, margin 2,654). See `REPORTS.md` for the full per-contract table.

## Deploying

The operational deploy scripts (per-chain venue wiring, treasury
configuration) are intentionally not part of this public repository. The
fork tests under `test/fork/` use a test-only helper
(`test/fork/BaseTestDeploy.sol`) that wires the same public, well-known
factory/bridge addresses a real deploy would, with placeholder test
treasuries, so the test suite exercises real discovery and execution
without depending on the actual deploy configuration.

## Security & bug bounty

The design doctrine is **verification over attestation**: the source is public
and verified, safety properties are re-derived on-chain at execution rather than
trusted from calldata, and every reported issue is reproduced against this repo's
own code and closed with a regression test that fails on the old code and passes
on the fix.

- **Open, permissive bounty.** Read the verified source, find a real issue, report
  it — you're credited in [`SECURITY_HALL_OF_FAME.md`](./SECURITY_HALL_OF_FAME.md)
  and, once the pool is funded, paid.
- **Private disclosure:** **security@blazephoenix.xyz** / blazephoenixxyz@proton.me.
  Non-critical reports may be filed as a GitHub issue.
- Fix internals are kept brief in public — the verified source and the tests are
  the record.

Recent: a **High**-severity route-scaling / capacity-clamp interaction reported by
[NetGakarot](https://github.com/NetGakarot) — validated, fixed and regression-tested
(`test/RouterUndoesSolverCapacityClamp.t.sol`).

## License

[Business Source License 1.1](./LICENSE) (BUSL-1.1). Converts to
GPL-2.0-or-later on 2030-06-01. Copyright (c) 2026 BlazePhoenix Protocol.
Test/mock files under `test/` are MIT-licensed individually (see their SPDX
headers) — only the contracts in `src/` are BUSL-1.1.
