# Hub bridges: three vs two, paired re-run of G7 and G8

The G7 gas campaign and the G8 pool tests were re-run twice on the same draws, changing only the
Hub's bridge list: run **A** has three bridges, run **B** has two. Every number below is a pair
(same chain, stratum, kind, idx, block, mode, tokens and amount in both runs) and every delta is
**B - A**, so a negative gas delta means two bridges cost less. All values come from
`docs/case-studies/data/gas-bridges-1126/` (`compare.tsv` per campaign), produced by
`tools/g7-gas-campaign/compare_bridges.py` from the two `results.tsv` of each campaign.

## Setup

| item | A (three bridges) | B (two bridges) |
|---|---|---|
| base | WETH, USDC, wstETH | WETH, USDC |
| optimism | WETH, USDC, wstETH | WETH, USDC |
| arbitrum | WETH, USDC, wstETH | WETH, USDC |
| robinhood | WETH, USDG, VIRTUAL | WETH, USDG |
| G7 run | 45720744246 | 45720753978 |
| G8 run | 45720037905 | 45720046359 |

- Base, optimism and arbitrum: A is the committed campaign state; B removes the third bridge with
  the Hub's own `removeBridge(2)`, executed as the admin on a local anvil loaded with the state
  (no fork, no RPC). `tools/g7-gas-campaign/patch_bridge.py` writes back every slot the call
  wrote (prestateTracer diff) and checks the bridge list before and after.
- Robinhood: the committed state already has two bridges, so B is the committed state and A adds a
  third bridge (VIRTUAL) with `addBridge`, through the same tool.
- The slot changes are in `state-A.diff` and `state-B.diff`: three Hub slots per chain (the
  `isBridge` entry, the array slot and the count).
- Spec, seed and universe are the pre-registered ones of the campaign; both runs of a campaign
  share them, so the draws pair one to one. The other chains of the campaign have no bridge change
  and are not part of this comparison.
- Absolute values are from this pair of runs and can differ from the published G7/G8 report,
  which was measured on an earlier state; only the paired deltas are compared here.

`g_quote` is the gas of the Quoter's preview call (an `eth_call`, traced); `g_discovery_bridge`
is the part of it spent searching routes through bridges. `g_exec` is the traced execution of the
calldata the quote returned: the gas a swap pays on chain. `delivered` is the amount that
execution delivered. Percentiles are nearest-rank.

## Coverage

| campaign | pairs | ok in A | ok in B | lost (ok A, not ok B) | won (not ok A, ok B) |
|---|---|---|---|---|---|
| G7 | 3200 | 2247 | 2247 | 0 | 0 |
| G8 | 2496 | 1746 | 1746 | 0 | 0 |

No draw that quoted and executed with three bridges failed with two, and none the other way.

## Quote gas (pairs ok in both, all modes)

| campaign | chain | n | g_quote p50 A | g_quote p50 B | delta p50 | delta p5 | delta p95 | lower / same / higher |
|---|---|---|---|---|---|---|---|---|
| G7 | base | 562 | 9227958 | 8097547 | -911728 | -2932771 | 4285 | 530 / 0 / 32 |
| G7 | optimism | 636 | 3695575 | 2912873 | -711533 | -1207953 | 60546 | 580 / 0 / 56 |
| G7 | arbitrum | 602 | 4413790 | 3632150 | -837904 | -1232012 | 391 | 562 / 0 / 40 |
| G7 | robinhood | 447 | 1966544 | 1491879 | -515484 | -829784 | -66454 | 447 / 0 / 0 |
| G7 | all | 2247 | 4121259 | 3334689 | -705305 | -2346111 | 700 | 2119 / 0 / 128 |
| G8 | base | 678 | 9914089 | 7861948 | -1805384 | -2583091 | 8537 | 642 / 0 / 36 |
| G8 | optimism | 480 | 3766154 | 2926368 | -848447 | -1290276 | -1222 | 462 / 0 / 18 |
| G8 | arbitrum | 384 | 4133568 | 3568871 | -851516 | -1395102 | 699 | 354 / 0 / 30 |
| G8 | robinhood | 204 | 1724088 | 900840 | -793085 | -824932 | -66257 | 204 / 0 / 0 |
| G8 | all | 1746 | 4577965 | 4015905 | -911595 | -2428195 | -1222 | 1662 / 0 / 84 |

