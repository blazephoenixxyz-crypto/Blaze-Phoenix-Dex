# BlazePhoenix-Dex — Verification Report, September 2026

*Metrological Design, measured. Every number below is printed beside the denominator it was
measured against, and every one of them is recomputed from a clean checkout by the scripts in
`.github/scripts/assurance/` or by a named `forge` command. Where a number is a floor it is
called a floor; where an instrument cannot see something, that is stated in §7.*

**Tree measured:** branch `vectors/invariant-mutants-metamorphic-t3-nversion` on top of `main`
`df46649`, executed on the project's CI hardware (release settings, `optimizer_runs = 300`, `via_ir`),
2026-09-05. Numbers marked *pending* are being measured as this document is written and are
filled in the commit that lands it.

---

## 1. The suite in numbers

| what | count | how it is counted |
|---|---|---|
| declared tests | 1,478 `test*` / `invariant*` / `check*` functions across 218 `.t.sol` files | `grep -rhoE 'function (test\|invariant\|check)[A-Za-z0-9_]*' test --include='*.t.sol'` |
| green on the release profile, fork suites excluded | 1,319 passed · 0 failed · 1 skipped (1,320) | `forge test --no-match-path 'test/fork/**'` |
| green on live liquidity | 119 of 119 on the 39 suites of the fork lane, five chains; plus the 3 tests of §5 on Base | `forge test --match-path 'test/fork/**'` with an archive RPC |
| stateful invariants | 40 `invariant_*` functions in 14 campaigns | `grep -rc 'function invariant_' test` |
| curated mutants, all killed | 200 of 200 | `.github/scripts/mutants.py`; `check_targets.py` 200/200 |
| regime covering arrays | strength 2: 63 rows, all 258 pairs · strength 3: 168 rows, all 1,636 triples · of 5,184 combinations | `covering_array.py --check` |
| shipped sizes (runtime bytes, EIP-170 limit 24,576, project gate 24,000) | Hub 23,648 · Router 23,781 · Solver 19,686 · Quoter 11,429 · Core 6,442 | `FOUNDRY_PROFILE=release forge build --sizes` |

## 2. What each instrument guarantees, and its limit

