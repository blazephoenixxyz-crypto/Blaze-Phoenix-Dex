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
| Projection distance | For each refusal site, how far the object the guard reads is from the object that decides (§4f) |
| Calldata-field confirmation | Which integrator-writable fields are steering, confirmed against an observation, or declared (`fields.json`) |
| Release-binary execution | Which instructions of the shipped artefact a recorded scenario ran, replayed with an opcode check at every step (§4g) |
| Regime covering array | Whether every pair of values of the ten regime factors appears in a generated fixture, and how each row ended (§4h) |
| Hostile-venue matrix | Whether every venue pathology × door settles or refuses with a selector of ours, never a third way (§4i) |
| Sandwich bound | How much an adversary who orders the block can take from a trade before the floor refuses (§4j) |
| Canonical-oracle tightness | How far the Core's quote maths sit from implementations written from the venues' specifications (§4k) |

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
| **proven executed** (seed + forced successors) | **88.3%** |
| no execution evidence | 11.7% |

The complement is not dead code. It is code that no evidence in this repository reaches, which is
a different and weaker statement, and the honest one.

Three caveats, none cosmetic.

Coverage builds with `--ir-minimum`, so these instructions are a **different binary from the
release artefact** — same sources, different optimiser, roughly twice the size; the bridge to the
shipped object is by source item, not by byte, and this figure is read beside `profile_parity.py`,
not instead of it.

**Corrected 2026-09-04, and the correction is the more useful half.** The first figure published
here, 85.9%, rested on resolving `PUSH <const>; JUMP` targets at file offset 0. Four of the five
artefacts come back as **creation code**, with the runtime appended after the constructor's
`CODECOPY; RETURN` and a one-byte `INVALID` pad, and jump targets inside that runtime are relative
to ITS start. At base 0 only 10–20% of targets landed on a real `JUMPDEST`; at the true base,
97–100% do. The old computation therefore dropped almost every real edge and followed a handful of
spurious ones — and a spurious edge marks an instruction as CERTAINLY EXECUTED when it may never
have run, which is not a loose bound but no bound at all. The instrument now derives the base two
independent ways (the `CODECOPY` source operand, and the byte after the `INVALID` pad), picks
whichever resolves more targets, and prints that rate so a bad base is visible instead of silent.
The corrected figure is **88.3%** — higher than the unsound one, which is luck, not vindication.

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

**Stability, measured.** Two runs of the identical tree at `84d1553` with the same `--fuzz-seed`
produced five listings identical instruction for instruction and the same closure: **88.3 % in
both**. The per-contract rows above are still printed for shape rather than cited, because the
report disassembles one deployed instance chosen by hash order and a run may hand back a
different instance of the same contract (the immutable probe shows exactly that). The figure to
quote is the **lowest observed** across pinned-seed runs, because every run's closure is a subset
of what that run executed, so a lower number is never contradicted by a higher one. Any citation
should say how many runs it rests on — this one rests on two.

## 4f. How far each refusal observes from what decides

Every defect confirmed in this repository, internal or reported, has one shape: a check observes
one object while a DIFFERENT object decides the behaviour. The preview modelled a fee the executor
measured. The volume event published the caller's declaration instead of the flow. The classifier
named the first intermediate while the fee anchor walked hop inputs. The hook pin commits to a
proxy's dispatcher while the implementation executes. "Absence is permission" is the same shape
with the observed object empty: nothing is read, and nothing is taken for yes.

That makes the interesting property of a refusal not its complexity but its DISTANCE — how far
what it reads sits from what decides. `projection_distance.py` classifies the predicate guarding
every `revert` in the five contracts:

| what the predicate reads | distance |
|---|---|
| a constant, an `immutable`, a value fixed at construction | 0 |
| a balance delta, or a quantity computed in-frame from one | 0 |
| a field of the caller's `Route`/`Hop`/`Leg` | 1 — unless the declared value is also what SELECTS the object it describes |
| a lookup in another contract's mutable storage | 1 |
| a property of a contract that can delegate its behaviour | unbounded |

