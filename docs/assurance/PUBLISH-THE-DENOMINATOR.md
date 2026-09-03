# Publish the Denominator

*On what test counts cannot tell you, two axes no coverage criterion indexes, and the one number
that bounds all the others.*

---

## 1. The claim that broke

We had reached the state every security-conscious codebase aims for. A curated mutation register
where every mutant is paired by name with the single test that must die to it — all of them
killed. An MC/DC census over every compound decision. Property tests, metamorphic relations,
stateful invariant campaigns, fork tests against live liquidity, symbolic proof gates, a
commercial prover on the load-bearing arithmetic, and eight rounds of a funded public bounty with
eighteen credited researchers and zero Critical findings.

Then an external researcher reported that a two-hop route paid roughly twice the fee the constant
advertises.

The line was covered. The branch was taken. Every mutant was green. Ten test files reached that
exact surface, and five of them asserted something about fees. The suite had 1,059 passing tests
and not one of them could fail.

The interesting question is not what the bug was. It is **why every instrument we had reported
health**, and what kind of instrument would not have.

---

## 2. What coverage criteria actually index

Statement, branch, condition and MC/DC coverage all index the same thing: **the code**. Did this
line run, was this branch taken, did this sub-condition independently affect the outcome. Mutation
testing indexes something else — **an injected fault** — and asks whether the suite notices it.
Property-based and metamorphic testing index a third thing: **relations over inputs**.

Three different indices, and between them they miss two properties that decide whether a defect is
reachable at all.

**The regime.** Some predicates are not decided by the arguments of a call. They are decided by
state a fixture puts in place beforehand — a registry entry, a lifecycle flag, a role granted. A
predicate over such state cannot vary *inside* a test, so no amount of input variation reaches its
other value. MC/DC enumerates argument variation and finds nothing to vary. And a mutant placed on
that predicate dies in whichever regime the fixtures happen to share, so mutation reports it
covered while an entire branch of the world has never run.

**The oracle.** An assertion compared against a literal, against the code's own output, or against
a helper that reuses production arithmetic is a fundamentally different kind of evidence from one
compared against an independent producer. No coverage criterion distinguishes them. Yet the
difference *is* the question of whether a test can fail for the right reason. A suite can be
mutation-adequate and consist entirely of assertions that move with the code they test.

Cross the two with a third, coarse axis — the shape of the composition under test — and you get a
lattice. In our corpus it has sixty-four cells over eight regimes, and when we first computed it,
**one cell was empty**: no bridge in the route, more than one hop, expected value from an
independent producer.

That is where the defect had been living.

The distribution is the finding. Fifty-one files occupied the easiest cell. One now occupies the
cell that mattered, and it was written the day the lattice was built.

Widened to every state flag, a sharper number appears: **seven of eight regimes have no composed,
cross-producer assertion at all when the flag is set**. The check that compares two independent
producers on a composed route exists only in the default world. Turn on ossification, pausing,
hooks, delegated approval, native value, or an operator seat — and the only assertion that
compares two producers disappears.

An empty cell is not a defect and we do not report it as one. It is the list of places where a
defect *could not be caught* by anything currently written, which is a different and considerably
more useful thing to know than a pass count.

---

## 3. Both directions of the trace

Registers of this kind run forward: from a threat, to the guard that answers it, to the test that
would fail without it. That direction finds threats with no answer.

It is blind to the opposite defect — code that refuses something for a reason nobody wrote down,
that no test has ever made fire.

Systems engineering has a name for the pair, **bidirectional traceability**, and its requirement
is not that the links exist but that they are *maintained*. We had done the backward direction by
hand, once: an inventory found refusal guards no test had ever driven, and a file was written to
drive them. Nothing recomputed that inventory afterwards, so it decayed from the day it was taken.

Recomputed continuously, it says: ninety-nine refusal sites, twenty-five distinct error codes, all
twenty-five driven by an assertion naming the exact code rather than a bare "it reverted".

And the number nobody had: **ninety of the ninety-nine sites share their error code with another
site.**

Where two refusals answer with the same bytes, an assertion about those bytes cannot say *which*
guard refused. Fire one, disable its neighbour by mutation, and both still look correct, because
the neighbour catches the call and produces the same error. Ninety-one percent of our refusal
surface is, at the level of the evidence, indistinguishable from itself.

---

## 4. What the source cannot promise

Every instrument above reads source and tests. There is a class of defect that lives in neither:
the source is right, the reviewer is right, and the bytecode is wrong.

In February 2026 a code-generator bug was reported against Solidity 0.8.28–0.8.33 under the IR
pipeline. A contract clearing both a persistent and a transient variable of the same type emitted
**the wrong opcode** for one of them — persistent where transient was meant, or the reverse —
because the generated helpers collided by name. Rated high. No source review finds that. No
source-level test finds it either, unless it happens to exercise the exact interleaving.

Two facts follow, and the second is the one worth having.

The first is a version fact: this tree compiles above that range.

The second is structural. All transient access here is written in inline assembly rather than as a
declared transient variable, so no clearing helper is generated and the collision has nothing to
collide. **The exposure is absent by construction, not avoided by a version choice** — and the
difference matters, because a version can be bumped by someone who does not know why it was
pinned, and a structural property survives that.

