# Audit scope

This document orients an external reviewer / formal-verification engagement. It
maps the highest-risk surfaces, the trust model, the invariants already exercised
by the test battery (see `TESTING.md`), and what still needs proof rather than
fuzzing. It is a guide, **not** an assurance — nothing here has been audited.

## In scope

| Contract | Role |
|---|---|
| `src/BlazePhoenixRouter.sol` | Swap execution, fee/floor enforcement, AMM callbacks (V3 fallback, V4 unlock/flash), reentrancy guard. **Highest risk.** |
| `src/BlazePhoenixHub.sol` | Pool/factory registry, role model, ossification, bridges, V4 registration. |
| `src/BlazePhoenixSolver.sol` | Off-chain-style route construction on-chain (quote/split). |
| `src/BlazePhoenixQuoter.sol` | View-only quoting. |
| `src/BlazePhoenixCore.sol` | Shared library: AMM math, floor derivation, safe transfers, codecs. |

## Architecture & trust model

- The **Router holds no funds at rest** — it pulls `amountIn`, executes the
  route, distributes output, and ends each swap with zero balance. (Enforced by
  the stateful invariant suites across single-leg / multi-hop / split shapes.)
- The **Router does not re-derive the route** — it executes the `Route` it is
  given. The Solver/Quoter are the route *source*; the Router is the *enforcer*.
  Protection therefore lives in the Router, not the route:
  - the protocol floor is recomputed on-chain from **measured** impact and the
    **realised** output (`ironFloorBps`), never read from caller-supplied route
    fields;
  - `userMinOut` is the user's own bound and can only tighten the floor;
  - fee base is clamped to the attested quote (surplus is fee-exempt) and floored
    at the protocol floor (a zero `totalOut` cannot evade the fee).
- **Callback authentication** is by committed counterparty held in transient
  storage for the duration of one swap; outside a swap every callback reverts.
- **Trusted-by-design (verify these assumptions):**
  - Registered factories/pools are bounded but not fully trusted — a V3-shaped
    pool's callback can only pull up to the current leg's budget (`maxAmt`).
  - For `h == 0` hops the Router spends `leg.amountIn` directly and does **not**
    sweep a remainder; a route whose legs under-sum the input strands the
    caller's *own* funds (self-harm, not a third-party exploit). The Solver is
    responsible for reconciling leg sums.
  - Admin powers are EOA-held until `renounceControl()` / a multisig is wired.

## Risk-ranked focus areas

1. **Fee / floor math** (`_execute` lines ~310–390; `Core.ironFloorBps`,
   `mulDiv`, `outV2/outV3/outSolidly`). Wants formal proof: floor is always a
   correct fraction of realised output; fee ≤ cap; no rounding path lets
   `delivered < effMin` slip through; fee-on-transfer branch cannot be abused to
   inflate or evade the fee. (Fuzz-covered by `RouterInvariants` P5/P6/P7.)
2. **V4 unlock / flash accounting** (`unlockCallback`, `_execV4Amt`:
   unlock→swap→sync→settle→take, BalanceDelta packing). Reentrancy and
   settle/take balance reconciliation under hostile hooks. `hookAltersDeltas`
   gate is unit-tested (`RouterExecGuards` E9) but the full settle path needs a
   fork/audit.
3. **V3 callback fallback** (`fallback`/`_v3Callback`): selector-agnostic
   amount parsing, `expected`/`maxAmt` transient checks. Unsolicited-call
   rejection is unit-tested (`RouterCallbackAuth` E6/E3); confirm no calldata
   layout bypasses the budget bound.
4. **Reentrancy guard** (`nrEntrant`, `TSLOT_LOCK`). Inner-call rejection is
   unit-tested (`RouterExecGuards` E7); confirm every external mutator is
   guarded and transient slots are cleared on all paths.
5. **Hub registry coherence** (`addFactory` kind/mode/initHash rules, CREATE2
   address derivation, `discoverFor`). A wrong `initHash` derives wrong pool
   addresses silently. (Fuzz-covered by `HubFuzz`.)
6. **Role model & ossification** (`onlyAdmin`/`onlyOperator`/`onlyControl`,
   `renounceControl`, bridge cap = 2). Confirm renounce truly freezes every
   control power and curator-only growth remains safe.