Measured over 99 refusal sites: **86 at distance 0, 11 at distance 1, and exactly 2 unbounded.**

The two unbounded sites are both `EXTCODEHASH` pins, and they are twins — `Hub:499` pins an
admitted hook's code, `Hub:728` pins an admitted factory's. Both are defeated by the same thing: a
proxy's runtime does not change when its implementation does. External researchers have reported
the first one twice. The asymmetry is what matters and it is not symmetric at all:

- For **hooks**, the residual is CLOSED by an argument the pin does not carry. A V4 hook's
  permission bits live in its ADDRESS, which is immutable, and the refusal at `Router:1764` reads
  those bits — distance 0. A proxy can replace every line of its logic and still gain no bit its
  address never had. The pin is defence in depth on top of that, not the defence.
- For **factories**, there is no equivalent. A factory address carries no bits. The residual is
  BOUNDED — by pool admission, the per-leg floor and `userMinOut`, so the damage is route
  degradation rather than drainage — and the guard at `Hub:728` documents that bound at the site.

Stating that difference is the point of measuring the distance. Two guards with identical text and
identical failure modes, one of which stands on something immutable and one of which does not.

The screen's own limit, stated: it reads one predicate and classifies the identifiers in it. It
cannot see that a value was constrained three frames up, and it cannot decide the `leg.hooks`
question — a caller-declared field that is ALSO the pool selector is at distance 0, not 1, but
only because one assignment binds them. That assignment is pinned by
`test/V4SievedHookIsTheExecutedHook.t.sol`, which is the point of measuring the distance.

## 4g. What the shipped binary executes

Every execution figure above is measured on the coverage build, a different binary from the one
that deploys. `pc_trace.py` reads the release artefacts and a trace recorded by
`test/PcTraceProbe.t.sol` with `vm.startDebugTraceRecording` under the release profile. A
`DebugStep` carries no program counter; it carries the opcode, the depth, the running address
and, for jumps and calls, the top two stack words — enough to replay the counter exactly, with
the artefact's own opcode checked at every step. A frame that disagrees once is abandoned and
counted, and a single mismatch fails the check: a replay that disagrees with the trace is no
bound. Which artefact a frame runs is learned by replaying its first steps under each of the
five objects, never assumed from an address.

Ground truth the reader must re-find before its number is printed: zero opcode mismatches; a
second Router deployed by the probe and never called must appear in no frame; the called Router
must have crossed the reentrancy lock (a `TLOAD` and two distinct `TSTORE` sites).

Measured for one recorded scenario — an honest V2 swap through `swapExactIn`:

| artefact | instructions run | code section | share | replayed steps | mismatches |
|---|---:|---:|---:|---:|---:|
| Router | 4,382 | 15,565 | 28.2 % | 9,043 | 0 |
| Hub | 407 | 16,120 | 2.5 % | 828 | 0 |

The complement is not dead code. It is code no recorded scenario ran, which is a list of
scenarios still to record — one per door and per venue family — and the union grows with each.
The figure this instrument is built to produce next is the intersection of each mutant's
footprint in the shipped binary with the instructions its paired test executed: a pair whose
intersection is empty is a test that cannot kill that mutant, whatever the guard reports.

## 4h. The regime covering array

Coverage criteria index the code; mutation indexes an injected fault; neither indexes the state
a fixture fixes. Ten such factors are enumerated — venue family (V2, V3, Solidly), hops (1–3),
legs per hop (1–2), whether the input token is a registered bridge, whether the intermediate is,
fee-on-transfer shape (none, pull-only, every transfer), the input token's decimals (18, 6), the
door (calldata route, solve-in-transaction, Permit2), control (live, renounced) and whether the
pair is full — **5,184 combinations**. `covering_array.py` generates a strength-2 covering array:
**63 rows that hold every one of the 258 pairs of factor values**, each row one fixture through
one harness (`test/regime/RegimeHarness.sol`) with one assertion — the swap settles, with the
delivered amount equal to the recipient's balance delta, at least the floor the Router emitted,
and nothing left on the Router; or it is refused with a selector of ours. A panic, a foreign
selector, an under-delivery or a stranded balance is a third way, and fails the row.

