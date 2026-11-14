# Gas campaigns G7 and G8: what is measured, and where

Status: first version, 13/11; section 6 (re-measure at `bb4cdbb`) and section 7 (DEX used per chain) added 14/11. Every number below cites the CI run and the line of its
`report.tsv`. A cell without a source says **not measured**. Tools:
`tools/g7-gas-campaign/` (G7, random draws over the inventory) and the G8 tool directory next to it (`tools/g8-*/`)
(G8, one case per AMM family, per bridge and per pair token).

Source run: **43376232767** (selar-G7 `e21e8f5`, dispatch 13/11 06:05), artefacts
`g7-results-43376232767/{report,results}.tsv`. `results.tsv` has 5600 rows; the draw key
(chain, stratum, idx, b, mode) is unique. Below, `R:<n>` means `report.tsv` line `n` of that run,
and `P:<n>` means line `n` of the report regenerated locally (no RPC) from the same `results.tsv`
with g7.py at `ac79b97` (command in section 5). Lines 1-4961 are byte-identical with g7.py at
`2bc266d`, which appends the `# g_record by hops x legs` section (P:4962-5003).

## 1. Dimensions (declared cells)

| Dimension | Values | Measured by | In run 43376232767 |
|---|---|---|---|
| chain | base, optimism, arbitrum, bsc, ethereum, robinhood, avalanche | `chain` column | avalanche: 0 ok rows (770 noquote, 30 mf_unforced): **not measured** |
| AMM type | the inventory families (v2, v3, v4, solidly, cl, curve, gates...) | G7 `kind`; G8 one case per family | G7 by kind (R:346-3790); per family: **not measured** (G8 not run yet) |
| hops | 1, 2, 3 | `hops` column | `g_record` per chain x hops x legs, D vs M0: `# g_record by hops x legs` (P:4962-5003), table in section 5 |
| legs | 1..n | `legs`, `g_legs_sum` | g_legs_sum per chain x kind x mode (R:346-3790) |
| mode | D (Discovery), M0 / M1h (moonslot age) | `mode` | per mode (R:346-3790) |
| moonslot case | hit / partial / miss / expired | `ms_case` (a column after this run; the report derives it per row, `g7.py` `ms_case`) | `# moonslot cases` per chain x kind x case (P:3971-4536); ok rows: D 459, hit 272, partial 879, miss 362, expired 1407 (sum 3379 = all ok rows); paired M0 vs D in section 5 |
| quote | ABI quote (`est_gas`) vs on-chain quote (`g_quote`) | `est_gas`, `g_quote` | g_quote (R:346-3790); ABI vs on-chain split: **not measured** in this report |
| segment | legs / DEX overhead (g_record and the sweep inside it) | `g_legs_sum`, `g_exec`, `g_record`, `g_sweep` | each per chain x kind x mode (R:346-3790). `dex_overhead` = g_exec - g_legs_sum: all the Router frame pays above the venue legs (Router, Hub `recordSwap`, sweep); `rec_frac` = g_record / g_exec. Per chain x kind in `# exec split` (P:4537-4571), per case in P:3971-4536 (`g7.py` `split_value`, pinned by `ReportSplit.test_exec_split_per_chain_kind`). g_record is a part of the overhead, not a third disjoint segment |

## 2. Vectors and their extremes

| Vector | Low end | High end | Measured by |
|---|---|---|---|
| amount | dust (balance / 10^5) | deep (balance / 10) | G8 `amounts` (not run yet: **not measured**) |
| registry state | venue already registered | venue admitted cold by `Hub.recordSwap` | `g_record` per mode |
| moonslot age | M0 (fresh) | expired (record older than the TTL, 3600 s) | `mode`, `ms_case` (P:3971-4536) |
| route shape | 1 hop direct | 2 hops via a bridge | G8 `xb-*`, `via-*` (**not measured**) |
| token | bridge token | pair token without bridge role (Base VIRTUAL) | G8 `xb-pair-*` (**not measured**) |

## 3. Seams and the invariant each one keeps

