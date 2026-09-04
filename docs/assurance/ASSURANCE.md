# Assurance

*Narrative companion: [Publish the Denominator](./PUBLISH-THE-DENOMINATOR.md).*

This document states how confidence in these contracts is produced, what each instrument can
establish, and — at least as carefully — what it cannot. It is written to be checked rather
than believed: every claim it makes about the system is either recomputed on each commit by a
script in `.github/scripts/assurance/`, or is marked as an argument rather than a measurement.

## 1. The evidence chain

A property is only as good as the shortest path from a threat to something that would fail if
the property broke. The chain used here has five links:

    threat  ->  property  ->  guard  ->  test  ->  mutant

- **threat** — a class of failure drawn from the public record of exploits, not invented here.
  The catalogue is `threats.json`.
- **property** — the thing that must hold, stated so that its negation is checkable.
- **guard** — the code that makes the property hold. Named by symbol, never by line number: a
  line number is valid only against one revision, and a stale anchor is a false claim wearing
  the clothes of evidence.
- **test** — an execution that fails if the guard is removed.
- **mutant** — a deliberate break of the guard, paired by name with the single test that must
  die to it. Without this link a passing test proves the code runs, not that it is watched.

Every link is checked mechanically. A guard symbol that leaves `src/`, a test that leaves
`test/`, or a mutant whose target line no longer exists, all fail the build.

## 2. What is measured, per commit

| Metric | Question it answers |
|---|---|
| Threat coverage | How many classes of published exploit are answered by a named guard, over how many have been considered at all |
| Relational consistency | How many quantities computed in two places have a test that ties the two producers together |
| Control-action arms | For each external state-changing function, whether its refusal and its post-renunciation behaviour are exercised |
| Assertion locality | What share of mutant/test pairs assert *at* the change rather than downstream of it |
| Regime lattice | In how many combinations of world-state, route shape and oracle provenance any test asserts at all |
| Guard inventory | How many refusals in the code a test drives by their exact error code, and how many refusal sites cannot be told apart by one |
| Bytecode invariants | Properties of the compiled artefact the source cannot guarantee: opcodes that must be absent, and the transient lock still transient after the compiler has spoken |
| Mutation-target integrity | Whether every mutant still points at exactly one line of real code |

Each is recomputable from a clean checkout. None of them is a probability that the system is
correct; see §5.

## 3. How each could be gamed, and the defence

A metric published without its failure mode is marketing. Each of these can be moved the wrong
way, and in each case the defence is to publish the denominator beside the numerator:

- **Threat coverage** rises by narrowing the catalogue. The number of classes considered is
  printed next to it; a rising ratio over a shrinking denominator is the shape of gaming.
- **Relational consistency** rises by deleting rows from the register. Same defence.
- **Control-action arms** rise by removing an entry point. The count of actions is printed.
- **Assertion locality** rises by writing a unit assertion at every mutated line, which buys the
  number at the cost of composition coverage. It is a measurement of the guard's *shape*, not
  of its quality, and neither direction is better on its own.
- **Regime lattice** rises by removing a regime from the catalogue, so the number of regimes is
  printed with it. It also rises honestly, by writing a test in a cell that was empty — which is
  the only use the number has.
- **Guard inventory** rises by giving two refusals the same error code, which is the opposite of
  what you want. The count of sites sharing a code is printed beside it for that reason.
- **Bytecode invariants** cannot usefully be gamed upward, and that is the point: the absence of
  an opcode is a real guarantee, while its presence proves nothing on its own. The check is a
  floor, and a no-op on a tree that has not been built.
- **Mutation-target integrity** is the only one with a single correct value. Anything below
  100% means a claim in the guard points at code that no longer exists.

## 4. Hazard analysis: what is counted and what is argued

Control actions are examined in the shape STPA gives: for each action the system offers, a
hazard may arise from not providing it, from providing it, from providing it at the wrong time,
or from stopping it too soon. Two of those four are decidable by reading source and tests, and
only those two are counted:

- **provided when it should not be** — a test that names the action and asserts a refusal;
- **stopped too soon / applied too long** — a test that names the action in a paused or
  post-renunciation world. This arm matters more here than in most systems, because the control
  plane can be renounced permanently: a permission that outlives it can never be answered.

