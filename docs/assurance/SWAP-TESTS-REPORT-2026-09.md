# BlazePhoenix-Dex — Swap Tests: Results, September 2026

*What the swap tests measured, in the numbers they produced. Companion to
`VERIFICATION-REPORT-2026-09.md` (which covers every instrument) — this document is the swap
side only: quotes, fees, floors, settlements and refusals, on mocks and on live Base. Every
figure is recomputable with the command beside it. Tree: branch
`vectors/invariant-mutants-metamorphic-t3-nversion`, release settings, 2026-09-05.*

## 1. A quote executed later — mocks

`forge test --match-path test/QuoteDelayStatistics.t.sol -vv`

The quote is taken through `previewAndEncode` (preview + calldata); zero to three trades by
someone else go through the same pools, each up to 3 % of the shallow reserve, in the user's
direction; zero to ten seconds pass; the calldata runs unchanged. 240 samples on a three-token
universe (A, B = bridge coin, C; direct into the bridge, two hops through it, two hops the other
way). No sample failed to quote.

| drift between quote and execution | samples | settled | refused by the floor `RouterE(5)` | delivered / predicted — mean | min | max |
|---|---|---|---|---|---|---|
| none | 64 | 64 | 0 | 10,000 bps | 10,000 | 10,000 |
| 1 – 100 bps | 43 | 43 | 0 | 9,952 bps | 9,803 | 10,000 |
| 100 – 300 bps | 133 | 102 | 31 | 9,966 bps | 9,653 | 10,000 |

| delay between quote and execution | samples | settled | refused `RouterE(5)` | delivered / predicted — mean | min |
|---|---|---|---|---|---|
| 0 s | 17 | 15 | 2 | 9,989 bps | 9,857 |
| 1 – 5 s | 99 | 89 | 10 | 9,959 bps | 9,653 |
| 6 – 10 s | 124 | 105 | 19 | 9,983 bps | 9,659 |

Asserted on every sample: a settlement never delivers below the floor the preview attested;
a drift-free quote settles at every delay and delivers exactly its prediction; there is no third
outcome. After the deadline (`deadline = now + 5`, executed at `+10`): 20 of 20 refused with
`RouterE(4)`, the deadline's own code, none settled.

Reading: time does not move a quote; drift does. Under up to 1 % of adverse drift every quote
still fills, within 2 % of its prediction. Under 1–3 % the floor refuses one in four rather than
fill it below the attested output, and the fills land within 3.5 % of the prediction.

## 2. A quote executed later — live Base

`DRPC_KEY=… forge test --match-path test/fork/QuoteDelayFork.t.sol -vv` (USDC → WETH, 1,000 USDC,
real pools, the protocol deployed on a fork of Base at the current block)

| delay, nothing else moving | delivered / predicted |
|---|---|
| 0 s | 10,000 bps |
| 3 s | 10,000 bps |
| 6 s | 10,000 bps |
| 10 s | 10,000 bps |

| USDC traded ahead of the user through the same route, then the stale calldata at +10 s | outcome | delivered / predicted |
|---|---|---|
| 10,000 | settled | 9,999 bps |
| 50,000 | settled | 9,998 bps |
| 200,000 | settled | 9,994 bps |
| 1,000,000 | settled | 9,974 bps |
| 5,000,000 | settled | 10,000 bps |

Five settled, none refused, no third outcome. A million dollars ahead of a thousand costs the
thousand a quarter of a percent; the five-million trade routed through pools the thousand-dollar
route does not touch.

## 3. The protocol fee, measured from outside the Router

`forge test --match-path test/FeeSeals.t.sol` (2,000 fuzz runs) and the Router invariant
campaign (`test/BlazePhoenixRouter.invariant.t.sol`)