| instrument | the question it answers | result on this tree | the limit, stated |
|---|---|---|---|
| **Curated mutation guard** | do the tests notice when a guard disappears? | 200 hand-written mutants, each paired with the one named test that must die; baseline-checked, fingerprinted so an optimiser-removed mutation is reported as inert; 200/200 killed | adequacy against *this* register — a saturated score is a floor, not a ceiling |
| **Mutants aimed at the invariants** (new) | can the stateful campaigns go red at all? | 15 source mutations × 39 invariants on one seed: 11 noticed, 18 distinct invariant names went red; the 11 are now guard entries paired with their invariant | four survivors, each published with its reading in `invariant-mutants.json`; two guards had no watcher of any kind and are queued |
| **Shared-quantity register** | is every quantity with two producers or two consumers tied? | every such quantity, the question it answers, the mechanism binding the copies, graded `SINGLE / PINNED / WEAK / OPEN / UNVERIFIED`; a CI rule demotes a row whose test does not reach what it claims to pin | a grade is a reading of the tree, not a proof of equivalence |
| **Regime covering arrays** (t = 3 new) | which combinations of regime factors has a fixture actually run? | strength 2: 53 settle, 4 refuse with a selector of ours, 6 not constructible, 0 third way · strength 3: 158 settle, 10 refuse (`SolverE(5)` ×7, `RouterE(13)` ×3), 0 not constructible, 0 third way | ten factors; V4, Algebra and the native door are stated as outside the array |
| **Hostile-venue matrix** | does a pathological pool ever produce a third outcome? | ten pathologies × two doors: settle with the balance delta and nothing left on the Router, or refuse with a selector of ours — 20/20 | the ten pathologies are the ones named; classes nobody has named are outside the denominator |
| **Sandwich curve** | what can an attacker extract against the floor? | on a 1 %-of-depth trade the floor caps a sandwich at about 2.7 % of the trade and refuses beyond it, leaving the attacker's round trip negative | constant-product mocks; the fork version needs an archive key |
| **Canonical oracles** | is the quote maths right against the venues' own specifications? | V2 exact to the wei; stable curve within 4 wei; V3 within one ulp of the square-root price (`L / 2⁹⁶` wei) | implementations written from the specifications, not from the venues' bytecode |
| **Metamorphic relations** (extended) | how must the output move when the input moves? | 14 relations over the quote maths (monotone, sub-additive, no round trip, scale equivariance, fee monotone, direction symmetry, identity of the volatile arm) and 5 over the Solver's plan (never below the best single pool, monotone, liquidity monotone, order independence to one weight unit, floor below expectation) — all green, three bounds measured before written | bounds are the mechanism (one ulp per arm; the ±5 % median filter; one weight unit of the split), stated in the assertion |
| **N-version of the quote maths** (new) | does the source mean the same thing under other code generation? | the same quote maths compiled at `optimizer_runs` 1 / 300 / 20000, three binaries compared on 3,000 fuzzed inputs per function: they agree | the compiler was not the finding — see §3 |
| **Executed-bytecode lower bound + opcode trace** | which instructions of the shipped binary does a scenario run? | a sound lower bound on the shipped-shape artefact with a ground-truth contract in the suite; an opcode-level trace of real swaps replayed on the release Router with the opcode checked at every step (0 mismatches) | a lower bound; declarations the compiler removed are outside it |
| **Projection distance** | how far does each refusal observe from what decides? | 86 of 99 refusal sites at distance zero | the 13 at distance > 0 are listed with their reading |
| **Evidence independence** | how many independent confirmations stand behind each load-bearing guard? | reported as the minimum across source, oracle, tool, environment and methodology | independence is the minimum, never the mean |
| **Calldata-field matrix** | which caller-writable fields steer, which are confirmed, which are only declared? | 23 fields: 5 steer, 13 confirmed, 5 declared | the 5 declared are weighed in the register |
| **Size gate inside the suite** | does every contract ship under the project's own margin? | asserted on the suite's own profile, which `profile_parity.py` keeps identical to the release profile | the gate is 24,000 bytes, 576 under EIP-170 |
| **The fee rule, both regimes, asserted at run time** (new) | is the protocol fee charged where the rule says, and counted? | anchored routes pay once at the first bridge input (or on the output of a direct route into a bridge coin); exhausted routes pay once per hop on each measured input — pinned by an oracle-independent fuzz over ten route shapes, one and two legs, both regimes; the Router keeps a transient ledger and refuses a settlement that paid nothing (`RouterE 15`) or twice on an anchored route (`RouterE 16`) | the ledger's own two checks are belts, measured as unobservable in isolation (§6) |
| **How a quote ages** (new) | what does a quote promise 0–10 s later, with the world moving? | §5 | mocks for the distribution; live Base for the reach |

## 3. What the instruments produced this round

**The N-version lane found a fail-open and closed it.** Fuzzing the three binaries of the stable
curve over its whole input domain made the *reference* revert: on a pool holding under one unit of
each token, the curve's own fit check divided `max · WAD / b` and overflowed; a whale input reserve
against a dust output reserve passed that check and overflowed the derivative. Both were reverts
inside a quote, and `universalQuote` is a library `DELEGATECALL`, so a registered dust pool unwound
the Solver's plan for its pair. The repair asks the question the division stood in for — the high
word of the 512-bit product against one WAD, two multiplications and no division — and went in
red-first: three named tests including the plan-level reach through a real Solver, a 5,000-run fuzz
over the full domain, a 60,000-sample sweep of the same arithmetic in Python, three mutants in the
guard. The repair is 35 bytes smaller than the code it replaced; the Hub is byte-for-byte the same
size as before. Its class is the one this repository names first — fail-open — found by an
instrument that was not looking for it.

**The fee rule gained its second name.** The rule since 2026-08-22 charges once, on the first
bridge input. A hand-built route through pools the registry would not hold, with no bridge coin as
any input, falls into a second regime the rule had not named, where every hop pays on its own
measured input. The obvious simplification — charge such a route once, on hop 0 — was tried inside
the suite and reopened a prefix escape (a value-less first hop carries the fee spot onto dust);
five pinned tests refused it within the run. The regime is now named in the code with that reason,
the commitment of a hop has one producer, and the Router asserts the count at run time.

