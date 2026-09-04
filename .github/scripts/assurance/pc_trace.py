#!/usr/bin/env python3
"""pc_trace.py - instructions of the SHIPPED binary that a recorded execution actually ran.

Every other execution figure in this directory is measured on the coverage build, which is a
different binary from the one that deploys (`--ir-minimum`, roughly twice the size). This one
reads the release artefacts and a trace recorded by `test/PcTraceProbe.t.sol` with
`vm.startDebugTraceRecording` under `FOUNDRY_PROFILE=release`.

A `DebugStep` carries no program counter. It carries the opcode, the call depth, the running
address, and - for JUMP / JUMPI and the CALL family - the top two stack words. That is enough to
REPLAY the pc exactly: a frame starts at 0, advances by 1 + push width, follows a JUMP to
stack[0] and a JUMPI to stack[0] when stack[1] is non-zero. The self-check is total: at every
replayed pc the artefact's opcode must equal the traced opcode, and a frame that disagrees once
is abandoned and counted. A replay with a single mismatch is no bound, and `--check` says so.

Which artefact a frame runs is learned, not assumed: the first sixty steps of a frame are
replayed under each of the five release objects and the one that agrees on every opcode wins.
Frames whose code is none of them (mocks, forge-std, the VM) are tracked by depth only.

Trace format (one file per recorded scenario, under out/pc-trace/):
    # <key> <value...>            header; `# addr <i> <address>` declares an address index,
                                  `# never <address>` names code that must NOT run
    <a> <op> <depth>              one step; <a> is an index from the header or an address
    <a> <op> <depth> <s0> <s1>    same, with the top two stack words (JUMP/JUMPI/CALL family)

Ground truth (`--check`), all of which must hold before a number here is worth citing:
  * zero opcode mismatches in every replayed frame;
  * the code named `never` in the header appears in no frame;
  * the Router frame executed at least one TLOAD and two distinct TSTORE sites (the lock's
    set and clear) - a swap that did not cross the lock was not the swap this measures;
  * every fraction lies in (0, 1].

Usage: python3 .github/scripts/assurance/pc_trace.py [--check] [--traces DIR] [ROOT]
"""
import collections, glob, json, os, re, sys

args = [a for a in sys.argv[1:] if not a.startswith("--")]
ROOT = args[0] if args else "."
CHECK = "--check" in sys.argv
TRACES = os.path.join(ROOT, "out", "pc-trace")
if "--traces" in sys.argv:
    TRACES = sys.argv[sys.argv.index("--traces") + 1]

SHIPPED = ("Core", "Quoter", "Solver", "Router", "Hub")
LIB_REF = re.compile(r"__\$[0-9a-fA-F]{34}\$__")
OPN = {0x56: "JUMP", 0x57: "JUMPI", 0xf1: "CALL", 0xf2: "CALLCODE", 0xf4: "DELEGATECALL",
       0xfa: "STATICCALL", 0x5c: "TLOAD", 0x5d: "TSTORE"}


def opsize(op):
    return 1 + (op - 0x5f) if 0x60 <= op <= 0x7f else 1


def disasm(raw):
    rows, i = [], 0
    while i < len(raw):
        op = raw[i]
        rows.append((i, op))
        i += opsize(op)
    return rows


def load_artefacts():
    art = {}
    for c in SHIPPED:
        p = os.path.join(ROOT, "out", f"BlazePhoenix{c}.sol", f"BlazePhoenix{c}.json")
        if not os.path.exists(p):
            print(f"no artefact for {c} at {p} - build the release profile first")
            sys.exit(2)
        a = json.load(open(p))
        d = a.get("deployedBytecode") or {}
        obj = d.get("object") or ""
        obj = obj[2:] if obj.startswith("0x") else obj
        raw = bytes.fromhex(LIB_REF.sub("0" * 40, obj))
        rows = disasm(raw)
        smap = d.get("sourceMap") or ""
        n_code = len(smap.split(";")) if smap else len(rows)
        # THE CODE SECTION ENDS WHERE THE SOURCE MAP ENDS: at low optimizer runs the compiler
        # appends a CODECOPY'd constant table, and a pc inside it is data, not an instruction.
        code_pcs = {pc for pc, _ in rows[:n_code]}
        art[c] = dict(raw=raw, code_pcs=code_pcs, ncode=len(code_pcs))
    return art


def parse(path):
    hdr, addr_of, never, steps = {}, {}, set(), []
    for ln in open(path).read().splitlines():
        if not ln.strip():
            continue
        if ln.startswith("#"):
            p = ln[1:].split()
            if len(p) >= 3 and p[0] == "addr":
                addr_of[p[1]] = p[2].lower()
            elif len(p) >= 2 and p[0] == "never":
                never.add(p[1].lower())
            elif len(p) >= 2:
                hdr[p[0]] = " ".join(p[1:])
            continue
        p = ln.split()
        a = addr_of.get(p[0], p[0].lower())
        op, depth = int(p[1]), int(p[2])
        s0 = int(p[3]) if len(p) > 3 else None
        s1 = int(p[4]) if len(p) > 4 else None
        steps.append((a, op, depth, s0, s1))
    return hdr, never, steps


def frames_of(steps):
    """Group steps into frames. A frame opens when the depth rises; its code address is the
    second stack word of the CALL-family step that opened it (CREATE frames get no address and
    are tracked by depth only)."""
    frames, stack, prev = [], [], None
    for i, (addr, op, depth, s0, s1) in enumerate(steps):
        if prev is None or depth > prev[2]:
            code_addr = None
            if prev is not None and prev[1] in (0xf1, 0xf2, 0xf4, 0xfa) and prev[4] is not None:
                code_addr = "0x%040x" % (prev[4] & ((1 << 160) - 1))
            elif prev is None:
                code_addr = addr
            f = dict(depth=depth, code_addr=code_addr, idx=[])
            frames.append(f)
            stack.append(f)
        elif depth < prev[2]:
            while stack and stack[-1]["depth"] > depth:
                stack.pop()
            if not stack:                      # trace resumed at a shallower depth than it began
                f = dict(depth=depth, code_addr=None, idx=[])
                frames.append(f)
                stack.append(f)
        stack[-1]["idx"].append(i)
        prev = steps[i]
    return frames