The fee token is derived from the rule and the bridge list; the base from the pools' balance
deltas (what left the Router into the fee hop, or what the previous hop's pools paid out) or the
recipient's; the fee from the treasuries' deltas; the count from the `Fee` events.

| route shape | regime | where the fee lands | measured |
|---|---|---|---|
| A → B (neither a bridge) | exhaustion, one hop | hop 0's input, once | fee = ⌈28 bps × input⌉, one event |
| W → A (bridge in) | anchored | hop 0's input | same |
| A → W (bridge out, direct) | anchored, output side | the output | fee = ⌈28 bps × gross output⌉, delivered = gross − fee |
| A → C → B (no bridge) | exhaustion, two hops | each hop's measured input | two events, each ⌈28 bps × that hop's input⌉ |
| W → A → B | anchored at hop 0 | hop 0's input | one event |
| A → W → B | anchored at hop 1 | the bridge coin hop 0 produced | one event, ⌈28 bps × what hop 0's pools paid out⌉ |
| A → C → W (bridge only as output of two hops) | exhaustion | each hop's input | two events |
| A → C → D → B, A → W → C → B, A → C → W → B | as above | as above | 3 / 1 / 1 events |

Each shape with one and with two legs per hop, fuzzed amounts from 10¹² to 10²¹ wei: 2,000 runs,
no failure, the Router holding nothing after every settlement. The exhaustion regime's per-hop
charge is a deliberate rule: charging such a route once, on hop 0, was tried and reopened a prefix
escape inside the suite (a value-less first hop carrying the fee spot onto dust).

The Router asserts the count itself: a transient ledger refuses a settlement that paid nothing
(`RouterE(15)`) and, on an anchored route, a second payment (`RouterE(16)`). Router runtime size
after the ledger: 23,781 bytes.

## 4. How often the fee tests notice a defect

`docs/assurance/fee-seal-detection.json` — twenty fuzz seeds per fuzzed test, one run per
deterministic test, Wilson 95 % interval on the detection probability.

| mutant | FeeSeals fuzz | Router campaign (2 hops, 2 legs) | covering array t=2 | junk-prefix escape | exhaustion preview parity |
|---|---|---|---|---|---|
| exhaustion charges hop 0 only (junk-prefix escape) | 20/20 [0.84, 1.00] | 20/20 [0.84, 1.00] | no | yes | yes |
| exhaustion skips hop 0 | 20/20 [0.84, 1.00] | 20/20 [0.84, 1.00] | no | yes | yes |
| commitment counts the first leg only | 20/20 [0.84, 1.00] | 20/20 [0.84, 1.00] | no | no | no |
| fee doubled | 20/20 [0.84, 1.00] | 20/20 [0.84, 1.00] | yes | yes | yes |
| input-side fee never charged | 20/20 [0.84, 1.00] | 20/20 [0.84, 1.00] | no | yes | yes |
| fee charged on both sides | 20/20 [0.84, 1.00] | 20/20 [0.84, 1.00] | no | yes | yes |
| BELT ledger: settlement without a fee no longer refused | 0/20 [-0.00, 0.16] | 0/20 [-0.00, 0.16] | no | no | no |
| BELT ledger: anchored double payment no longer refused | 0/20 [-0.00, 0.16] | 0/20 [-0.00, 0.16] | no | no | no |

At 20 of 20 the rule of three bounds a single campaign's miss probability at 15 %; the guard
runs the named test and the campaign both. The two ledger rows are belts — nothing in front of
them leaves a path they could catch — and are published as such. The Router campaign column is
the campaign after it was widened to two hops and two legs: its first measurement, with direct
one-leg routes only, was blind to the exhaustion-regime mutant that spares hop 0 and to the
commitment producer (0 of 20 each); the widened campaign sees both 20 of 20.

## 5. What a quote costs through the ABI

`forge test --match-path test/QuoterGasStatistics.t.sol -vv` · `test/fork/QuoterGasFork.t.sol`

| world | `previewPlan` mean gas | min | max | σ | `previewAndEncode` mean | σ |
|---|---|---|---|---|---|---|
| mocks, discovery (pair known to the factory only; one pool found) | 121,313 | 116,468 | 123,491 | 1,433 | 123,317 | 1,851 |
| mocks, fresh registry (three seeded pools priced) | 235,574 | 227,205 | 237,843 | 1,815 | 239,647 | 1,937 |
| live Base, cold (registry empty; admitted factories swept) | 1,524,221 | | | | 1,525,341 | |
| live Base, warm (fresh after one execution; two pools registered) | 1,414,633 | | | | 1,416,037 | |
| live Base, cold again (discovery TTL expired) | 1,359,925 | | | | 1,361,582 | |

`batchQuote` of ten entries on mocks: 2,055,390 gas, 205,539 per entry. The mock worlds are not
one pool against the same pool — the fresh registry prices three pools where discovery found one —
so the honest comparison is the live one: the discovery sweep is about 7 % of a live quote, and a
quote is a view call.

## 6. Settlement under hostile venues and across regimes

| instrument | rows | settle | refuse with a selector of ours | not constructible | third outcome | command |
|---|---|---|---|---|---|---|
| hostile-venue matrix (ten pathologies × two doors) | 20 | — | — | — | 0 | `forge test --match-path test/regime/HostileVenueMatrix.t.sol` |
| regime covering array, strength 2 (all 258 value pairs) | 63 | 53 | 4 | 6 | 0 | `--match-contract RegimeCoverageTest -vv` |
| regime covering array, strength 3 (all 1,636 value triples) | 168 | 158 | 10 (`SolverE(5)` ×7, `RouterE(13)` ×3) | 0 | 0 | `--match-contract RegimeCoverageT3Test -vv` |

Every row either settles inside the floors with nothing left on the Router, or refuses with a
selector of ours. The ten pathologies: a pool that pays nothing, pays half, returns a data bomb,
burns all gas on read and on swap, a token whose `decimals()` never returns, a double payment
callback, a re-entering pool, a reverting `slot0()`, a factory answering with a pool on other
tokens.

## 7. The sandwich, from the attacker's side

`forge test --match-path test/regime/SandwichCurve.t.sol -vv`

On a 1 %-of-depth trade against a constant-product pool, the floor caps a sandwich at about
2.7 % of the trade and refuses beyond it; the refusal region is closed upward; at every point
the victim receives at least the floor attested at quote time, and past ~3 % of manipulation
the attacker's round trip is negative.

## 8. The stateful campaigns

40 `invariant_*` functions in 14 campaigns (Router fee and holds-nothing, full-stack loop through
Hub → Solver → Router with the registry moving, stranded-money regime with a paused Router, the
V4 adversarial manager with a re-entering hook, conservation across split and multi-hop routes,
registry bounds), all green on the release settings. Fifteen source mutations were run against
all of them on one seed to ask whether any campaign can go red at all: eleven were noticed and
are now paired guard entries; the four that were not are published with their reading
(`docs/assurance/invariant-mutants.json`).

## 9. What these results do not say

The distributions of §1 are over mocks with constant-product pools; live Base (§2) gives reach on
one pair at one block, not a distribution. Detection rates (§4) are per test at 256 fuzz runs per
seed; a test that misses at that budget may catch at a larger one. No probability of correctness
follows from any table here.
