#!/usr/bin/env python3
"""Assurance metrics, computed from the tree and printed as one table.

Five numbers, each defined by a script in this directory, each recomputable from a clean
checkout, and each with a stated way of being gamed. They are published together on purpose:
any one of them read alone can be moved without moving the others, and it is the SET that is
hard to fake.

  threat coverage      classes of exploit answered by a named guard, over classes considered
  relational           quantities with two producers that a named test ties together
  control actions      external state-changing functions whose refusal and lifecycle arms are
                       exercised
  assertion locality   share of mutant/test pairs whose assertion names what the mutant changes
  regime lattice       combinations of world-state, route shape and oracle provenance that some
                       test asserts in, over all such combinations
  guard inventory      refusals in the code that a test drives by their exact code - the
                       BACKWARD direction, from implementation back to evidence
  bytecode             properties of the COMPILED artefact that the source cannot guarantee -
                       forbidden opcodes absent, and the transient lock still transient after
                       the compiler has had its say
  provenance           arithmetic that SUMS terms of different epistemic status - measured,
                       declared, modelled - where the weakest one dominates the result
  branch attribution   how many source conditionals the artefact's own map still points back
                       to - a WATCH, not a coverage figure: it is a fact about the map
  unattributed         what fraction of the SHIPPED runtime traces back to a file in src/,
                       and what fraction is compiler machinery nobody reviews
  profile parity       whether the artefact the suite executes is the artefact that deploys -
                       a suite that ran against a different binary is evidence about a contract
                       nobody will use
  guard reach          named guards that reach an instruction in the SHIPPED artefact - the
                       bytecode half of the traceability chain, which stops at source everywhere
                       else
  constants            declared constants the artefact never pushes: folded away, or dead
  bytecode coverage    what fraction of the SHIPPED runtime bytes the suite executes - the
                       figure over the deployed object rather than over source lines
  panics               the refusal surface we did NOT write - which compiler-generated
                       Panic(uint256) codes the artefact can raise, and which any test asserts
  mutation targets     mutants whose target line still exists exactly once

WHAT MOVES EACH OF THEM THE WRONG WAY, stated so a reader can check for it:

  * threat coverage rises by NARROWING the catalogue. Read it next to the catalogue size, which
    is printed beside it. A rising index and a shrinking denominator is the shape of gaming.
  * relational rises by REMOVING rows. Same defence: the denominator is printed.
  * control actions rise by DELETING an entry point, and the count is printed for that reason.
  * assertion locality rises by writing unit assertions AT each mutated line, which trades
    composition coverage for it. It is a shape measurement, not a quality score; neither
    direction is "better" on its own.
  * regime lattice rises by REMOVING a regime from the catalogue, which is why the number of
    regimes is printed with it. It also rises, honestly, by writing a test in an empty cell -
    which is the only use it has.
  * guard inventory rises by giving two refusals the same error code, which is the opposite of
    what you want: the ambiguous-site count is printed beside it for that reason.
  * bytecode cannot be gamed upward in any useful way, and that is its point: absence of an
    opcode is a real guarantee, while presence proves nothing on its own. It is a floor, and it
    is a no-op on a tree that has not been built.
  * branch attribution cannot be gamed in any direction that means anything, which is why it is
    a watch rather than a target. Its value is the CHANGE: a fall means the compiler started
    treating guards differently, and that is the event worth being told about.
  * unattributed is not a target in either direction. Driving the unmapped fraction down would
    mean hand-writing what the compiler writes better. Its value is the PROPORTION being known
    at all, and a jump in it meaning this build emits materially more machinery than the last.
  * profile parity has one correct value and cannot be gamed: it either holds or the suite is
    evidence about a binary that does not ship.
  * bytecode coverage rises by deleting declarations, which is why the four buckets are printed
    rather than one ratio. It needs an lcov file and is skipped without one.
  * panics cannot be gamed downward except by removing the assumption that produced the guard,
    which is the correct response. A panic no test asserts is not a defect - it is a refusal path
    whose reachability nobody has established in either direction.
  * mutation targets is the only one with a single correct value: anything but 100% means a
    claim in the guard points at code that is gone.

None of them is a probability that the system is correct. There is no such number, and the
literature on validating ultra-high dependability is explicit that testing cannot produce one.
"""
import json, os, subprocess, sys

