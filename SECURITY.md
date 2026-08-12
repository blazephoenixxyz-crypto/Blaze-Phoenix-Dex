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

## Recognition

Valid, previously-unknown findings are credited in our Security Hall of Fame
(with your consent). We do not currently run a paid bounty; this may change and
will be announced here.

## Authorship & integrity

This code is original work by **Fable & Mitra**, licensed BUSL-1.1. Authorship
is cryptographically provable via a keccak256 fingerprint embedded in the source,
without disclosing the authors' identity.
