#!/usr/bin/env python3
"""How far each refusal observes from the thing that decides.

THE LAW THIS MEASURES. Every defect this project has confirmed is one shape: a check observes
one object while a DIFFERENT object decides the behaviour. The fee preview modelled what the
executor measured; the volume event published the caller's declaration instead of the flow; the
classifier named the first intermediate while the anchor walked hop inputs; the hook pin commits
to a proxy's dispatcher while the implementation executes. "Absence is permission" is the same
shape with the observed object empty.

So the interesting property of a refusal is not how complicated it is. It is the DISTANCE
between what it reads and what decides:

  IMMUTABLE  a constant, an `immutable`, or a value fixed at construction         - distance 0
  MEASURED   a balance delta or a quantity computed in-frame from one             - distance 0
  DECLARED   a field of the caller's Route/Hop/Leg                                - distance 1,
             UNLESS the declared value is also what selects the object it describes. `leg.hooks`
             is the standing example: the caller names it, and it is also what goes into the V4
             pool key, so the identity holds - but only because one assignment binds them, and
             that assignment had no test until `V4SievedHookIsTheExecutedHook.t.sol`.
  EXTERNAL   a lookup in another contract's mutable storage                       - distance 1
  DELEGATED  a property of a contract that can delegate its behaviour elsewhere   - unbounded;
             `EXTCODEHASH` of a proxy is the canonical case, and the EVM gives no way to close it

WHAT THIS IS NOT. A screen over text, not a proof. It reads the predicate that guards each
`revert` and classifies the identifiers in it; it cannot see that a value was constrained three
frames up, and it cannot decide the `leg.hooks` question for you. It produces a reading list
ordered by how far a refusal looks from its subject, which is the useful shape when the
alternative is reading every guard in five contracts.

Usage: python3 projection_distance.py <repo_root>
"""
import re, os, sys, glob, json, collections

ROOT = sys.argv[1] if len(sys.argv) > 1 else "."

CALLDATA_ROOTS = ("leg", "hop", "route", "legs", "hops", "plan", "params", "p")
MEASURE = re.compile(r"balanceOf|_bal\b|foreignBase|bridgeBase|delta|measured|actual|got\b")
DELEGATED = re.compile(r"\.codehash\b|extcodehash", re.I)


def strip_comments(src):
    src = re.sub(r"/\*.*?\*/", " ", src, flags=re.S)
    return "\n".join(l.split("//")[0] for l in src.splitlines())


def immutables(src):
    """Names the compiler will inline: constants and immutables."""
    out = set()
    for m in re.finditer(r"\b(?:constant|immutable)\s+([A-Za-z_]\w*)", src):
        out.add(m.group(1))
    for m in re.finditer(r"\b([A-Z][A-Z0-9_]{2,})\s*=", src):
        out.add(m.group(1))
    return out


def guard_of(src, pos):
    """The predicate that guards the revert at `pos`: text between the nearest preceding
    `if (` and the revert. Returns '' when the revert is unconditional, which is itself an
    answer - an unconditional revert observes nothing."""
    i = src.rfind("if (", max(0, pos - 400), pos)
    if i < 0:
        return ""
    j, d = i + 3, 0
    while j < pos:
        if src[j] == "(":
            d += 1
        elif src[j] == ")":
            d -= 1
            if d == 0:
                break
        j += 1
    return src[i + 4:j]


def classify(pred, imm):
    kinds = set()
    if not pred.strip():
        return {"UNCONDITIONAL"}
    if DELEGATED.search(pred):
        kinds.add("DELEGATED")
    for m in re.finditer(r"\b([A-Za-z_]\w*)\s*\.\s*(\w+)", pred):
        base, field = m.group(1), m.group(2)
        if base in ("hub", "solver", "mgr", "manager") or base.startswith("I"):
            kinds.add("EXTERNAL")
        elif base.lower() in CALLDATA_ROOTS:
            kinds.add("DECLARED")
    for m in re.finditer(r"\b([A-Za-z_]\w*)\b", pred):
        n = m.group(1)
        if n in imm:
            kinds.add("IMMUTABLE")
    if MEASURE.search(pred):
        kinds.add("MEASURED")
    if not kinds:
        kinds.add("LOCAL")
    return kinds


RANK = {"IMMUTABLE": 0, "MEASURED": 0, "LOCAL": 0,
        "DECLARED": 1, "EXTERNAL": 1, "DELEGATED": 9, "UNCONDITIONAL": 0}

rows = []
for p in sorted(glob.glob(os.path.join(ROOT, "src", "*.sol"))):
    name = os.path.basename(p)[:-4].replace("BlazePhoenix", "")
    src = strip_comments(open(p).read())
    imm = immutables(src)
    for m in re.finditer(r"revert\s+(\w*E)\s*\(\s*(\d+)\s*\)", src):
        pred = guard_of(src, m.start())
        kinds = classify(pred, imm)
        rows.append({"contract": name, "code": f"{m.group(1)}({m.group(2)})",
                     "line": src.count("\n", 0, m.start()) + 1,
                     "kinds": sorted(kinds),
                     "d": max(RANK[k] for k in kinds),
                     "pred": " ".join(pred.split())[:88]})

by_d = collections.Counter(r["d"] for r in rows)
by_kind = collections.Counter(k for r in rows for k in r["kinds"])

print(f"{'CONTRACT':10} {'CODE':12} {'LINE':>6}  {'d':>2}  KINDS")
print("-" * 78)
for r in sorted(rows, key=lambda r: (-r["d"], r["contract"], r["line"])):
    if r["d"] >= 1:
        print(f"{r['contract']:10} {r['code']:12} {r['line']:6}  {r['d']:2}  {','.join(r['kinds'])}")
        print(f"{'':32}{r['pred']}")

print(f"\nrefusal sites read                 : {len(rows)}")
for d in sorted(by_d):
    label = {0: "observes the deciding object", 1: "one indirection away",
             9: "delegated - unbounded"}.get(d, "")
    print(f"  distance {d:<2}                       : {by_d[d]:4}  {label}")
print("\nby what the predicate reads (a site can read more than one):")
for k, c in by_kind.most_common():
    print(f"  {k:14} {c:4}")
print("\nSCREEN, not proof: a value can be constrained out of frame, and a caller-DECLARED field")
print("that also SELECTS the object it describes is at distance 0, not 1 - `leg.hooks` is the")
print("standing example. This ranks reading, it does not decide.")

json.dump({"rows": rows, "by_distance": dict(by_d), "by_kind": dict(by_kind)},
          open(os.path.join(ROOT, "assurance-projection-distance.json"), "w"), indent=1)
