# Testing

How the suite is organised, how to run every gate, and what a test has to satisfy before it
counts as evidence here. The method behind it is in [`docs/AUDIT_METHOD.md`](docs/AUDIT_METHOD.md).

Measured on this tree (2026-09-05): **206 `.t.sol` files** — 181 local, 25 fork — holding
**1,252 `test*` / `invariant*` / `check*` declarations**; **1,117 tests green** in the release
profile with fork suites excluded and **119 green on live liquidity**; **183 curated mutants**, all killed.

## Running

```bash
forge install                                   # first time only — pulls forge-std into lib/
forge build
forge test --no-match-path 'test/fork/*'        # unit, property, parity, stateful invariants
FOUNDRY_PROFILE=release forge test --no-match-path 'test/fork/*'   # the shipped binary

# Fork suites — live liquidity on every network foundry.toml names (needs DRPC_KEY)
forge test --match-path 'test/fork/*' -vv

# Contract sizes against the EIP-170 wall, and the in-suite size gate
FOUNDRY_PROFILE=release forge build --sizes
forge test --match-contract DeployedSizeGate

# The guards that judge the suite
python3 .github/scripts/check_targets.py        # every mutant still points at one line (1 s)
python3 .github/scripts/mutants.py              # the mutation guard, one mutant at a time
bash    .github/scripts/shared-quantities.sh    # the register must agree with the code
python3 .github/scripts/check_no_secrets.py     # nothing private in the tree

# Symbolic proofs
halmos --contract CoreFormalGateSpec -v
halmos --contract EffV4FeeFormalSpec -v
```

The suite and the size gate run under the **same optimiser profile**; `profile_parity.py`
asserts it. A number measured on one profile is not evidence about the other.

Invariant campaigns run at a modest depth by default (see `[invariant]` in `foundry.toml`); raise
`--invariant-runs` / `--invariant-depth` for a deeper search. Foundry persists a failing sequence
under `cache/invariant` and replays it on the next run — clear it when you change a handler, or a
stale sequence can be scored as a fresh result.

## How the suite is organised

| Where | What lives there |
|---|---|
| `test/*.t.sol` | unit, property and **parity** tests — one file per property or per finding, named for the property it pins |
| `test/*.invariant.t.sol` | stateful campaigns driven by handler contracts; every campaign counts its own non-vacuity (a witness that the interesting state was reached) |
| `test/fork/` | 25 suites against live liquidity: end-to-end swaps, discovery censuses per factory, preview-versus-execution parity, and the pins of what is deployed (`DeployedCodehashPin`, `DeployedParity`) |
| `test/formal/` | Halmos specifications for the fail-closed arithmetic (iron floor, impact, V3 fail-closed, `effV4Fee`) |
| `test/hunt/` | regressions from adversarial review campaigns |
| `test/regime/` | the **regime covering array** (`RegimeHarness.sol`, one fixture builder, one assertion; the generated `RegimeCoverage.t.sol` — 63 rows holding every pair of values of ten regime factors) and the **hostile-venue matrix** (`HostileVenues.sol`, `HostileVenueMatrix.t.sol` — ten venue pathologies × two doors under the same rule); `Outcomes.sol` is the one classifier of a refusal both use |
| `test/mocks/` | venue mocks — V2 pair, V3 pool, Solidly pair, V4 manager, Permit2, ERC-20 with every pathology (fee-on-transfer, no-return-data, return-false, rebasing, blocklisting, pausing, non-standard decimals) |

Three families of test do the load-bearing work:

- **Parity.** Two producers of one quantity — the Solver's attested floor and the Router's
  enforced floor, the Quoter's preview and the Router's delivery, the registry's volume and the
  pool's balance delta — asserted equal on the same block. These are the tests the shared-quantity
  register names.
- **Refusal, driven on the side that fires.** Every refusal code is asserted by its exact
  selector with a control one wei under the threshold, so the test can say *which* guard refused.
- **Probes.** For every finding in the register, a test whose fixture is the attack — forged
  reserves, a padded leg, an unlisted hook at the second door — asserting the effect that is no
  longer reachable, beside a positive control that shows the honest case still passes.

## What a test must satisfy here

Before a test is counted, it is read against one question: *what change to the contract would
make this fail?* Three things every test in the suite carries:

- **Red first.** A test that guards a fix was red against the code without the fix, and the
  header says at which commit.
- **An exact effect.** A refusal is asserted by its selector and code; a value by an oracle
  that is not the code under test.
- **The property as its name.** The test name is the sentence the property states, so a
  failure reads as a falsified claim.

## What the suite is measured by

- **The mutation guard** — 183 curated mutants, each paired with the one test that must die;
  baseline-checked, fingerprinted against inert mutations, target-checked without a compiler.
- **The MC/DC census** — every sub-condition of every compound decision neutralised one at a
  time and judged by whether a named test notices.
- **The executed-bytecode bound** — 88.3 % of the shipped-shape instruction stream proven
  executed, closure verified against a ground-truth contract.
- **The regime lattice** — which cells of regime × shape × oracle hold a cross-producer assertion.
- **The regime covering array** — every pair of factor values in a generated fixture; regenerate and read it with:

  ```bash
  python3 .github/scripts/assurance/covering_array.py --check
  forge test --match-contract RegimeCoverage -vv > regime.log; python3 .github/scripts/assurance/regime_summary.py regime.log
  ```
- **The sandwich curve** — `SandwichCurve.t.sol` plays the attacker across a grid of manipulations and asserts the floor's bound at every point; `forge test --match-contract SandwichCurve -vv` prints the curve.
- **The in-suite size gate** — every contract's deployed size asserted with a signed margin.
- **Release-binary execution** — `PcTraceProbe` records an opcode-level trace of real swaps
  through the release Router; `pc_trace.py` replays the program counter against the shipped
  artefacts, checking the opcode at every step, and reports which instructions ran:

  ```bash
  PC_TRACE=1 FOUNDRY_PROFILE=release forge test --match-contract PcTraceProbe -vvv
  python3 .github/scripts/assurance/pc_trace.py --check
  ```

## Extending the suite

1. Write the property as a sentence. That sentence is the test's name.
2. Build the fixture that reaches the regime the sentence is about, and assert that it did.
3. Write the test red against the current tree if it guards a change; record the commit in the
   header.
4. Make it green. Assert the effect by exact value or exact selector.
5. Add the mutant to `.github/scripts/mutants.py`, run `check_targets.py`, and run that mutant.
6. If the property ties two producers, add or update the row in `SHARED_QUANTITIES.md` and run
   `shared-quantities.sh`.

A pull request that adds a guard without steps 5 and 6 is not complete. Conventions and the
pre-PR checklist are in [`CONTRIBUTING.md`](CONTRIBUTING.md).
