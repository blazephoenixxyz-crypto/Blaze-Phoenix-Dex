#!/usr/bin/env python3
"""A LOWER bound on how much of the shipped instruction stream the suite executes.

bytecode_coverage.py reports an UPPER bound: an instruction counts as covered because the
LINE it belongs to ran, so a line holding an untaken branch still contributes its bytes.
Its closing sentence asks for the other side, and this is it.

WHERE THE EVIDENCE COMES FROM, AND WHY IT IS NOT TAKEN AT FACE VALUE

`forge coverage --report bytecode` writes one disassembly per contract with a hit count in
front of some instructions. It is tempting to read that as per-instruction execution. It is
not, and the file says so if asked: on this repository 25.7% of the marked instructions have
an UNMARKED straight-line successor, which control flow forbids - if a JUMPDEST executed, the
PUSH after it executed too. The marks are the hit counts of foundry's SOURCE-LEVEL coverage
items (Line/Statement/Branch/Function), each pinned to the one instruction that anchors it.
Everything else in the same statement is left blank, and a zero count is never printed at
all, so a blank means "not an anchor" OR "an anchor that never ran" and the two cannot be
told apart. No percentage can be read off that file directly.

What the marks DO support is one direction: an instruction carrying a positive count ran.
So take them as a seed and close it under the two successors execution forces:

    * a non-terminator is always followed by its neighbour;
    * `PUSH <const>` immediately before a `JUMP` forces control to that JUMPDEST, because the
      JUMP consumes exactly the constant the PUSH left.

JUMPI is deliberately NOT followed: neither arm is implied by reaching the branch. The result
is a subset of what really ran. Its size over the instruction count is a lower bound, never an
estimate, and the report prints the residual control-flow violations so the claim is checkable:
they must be zero.

THE SELF-TEST. An instrument is worth nothing until it finds an instance already known by
another route. `test/PcCoverageGroundTruth.t.sol` deploys a contract with one function the
suite calls and two it never calls. Run this with `--check` and it fails unless the closure
covers the called one and leaves BOTH uncalled ones at exactly zero instructions. That check
has caught the failure mode that matters here - a closure rule that leaks into code that never
ran would silently inflate every number below.

WHAT THE REPORT ACTUALLY HANDS BACK, established rather than guessed. The second probe
(`test/PcCoverageImmutableProbe.t.sol`) deploys ONE contract TWICE with different values in an
immutable, and calls only the first instance. The disassembly comes back carrying the SECOND
instance's tag - the one never called - while the annotation marks the called instance's
function as reached. So the listing and the annotation are two different objects: the hit map
is merged across every deployment by source item, and the disassembly is ONE ARBITRARY
DEPLOYED INSTANCE. Not the artefact - a deployed instance, immutables patched, chosen by hash
order.

That is the whole mechanism, and it predicts exactly which contracts move: the ones the suite
deploys many times. Every fixture builds its own Hub and Router; Core, Quoter and Solver are
built far less. So the figure below is a lower bound on the union of what all deployments
executed, laid over one instance's layout - NOT a measurement of the shipped artefact, whose
immutables differ from any test instance.

THE INPUT IS NOT STABLE, AND THAT BOUNDS WHAT MAY BE CITED. Two runs of the identical tree
with the same `--fuzz-seed` do not produce the same listings. Core, Quoter and Solver came back
byte-identical in their instruction stream; Router and Hub did not - same instruction COUNT and
same per-source line attribution, but a different total byte span (0xa741 vs 0xa769) and a
different head, one run opening on the runtime dispatcher and the next on a constructor's
CALLVALUE guard. The two contracts that moved are the two built with constructor arguments.
Consequence: the PER-CONTRACT rows below are printed for shape and must not be cited, because
the same name did not describe the same object twice. The aggregate moved 0.3 points across two
pinned-seed runs (85.9% and 86.2%), and the figure to quote is the LOWEST one observed, since
every run's closure is a subset of what that run executed. `--compare <other dir>` reports the
spread directly, and any report of this number should say how many runs it rests on.

CAVEAT, and it is not small. Coverage builds with `--ir-minimum`, so these instructions are a
DIFFERENT binary from the release artefact: same sources, different optimiser, roughly twice
the size. This bounds the coverage build, and the bridge to the shipped object is by source
item, not by byte. Read it beside profile_parity.py, not instead of it.

Usage: python3 pc_coverage.py <bytecode-coverage dir> [repo root] [--check] [--compare=<dir>]
  Produce the input with: forge coverage --ir-minimum --report bytecode
"""
import os, re, sys, json, glob

