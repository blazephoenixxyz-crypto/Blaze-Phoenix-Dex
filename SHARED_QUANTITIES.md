# Shared-Quantity Register

> Every quantity in this system that has **more than one producer or more than one consumer**,
> and the mechanism that keeps them from drifting apart.

## Why this file exists

Across the security reviews of this codebase, the dominant defect class is not a missing check and
not a wrong formula. It is **two places answering the same question with different answers, and
nothing forcing them to agree**.

In the 2026-08-23 review, of the findings that survived verification:

| Class | Count | Examples |
|---|---:|---|
| Two producers of one quantity, no pin | 7 | leg tokens vs hop pair; Solver floor vs Router floor; snapshot `bridged` bit vs live predicate |
| Unproven calldata reaching shared state | 3 | registry `fee`, registry `hooks`, self-reported depth |
| Everything else | 0 | — |

A type system cannot catch the first class: both sides are legitimately measured, they just
disagree. What catches it is enumeration. This file is that enumeration.

**The rule.** A quantity with more than one producer must either

- **(a)** collapse to a single producer, with a CI guard forbidding copies, or
- **(b)** keep its producers and carry a named test that asserts they agree.

A row here records which, and — when the answer is "neither" — says so out loud.

## How to read the Status column

| Status | Meaning |
|---|---|
| `SINGLE` | Collapsed to one producer. A CI guard fails the build if a copy reappears. |
| `PINNED` | Multiple producers, and a named test asserts agreement. The test **names the quantity**. |
| `WEAK` | A pin exists but does not fully bind: it is tolerance-based, or it pins a neighbouring primitive rather than the one actually consumed. Known escapes are listed. |
| `OPEN` | No pin. Carries the finding id when one exists. |
| `UNVERIFIED` | Listed because the code shows multiple consumers; the pin has not been confirmed by reading. Treat as `OPEN` until someone checks. |

A `WEAK` row is more dangerous than an `OPEN` one. `OPEN` is a known hole. `WEAK` is a hole with a
green test in front of it.

---

## The register

### Floors and fees

| Quantity | The question it answers | Producers / consumers | Status | Pin |
|---|---|---|---|---|
| `LEG_FLOOR_BPS` | "How much may a single leg legitimately lose?" | `Core` (definition), `Router` ×8 | `UNVERIFIED` | **Downgraded 2026-09-04.** The row cited `test/formal/CompositionFormalSpec.t.sol`, which **no runner executes**: `check_` is the Halmos prefix, `forge test` skips it, and no CI job names the contract. It also asserts over test-local reimplementations rather than `src/`, and models the leg floor with `mulDiv` where the live guard at `Router:1633` uses `mulDivUp` — wired up as written it would report the correct code as broken. No test in the corpus names this constant. |
| `PROTOCOL_FEE_BPS` | "How much does the protocol take?" | `Router._chargeHopFee` ×2, `Quoter._pack` ×1, `Quoter.previewPlanExact` ×1 (since 2026-09-03) | `WEAK` | `test/PreviewExecutionParity.t.sol` — behavioural, `assertApproxEqRel(…, 0.001e18)`; **does not name the constant**. `test/QuoterExactNetOut.t.sol` pins the exact pass: `exactOut` equals the view preview's after-fee figure to the wei, is a floor the Router honours, and its deduction is `_pack`'s (once, rounded up); mutants 154-155 |
| `effV2Fee` / `quoteV3Fee` | "What fee does this pool actually charge?" | `Core` only — all other sites call it | `SINGLE` | CI job *Fee producer guard*; `test/FeeProducersSingle.t.sol` names both |
| `ironFloorBps` **impact input** | "What is this route's price impact?" | `Solver` ×2 (`_assembleRoute`, `_assembleRouteMulti`), `Router` ×1 — the same aggregation since 2026-09-02: share-weighted per leg (`_wImp`), averaged over the route's total leg count, rounded up. PR #25 fixed the single-hop arm; the multi-hop arm followed the same evening after a review pass found it still summing unweighted per-hop means (and a comment asserting it was safe) | `PINNED` (fixed 2026-09-02) | `test/FloorParitySolverRouter.t.sol` — single-hop `singleOutFloor == floorUsed`, two-hop floor **rate** parity (hop-1 fee shifts the base); mutants 88-89 and 98-99 in `mutants.py` (was finding **FLOOR-01**) |

