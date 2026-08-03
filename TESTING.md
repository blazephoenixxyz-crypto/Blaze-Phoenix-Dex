# Testing

Two tiers: an **offline** suite (no network, deterministic, CI-friendly) and a
**fork** suite that runs against real mainnet / L2 liquidity. The fork suite
skips automatically when its RPC env vars are unset, so the offline suite always
stays green.

```bash
forge build
forge test                                  # everything; fork suites run only if their RPC vars are set
forge test --no-match-path "test/fork/*"    # offline battery only — always safe, no RPC
```

> If your shell already exports `ETH_RPC_URL` / `ARB_RPC_URL` / … then a bare
> `forge test` will try to run **all** fork suites across every chain at once.
> On a rate-limited (free-tier) RPC that triggers HTTP 429 failures — those are
> infra, not code. For an offline-only run use `--no-match-path "test/fork/*"`;
> run fork suites one chain at a time with the throttle flags below.

---

## Offline suite (no RPC)

| File | What it covers |
|---|---|
| `test/CoreMath.t.sol` | Core AMM math (V2/V3/Solidly/Curve quote primitives, floor derivation). |
| `test/HubFuzz.t.sol` | Hub registry fuzzing (factory/bridge registration coherence). |
| `test/HubInvariant.t.sol` | Hub stateful invariants. |
| `test/RouterAdmin.t.sol` | Router admin / control surface (roles, treasuries, pause, renounce). |
| `test/SolverEquivalence.t.sol` | Differential equivalence vs. the previous Solver (`test/refs`). |
| `test/BenchGas.t.sol` | Gas benchmarks. |
| `test/RouterCallbackAuth.t.sol` | **Callback auth** — unsolicited V3 fallback & V4 `unlockCallback` are rejected (the classic router-drain vector). |
| `test/RouterExecGuards.t.sol` | **Exec-path guards** — reentrancy (`RouterE 7`) and V4 hook-alters-deltas (`RouterE 9`), driven through a mock executable V2 venue. |
| `test/RouterStatefulInvariant.t.sol` | **Stateful invariants (single leg)** — pass-through (no dust at rest) + per-token conservation over long random swap sequences. |
| `test/RouterMultiHopInvariant.t.sol` | **Stateful invariants (multi-hop)** — same, on a 2-hop bridge path; asserts the intermediate token is never stranded in the Router. |
| `test/RouterSplitInvariant.t.sol` | **Stateful invariants (intra-hop split)** — same, splitting one hop across two pools; asserts no per-leg allocation remainder is stranded. |

Run a single suite, e.g.:

```bash
forge test --match-contract RouterCallbackAuthTest -vv
forge test --match-contract RouterExecGuardsTest   -vvv
```

The three stateful suites are full Foundry invariant runs (a bounded handler
drives random swap sequences). Crank them up for long-running fuzzing:

```bash
FOUNDRY_INVARIANT_RUNS=2000 FOUNDRY_INVARIANT_DEPTH=256 \
  forge test --match-contract RouterMultiHopInvariant -vv
```

Each stateful suite checks two protocol-wide invariants across the whole
sequence:

- **pass-through** — the Router retains 0 of every token at rest (no funds ever
  trapped, including bridge intermediates and split remainders).
- **conservation** — per token, the sum of all holders' balances equals the
  total minted into the system (no value created or destroyed).

---

## Fork suite (needs an archive/full RPC)

Set the RPC for the chain(s) you want and (recommended) **pin a block** so the
fetched state is cached on disk — the first run hits the RPC, later runs fly:

```bash
export ETH_RPC_URL="https://eth-mainnet.g.alchemy.com/v2/<KEY>"
export ETH_FORK_BLOCK=$(cast block-number --rpc-url "$ETH_RPC_URL")
# L2s: ARB_RPC_URL / BASE_RPC_URL / OP_RPC_URL  (+ *_FORK_BLOCK)
```

On a rate-limited (free-tier) RPC, throttle and serialize to avoid HTTP 429:

```bash
forge test --match-contract <Name> -vv --compute-units-per-second 100 --threads 1
```

| File | What it covers |
|---|---|
| `test/fork/ForkMetricsBase.sol` | Shared base: fork bootstrap, deploy, `_report` (gas cold/warm, hops, legs, realised/quote) and `_sweep`. |
| `test/fork/ForkMetrics.t.sol` | **Ethereum** metrics — direct / stable / WBTC / exotic / exotic→exotic + size sweeps. |
| `test/fork/ForkL2Metrics.t.sol` | **Arbitrum / Base / Optimism** metrics — exercises the off-mainnet adapters: Camelot (Algebra), Aerodrome/Velodrome (Solidly), Velodrome CL, Uniswap V4. |
| `test/fork/RouterInvariants.t.sol` | **Property/fuzz invariants** over the exec path (P1–P7 below). |

Run examples:

```bash
forge test --match-path test/fork/ForkMetrics.t.sol -vv --compute-units-per-second 100 --threads 1
forge test --match-contract ForkBaseMetrics       -vv --compute-units-per-second 100 --threads 1
FOUNDRY_FUZZ_RUNS=64 forge test --match-contract RouterInvariants -vv --compute-units-per-second 100 --threads 1
```

The per-chain venue wiring mirrors the local deploy scripts
(`script/Deploy*.s.sol`, kept out of version control) so the fork tests exercise
the exact production configuration.

### Router invariants (P1–P7)

For each fuzzed fill against real liquidity:

- **P1** truthful reporting — return value == recipient balance delta
- **P2** slippage honored — a successful fill delivers ≥ `userMinOut`
- **P3** unreachable `minOut` reverts, never fills
- **P4** no trapped funds — the Router holds 0 extra tokenIn/tokenOut afterwards
- **P5** fee cap — protocol fee ≤ realised output × 0.28% (+rounding)
- **P6** surplus is fee-exempt — fee charged on at most the attested quote
- **P7** fee split — treasury 30/70 shares match the constants

---

## What these tests do NOT replace

The suites raise confidence in behaviour, **not** a clean bill of health. Still
required before production:

- External security **audit** and **formal verification** of the floor/fee math
  and the V4 / flash callback accounting.
- Long-running **stateful invariant** fuzzing of the execution path.
- Review of the Curve / Stable adapters before they are re-enabled (disabled in
  v1.0 — see `BlazePhoenixHub.addFactory`).
- Multisig / timelock control of admin powers (or `renounceControl`).