The other two arms — hazards from an action never being taken, and from ordering between
actions — are not textual properties. They are argued in review and recorded as properties in
the shared-quantity register where they touch a quantity with more than one producer. A screen
that claimed to count them would be measuring its own pattern-matching.

## 4b. The regime lattice, and why the usual criteria do not reach it

Coverage criteria index the **code**: statement, branch, condition, path. Mutation indexes an
injected **fault**. Property and metamorphic testing index relations over **inputs**. Two things
that decide whether a defect is reachable are indexed by none of them.

The first is the **regime** — state that a fixture fixes before the call. A predicate over a
regime cannot vary inside a test, so no amount of input variation reaches its other value, and
a mutant placed on it dies in whichever regime the fixtures happen to share. Condition coverage
reports it as covered because the line ran and the branch was taken.

The second is the **oracle** — where the expected value came from. An assertion compared against
a literal, against the code's own output, or against a helper that reuses production arithmetic
is a different kind of evidence from one compared against an independent producer. No coverage
criterion distinguishes them, and the difference is the whole question of whether a test can
fail for the right reason.

Crossing the two with route shape gives a lattice whose empty cells are combinations in which
nothing has ever been asserted. An empty cell is not a defect and is not reported as one. It is
the list of places where a defect could not be caught by anything currently written, which is a
different and more useful thing to know.

The measurement is a screen, not a proof: membership is decided by matching patterns against
test sources with comments stripped, and a test can be filed in the wrong cell. Two ways of
getting that wrong are recorded in the script itself, because both produced confident wrong
answers before they were fixed — comments read as fixture, and route shape detected only when a
route was built by hand rather than composed by the planner. A cell reported as empty is
confirmed by reading before it is acted on.

## 4c. Both directions of the trace

The registers above run **forward**: from a threat, to the guard that answers it, to the test
that would fail without it. That direction finds threats with no answer. It is blind to the
opposite defect — code that refuses something for a reason nobody wrote down, and that no test
has ever made fire.

Systems-engineering practice calls the pair **bidirectional traceability**, and the requirement
is not that the links exist once but that they are maintained and re-verified as the system
changes. This repository had done the backward direction by hand exactly once: an inventory found
twelve refusal guards that no test had ever fired, and a file was written to drive them. Nothing
recomputed that inventory afterwards, so it decayed from the day it was taken. It is now
recomputed on every commit.

Two numbers come out of it, and the second is the interesting one:

- how many distinct refusal codes a test drives **by their exact code**, rather than by a bare
  "it reverted" that any neighbouring guard would also satisfy;
- how many refusal **sites share a code** with another site.

Where two refusals answer with the same bytes, an assertion about those bytes cannot say which
guard refused. A test that fires one and a mutation that disables the other will both look
correct, because the neighbour catches the call and produces the same error. Each such site needs
either a distinct code or a control that settles cleanly through the neighbour, pinning the fire
to its own site.

The screen went through three corrections before it was worth reading, each because it did not
understand a form of evidence the corpus already used: an argument cast to a width it did not
expect, a local helper that wraps the error selector, and — the one worth naming — the strongest
form in the corpus, where the revert is caught, the code decoded and the number asserted as a
**value**. That form proves which guard fired instead of matching bytes a neighbour could
produce, and the first version of the screen reported the most carefully tested guard in the
contract as untested because it did not recognise it. A screen that ranks evidence has to
understand the evidence.

## 4d. What the source cannot promise

Every other instrument here reads source and tests. One reads what the compiler actually
emitted, because there is a class of defect that lives only there: the source is right, the
reviewer is right, and the bytecode is wrong.

That class is not hypothetical. A code-generator bug reported against Solidity 0.8.28–0.8.33
under the IR pipeline caused a contract clearing both a persistent and a transient variable of
the same type to emit **the wrong opcode** for one of them, because the generated helpers
collided by name. It was rated high. No source review finds it, and no source-level test finds
it unless it happens to exercise the exact interleaving.

Two things follow, and the second is the more useful.