**Three metamorphic bounds were measured before they were written.** At `L = 8.5 × 10³⁷` and 1,374
wei in, the two arms of `outV3` disagree by exactly one ulp of the square-root price — the bound
of the canonical-oracle section, seen between the arms. A pool priced 10¹⁰ away from its sibling
makes the plan pay 35 % less than the outlier alone: the median filter refusing to believe it. A
pool whose depth weight floors to the minimum is kept as a dust leg when registered first and cut
when registered second, moving the plan by 3 × 10⁻⁷ of the output: the split's keep-or-cut of a
minimum-weight pool depends on its position, and is now written where it was found.

**The measurement of the campaigns found what they cannot see.** Two guards — the registry's
pair-proof and the bridge-residual sweep's baseline — had no watcher of any kind, and no campaign
asserts the protocol floor. They are recorded with their reading and are the next work.

## 4. Detection rates — how often a test notices a defect

Every fee mutant (the regime predicate moved either way, the commitment producer, the ledger's
two checks, and the three fee mutants of the invariant study) was run under twenty fuzz seeds per
fuzzed test and once per deterministic test; the detection rate is reported with a Wilson 95 %
interval, and — where nothing was missed — the rule-of-three bound on the miss probability.

| mutant | FeeSeals fuzz | Router fee campaign | covering array t=2 | junk-prefix escape | exhaustion preview parity |
|---|---|---|---|---|---|
| exhaustion charges hop 0 only (junk-prefix escape) | 20/20 [0.84, 1.00] | 0/20 [-0.00, 0.16] | no | yes | yes |
| exhaustion skips hop 0 | 20/20 [0.84, 1.00] | 20/20 [0.84, 1.00] | no | yes | yes |
| commitment counts the first leg only | 20/20 [0.84, 1.00] | 0/20 [-0.00, 0.16] | no | no | no |
| BELT ledger: settlement without a fee no longer refused | 0/20 [-0.00, 0.16] | 0/20 [-0.00, 0.16] | no | no | no |
| BELT ledger: anchored double payment no longer refused | 0/20 [-0.00, 0.16] | 0/20 [-0.00, 0.16] | no | no | no |
| fee doubled | 20/20 [0.84, 1.00] | 20/20 [0.84, 1.00] | yes | yes | yes |
| input-side fee never charged | 20/20 [0.84, 1.00] | 20/20 [0.84, 1.00] | no | yes | yes |
| fee charged on both sides | 20/20 [0.84, 1.00] | 20/20 [0.84, 1.00] | no | yes | yes |

Read across a row: which tests see this defect. Read down a column: what a test can and cannot
see. The Router campaign builds direct routes only, so the exhaustion-regime mutants that spare
hop 0 are invisible to it and visible to the every-shape fuzz and the two pinned tests; the
commitment producer only matters on a two-leg hop, which only the every-shape fuzz builds; the
two ledger belts are seen by nothing, as their name says. Twenty seeds at 20/20 bound the miss
probability of one campaign at 15 % (rule of three), which is why the guard runs the named test
and the campaign both.


## 5. How a quote ages

