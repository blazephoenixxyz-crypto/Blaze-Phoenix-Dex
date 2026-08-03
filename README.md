# Blaze Phoenix

A fully on-chain, multi-venue DEX router. Route solving runs **on-chain** — anyone
can obtain a trustless quote with a free `eth_call`, and execution re-derives the
safety floor on-chain so a submitted route cannot misrepresent its guarantees.
One codebase deploys unchanged across Ethereum, Arbitrum, Base and Optimism.

> **Status:** unaudited research/engineering preview.

## Highlights

- **On-chain solving, off-chain-free.** The Solver evaluates direct and bridged
  routes on-chain; quoting is a `view` call, so users pay nothing for a trustless
  quote. No off-chain solver, relayers, or signing infrastructure.
- **Router as enforcer.** The Router executes the route it is given but does not
  trust it: the protocol floor is recomputed on the *realised* output from
  *measured* impact, never read from caller-supplied fields.
- **Deterministic discovery.** Venues are derived by CREATE2 — no hardcoded pool
  addresses — with a freshness-gated registry shortcut that cuts the on-chain
  solve cost by ~70% on a warm pair.
- **Broad venue coverage.** Uniswap V2/V3/V4, SushiSwap V2/V3, PancakeSwap V2/V3,
  Aerodrome & Velodrome (Solidly), Velodrome CL, Camelot (Algebra).
- **Pass-through & ossifiable.** The Router holds zero token balance between
  swaps; control powers can be permanently renounced.

## Architecture

| Contract | Responsibility |
|---|---|
| `BlazePhoenixHub` | Venue registry, deterministic discovery, fitness, bridges, V4 registration, roles, ossification. |
| `BlazePhoenixSolver` | On-chain route construction, splitting, bridge topologies, conservative quoting. |
| `BlazePhoenixRouter` | Execution + on-chain floor/fee enforcement; AMM callbacks; reentrancy guard. |
| `BlazePhoenixQuoter` | View-only quoting, including an exact revert-extraction pass. |
| `BlazePhoenixCore` | Shared library: AMM math, floor derivation, safe transfers, fitness codec. |

## Repository layout

```
src/      protocol contracts
test/     offline suite + test/fork/ real-liquidity metrics & invariants
docs/     DEX_ROUTING.md, WHITEPAPER.md
```

## Build & test

```bash
forge build
forge test --no-match-path "test/fork/*"   # offline suite (no RPC)
```

Fork suites need a per-chain RPC and run one chain at a time — see
[`TESTING.md`](TESTING.md).

## Documentation

- [`docs/DEX_ROUTING.md`](docs/DEX_ROUTING.md) — the routing design.
- [`docs/WHITEPAPER.md`](docs/WHITEPAPER.md) — the full technical whitepaper.
- [`audit/SCOPE.md`](audit/SCOPE.md) — risk-ranked review scope for auditors.
- [`TESTING.md`](TESTING.md) — how to run the test campaign.

## License

Business Source License 1.1 (BUSL-1.1). See the SPDX headers in `src/`.

## Disclaimer

This software is provided “as is”, without warranty of any kind. It is unaudited
and may contain errors. Nothing here is financial advice or an offer of any kind.