Measured on this tree: **53 rows settle, 4 are refused with a selector of ours** (the planner
has no bridged path to build; a route the executor declines), **6 are not constructible** (the
pull-only-taxed token has no six-decimal form) and **0 take a third way**. The rows the fixture
cannot build are printed by name and count against the denominator; the families not yet in the
array — V4, native V4, Algebra, the native door, hooks — are stated in
`docs/assurance/regimes-covering.json`. The generated file is checked against its generator in
CI, so the array cannot drift from the factors it claims to cover.

The array's first run made a frame explicit that the parity tests had pinned only on one side:
the floor the Router enforces equals the attested floor when the protocol fee comes off the
output, and sits inside `[attested × (1 − fee), attested]` when it comes off the input — the lower
edge by the fee, the upper by the curve's convexity. Both frames are now asserted on every row.

### 4h.1 Strength three

The same generator, asked for every **triple** of factor values: `covering_array.py` now builds a
strength-3 array beside the pairwise one (`test/regime/RegimeCoverageT3.t.sol`,
`docs/assurance/regimes-covering-t3.json`), 168 rows holding all 1,636 triples of the same ten
factors, through the same harness and the same single assertion. The pairwise file is byte-identical
to before — the two arrays are two denominators, not one replacing the other.

| strength | rows | tuples held | settled | refused, ours | not constructible | third way |
|---|---|---|---|---|---|---|
| 2 | 63 | 258 pairs | 53 | 4 | 6 | 0 |
| 3 | 168 | 1,636 triples | 158 | 10 — `SolverE(5)` ×7, `RouterE(13)` ×3 | 0 | 0 |

What strength three adds is interactions of three factors that no pair reaches — a fee-on-transfer
token entering a three-hop route through the planned door, a six-decimal input on a full pair under
renounced control. Every one of the 168 rows either settled inside its floors or refused with a
selector of ours; the ten refusals are the same two families the pairwise array refuses for.

## 4i. The hostile-venue matrix

Token pathologies had their tests; venue pathologies had none in a matrix. `test/regime/HostileVenues.sol`
holds one misbehaviour per venue — a pair that takes the input and pays nothing, one that pays
half, reserves that come back as a 64 KiB returndata bomb, a reserve read and a swap that burn
every unit of gas, a token whose `decimals()` never returns, a V3 pool that fires its payment
callback twice, one that re-enters the Router through the solve door before paying, one whose
`slot0()` reverts, and a factory whose `getPair()` answers with a pool on other tokens — and
`HostileVenueMatrix.t.sol` crosses each with the calldata door and the solve-in-transaction
door under the covering array's rule: settle with the delivered amount equal to the balance
delta and nothing left on the Router, or refuse with a selector of ours. Two cells carry a
sharper oracle: a venue that under-pays must be refused, and the re-entering pool records
whether the Router ever let its nested swap run.

| venue | calldata door | solve door |
|---|---|---|
| pays nothing / pays half | refused `RouterE(5)` | refused `RouterE(5)` |
| returndata bomb on the reserve read | settles | settles |
| reserve read burns all gas | refused `RouterE(8)` | the planner never selects it |
| swap burns all gas | whole transaction reverts, balance untouched | whole transaction reverts, balance untouched |
| `decimals()` burns all gas | settles | settles |
| payment callback fired twice | refused `RouterE(6)` | refused `RouterE(6)` |
| re-enters the Router before paying | settles; the nested swap never ran | settles; the nested swap never ran |
| `slot0()` reverts | settles on the attested quote | the planner never selects it |
| factory answers with a pool on other tokens | never listed | never listed |

The last row is what the matrix's first run changed. Discovery listed a pool a curator-admitted
factory answered with, the planner ranked it, and the executor refused it at the seam that pays
(`LEG-01`, `RouterE(3)`) — funds never at risk, the pair refused while the impostor won the
split. An asked pool now proves its own `token0()` / `token1()` before discovery lists it, with
the reads the executor already makes, so a pool that would be refused at execution is never
listed, planned or ranked. A derived address is a theorem over the pair and needs no proof.