A quote is taken the way an integrator takes it — `previewAndEncode` returns the preview and the
calldata — the world moves (zero to three trades by someone else through the same pools, each up
to 3 % of the shallow reserve, all in the user's direction), zero to ten seconds pass, and the
calldata is executed unchanged. 240 samples, three-token universe, every outcome classified.

| drift between quote and execution | samples | settled | refused by the floor (`RouterE 5`) | delivered / predicted, mean · min |
|---|---|---|---|---|
| none | 64 | 64 | 0 | 100.00 % · 100.00 % |
| up to 100 bps | 43 | 43 | 0 | 99.52 % · 98.03 % |
| 100 – 300 bps | 133 | 102 | 31 | 99.66 % · 96.53 % |

By delay (0 s / 1–5 s / 6–10 s) the settle rates are 15/17, 89/99, 105/124: time is not what
moves a quote, drift is. Asserted, not printed: drift-free quotes settle 100 % at every delay and
deliver exactly the prediction; a settlement never delivers below the floor the preview attested;
after the deadline the refusal is the deadline's own code (`RouterE 4`, 20 of 20); there is no third
way. Under 3 % of adverse drift, one settlement in four is refused by the floor rather than filled
below it, and the ones that fill land within 3.5 % of the prediction.

**Live Base** (`test/fork/QuoteDelayFork.t.sol`, 1,000 USDC → WETH): executed 0, 3, 6 and 10 s
later with nothing else moving, the quote delivered exactly its prediction all four times
(10,000 of 10,000 bps). With 10,000 · 50,000 · 200,000 · 1,000,000 · 5,000,000 USDC traded
ahead of it through the same route and the calldata executed 10 s later, all five settled inside
the floor at 9,999 · 9,998 · 9,994 · 9,974 · 10,000 bps of the prediction — the live pools are deep
enough that a million dollars ahead of a thousand costs the thousand a quarter of a percent.

**What a quote costs through the ABI.** On the three-token universe, forty sizes each, gas measured
around the external call:

| world | `previewPlan` mean (min – max, σ) | `previewAndEncode` mean (σ) |
|---|---|---|
| discovery — the pair known only to the factory, one pool found | 121,313 (116,468 – 123,491, σ 1,433) | 123,317 (σ 1,851) |
| fresh registry — three seeded pools, no sweep | 235,574 (227,205 – 237,843, σ 1,815) | 239,647 (σ 1,937) |

The fresh registry costs more here because it prices three pools where discovery found one; the
sweep itself is the cheaper half of the discovery quote. `batchQuote` of ten entries: 2,055,390
gas, 205,539 per entry. On live Base (USDC → WETH, five sizes each) `previewPlan` costs 1,524,221
cold (registry empty, the admitted factories swept), 1,414,633 warm (registry fresh after one real
execution, two pools registered) and 1,359,925 cold again after the discovery TTL — the sweep is
worth about 7 % of a live quote, and the whole quote is a view call an integrator never pays for
on chain.

## 6. Belts

Two checks in the fee ledger cannot be made to fire by any test in isolation, because the predicate
in front of them leaves no path that settles without paying, or pays twice on an anchored route.
They are the contract refusing at run time what the tests refuse at review time, on paths that do
not exist yet. They are listed as belts, counted as covered nowhere, and absent from the mutation
guard, which admits only mutants a named test kills. A fourth guard on the stable curve — a cap on
Newton's iterate — was written, found unobservable once the two fit checks hold, and removed.

## 7. What none of this establishes

- **No probability of correctness.** Testing cannot produce one, and none is stated here.
- **Mutation adequacy is adequacy against this register.** It is hand-curated; a saturated score
  is a floor.
- **Threat and regime coverage are floors on what has been considered.** Classes and factors
  nobody has named are outside the denominator by construction.
- **The distributions of §5 are over mocks.** Live Base gives reach, not a distribution.
- **This repository is V2, and V2 is not deployed.** The deployed generation is V1, pinned by
  codehash on every network so the two are never conflated.

## 8. Reproduce

```
forge test --no-match-path 'test/fork/**'                       # the suite, release settings
python3 .github/scripts/mutants.py                               # the mutation guard
python3 .github/scripts/check_targets.py                         # every mutant still points at one line
python3 .github/scripts/assurance/covering_array.py --check      # both covering arrays current
FOUNDRY_PROFILE=nver1 forge build --skip '*.t.sol' && FOUNDRY_PROFILE=nver2 forge build --skip '*.t.sol'
NVERSION_LANE=1 forge test --match-path 'test/nversion/*'        # the three binaries agree
forge test --match-path test/FeeSeals.t.sol                      # the fee rule, both regimes
forge test --match-path test/QuoteDelayStatistics.t.sol -vv      # how a quote ages
forge test --match-path test/QuoterGasStatistics.t.sol -vv       # what a quote costs
python3 .github/scripts/assurance/metrics.py                     # every assurance number, with its denominator
```

## 9. The claims, falsifiable

We know of no other public DeFi codebase that publishes a curated, named mutation guard with
per-mutant killing tests and inert-mutation reporting; a shared-quantity register with a CI rule
that demotes it; mutants aimed at its stateful invariants with the survivors published; a
strength-3 covering array over its regime factors under one assertion; N-version testing of its
quote maths; a measured curve of how its quotes age; or the detection rate of its own fee mutants
with a confidence interval. The artefacts are in the repository; if you find a prior instance, the
claim is wrong and we would like to know: contact@blazephoenix.xyz.
