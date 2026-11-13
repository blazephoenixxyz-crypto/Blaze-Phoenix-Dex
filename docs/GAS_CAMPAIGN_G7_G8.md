# Gas campaigns G7 and G8: what is measured, and where

Status: first version, 13/11. Every number below cites the CI run and the line of its
`report.tsv`. A cell without a source says **not measured**. Tools:
`tools/g7-gas-campaign/` (G7, random draws over the inventory) and the G8 tool directory next to it (`tools/g8-*/`)
(G8, one case per AMM family, per bridge and per pair token).

Source run: **43376232767** (selar-G7 `e21e8f5`, dispatch 13/11 06:05), artefacts
`g7-results-43376232767/{report,results}.tsv`. `results.tsv` has 5600 rows; the draw key
(chain, stratum, idx, b, mode) is unique. Below, `R:<n>` means `report.tsv` line `n` of that run.

## 1. Dimensions (declared cells)

| Dimension | Values | Measured by | In run 43376232767 |
|---|---|---|---|
| chain | base, optimism, arbitrum, bsc, ethereum, robinhood, avalanche | `chain` column | avalanche: 0 ok rows (770 noquote, 30 mf_unforced): **not measured** |
| AMM type | the inventory families (v2, v3, v4, solidly, cl, curve, gates...) | G7 `kind`; G8 one case per family | G7 by kind (R:346-3790); per family: **not measured** (G8 not run yet) |
| hops | 1, 2 | `hops` column | per hops: **not measured** in the report (column present in results.tsv) |
| legs | 1..n | `legs`, `g_legs_sum` | g_legs_sum per chain x kind x mode (R:346-3790) |
| mode | D (Discovery), M0 / M1h (moonslot age) | `mode` | per mode (R:346-3790) |
| moonslot case | hit / partial / miss / expired | `ms_case` (added after this run) | **not measured** in this report: the new campaign (measure with universe=site) measures it |
| quote | ABI quote (`est_gas`) vs on-chain quote (`g_quote`) | `est_gas`, `g_quote` | g_quote (R:346-3790); ABI vs on-chain split: **not measured** in this report |
| segment | legs / overhead / g_record | `g_legs_sum`, `g_exec`, `g_record` | R:346-3790; overhead = g_exec - g_legs_sum - g_record - g_sweep is not a report column: **not measured** as such |

## 2. Vectors and their extremes

| Vector | Low end | High end | Measured by |
|---|---|---|---|
| amount | dust (balance / 10^5) | deep (balance / 10) | G8 `amounts` (not run yet: **not measured**) |
| registry state | venue already registered | venue admitted cold by `Hub.recordSwap` | `g_record` per mode |
| moonslot age | M0 (fresh) | expired | `mode`, `ms_case` (ms_case **not measured** in this run) |
| route shape | 1 hop direct | 2 hops via a bridge | G8 `xb-*`, `via-*` (**not measured**) |
| token | bridge token | pair token without bridge role (Base VIRTUAL) | G8 `xb-pair-*` (**not measured**) |

## 3. Seams and the invariant each one keeps

| Seam | Invariant | Measured by |
|---|---|---|
| quote <-> execution | the executed route is the quoted route; the delivered amount is measured (balance delta), not recomputed | `delivered`, `out_vs_D_bps`, `net_out` |
| registry <-> moonslot <-> expiry | an expired or missing moonslot falls back to Discovery; it never quotes a stale route | `ms_case` (**not measured** in this run) |
| bridge <-> pair token | a pair token gets bridge cases without becoming a bridge; the Hub bridge list equals the deploy script | G8 `bridges.tsv` pinned by `test_bridges_tsv_matches_deploy_addbridge` |
| Hub <-> Core | the Hub records what the Core executed; `g_record` is the Hub cost, legs are the venue cost | `g_record`, `g_legs_sum` |

## 4. Numbers per chain (kind `major`, marginal per mode, NOT paired)

The per-mode lines below are marginals over the ok rows of each mode. They are different
populations: **do not subtract them**. The paired table (same chain, stratum, idx, b; both ok)
is in section 5, from the report regenerated over the same `results.tsv`.

| chain | mode | n | g_quote p50 / p95 | g_record p50 / p95 | g_exec p50 | source |
|---|---|---|---|---|---|---|
| base | D | 20 | 11,759,662 / 21,853,457 | 686,452 / 1,755,759 | 1,153,096 | R:1355, R:1363, R:1360 |
| base | M0 | 19 | 8,872,690 / 21,831,896 | 30,379 / 1,276,200 | 1,235,400 | R:1369, R:1377, R:1374 |
| optimism | D | 28 | 3,622,412 / 4,477,265 | 292,858 / 636,500 | 607,702 | R:3063, R:3071, R:3068 |
| optimism | M0 | 29 | 3,695,575 / 10,556,935 | 12,811 / 1,016,448 | 477,830 | R:3077, R:3085, R:3082 |
| arbitrum | D | 30 | 5,127,965 / 6,360,605 | 356,052 / 1,006,943 | 719,544 | R:655, R:663, R:660 |
| arbitrum | M0 | 30 | 4,449,501 / 10,384,144 | 12,811 / 1,006,943 | 378,353 | R:669, R:677, R:674 |
| bsc | D | 22 | 3,075,085 / 7,565,617 | 320,455 / 844,537 | 690,914 | R:1859, R:1867, R:1864 |
| bsc | M0 | 22 | 2,821,459 / 7,131,030 | 16,089 / 810,576 | 391,277 | R:1873, R:1881, R:1878 |
| ethereum | D | 30 | 1,694,769 / 6,576,503 | 415,570 / 904,449 | 774,427 | R:2475, R:2483, R:2480 |
| ethereum | M0 | 30 | 829,428 / 7,958,882 | 12,758 / 61,064 | 339,721 | R:2489, R:2497, R:2494 |
| robinhood | D | 9 | 1,350,754 / 2,321,117 | 327,136 / 327,154 | 1,127,205 | R:3483, R:3491, R:3488 |
| robinhood | M0 | 9 | 963,581 / 1,745,549 | 21,604 / 21,622 | 821,673 | R:3497, R:3505, R:3502 |
| avalanche | - | 0 | not measured | not measured | not measured | 0 ok rows |

