# Swap Transaction Flow

A step-by-step reference for the path a swap takes through the public V2 source: the read-only
quote, the user's transaction, the execution core, the delivered-amount check and the events it
emits. Every statement names the file and the line it rests on, at one pinned commit, so a reader
can re-check it without trusting this text.

| | |
|---|---|
| Pinned commit | `d2cb3b385483e8f6cd1c0fe5bee76a94cf18a890` |
| Router version string | `2.0.0` (`Router:129`) |
| Entry points covered | `swapExactIn`, `swapExactInWithPermit2`, `swapExactInNative`, `swapBestExactIn` |
| Not covered | admin and rescue functions, the Hub registry internals, the Solver's route search |
| Generation | this is the V2 source in this repository; the contracts live on chain today are the previous generation, a separate archived codebase |

Citations read `Router:380` for `src/BlazePhoenixRouter.sol`, line 380, at the pinned commit. The
other prefixes are `Quoter`, `Solver`, `Core` (`src/BlazePhoenixQuoter.sol`,
`src/BlazePhoenixSolver.sol`, `src/BlazePhoenixCore.sol`). Later commits can move lines; the pinned
commit cannot. See "Re-checking a statement" at the end.

## 1. The path at a glance

```text
 read only                           user transaction                         same transaction
 ---------                           ----------------                         ----------------
 Solver.findBestRoutePlan   ----->   swapExactIn                 ----->       pull the input (measured)
 Quoter.previewPlan*                 swapExactInWithPermit2                   per hop: fee, scale, legs
 Quoter.previewAndEncode*            swapExactInNative                        per-leg and per-hop floors
 Quoter.previewPlanExact             swapBestExactIn                          output floor and userMinOut
                                     (userMinOut and deadline                 pay the recipient (measured)
                                      travel in the calldata)                 events: Swap, ExecutionProof, Fee
```

## 2. The pieces