| Seam | Invariant | Measured by |
|---|---|---|
| quote <-> execution | the executed route is the quoted route; the delivered amount is measured (balance delta), not recomputed | `delivered`, `out_vs_D_bps`, `net_out` |
| registry <-> moonslot <-> expiry | an expired or missing moonslot falls back to Discovery; it never quotes a stale route | `ms_case` per chain x kind (P:3971-4536) and the paired M0 vs D table (section 5) |
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
same call is a short update. The tool's own trace split (`tools/g7-gas-campaign/g7.py:313-318`)
measured 710,573 of a g_exec of 1,011,096 on Base for a cold admission against 12,706 once the
venue is registered. In run 43376232767 the Base `major` p50 of g_record is 686,452 in D
(n = 20, R:1363) and 30,379 in M0 (n = 19, R:1377). The ~591k figure quoted earlier is the
Base D g_record p50 over 1-hop, 1-leg routes: 591,221 (n = 47, P:4972).

**g_record, D cold vs M0, per chain x hops x legs.** From the `# g_record by hops x legs`
section of the regenerated report (P:4962-5003): ok rows with a g_record, D and M0 each a
marginal (NOT paired: the D row and the M0 row of one draw may route through a different number
of hops or legs), all kinds of the chain together. The p95 needs n >= 20, as in the paired table.
Avalanche has no ok row, so no line. The per-draw view is the paired g_record line of each chain
(M0, ms_case all): P:4647 arbitrum, P:4716 base, P:4764 bsc, P:4812 ethereum, P:4860 optimism,
P:4910 robinhood, P:4691 avalanche (n 0).