The first is a version fact: this tree compiles above that range.

The second is structural, and it is why the check exists rather than the version note alone. All
transient access here is written in inline assembly rather than as a declared transient variable,
so no clearing helper is generated at all and the collision has nothing to collide. The exposure
is **absent by construction**, not avoided by choosing a compiler — and the difference matters,
because a version can be bumped by someone who does not know why it was pinned, while a
structural property survives that.

What is asserted over the artefact: opcodes that must never appear anywhere (self-destruct,
callcode), and the presence of the transient opcodes in the executor. That last one is the direct
defence: if the emitted code ever loses them, the reentrancy lock has quietly become persistent
storage, which passes every source-level test and is a different contract.

The strongest bytecode property is not internal at all — it is that the runtime on chain equals
the runtime this tree builds. That one needs a network and belongs with the fork suites; it is
named here because it is the property that matters most, and because a divergence between a
reviewed tree and a deployed contract on a security-relevant constant is not a hypothetical for
this project either.

Opcode presence is coarse. Absence is a guarantee; presence is not. Anything requiring the
MEANING of emitted code needs symbolic execution or a verified compiler, and neither is claimed.

## 4e. How much of the emitted code is reached, and one tool that cannot say

`bytecode_coverage.py` reports an UPPER bound: an instruction counts as covered because the
LINE it belongs to ran, so a line holding an untaken branch still contributes its bytes. It ends
by asking for the other side. `pc_coverage.py` is the other side, and getting there required
throwing away the obvious answer first.

The obvious answer is `forge coverage --report bytecode`, which prints a disassembly with a hit
count in front of some instructions. Read literally it is a per-instruction execution map. It is
not, and the file refutes itself if asked: **25.7% of its marked instructions have an UNMARKED
straight-line successor**, which control flow forbids — if a JUMPDEST executed, the PUSH after it
executed too. The marks are the hit counts of foundry's SOURCE-level coverage items, each pinned
to the single instruction that anchors it; every other instruction in the same statement is left
blank, and a zero count is never printed at all, so a blank means "not an anchor" OR "an anchor
that never ran" and nothing distinguishes them. Two further readings were tried and refuted: that
the map is indexed by instruction counter and printed by byte offset (worse — 31.7% violations,
and a third of the marks land off an instruction boundary), and that the runtime section carries
a fixed offset (no shift in 0–700 bytes improves on none).

What survives is one direction. An instruction carrying a positive count ran. So the marks are a
SEED, closed under the two successors execution forces — a non-terminator is followed by its
neighbour, and `PUSH <const>; JUMP` lands on that JUMPDEST because the JUMP consumes exactly what
the PUSH left. JUMPI is not followed: reaching a branch implies neither arm. The closure is a
subset of what really ran, so its size is a lower bound and never an estimate, and the report
prints the residual control-flow violations, which must be zero.

An instrument is worth nothing until it finds an instance already known by another route, so this
one ships with its own: `test/PcCoverageGroundTruth.t.sol` deploys a contract with one function
the suite calls and two it never calls, and `--check` fails the build unless the closure reaches
the first and leaves BOTH the others at exactly zero instructions. A closure rule that leaked
would inflate every figure below by an amount nobody could see.

Measured over the five shipped runtime objects, 93,787 instructions:

| | share |
|---|---|
| carrying a positive recorded hit count | 68.1% |
| **proven executed** (seed + forced successors) | **85.9%** |
| no execution evidence | 14.1% |

The complement is not dead code. It is code that no evidence in this repository reaches, which is
a different and weaker statement, and the honest one.

Three caveats, none cosmetic.

Coverage builds with `--ir-minimum`, so these instructions are a **different binary from the
release artefact** — same sources, different optimiser, roughly twice the size; the bridge to the
shipped object is by source item, not by byte, and this figure is read beside `profile_parity.py`,
not instead of it.

