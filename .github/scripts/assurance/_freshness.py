"""Refuse to read an artefact older than the source it claims to be.

Every bytecode check in this directory reads `out/`. An artefact from an earlier build describes
a contract that no longer exists, and a measurement taken from it is a confident statement about
the wrong object - which is the stale-anchor failure this project documents at the source level,
one level further down.

It happened: five bytecode instruments were run against artefacts four hours older than the
sources they were measuring, and every number they produced was about a build from before three
fixes landed. Nothing said so, because the artefacts were present, well-formed and parsed
cleanly. Being readable is not being current.

Import and call `require_fresh(ROOT)` at the top of any script that reads `out/`.
"""
import os, glob, sys

def require_fresh(root, quiet=False):
    srcs = sorted(glob.glob(os.path.join(root, "src", "*.sol")))
    if not srcs:
        return
    newest_src = max(os.path.getmtime(p) for p in srcs)
    arts = sorted(glob.glob(os.path.join(root, "out", "BlazePhoenix*.sol", "*.json")))
    if not arts:
        print("no artefacts in out/ - run `forge build` first; this check is a no-op without one")
        sys.exit(2)
    oldest_art = min(os.path.getmtime(p) for p in arts)
    if oldest_art < newest_src:
        gap = (newest_src - oldest_art) / 60.0
        print(f"STALE ARTEFACTS: out/ is {gap:.0f} minutes older than src/.")
        print("Whatever this would print describes a contract that no longer exists.")
        print("Run `forge build` and try again.")
        sys.exit(2)
    if not quiet:
        print(f"artefacts are current (built after the last source change)")
