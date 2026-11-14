#!/usr/bin/env python3
"""The binary the suite runs against must be the binary that ships.

A test suite is evidence about the artefact it executed. If the profile used for testing and the
profile used for the release build differ in any setting that reaches code generation, then the
suite is evidence about a contract that will never be deployed, and the deployed one has never
been executed by a single test.

That was true here. The suite ran at one optimizer setting and the release build at another, and
nothing said so: both jobs were green, both were required, and neither was wrong on its own
terms. The release job built the shipped binary and only measured its SIZE.

The repair is not a second test run. It is to stop having two binaries: the settings are now
identical, so the artefact the suite executes IS the artefact that deploys. This script exists
to keep it that way, because a divergence reintroduced later would be invisible again - somebody
tunes one profile for a size margin, every check stays green, and the evidence quietly detaches
from the thing it is evidence about.

Settings that reach code generation, and are therefore compared: solc version, EVM version,
optimizer on/off, optimizer runs, the IR pipeline, the optimizer details (the Yul step sequence
lives there: a profile that changes it builds another program from the same source), the
bytecode hash and the CBOR metadata (both are bytes of the shipped object), the revert strings
(stripped or kept, they are bytes of the object too), and the two settings that compile ONE FILE
on other settings than its profile's: `compilation_restrictions` and the
`additional_compiler_profiles` they select from. Those two are how a profile keeps every key above
on its pin and still ships another binary: a restriction on src/BlazePhoenixRouter.sol in the
release profile alone built a Router of 23757 bytes where the suite had executed one of 23779, and
this script said there was one binary (measured 2026-11-10). Fuzzing and invariant parameters are
not compared: they change how the suite is run, not what it is run against.

Parity alone is relative: if both profiles drift together (runs 200 -> 199 in each, a solc bump
in each), every comparison still agrees. So the default is also pinned to ABSOLUTE values below,
and a deliberate change edits PINNED in the same commit. Two blind spots of the toml close with
it: a typo inside optimizer_details.yulDetails is dropped by forge in silence (no warning, the
effective config shows an empty yulDetails), and any optimizer_details at all differs from the
pinned absence; a key left out of the toml takes forge's default, which moves with the forge
release (the CI does not pin forge), and `--effective` reads what forge actually resolved.

One instrument setting is pinned too, though it generates no code: `isolate`. It decides what a
gasleft() delta around a top-level call measures (the transaction's total, or execution alone)
and whether transient storage survives from one top-level call to the next, which is the rule
the transient-lock tests are written on (test/GasInstrumentMode.t.sol observes it).

Usage: python3 profile_parity.py <repo_root> [--effective]
       python3 profile_parity.py --self-test
"""
import json, os, subprocess, sys, tomllib

# profiles whose output is executed or deployed. `smt` is a model-checker profile that produces
# no artefact anyone runs, and the nver* profiles are the N-version lane's deliberate other
# binaries (test/nversion), so they are out of scope.
COMPARED = ["default", "release"]
KEYS = ["solc_version", "evm_version", "optimizer", "optimizer_runs", "via_ir",
        "optimizer_details", "bytecode_hash", "cbor_metadata",
        "additional_compiler_profiles", "compilation_restrictions", "revert_strings"]
# Absolute values, for both compared profiles. None = the key is absent from the toml.
PINNED = {"solc_version": "0.8.36", "evm_version": "cancun", "optimizer": True, "optimizer_runs": 200,
          "via_ir": True, "optimizer_details": None, "bytecode_hash": "none", "cbor_metadata": None,
          "additional_compiler_profiles": None, "compilation_restrictions": None, "revert_strings": None,
          "isolate": True}
# What forge resolves for the same pin (`forge config --json`): absent keys read as its defaults.
EFFECTIVE = {"solc": "0.8.36", "evm_version": "cancun", "optimizer": True, "optimizer_runs": 200,
             "via_ir": True, "optimizer_details": None, "bytecode_hash": "none", "cbor_metadata": True,
             "additional_compiler_profiles": [], "compilation_restrictions": [], "revert_strings": None,
             "isolate": True}


def problems(text):
    """Every way the toml `text` lets the tested binary differ from the shipped one, or from the pin."""
    prof = tomllib.loads(text).get("profile", {})
    out = [f"profile not found in foundry.toml: {p}" for p in COMPARED if p not in prof]
    if out:
        return out
    for k in KEYS:
        vals = {p: prof[p].get(k) for p in COMPARED}
        if len({json.dumps(v, sort_keys=True) for v in vals.values()}) > 1:
            out.append(f"{k} differs: " + ", ".join(f"{p}={json.dumps(v)}" for p, v in vals.items()))
    for p in COMPARED:
        for k, want in PINNED.items():
            got = prof[p].get(k)
            if got != want:
                out.append(f"{p}.{k} = {json.dumps(got)}, pinned {json.dumps(want)}")
    return out