A swap that burns all forwarded gas is the one cell no caller can decide for its callee; the
transaction reverts whole and the user's balance is untouched, which is asserted rather than
assumed. Read the matrix with `matrix_summary.py`.

## 4j. The sandwich curve — the attacker's side of the floor

Every floor test asks whether a bad fill is refused. `test/regime/SandwichCurve.t.sol` asks what
an adversary who orders the block can extract before it is: the victim's route and floor are fixed
at quote time, as in a pending transaction; the attacker trades a fraction of the pool's depth
ahead of the victim, the victim executes, the attacker trades back. The venue is a constant-product
pair, the shape every sandwich model uses, so the curve is a property of the floor.

Measured on a 1 %-of-depth trade (10,000 against 1,000,000 a side):

| attacker moves | victim | victim's loss vs the quote | attacker's round trip |
|---|---|---|---|
| 0.1 % of depth | settles | 0.47 % | +13.9 |
| 0.5 % | settles | 1.26 % | +68.9 |
| 1 % | settles | 2.22 % | +136.7 |
| 2 % | settles | 4.12 % | +268.7 |
| 3 % and beyond | **refused** | 0 | −174.5 … −544.9 |

The guarantee asserted at every point: a settled victim never receives less than the floor
attested at quote time, so the loss is bounded by the distance between the attested quote and the
attested floor; and the refusal region is closed upward — past the edge, every larger manipulation
is refused and the attacker is left holding the price they moved. The number worth quoting is the
last settled row: **the floor caps what a sandwich can take from a 1 % trade at about 2.7 % of it**,
and turns the attacker's trade into a loss the moment it would take more.

## 4k. Canonical oracles — the quote maths against the venues' specifications

