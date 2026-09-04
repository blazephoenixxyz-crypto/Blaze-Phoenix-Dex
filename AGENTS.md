# AGENTS.md — how to work in this repository

This file is for coding agents and AI-assisted contributors. It is the short form of
[`CONTRIBUTING.md`](CONTRIBUTING.md), [`TESTING.md`](TESTING.md) and [`SECURITY.md`](SECURITY.md);
when they disagree, those files win. Machine-readable project context is in [`llms.txt`](llms.txt).

## What this repository is

An on-chain DEX aggregator for the EVM in Solidity 0.8.36 + Yul: `src/` holds five contracts
(Router, Solver, Hub, Core, Quoter), `test/` holds the suite, `.github/scripts/` holds the guards
that judge the suite. The design discipline is **metrological**: every quantity the contracts act on
is measured from the pool or proven by derivation, never taken from calldata as a fact.

## Rules that are enforced, not requested

1. **Red before green.** A change that fixes a defect arrives with a test that fails without it,
   and the test header names the commit at which it was red. A guard without a mutant does not merge.
2. **Every guard has a watcher.** Add the mutant to `.github/scripts/mutants.py` — one exact line,
   the replacement, the single test that must die — then run `check_targets.py` and that mutant.
3. **One question, one producer.** If your change touches a quantity with two producers or two
   consumers, update `SHARED_QUANTITIES.md` and run `bash .github/scripts/shared-quantities.sh`.
4. **Exact effects.** Refusals are asserted by selector and code, never a bare `expectRevert()`;
   expected values come from an oracle that is not the code under test.
5. **Size is a gate.** Every contract sits under EIP-170 with the project's own margin, on the
   release profile; `DeployedSizeGate` asserts it inside the suite. Measure size and gas on a build
   before proposing a change — never estimate them from the shape of the source.
6. **English only** in source, tests, docs and pull requests.
7. **Security findings do not go in public issues or public fix branches.** Write to
   contact@blazephoenix.xyz; the process is in [`docs/BOUNTY_METHOD.md`](docs/BOUNTY_METHOD.md).

## Commands

```bash
forge build
forge test --no-match-path 'test/fork/*'
FOUNDRY_PROFILE=release forge build --sizes
python3 .github/scripts/check_targets.py
python3 .github/scripts/mutants.py
bash    .github/scripts/shared-quantities.sh
python3 .github/scripts/check_no_secrets.py
python3 .github/scripts/assurance/metrics.py .
```

## What not to claim

No probability of correctness. Mutation adequacy is adequacy against this register. Threat
coverage is a floor on what has been considered. The contracts live on chain today are the previous
generation, a separate archived codebase; fixes here describe V2. Say what is measured, beside its
denominator, and nothing more — [`docs/AUDIT_METHOD.md`](docs/AUDIT_METHOD.md) §13.

## Licence

BUSL-1.1 until 2030-07-01. Reading, auditing, verifying and quoting are free and encouraged;
deploying the source or a derivative before the change date requires a licence.