With n = 9 (robinhood) the p95 is the maximum of nine rows; read it as such.

## 5. The owner's questions

**Quote of a ready route, in Discovery and with a registered moonslot, per chain.** The
marginals are in section 4. The per-draw difference is in the `# paired vs D` section of the
report, regenerated locally (no RPC) from the `results.tsv` of run 43376232767:
`python3 -I tools/g7-gas-campaign/g7.py report <spec.json of e21e8f5> results.tsv` with g7.py at
`ac79b97`. Below, `P:<n>` is line `n` of that regenerated report. A pair is the D row and the
M0 row of the same draw (chain, stratum, idx, b), both ok; delta = M0 - D per draw, all kinds of
the chain together. The delta p95 needs n >= 20 (below it the nearest-rank p95 is the maximum).

| chain | ms_case | n_pairs | g_quote D p50 | g_quote M0 p50 | delta p50 | delta p95 | source |
|---|---|---|---|---|---|---|---|
| arbitrum | all | 80 | 4,461,284 | 4,096,488 | -365,373 | 560,727 | P:4641 |
| arbitrum | partial | 58 | 4,461,861 | 4,096,488 | -680,284 | 1,590,523 | P:4642 |
| arbitrum | miss | 22 | 3,890,021 | 3,890,021 | 0 | 0 | P:4643 |
| base | all | 77 | 9,714,814 | 8,721,866 | -1,346,531 | 0 | P:4710 |
| base | partial | 46 | 11,403,868 | 9,066,990 | -1,922,298 | -1,154,203 | P:4711 |
| base | miss | 31 | 7,184,386 | 7,184,386 | 0 | 0 | P:4712 |
| bsc | all | 76 | 5,639,124 | 5,639,124 | 0 | 25,888 | P:4758 |
| bsc | partial | 39 | 5,918,401 | 5,748,787 | -227,314 | 1,104,550 | P:4759 |
| bsc | miss | 37 | 5,639,124 | 5,639,124 | 0 | 25,888 | P:4760 |
| ethereum | all | 81 | 1,291,808 | 828,915 | -411,932 | 17,673 | P:4806 |
| ethereum | hit | 58 | 1,291,808 | 708,585 | -581,012 | 44,714 | P:4807 |
| ethereum | miss | 23 | 1,190,385 | 1,190,385 | 0 | 17,673 | P:4808 |
| optimism | all | 86 | 3,622,412 | 3,589,711 | -26,256 | 630,160 | P:4854 |
| optimism | partial | 58 | 3,809,102 | 3,647,566 | -242,367 | 3,035,036 | P:4855 |
| optimism | miss | 28 | 2,573,546 | 2,573,546 | 0 | 12,206 | P:4856 |
| robinhood | all | 58 | 1,520,169 | 1,439,500 | 0 | 50,906 | P:4902 |
| robinhood | hit | 9 | 1,350,754 | 963,581 | -321,735 | n < 20 | P:4903 |
| robinhood | partial | 9 | 1,559,780 | 1,491,205 | -68,631 | n < 20 | P:4904 |
| robinhood | miss | 40 | 1,543,144 | 1,556,240 | 13,105 | 50,906 | P:4905 |
| avalanche | all | 0 | not measured | not measured | not measured | not measured | P:4689 |

No `expired` M0 pair exists (M0 is age 0). M1h, M6h, M24h, M72h and the MF modes have their own
lines in the same section (P:4640-4961); g_exec and g_record are paired the same way.

**Why Base costs ~0.6-0.7 M in the cold registry.** `g_record` is the gas of the
`Hub.recordSwap` frames under the Router. When the executed AMM venue is not yet in the
registry, `recordSwap` admits it (writes the new registry rows); once it is registered the
same call is a short update. The tool's own trace split (`tools/g7-gas-campaign/g7.py:312-316`)
measured 710,573 of a g_exec of 1,011,096 on Base for a cold admission against 12,706 once the
venue is registered. In run 43376232767 the Base `major` p50 of g_record is 686,452 in D
(n = 20, R:1363) and 30,379 in M0 (n = 19, R:1377). The ~591k figure quoted earlier is the
Base D g_record p50 over 1-hop, 1-leg routes: 591,221 (n = 47), recomputed from the same
`results.tsv` (rows with mode D, outcome ok, hops 1, legs 1). It is not a report line: the report
does not split by hops.
