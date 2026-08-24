<!--
  Security fixes do not belong in a public pull request.
  Write to contact@blazephoenix.xyz instead — see SECURITY.md.
-->

## What this changes, and why

<!-- The diff shows the what. Use this space for the why. -->

## The test that fails without it

<!--
  Name it. A fix without a test that goes red on the unfixed code is not finished.
  If the change is not a fix, say what it is instead (refactor, docs, tooling).
-->

## Checklist

- [ ] `forge test` is fully green
- [ ] `FOUNDRY_PROFILE=release forge build --sizes` — nothing crosses EIP-170
- [ ] `bash .github/scripts/shared-quantities.sh` passes
- [ ] Comments touched by this change are in English and still describe the code beneath them
- [ ] If a shared quantity gained a producer or consumer, `SHARED_QUANTITIES.md` has the row

## Cost

- **Bytecode:** <!-- +N B / -N B per contract, or "none" -->
- **Gas:** <!-- which of the Router's four entry points pays, and roughly how much -->

## What this does not do

<!--
  The limits you know about. A pull request that lists none is either trivial
  or has not been thought about hard enough.
-->