ROOT = sys.argv[1] if len(sys.argv) > 1 else "."
HERE = os.path.dirname(os.path.abspath(__file__))
STEPS = [("threat coverage", "threat_coverage.py", "assurance-threat-coverage.json"),
         ("relational",      "relational_pairs.py", "assurance-relational.json"),
         ("control actions", "control_actions.py",  "assurance-control-actions.json"),
         ("assertion locality", "assertion_locality.py", "assurance-observable.json"),
         ("regime lattice",  "regime_lattice.py",  "assurance-regime-lattice.json"),
         ("guard inventory", "guard_inventory.py", "assurance-guard-inventory.json"),
         ("bytecode",        "bytecode_invariants.py", "assurance-bytecode.json"),
         ("provenance",      "provenance.py",      "assurance-provenance.json"),
         ("branch attribution", "branch_attribution.py", "assurance-branch-attribution.json"),
         ("unattributed",    "unattributed_code.py", "assurance-unattributed.json"),
         ("profile parity",  "profile_parity.py",  None),
         ("guard reach",     "guard_reaches_chain.py", "assurance-guard-reach.json"),
         ("constants",       "constant_multiplicity.py", "assurance-constants.json"),
         ("panics",          "panic_inventory.py", "assurance-panics.json")]

out, failed = {}, []
for label, script, artefact in STEPS:
    r = subprocess.run([sys.executable, os.path.join(HERE, script), ROOT],
                       capture_output=True, text=True)
    if r.returncode != 0:
        failed.append((label, r.stdout.strip().splitlines()[-3:]))
    if artefact is None:
        out[label] = {"ok": r.returncode == 0}
        continue
    p = os.path.join(ROOT, artefact)
    if os.path.exists(p):
        out[label] = json.load(open(p))

r = subprocess.run([sys.executable, os.path.join(ROOT, ".github/scripts/check_targets.py")],
                   capture_output=True, text=True, cwd=ROOT)
out["mutation targets"] = {"ok": r.returncode == 0, "line": r.stdout.strip()}

t, rel, ca, loc = (out.get("threat coverage", {}), out.get("relational", {}),
                   out.get("control actions", {}), out.get("assertion locality", {}))
lat = out.get("regime lattice", {})
gi  = out.get("guard inventory", {})
bc  = out.get("bytecode", {})
pv  = out.get("provenance", {})
ba  = out.get("branch attribution", {})
ua  = out.get("unattributed", {})
pp  = out.get("profile parity", {})
grx = out.get("guard reach", {})
cst = out.get("constants", {})
pan = out.get("panics", {})
print("=" * 66)
print("ASSURANCE METRICS")
print("=" * 66)
print(f"threat coverage      {t.get('blocked','?')}/{t.get('considered','?')} classes answered by a named guard")
print(f"relational           {rel.get('tied','?')}/{rel.get('pairs','?')} two-producer quantities tied by a test")
print(f"control actions      refusal {ca.get('refusal','?')}/{ca.get('actions','?')}, "
      f"lifecycle {ca.get('lifecycle','?')}/{ca.get('actions','?')}")
print(f"assertion locality   {loc.get('local','?')}/{loc.get('mutants','?')} pairs assert at the change")
print(f"regime lattice       {lat.get('cells',0)-lat.get('empty',0)}/{lat.get('cells','?')} cells "
      f"some test asserts in, over {lat.get('regimes','?')} regimes")
print(f"                     {lat.get('cross_multi_on_empty','?')}/{lat.get('regimes','?')} regimes have no "
      f"composed cross-producer assertion when set")
print(f"guard inventory      {gi.get('driven','?')}/{gi.get('codes','?')} refusal codes driven exactly; "
      f"{gi.get('ambiguous_sites','?')}/{gi.get('sites','?')} sites share a code")
print(f"bytecode             {bc.get('artefacts','?')} artefacts, "
      f"{len(bc.get('problems',[]))} invariants broken")
print(f"provenance           {pv.get('mixed','?')} mixed sums; "
      f"{pv.get('by_kind',{}).get('MEASURED + MODELLED',0)} where a model meets a measurement")
print(f"branch attribution   {ba.get('with_branch','?')}/{ba.get('conditionals','?')} source "
      f"conditionals mapped to a branch in the artefact")
_t = ua.get("totals", {})
_g = sum(_t.values()) or 1
print(f"unattributed         {ua.get('ours_fraction','?')} of shipped runtime traces to src/; "
      f"{_t.get('UNMAPPED','?')} bytes are compiler machinery")
print(f"profile parity       {'one binary - the suite ran against what deploys' if pp.get('ok') else 'DIVERGED - the suite tested a binary that does not ship'}")
print(f"guard reach          {grx.get('reaching','?')}/{grx.get('guards','?')} named guards reach the shipped artefact")
print(f"constants            {len(cst.get('never_pushed',[]))} declared constants the artefact never pushes")
print(f"panics               {len(pan.get('codes',[]))} compiler panic codes reachable; "
      f"{len(pan.get('unasserted',[]))} asserted by no test")
print(f"mutation targets     {out['mutation targets']['line']}")
print("=" * 66)
if failed:
    print("\nFAILED CHECKS:")
    for label, tail in failed:
        print(f"  {label}:")
        for l in tail: print("   ", l)
json.dump(out, open(os.path.join(ROOT, "assurance-metrics.json"), "w"), indent=1)
sys.exit(1 if failed or not out["mutation targets"]["ok"] else 0)