SHIPPED = ["BlazePhoenixCore", "BlazePhoenixQuoter", "BlazePhoenixSolver",
           "BlazePhoenixRouter", "BlazePhoenixHub"]
PROBES = [
    # (artefact name, source file, the function the suite calls, the functions it never calls)
    ("PcCoverageProbeTarget", "test/PcCoverageGroundTruth.t.sol",
     "touched", ("untouched", "alsoUntouched")),
    # The second probe has a constructor argument stored in an immutable, which is the shape
    # the first probe lacked and the shape of the two contracts whose listings moved.
    ("PcCoverageImmutableProbe", "test/PcCoverageImmutableProbe.t.sol",
     "touchedImm", ("untouchedImm",)),
]
# Patched into the immutable probe's RUNTIME code at deployment. An artefact carries a zero
# placeholder here; a deployed instance carries the real number. Which of these appears in the
# disassembly says which object the report handed back, with no inference.
TAGS = {"c0ffee01": "deployed instance A", "c0ffee02": "deployed instance B"}
TERM = {"JUMP", "JUMPI", "STOP", "RETURN", "REVERT", "INVALID", "SELFDESTRUCT"}
LINE = re.compile(r'^(?:\[(\d+)\] |      )([0-9a-f]{8}): (\S+)(?:\s+(0x[0-9a-f]+))?')


def parse(path):
    rows = []
    for ln in open(path):
        m = LINE.match(ln)
        if not m:
            continue
        rows.append(dict(hits=int(m.group(1)) if m.group(1) else None,
                         pc=int(m.group(2), 16), op=m.group(3),
                         imm=int(m.group(4), 16) if m.group(4) else None,
                         src=ln.split("// ", 1)[1].strip() if "// " in ln else ""))
    return rows


def runtime_base(rows):
    """Where the RUNTIME object starts inside the listing, and how sure we are.

    `forge coverage --report bytecode` does not always hand back a bare runtime object: four of
    the five artefacts in this repository come back as CREATION code, with the runtime appended
    after the constructor's `CODECOPY; RETURN` and a one-byte `INVALID` pad. Jump targets inside
    that runtime are relative to ITS start, not to file PC 0 - so resolving `PUSH <const>; JUMP`
    at base 0 drops almost every real edge and follows a handful of spurious ones that happen to
    land on a JUMPDEST. A spurious edge marks an instruction as CERTAINLY EXECUTED when it may
    never have run, which turns the lower bound below into no bound at all.

    The base is derived, then CHECKED: whichever candidate makes more `PUSH; JUMP` targets land
    on a real JUMPDEST wins, and the winning rate is reported so a bad guess is visible rather
    than silent. On this repository the difference is not subtle - about 10% of targets resolve
    at base 0 against 99.9% at the true base."""
    by_pc = {r["pc"]: i for i, r in enumerate(rows)}
    targets = [rows[i - 1]["imm"] for i in range(1, len(rows))
               if rows[i]["op"] == "JUMP" and rows[i - 1]["op"].startswith("PUSH")
               and rows[i - 1]["imm"] is not None]
    if not targets:
        return 0, 1.0
    def rate(b):
        ok = sum(1 for t in targets
                 if (t + b) in by_pc and rows[by_pc[t + b]]["op"] == "JUMPDEST")
        return ok / len(targets)
    cand = [0]
    # Two independent readings of the same boundary, both checked against the rate below.
    # (a) the constructor's `CODECOPY` is fed the runtime's offset two instructions earlier:
    #     `PUSH2 <len>; PUSH2 <base>; DUP3; CODECOPY`.
    for i, r in enumerate(rows):
        if r["op"] == "CODECOPY" and i >= 3 and rows[i - 3]["imm"] is not None:
            cand.append(rows[i - 3]["imm"])
        if r["op"] == "CODECOPY" and i >= 2 and rows[i - 2]["imm"] is not None:
            cand.append(rows[i - 2]["imm"])
    # (b) solc pads one INVALID byte between the constructor and the runtime object.
    ret = next((i for i, r in enumerate(rows) if r["op"] == "RETURN"), None)
    if ret is not None:
        inv = next((j for j in range(ret + 1, len(rows)) if rows[j]["op"] == "INVALID"), None)
        if inv is not None and inv + 1 < len(rows):
            cand.append(rows[inv + 1]["pc"])
    best = max(cand, key=rate)
    return best, rate(best)


