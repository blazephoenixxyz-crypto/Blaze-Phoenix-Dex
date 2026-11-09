#!/usr/bin/env python3
"""Every shipped contract's size, written down: a byte that moves is a byte somebody meant to move.

The size guard (ci.yml, size-guard) only fails at the 24,000-byte margin, so a change that adds
300 B to the Router passes in silence until the day one more feature does not fit, and nobody can
say which commit spent the margin. `.sizes-snapshot` records the runtime and initcode size of
every contract compiled from src/ under the release profile, one line each, the way
`.gas-snapshot` records gas: `check` fails on any difference, in either direction, and names the
contract and the delta; `update` rewrites the file, in the same commit as the change that moved
the bytes, so the diff of the snapshot is the review of the size.

Sizes are read from the artefacts `forge build` writes (out/), not estimated from the source:
runtime = deployedBytecode, initcode = bytecode, both as forge --sizes counts them (immutables and
link placeholders at their full width). Interfaces and abstract contracts have no code and are
not listed.

Usage: python3 sizes_snapshot.py check  [repo_root]     (after FOUNDRY_PROFILE=release forge build)
       python3 sizes_snapshot.py update [repo_root]
       python3 sizes_snapshot.py --self-test
"""
import json, os, sys

SNAP = ".sizes-snapshot"


def measured(root):
    """{contract: (runtime, initcode)} for every contract with code whose source is in src/."""
    out, src = {}, os.path.join(root, "src")
    for dirpath, _, files in os.walk(src):
        for f in sorted(files):
            if not f.endswith(".sol"):
                continue
            rel = os.path.relpath(os.path.join(dirpath, f), root)
            d = os.path.join(root, "out", f)
            for j in sorted(os.listdir(d)) if os.path.isdir(d) else ():
                art = json.load(open(os.path.join(d, j)))
                target = (art.get("metadata") or {}).get("settings", {}).get("compilationTarget", {})
                if target and rel not in target:
                    continue            # the same file name under another directory
                rt = art.get("deployedBytecode", {}).get("object", "")[2:]
                ic = art.get("bytecode", {}).get("object", "")[2:]
                if rt:
                    out[j[:-len(".json")]] = (len(rt) // 2, len(ic) // 2)
    return out


def render(sizes):
    return "".join(f"{c} runtime={r} initcode={i}\n" for c, (r, i) in sorted(sizes.items()))


def parse(text):
    out = {}
    for line in text.splitlines():
        if line.strip():
            c, r, i = line.split()
            out[c] = (int(r.split("=")[1]), int(i.split("=")[1]))
    return out


def compare(snap, now):
    bad = []
    for c in sorted(set(snap) | set(now)):
        if c not in now:
            bad.append(f"{c}: in {SNAP}, not built (removed or renamed?)")
        elif c not in snap:
            bad.append(f"{c}: built, not in {SNAP} (runtime {now[c][0]}, initcode {now[c][1]})")
        elif snap[c] != now[c]:
            (r0, i0), (r1, i1) = snap[c], now[c]
            bad.append(f"{c}: runtime {r0} -> {r1} ({r1 - r0:+d}), initcode {i0} -> {i1} ({i1 - i0:+d})")
    return bad


def self_test():
    base = {"BlazePhoenixRouter": (23779, 25000), "BlazePhoenixGateWrapper": (3962, 4477)}
    snap = parse(render(base))
    cases = {
        "runtime +1 byte": {**base, "BlazePhoenixRouter": (23780, 25000)},
        "runtime -1 byte": {**base, "BlazePhoenixRouter": (23778, 25000)},
        "initcode only": {**base, "BlazePhoenixGateWrapper": (3962, 4478)},
        "a contract disappears": {"BlazePhoenixRouter": (23779, 25000)},
        "a new contract": {**base, "BlazePhoenixNew": (1, 2)},
    }
    bad = [] if not compare(snap, base) else ["the snapshot does not match the sizes it was rendered from"]
    bad += [f"passed (should be red): {n}" for n, now in cases.items() if not compare(snap, now)]
    for b in bad:
        print(f"::error::sizes snapshot self-test: {b}")
    print(f"sizes snapshot self-test: {len(cases)} mutants, {len(cases) - len(bad)} red as they must be")
    sys.exit(1 if bad else 0)


def main():
    a = sys.argv[1:]
    if a[:1] == ["--self-test"]:
        self_test()
    if not a or a[0] not in ("check", "update"):
        sys.exit(__doc__)
    root = a[1] if len(a) > 1 else "."
    now = measured(root)
    if not now:
        sys.exit("no artefacts under out/ for src/: run `FOUNDRY_PROFILE=release forge build` first")
    path = os.path.join(root, SNAP)
    if a[0] == "update":
        open(path, "w").write(render(now))
        print(f"{SNAP}: {len(now)} contracts written")
        return
    bad = compare(parse(open(path).read()) if os.path.exists(path) else {}, now)
    if bad:
        print(f"{len(bad)} contract(s) moved off {SNAP}. If the change is meant, run "
              f"`python3 .github/scripts/assurance/sizes_snapshot.py update` and commit the file with it:")
        for b in bad:
            print(f"  {b}")
        sys.exit(1)
    print(f"{len(now)} contracts: every runtime and initcode size is the one in {SNAP}.")


if __name__ == "__main__":
    main()
