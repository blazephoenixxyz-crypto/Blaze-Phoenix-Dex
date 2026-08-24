# Contributing

Thank you for reading the source. This file describes how work lands in this repository.

## Security issues do not belong here

If you believe you have found a vulnerability, **do not open a public issue and do not open a
pull request that fixes it in the open**. A public fix is a public disclosure of an unfixed
system. Write privately to **contact@blazephoenix.xyz**. Terms, severity rubric, and bounty
details are in [`SECURITY.md`](./SECURITY.md); confirmed reporters are credited in
[`SECURITY_HALL_OF_FAME.md`](./SECURITY_HALL_OF_FAME.md).

## The rule that matters most: red before green

A change that fixes a defect must arrive with a test that **fails without the fix**. Not a test
that passes with it — one that fails without it. This is not ceremony. Twice in this codebase a
live fix shipped with dead tests, and the second time we only found out because a mutation guard
caught it. If you cannot make the test fail on the unfixed code, you have not yet understood the
defect.

The same applies to guards: adding a security guard means adding the mutant that proves the guard
is watched. The CI mutation job pairs every versioned mutant with the named test that must catch
it, and it fails when a guard has no watcher.

## Before you open a pull request

```bash
forge build
forge test                                    # must be fully green
FOUNDRY_PROFILE=release forge build --sizes   # nothing may cross EIP-170
bash .github/scripts/shared-quantities.sh     # the register must agree with the code
solhint 'src/**/*.sol'
```

Fork tests need an RPC endpoint and run in their own CI job; you do not need them locally.

## If your change touches a shared quantity

[`SHARED_QUANTITIES.md`](./SHARED_QUANTITIES.md) lists every quantity with more than one producer
or consumer. If your change introduces a second producer of an existing quantity — or a new
quantity that a second place will read — add the row. State the **question** the quantity answers,
not just its name: two consumers of `fee` asking *"what will this pool charge?"* and *"what should
I assume it charges?"* drift while looking identical in a grep.

If you claim a row is `PINNED`, the test you name must exist and must mention the quantity. CI
checks exactly that, and it has already demoted two rows that could not meet it.

## House conventions

- **Solidity 0.8.36**, pinned. `via_ir` in every profile. Do not change the pragma.
- **Comments in English.** They carry weight here: most of them record the incident that motivated
  the line beneath them. When you change such a line, update the reason above it — a comment that
  survives the code it explains becomes a trap for the next reader.
- **Measure, do not trust.** Any value supplied by a caller is a coordinate to be measured or
  proven, never a fact to be stored. If you find yourself writing calldata into shared state, stop
  and read the *Depth producer guard* in `.github/workflows/ci.yml` first.
- **State the entry point.** The Router has four; only `swapBestExactIn` invokes the Solver. A gas
  optimisation on the Solver side saves exactly nothing in the other three. Say which one your
  change pays in.
- **Say what it costs in bytecode.** The contracts run against the EIP-170 24 576-byte ceiling and
  the Hub has the least headroom. If your change grows a contract, say by how much and what pays
  for it.

## Commits and pull requests

Conventional prefixes (`fix:`, `feat:`, `test:`, `ci:`, `docs:`, `chore:`), with a scope where it
helps (`fix(router):`). Write the *why* in the body — the diff already shows the *what*.

Keep a pull request to one concern. If it fixes two unrelated things, it is two pull requests.