def close(rows):
    """Everything the seed forces. Returns (seed, closure)."""
    by_pc = {r["pc"]: i for i, r in enumerate(rows)}
    base, _ = runtime_base(rows)
    seed = {i for i, r in enumerate(rows) if r["hits"] is not None}
    marked, work = set(seed), list(seed)
    while work:
        i = work.pop()
        nxt = []
        if rows[i]["op"] not in TERM and i + 1 < len(rows):
            nxt.append(i + 1)
        if rows[i]["op"] == "JUMP" and i and rows[i - 1]["op"].startswith("PUSH") \
                and rows[i - 1]["imm"] is not None:
            t = by_pc.get(rows[i - 1]["imm"] + base)
            if t is not None and rows[t]["op"] == "JUMPDEST":
                nxt.append(t)
        for j in nxt:
            if j not in marked:
                marked.add(j)
                work.append(j)
    return seed, marked


def violations(rows, marked):
    """Marked, non-terminating instructions whose neighbour is unmarked. Must be zero."""
    bad = tot = 0
    for i in marked:
        if i + 1 < len(rows) and rows[i]["op"] not in TERM:
            tot += 1
            bad += (i + 1) not in marked
    return bad, tot


def _spans(src_path):
    """(start, end) line of each function body in the probe source, by brace matching."""
    src = open(src_path).read()
    lines = src[:].splitlines()
    out = {}
    for m in re.finditer(r"function\s+(\w+)\s*\(", src):
        i = src.find("{", m.end())
        if i < 0:
            continue
        d, j = 0, i
        while j < len(src):
            if src[j] == "{":
                d += 1
            elif src[j] == "}":
                d -= 1
                if d == 0:
                    break
            j += 1
        out[m.group(1)] = (src[:i].count("\n") + 1, src[:j].count("\n") + 1)
    return out, len(lines)


def ground_truth(d, root):
    """Every probe: the called function must be reached, the uncalled ones must not be."""
    out, errs = {}, []
    for name, src_rel, called, uncalled in PROBES:
        asm, src = os.path.join(d, name + ".asm"), os.path.join(root, src_rel)
        if not os.path.exists(asm):
            errs.append(f"{name}.asm absent - that probe checked nothing this run")
            continue
        if not os.path.exists(src):
            errs.append(f"{src_rel} absent - the probe source is what locates the functions")
            continue
        spans, _ = _spans(src)
        rows = parse(asm)
        _, marked = close(rows)
        for fn in (called,) + tuple(uncalled):
            lo, hi = spans[fn]
            idx = []
            for i, r in enumerate(rows):
                m = re.search(r":\s*(\d+):\d+-(\d+):", r["src"])
                if m and lo <= int(m.group(1)) and int(m.group(2)) <= hi:
                    idx.append(i)
            hit = sum(1 for i in idx if i in marked)
            out[f"{name}.{fn}"] = (hit, len(idx), fn == called)
            if not idx:
                errs.append(f"{name}.{fn} has no instructions attributed to it - the check is "
                            "vacuous, the source map did not carry its lines")
            elif (fn == called) != (hit > 0):
                errs.append(f"{name}.{fn} reached {hit} of {len(idx)} instructions and must "
                            f"reach {'more than none' if fn == called else 'none'}")
    return out, "; ".join(errs)


def object_identity(d):
    """WHICH object the report handed back for the immutable probe.

    The tag is an immutable, so it is patched into the runtime code at deployment. Nothing else
    in this repository contains these values, so a plain search settles the question that could
    not be settled from the Router and Hub listings: an artefact carries a zero placeholder, a
    deployed instance carries its own number, and two numbers at once means the listing is not
    one object."""
    p = os.path.join(d, "PcCoverageImmutableProbe.asm")
    if not os.path.exists(p):
        return None
    blob = open(p).read().lower()
    found = [why for tag, why in TAGS.items() if tag in blob]
    if not found:
        return "the ARTEFACT (immutables unpatched) - not any deployed instance"
    if len(found) > 1:
        return "MORE THAN ONE OBJECT: " + " and ".join(found)
    return found[0]


