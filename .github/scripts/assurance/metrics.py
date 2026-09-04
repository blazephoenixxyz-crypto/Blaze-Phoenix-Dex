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
         ("provenance",      "provenance.py",      "assurance-provenance.json")]

out, failed = {}, []
for label, script, artefact in STEPS:
    r = subprocess.run([sys.executable, os.path.join(HERE, script), ROOT],
                       capture_output=True, text=True)
    if r.returncode != 0:
        failed.append((label, r.stdout.strip().splitlines()[-3:]))
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
print(f"mutation targets     {out['mutation targets']['line']}")
print("=" * 66)
if failed:
    print("\nFAILED CHECKS:")
    for label, tail in failed:
        print(f"  {label}:")
        for l in tail: print("   ", l)
json.dump(out, open(os.path.join(ROOT, "assurance-metrics.json"), "w"), indent=1)
sys.exit(1 if failed or not out["mutation targets"]["ok"] else 0)
