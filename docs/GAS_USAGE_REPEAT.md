# Repeated use of one route: execution and quote gas, three vs two Hub bridges

The same G7 draw is executed several times in a row, each time on the state the previous
execution left, to measure how gas changes as a pair is used. The run is done twice, with three
and with two Hub bridges, on the same draws. All values come from
`docs/case-studies/data/gas-usage-1126/`; percentiles are nearest-rank, medians are per draw.

## Setup

| item | A (three bridges) | B (two bridges) |
|---|---|---|
| base, optimism, arbitrum | WETH, USDC, wstETH | WETH, USDC |
| robinhood | WETH, USDG, VIRTUAL | WETH, USDG |
| base, optimism, arbitrum run | 45727452792 | 45732026556 |
| robinhood run | 45727456340 | 45727452792 |

- The bridge states are the ones of `GAS_BRIDGES_3_VS_2.md` (state files byte-identical to that
  report's runs); spec, seed and universe are shared, so the 3204 rows pair one to one, with no
  draw that is ok in one run and not in the other.
- **U1..U5** (`usage_steps: 5`): U1 is the campaign's D row at block b (checked: equal `g_exec`
  and `delivered` for all 303 draws ok at U1). Uk runs the same quote and execution again at
  block b on the state Uk-1 left (prestateTracer diff carried into the state override).
- **S2..S5** (`usage_seed: true`): after U1, the operator calls `Hub.seedPool` on the stratum's
  seed pools, on U1's state; S2..S5 then repeat the draw on that state. S1 is U1.
- `g_exec` is the gas the swap pays on chain; `g_record` is the part of it spent recording the
  pool; `g_quote` is the Quoter's preview, an `eth_call` the user does not pay for.
  `ms_case` says whether the quote skipped discovery: **hit** (no discovery), **partial**
  (discovery left only on bridge legs), **miss** (full discovery).

## Execution gas drops once, at the second swap

Median `g_exec` delta vs U1 (A; B within 4 % of A on every cell, both in `usage-*.tsv`):

| chain | n | U1 | step 2 | step 3 | step 4 | step 5 | step 2 lower/higher |
|---|---|---|---|---|---|---|---|
| base | 78-74 | 1,117,846 | -569,637 | -616,159 | -705,711 | -650,628 | 68 / 10 |
| arbitrum | 81 | 754,597 | -392,578 | -392,794 | -396,148 | -397,465 | 72 / 9 |
| optimism | 86-84 | 623,032 | -342,688 | -334,861 | -342,671 | -335,729 | 71 / 14 |
| robinhood | 58-57 | 796,359 | -364,200 | -345,058 | -376,503 | -306,908 | 54 / 4 |

The drop is the pool admission paid once: median `g_record` goes from 685,766 to 21,378 on
base, 353,984 to 21,465 on arbitrum, 304,056 to 16,045 on optimism and 314,568 to 12,811 on
robinhood between U1 and U2. After step 2 there is no further drop: the paired median of
Uk - U2 at steps 3 to 5 lies between -1,957 and 0 on every chain in both runs. Single draws
spread widely around it (p5 to p95 up to -2.0M / +1.6M on base), so one later swap can cost
more or less than the second. Draws counted at step k are those ok at every step up to k, so
n shrinks by up to 4.

## Quote gas drops only when the pairs are seeded

Median `g_quote` delta vs U1:

| chain | U2..U5 (A) | S2..S5 (A) | S2..S5 (B) |
|---|---|---|---|
| base | +30,122 to +39,349 | -942,781 to -1,139,417 | -948,453 to -1,126,860 |
| arbitrum | +9,942 to +13,529 | -355,434 to -491,063 | -351,125 to -489,476 |
| optimism | +12,403 to +13,956 | -21,555 to +8,102 | -22,095 to +4,639 |
| robinhood | +12,386 to +12,596 | -61,157 to +12,596 | -61,017 to +12,438 |

Usage alone leaves every quote a miss (all U2..U5 rows, both runs): the swap records the pool
in a tier that the Solver's freshness check (`_registryFresh`, `BlazePhoenixSolver.sol`) does
not count; only seeded (tier 0) rows count, at least `MIN_FRESH_VENUES` = 3 of them per pair.
This is deliberate: a row any swapper can write must not be able to switch discovery off.

Quote case at S2 (same counts at S3..S5 up to the draws lost on the way):

| chain | A hit / partial / miss | B hit / partial / miss |
|---|---|---|
| base | 0 / 46 / 31 | 4 / 42 / 31 |
| arbitrum | 0 / 58 / 23 | 6 / 52 / 23 |
| optimism | 0 / 57 / 28 | 6 / 51 / 28 |
| robinhood | 0 / 18 / 40 | 9 / 9 / 40 |

- Every hit and partial row had all three seeds accepted (`seeds_ok` 3 of 3). Every miss had
  fewer than three seed pools in its stratum (0, 1 or 2) or three seeds not accepted (0 of 3);
  the reason for the refusals was not examined in this run.
- In every partial row the remaining discovery gas equals the bridge-leg discovery
  (`g_discovery` = `g_discovery_bridge`, 154 of 154 in B, 179 of 179 in A).
- The 25 draws that are hits in B were partials in A: the bridge-leg discovery they still paid
  with three bridges is gone with two.

## Three vs two bridges along the usage chain

Paired B - A, median (`compare.tsv`):

| chain | `g_quote` U1 | `g_quote` S5 | `g_exec` U1 | `g_exec` S5 | route changed (S5) |
|---|---|---|---|---|---|
| base | -912,001 | -914,052 | 0 | 0 | 4 of 75 |
| arbitrum | -837,904 | -838,031 | 0 | 0 | 0 of 81 |
| optimism | -736,081 | -736,182 | 0 | 0 | 4 of 84 |
| robinhood | -518,949 | -518,945 | 0 | 0 | 3 of 57 |

The bridge count moves the quote by the same amount before and after usage and seeding; it does
not change the execution gas or how usage changes it. Delivered amounts where the route changed:
`compare.tsv`, section "route and output".

## Reading

- Measured: a pair's second swap costs less to execute by the admission cost (about 0.3M to
  0.6M gas at the median, by chain); later swaps cost, at the median, what the second cost.
- Measured: seeding the stratum's pools after discovery lowers the quote on base and arbitrum
  and turns misses into partials; usage without seeding does not.
- Not measured: seeding the bridge-leg pairs as well. The partial rows' remaining discovery is
  exactly the bridge legs, so this is the next variant to run, not a result.

## Reproduce

```
python3 -I tools/g7-gas-campaign/usage_report.py docs/case-studies/data/gas-usage-1126/results-A.tsv
python3 -I tools/g7-gas-campaign/compare_bridges.py docs/case-studies/data/gas-usage-1126/results-A.tsv \
    docs/case-studies/data/gas-usage-1126/results-B.tsv
```

`results-A.tsv` and `results-B.tsv` join the per-run `results.tsv` listed in `provenance.tsv`
(chains as in the setup table; sha256 of every source and of both joined files).
