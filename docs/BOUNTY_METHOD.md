# How a report is handled

This is the working method behind the bounty terms in [`SECURITY.md`](../SECURITY.md): what
happens to a report from the moment it arrives to the moment a name goes into the Hall of Fame.
It exists so that a researcher can predict the outcome of their work before doing it, and check
afterwards that the process was followed.

---

## 1. Receipt

Reports arrive privately — **contact@blazephoenix.xyz**, or a DM — and are acknowledged within
72 hours. A report is read against the current `main`, not only against the commit it cites; if
the two differ in a way that matters, the delta is stated in the reply with the commit that made
it, so nobody is told "already fixed" without being able to check.

Everything that follows happens in private until a fix is merged. Fix branches are not public
before the fix is: an unmerged fix branch is a map to a live defect.

## 2. Reproduction before verdict

The first thing done with a report is not to read the code for a rebuttal. It is to turn the
claim into a **forge test that fails against the unfixed tree**. If the researcher supplied a
proof of concept, it is run as delivered, then rewritten against our harness so that it asserts
the exact effect (a balance, a floor rate, a registry word, an error selector) rather than a
symptom.

If the test goes red, the finding is confirmed regardless of what anyone expected. If it does
not, the reply contains the experiment — the test, the fixture, the block — so the researcher can
see precisely where the claim and the code part ways, and can come back with the missing piece.

## 3. Verdicts

Every report receives exactly one of these, in writing, with the evidence for it:

| Verdict | What it means | What the reply contains |
|---|---|---|
| **Confirmed** | the red test exists and the fix makes it green | the property named, the test, the mutant |
| **Confirmed, already known** | the defect was in our records before the report | the dated evidence: a commit, a merged test, or a dated note |
| **Duplicate** | another report reached us first | the timestamp of the earlier report (never its author) |
| **Refuted** | the experiment does not reproduce the claim | the experiment |
| **Out of scope** | outside the contracts named in the policy | the reason |
| **Derivative credit** | the report itself does not stand, but its question led us to a finding of our own | the finding it caused, credited to the reporter |

Duplicates and prior knowledge cut **both ways**. When we fixed something before the report, we
say so and show the commit. When the report predates our fix — even by hours, even if we were
already working on it — the credit is the researcher's. The clock is the report's timestamp, not
ours.

**Derivative credit** is the verdict researchers most often do not expect. A report that is
technically wrong can still force a test that nobody had written, and that test can find
something. When it does, the researcher who asked the question is credited for the answer,
because without the question there would have been no test.

## 4. Severity

Severity is our assessment, and the reasoning is written down. The reply states the tier, the
number, and why — impact, preconditions, what capital or privilege the attack needs, and whether
the path is reachable on the deployed generation. Where we disagree with the reporter's rating we
say why rather than silently downgrading.

Two rules that follow from taking the rubric seriously:

- A finding is never reclassified to make a number fit. If a Low deserves more than the Low
  ceiling, it is paid above the ceiling and written as a Low paid above the ceiling.
- The tier is decided by the **effect demonstrated**, not by the language of the report. A
  Critical is a demonstrated direct theft or permanent freeze of user funds, and no confirmed
  finding in the programme's history has reached that line — a fact you can check against the
  tests that pin each one.

## 5. What is paid

- **The base** is the tier's published band, applied from the midpoint upward.
- **A quality bonus** is added for a proof of concept that reproduces as delivered, for a fix
  diff we can use, and for a report that corrects a belief of ours rather than only a line of
  code.
- **Awards are floors.** An award may be revised upward until the programme closes and settles;
  it is never revised downward, and a researcher does not need to ask for a revision.
- Awards are paid in BZPX on the schedule stated in `SECURITY.md`.

## 6. What happens after

A confirmed finding does not end with a fix. It ends with four artefacts, in this order:

1. **A named property** — the sentence the finding falsified, now stated positively.
2. **A regression test** that fails against the pre-fix code and passes with it.
3. **A mutant** in the curated guard, paired with that test, verified killed.
4. **A register row** — in `SHARED_QUANTITIES.md`, `docs/assurance/fields.json` or the threat
   catalogue — so that the class, not only the instance, is tracked from then on.

Then the name goes into [`SECURITY_HALL_OF_FAME.md`](../SECURITY_HALL_OF_FAME.md), with the
researcher's consent, as a name and nothing else. Technical detail stays in the verified source
and in our private records; a credits page is not the place to publish an attack.

## 7. What makes a strong report

The reports that moved fastest through this process shared four things:

- **`file:line` against a named commit**, so the claim can be located without interpretation;
- **a forge test**, or the exact sequence of calls, so reproduction is a run rather than a
  reconstruction;
- **the effect in numbers** — how much, from whom, under what preconditions;
- **the invariant it breaks**, in the words of the policy or of the code's own comments.

A report that arrives with the delta of its own fix is credited for the fix as well as the
finding. A report that names the *class* — "this is the same shape as X, here is the second
door" — is worth more than one that names an instance, and is paid as such.

## 8. What is not published

The per-row detail behind the assurance metrics is not published; the aggregates are. The
Hall of Fame is names only. Researcher wallets and contact
details never enter the repository.

## 9. Checking that this was followed

Every verdict in §3 leaves a public trace a researcher can verify: a merged test whose header
names the finding, a mutant in `mutants.py`, a register row, and a name in the Hall of Fame. The
researcher count in `SECURITY.md` is derived from that file, not the other way round. If a step is
missing, say so at the address above; that is a defect in the process and is handled like any
other.

---

Related: [`SECURITY.md`](../SECURITY.md) · [`docs/AUDIT_METHOD.md`](AUDIT_METHOD.md) ·
[`SECURITY_HALL_OF_FAME.md`](../SECURITY_HALL_OF_FAME.md) · [`CONTRIBUTING.md`](../CONTRIBUTING.md)