Asserted over the compiled artefact, per commit: no self-destruct, no callcode, no origin-based
authority anywhere; every declared function present as a selector in the dispatcher; and the
executor still emitting transient opcodes. That last one is the direct defence — if the emitted
code ever loses them, the reentrancy lock has quietly become persistent storage, which passes
every source-level test and is a different contract.

The artefact also proves something the language only promises. Three of our five contracts emit
**zero storage writes**. `view` is a claim the compiler makes; zero `SSTORE` is what it did.

---

## 5. Adding metres to seconds

Physics checks dimensional homogeneity as a matter of course. You do not add metres to seconds,
and a formula that tries is rejected before anyone reasons about it.

Solidity has one numeric type. A formula may add quantities of entirely different epistemic status
and pass the compiler, the tests, and every coverage criterion listed above.

Three provenances matter and they are not interchangeable. A **measured** quantity is read from
chain in this frame — a balance delta, a reserve, a venue's own answer. A **declared** quantity is
supplied by the caller. A **modelled** quantity is a constant, a count, or a formula over shape.

When terms of different provenance are summed or compared, **the weakest one dominates**, and the
strongest can be made irrelevant. Our output floor is the instance:

    floor = base − [ (legs − 1) × per_leg  +  min(impact, BPS)  +  volatility ]
                     └──── MODELLED ────┘     └─── MEASURED ───┘

The modelled term saturates the floor from route shape alone. Past a threshold in leg count, the
measured impact term has **no effect on the result at all**. It is formally present and materially
inert — and the shape parameter that saturates it is chosen by whoever builds the route.

Nothing in the type system sees that. No test noticed it. No coverage criterion indexes it. It is
the mathematical form of a design law we had written down for ourselves weeks earlier and never
confronted with this particular term.

The screen that finds it is crude — it classifies operands by how they are assigned, resolves one
level across call boundaries, and mixes are frequently correct, because a measured amount times a
constant rate is exactly what a fee is. Sums and comparisons are the rows to read; products
preserve provenance.

---

## 6. The number that bounds the others

We built nine instruments in one working session.

**Seven of them were wrong on their first run.**

One classified a test into the wrong world because it matched text inside a comment — it read
documentation as behaviour. One reported a fully covered entry point as having no tests, because
its pattern did not allow for a call-option block between a function name and its arguments. One
returned "none found" for a quantity whose pattern list was empty: it had searched nothing and
answered anyway. One filed every test that lets the planner compose a route as single-hop, because
it only recognised routes built by hand. One reported the most carefully tested guard in the
contract — the reentrancy lock — as undriven, because it did not recognise the corpus's *strongest*
form of evidence: catch the revert, decode the code, assert the number as a value. And one missed
the very instance it had been built to find, because the measured term it was looking for arrives
as a parameter and looks modelled when read locally.

Every one produced a confident, wrong number first.

That rate is not a confession, it is a **measurement**, and it is the one that bounds all the
others. If verification instruments are wrong at that rate on first construction, then every number
any of them produces carries that as a prior until the instrument has been tested. Nobody publishes
this figure. It may be the most important one in the whole apparatus.

The rule that comes out of it is the only one here that generalises:

> **An instrument is worth nothing until it finds an instance already known by other means.**

Not "until it looks right". Not "until it passes review". Until it finds, unprompted, a defect you
already have in hand from somewhere else. Every screen above was pointed at a confirmed finding
before its output about anything else was allowed to count.

---

## 7. The rhetoric

Assurance is usually communicated in numerators. *We have 1,059 tests. We have 96% coverage. We
have an audit. We have a bounty with eighteen researchers.* Every one of those is true here, and
not one of them would have caught the defect that started this.

Four rules, offered as a replacement.

**Publish the denominator.** Every assurance number is a ratio, and the denominator is a choice
somebody made. Seventeen of twenty-one threat classes answered is a claim; "we cover the major
threat classes" is not. Widening a catalogue *lowers* the ratio until the new rows are answered —
which is exactly the behaviour a completeness measure should have. A metric that only rises is
measuring its own window.

**Say how it would be gamed.** Each of our nine metrics improves if you shrink what it is measured
against; two of them improve if you make the code worse. That is not a reason to hide them, it is
the reason to publish the denominator beside each one and to write down the attack on the metric
in the same document as the metric.

**Report the instrument-defect rate.** You built the thing that measures. How often was it wrong?
If you do not know, you are reporting an unbounded number.

**Name what you cannot claim.** There is no probability of correctness in this document, and there
will not be one: the literature on validating ultra-high dependability is explicit that testing
cannot produce one. Mutation adequacy against a curated register is adequacy with respect to that
register, not evidence it is representative. Threat coverage is a floor on what has been
*considered*, and classes nobody has named are outside the denominator by construction — which is
the residual this whole apparatus shrinks and cannot eliminate.

An audit tells you what a good reviewer found in the time they had. None of this replaces that.
What it does is answer the question an audit structurally cannot: **not "is there a bug here", but
"what kind of bug could be here without anything we own noticing".**

---

*Every number in this document is recomputed on each commit from a clean checkout by scripts in
`.github/scripts/assurance/`, and each is printed beside its denominator. Method, definitions, and
the failures that produced each instrument: [`ASSURANCE.md`](./ASSURANCE.md).*
