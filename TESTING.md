# Testing

> Status: broad, not complete. This file replaces a previous version
> referenced by `docs/WHITEPAPER.md` and `docs/DEX_ROUTING.md` that described
> a "51 offline tests + ~85 fork cases, no security bug found" campaign. That
> claim could not be verified — no `.t.sol` source exists anywhere in this
> repository's history prior to this suite, only prose describing it. What
> follows is the actual, current suite, written from scratch and measured
> against real mainnet liquidity where noted below.

## Running

```bash
forge install   # first time only — pulls forge-std into lib/
forge build
forge test -vvv                              # unit + invariant (no network needed)
forge test --match-path "test/fork/*" -vvv    # fork tests — need RPC access (see foundry.toml)
```

Fork tests read the `base` / `mainnet` endpoints configured in `foundry.toml`.
They cost real time (cold multi-venue discovery against a live chain is not
cheap — see `REPORTS.md`) and are excluded from the default `forge test` run
via `--no-match-path "test/fork/*"` in CI-style invocations.

## Coverage by file

| File | What it covers |
|---|---|
| `test/BlazePhoenixCore.t.sol` | `vitality()` decay (incl. a regression for a previously-shipped 128×-too-fast decay bug, and the shift>31 hard-cutoff-to-zero edge case), `mulDiv`/`mulDivUp` correctness (incl. a property-based fuzz test), `ironFloorBps` bounds (96% base, 80% hard floor), `hookAltersDeltas` V4 bit decoding, packed-slot encode/decode round-trips, `psi` bridge/concentration bonuses, `impactV2Bps`/`impactV3Bps`, `depthBucket`/`bucketWeight`, `tickSlot`, `outV2` edge cases, `sortTokens`, `hasCode`, and — via `test/mocks/CoreHarness.sol`, a thin external wrapper around the library's internal functions — `safeTransfer`/`safeTransferFrom`/`safeApprove`/`balanceOf` against no-return-data (USDT-style), return-false, and fee-on-transfer token behavior, plus a regression for `balanceOf` returning 0 (not scratch-memory garbage) against a codeless address. |
| `test/BlazePhoenixHub.t.sol` | Regression proving `addV4` registers a pool under the exact key `recordSwap` looks up later; the full `addFactory` coherence-guard matrix (invalid kind/mode, CREATE2-needs-initHash, salt-slot↔kind coherence, Algebra zero-fee sentinel, `MAX_FACTORIES` cap); bridge add/remove (cap, array-shift, flag-clear); `seedPool`; `recordSwap` access control, ticking, and the eviction/insertion-margin logic at `MAX_SLOTS`; `discoverFor` against a factory-call mock (incl. the `hasCode` guard discarding a codeless derived address); `renounceControl` scope (curator powers survive, control powers don't, including `addBridge`/`addFactory` specifically); `initialize` front-running guard. |
| `test/BlazePhoenixSolver.t.sol` | The median-rate filter excluding a stale-priced outlier; the capital anchor overriding a naive dust-majority median; the two-tier `MAX_CONC_DRAIN_BPS` capacity clamp (promise-only vs. input-cut regimes); depth-weighted split proportionality; bridge-topology selection and best/fallback ranking; the `MAX_CANDIDATES` funnel cut keeping the top-weighted survivors; the `_registryFresh` discovery gate (both "runs when cold" and "skips when warm" behavior, verified against a factory mock). |
| `test/BlazePhoenixQuoter.t.sol` | `previewPlan`/`previewPlanWithMinOut`/`previewRoute` packing math (fee, safety buffer scaling/cap, floor composition, `canExecute`); the documented fee-vs-floor divergence from the Router's real execution path; `batchQuote` (`MAX_BATCH` revert, mixed success/silently-zeroed failure); `previewPlanExact`'s revert-extraction dry-run for both a V3 leg (via `MockV3Pool`) and a plain V2 leg; callback-misuse guards (`fallback()` on short calldata, `unlockCallback` from a non-manager). |
| `test/BlazePhoenixRouter.t.sol` | Regression proving the protocol fee is charged on an on-chain-verified quote of the legs as executed, not on a caller-suppliable `route.totalOut`; deadline/zero-amount/empty-hops/below-userMinOut reverts; pause; the full admin/control access matrix including permanent lock-out after `renounceControl`; direct-invocation callback auth (`fallback()` with no expected pool set, `unlockCallback` from a non-manager); a full V3 leg execution against `MockV3Pool` (incl. the "pool demands more than committed input" guard); the **reentrancy guard**, proven via `MaliciousReentrantERC20`, whose `transferFrom` attempts a nested `swapExactIn` call mid-pull — the outer swap completes, the nested attempt is blocked by `nrEntrant`; a plain ETH transfer reverting instead of being silently trapped. |
| `test/BlazePhoenixRouter.invariant.t.sol` | **Stateful (Monte Carlo) invariant fuzzing** via a handler contract driving random swaps across a small token/pool universe: `invariant_RouterHoldsNothing` (the Router never retains a residual balance of any touched token across any sequence of successful/failed swaps) and `invariant_FeeNeverExceedsProtocolMax` (every collected fee stays within `PROTOCOL_FEE_BPS` of its own gross output). Both run 50×50 (2,500 calls) by default — see `[invariant]` in `foundry.toml` for why, and how to raise it on real hardware/CI. |
| `test/GasReport.t.sol` | Not correctness tests — a measurement harness for gas (legs/hops/discovery/exotic-token scaling), price impact across trade sizes, and slippage/stale-quote-floor behavior. See `REPORTS.md` for the actual numbers and how they compare to published Uniswap/aggregator benchmarks. |
| `test/fork/BaseFork.t.sol` | End-to-end against **live Base mainnet state** via `vm.createSelectFork`: deploys the full stack through `test/fork/BaseTestDeploy.sol`'s real wiring (9 real factories, real bridges), previews and **executes** a real USDC→WETH swap through real Uniswap V3/Aerodrome liquidity, confirms delivered output and the holds-nothing invariant against real balances. |
| `test/fork/EthereumCurveFork.t.sol` | End-to-end against the **real Curve 3pool** on Ethereum mainnet: `curveResolveIndices` matches the pool's real `coins()` order, `curveGetDy` returns a real live quote, and a full execution through the Router's `exchange()` adapter succeeds against real Curve bytecode — the ABI-quirk class (int128 vs uint256 `exchange` signatures, tricrypto-NG accepting-but-not-paying) that no mock can validate. |
| `test/fork/BaseTop100.t.sol` | Sweeps `previewPlan` across the **top-100 real Base tokens by global CoinGecko market-cap rank** (addresses fetched via the CoinGecko public API, not hand-typed — see `test/fork/Top100BaseTokens.sol`). Asserts a sanity floor (`routeFound > 10`) meant to catch a broken deployment, not genuine long-tail illiquidity. Results and root-cause breakdown of the misses: see `REPORTS.md`. |
| `test/fork/DiscoveryDiag.t.sol` | One-off diagnostic distinguishing, for each `BaseTop100` miss, "no pool exists on any wired venue" from "a pool exists but the Solver still couldn't build a route" — see `REPORTS.md` for the pattern analysis. |

## Mocks (`test/mocks/`)

| Mock | Purpose |
|---|---|
| `MockERC20.sol` | Configurable ERC20: no-return-data, return-false-on-failure, fee-on-transfer. |
| `MockV2Pair.sol` | Minimal Uniswap-V2-shaped pair: configurable reserves, permissive `swap()`. |
| `MockV3Pool.sol` | Minimal Uniswap-V3-shaped pool: single-tick, quotes via the same `outV3` formula the Core library uses (quote == execution by construction), the universal callback auth path, and an `overDemand` flag for the "pool demands more than committed input" guard. |
| `MockSolidlyPair.sol` | Minimal Solidly/Aerodrome-shaped pair: `getAmountOut` primary path + replicated-curve fallback. |
| `MockV2Factory.sol` | Minimal factory-call-family mock (`getPair`) for exercising `Hub.discoverFor` without CREATE2. |
| `MaliciousReentrantERC20.sol` | A working ERC20 whose `transferFrom` can attempt a nested call into an arbitrary target — used to prove the reentrancy guard. |
| `CoreHarness.sol` | Thin external wrapper around `BlazePhoenixCore`'s internal functions, so a library's pure/view helpers are directly unit-testable. |

## Known gaps (still not covered)

- **Balancer V2** (`KIND_BALANCER_V2`): investigated, not tested, because it
  isn't a real integration yet — `Core.universalQuote` and
  `Router._execScaled` currently alias it to plain V2 constant-product math
  and the V2 `swap()` call shape, which does not match a real Balancer V2
  pool (no `getReserves()`, no per-pool `swap()` — trading goes through a
  central Vault's `batchSwap`). No deploy script registers a Balancer
  factory. Needs a real Vault-based adapter before it can be tested
  meaningfully, not a mock reusing V2 semantics.
- **Arbitrum/Optimism fork tests** — only Base and Ethereum are covered by
  live-liquidity fork tests.
- **MEV/sandwich simulation** in the adversarial sense (a bot front-running
  a pending swap) — the floor mechanisms are unit- and invariant-tested for
  *rejecting* a bad fill, but no test simulates the attacker's side of an
  actual sandwich.
- **Deeper invariant runs** — the default `[invariant]` profile in
  `foundry.toml` is deliberately modest (50×50) for this repo's dev
  hardware; raise `--invariant-runs`/`--invariant-depth` for a stronger
  search on real CI.
- **Curve/Stable (`KIND_STABLE`) discovery** via `Hub`'s `MODE_CURVE_META`
  meta-registry scan — `EthereumCurveFork.t.sol` registers the real 3pool
  directly via `seedPool` to isolate and prove the execution adapter, but
  does not exercise the meta-registry `find_pool_for_coins` discovery path
  itself against a real registry address.

Do not assume anything outside this list is untested, and do not assume
anything *inside* it is broken — it just hasn't been verified yet. Treat
`REPORTS.md` as the actual measured, current state, not a claim.