Every mock in the suite quotes with the Core's own formulas, so a defect in a formula is invisible
to every parity test that uses them: the oracle is the object. `test/regime/CanonicalOracles.t.sol`
holds three implementations written from the venues' published invariants — Uniswap V2's constant
product with the fee on the input, Uniswap V3's single-tick square-root-price step with the pool's
own against-the-trader rounding, Solidly's stable curve `x³y + xy³ = k` solved by Newton's method —
and fuzzes the Core against them, 5,000 runs each, asserting the direction first (the Core never
promises more than the venue's maths delivers) and the tightness second.

| family | direction | tightness measured |
|---|---|---|
| Uniswap V2 | the Core never exceeds the spec | exact to the wei |
| Solidly stable | the Core never exceeds the curve by more than the solver's own last step | within 4 wei |
| Uniswap V3 | the Core never exceeds the spec by more than **one ulp of the square-root price**, which is `L / 2⁹⁶` wei | below one wei for every pool with `L < 2⁹⁶`, i.e. every pool in existence |

The V3 bound is stated in the quantity that causes it: the pool rounds its new price against the
trader and the Core rounds it once, so the two can differ by one unit of `sqrtP`, worth `L / 2⁹⁶`
wei of output. The fuzz found exactly that — 13 wei on a 6.5 × 10³⁴ output at `L = 10³⁰` — and the
assertion is the bound, not the sample.

## 4l. Mutants aimed at the invariants

Until 2026-09-05 none of the 183 curated mutants named a stateful invariant as the test that must
die to it. The 39 `invariant_*` functions across 14 campaigns were green, and nothing had ever
asked whether any of them could go red: a campaign whose handler never reaches the state a
property protects certifies that property over an empty universe, and looks identical from the
outside to one that reaches it. The measurement is the same one the guard makes for unit tests,
pointed at the campaigns: alter one guard in the source, run every invariant, and record which
ones notice.

Fifteen mutants, one per property the campaigns claim, each run against all 39 invariants on the
same seed (`docs/assurance/invariant-mutants.json` holds the full matrix, with the exact edit):

| mutant | what it removes | noticed by |
|---|---|---|
| the final transfer pays one wei less | holds-nothing | `RouterHoldsNothing`, `routerHoldsNothing`, `HoldsNothingBeyondTheSeed` |
| the protocol fee doubles | the fee ceiling | `FeeNeverExceedsProtocolMax` |
| the input-side fee is never charged | the fee floor | `FeeNeverEscapes` |
| the fee is charged on both sides | one fee, one side | `FeeIsChargedOnExactlyOneSide` |
| 30 % of every fee goes to a dead address | conservation | `conservationA/B/C/H`, `TokenConservation`, `LedgerConservationA` |
| the leg-pair guard admits a leg on the wrong pair | homogeneous hops | `DivergentLegNeverSettles`, and the stranded-money pair |
| `whenLive` no longer checks `paused` | the pause | `PausedRouterNeverSettles` |
| the reentrancy lock no longer refuses | the lock | `reentrancyBlocked` |
| `MAX_SLOTS` becomes 17 | the registry bound | `neverExceedsMaxSlots` |
| the input-residual sweep ignores its baseline | stranded money | `StrandedMoneyIsNeverSwept`, `HoldsNothingBeyondTheSeed` |
| the output measurement ignores its baseline | stranded money | the same pair |

**Eleven of fifteen were noticed; eighteen distinct invariant names went red at least once.** The
eleven are now entries in the mutation guard, paired with the invariant that dies to them, so the
campaigns stop being properties nobody has tried to break.

The four survivors are the finding, and each is read rather than counted:

| survivor | reading |
|---|---|
| the post-fee `userMinOut` check is halved | expected — `DeliveredNeverBelowUserMinOut` is a regression sentinel; no campaign universe holds a fee-on-transfer `tokenOut`, so the guard is unreachable there and two unit mutants watch it instead |
| the protocol floor is halved | **gap**: no stateful campaign asserts the floor. One unit mutant watches the comparison. A handler that reads `ExecutionProof.floorOut` and asserts `delivered >= floorOut` would close it |
| `recordSwap`'s pair-proof is removed | **unwatched guard**: no mutant anywhere, unit or invariant. No handler ever offers the Hub a pool that trades other tokens |
| the bridge-residual sweep ignores its baseline | **unwatched guard**: no mutant anywhere. `StrandedRegime` seeds `tokenIn` and `tokenOut` balances but never a pre-existing bridge balance under a multi-hop route |

Two guards with no watcher at all is the number this section exists to print. Both are recorded
as `survived` with their reading in `invariant-mutants.json`, and neither is counted anywhere as
covered; a green suite with an unwatched guard in it was the shape of both documented
regressions in this codebase.

## 4m. Metamorphic relations — a second judge for the maths and for the plan

An oracle written from the same formula cannot catch the formula. A metamorphic relation asks
instead how the output must **move** when the input moves, and the venue's own curve answers
that question without a reference implementation. `test/CoreMetamorphicRelations.t.sol` (2026-09-02,
extended 2026-09-05) holds fourteen relations over the Core's quote maths; `test/RouteMetamorphicRelations.t.sol`
(2026-09-05) holds five over the Solver's plan on a two-pool universe with a real Hub and a real Solver.

| level | relation | what it says |
|---|---|---|
| Core, V2 · V3 · stable | MR1 monotone | more in, never less out |
| Core, V2 · V3 · stable | MR2 sub-additive | splitting an order across the same pool never gains |
| Core, V2 · stable | MR3 no round trip | in, then back on the updated reserves, never returns more than went in |
| Core, V2 · V3 · stable | MR4 scale equivariance | scaling order and pool together scales the output, to rounding |
| Core, V2 · V3 | MR5 fee monotone | a higher fee never pays more |
| Core, V3 | MR6 direction symmetry | at price 1.0 the two arms of `outV3` agree to two ulps |
| Core, Solidly | MR7 identity | the volatile arm **is** `outV2`, one producer |
| plan | MR-R1 | the split never pays less than the best single pool would |
| plan | MR-R2 | monotone in `amountIn` |
| plan | MR-R3 | adding a pool inside the price band never lowers the plan |
| plan | MR-R4 | registration order moves the plan by at most one weight unit of the split |
| plan | MR-R5 | the attested floor never exceeds the expected output |

Three of the bounds were **measured before they were written**, and the number in the assertion is
the mechanism, not the sample:

- **MR6.** At `L = 8.5 × 10³⁷` and 1,374 wei in, the `zeroForOne` arm quoted 1,073,741,823 wei —
  exactly `L / 2⁹⁶`, one ulp of the square-root price — while the other arm quoted 0 (its price
  step rounded to nothing and it failed closed). Both sit inside the §4k bound; the relation now
  states it between the arms: two ulps, one per arm, plus the two output floors.
- **MR-R1 / MR-R3.** With one pool priced 10¹⁰ away from the other, the plan paid 35 % less than
  the outlier alone, and a deep mispriced pool displaced a shallow honest one. That is the Solver's
  median filter (`MEDIAN_FILTER_BPS`, ±5 %) refusing to believe an outlier — the relations hold over
  pools it admits, so the domain keeps the two prices within ±4 %.
- **MR-R4.** Replayed leg by leg: a pool whose depth weight floors to the minimum (1 of 10,000
  against the deepest) is **kept** as a dust leg when it was registered first and **cut** when
  registered second. Both plans are sound; they differ by what one weight unit of the amount earns
  in one pool against the other — observed 3 × 10⁻⁷ of the output. The split's keep-or-cut of a
  minimum-weight pool depends on its position; that is now written down where it was found.

## 4n. N-version: the same source under other code generation

The suite executes one binary — the one the release settings emit, and `profile_parity.py` keeps
the suite on those settings. Every other optimiser setting is a different program compiled from the
same source, and the compiler is a component: a miscompile, or source that only means what it seems
to mean under one setting, is invisible to a suite that runs under that setting alone.

`test/nversion/` compiles the Core's quote maths (`CoreProbe.sol`, an external surface over the
internal library) under two more profiles — `nver1` at `optimizer_runs = 1`, `nver2` at
`20000`, everything else identical to `release` — and `NVersionCore.t.sol` deploys the three
binaries side by side and asserts equality on fuzzed inputs: `outV2`, `outV3`, `outSolidly`,
`outSolidlyStable`, `mulDiv`, `mulDivUp`, 3,000 runs each, over the whole input domain. The lane
first asserts the alternate bytecode **differs** from the shipped one, so it cannot pass by comparing
a program with itself; and `NVERSION_LANE=1` turns a missing artefact from a skip into a failure,
so it cannot pass by never having built anything.