**`PROTOCOL_FEE_BPS` — the escapes.** The pin compares realised delivery against predicted `netOut`
within 0.1 %. The protocol fee is 28 bps, so a missing deduction *would* break that tolerance — but
only on the routes the test builds, which all have a bridge token in a hop input (the **anchored**
fee regime). Two regimes escape it:

- **FEE-01** — in the *exhaustion* regime (multi-hop route with no bridge token in any hop input) the
  Router charges on **every** hop while the Quoter models a single deduction. Measured: 2.80e18 in
  `tA` **and** 2.78e18 in `tB` against the 28 bps promised — ~56 bps on an honest route.
- **FEE-02** — **closed 2026-09-03.** `Quoter.previewPlanExact` contained no `PROTOCOL_FEE_BPS` term at
  all, yet its own docstring called the result *execution-grade* and the Router's docstring told
  integrators to derive `userMinOut` from it: delivery was exactly the fee below it on every route,
  so a buffer under 28 bps was refused by the floor guard. Reported with a PoC in the eighth
  disclosure round. Fixed by one deduction on the returned scalar (the `route` keeps its gross
  pool-math attestation, which is what the Router compares against); pinned by
  `test/QuoterExactNetOut.t.sol` and mutants 154-155.

**`ironFloorBps` — the divergence.** `Solver._assembleRouteMulti` averages impact **per hop** and
then **sums the hops**; `Router._execute` sums every leg and divides by the **global** leg count.
Both call `ironFloorBps` with the same `totalLegs`. On a 2-hop route at ~100 bps per hop the Solver
promises a 92 % floor and the Router enforces 93 % — a legitimate fill at 92.5 % satisfies the
published plan and dies on `RouterE(5)`. The gap is exactly `(H − 1) × mean impact` and grows with
hop count.

### Registry state (the Monoslot)

| Quantity | The question | Producers / consumers | Status | Pin |
|---|---|---|---|---|
| registry `fee` | "What fee should the planner assume for this pool?" | written by `Hub._register`, read by `Hub._readPoolInfo` → Solver/Quoter | `SINGLE` (fixed 2026-08-23) | measured at the registration door; V4 keeps the calldata value because the pool id **authenticates** it |
| registry `hooks` | "Does this pool have a hook?" | same | `SINGLE` (fixed 2026-08-23) | forced to `address(0)`: every path reaching that door has proven hooklessness |
| `depthWad` (via `depthFromL18`) | "How deep is this pool?" | `Core` ×2, `Hub` ×1, `Router` ×3 | `WEAK` | CI job *Depth producer guard* covers the **source** (never calldata); `test/DepthUnitParity.t.sol` covers the **units** — but it exercises `depthFromL`, the inner primitive, **not** `depthFromL18`, which is where decimal normalisation lives and where a defect has already escaped once |
| `bridged` (Monoslot bit 7) | "Is this pool anchored on a routable bridge?" | written frozen at registration (`Hub._register`), read live by `_psiOfSlot` — and the **live** predicate `_isRoutableBridge` answers the same question elsewhere | `SINGLE` (fixed 2026-09-02) | `Hub._pairBridged` is the only producer: read live at every psi site (`getPsi`, `psisOf`, `_canInsert`, `_register`), bit 7 no longer written. Pins: `test/FrozenAtWriteProbes.t.sol` `test_probe_bridgedBit_*` (both directions, red on the frozen bit: 6400 ≠ 5120 and 4096 ≠ 5120), mutants 93-94. CI guard: *Producer copy guard* forbids `_isBridged`. Was finding **BRIDGE-01**. Note: read live the bonus is uniform within a pair, so no within-pair ranking can turn on it — the frozen bit was the only way it ever reordered anything |
| `stable` | "Is this a stable-curve pool?" | the pool's own `stable()`, read once by `Core.solidlyStable` at the registration door (`Hub._register`) into Monoslot **bit 5**; `_readPoolInfo` reads the bit; the factory-derived path keeps the factory's value | `SINGLE` (fixed 2026-09-02) | Pins: `test/FrozenAtWriteProbes.t.sol` `test_probe_stableField_*` (registry field, and the fallback curve at −0.99 % on the frozen `false`), mutants 95-96. CI guard: *Producer copy guard* forbids `p.stable = false`. Was finding **SLOT-01**. Blast radius was the replicated-curve fallback and the impact model only — every quote channel asks `getAmountOut` first (`test_control_stableField_standardPoolIsPricedByItsOwnGetter`) |
| pool depth **source** | "Who says how deep this pool is?" | `Router._recordHits` reads `getReserves` from the pool — an adversary-controlled contract for a synthetic pair | `WEAK` (capped 2026-09-02) | declared reserves are capped by physical holdings at both producers: `Solver` (probe loop, `min(depth, to18(balsOut))`, no extra call) and `Router._v2Depth18` (per reserve, two staticcalls). Pin: `test/FrozenAtWriteProbes.t.sol` `test_probe_forgedMass_cannotCaptureTheRouteWithoutCapital` — a pair declaring 3e30 of reserves while holding 1 token of each captured the whole route at 1:0.5 against three funded honest pools (0 honest legs, red before the cap); mutant 97 kills the Solver cap. **Escape:** the Router copy of the cap has no test of its own yet — a forged pair still enters the registry through a self-swap, and only the cap keeps its bucket honest; until a Router-level probe exists, that half rests on reading, not on a red. Was finding **PROV-01**. `KINDS_PAIR_PROOF` still checks `token0()/token1()` only — the cap makes the proof unnecessary for mass, not for identity |

