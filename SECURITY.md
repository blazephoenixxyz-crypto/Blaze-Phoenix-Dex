# Security Policy

BlazePhoenix-Dex is a financial protocol. We take security seriously and welcome
responsible disclosure from researchers.

## Reporting a vulnerability

**Please do not open a public issue for security reports.**

Report privately to **contact@blazephoenix.xyz** (or a DM to
[@Sigmacrit](https://x.com/Sigmacrit)). Include:

- a description of the issue and its impact,
- the affected contract(s) and, where possible, `file:line`,
- a minimal proof-of-concept or the exact conditions to reproduce,
- your assessment of severity.

We aim to acknowledge a report within 72 hours and to keep you updated through
triage and remediation. Please give us a reasonable window to fix and deploy
before any public disclosure.

## Scope

In scope: the smart contracts in this repository (Router, Solver, Hub, Quoter,
Core) and their on-chain behaviour. Out of scope: third-party pools, tokens,
bridges, and RPC providers the protocol reads from — but a vulnerability in how
*we* consume them is in scope.

## Our security model

The protocol is invariant-driven and designed to **fail closed**. Reports are
most valuable when they demonstrate a violation of a stated invariant — for
example a path where the quoted output diverges from execution, where route
weight can be sourced from forgeable (self-reported) pool state, where the
measured output floor or the caller's `userMinOut` can be bypassed, or where the
reentrancy lock does not span the measurement seam.

The invariant catalogue is documented in [`llms.txt`](./llms.txt). Invariants are
exercised in CI by the test suite, Halmos symbolic proofs, and Slither static
analysis; a report that defeats one of these is especially welcome.

## Verification pipeline and track record

An independent external audit has not happened yet; it is planned before
launch. What runs on every push, today, in public CI: a ~290-test forge suite
(unit, fuzz, stateful invariants) plus ~40 fork tests against live chain
liquidity; Certora Prover (INV-20 fail-closed) and Halmos symbolic proofs;
Slither (fail on high), Aderyn and Solhint static gates; an EIP-170 size guard;
an offline gas ledger.

Track record so far, across this repo and the staking sibling: **21 external
reports triaged (8 public + 13 private), every confirmed finding fixed with
regression tests, zero Critical** — no direct theft or permanent freeze of user
funds has ever been demonstrated. Internal adversarial audits are red-first:
a finding becomes a failing CI test before any fix is written. The public
ledger of findings and credits lives in
[`SECURITY_HALL_OF_FAME.md`](./SECURITY_HALL_OF_FAME.md) and [`REPORTS.md`](./REPORTS.md).

## Bounty programme

**40,000,000 BZPX is allocated to security research** — 4% of a fixed
1,000,000,000 supply, carved out of the token allocation for this and nothing
else. The pool is shared with
[BlazePhoenix-Staking](https://github.com/blazephoenixxyz-crypto/Blaze-Phoenix-Staking);
a finding against either protocol draws from it.

Three things stated up front, because a researcher deserves to decide with open
eyes rather than discover the terms after doing the work:

1. **Rewards are paid in BZPX, not in stablecoins or ETH.** The token is not
   liquid at the time of writing, so the value of an award at the moment it is
   granted is not something we can promise. What we can promise is the quantity
   and the schedule.
2. **Payouts begin after October 2026.** Reports are accepted, triaged and
   acknowledged from now; settlement of awards starts after that date. If that
   timing does not work for you, it is entirely reasonable to wait — the scope
   is not going anywhere.
3. **Severity is our assessment, and we will show our reasoning.** Where we
   disagree with a reporter's rating we will say why in writing rather than
   silently downgrading.

| Severity | Award |
|---|---|
| Critical — direct theft or permanent freezing of user funds | 2,000,000 – 6,000,000 BZPX |
| High — theft under specific conditions, or protocol insolvency | 500,000 – 2,000,000 BZPX |
| Medium — griefing, temporary denial of service, value leakage | 100,000 – 500,000 BZPX |
| Low — demonstrated impact below the above | up to 100,000 BZPX |

A report must be previously unknown to us and must demonstrate impact, not merely
describe a theoretical concern. Duplicates are settled by timestamp of the first
report received.

## Safe harbour

Research conducted in good faith under this policy is **authorised**, and we will
not pursue or support legal action against you for it. If a third party brings an
action against you for research that complied with this policy, we will make that
authorisation known publicly and in writing.

Good faith means, concretely: you work only against the contracts named in Scope;
you do not destroy data, degrade service for others, or access funds or
information beyond the minimum needed to demonstrate the issue; you stop at proof
of concept rather than extracting value; and you report promptly and give us a
reasonable window before disclosing publicly.

If you are unsure whether something is in bounds, ask first at the address below.
A question costs you nothing and we would rather answer it than have you guess.

## Recognition

Valid, previously-unknown findings are credited in our Security Hall of Fame
(with your consent), whether or not an award applies. This is not a new promise:
external researchers have already been credited by name in this repository's
history for findings that shaped the current contracts.

## Authorship & integrity

This code is original work by **Fable & Mitra**, licensed BUSL-1.1. Authorship
is cryptographically provable via a keccak256 fingerprint embedded in the source,
without disclosing the authors' identity.