| chain | hops | legs | D n | D p50 | D p95 | M0 n | M0 p50 | M0 p95 | source |
|---|---|---|---|---|---|---|---|---|---|
| arbitrum | 1 | 1 | 48 | 341,464 | 356,070 | 48 | 12,793 | 353,984 | P:4963 |
| arbitrum | 1 | 2 | 5 | 514,764 | n < 20 | 5 | 21,552 | n < 20 | P:4964 |
| arbitrum | 1 | 3 | 6 | 695,981 | n < 20 | 8 | 34,709 | n < 20 | P:4965 |
| arbitrum | 1 | 4 | 2 | 811,400 | n < 20 | 2 | 811,400 | n < 20 | P:4966 |
| arbitrum | 1 | 5 | 3 | 1,081,301 | n < 20 | 0 | not measured | not measured | P:4967 |
| arbitrum | 2 | 2 | 10 | 615,178 | n < 20 | 11 | 615,178 | n < 20 | P:4968 |
| arbitrum | 2 | 3 | 4 | 799,340 | n < 20 | 4 | 799,340 | n < 20 | P:4969 |
| arbitrum | 2 | 4 | 1 | 1,006,943 | n < 20 | 1 | 1,006,943 | n < 20 | P:4970 |
| arbitrum | 2 | 5 | 1 | 1,188,613 | n < 20 | 1 | 1,188,613 | n < 20 | P:4971 |
| base | 1 | 1 | 47 | 591,221 | 742,969 | 42 | 12,793 | 735,471 | P:4972 |
| base | 1 | 2 | 1 | 1,040,578 | n < 20 | 2 | 21,534 | n < 20 | P:4973 |
| base | 1 | 3 | 5 | 1,366,207 | n < 20 | 6 | 30,380 | n < 20 | P:4974 |
| base | 1 | 4 | 1 | 1,936,878 | n < 20 | 0 | not measured | not measured | P:4975 |
| base | 1 | 5 | 2 | 1,755,759 | n < 20 | 0 | not measured | not measured | P:4976 |
| base | 2 | 2 | 17 | 929,920 | n < 20 | 21 | 1,207,095 | 1,275,694 | P:4977 |
| base | 2 | 3 | 2 | 1,630,308 | n < 20 | 3 | 1,630,308 | n < 20 | P:4978 |
| base | 2 | 4 | 1 | 1,956,751 | n < 20 | 1 | 1,956,751 | n < 20 | P:4979 |
| base | 2 | 5 | 1 | 2,461,246 | n < 20 | 1 | 2,461,246 | n < 20 | P:4980 |
| base | 2 | 6 | 1 | 2,492,906 | n < 20 | 1 | 2,492,906 | n < 20 | P:4981 |
| bsc | 1 | 1 | 39 | 300,604 | 320,599 | 39 | 16,124 | 315,743 | P:4982 |
| bsc | 1 | 2 | 5 | 487,340 | n < 20 | 5 | 487,340 | n < 20 | P:4983 |
| bsc | 1 | 3 | 0 | not measured | not measured | 1 | 40,301 | n < 20 | P:4984 |
| bsc | 1 | 4 | 3 | 844,537 | n < 20 | 2 | 55,439 | n < 20 | P:4985 |
| bsc | 2 | 2 | 19 | 552,842 | n < 20 | 19 | 552,842 | n < 20 | P:4986 |
| bsc | 2 | 5 | 2 | 1,062,250 | n < 20 | 2 | 1,062,250 | n < 20 | P:4987 |
| bsc | 3 | 3 | 8 | 805,073 | n < 20 | 8 | 805,073 | n < 20 | P:4988 |
| ethereum | 1 | 1 | 53 | 391,480 | 450,367 | 53 | 12,793 | 414,051 | P:4989 |
| ethereum | 1 | 2 | 14 | 587,766 | n < 20 | 20 | 26,555 | 589,717 | P:4990 |
| ethereum | 1 | 3 | 10 | 801,298 | n < 20 | 6 | 35,658 | n < 20 | P:4991 |
| ethereum | 1 | 5 | 4 | 1,254,267 | n < 20 | 3 | 1,254,267 | n < 20 | P:4992 |
| optimism | 1 | 1 | 65 | 292,631 | 307,191 | 53 | 12,811 | 306,354 | P:4993 |
| optimism | 1 | 2 | 6 | 447,584 | n < 20 | 5 | 447,584 | n < 20 | P:4994 |
| optimism | 1 | 3 | 2 | 636,500 | n < 20 | 3 | 33,666 | n < 20 | P:4995 |
| optimism | 2 | 2 | 8 | 525,410 | n < 20 | 18 | 518,277 | n < 20 | P:4996 |
| optimism | 2 | 3 | 4 | 656,885 | n < 20 | 4 | 656,885 | n < 20 | P:4997 |
| optimism | 2 | 4 | 1 | 826,560 | n < 20 | 2 | 826,560 | n < 20 | P:4998 |
| optimism | 2 | 5 | 0 | not measured | not measured | 2 | 1,016,448 | n < 20 | P:4999 |
| robinhood | 1 | 1 | 22 | 206,181 | 206,812 | 31 | 12,793 | 206,181 | P:5000 |
| robinhood | 1 | 2 | 17 | 314,568 | n < 20 | 17 | 21,622 | n < 20 | P:5001 |
| robinhood | 1 | 3 | 3 | 448,301 | n < 20 | 3 | 448,301 | n < 20 | P:5002 |
| robinhood | 2 | 2 | 16 | 357,173 | n < 20 | 16 | 357,173 | n < 20 | P:5003 |

In the 1-hop, 1-leg line of every chain the M0 p50 (12,793 to 16,124) is the short update and the
D p50 (206,181 to 591,221) the cold admission. Where the M0 p50 equals the D p50 (for example
P:4983, P:4986), the M0 rows of that cell paid the same g_record as D; why is not measured here.

**An earlier note on the same run, not reproduced.** An earlier internal note gave the 1-hop,
1-leg D g_record p50 of all six chains with these n: base 47, ethereum 50, arbitrum 47, bsc 39,
optimism 65, robinhood 20. Its six p50 equal the lines above (P:4963, P:4972, P:4982, P:4989,
P:4993, P:5000). Its n equals ours on base, bsc and optimism and differs on three chains:
ethereum 53 here against 50, arbitrum 48 against 47, robinhood 22 against 20. The note did not
record its row filter. Fourteen filters over the same `results.tsv` were tried and none gives
its n on those three chains. The merged `results.tsv` and the per-chain artefact of each of the
six chains give the same 800 rows and the same n, so the gap is not a merge artefact. The n
used in this document are the report's (P:4962-5003); the three earlier n are not used.

