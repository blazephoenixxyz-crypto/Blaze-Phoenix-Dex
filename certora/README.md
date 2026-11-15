# Certora formal verification

Top of the formal ladder (SMTChecker → Halmos → Kontrol → **Certora**).

**Status: no rule is proven yet.** The Certora Prover runs in the vendor cloud and needs the
`CERTORAKEY` secret. Until a run with the key reports a verdict, every rule below is a
written, type-checked claim, not a proof. Locally, `--compilation_steps_only` compiles the
harnesses and type-checks the specs; it proves nothing.

## Activate
1. Get a key (certora.com).
2. GitHub: Settings → Secrets and variables → Actions → New repository secret,
   name `CERTORAKEY`.
3. The next run of `.github/workflows/security.yml` runs the `certora` matrix. Without the
   key, `certora-gate` writes "Certora NOT RUN - no rule proven" to the run summary and every
   matrix entry shows SKIPPED.

Every conf sets `wait_for_results: "all"`: without it `certoraRun` exits 0 as soon as the
job is submitted, a green that proved nothing. `rule_sanity: "basic"` flags vacuous rules.
The matrix runs with `fail-fast: false`, one job per conf, and one job per rule for
`router-swap`.

## Run locally
```
pip install certora-cli==8.20.3 solc-select     # needs Java 11+
solc-select install 0.8.36 && solc-select use 0.8.36
ln -sf "$(command -v solc)" ~/.local/bin/solc0.8.36
certoraRun certora/conf/<conf>.conf --compilation_steps_only   # compile + type-check, no key
CERTORAKEY=<key> certoraRun certora/conf/router-swap.conf --rule routerHoldsNothing
```

## Rules and the mutant that must turn each red
| conf | rule | mutant (src) |
|---|---|---|
| effv4fee | EffV4Fee.spec (INV-20) | `pf == 0` → `pf != 0`; `return 0xFFFFFF` → `return lpFee`; swap `& 0xFFF` and `>> 12` (Core `effV4Fee`) |
| floorsfee | constantsArePinned, protocolFeeIsCeilOf28Bps | `PROTOCOL_FEE_BPS` 28 → 29 |
| floorsfee | protocolFeePaysAndNeverSwallows | fee `mulDivUp` → `mulDiv` |
| floorsfee | legFloorIsCeil80, hopRuleCollapsesToLegFloorAtN1 | leg floor `mulDivUp` → `mulDiv` |
| floorsfee | moreLegsNeverLoosensHopSlack, hopSlackNeverExceedsOneAverageLeg | `hopBound / hopQuoted` → `hopBound` |
| floorsfee | ironFloorBounds | delete `if (floorBps < hardFloor)`; invert `total >= base ? hardFloor : …` |
| floorsfee | ironFloorMonotoneInShaves | `base - total` → `base + total` |
| router-control | controlGateOnSetters | drop `onlyControl` from `setPermit2`; `\|\|` → `&&` in `_onlyControl` |
| router-control | configOnlyByControl | `moveTreasury` from treasury1 writes treasury2 |
| router-control | renounceIsForever | `moveTreasury` also writes `controlRenounced = false` |
| router-control | renounceRefusedWhilePaused, neverPausedAndRenounced | delete `if (paused) revert RouterE(2)` in `renounceControl` |
| router-control | queueSetsFortyEightHourEta | `RESCUE_DELAY` 48 h → 47 h |
| router-control | rescueTimelockAndSingleUse | delete `\|\| block.timestamp < eta`; delete `delete rescueEta[k]` |
| router-control | rescueNeverTakesOwedFees | delete `amt = amt > o ? amt - o : 0` |
| router-swap | zeroMinOutRefused | delete the `userMinOut == 0` refusal of swapExactIn / Native / Best |
| router-swap | amountInAboveU128Refused | delete the `amountIn > type(uint128).max` refusal of a door |
| router-swap | pausedBlocksEverySwapDoor | drop `whenLive` from one door |
| router-swap | deliveryAtLeastMinOutOrRevert | delete BOTH `delivered < userMinOut` and `amountOut < effMin` reverts |
| router-swap | routerHoldsNothing | delete the tokenIn residue sweep after the hop loop |

A mutant counts as killed only in a keyed run that reports the rule violated.

## Limits (read before trusting a verdict)
- **Inline copies.** `FloorsFeeHarness.legFloor`, `hopSlack` and `protocolFee` are COPIES of
  Router expressions (the per-leg floor, the hop slack, the hop fee), and
  `RouterHarness.rescueKey` copies the rescue key. A proof about a copy is a proof about the
  copy: a mutant on the Router line itself is killed by the forge suite, not by these specs.
  If the Router expression changes, the copy must change with it.
- **Venue model (router-swap).** Unresolved external calls (pools, PoolManager, WETH,
  Permit2) are `HAVOC_ECF`: they may rewrite any other contract's storage and cannot
  reenter the Router. Hub calls are `NONDET`. A `NONDET` venue would make the swap rules
  vacuous (no tokB ever arrives, every swap reverts at `amountOut < effMin`). The havoc can
  also debit the recipient's tokB without an allowance, which no ERC20 allows: a
  counterexample to `deliveryAtLeastMinOutOrRevert` of that shape is the model, not the
  Router, and is triaged, not counted.
- **Surface.** router-control's parametric rules range over the control surface and views
  only; the swap doors are not shown to leave the control slots alone. router-swap covers
  `swapExactIn` for delivery and holds-nothing (1-2 hops, tokA → tokB); the Permit2 door is
  only in `pausedBlocksEverySwapDoor`.
- **Internal summaries.** Certora's internal-function finder does not instrument this
  source (a Yul variable named `sub`), so no internal function is summarized.
- Loops are unrolled twice (`loop_iter: 2`, `optimistic_loop`): longer routes are assumed,
  not proven.