**The three binaries agree.** The compiler was not the finding. The lane's first full-domain run
made the *reference* revert: `outSolidlyStable` on a pool holding under one unit of each token
raised `BPC:mulDiv` instead of quoting zero. The stable curve's domain guards were written for the
seed of Newton's method; the guard that checks whether `k` fits a word divides `max · WAD / b`, and
that division itself overflows once `b < WAD` — a pool with less than one token per side. A second
escape, a whale input reserve against a dust output reserve, passed the `k` check and overflowed the
derivative on the first step. Neither was a wrong number: both were **reverts inside a quote**, and
`universalQuote` is a library `DELEGATECALL`, so the revert unwinds the Solver's whole plan and,
with it, the planned door for the pair. Reach: the curve is the fallback for a pool whose own
`getAmountOut` answers at most 1 wei — a registered pool holding 1 wei of the output token is enough.

The repair replaces the division with the question it was standing in for: `mulDiv` reverts
exactly when the high word of the 512-bit product reaches the divisor, so `_mulFitsWad` computes
that high word (two multiplications, no division) and compares it with one WAD — asked once for
`k` and once for the derivative, at the seed, which is the largest point Newton visits. It cannot
overflow on any input, and it went in red-first: three named tests
(`CoreStableCurveFailsClosed.t.sol`, including the plan-level reach through a real Solver) failed
against the tree before the repair and pass against the tree after it; a 5,000-run fuzz over the full domain and a
60,000-sample sweep of the same arithmetic in Python find no revert; three mutants in the guard
watch the two checks. A further guard — a cap on Newton's iterate — was written first, found to be
unobservable by any test once the two checks hold (its mutant was *decorative*), and removed:
the guard reports it rather than carrying it. The repair is also smaller than the code it replaces. Its class is the one this repository names first — fail-open — found by an
instrument that was not looking for it.