## 6. Re-measure at `bb4cdbb`: swap coverage, harness causes, fixes

Source: the local re-measure `docs/case-studies/data/gas-1114/g7/results-bb4cdbb.tsv` (same spec
and seed as run 43376232767; 6 chains x 800 rows, avalanche absent, not zero) and its report
`report-bb4cdbb.tsv` in the same directory, regenerated with g7.py at `8c844a1` (command and
sha256 in `provenance.tsv`). Below, `B:<n>` means line `n` of that report.

**Swap coverage.** The outcome table counts an `mf_unforced` row as not ok. That row is a
forced-memory mode the harness could not force; when its natural twin `M<age>` of the same draw
is ok, the swap itself works. `swap coverage` (g7.py `swap_coverage`, `8c844a1`) counts such a
row as ok; the denominator stays every row.

| chain | n | ok | mf_unforced, twin ok | swap ok | swap ok % | source |
|---|---|---|---|---|---|---|
| arbitrum | 800 | 608 | 48 | 656 | 82.0 | B:299 |
| base | 800 | 562 | 62 | 624 | 78.0 | B:300 |
| bsc | 800 | 534 | 74 | 608 | 76.0 | B:301 |
| ethereum | 800 | 626 | 46 | 672 | 84.0 | B:302 |
| optimism | 800 | 648 | 56 | 704 | 88.0 | B:303 |
| robinhood | 800 | 447 | 80 | 527 | 65.9 | B:304 |
| avalanche | - | - | - | - | not measured | absent from the re-measure |

**Harness causes.** Rows that are not ok because of the campaign harness, not the Quoter, the
Solver or the market. Counts are draws and rows of `results-bb4cdbb.tsv`, classified by replaying
each failed draw on a fork at its block (the per-draw replay is not in this repository).