## Invariants

**Already exercised (see `TESTING.md`):**
- Router is pass-through (0 balance at rest) over random single-leg / multi-hop /
  split sequences; bridge intermediates and split remainders never stranded.
- Per-token conservation across all holders.
- Truthful reporting, `delivered ≥ userMinOut`, unreachable `minOut` reverts,
  fee ≤ cap, surplus fee-exempt, 30/70 split (`RouterInvariants` P1–P7, fork).
- Callback/reentrancy/hook guards (E3/E6/E7/E9).

**Recommended to *prove* (not just fuzz):**
- `delivered ≥ effMin` holds for all inputs incl. adversarial rounding.
- Fee base monotonic in realised output and bounded by the attested quote.
- V4 settle/take leaves no protocol-owed delta and no token retained.
- CREATE2 pool-address derivation matches the canonical formula per registered
  factory mode.

## Observed during fork testing (leads, not confirmed bugs)

- **Single-tick concentrated-liquidity quote diverges on tick-crossing swaps
  (V3 and V4).** Both the V3 (`KIND_V3`) and V4 (`KIND_V4`, ~line 777) quotes use
  the **current-tick** `outV3` formula, which ignores tick crossing (V4 also
  ignores hooks); the comment states the iron floor is the intended backstop.
  This bites any large swap, not just V4 — e.g. `DEGEN→cbETH` at 1e24 (all V3,
  multi-hop) realises below its floor and reverts `RouterE(5)`. On a Base fork it
  also shows on the V4 pairs:
  `WETH→USDC` realised ~21% **above** quote (`realized/quote ≈ 12096 bps`), while
  the reverse `USDC→WETH` (same pools, V4 leg present) realised **below** the
  protocol floor and reverted `RouterE(5)`. Large exotic V3 multi-hops
  (`DEGEN→cbETH` at size) hit the same floor. **The floor backstop is working as
  designed** — but two practical consequences deserve review:
  (1) affected V4 pairs/sizes get **failed swaps** (the floor rejects a real
  fill), hurting UX; (2) a quote off by ~20% can make the **Solver mis-weight V4
  vs other venues**, degrading split quality. Consider a tick-aware quote (e.g. a
  `QuoterV4` staticcall) for the V4 leg. Lead for focus area #2. The fork metrics
  harness now logs `FLOOR-REJECTED` instead of aborting, so the report still
  surfaces the per-pair numbers.

  An expanded Base run (~20 pairs/sizes) sharpens this: the divergence is **not
  limited to exotics**. Even `USDC→DAI` ($500k) and `USDC→USDbC` ($250k)
  floor-rejected, and `VIRTUAL→USDC` realised only `9299 bps` (−7%). Meanwhile
  every Solidly-routed leg and every small/whale WETH-pair fill landed at
  `≈10000 bps`. So the gap tracks **single-tick concentrated-liquidity legs at
  size**, exactly as the `outV3` approximation predicts — a tick-aware quote
  would tighten routing quality across V3 *and* V4, not just avoid failed swaps.

  Note on interpretation: the realised slippage on these large fills is **normal
  for the pool depth** — moving $500k through a concentrated pool genuinely
  moves price. The issue is only that the single-tick quote does not *predict*
  that slippage, so the quote↔fill gap trips the floor. This is a
  routing-quality / UX limitation, **not** abnormal execution and **not** a
  safety defect — the floor protecting the user is the correct outcome.

## Known limitations (by design, v1.0)

- **Curve / Stable adapters are disabled** at registration (`Hub.addFactory`
  rejects `KIND_STABLE` / `KIND_CURVE`). Re-enable + review in v1.1.
- Admin is a single key until multisig/timelock or `renounceControl`.
- Deploy scripts (`script/Deploy*.s.sol`) are local-only and not version
  controlled; their hard-coded venue addresses/`initHash` are verified manually.

## Out of scope

- The local deploy scripts and the fork-metrics harness (`test/fork/*`,
  `script/*`) — tooling, not protocol code.
- Off-chain infrastructure and front-ends.

## Running the tests

See `TESTING.md`. Offline suite: `forge test`. Fork suites need per-chain RPC
env vars and skip when unset.