### Identity and keys

| Quantity | The question | Producers / consumers | Status | Pin |
|---|---|---|---|---|
| `computeV4PoolId` | "Which V4 pool is this leg talking about?" | `Core` (definition), `Hub` ×8, `Router` ×3 | `WEAK` | `test/V4NativeOrientation.t.sol` names it. But the three Router sites (`_v4LegQuote`, `_execV4Amt`, `_recordHits`) derive the id from **different coordinates** and agree "by construction of `zeroForOne`" — a claim with no differential test. Proposal **P-4** / invariant **I15** |
| `keyOf` | "What is this pool's registry key?" | `Hub` ×10, `Solver` ×3 | `UNVERIFIED` | pure function in the Hub, single definition — consumer parity not confirmed by reading |
| `KINDS_ROUTABLE` / `KINDS_EXECUTABLE` / `KINDS_PAIR_PROOF` | "Which kinds may enter / execute / must prove their pair?" | `Hub` — masks written out longhand, deliberately not derived from one another | `UNVERIFIED` | the longhand is intentional (deriving one from another once removed a kind from a gate with the parity test green); the pin was not confirmed |
| `hookAltersDeltas` bit map | "Does this hook return deltas?" | `Core` (definition), `Router` ×1, `Solver` ×3, `Quoter` ×1 | `PINNED` (bits) | `test/BlazePhoenixCore.t.sol:103-104` pins `1<<3` and `1<<2` by name. Consumer **parity** across the four call sites is untested |
| `MAX_BRIDGES` ↔ Solver arms | "How many bridges does the planner actually walk?" | `Hub` ×7, `Solver` ×2 | `WEAK` | the coupling is documented in `Hub:106-123` in prose; **DOC-01** found the prose describing a state that does not exist |
| `MAX_LEGS_PER_STAGE` (4) vs `MAX_LEGS_PER_HOP` (5) | "How many legs fit in one hop?" | `Solver:111` answers 4, `Router:133` answers 5 | `OPEN` | none — finding **PIN-01**. Harmless today because 4 < 5; no test references `MAX_LEGS_PER_HOP` |
| `MAX_HOPS` (3) | "How many hops fit in one route?" | `Router._execute` (the only door every entry point passes through); the Solver's deepest topology is `_planViaTwoBridges` (3) | `PINNED` (added 2026-09-02) | `test/RouteHopCeiling.t.sol` — a 61-hop route is refused, a 3-hop one still routes; mutant 103. PIN-01's missing sibling: until this row there was no producer at all, and `executedMask` past leg 255, the exhaustion-regime fee and `bridgeBase` were all bounded only by nobody sending long routes |
| Layer 2 scope (hookless before hooked) | "Over what span may no hookless leg follow a hooked one?" | `Router._execute` (the `sawHooked` flag) and `Solver._assembleRouteMulti` (refuses a hooked leg outside the last hop) | `PINNED` (widened 2026-09-02) | `test/CrossHopHookOrdering.t.sol` — a hooked leg in hop 0 before a hookless hop 1 is refused; a hook in the last hop still routes; mutant 104. The flag was declared inside the hop loop, so the rule closed the intra-hop vector and left the cross-hop one open while its own justification named the route |
| `Volume(key, amtIn, amtOut)` | "How much really went through this pool?" | emitted by `Hub.recordSwap` from the amounts the Router passes, which are `leg.amountIn` / `leg.expectedOut` — **calldata**, not measurements | `OPEN` | finding **VOL-01** (review 2026-09-02, red probe kept out of the tree): a leg declaring 1e30 executes at its real size and reports 1e30. Not an execution defect (nothing on-chain reads the amounts); a metrological one. The fix is carrying the measured per-leg (in, out) from `_execute` to `_recordHits`, in a frame via-IR already refuses to grow — decided later, not by accident |
| `v4EntryOf` (V4 row → V4Entry) | "Where is this V4 row's tickSpacing?" | written by every V4 door (`addV4`, `claimV4`, `recordSwap`, and since 2026-09-02 `seedPool`); read by `_readPoolInfo` and by `_recoverV4Ts` step 5 | `SINGLE` (fixed 2026-09-02) | `test/V4EntryScanUnbounded.t.sol` — reading one pool, and registering one, costs the same with 0 and 200 foreign entries; mutants 101-102. The two linear walks over `v4Entries` (a permissionlessly grown array) are gone |
| `factoryDeployer` (the attested Algebra origin) | "Which CREATE2 origin do this factory's mode-5 fee-0 probes derive from?" | written by `Hub.addFactory` from `Core.resolvePoolDeployer` at admission — and again at every re-admission, through a door that survives `renounceControl`; read by the mode-5 fee-0 derive in discovery | `PINNED` (fixed 2026-09-03) | After renunciation the attested origin is frozen, a dead resolver never demotes it to zero, and a non-mode-5 refresh of the row leaves it untouched; a live admin may still re-attest on purpose. Pins: `test/T19ReadmissionEdge.t.sol`, `test/T19AlgebraDeployerPin.t.sol`; mutants 67, 133, 143, 144. Was cluster **C4** of the 2026-09-03 closure pass: a pin against *time*, re-openable by the one lever renunciation keeps |
| `factories[]` row ↔ `factoryCodehash` / `factoryDeployer` (keyed by address) | "Is this factory already admitted, and which row is it?" | the array holds the rows, the mappings are keyed by address; `addFactory` pushed one row per call, so a single address could own several rows (and, with no `removeFactory`, exhaust the sixteen seats for ever) while its mappings held one value | `SINGLE` (fixed 2026-09-03) | `addFactory` scans the seats and refreshes a known address in place — after renunciation only if its code did not move, the twin of the `allowHook` guard. Pins: `test/RenouncedFactoryRearm.t.sol` (one row per address, one address cannot exhaust the table, a mutated factory cannot be re-armed after renunciation, a new factory is still admitted, a live admin may re-attest); mutants 140-142. Was cluster **C3** |