def identify(art, seq):
    for c, A in art.items():
        pc, raw = 0, A["raw"]
        for op, s0, s1 in seq:
            if pc >= len(raw) or raw[pc] != op:
                break
            if op == 0x56:
                pc = s0
            elif op == 0x57:
                pc = s0 if s1 else pc + 1
            else:
                pc += opsize(op)
        else:
            return c
    return None


def replay(art, steps, frames):
    addr_art = {}
    for f in frames:
        ca = f["code_addr"]
        if ca is None or ca in addr_art:
            continue
        seq = [(steps[i][1], steps[i][3], steps[i][4]) for i in f["idx"][:60]]
        addr_art[ca] = identify(art, seq)
    executed = collections.defaultdict(set)
    ops_at = collections.defaultdict(lambda: collections.defaultdict(set))   # art -> op -> pcs
    checked, mismatch, replayed = collections.Counter(), collections.Counter(), 0
    for f in frames:
        c = addr_art.get(f["code_addr"])
        if c is None:
            continue
        replayed += 1
        raw, pc = art[c]["raw"], 0
        for i in f["idx"]:
            _a, op, _d, s0, s1 = steps[i]
            checked[c] += 1
            if pc >= len(raw) or raw[pc] != op:
                mismatch[c] += 1
                break                      # no pc to resynchronise on; the frame is abandoned
            executed[c].add(pc)
            ops_at[c][op].add(pc)
            if op == 0x56:
                pc = s0
            elif op == 0x57:
                pc = s0 if s1 else pc + 1
            else:
                pc += opsize(op)
    return addr_art, executed, ops_at, checked, mismatch, replayed


def main():
    art = load_artefacts()
    files = sorted(glob.glob(os.path.join(TRACES, "*.txt")))
    if not files:
        print(f"no traces under {TRACES} - record one with:\n"
              f"  PC_TRACE=1 FOUNDRY_PROFILE=release forge test --match-contract PcTraceProbe -vvv")
        sys.exit(2)
    union = collections.defaultdict(set)
    ops_union = collections.defaultdict(lambda: collections.defaultdict(set))
    problems, rows = [], []
    for path in files:
        hdr, never, steps = parse(path)
        frames = frames_of(steps)
        addr_art, executed, ops_at, checked, mismatch, replayed = replay(art, steps, frames)
        name = os.path.basename(path)[:-4]
        ran_never = sorted(n for n in never if any(f["code_addr"] == n for f in frames))
        if ran_never:
            problems.append(f"{name}: code declared `never` ran: {ran_never}")
        for c in SHIPPED:
            if checked[c]:
                rows.append((name, c, checked[c], mismatch[c], len(executed[c]), art[c]["ncode"]))
                if mismatch[c]:
                    problems.append(f"{name}/{c}: {mismatch[c]} opcode mismatch(es) - the replay is no bound")
                union[c] |= executed[c]
                for op, pcs in ops_at[c].items():
                    ops_union[c][op] |= pcs
        print(f"{name}: {len(steps)} steps, {len(frames)} frames, {replayed} replayed against the five artefacts")

    print(f"\n{'trace':22} {'artefact':8} {'steps':>7} {'mismatch':>8} {'pcs run':>8} {'code':>7}  of the RELEASE code section")
    for name, c, chk, mm, ex, nc in rows:
        print(f"{name:22} {c:8} {chk:7} {mm:8} {ex:8} {nc:7}  {ex / nc:.1%}")
    print(f"\n{'UNION':22} {'artefact':8} {'pcs run':>8} {'code':>7}")
    summary = {}
    for c in SHIPPED:
        if union[c]:
            frac = len(union[c]) / art[c]["ncode"]
            summary[c] = dict(executed=len(union[c]), code=art[c]["ncode"], fraction=round(frac, 4),
                              tload_sites=len(ops_union[c].get(0x5c, ())),
                              tstore_sites=len(ops_union[c].get(0x5d, ())))
            print(f"{'':22} {c:8} {len(union[c]):8} {art[c]['ncode']:7}  {frac:.1%}")
            if not (0 < frac <= 1):
                problems.append(f"{c}: fraction {frac} outside (0, 1]")

    r = summary.get("Router")
    if r is None:
        problems.append("no trace ran the Router - the measurement is about nothing")
    elif r["tload_sites"] < 1 or r["tstore_sites"] < 2:
        problems.append(f"Router: lock not crossed (TLOAD sites {r['tload_sites']}, TSTORE sites {r['tstore_sites']})")

    os.makedirs(TRACES, exist_ok=True)
    json.dump(dict(traces=[os.path.basename(f) for f in files], union=summary, problems=problems),
              open(os.path.join(TRACES, "summary.json"), "w"), indent=1)
    print("\nRELEASE-BINARY EXECUTION: a pc counts only if the replay reached it with the artefact's own\n"
          "opcode at every step before it. The complement is code no recorded scenario ran, which is\n"
          "not dead code; it is the list of scenarios still to record.")
    if problems:
        print("\nPROBLEMS:")
        for p in problems:
            print("  - " + p)
    if CHECK:
        print("\nground truth:", "FAIL" if problems else "OK")
        sys.exit(1 if problems else 0)


if __name__ == "__main__":
    main()