if __name__ == "__main__":
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    check = "--check" in sys.argv
    other = None
    for a in sys.argv[1:]:
        if a.startswith("--compare="):
            other = a.split("=", 1)[1]
    d = args[0] if args else "bytecode-coverage"
    if not os.path.isdir(d):
        sys.exit(f"no {d}/ - run: forge coverage --ir-minimum --report bytecode")

    rows_out, T = [], dict(instr=0, seed=0, closed=0, viol=0)
    print(f"{'CONTRACT':22} {'instr':>7} {'seed':>7} {'>= executed':>12}  {'violations':>10}")
    print("-" * 64)
    for name in SHIPPED:
        p = os.path.join(d, name + ".asm")
        if not os.path.exists(p):
            print(f"{name[12:]:22} {'absent':>7}")
            continue
        rows = parse(p)
        seed, marked = close(rows)
        bad, tot = violations(rows, marked)
        n = len(rows)
        print(f"{name[12:]:22} {n:7} {len(seed):7} {len(marked):7} {len(marked)/n:6.1%}  {bad:4}/{tot}")
        rows_out.append(dict(contract=name, instructions=n, seed=len(seed),
                             executed_at_least=len(marked), violations=bad))
        T["instr"] += n; T["seed"] += len(seed); T["closed"] += len(marked); T["viol"] += bad

    g = T["instr"] or 1
    print(f"\ninstructions in the five shipped runtime objects : {T['instr']}")
    print(f"  carrying a positive recorded hit count         : {T['seed']:7}  {T['seed']/g:6.1%}")
    print(f"  PROVEN EXECUTED (seed + forced successors)     : {T['closed']:7}  {T['closed']/g:6.1%}")
    print(f"  no execution evidence                          : {g-T['closed']:7}  {1-T['closed']/g:6.1%}")
    print(f"\nLOWER BOUND: at least {T['closed']/g:.1%} of the shipped instruction stream runs under the")
    print("suite. The complement is not dead code - it is code no evidence here reaches.")
    print(f"Residual control-flow violations: {T['viol']} (any non-zero voids the bound above).")

    got, err = ground_truth(d, args[1] if len(args) > 1 else ".")
    if got:
        print("\nGROUND TRUTH")
        for k, (hit, tot, is_called) in got.items():
            print(f"  {k:44} {hit:3}/{tot:<3} reached"
                  f"   {'must be > 0' if is_called else 'must be 0'}")
    ident = object_identity(d)
    if ident:
        print(f"  object handed back for the immutable probe: {ident}")
    if err:
        print("\nGROUND TRUTH FAILED: " + err)

    json.dump({"rows": rows_out, "totals": T,
               "executed_at_least": round(T["closed"] / g, 4)},
              open("assurance-pc-coverage.json", "w"), indent=1)

    if other:
        # Input stability. Two runs of the same tree should disassemble the same object for
        # each contract; when they do not, the per-contract rows are not comparable and the
        # aggregate is the only figure that survives.
        print("\nINPUT STABILITY vs " + other)
        same = moved = 0
        oT = oN = 0
        for name in SHIPPED:
            a, b = os.path.join(d, name + ".asm"), os.path.join(other, name + ".asm")
            if not (os.path.exists(a) and os.path.exists(b)):
                continue
            ra, rb = parse(a), parse(b)
            ident = ([(x["pc"], x["op"]) for x in ra] == [(x["pc"], x["op"]) for x in rb])
            _, mb = close(rb)
            oT += len(mb); oN += len(rb)
            same, moved = same + ident, moved + (not ident)
            print(f"  {name[12:]:22} listing {'identical' if ident else 'DIFFERENT OBJECT'}"
                  f"   this run {len(ra):6}  other {len(rb):6}")
        lo, hi = sorted((T["closed"] / g, oT / (oN or 1)))
        print(f"  {same} of {same+moved} listings identical")
        print(f"  aggregate across the two runs: {lo:.1%} .. {hi:.1%}  -> quote {lo:.1%}")

    if check and (err or T["viol"]):
        sys.exit(1)