**What the report hands back is one deployed instance, not the artefact.** A second probe
settles it. `test/PcCoverageImmutableProbe.t.sol` deploys one contract twice with different values
in an immutable and calls only the first. The disassembly comes back carrying the *second*
instance's tag — the one never called — while the annotation marks the *first* instance's function
as reached. The listing and the annotation are therefore two different objects: the hit map is
merged across every deployment by source item, and the disassembly is one arbitrary deployed
instance, immutables patched, chosen by hash order. That predicts exactly which contracts move —
the ones the suite deploys many times, which is every fixture's own Hub and Router. So the figure
is a lower bound on the union of what all deployments executed, laid over one instance's layout,
and not a measurement of the shipped artefact, whose immutables match no test instance.

**The input is not stable, and that bounds what may be cited.** Two runs of the identical tree
with the same `--fuzz-seed` do not produce the same listings. Core, Quoter and Solver came back
identical in their instruction stream. Router and Hub did not: same instruction count and the same
per-source line attribution, but a different total byte span (`0xa741` against `0xa769`) and a
different head — one run opening on the runtime dispatcher, the next on a constructor's `CALLVALUE`
guard. The two that moved are the two built with constructor arguments. So the **per-contract rows
above are printed for shape and must not be cited**: the same name did not describe the same object
twice. `--compare <dir>` reports that directly, and `3 of 5 listings identical` is what it said here.

The aggregate survives it, and barely moves: **85.9% and 86.2%** across two pinned-seed runs. The
figure to quote is the **lowest observed**, because every run's closure is a subset of what that run
executed, so a lower number is never contradicted by a higher one. Any citation should say how many
runs it rests on — this one rests on two.

## 5. What none of this establishes

Three limits, stated plainly because a document that omits them is not an assurance case.

**There is no probability of correctness here.** The literature on validating ultra-high
dependability is explicit that testing cannot produce one: after observing a system operate
without failure for some period, the defensible claim about the next equal period is close to
even odds, and confidence in very small failure rates requires evidence on a scale that
functional testing does not reach. No number in this repository should be read as "the
probability that these contracts are correct".

**Mutation adequacy is adequacy with respect to this mutant set.** The register is
hand-curated: each mutant exists because a specific guard was worth watching. Killing all of
them says the suite watches those guards. It does not say the set is representative of the
faults that occur in the wild, and the empirical work on fault–mutant coupling in other
languages reports that a substantial minority of real faults are not coupled to any mutant from
the usual operators. A saturated score is a floor, not a ceiling.

**Threat coverage is a floor on what has been considered.** No single published taxonomy covers
the losses actually observed in this domain; evaluations of automated detectors against real
incidents find that most incidents fall outside what any one classification enumerates. The
catalogue is therefore explicitly a record of what has been thought about, including the classes
recorded as out of scope with a reason. Classes nobody has named yet are, by construction, not
in the denominator — which is exactly the residual this whole apparatus is built to shrink and
cannot eliminate.

## 6. Practices that produced the instruments

Three rules, each of which was paid for with a defect in this repository's own tooling.

**An instrument is worth nothing until it finds the instance already known.** Every screen in
this directory was first run against a defect that had already been confirmed by other means.
Two of them failed that test on their first version — one classified documentation as behaviour
because it matched text inside comments; another reported a fully covered entry point as
untested because its regex did not allow for a call-option block between the function name and
its arguments. Both would have produced confident, wrong numbers.

**A verdict without a search is vacuity.** An early version of one screen reported "no
counterpart found" for a quantity whose pattern list was empty — it had searched nothing and
answered anyway. Absence must be produced by a search that ran.

**Measure, do not estimate, anything the compiler decides.** A guard added to a hot path was
estimated at tens of bytes and measured at several hundred, because the shape chosen extended a
variable's live range and the optimiser emitted a storage write twice. The estimate and the
measurement disagreed by an order of magnitude. Size, gas and codegen are measured on a
container before a change is proposed, never argued from the shape of the source.

## 7. What is not in this repository

Findings that are open, paths that are unfixed, and the per-row detail behind the metrics are
not published. The aggregate is: a reader can see how many rows of each register are answered
and how many are not. The rows themselves are a reading list for the people fixing them, and
publishing a list of the least-exercised surfaces of a live financial contract would be an
odd way to protect its users.

Security contact and disclosure policy: see `SECURITY.md`.