Bridge discovery alone (`g_discovery_bridge`, delta p50): G7 all -238071, G8 all -244427; the rest
of the quote delta is outside bridge discovery.

## Execution gas (pairs ok in both, all modes)

| campaign | chain | g_exec p50 A | g_exec p50 B | delta p50 | delta p5 | delta p95 |
|---|---|---|---|---|---|---|
| G7 | base | 1083376 | 1003313 | 0 | 0 | 12 |
| G7 | optimism | 612823 | 593044 | 0 | -8681 | 0 |
| G7 | arbitrum | 690178 | 690178 | 0 | 0 | 12 |
| G7 | robinhood | 769720 | 769720 | 0 | 0 | 0 |
| G7 | all | 716638 | 703595 | 0 | 0 | 12 |
| G8 | base | 1060443 | 1043394 | 0 | 0 | 296 |
| G8 | optimism | 635945 | 635945 | 0 | -4313 | 0 |
| G8 | arbitrum | 788970 | 788970 | 0 | -916 | 0 |
| G8 | robinhood | 538963 | 538953 | 0 | 0 | 0 |
| G8 | all | 948553 | 928060 | 0 | -871 | 0 |

The paired execution delta is zero at the median on every chain: the bridge list changes what the
quote searches, not what a given route costs to execute.

## Routes and delivered amount (pairs ok in both)

| campaign | chain | n | route changed | delivered changed | worst bps | best bps |
|---|---|---|---|---|---|---|
| G7 | base | 562 | 18 | 18 | -3 | -1 |
| G7 | optimism | 636 | 28 | 68 | -31 | 1 |
| G7 | arbitrum | 602 | 0 | 8 | 0 | 0 |
| G7 | robinhood | 447 | 18 | 18 | -353 | -36 |
| G8 | base | 678 | 18 | 36 | -2 | 0 |
| G8 | optimism | 480 | 6 | 24 | -12 | 4 |
| G8 | arbitrum | 384 | 0 | 18 | 0 | 0 |
| G8 | robinhood | 204 | 6 | 6 | -3 | -3 |

bps are floored (`(B - A) * 10000 // A`), so any loss reads at least -1. Every route change is on
a draw that A routed in two hops (`by route shape` in `compare.tsv`). A draw is measured in up to
six modes (D, M0 and four aged modes), so 18 changed pairs on robinhood in G7 are three draws.

## Reading

- A third bridge costs between about 0.5M and 1.8M gas per quote at the median, depending on the
  chain, and does not change execution gas at the median.
- On most draws it does not change the route or the delivered amount. Where it does, the gain
  depends on the token: wstETH on base, optimism and arbitrum moved the delivered amount by at most
  31 bps; with VIRTUAL on robinhood, the three G7 draws whose route changed delivered between 36 and
  353 bps more than without it.
- The choice of the third bridge is therefore per chain: it pays where the chain's routable tokens
  pair mainly through it, and it is quote gas spent for nothing where they do not.

## Reproduce

```
python3 -I tools/g7-gas-campaign/compare_bridges.py \
  docs/case-studies/data/gas-bridges-1126/g7/results-A-45720744246.tsv \
  docs/case-studies/data/gas-bridges-1126/g7/results-B-45720753978.tsv
python3 -I tools/g7-gas-campaign/test_compare_bridges.py
python3 -I tools/g7-gas-campaign/mutants_compare_bridges.py
```

The comparator has 14 tests and 15 mutants, each killed by an assertion; both run in the offline
job of `g7-gas-campaign.yml`. `provenance.tsv` lists the run ids, branch commits and sha256 of every
`results.tsv`.