def effective(root):
    """The settings forge resolved for each compared profile, against EFFECTIVE."""
    out = []
    for p in COMPARED:
        r = subprocess.run(["forge", "config", "--json"], cwd=root, capture_output=True, text=True,
                           env={**os.environ, "FOUNDRY_PROFILE": p})
        if r.returncode != 0:
            return [f"forge config failed under {p}: {r.stderr.strip()[:200]}"]
        cfg = json.loads(r.stdout)
        for k, want in EFFECTIVE.items():
            if cfg.get(k) != want:
                out.append(f"effective {p}.{k} = {json.dumps(cfg.get(k))}, pinned {json.dumps(want)}")
    return out


def self_test(root):
    """Each mutant of the toml must be red, and the toml as committed must be green."""
    base = open(os.path.join(root, "foundry.toml")).read()
    sec = lambda t, p: t.index(f"[profile.{p}]\n") + len(f"[profile.{p}]\n")
    def put(t, p, line):
        i = sec(t, p)
        return t[:i] + line + "\n" + t[i:]
    def sub_in(t, p, old, new):
        i = sec(t, p)
        j = t.index(old, i)
        return t[:j] + new + t[j + len(old):]
    def both(t, old, new):
        n = t.count(old)
        return t.replace(old, new), n
    noF = 'optimizer_details = { yul = true, yulDetails = { optimizerSteps = "dhfoDgvulfnTUtnIf:fDnTOcmu" } }'
    typo = 'optimizer_details = { yul = true, yulDetails = { optimizerStep = "dhfoDgvulfnTUtnIf:fDnTOcmu" } }'
    restr = 'compilation_restrictions = [{ paths = "src/BlazePhoenixRouter.sol", optimizer_runs = 1 }]'
    extra = 'additional_compiler_profiles = [{ name = "tight", optimizer_runs = 1 }]'
    runs, nr = both(base, "optimizer_runs = 200\n", "optimizer_runs = 199\n")
    solc, ns = both(base, 'solc_version = "0.8.36"\n', 'solc_version = "0.8.38"\n')
    mutants = {
        "runs 200->199 in every profile": (runs, nr >= 2),
        "solc 0.8.36->0.8.38 in every profile": (solc, ns >= 2),
        "noF optimizer steps in release only": (put(base, "release", noF), True),
        "typo inside yulDetails, in both profiles": (put(put(base, "default", typo), "release", typo), True),
        "bytecode_hash ipfs in release": (sub_in(base, "release", 'bytecode_hash = "none"', 'bytecode_hash = "ipfs"'), True),
        "cbor_metadata off in release": (put(base, "release", "cbor_metadata = false"), True),
        "isolate dropped from default": (base.replace("isolate = true\n", "", 1), "isolate = true\n" in base),
        "a per-file compilation restriction in release only": (put(base, "release", restr), True),
        "an additional compiler profile in release only": (put(base, "release", extra), True),
        "revert strings stripped in release only": (put(base, "release", 'revert_strings = "strip"'), True),
    }
    bad = []
    if problems(base):
        bad.append("the committed foundry.toml is not green: " + "; ".join(problems(base)))
    for name, (text, applies) in mutants.items():
        if not applies or text == base:
            bad.append(f"mutant did not apply: {name}")
        elif not problems(text):
            bad.append(f"mutant passed (should be red): {name}")
    for b in bad:
        print(f"::error::profile parity self-test: {b}")
    print(f"profile parity self-test: {len(mutants)} mutants, {len(mutants) - len(bad)} red as they must be")
    sys.exit(1 if bad else 0)


def main():
    args = sys.argv[1:]
    if args[:1] == ["--self-test"]:
        self_test(args[1] if len(args) > 1 else ".")
    root = next((a for a in args if not a.startswith("--")), ".")
    text = open(os.path.join(root, "foundry.toml")).read()
    prof = tomllib.loads(text).get("profile", {})
    w = max(len(k) for k in KEYS + list(PINNED))
    print(f"{'SETTING':{w}}  " + "  ".join(f"{p:>12}" for p in COMPARED) + f"  {'PINNED':>12}")
    print("-" * (w + 2 + 14 * (len(COMPARED) + 1)))
    for k in dict.fromkeys(KEYS + list(PINNED)):
        row = "  ".join(f"{str(prof.get(p, {}).get(k)):>12}" for p in COMPARED)
        print(f"{k:{w}}  {row}  {str(PINNED.get(k, '-')):>12}")
    bad = problems(text) + (effective(root) if "--effective" in args else [])
    if bad:
        print(f"\n{len(bad)} setting(s) let the binary the suite executes differ from the one that deploys,")
        print("or moved off the pinned values without the pin moving with them:")
        for b in bad:
            print(f"  {b}")
        sys.exit(1)
    print("\nEvery code-generating setting agrees and sits on its pin: the artefact the suite executes is")
    print("the artefact that deploys. There is one binary, and the tests ran against it.")


if __name__ == "__main__":
    main()
