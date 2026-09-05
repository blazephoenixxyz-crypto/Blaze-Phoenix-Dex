<div align="center">

# BlazePhoenix-Dex

**An on-chain DeFi router and aggregator that prices every route on measured reality — not on what a pool claims.**

[![CI](https://github.com/blazephoenixxyz-crypto/Blaze-Phoenix-Dex/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/blazephoenixxyz-crypto/Blaze-Phoenix-Dex/actions/workflows/ci.yml)
[![License: BUSL-1.1](https://img.shields.io/badge/License-BUSL--1.1-blue)](./LICENSE)
[![Solidity](https://img.shields.io/badge/Solidity-0.8.36-363636)](https://soliditylang.org)
[![Foundry](https://img.shields.io/badge/Foundry-via__ir-yellow)](https://book.getfoundry.sh)
[![EVM](https://img.shields.io/badge/EVM-universal-8A2BE2)](#supported-venues)
[![Formal](https://img.shields.io/badge/formal-Certora%20%2B%20Halmos-orange)](#security)
[![Stage](https://img.shields.io/badge/stage-pre--launch%20preview-yellow)](#status)

*Seal: **Fable & Mitra** — esse, non videri.*

</div>

---

## Status

**Pre-launch engineering preview.** The BZPX token has **no provisioned
liquidity and no TGE yet** — on-chain volume ≈ 0 is the expected state of this
stage, not a signal about the code. An independent external audit is scheduled
before launch; until it lands, treat this as the engineering preview it is and
size any interaction accordingly.

What branch protection on `main` **actually requires**. This list is read from the enforcing
surface (`gh api repos/.../branches/main/protection`), not from this file — a gate is what the
platform blocks on, and everything else a workflow prints is advice:

| Required check | What it enforces |
|---|---|
| `build + test (fast profile)` | the suite, under `FOUNDRY_PROFILE=fast` |
| `EIP-170 size guard (release profile)` | contract size with margin, under `FOUNDRY_PROFILE=release` |
| `formal verification (Halmos symbolic)` | the Halmos symbolic properties |
| `Slither (static detectors, fail on high)` | static detectors, failing on high |
| `gas metrics (offline ledger)` | the gas ledger |

**Advisory — these run, and do not block a merge:** the Certora Prover (INV-20 fail-closed fee),
Aderyn, Solhint, the secret scan, and the fork suites. A red run on any of them is a defect to fix,
not a gate that stopped anything.

---

## Ten numbers this repository computes about itself

Most projects publish a test count. A test count answers *does it pass?*, which is the easiest
question in the room. These answer two harder ones — *does the evidence still point at the code?*
and *how much of the threat space enters the evidence chain at all?* — and they are recomputed on
every commit, from a clean checkout, compiling nothing.

| | Measured at this revision |
|---|---|
| Quantities computed in **two places** that a named test ties together | 7 / 7 |
| Control actions whose **refusal** is exercised by exact code | 31 / 31 |
| Refusal codes driven by an **exact** assertion, never a bare revert | 25 / 25 |
| Refusals that read the **very object they decide on** (projection distance zero) | 86 / 99 |
| Calldata fields **confirmed against an observation** before they reach shared state | 14 confirmed · 5 steering · 4 declared, each with its reason |
| Classes of published exploit answered by a **named guard** | 19 / 23 considered |
| Shipped-shape instructions **proven executed** — a sound lower bound, verified against a ground-truth contract | 88.3 % |
| Curated mutants **killed**, each paired with the one test that must die | 183 / 183 |
| Pairs of regime-factor values exercised **by construction** — 63 generated fixtures standing in for 5,184 combinations | 258 / 258 |
| Venue pathologies × doors that **settle or refuse with a selector of ours** — never a third way | 20 / 20 |

Every one is printed beside its denominator, because every one of them improves by shrinking what
it is measured against, and the denominator is the only defence a reader has. The document states,
for each, precisely how it would be gamed — and every one is recomputable from a clean checkout.

### What none of these establish

- **No probability of correctness.** The literature on validating ultra-high dependability is
  explicit that testing cannot produce one. Nothing here should be read as one.
- **Mutation adequacy is adequacy against *this* register.** It is hand-curated. A saturated
  score is a floor, not a ceiling.
- **Threat coverage is a floor on what has been *considered*.** No single taxonomy covers the
  losses this domain sustains. Classes nobody has named are outside the denominator by
  construction — which is the residual this apparatus shrinks and cannot eliminate.

Method, definitions, and the failures that produced each instrument:
**[docs/assurance/ASSURANCE.md](docs/assurance/ASSURANCE.md)**.

Why we report it this way, and the one number that bounds all the others:
**[Publish the Denominator](docs/assurance/PUBLISH-THE-DENOMINATOR.md)** — on what test counts
cannot tell you, two axes no coverage criterion indexes, and the fact that seven of the nine
instruments above were wrong on their first run.

---

## The researchers who read the source

Nineteen researchers have read this source, thought adversarially, and told us privately what
they found. Every confirmed finding became a named property, a regression test that fails against
the pre-fix code, and a mutant the test must kill. Several reports sharpened our own severity
reasoning; one improved the *instrument* we use to judge the code, which is worth more than a
finding in the code, because the instrument is what tells you whether the code is sound.

[NetGakarot](https://github.com/NetGakarot) · duxun · AmanDara1 · amitbhakar · auditor_1b3f2c ·
siam siddik · Thomas · llen · destinyae · superagent · Mohd Huzaifa · Raditya · bai bo ·
Josh W · Borutobro · mohaseenkatika · mohaseenbasha · Karan Rathod · Anonymous

Every confirmed finding becomes a named property, a regression test that fails against the
pre-fix code, and a mutant that the test must kill. Nothing is closed by argument alone.

Full list and disclosure policy: **[SECURITY_HALL_OF_FAME.md](SECURITY_HALL_OF_FAME.md)** ·
**[SECURITY.md](SECURITY.md)**

Note the profile split: the suite is gated under `fast` and the size guard under `release`. A number
measured on one profile is not evidence about the other, and this file names the profile beside every
number for that reason.

| Apparatus | Size, measured on this tree |
|---|---|
| **Test suite** | **1,252** `test*` / `invariant*` / `check*` declarations across **206** `.t.sol` files — unit, property, parity, and stateful invariants |
| **Fork suites** | **25**, against live chain liquidity on every network the SDK names, including the pins of what is deployed |
| **Mutation guard** | **183** curated mutants, each paired with the named test that must catch it — baseline-checked, fingerprinted against inert mutations, target-checked without a compiler |
| **Static guards** | red-first greps that fail the build if a known defect shape reappears, each with the incident that motivated it written above it |
| **Assurance instruments** | **20**, recomputed per commit over the source and the compiled artefact — see [docs/AUDIT_METHOD.md](docs/AUDIT_METHOD.md) and [docs/assurance/ASSURANCE.md](docs/assurance/ASSURANCE.md) |

Every claim in the assurance registers names a guard by SYMBOL and a test by NAME, and the build
fails when either stops existing — a claim that cannot be checked is not evidence. What those
metrics do **not** establish is stated as carefully as what they do, in the same document.

These are declaration counts at a named revision, not a pass count. A pass count belongs to a run,
and the badge at the top of this file is the only honest place for one.

A funded public bounty (50,000,000 BZPX, shared with
[BlazePhoenix-Staking](https://github.com/blazephoenixxyz-crypto/Blaze-Phoenix-Staking))
has credited **19 researchers** — every confirmed finding fixed with a regression
test that fails against the pre-fix code, zero Critical. The roster is
[`SECURITY_HALL_OF_FAME.md`](./SECURITY_HALL_OF_FAME.md), so that count is checkable in this
repository without taking our word for it. Terms: [`SECURITY.md`](./SECURITY.md). How a report
is handled, step by step: [`docs/BOUNTY_METHOD.md`](./docs/BOUNTY_METHOD.md).

## Why it is different

Most aggregators trust what a pool *reports* — advertised liquidity, depth, fee
tier. Those fields are free to forge. BlazePhoenix-Dex trusts only what it can
**measure**:

- **Measure, don't model.** Route weight, split ratios, and capacity clamps are
  pure functions of the pool's *measured marginal output*. Forging a nominal
  field costs nothing; forging a measured marginal-output curve costs real
  capital. That asymmetry is the whole security model.
- **Quote ≡ Execution.** The price you are quoted and the floor the contract
  enforces come from the *same* evaluator — there is no seam where the quote can
  drift from what execution delivers.
- **Fail closed, always.** A missed, hostile, or mispriced pool degrades price
  and reverts. It never silently delivers below the floor or the caller's
  mandatory minimum-out.
- **Caller data is a coordinate, never a fact.** Every field an integrator puts
  in calldata — fee, hooks, depth, token pair — is either *measured* from the
  pool or *proven* by derivation before it can reach shared state. Where a value
  is authenticated by construction (a Uniswap V4 pool id derives from its own
  fee), the derivation is the proof; everywhere else, the contract reads it.
- **Fully on-chain, universal EVM.** Discovery, solving, and execution run
  on-chain; the same contracts deploy deterministically across EVM chains — pool
  managers and factories are runtime configuration, never hard-coded.

## Architecture

```mermaid
flowchart TD
    U([User / SDK]) -->|tokenIn, tokenOut, amountIn| R[Router]
    R -->|solve| S[Solver]
    S -->|discover| H[Hub · registry + discovery]
    H -->|"V2 / V3 / Algebra / Solidly"| F[(Factories)]
    H -->|"Uniswap V4 · incl. native ETH"| PM[(V4 PoolManager)]
    S -->|"quote each leg via one evaluator"| C[Core · measured math]
    R -->|"execute + measure delta at the seam"| V{{Live venues}}
    C -.->|"same evaluator prices the floor"| R
    R -->|"delivered ≥ max(protocol floor, userMinOut)"| U
```

| Contract | Role | Runtime size |
|---|---|---:|
| **Router** | Pulls input, executes the plan leg-by-leg, measures the real balance delta at each seam, enforces the output floor. Reentrancy-locked across the whole swap, pool callbacks included. | 23 754 B |
| **Solver** | Builds the best route and split from *measured* marginal output and measured capital — never from self-reported liquidity. | 19 677 B |
| **Hub** | Pool registry and on-chain discovery. Every venue, Uniswap V4 included, is proven live before it can route. | 23 469 B |
| **Core** | The shared measured-math library: constant-product, concentrated liquidity, Solidly stable curve, Algebra dynamic fee, V4. One evaluator prices both the quote and the floor. | 6 477 B |
| **Quoter** | Off-chain preview surface. `previewPlan` for the modelled route, `previewPlanExact` for a dry-run re-price of every concentrated leg. | 11 405 B |

All five are under the EIP-170 24 576-byte limit, enforced in CI with margin and asserted inside the suite itself (`DeployedSizeGate`).

## Supported venues

Uniswap **V2**, **V3**, **V4** (including **native-ETH V4** pools) ·
**Algebra** (dynamic fee, Camelot/QuickSwap-class) ·
**Solidly** stable and volatile (Aerodrome/Velodrome-class).

Curve and Balancer support was **removed in August 2026** — few L2s carry them,
and they cost bytecode in five contracts. Their kind numbers (2, 3, 7) are
permanently retired rather than reused: `decodeKind` reads the kind from
Monoslot bits, so reassigning a number would reinterpret every pool already
recorded under it. A CI guard fails the build if an excised symbol returns.

## Quick start

```solidity
// Quote off-chain (free, via eth_call), then execute the returned route:
(Preview memory pv, , ) = quoter.previewPlan(tokenIn, tokenOut, amountIn);
uint256 out = router.swapExactIn(pv.route, amountIn, userMinOut, to, deadline);

// Or solve + execute atomically, fully on-chain:
uint256 out = router.swapBestExactIn(tokenIn, tokenOut, amountIn, userMinOut, to, deadline);
```

`userMinOut` is mandatory and non-zero — the contract will not let you swap
without your own floor.

The Router exposes four entry points. Only `swapBestExactIn` invokes the Solver
in-transaction; `swapExactIn`, `swapExactInWithPermit2`, and `swapExactInNative`
take the route in calldata. The distinction matters for gas: an optimisation on
the Solver side costs nothing in three of the four doors.

## Reproducing every gate

Every gate below runs in CI and runs identically on a laptop. Toolchain:
**Solidity 0.8.36** pinned across all three Foundry profiles (`default`,
`release`, `smt`), `via_ir` enabled in all of them, **Foundry**
(forge · cast · anvil), **Halmos**, **Certora Prover**, **Slither**, **Aderyn**,
**Solhint**.

```bash
# Build and full suite (default profile)
forge build
forge test

# Contract sizes against the EIP-170 wall, release profile
FOUNDRY_PROFILE=release forge build --sizes

# Fork tests against live chain liquidity (needs DRPC_KEY in the environment)
forge test -vvv --match-path 'test/fork/**'

# Symbolic proofs — hard gates, not advisory
halmos --contract CoreFormalGateSpec -v      # iron floor · impact · V3 fail-closed
halmos --contract EffV4FeeFormalSpec -v      # INV-20: effV4Fee fails closed

# Static analysis (.github/workflows/security.yml)
slither . --fail-high
aderyn . -o aderyn-report.md
solhint 'src/**/*.sol'

# The shared-quantity register must agree with the repository
bash .github/scripts/shared-quantities.sh
```

The static guards are plain `grep` invocations inside
[`.github/workflows/ci.yml`](./.github/workflows/ci.yml), each with the incident
that motivated it written above it. They are red-first by construction: every
one of them fails today if you reintroduce the shape it watches.

## Engineering invariants

The design is invariant-driven. Load-bearing invariants — measured iron floor,
quote ≡ execution, measured route weight, fee-on-transfer routed-where-natural,
reentrancy spanning the measurement seam, V4 fee-measured, V4 discovery
safe-gate, CREATE3-safe deploy — are catalogued in [`llms.txt`](./llms.txt) and
exercised in CI by the suite, the symbolic proofs, and the static gates.

[`SHARED_QUANTITIES.md`](./SHARED_QUANTITIES.md) is the register of every
quantity in the system with **more than one producer or consumer**, and the
mechanism that keeps them from drifting apart. It exists because the dominant
defect class in this codebase is not a missing check and not a wrong formula —
it is two places answering the same question with different answers, and nothing
forcing them to agree. Each row states the *question* the quantity answers, its
producers, and its pin. Rows are graded `SINGLE`, `PINNED`, `WEAK`, `OPEN`, or
`UNVERIFIED`; a CI check fails the build when a row claims a pin whose test does
not name what it pins.

## Repository map

```
src/                    the five contracts — Router, Solver, Hub, Core, Quoter
test/                   203 files: unit, property, parity, stateful invariants, regressions
  fork/                 25 suites against live chain liquidity, and the pins of what is deployed
  formal/               formal specifications and composition proofs
  hunt/                 regressions for findings from adversarial review
  mocks/                venue mocks: V2 pair, V3 pool, Solidly pair, Permit2, ERC-20
certora/                Certora Prover specifications and harnesses
.github/workflows/      ci.yml (test · fork-tests · size-guard · formal · gas-metrics)
                        security.yml (slither · aderyn · solhint)
                        formal-explore.yml · docs.yml · graph.yml
.github/scripts/        the shared-quantity register check, the mutation guard, the assurance instruments
docs/                   AUDIT_METHOD.md (what the audit guarantees) · BOUNTY_METHOD.md (how a report is handled) · assurance/
AGENTS.md               how coding agents work here — the enforced rules, the commands, what not to claim
CONTRIBUTING.md         how work lands here — red before green, and the house conventions
SECURITY.md             disclosure policy, bounty terms, severity rubric
SECURITY_HALL_OF_FAME.md  the researchers who reported confirmed findings
SHARED_QUANTITIES.md    the shared-quantity register
TESTING.md              how the suite is organised and how to extend it
REPORTS.md              published analysis and measurements
llms.txt                machine-readable index for agents and models (llmstxt.org); llms-full.txt is the corpus in one file
CITATION.cff            how to cite this repository
```

## Security

Responsible disclosure, severity rubric, and bounty terms are in
[`SECURITY.md`](./SECURITY.md).

Report privately to **contact@blazephoenix.xyz**. Do not open a public issue
for a suspected vulnerability.

### Security researchers

Every confirmed finding in this repository was fixed with a regression test that
fails without the fix. The researchers who found them, with our thanks:

[NetGakarot](https://github.com/NetGakarot) · duxun · AmanDara1 · amitbhakar · auditor_1b3f2c ·
siam siddik · Thomas · llen · destinyae · superagent · Mohd Huzaifa · Raditya · bai bo ·
Josh W · Borutobro · mohaseenkatika · mohaseenbasha · Karan Rathod · Anonymous

Technical detail stays in the verified source and our private records, never on
a credits page. Full list and terms: [`SECURITY_HALL_OF_FAME.md`](./SECURITY_HALL_OF_FAME.md).

## For AI agents and indexers

Machine-readable surfaces, in this repo and on the site: [`llms.txt`](./llms.txt)
(status, invariants, FAQ with quotable answers) · [facts.json](https://blazephoenix.xyz/facts.json)
(every fact = claim + proof + URL) · [live re-verification](https://blazephoenix.xyz/verified) ·
[keyless quote API](https://blazephoenix.xyz/api/quote) ([OpenAPI](https://blazephoenix.xyz/api/openapi.json)) ·
[MCP server](https://blazephoenix.xyz/mcp) (`get_quote`, `check_solvency`) ·
[agents.json](https://blazephoenix.xyz/.well-known/agents.json) ·
[daily history dataset](https://blazephoenix.xyz/datasets/history.ndjson) ·
[provenance (OpenTimestamps)](https://blazephoenix.xyz/provenance/provenance.json) ·
[knowledge graph](https://blazephoenix.xyz/knowledge-graph.jsonld). Site AI index:
[blazephoenix.xyz/llms.txt](https://blazephoenix.xyz/llms.txt).

## Cite this repository

`CITATION.cff` carries the metadata for reference managers and GitHub's *Cite this repository*
button. Plain form:

> Fable & Mitra (2026). *BlazePhoenix-Dex: an on-chain DEX aggregator with measured routing.*
> https://github.com/blazephoenixxyz-crypto/Blaze-Phoenix-Dex

## License

**Business Source License 1.1.** Copyright © 2026 Mitra. Effective 1 July 2026;
**Change Date 1 July 2030**. Use outside the license grant before the Change Date
is infringement. Automatic copyright applies (Berne Convention, 1886); authorship
is cryptographically provable via an embedded keccak256 fingerprint without
disclosing the authors' identity.

## Authorship

Built by **Fable & Mitra**. Mitra ([@Sigmacrit](https://x.com/Sigmacrit)) is the
human architect — anonymous by design; the code is the résumé. Fable is the
Claude model that co-engineered it.