## 4o. The fee rule, both regimes named — and the contract asserting the count

The protocol fee has had one rule since 2026-08-22: charge once, on the input of the first hop
whose input is a bridge coin (or on the output of a direct route into one). It also had a second
regime the rule did not name: a hand-built route through pools the registry would not hold, with
no bridge coin as any hop's input. There the fee hop is never found and the predicate that charges
is true for every hop, so each hop pays on its own measured input — *immunity by exhaustion*. The
register carried it as **FEE-01** ("~56 bps on an honest two-hop route") and the suite pinned it
(`ExhaustionRegimePreviewParity.t.sol`), with the Quoter modelling the same per-hop deduction.

On 2026-09-05 the obvious repair was tried inside the suite: no bridge anywhere → charge once, on
hop 0. It reopened the escape the exhaustion policy exists to close — a value-less first hop
(`FeeEscapeViaJunkPrefix.t.sol`) carries the fee spot onto dust and the real hop pays nothing —
and five pinned tests went red within the same run. The policy stands, and is now **named in the
code** where the predicate is, with the reason. What changed is the assertion of it:

| seal | what it does | where |
|---|---|---|
| both regimes named | the anchored regime pays exactly once, at `feeHop`; the exhaustion regime pays once per hop; the alternative is written down as tried and refused | `_execute`, at the predicate |
| one producer of the commitment | the sum of a hop's declared leg inputs — the fee base at hop 0 and the scale's denominator — is computed by one function, `_legSum`; before, two loops | `_legSum` |
| the run-time ledger | `_payFee` counts into a transient slot; every settlement reads it once and refuses a delivery that paid nothing (`RouterE(15)`) and, on an anchored route, a second payment (`RouterE(16)`), then clears it | `_payFee`, end of `_execute` |

