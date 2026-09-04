# What the audit guarantees

Every security claim in this repository is produced the same way and can be checked the same
way. This page states what that process guarantees, what artefacts it leaves behind for a reader
to verify, and what it deliberately does not claim. It is written for the integrator deciding
what a green badge here means, and for the researcher deciding where a weekend is best spent.

The short version: **nothing here is closed by argument.** A property is either a test that
fails without it, paired with a mutant the test must kill, and a row in a register the build
fails without — or it is not a claim we make.

---

## 1. The guarantee chain

```
threat  →  property  →  guard  →  test  →  mutant
```

Every link is checked in both directions on every push. A guard is named by symbol, a test by
name, a mutant by the exact line it alters; if any of the three leaves the tree, the build fails.
A claim that cannot be checked from a clean checkout is not evidence, and is not published as
such.

## 2. Red before green

A fix arrives with the test that was red against the code without it, and the header of that
test says at which commit. This is enforced, not requested: the mutation guard fails the build
for any guard without a watcher, and a change that closes a property without a red test does not
merge. The consequence for a reader is simple — every regression test in this suite has been
seen to fail once, for the reason it is named after.

## 3. The curated mutation guard

`.github/scripts/mutants.py` holds **181 hand-written mutants**, each pairing one exact line of
source with the single test that must fail once that line is altered. The operator classes are
the shapes a real regression takes: a guard deleted, a comparison flipped at the bound that
decides a refusal, an authorisation condition widened, an error code swapped with its
neighbour's, a modifier removed.

Three properties make it a guard rather than a score:

- the paired test is run green on the unmutated tree first, so nothing is scored as a kill for
  an unrelated reason;
- a mutation the optimiser removes — identical runtime bytecode — is reported as *inert*, never
  as killed;
- a one-second static check verifies that every mutant still points at exactly one line, so a
  refactor cannot silently orphan a watcher.

**181 of 181 are killed.** The figure is always printed beside its denominator: it is adequacy
against this register, which is what §9 is about.

## 4. One question, one answer

The defect class this architecture is most exposed to is not a missing check. It is two
components — a planner and an executor, a preview and a delivery — answering one question in two
frames. [`SHARED_QUANTITIES.md`](../SHARED_QUANTITIES.md) enumerates every quantity with more
than one producer or consumer, states the *question* it answers, and grades what binds the
copies: a single producer with a CI guard forbidding a second, or a named test that asserts the
producers agree and names what it pins. A CI check fails the build when a row's test does not
reach the quantity it claims to tie. **Every two-producer quantity in the register is tied.**

## 5. Caller data is a coordinate, never a fact

Every field an integrator can write into calldata is classified in
[`docs/assurance/fields.json`](assurance/fields.json): **steering** — it chooses which pool,
never what the pool is; **confirmed** — measured from the pool or proven by derivation before it
reaches shared state; or **declared**, with the reason recorded. The registry's ranking, the
protocol floor and the fee base are computed only from confirmed quantities. Where a value is
authenticated by construction — a Uniswap V4 pool id derives from its own fee — the derivation
is the proof; everywhere else, the contract reads the pool.

## 6. Every refusal reads what it decides on

For each refusal site in the five contracts, an instrument measures the distance between the
object the guard observes and the object that decides the outcome. **86 of 99 refusals are at
distance zero** — the guard reads the very thing it rules on; the remainder sit behind a single
pinned derivation or, by design, an external codehash. A refusal at distance zero leaves no room
for the shape of defect in which a check is correct about the wrong object.

## 7. Beyond line coverage

Statement, branch and MC/DC coverage index the code; mutation indexes an injected fault;
property testing indexes relations over inputs. Two things that decide whether a guard is
reached at all are indexed by none of them — the **regime** a fixture fixes (is the route
bridged, is the pair full, is control renounced) and the **oracle** an expectation comes from.
The suite is measured against the lattice of regime × composition shape × oracle, and the
stateful invariant campaigns exist to reach the cells no hand-written fixture reaches. Every
compound decision in the sources is additionally censused sub-condition by sub-condition, so an
`&&` whose second half no test can notice is either documented as dead by construction or given
its test.

## 8. The compiled artefact, not only the source

The source promises; the artefact is what runs. Twenty instruments read the compiled objects and
assert, per commit:

- **88.3 % of the shipped-shape instruction stream is proven executed** by a sound lower bound —
  instructions foundry proves reached, closed under the successors execution forces, verified
  against a ground-truth contract the instrument must classify correctly before it prints;
- no `SELFDESTRUCT`, `CALLCODE` or `ORIGIN` anywhere; every declared function present in the
  dispatcher; three of five contracts emitting **zero** storage writes; every registry write
  under its ERC-7201 namespace;
- every compiler `Panic` code the artefact can raise classified and tested — pinned with its
  boundary where reachable, proven unreachable with a paired mutant where not;
- **every contract's deployed size asserted inside the suite**, with a signed margin to the
  project's own gate under EIP-170, on the same optimiser profile the suite runs under.

## 9. Evidence that is independent, not merely plentiful

For each load-bearing guard the apparatus records how many *independent* confirmations exist —
by source, oracle, tool, environment and methodology — and reports the **minimum**, because a
chain of evidence fails at its weakest link. Load-bearing properties are confirmed by at least
two routes that share no hypothesis: a unit test and a stateful campaign, a mock and a fork, a
Solidity assertion and a bytecode inspection.

## 10. Review from outside the frame

Every campaign that seals is reviewed read-only by reviewers who did not write it —
independent researchers through the bounty, and independent model families in adversarial mode
against a named commit. Each claim is confirmed or refuted by an experiment, never by reading,
and the experiment stays in the suite either way.

## 11. What is deployed

The contracts in production are the previous generation, a separate archived codebase. Fork
tests pin their codehash on every network the SDK names, so a change to what is deployed is
noticed; the V2 contracts in this tree are deployed onto forks of live liquidity and exercised
end to end on every fork run.

## 12. When a campaign is done

Bug hunting has no natural end, so the end is measured. A campaign closes when the severity of
what a sweep returns is monotone decreasing at constant effort, an independent pass over the
whole corpus returns nothing above threshold in the contracts, and every remaining item is a
recorded product decision or a test with a named regime still to reach. The pull request that
closes a campaign states that baseline in numbers, so the next one starts from a measurement.

## 13. What is deliberately not claimed

No probability of correctness — the literature on validating ultra-high dependability is
explicit that testing cannot produce one. Mutation adequacy is adequacy against this register.
Threat coverage is a floor on what has been considered. Each limit is stated in full in
[`docs/assurance/ASSURANCE.md`](assurance/ASSURANCE.md), beside the denominator of every number
above.

What *is* claimed is narrow and checkable from a clean checkout: every property named in this
repository has a test that fails without it, a mutant that test kills, and a register row the
build fails without.

---

Related: [`SECURITY.md`](../SECURITY.md) · [`docs/BOUNTY_METHOD.md`](BOUNTY_METHOD.md) ·
[`TESTING.md`](../TESTING.md) · [`SHARED_QUANTITIES.md`](../SHARED_QUANTITIES.md) ·
[`docs/assurance/ASSURANCE.md`](assurance/ASSURANCE.md) ·
[`docs/assurance/PUBLISH-THE-DENOMINATOR.md`](assurance/PUBLISH-THE-DENOMINATOR.md)
