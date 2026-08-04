# Reports — gas, price impact, slippage, real-liquidity coverage

Measured 2026-08-04 during the dev-v2 reconstruction/test pass. All numbers
come from actual `forge test` runs against this repo's code — not estimated,
not carried over from the whitepaper's prior (unverifiable) claims. Regenerate
any of these by running the exact command listed above each section.

Two data sources:
- **Mock-pool measurements** (`test/GasReport.t.sol`) — constant-product math
  against `MockV2Pair`/`MockV3Pool`, no real-world MEV/latency. Useful for
  *relative* comparisons (legs vs legs, factories vs factories), not as an
  absolute mainnet gas budget.
- **Real-liquidity fork tests** (`test/fork/*.t.sol`) — `vm.createSelectFork`
  against live Base/Ethereum mainnet state via the RPCs in `foundry.toml`.
  These prove the discovery → solve → quote → execute pipeline against actual
  deployed factories and pools, not mocks.

## Gas — legs, hops, discovery, exotic tokens

`forge test --match-contract GasReport -vv`

| Scenario | Gas used |
|---|---|
| 1 leg (direct) | 181,307 |
| 2 legs (depth-split) | 210,044 |
| 3 legs | 238,796 |
| 5 legs | 296,273 |
| **Marginal cost per extra leg** | **≈ 28,700 gas** |
| 1 hop (direct) | 181,325 |
| 2 hops (via bridge) | 240,305 |
| **Marginal cost of a bridge hop** | **≈ 59,000 gas** |
| `Hub.discoverFor`, 1 factory | 12,919 |
| `Hub.discoverFor`, 4 factories | 32,168 |
| `Hub.discoverFor`, 8 factories | 57,844 |
| `Hub.discoverFor`, 16 factories | 109,234 |
| **Marginal cost per registered factory** | **≈ 6,400 gas** (near-linear) |
| Normal ERC20 swap | 181,325 |
| No-return-data token (USDT-style) | 181,388 (+63) |
| Fee-on-transfer token as **tokenIn** | **fixed this session** — completes normally now, see Finding 1 below |

## Price impact across trade sizes (single 1M/1.6M-reserve mock pool)

`forge test --match-contract GasReport --match-test test_Impact -vv`

| amountIn | % of pool | totalOut | impactBps |
|---|---|---|---|
| 100e18 | 0.01% | 159.5e18 | 1 |
| 10,000e18 | 1% | 15,794e18 | 100 |
| 100,000e18 | 10% | 145,057e18 | 910 |
| 500,000e18 | 50% | 532,265e18 | 3,334 |

## Slippage / stale-quote behavior

`forge test --match-contract GasReport --match-test test_Slippage -vv`

- Quote immediately followed by execution, no intervening activity: realised
  output matched the quote **exactly** (75,760.034290612944706387e18 both
  sides) — no drift when nothing changes between quote and fill.
- A small (~0.1%) reserve move between quote and execution: realised output
  drifted **-19 bps** from the quote and the swap still completed (within
  the protocol floor's tolerance).
- A large (~19%) adverse reserve move on a 5%-of-pool trade: **rejected**
  with `RouterE(5)` — `route.singleOutFloor` (the Solver's own quote-time
  floor, ~91-96% of its own quote) caught it before the coarser per-leg
  75%/aggregate 80%-hard-cap floors would have.

## Real-liquidity fork results

### Base mainnet — `forge test --match-path "test/fork/BaseFork.t.sol" -vvv`
- Deployment wires real factories (Uniswap V3, Aerodrome, PancakeSwap V2/V3,
  SushiSwap, BaseSwap) and real bridges (WETH, USDC), confirmed via
  `hub.factoryCount() > 0` and `hub.isBridgeToken(...)`.
- `previewPlan(USDC, WETH, 1000e6)` against LIVE Base state found a real
  route (grossOut > 0, sane 0.0001-10 ETH band, `canExecute == true`).
- Full execution: `deal`'d 1,000 real USDC to a fresh user, ran the
  Solver-suggested route through the real Router, WETH delivered matched
  the Router's own return value exactly, Router held nothing (0 USDC, 0
  WETH) afterward — the holds-nothing invariant verified against a real
  multi-venue path, not just mocks.