The tests were written to **catch**, not to fit. `test/FeeSeals.t.sol` reads none of the Router's
numbers: the fee token comes from the rule and the bridge list, the base from the pools' balance
deltas (what left the Router into the fee hop, or what the previous hop's pools paid out) or the
recipient's, the fee from the treasuries' deltas, the count from the `Fee` events — over every
shape the Router accepts (one to three hops; bridge in no, first, middle or last position; one or
two legs per hop) on fuzzed amounts, in both regimes. The Router invariant campaign counts `Fee`
events per settlement (`invariant_SettledSwapEmitsExactlyOneFee`).

**How often each test notices each defect** was measured rather than assumed: every fee mutant
(the regime predicate moved two ways, the commitment producer, the ledger's two checks, and the
three fee mutants of §4l) was run under twenty fuzz seeds per fuzzed test, and the detection rate
is published with a Wilson 95 % interval (`docs/assurance/fee-seal-detection.json`):

| mutant | FeeSeals fuzz | Router fee campaign | covering array t=2 | junk-prefix escape | exhaustion preview parity |
|---|---|---|---|---|---|
| exhaustion charges hop 0 only (junk-prefix escape) | 20/20 [0.84, 1.00] | 0/20 [-0.00, 0.16] | no | yes | yes |
| exhaustion skips hop 0 | 20/20 [0.84, 1.00] | 20/20 [0.84, 1.00] | no | yes | yes |
| commitment counts the first leg only | 20/20 [0.84, 1.00] | 0/20 [-0.00, 0.16] | no | no | no |
| BELT ledger: settlement without a fee no longer refused | 0/20 [-0.00, 0.16] | 0/20 [-0.00, 0.16] | no | no | no |
| BELT ledger: anchored double payment no longer refused | 0/20 [-0.00, 0.16] | 0/20 [-0.00, 0.16] | no | no | no |
| fee doubled | 20/20 [0.84, 1.00] | 20/20 [0.84, 1.00] | yes | yes | yes |
| input-side fee never charged | 20/20 [0.84, 1.00] | 20/20 [0.84, 1.00] | no | yes | yes |
| fee charged on both sides | 20/20 [0.84, 1.00] | 20/20 [0.84, 1.00] | no | yes | yes |

Read across a row: which tests see this defect. Read down a column: what a test can and cannot
see. The Router campaign builds direct routes only, so the exhaustion-regime mutants that spare
hop 0 are invisible to it and visible to the every-shape fuzz and the two pinned tests; the
commitment producer only matters on a two-leg hop, which only the every-shape fuzz builds; the
two ledger belts are seen by nothing, as their name says. Twenty seeds at 20/20 bound the miss
probability of one campaign at 15 % (rule of three), which is why the guard runs the named test
and the campaign both.


The ledger's two checks are **belts**: in isolation no test can make them fire, because the
predicate in front of them leaves no path that settles without paying, or pays twice on an
anchored route. They are kept — they are the contract refusing at run time what the tests refuse
at review time, on paths that do not exist yet — listed as belts here, counted as covered nowhere,
and absent from the mutation guard, which admits only mutants a named test kills.

## 4p. How a quote ages — the promise measured against time and drift

A quote is a promise about a future block. `test/QuoteDelayStatistics.t.sol` takes it the way an
integrator does — `previewAndEncode` returns the preview and the calldata — lets the world move
(zero to three trades by someone else through the same pools, each up to 3 % of the shallow
reserve, all in the user's direction so every one of them hurts), lets zero to ten seconds pass,
and executes the calldata unchanged. 240 samples on the three-token universe, every outcome
classified, the guarantees asserted and the distribution printed:

| drift between quote and execution | samples | settled | refused by the floor (`RouterE 5`) | delivered / predicted, mean · min |
|---|---|---|---|---|
| none | 64 | 64 | 0 | 100.00 % · 100.00 % |
| up to 100 bps | 43 | 43 | 0 | 99.52 % · 98.03 % |
| 100 – 300 bps | 133 | 102 | 31 | 99.66 % · 96.53 % |

Bucketed by delay instead (0 s / 1–5 s / 6–10 s) the settle rates are 15/17, 89/99, 105/124 —
the same picture, because time is not what moves a quote: drift is. What is asserted, not
printed: time alone never breaks a quote inside its deadline (drift-free samples settle 100 % at
every delay, delivering exactly the prediction); a settlement never delivers below the floor the
preview attested; nothing is a third way; and after the deadline the refusal is the deadline's
own code (`RouterE 4`, 20 of 20). Under 3 % of adverse drift, one settlement in four is refused
by the floor rather than filled below it, and the ones that fill land within 3.5 % of the
prediction — the sandwich curve of §4j seen from the quote's side.

The same measurement on live Base (`test/fork/QuoteDelayFork.t.sol`, 1,000 USDC → WETH): executed
0, 3, 6 and 10 s later with nothing else moving, the quote delivered exactly its prediction all
four times; with 10,000 to 5,000,000 USDC traded ahead of it and the calldata executed 10 s later,
all five settled inside the floor at 9,999 · 9,998 · 9,994 · 9,974 · 10,000 bps of the prediction.
`test/QuoterGasStatistics.t.sol` and `test/fork/QuoterGasFork.t.sol` price the quote itself through
the ABI as mean, minimum, maximum and spread: on the three-token universe `previewPlan` costs
121,313 gas (σ 1,433) where discovery finds one pool and 235,574 (σ 1,815) where a fresh registry
prices three; `batchQuote` of ten, 205,539 per entry; on live Base 1,524,221 cold, 1,414,633 warm,
1,359,925 cold again — the discovery sweep is about 7 % of a live quote.

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

The per-row detail behind the metrics is not published; the aggregates are. A reader can see
how many rows of each register are answered and how many are not. The rows themselves are a
working list, and publishing the least-exercised surfaces of a financial contract would be an
odd way to protect its users.

Security contact and disclosure policy: see `SECURITY.md`.