### Transient state

| Quantity | The question | Producers / consumers | Status | Pin |
|---|---|---|---|---|
| `TSLOT_FOT` | "Did this swap meet a fee-on-transfer token?" | `Router._noteFot` — leg loop, and (since 2026-08-23) the three input pulls | `SINGLE` (fixed) | the input pull previously never marked it, so a token taxing `transferFrom` but not `transfer` made `singleOutFloor` reject an honest swap — finding **FOT-01** |
| transient slot numbering | "Which slot holds what?" | `Router` — 8 constants, 17 materialisation sites | `SINGLE` | the Core performs no `tstore`/`tload`, which is what makes the namespace safe. If proposal **P-1** lands (literals `0..7`, −527 B, zero gas) this becomes a CI grep: `grep -c "tstore\|tload" src/BlazePhoenixCore.sol` must be `0` |

---

## Adding a row

Add one whenever you introduce a quantity that a second place will read or write. The row costs a
minute; the review that finds the drift costs a day, and the drift itself can cost more.

State the **question**, not the variable name. Two consumers of `fee` that ask *"what will this pool
charge?"* and *"what should I assume it charges?"* are asking different questions, and that is
precisely how they drift while looking identical in a grep.

## What the CI check enforces

`.github/scripts/shared-quantities.sh` parses the tables above and fails when:

1. a row claims `PINNED` but the test file it names does not exist;
2. a row claims `PINNED` but that test file never mentions the quantity;
3. a row claims `SINGLE` but the guard it names is absent from `.github/workflows/ci.yml`.

Rule 2 is not theoretical. It is what demoted two rows on the day this file was written:
`PROTOCOL_FEE_BPS` and `depthWad` both claimed pins that do not name what they pin — and both have
findings that walked straight through the gap.

The check deliberately does **not** try to discover new shared quantities automatically. That
requires reading the code and asking what question each consumer is asking, which is a human job —
and, in the 2026-08-23 review, doing exactly that enumeration by hand over one pass produced four
findings (**REG-01**, **FLOOR-01**, **PIN-01**, **BRIDGE-01**).