| Piece | File | Role in the flow |
|---|---|---|
| Solver | `BlazePhoenixSolver.sol` | `findBestRoutePlan(tIn, tOut, amountIn)` is a `view` function that returns a `RoutePlan` (`Solver:258`; the Router's interface to it is `Router:62-65`). |
| Quoter | `BlazePhoenixQuoter.sol` | Read-only previews built on the Solver's plan (`Quoter:192-268`, `Quoter:586`). |
| Router | `BlazePhoenixRouter.sol` | The four entry points and the execution core (`Router:380-595`, `Router:973-1593`). |
| Hub | `BlazePhoenixHub.sol` | The registry the Router reads (`isBridgeToken`, `v4PoolManager`, `hookPaused`) and reports to (`recordSwap`) (`Router:67-77`). |
| Core | `BlazePhoenixCore.sol` | Shared types and arithmetic, imported by the Router as `BPC` (`Router:57-60`). |

The route is plain data. `Route` holds the hops plus the attested totals and the attested output
floor (`Core:103`); a `Hop` holds its two tokens, its input, its attested output and its legs
(`Core:95`); a `Leg` holds the venue address, the hooks address, the venue kind, the fee, the tick
spacing, the direction, the stable flag, the leg input, the leg's attested output and an auxiliary
id (`Core:82`). A `RoutePlan` is a best route plus a fallback (`Core:115`).

## 3. Step 1 - the quote (read only)

| Function | Kind | Returns |
|---|---|---|
| `Solver.findBestRoutePlan` | `view` | the best route and a runner-up (`Solver:258`) |
| `Quoter.previewPlan` | `view` | a `Preview` of the best route plus the fallback (`Quoter:192`) |
| `Quoter.previewPlanWithMinOut` | `view` | the same, with the caller's tighter minimum folded in (`Quoter:204`) |
| `Quoter.previewAndEncode`, `previewAndEncodeWithMinOut` | `view` | the `Preview` and the exact calldata of a `swapExactIn` call with `effectiveMinOut` inside it; the bytes are empty when `canExecute` is false (`Quoter:222-244`) |
| `Quoter.previewRoute` | `view` | the `Preview` of a route supplied by the caller (`Quoter:248`) |
| `Quoter.batchQuote` | `view` | one `Preview` per entry, up to `MAX_BATCH` (`Quoter:255-268`) |
| `Quoter.previewPlanExact` | not `view`; meant for `eth_call` | the route and `exactOut`, the execution-grade net output, re-priced by dry-running the concentrated-liquidity legs (`Quoter:572-586`) |

The `Preview` struct carries `grossOut`, `protocolFee`, `netOut`, `ironFloor`, `userMinOut`,
`effectiveMinOut` (the larger of the caller's minimum and the Solver's output floor), `estGas`, the hop and
leg counts, `bridgeUsed` and `canExecute` (`Quoter:165-181`).

## 4. Step 2 - the user's transaction

Every entry point carries two modifiers: `whenLive` reverts `RouterE(2)` while the Router is paused
(`Router:278`), and `nrEntrant` is a transient-storage reentrancy lock that reverts `RouterE(7)`
(`Router:279-284`). The calldata always carries `userMinOut`, `recipient` and `deadline`.

| Entry point | How the input arrives | Minimum-output rule | Where the deadline is checked |
|---|---|---|---|
| `swapExactIn(route, amountIn, userMinOut, recipient, deadline)` (`Router:380`) | pulled from `msg.sender` with `safeTransferFrom`, so the caller must have approved the Router beforehand; the received amount is measured (`Router:569-572`) | `amountIn > 0` with `userMinOut == 0` reverts `RouterE(10)` (`Router:395`); `amountIn` above `uint128` max reverts `RouterE(3)` (`Router:394`) | `block.timestamp > deadline` reverts `RouterE(4)`, before the pull (`Router:563`) |
| `swapExactInWithPermit2(..., permit, signature)` (`Router:400`) | pulled through Permit2 `permitTransferFrom` with the owner argument set to `msg.sender` (`Router:422-426`); the permitted token must equal `route.hops[0].tokenIn` (`Router:420`) and the permitted amount must cover `amountIn` (`Router:407`); the received amount is measured (`Router:421-428`) | same rule (`Router:406`) | in the shared internal function, after the pull and inside the same transaction (`Router:591`) |
| `swapExactInNative(route, userMinOut, recipient, deadline)`, payable (`Router:465`) | `msg.value` is wrapped once into the configured wrapped-native token and the measured balance change is used (`Router:468-481`); the route must start in that token (`Router:474`) | `userMinOut == 0` reverts `RouterE(10)` (`Router:472`) | `Router:591` |
| `swapBestExactIn(tokenIn, tokenOut, amountIn, userMinOut, recipient, deadline)` (`Router:504`) | the route is solved inside the transaction by `findBestRoutePlan` (`Router:512`); both ends of the plan are checked against `tokenIn` and `tokenOut` (`Router:519-522`); the input is then pulled from `msg.sender` and measured (`Router:523-526`) | `userMinOut == 0` reverts `RouterE(10)` (`Router:509`) | `Router:591`, reached through the self-call `selfExecutePrePulled`, which only the Router itself may call (`Router:540`, `Router:547-553`) |

Two further facts about the entry points. The native entry delivers the wrapped-native token to the
recipient; native output is not implemented (`Router:463-464`). There is no dedicated EIP-7702 entry
point: under 7702 the account delegates code to itself, `msg.sender` is still that account, and
`swapExactIn` is the call to make (`Router:444-449`).

## 5. Step 3 - execution (`_execute`, `Router:973`)

All four entry points converge on one execution core.

1. **Bounds.** A route has at most `MAX_HOPS = 3` hops (`Router:144`, `Router:977`) and each hop has
   between one and `MAX_LEGS_PER_HOP = 5` legs (`Router:137`, `Router:1103`).
2. **Baselines.** The Router's balances of the input and output tokens at entry are recorded, so
   that only this swap's flows are paid out or refunded (`Router:982`, `Router:1006-1007`).
3. **Where the fee lands.** The protocol fee is 28 basis points (`Core:323`), split 30 and 70
   between two treasuries (`Router:131-136`, `Router:694-697`). It is charged on the input of the
   first hop whose input token is a registry bridge coin (`Router:1067-1071`, `Router:1159-1161`),
   or out of the output when a direct route ends in a bridge coin (`Router:1074`,
   `Router:1533-1543`). If no hop takes a bridge coin as input, every hop pays on its own measured
   input (`Router:1159`).
4. **Per hop.** Hops must chain: a hop's input token is the previous hop's output token, and the
   route's input token is not taken again (`Router:1125`). The leg inputs are rescaled to the
   balance the hop really holds (`Router:1164-1165`, `Router:1275`).
5. **Per leg.** A leg must trade the hop's own pair (`Router:1262`); legs without hooks run before
   legs with hooks, otherwise `RouterE(3)` (`Router:1222-1226`). `_execScaled` (`Router:1616`)
   dispatches on the venue kind:
   - reserve-based venues (V2 and Solidly-style) go to `_execPairAmt` (`Router:1656-1657`,
     `Router:1823`): the input is transferred to the venue, the amount that really arrived is
     read, the output is computed (V2: from the reserves; Solidly-style: from the venue's own
     quote function, `Router:1826`, `Router:1855-1858`), and the venue's `swap` is called;
   - concentrated-liquidity venues (V3-shaped) go to `_execV3Amt` (`Router:1658-1659`,
     `Router:1866`), which records a maximum input for the venue's callback and passes a price
     limit (`Router:1873-1879`);
   - V4 singleton venues go to `_execV4Amt` (`Router:1660-1661`, `Router:1883`) through the
     PoolManager unlock sequence;
   - any other kind reverts `RouterE(8)` (`Router:1662-1664`).
6. **Per-leg floor.** Each leg must deliver at least `LEG_FLOOR_BPS = 8,000` basis points of its
   bound (`Core:305`), measured as the change in the Router's balance of the output token
   (`Router:1667`, `Router:1766`). Failure reverts `RouterE(5)`.
7. **Per-hop floor.** The legs of a hop together must deliver at least the sum of their attested
   outputs minus the allowance of one average leg (`Router:1329-1338`).
8. **Sweep.** Unspent input and intermediate tokens produced by this swap go back to the payer
   (`Router:1394-1406`).

## 6. Step 4 - the delivered-amount check

1. The total received is the change in the Router's output-token balance since entry; zero reverts
   `RouterE(8)` (`Router:1415-1417`).
2. The effective minimum is the strictest of three numbers (`Router:1480`, `Router:1507`,
   `Router:1515`):
   - `userMinOut`, the caller's absolute amount in output-token units;
   - `route.singleOutFloor`, which is dropped for this swap if a fee-on-transfer token was observed
     during execution (`Router:1504-1507`);
   - the protocol floor: the in-frame quote of the final hop times a floor in basis points that is
     derived on chain from the measured impact and the leg count, rounded up (`Router:1463`,
     `Router:1479`). It is recomputed on chain and is not read from the route (`Router:1419-1424`).
3. `amountOut < effMin` reverts `RouterE(5)` (`Router:1516`).
4. When the fee comes out of the output, it is paid here and the net amount continues
   (`Router:1533-1543`).
5. The recipient is paid and its balance change is measured (`Router:1550-1552`).
6. `delivered < userMinOut` reverts `RouterE(5)`, so the caller's minimum is enforced on what the
   recipient actually received (`Router:1556`).
7. The fee ledger is checked: a delivery that paid no fee reverts `RouterE(15)`, and on an anchored
   route a second payment reverts `RouterE(16)` (`Router:1561-1567`).
8. The function returns `delivered` (`Router:1569`, `Router:1592`).

## 7. Step 5 - events and registry feedback

| Output | Where | Content |
|---|---|---|
| `Swap(user, tokenIn, tokenOut, amountIn, amountOut, legs)` | declared `Router:223`, emitted `Router:1590` | `user` is the payer; `amountOut` is the delivered amount |
| `ExecutionProof(user, tokenOut, quoted, realized, floorUsed, blockNumber)` | declared `Router:252`, emitted `Router:1591` | the in-frame reference quote, the delivered amount, the floor that had to be beaten, and the block |
| `Fee(token, amount, toT1, toT2)` | declared `Router:256`, emitted in `_payFee` at `Router:698` | one event per fee payment |
| `Hub.recordSwap` per executed leg | `_recordHits` (`Router:1570`, `Router:2111`) | reported only after every floor has passed; wrapped in `try/catch`, so a registry failure does not revert the swap (`Router:2170-2173`) |

## 8. Revert codes

`RouterE(code)` is the Router's single error (`Router:263`). The codes are listed at
`Router:264-270`:

| Code | Meaning |
|---|---|
| 1 | unauthorized |
| 2 | paused |
| 3 | bad input |
| 4 | deadline |
| 5 | slippage |
| 6 | callback authorization |
| 7 | reentrancy |
| 8 | swap failed |
| 9 | disallowed V4 hook |
| 10 | `userMinOut == 0` with `amountIn > 0` |
| 11 | a V4 leg's fields disagree with its key |
| 13 | fee-on-transfer token on a V3-only route |
| 14 | rescue not queued or still inside the 48 hour timelock |
| 15 | a swap settled without paying the protocol fee |
| 16 | the fee was paid twice on an anchored route |

## 9. Where block time and chain state enter

Everything below is read inside the swap transaction itself.

| Input | Fixed when | Read when |
|---|---|---|
| `deadline` | in the calldata | at execution, against `block.timestamp` (`Router:563`, `Router:591`) |
| `userMinOut` | in the calldata, as an absolute amount | at execution, twice: inside the effective minimum (`Router:1480`, `Router:1516`) and against the recipient's measured receipt (`Router:1556`) |
| The route: venues, leg inputs, attested outputs | in the calldata for `swapExactIn`, `swapExactInWithPermit2` and `swapExactInNative`; computed in the transaction for `swapBestExactIn` (`Router:512`) | at execution |
| Venue state: reserves, price, liquidity | never fixed | at execution; for example the reserves at `Router:1826`, the concentrated-liquidity swap at `Router:1877` |
| The in-frame quote behind the protocol floor | never fixed | at execution, from venue state (`_hopScaleImpactAndQuote`, `Router:764`; used at `Router:1164-1165`) |
| The bridge-coin registry | Hub state | at execution (`Router:1069`, `Router:1074`) |
| The Permit2 signature | signed off chain by the token owner | at execution, by Permit2, with the owner argument set to `msg.sender` (`Router:422-426`); the permit struct has its own `deadline` field (`Router:83`) |

## Re-checking a statement

```bash
git clone https://github.com/blazephoenixxyz-crypto/Blaze-Phoenix-Dex.git
cd Blaze-Phoenix-Dex
git checkout d2cb3b385483e8f6cd1c0fe5bee76a94cf18a890
sed -n '380,397p'   src/BlazePhoenixRouter.sol   # swapExactIn and its shared entry checks
sed -n '1479,1516p' src/BlazePhoenixRouter.sol   # the protocol floor and the output check
sed -n '1550,1556p' src/BlazePhoenixRouter.sol   # the recipient's measured receipt and userMinOut
```

The Router's own comments in these ranges give the reasoning behind each rule; this document only
states what the code does and where.