| cause | what | draws | rows | status |
|---|---|---|---|---|
| H1 | the stratum's venue has no code at the draw's block (created after it; the inventory was taken at a later head) | 55 | 440 | `a1849b4`: a stratum keeps only pools alive at b0 (V2/V3 code, V4 slot0 and both tokens' code); takes effect with a rebuilt spec, so not yet in these rows |
| H1b | same root as H1 for V4: the venue's slot0 is 0 at the draw's block | 17 | 136 | `a1849b4`, as H1 |
| H2 | `mf_unforced` row of a draw whose swap is ok | 183 | 366 | `8c844a1`: counted by its twin in swap coverage (the 366 rows are the column `mf_unforced, twin ok` above); seeding V4-native pools through `addV4` not done |
| H4 | the G7 deploy script does not wire V4 as the fixture it mirrors (`_v4Wire`: `setWeth` and the `MODE_V4_DERIVE` line) on robinhood, optimism and arbitrum | 10 (robinhood; other chains not measured) | 17 (robinhood; other chains not measured) | recorded, not changed |
| M1 | amount ladder below one unit of output on dust pools (ladder 1e-7..1e-1 of the venue balance) | 13 | 104 | recorded, not changed; the floor N is the owner's number |

**Fixes in source, with the draws they settle.** Each draw was replayed on a fork at its block;
the test pins it there. The rows of `results-bb4cdbb.tsv` were measured before these commits
(all 8 rows of each draw are `revert` or `mf_unforced`); a re-measure on the fixed source is
**not measured**.

| commit | what changed | draws | test |
|---|---|---|---|
| `6e1bc78` | the in-frame quote of a cut V3 walk answers what it walked, min(walked, f); the Solver's promise keeps the rest. Before, a cut walk priced the rest of the input on the last range read, so the frame quoted more than the venue pays and the protocol floor (`Router.sol:1649`) refused the fill | bsc gate-6-2 idx 5 (b 132377036), bsc midtail-2 idx 2 (b 132580903) | `test/fork/G7ErrBscV3PayReadsOverstatePoolProtocolFloor.t.sol` |
| `4f729bc` | encode doors refuse a zero floor (`RouterE(10)`); for one unit of USDC the fee took the base and the door encoded `minOut` 0, which the Router refuses | ethereum shallow-3 idx 2 (b 26316739), ethereum shallow-3 idx 5 (b 26325844) | `test/fork/G7ErrEthShallow3ZeroFloorEncoded.t.sol` |
| `f82bc67` | encode doors fall back once to the Solver's runner-up when the leader's bytes do not settle | none of the draws above | `test/QuoterEncodeFallsBackOnce.t.sol`, `test/fork/G7ErrEthC6UnwalkedLastHop.t.sol` |

## 7. DEX used per chain

Source: the `# dex used` (B:4895-4935) and `# dex available` (B:4936-4986) sections of
`report-bb4cdbb.tsv`, regenerated from the same `results-bb4cdbb.tsv` (lines 1-4894 unchanged; sha256
in `provenance.tsv`). Only `outcome == ok` rows count: the routes that settled. A leg is one entry of
`legs_detail` (a swap or unlock frame under the Router, not nested in another leg); `% legs` is the
share of the chain's ok legs, `% gas` the share of their frame gas.

**Not volume.** `legs_detail` records `<target>:<gas>` per leg and no amount, so the share of the
traded volume per DEX is **not measured** for this re-measure. The runner now writes a `leg_amt`
column (the input paid to each leg: token transfers into the leg's target under the Router, and
native value sent to it); it fills only in campaigns run after this change.

**Naming (`basis`).** A leg's target is mapped to its venue through `docs/prereg/gas-1114-universe.tsv`
(a V4 leg's target is the PoolManager itself). `factory`: a repo constant at that address on the
same chain names the DEX (the constant's file and line are in g7.py `DEX_NAME`). `addr`: no constant
on this chain, but the same address with the same kind is named on another chain. `kind`: the kind
names one protocol (for example `algebra`, `curve_ng`). `gate`: a Gate row (`gate_used = 1`) named by
its stratum's gate family. `seed`: a seed pool of the stratum in the spec, named only by its Hub
kind. `unknown`: none of these; unknown is a missing name, not a missing DEX.

Top three DEXes per chain by legs:

| chain | ok legs | 1st | 2nd | 3rd | basis `unknown` | source |
|---|---|---|---|---|---|---|
| arbitrum | 1073 | Uniswap V3: 51.4 % legs, 25.8 % gas | PancakeSwap V3: 23.3 %, 63.8 % | unknown: 9.5 %, 3.8 % | 9.5 % | B:4896-4903 |
| base | 1016 | Uniswap V3: 34.4 %, 18.7 % | PancakeSwap V3: 18.5 %, 51.8 % | Aerodrome CL: 15.7 %, 10.1 % | 10.6 % | B:4904-4912 |
| bsc | 866 | PancakeSwap V3: 58.2 %, 87.6 % | Uniswap V3: 24.2 %, 6.7 % | unknown: 9.2 %, 2.4 % | 9.2 % | B:4913-4916 |
| ethereum | 1252 | Uniswap V3 (`addr`): 56.9 %, 80.0 % | unknown v2: 13.6 %, 3.0 % | PancakeSwap V3 (`addr`): 10.4 %, 9.7 % | 23.8 % | B:4917-4924 |
| optimism | 1006 | Uniswap V3: 52.0 %, 46.4 % | unknown cl: 18.8 %, 22.7 % | Velodrome: 11.8 %, 15.6 % | 22.4 % | B:4925-4931 |
| robinhood | 693 | Uniswap V3: 76.2 %, 42.1 % | Uniswap V4: 9.1 %, 55.6 % | Uniswap V2: 7.8 %, 1.1 % | 6.9 % | B:4932-4935 |
| avalanche | - | not measured | - | - | - | absent from the re-measure |

`ok legs` is the sum of the `legs` column over the cited lines; `basis unknown` is the share of
those legs whose basis is `unknown` (legs named only by their `seed` kind are not in it). `# dex available` lists each venue of the universe with its pools, the
routable ones and the ok legs that used it. The G8 report (`g8/report-bb4cdbb.tsv`) carries the same
two sections, because g8.py prints g7's report first; this document cites none of its lines.