### Ethereum mainnet Curve 3pool — `forge test --match-path "test/fork/EthereumCurveFork.t.sol"`
- `curveResolveIndices` against the real 3pool (`0xbEbC...FF1C7`) correctly
  resolved USDC→index 1, DAI→index 0 (matches 3pool's real `coins()` order).
- `curveGetDy` quote for 1,000 USDC → ~999.97 DAI (a live, balanced-pool
  stable quote, not a replicated formula).
- Full execution via the Router's `exchange()` adapter against the real
  pool succeeded, delivered DAI matched exactly, Router held nothing after.

### Base top-100 real tokens — `forge test --match-path "test/fork/BaseTop100.t.sol" -vv`
See `test/fork/Top100BaseTokens.sol` for the address list (top-100 by global
CoinGecko market-cap rank among tokens with a verified Base deployment,
fetched via the CoinGecko public API on 2026-08-04, not hand-typed — solc's
own EIP-55 checksum errors were parsed back out to get correct casing rather
than computing checksums by hand). `previewPlan(USDC, token, 1000e6)` for
each of the 100:

| Result | Count |
|---|---|
| Route found (grossOut > 0) | **78** |
| No route (thin/no pool on wired venues, or transfer-restricted) | 21 |
| Self-pair (token IS USDC) | 1 |
| Avg gas per **found** quote | 1,512,835 (cold discovery: every pair is fresh, so every quote runs a full `discoverFor` sweep across all ~9 wired factories — see `_registryFresh`'s gate, which only pays off on repeat/warm pairs) |
| Total wall-clock | 1,138s for 100 live RPC-backed quotes (~11.4s/token) — this device's proot overhead + mobile RPC latency, not a contract cost |

Sample of what was found (symbol, grossOut for 1,000 USDC in, wei): AERO
2,422.8e18, LINK 121.04e18, AAVE 10.74e18, VIRTUAL 1,763.4e18, CRV 4,670.6e18,
PENDLE 727.5e18, KAITO 1,081.8e18.

**Root-cause breakdown of the 21 misses** — `forge test --match-path "test/fork/DiscoveryDiag.t.sol" -vv`
(one-off diagnostic, calls `hub.discoverFor` directly on each miss to
distinguish "no pool at all" from "pool exists but still no viable route").
All 21 have real bytecode (`extcodesize > 0` — not dead/fake addresses):

| Pattern | Count | Tokens |
|---|---|---|
| Zero pools found by any of the 9 wired factories | 16 | EURSAFO, EUTBL, JTRSY, JAAA, USD0, USTBL, SAFO, THBILL, ALFW, BRLV, RIF, HOT, FT, XVS, BR, MGLO |
| Pool(s) *found* by discovery, but Solver still couldn't build a route | 5 | USDAI (3 hits), APYUSD (1 hit), O (3 hits), CYS (2 hits), ZCHF (1 hit) |

The 16-token group is almost entirely tokenized RWA/fund products (JTRSY =
Superstate short-duration treasury fund, JAAA = Superstate AAA CLO fund,
USD0/USTBL/THBILL-shaped names) that trade by redemption, not on public
AMMs — "no route" is the *correct* answer, not a gap. RIF/HOT/FT/XVS/BR/MGLO
are real projects that plausibly just have no Base-native pool on the 9
wired venues (could be primarily on other chains, or on a Base DEX not yet
wired). The 5-token group is the more interesting pattern: a pool genuinely
exists and discovery found it, but it still didn't clear the Solver's bar —
most likely a near-empty/dust pool that quotes to 0 output, or one lone
candidate whose marginal rate got excluded by the median filter with nothing
else to anchor against. That's the capital-anchor/median-filter machinery
correctly refusing to route through a pool it can't trust, not a bug — but
it IS a distinct pattern from "no pool exists" and worth knowing apart from
the RWA group when reasoning about coverage.

Sanity floor: the test asserts `routeFound > 10`, specifically to catch a
*broken deployment* (wrong factories/bridges) rather than genuine
long-tail illiquidity — 78 clears that floor by a wide margin.

## Mock gas vs real gas — how close is the relative comparison to reality?

Investigated directly: the Base fork's real USDC→WETH route split across
**5 legs, 1 hop** (`test_Preview_USDCtoWETH_AgainstRealLiquidity`, `pv.legs
== 5`) — the SAME leg count as the mock report's `test_Gas_Legs_5` scenario.
Comparing the two directly:

| | Legs | Hops | Gas |
|---|---|---|---|
| Mock (`test_Gas_Legs_5`, all V2) | 5 | 1 | 296,273 |
| Real Base fork (`test_Execute_USDCtoWETH_AgainstRealLiquidity`) | 5 | 1 | 2,150,780 |

**~7.3x higher in reality, at the same leg count.** This is NOT a discovery
artifact (the route was already solved via a separate `previewPlan` call
before `swapExactIn` executes it — discovery cost is not double-counted
here). The gap is the mock's own stated limitation from the top of this
file: `MockV2Pair` is a deliberately minimal permissive mock, while the real
route mixes real Uniswap V3 / Aerodrome pools, whose actual bytecode does
real concentrated-liquidity tick math and (for V3) a full callback
round-trip back into the Router's `fallback()` per leg — meaningfully more
expensive than a V2-style push-then-`swap()`. **Conclusion: the mock gas
numbers in the "legs/hops/discovery/exotic-token" table above are reliable
for *relative* comparisons (this repo's own code paths against each other)
but understate *absolute* real-world gas by roughly an order of magnitude
whenever the route includes V3/concentrated-liquidity legs** — budget
accordingly for anything gas-sensitive (e.g. a UI gas estimate) rather than
extrapolating mock numbers directly to mainnet cost.

## On "full discovery on the first call" (dev question, not a code change)

Worth confirming explicitly, without touching `_registryFresh`/`MIN_FRESH_VENUES`
(as instructed): a brand-new pair *already* gets a full discovery sweep
today — `_registryFresh` only returns `true` (skipping discovery) once at
least `MIN_FRESH_VENUES = 3` registered pools exist and are recently active;
for a pair with 0 registered pools that's trivially false, so every one of
the 100-token sweep's quotes above ran full discovery across all 9 wired
factories. The "full on the first call" idea is already this codebase's
actual behavior, not a gap — the 1.5M-gas average per found quote in the
top-100 sweep IS that cost. The real lever available (not touched here) is
`MIN_FRESH_VENUES` / `DISCOVERY_TTL_SECONDS`, which trade gas for
staleness-risk on *repeat* queries against a pair that's already warm, not
the cold-start case.

## How do the real (fork) gas numbers compare to the broader ecosystem?

Researched published, external reference points (not this repo's own numbers)
to sanity-check whether the real-fork gas measurements above are in a
reasonable range, rather than treating them in isolation:

- **Single Uniswap V3 swap, one pool, direct**: industry-cited range is
  **~150,000-200,000 gas** ([Uniswap gas fees analysis](https://www.writereader.com/blog/uniswap-gas-fees-analysis-and-optimization-tips/)).
  This repo's own single-leg V2 mock (`test_Gas_Legs_1`, 181,307 gas) sits
  right in that band — a good sanity check that the simple case isn't
  obviously broken or bloated.
- **Multi-hop (sequential, e.g. A→B→C) vs direct**: cited at
  **+30-50% gas over a direct route** for one extra hop
  ([same source](https://www.writereader.com/blog/uniswap-gas-fees-analysis-and-optimization-tips/)).
  This repo's own bridge-hop measurement (+59,000 gas ≈ +33% over the
  181,325-gas direct baseline) lands squarely inside that published range.
- **Split routes (parallel legs within one hop, e.g. Uniswap's Auto Router
  spreading one trade across up to 7 pools)**: Uniswap's own documentation
  confirms splitting is gas-aware and "only taken when it results in a
  better net rate," with gas cost as an explicit, real overhead traded
  against better pricing — real Auto Router examples cite trades where the
  extra gas is "more than covered" by the pricing improvement
  ([Uniswap Auto Router](https://blog.uniswap.org/auto-router),
  [Auto Router V2](https://blog.uniswap.org/auto-router-v2)). No public
  source gives an exact per-leg split-route gas figure to compare against
  directly, so this repo's own real-fork measurement is the most concrete
  data point available: **the 5-leg real Base route averaged ≈430,156
  gas/leg** (2,150,780 ÷ 5) — roughly **2.1-2.9x** a bare single-pool V3
  swap's 150-200K baseline. That premium is consistent with what a
  multi-venue router does PER LEG beyond a plain swap: an on-chain re-quote
  of the leg for the fee-base derivation, a per-leg output-floor check
  (`LEG_FLOOR_BPS`), and a `Hub.recordSwap` registry write (an extra SSTORE)
  — none of which a bare direct Uniswap swap does. This is the measurable
  cost of BlazePhoenix's specific safety guarantees (fee-base
  manipulation resistance, per-leg sandwich floor, self-improving registry),
  not an unexplained anomaly — but it is real, and worth knowing before
  quoting gas to a UI/user.
- Academic grounding: [Adams, Chan, Markovich & Wan (2024), "Don't Let MEV
  Slip: The Costs of Swapping on the Uniswap Protocol"](https://arxiv.org/abs/2309.13648)
  find that **for small swaps, gas dominates total cost; for large swaps,
  price-impact/slippage dominates** — consistent with this repo's own price-
  impact table above (impact grows from 1 bps at 0.01%-of-pool to 3,334 bps
  at 50%-of-pool, while gas per swap stays roughly flat regardless of size).

## Literal anvil node (not just forge's fork cheatcodes)

Ran a real, standalone `anvil --fork-url https://mainnet.base.org` process
(not `vm.createSelectFork`), then a genuine `forge script ... --broadcast`
deployment against it, using this project's own (unpublished) deploy
configuration — real transactions, real addresses, persisted node state.

Result: Hub/Solver/Router/Quoter all deployed with real addresses, 9
factories wired, confirmed via plain `cast call` (not a forge cheatcode):
`cast call $HUB "factoryCount()(uint256)" --rpc-url http://127.0.0.1:8545` → `9`.

Then ran a real swap: impersonated a genuine external USDC holder (Base's
`L2StandardBridge`, `0x4200...0010` — NOT a DEX pool, deliberately, after
first hitting a self-inflicted bug using the Aerodrome pool itself as the
whale, which corrupted that pool's own reserve accounting before its own leg
executed — see below) via `anvil_impersonateAccount` + `anvil_setBalance`,
then broadcast a real `approve` + `swapExactIn` through
`script/AnvilDemoSwap.s.sol` (takes Router/Quoter/whale addresses as env
vars — no deploy-specific config baked in). Verified via `cast receipt`:
`status: 1 (success)`, `gasUsed: 1,052,440`, `to: <Router>`. 100 USDC in,
0.0532305...  WETH out, Router held 0/0 afterward.

**A genuinely interesting failure mode found along the way**: the first
attempt impersonated the Aerodrome USDC/WETH pool itself as the "whale"
funding the swap. That pool was ALSO one of the route's own legs. Pulling
USDC directly out of the pool via `safeTransferFrom` (bypassing its normal
`swap()`-based accounting) desynced its actual token balance from its
internally-tracked reserves, so when the route's own leg later tried to
swap against that same pool, its own invariant check reverted (custom error
`0x098fb561`, unrelated to any BlazePhoenix code — the revert happened
entirely inside the third-party pool's own bytecode). Not a contract bug —
a test-setup mistake (funding source and route participant must be
different entities) — but worth documenting since it's the kind of trap a
real integration test against mutable state can hit that an ephemeral
`vm.createSelectFork` snapshot won't.

## Findings surfaced by this measurement pass

1. **FIXED — fee-on-transfer tokenIn used to revert every time.** Hop 0's
   legs spent `leg.amountIn` exactly as the Solver planned it (the pre-fee
   amount) — unlike hop 1+, which measured `realIn = balanceOf(hop.tokenIn,
   this)` and rescaled every leg proportionally. `_swap`'s "received"
   measurement was taken correctly at the top-level pull, but `_execute`
   never used it to rescale hop 0 (only in the final residual-sweep math).
   The first leg then tried to push more than the Router actually held, and
   `safeTransfer` reverted — a DoS on this specific input shape, never a
   fund-loss path (the tx failed atomically). **Fix applied**: `_execute`'s
   scaling primitive (now `_hopScaleImpactAndQuote`) runs for every hop
   uniformly — hop 0 scales against the already-measured `amountIn`
   parameter (zero extra staticcalls), hop 1+ against a fresh
   `balanceOf(hop.tokenIn, this)` exactly as before. Verified: full mock
   suite (149 tests), both invariant suites (2,500 random calls each), and
   the real-liquidity Base/Curve fork tests all pass unchanged after the
   fix. See `test/GasReport.t.sol:test_Gas_Token_FeeOnTransfer_TokenInSucceeds`.
2. **`BlazePhoenixCore.balanceOf` could return garbage instead of 0 for a
   codeless address** (fixed this session — see `src/BlazePhoenixCore.sol`,
   the `returndatasize()==32` guard now added). Not exploitable (every path
   that could pay out real value is independently guarded by
   `safeTransfer`/`safeTransferFrom`'s `extcodesize` check), but was a real
   divergence from the documented "silently returns 0" behavior.
3. **`vitality()` has a hard cutoff at exactly 32 decay steps**: it returns
   literal `0` (not floored to `1` like 31 steps and below). A real,
   non-empty pool can score zero fitness once fully decayed. Not a
   fund-safety issue (a route-preference detail), but worth a deliberate
   design decision rather than an accidental boundary condition.
4. **`KIND_BALANCER_V2` is a non-functional stub.** Both `Core.universalQuote`
   and `Router._execScaled` alias it to plain V2 constant-product math and
   the V2 `swap(amount0Out, amount1Out, to, data)` call shape — real Balancer
   V2 pools have neither `getReserves()` nor a per-pool `swap()` (trading
   routes through a central Vault's `batchSwap`). No deploy configuration
   registers a Balancer factory. If Balancer support is wanted, it needs a
   real Vault-based adapter, not the current aliasing.

## Registry lifecycle — discovery cold vs warm, and the vitality trajectory

`forge test --match-contract LifecycleMetrics -vv` (added 2026-08-04). Controlled offline
setup: 4 factories, 4 V2 pools (1M/1M reserves), pools reachable ONLY via discovery so the
first solve genuinely pays cold-start cost.

| Phase | Gas |
|---|---|
| `discoverFor()` alone (4 factories) | 94,566 |
| Solve **COLD** (empty registry) | 169,093 |
| Solve **WARM** (registry fresh, discovery skipped) | 132,691 |
| Solve after `DISCOVERY_TTL_SECONDS` lapses | 170,542 |
| **Freshness-gate reduction** | **−36,402 (−21%)** |

| Swap | Gas |
|---|---|
| #1 (registers 4 pools, cold SSTOREs) | 658,859 |
| #2 | 185,908 |
| #3–#5 | ~186,000 |

Vitality trajectory (sum across the 4 pools): 4 after one swap → 20 after five → 8 after one
decay step (~6.8h) → **0** past the 32-step horizon (~9.1 days) → **4** after a reactivating
swap (NOT 20). That last figure is the R3 fix verified end-to-end through the real
`Router → Hub.recordSwap → tickSlot` path, not a direct unit poke.

### Two findings this measurement surfaced

1. **The freshness gate's reduction is 21% here, not the ~72-80% in `docs/DEX_ROUTING.md` §4.**
   Not a contradiction — the saving is proportional to the number of factories swept. With 4
   factories discovery is cheap, so skipping it saves little; the published table came from a
   ~9-factory real-chain setup. **The benefit scales with the deploy's factory count**, an
   environment assumption invisible in the contract logic. Quoting "−72%" without quoting the
   factory count is an incomplete claim.
2. **The first swap on a pair costs 3.5× the steady-state swap** (658,859 vs ~186,000) because
   it builds the registry for that pair. That cost is an uncompensated positive externality:
   nothing reimburses the trader who pays it.

### Consistency of the `vitality()` refactor

`vitality()` was changed to delegate its decay arithmetic to `_decayedSwapCount` (R5: one
implementation per published quantity) rather than carry a second copy. Verified by
differential fuzz rather than by "the suite is still green":
`test/VitalityRefactorEquivalence.t.sol` re-implements the pre-refactor version verbatim and
fuzzes both over the same inputs — **12,000 runs, zero divergence**, covering the branch
boundaries (dead slot vs floored-to-1 live slot, the 32-step horizon, the never-ticked
sentinel, clock underflow) and the `psi()` consumer. Consumer survey: `swapCount` is read by
exactly one function, and both `tickSlot` call sites are immediately wrapped in `_stampTs`, so
no tick-without-stamp path exists that could double-decay.

## Derivation mode and gas — a plausible optimisation, measured and refuted

`forge test --match-contract DiscoveryModeGas -vv` (added 2026-08-04).

`BPC.deriveAddress` resolves a pool two ways: modes 0-3 staticcall the factory (one call per
probe), modes 4-7 compute `keccak256(0xff‖factory‖salt‖initCodeHash)` locally with no calls.
The intuitive conclusion — "CREATE2 skips a CALL, so migrating factories to CREATE2 modes is a
large discovery saving" — is **wrong at any realistic factory count**. Both arms below discover
the same number of pools, so the delta is purely the derivation mechanism:

| Factories | Factory-call (mode 0) | CREATE2 (mode 4) | Saved |
|---|---|---|---|
| 1 | 12,978 | 8,732 | 4,246 (32%) |
| 4 | 30,008 | 29,031 | 977 (3%) |
| 9 | 69,479 | 67,298 | 2,181 (3%) |

| Marginal gas per extra factory | |
|---|---|
| factory-call | 7,062 |
| CREATE2 | **7,320** |

**At the margin CREATE2 is slightly more expensive, not cheaper.** The 32% figure at n=1 is a
fixed-overhead artifact that disappears once `discoverFor`'s base cost amortises. Mechanism
(reasoned, not separately measured): CREATE2 avoids a cold account access for the CALL (~2,600)
but pays a cold SLOAD for `initHash` (~2,100) plus the keccak, so the two roughly cancel; what
actually dominates is the per-factory `Factory` struct reads (address, kind, mode, initHash,
plus the `fees`/`spacings` arrays), which both modes pay identically.

**Consequence for optimisation work:** discovery costs ~7,000 gas per registered factory
*regardless of derivation mode*, so the lever is not a cheaper derivation — it is scanning
**fewer factories per call**. That is exactly the amortised rotating-cursor discovery in the
research series (note 049), which remains unimplemented. Switching venue registrations to
CREATE2 modes for gas reasons would be effort spent for ~3%.

CREATE3 does not apply to this path at all: it addresses deploying *our own* contracts
deterministically across chains, whereas `deriveAddress` derives *third-party* pool addresses
(Uniswap/Curve/Solidly), none of which deploy via CREATE3. It cannot affect per-swap gas.

## SSTORE2 for the factory registry — theory from note 056 §5, measured

`forge test --match-contract Sstore2RegistryGas -vv` (added 2026-08-04). Read path only (the
path every `discoverFor` pays); the write happens once in `addFactory` and is out of scope.
Data shape mirrors `Hub.Factory` as wired on Base (address + kind + mode + initHash +
uint24[4] fees + int24[4] spacings).

| | Storage (SLOADs) | SSTORE2 (EXTCODECOPY) | Saved |
|---|---|---|---|
| One factory record | 24,045 | 16,836 | 7,209 (29%) |
| Full sweep, 9 factories | 164,076 | 115,304 | 48,772 (29%) — **5,419/factory** |

Both arms pay an identical external CALL in the harness, so that overhead is common-mode and
the delta is the real read-path difference. Note 056 §5 predicted "~2606 via bytecode vs ~4200
in storage" (38%); the measured percentage is lower (29%) but the **absolute** saving is far
larger than the note's 64-byte example, because the real `Factory` record carries the
fees/spacings arrays.

### Ranked gas levers, by measurement rather than intuition

| Lever | Measured effect | Verdict |
|---|---|---|
| SSTORE2 registry (note 056 §5) | −5,419 gas per factory scanned | **Real.** Biggest single lever found |
| Scan fewer factories (note 049 rotating cursor) | discovery is ~7,062 gas/factory, linear | **Real**, unimplemented |
| CREATE2 modes instead of factory-call | ~3% at realistic counts; *more* expensive at the margin | **Refuted** — see previous section |
| CREATE3 | n/a to this path | **Not applicable** — third-party pools don't use it |
| Arbitrum Stylus (note 058) | 49-86% published, chain-conditional | Real but Arbitrum-only, not portable |

## Which gas actually reaches the user — and why SSTORE2 does NOT

Before implementing the SSTORE2 registry the measurement above argued for, one structural fact
was verified rather than assumed:

- `Solver.findBestRoutePlan` and `Hub.discoverFor` are both `view`.
- The Router **never calls the Solver**. `solver` appears in `BlazePhoenixRouter.sol` only as an
  immutable and its constructor check — there is no call site in the swap path.

**Therefore discovery gas is never paid by a swap.** Solving happens off-chain through a free
`eth_call`. The SSTORE2 registry saving (−5,419/factory) applies only to view calls and to any
on-chain integrator that solves inside its own transaction. It would **not** make a single user
swap cheaper. Implementing it for swap-gas reasons would be effort against the wrong path.

That saving is still not worthless — `eth_call` is free but gas-*bounded*, and the top-100 sweep
measured ~1.5M gas per cold quote, which is within an order of magnitude of typical node
`eth_call` caps. SSTORE2 buys headroom there, not user savings.

### What a user's swap actually pays for the registry

`forge test --match-test test_Metrics_RegistryFeedbackCostPerSwap -vv`. The Router calls
`hub.recordSwap` once per leg (inside the tx, wrapped in try/catch). Pausing the Hub makes that
call revert on `whenLive` and be swallowed, isolating the write-side work:

| | Gas |
|---|---|
| Swap, Hub live (registry writes) | 185,876 |
| Swap, Hub paused (registry feedback swallowed) | 170,322 |
| **Registry feedback cost** | **15,554 (8% of the swap), ~3,889 per leg** |

This — not the factory registry — is the only registry machinery a user pays for, and it is
fully EVM-agnostic. It is also **not free to remove**: `recordSwap` is what makes the registry
self-improving (vitality, depth buckets, eviction). Cutting it trades routing quality for gas,
so it is a product decision rather than a pure optimisation, and is left unimplemented pending
that decision. The non-destructive variants worth evaluating are batching the per-leg calls into
one, and skipping the write when the slot would be unchanged in the same block.

## The meta-pattern: the protocol computes the number it needs, then discards it

External research (Aug 2026) into who actually achieves the lowest swap gas, cross-checked
against this repo's own measurements. The conclusion is structural, not a micro-optimisation.

### Why the industry's biggest win is unavailable to us

Ambient/CrocSwap runs the entire DEX in a single contract with pools as lightweight data
structures; Ekubo reports 20-30% cheaper than leading AMMs by the same route; Uniswap V4 nets
transient debits/credits and settles only the balance. All three win the same way: **singleton
architecture that avoids token transfers**. An aggregator routing through *third-party* pools
cannot adopt it — we do not own the pools. This is a structural ceiling on how cheap a
BlazePhoenix swap can get, and it should be stated plainly rather than chased.

### Why deferred writes don't rescue the hot path either

Flash accounting works for V4 because it nets *transfers to the same counterparty*. Our
per-leg `recordSwap` writes touch **distinct storage slots** (one per pool), and netting cannot
merge distinct slots. Accumulating them in transient storage (TSTORE at 100 gas vs SSTORE at
5,000-22,100) would still owe the same N cold SSTOREs at settlement. Dead end, for a real
reason worth recording.

EIP-2930 access lists are likewise ~break-even by construction: listing a storage key costs
1,900 upfront to make the access cost 100 instead of 2,100. Net ~100 gas. Not a lever.

### What IS available, and is already half-built

Measured marginal cost of one extra leg: **≈28,700 gas** (`GasReport`) **+ ~3,889** registry
feedback = **≈32,600 gas per additional leg**. Against that, the Solver picks legs purely by
`psi` weight: `_cutByWeight` and the allocation loop contain no gas term.

And yet `BlazePhoenixSolver._estGas` already exists — it prices each leg by venue kind (90k V2,
110k V3/Algebra, 140k Curve, 180k V4) and the Quoter publishes it as `Preview.estGas`. **It is
computed, reported, and never used as a decision input.** The protocol already knows what an
extra leg costs and does not consult that number when deciding whether to add one.

This is what 1inch ships as "Lowest Gas mode" (favouring simpler routes) and what Uniswap's Auto
Router documents as splitting "only when it results in a better net rate". It is fully
EVM-agnostic, needs no new opcode, and strictly improves the user's NET output.

### The catch that makes it a design decision, not a patch

Comparing a leg's gas (denominated in the chain's native token) against its marginal output
(denominated in `tokenOut`) requires a price between them — and this protocol is deliberately
oracle-free ("no oracle, no off-chain solver"). Two oracle-free resolutions exist:

1. **Caller-supplied budget** — the caller passes gas price already expressed in `tokenOut`
   terms, keeping the contract oracle-free and the decision verifiable.
2. **Self-quoting** — the Solver prices gas through its own WETH pools. Elegant and internally
   consistent, but self-referential, and inherits whatever manipulation resistance those pools
   have.

Until one is chosen, `_estGas` remains reporting-only. That choice is the open item; the
measurement supporting it is done.
