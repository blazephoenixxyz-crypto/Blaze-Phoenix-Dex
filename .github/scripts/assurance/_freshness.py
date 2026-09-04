"""Refuse to read an artefact that was not built from the sources now on disk.

Every bytecode check here reads `out/`. An artefact from an earlier build describes a contract
that no longer exists, and a measurement taken from it is a confident statement about the wrong
object - the stale-anchor failure this project documents at the source level, one level down.

It happened: five instruments ran against artefacts built before three fixes landed, and every
number was about a contract that had ceased to exist. Nothing said so, because the artefacts were
present, well-formed and parsed cleanly. Being readable is not being current.

WHY NOT MODIFICATION TIMES. The first version compared mtimes and produced a false alarm the
first time a `git checkout` rewrote a file with identical content: the build was current and the
guard said otherwise. A guard that cries wolf is worse than none, because the next true alarm is
the one that gets waved away - and that nearly happened here.

WHY NOT THE COMPILER'S OWN HASHES. The artefact records a keccak of each source, and reproducing
it needs the exact byte sequence the compiler read. An attempt to recompute it through the shell
disagreed even for files that had not changed, and the disagreement was mistaken for staleness
for several minutes. A check whose own correctness cannot be established is not a check.

WHAT THIS DOES INSTEAD. It keeps its own stamp: a digest of each source file as of the last time
a build was declared current, written to `out/.assurance-stamp.json`. Self-consistent, needs no
agreement with the compiler's scheme, and both directions are exact.

    python3 -c "from _freshness import stamp; stamp('.')"    after a successful build
    require_fresh(ROOT)                                       at the top of any artefact reader

An unstamped tree is reported as unknown rather than fresh, because assuming freshness is the
failure this file exists to prevent.
"""
import os, glob, json, hashlib, sys

STAMP = "out/.assurance-stamp.json"

def _digests(root):
    out = {}
    for p in sorted(glob.glob(os.path.join(root, "src", "*.sol"))):
        with open(p, "rb") as f:
            out[os.path.relpath(p, root)] = hashlib.sha256(f.read()).hexdigest()[:32]
    return out

def stamp(root="."):
    """Record the current sources as the ones the artefacts in out/ were built from."""
    d = _digests(root)
    os.makedirs(os.path.join(root, "out"), exist_ok=True)
    json.dump(d, open(os.path.join(root, STAMP), "w"), indent=1)
    print(f"stamped {len(d)} sources as current")

def require_fresh(root, quiet=False):
    arts = glob.glob(os.path.join(root, "out", "BlazePhoenix*.sol", "*.json"))
    if not arts:
        print("no artefacts in out/ - run `forge build` first; this check is a no-op without one")
        sys.exit(2)
    p = os.path.join(root, STAMP)
    if not os.path.exists(p):
        print("UNSTAMPED TREE: out/ has artefacts but nothing records which sources built them.")
        print("Run `forge build`, then: python3 .github/scripts/assurance/_freshness.py stamp")
        print("Assuming they are current is the failure this check exists to prevent.")
        sys.exit(2)
    rec, now = json.load(open(p)), _digests(root)
    moved = sorted(k for k in now if rec.get(k) != now[k])
    if moved:
        print(f"STALE ARTEFACTS: {len(moved)} source file(s) changed since the last build:")
        for m in moved:
            print(f"  {m}")
        print("Whatever this would print describes a contract that no longer exists.")
        sys.exit(2)
    if not quiet:
        print("artefacts were built from the sources now on disk")

if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "stamp":
        stamp(sys.argv[2] if len(sys.argv) > 2 else ".")
    else:
        require_fresh(sys.argv[1] if len(sys.argv) > 1 else ".")
