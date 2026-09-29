# Security Policy

BlazePhoenix-Dex is a financial protocol. We take security seriously and welcome
responsible disclosure from researchers.

## Reporting a vulnerability

**Please do not open a public issue for security reports.**

Report privately to **contact@blazephoenix.xyz** (or a DM to
[@Sigmacrit](https://x.com/Sigmacrit)). Include:

- a description of the issue and its impact,
- the affected contract(s), endpoint(s) or package(s) and, where possible, `file:line`,
- a minimal proof-of-concept or the exact conditions to reproduce,
- your assessment of severity.

We aim to acknowledge a report within 72 hours and to keep you updated through
triage and remediation. Please give us a reasonable window to fix and deploy
before any public disclosure.

## Scope

Six surfaces are in scope. The campaign page,
[blazephoenix.xyz/bounty](https://blazephoenix.xyz/bounty), carries the same list
and the reporting window.

| Surface | What is covered | Hunt for | Source |
|---|---|---|---|
| DEX aggregator | Router, Solver, Hub, Quoter and Core: the deployed contracts and the release that launches after the campaign. `GET /api/deployments` is the authoritative list of what is deployed. | A quote diverging from execution; the Iron-Law floor bypassed; route weight sourced from self-reported pool state; a hostile hook reaching a user's swap. | [Blaze-Phoenix-Dex](https://github.com/blazephoenixxyz-crypto/Blaze-Phoenix-Dex) |
| Staking engine | `BlazePhoenixStaking` and `BlazePhoenixMathLib`, published ahead of launch so they can be broken first. | Insolvency reachable, or value paid to the wrong party even while the conservation guard balances. | [Blaze-Phoenix-Staking](https://github.com/blazephoenixxyz-crypto/Blaze-Phoenix-Staking) |
| Public API | `/api/quote`, `/api/verify`, `/api/stats`, `/api/tape`, `/api/openapi.json` and the rest of `blazephoenix.xyz/api`. | A response that makes a caller sign a worse trade than the chain would settle; cache poisoning; injection; authorisation bypass. | [Blaze-Phoenix-API](https://github.com/blazephoenixxyz-crypto/Blaze-Phoenix-API) |
| MCP server and agent surfaces | `blazephoenix.xyz/mcp`, `/.well-known/mcp.json`, `/agents`, `llms.txt`, the machine-readable files, and the local server `@blazephoenix/mcp`. | A tool call or file that steers an AI agent into signing a harmful transaction, leaking data, or trusting forged content. | [blazephoenix-mcp](https://github.com/blazephoenixxyz-crypto/blazephoenix-mcp) |
| SDK and calldata | `@blazephoenix/sdk`, and the route and calldata the API, MCP server and front end hand to integrators. | Calldata that encodes a different recipient, token, amount or minimum than the caller asked for. | [SDK](https://github.com/blazephoenixxyz-crypto/SDK) |
| Website | `blazephoenix.xyz`: the swap, staking and API tabs. | The interface showing one trade and asking the wallet to sign another; stored or reflected XSS with impact. | none published |

## Out of scope

- Third-party code: pools, tokens, bridges, wallets, RPC providers, Cloudflare, GitHub, unless our code consumes them unsafely.
- Limits the whitepaper already states and bounds (for example the ≈2.7 % sandwich cap on a 1 %-of-depth trade, or quote staleness under your signed minimum), unless you beat the stated bound.
- Anything already in `/security/advisories` or a Hall of Fame register. Duplicates go to the first report by timestamp.
- Price movement, MEV and front-running that settle at or above the minimum the user signed.
- Attacks that need a compromised private key, admin key, or the victim's own device.
- Volumetric DoS, load testing, spam, and rate-limit exhaustion of the free public API.
- Missing headers or cookie flags, SPF/DKIM/DMARC, clickjacking, CSRF, and CORS on public read-only endpoints, without demonstrated impact.
- Self-XSS, tab-nabbing, open redirects and text injection without impact.
- Outdated dependencies or versions without a working exploit.
- Gas optimisations, style, best-practice and informational notes.
- Theoretical reports without a proof of concept, and unverified AI-generated reports.
- Display glitches (stale figures, layout) that cannot change what a user signs.
- Social engineering, phishing and physical attacks.

## Testing rules

- **Contracts.** Test on a fork. Every contract is deterministic and forkable. Do
  not test against other users' funds on mainnet.
- **API, MCP endpoint and website.** Test only against `blazephoenix.xyz`, or
  against your own local run of the published source. Do not test other hostnames,
  or the infrastructure and third-party services behind them.
- **SDK and local MCP server.** They run entirely on your own RPC. Test them locally.
- **No volumetric testing.** No denial-of-service, load testing, spam or
  rate-limit exhaustion of the public API.
- **Stop at proof of concept.** Show the issue with the minimum needed; do not
  extract value or read data beyond it.
- **Disclosure.** Do not disclose before a fix. A report that tests against other
  users' funds on mainnet, or discloses before a fix, is disqualified.

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

An independent external audit is scheduled before launch. What runs on every
push: a forge suite of 1,252 declared tests across 206 files (unit, property,
parity, stateful invariants) and 25 fork suites against live chain liquidity;
Halmos symbolic proofs, Slither (fail on high), an EIP-170 size guard — also
asserted inside the suite — and the offline gas ledger, which together with the
suite are what branch protection on `main` requires; the Certora Prover (INV-20
fail-closed), Aderyn, Solhint and the secret scan run alongside. Beyond the
suite, a curated mutation guard of 183 named mutants, a shared-quantity
register, a calldata-field matrix and twenty instruments over the compiled
artefact are recomputed per commit. What each guarantees, and how to check it
from a clean checkout: [`docs/AUDIT_METHOD.md`](./docs/AUDIT_METHOD.md).

Track record, across this repo and the staking sibling: **25 researchers
credited** in [`SECURITY_HALL_OF_FAME.md`](./SECURITY_HALL_OF_FAME.md) — a count
you can check against that file rather than against this sentence — every
confirmed finding fixed with a regression test that fails against the pre-fix
code, and **zero Critical**: no direct theft or permanent freeze of funds has
ever been demonstrated. Every report is reproduced red-first before a verdict
is given; the process, from receipt to Hall of Fame, is written down in
[`docs/BOUNTY_METHOD.md`](./docs/BOUNTY_METHOD.md).

## Bounty programme

**50,000,000 BZPX is allocated to security research** — 5% of a fixed
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
| Critical — direct theft or permanent freezing of user funds | 2,500,000 – 7,500,000 BZPX |
| High — theft under specific conditions, or protocol insolvency | 625,000 – 2,500,000 BZPX |
| Medium — griefing, temporary denial of service, value leakage | 125,000 – 625,000 BZPX |
| Low — demonstrated impact below the above | up to 125,000 BZPX |

A report must be previously unknown to us and must demonstrate impact, not merely
describe a theoretical concern. Duplicates are settled by timestamp of the first
report received.

## Safe harbour

Research conducted in good faith under this policy is **authorised**, and we will
not pursue or support legal action against you for it. If a third party brings an
action against you for research that complied with this policy, we will make that
authorisation known publicly and in writing.

Good faith means, concretely: you work only against the surfaces named in Scope,
following the Testing rules;
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
