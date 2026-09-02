#!/usr/bin/env python3
"""Adequacao ao nivel da CONDICAO — o que o `forge coverage` nao pergunta.

WHY THIS EXISTS. Branch coverage asks only whether each branch was taken. It
does NOT ask whether each CONDITION inside a compound predicate independently
determined the outcome. A predicate `a || b` exercised only where `a` is true
reports 100% branch coverage while `b` has never once decided anything. This
repository's most consequential guards are compound — the V3 callback
authentication is `msg.sender != expected || expected == address(0)`, and a
logical-connector swap there weakens authentication while still reverting
often enough to look like a working guard. That mutant was found by hand and
is now killed; nothing systematically found the next one. This tool does.

THE METHOD — MC/DC's independence question, answered by mutation instead of
instrumentation. MC/DC demands that each of the N conditions in a decision be
shown to independently flip the decision's outcome. We cannot instrument the
contracts, so for each sub-condition we build the mutation that NEUTRALISES
it — replace it with the identity element of its immediate boolean connective
(`a && b` with `b` forced `true`; `a || b` with `b` forced `false`), which
makes that sub-condition irrelevant to the decision while changing nothing
else — and run the whole suite. If the suite still PASSES, no test in the
tree depends on that sub-condition: it has never independently decided
anything, and a defect in it is invisible to CI. If the suite FAILS, some
test depends on it. This is the same logic mutants.py already uses, applied
exhaustively at the granularity MC/DC cares about.

THE LIMIT, stated plainly. A red suite proves DEPENDENCE — some test's
verdict changes when the sub-condition is removed from play. It does NOT
prove the full MC/DC unique-cause pairing (two tests differing only in that
condition with opposite outcomes), and the failure can be collateral: the
neutralised text may fail a source-census pin (HookSieveCensusPin greps
src/*.sol), or eager evaluation of a formerly short-circuited neighbour may
revert. Both directions of error are conservative for our purpose — they can
only overstate "exercised", never overstate "inert". Every INERT verdict is
backed by a full green suite with the sub-condition neutralised; that claim
is exact. A neutralisation that fails to upload, run, or compile is an
UNVERIFIED verdict and fails the run — never a skip (cfmutants.py's lesson:
a failed upload is a failed verification).

WHERE IT RUNS. This script runs on the dev machine (the box has no python)
and drives the CI box over HTTP, exactly as the remote mutation guard does:
mutations are built in memory, PUT to the box, judged there, and the
pristine text is PUT back. The local tree is never written.

USAGE
  mcdc.py --list                 static census of every compound decision
  mcdc.py --run guards           neutralise every sub-condition of guard-class
                                 decisions (require / _auth / if-revert +
                                 curated auth returns) and judge each
  mcdc.py --run all              the full sweep (expensive: one suite per leaf)
  mcdc.py --run File.sol:LINE[,File.sol:LINE...]
                                 explicit decisions, judged in the order given
                                 (budget-ordering: most consequential first)

EXIT CODE: non-zero if any guard-class sub-condition is INERT, or if any
attempted neutralisation ended UNVERIFIED.
"""
import json, os, re, subprocess, sys, time, urllib.parse

U = "https://bp-ci.a-s-myros-gtar.workers.dev"
REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SRC = os.path.join(REPO, "src")
# THE SEED IS PINNED, AND IT HAS TO BE. The invariant campaigns walk randomly, and
# one of them carries an anti-vacuity sentinel that fails when the walk never reaches
# the V4 settle path. With a free seed the same tree gives a green baseline on one run
# and a red one on the next -- but worse, a mutant judged "killed" might merely have
# drawn a different walk. A red is only attributable to the mutation when everything
# else, the seed included, is held fixed.
# THE SAME seed as foundry.toml's [fuzz] seed, deliberately: with two instruments
# on two seeds, a red or green in one was not transferable to the other without
# re-running (an INERT verdict was a statement about one walk, CI's green about
# another). One seed, one walk, one reading (review 2026-09-02).
SUITE_CMD = 'test --no-match-path "test/fork/*" --fuzz-seed 0xb1a2ef00'

# Return-decisions that ARE authentication even though they revert nothing:
# a false return here silently admits/refuses. Curated, like mutants.py's M.
CURATED_GUARD_RETURNS = {
    ("BlazePhoenixHub.sol", "isHookLive"),   # hook admission: allow-list && codehash pin
}

# ─── source masking ──────────────────────────────────────────────────────────

def mask(text):
    """Blank comments and string literals (keep offsets/newlines)."""
    out = list(text)
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c == "/" and i + 1 < n and text[i + 1] == "/":
            while i < n and text[i] != "\n":
                out[i] = " "; i += 1
        elif c == "/" and i + 1 < n and text[i + 1] == "*":
            j = text.find("*/", i + 2)
            j = n if j < 0 else j + 2
            while i < j:
                if out[i] != "\n": out[i] = " "
                i += 1
        elif c in "\"'":
            q = c; out[i] = " "; i += 1
            while i < n and text[i] != q:
                if text[i] == "\\": out[i] = " "; i += 1
                if i < n and out[i] != "\n": out[i] = " "
                i += 1
            if i < n: out[i] = " "; i += 1
        else:
            i += 1
    return "".join(out)

def match_paren(s, i):
    """i points at '('; return index just past its match."""
    d = 0
    for j in range(i, len(s)):
        if s[j] == "(": d += 1
        elif s[j] == ")":
            d -= 1
            if d == 0: return j + 1
    return len(s)

# ─── boolean structure ───────────────────────────────────────────────────────

def top_level_ops(s, a, b, op):
    """Positions of `op` at local depth 0 within s[a:b]."""
    d, out, j = 0, [], a
    while j < b - 1:
        c = s[j]
        if c in "([{": d += 1
        elif c in ")]}": d -= 1
        elif d == 0 and s[j:j+2] == op:
            out.append(j); j += 2; continue
        j += 1
    return out

def strip_span(s, a, b):
    while a < b and s[a] in " \t\n": a += 1
    while b > a and s[b-1] in " \t\n": b -= 1
    return a, b

def leaves(s, a, b, parent_op=None):
    """Recursively split s[a:b] into atomic sub-conditions.
    Returns [(start, end, immediate_op)] — immediate_op decides the identity
    constant that neutralises the leaf ('&&' -> true, '||' -> false)."""
    a, b = strip_span(s, a, b)
    for op in ("||", "&&"):
        pos = top_level_ops(s, a, b, op)
        if pos:
            out, prev = [], a
            for p in pos:
                out += leaves(s, prev, p, op); prev = p + 2
            out += leaves(s, prev, b, op)
            return out
    # no top-level binary op: strip redundant wrapping and recurse, else leaf
    if a < b and s[a] == "(" and match_paren(s, a) == b:
        inner = leaves(s, a + 1, b - 1, parent_op)
        if len(inner) > 1: return inner
        return [(a, b, parent_op)]
    if a < b and s[a] == "!":
        j = a + 1
        while j < b and s[j] in " \t\n": j += 1
        if j < b and s[j] == "(" and match_paren(s, j) == b:
            inner = leaves(s, j + 1, b - 1, parent_op)
            if len(inner) > 1: return inner
    return [(a, b, parent_op)]

IDENT = {"&&": "true", "||": "false"}

# ─── decision extraction ─────────────────────────────────────────────────────

def enclosing_fn(s, pos):
    best = None
    for m in re.finditer(r"\b(function|modifier)\s+(\w+)|\b(constructor|receive|fallback)\s*\(", s[:pos]):
        best = m.group(2) or m.group(3)
    return best or "?"

def classify_if(s, close):
    """Look at the statement the if() controls: revert => guard, return => fail-closed."""
    j = close
    while j < len(s) and s[j] in " \t\n": j += 1
    if j < len(s) and s[j] == "{":
        d, k = 0, j
        while k < len(s):
            if s[k] == "{": d += 1
            elif s[k] == "}":
                d -= 1
                if d == 0: break
            k += 1
        body = s[j:k]
    else:
        k = s.find(";", j)
        body = s[j:k if k > 0 else j]
    if re.search(r"\brevert\b", body): return "guard"
    if re.search(r"\breturn\b", body): return "fail-closed"
    return "flow"

def find_decisions(path):
    """All compound decisions in one file. Each: dict with spans + leaves."""
    text = open(path, encoding="utf-8").read()
    s = mask(text)
    fname = os.path.basename(path)
    decisions, covered = [], []

    def add(cs, ce, ctx, klass):
        cs, ce = strip_span(s, cs, ce)
        # ternary: the decision proper is the part before a top-level '?'
        q = [p for p in range(cs, ce) if s[p] == "?" and s[p:p+2] != "?." ]
        qtop = None
        d = 0
        for p in range(cs, ce):
            if s[p] in "([{": d += 1
            elif s[p] in ")]}": d -= 1
            elif s[p] == "?" and d == 0: qtop = p; break
        if qtop is not None: ce = qtop
        cs, ce = strip_span(s, cs, ce)
        if not (top_level_ops(s, cs, ce, "||") or top_level_ops(s, cs, ce, "&&")
                or "&&" in s[cs:ce] or "||" in s[cs:ce]):
            return
        lv = leaves(s, cs, ce)
        if len(lv) < 2: return
        fn = enclosing_fn(s, cs)
        if (fname, fn) in CURATED_GUARD_RETURNS and ctx == "return":
            klass = "guard"
        decisions.append(dict(
            file=fname, line=text.count("\n", 0, cs) + 1, fn=fn, ctx=ctx,
            klass=klass, span=(cs, ce), cond=re.sub(r"\s+", " ", text[cs:ce]).strip(),
            leaves=[dict(span=(a, b), op=op or "?", text=re.sub(r"\s+", " ", text[a:b]).strip())
                    for a, b, op in lv]))
        covered.append((cs, ce))

    for m in re.finditer(r"\b(if|while|require|_auth)\s*\(", s):
        kw = m.group(1)
        o = m.end() - 1
        close = match_paren(s, o)
        cs, ce = o + 1, close - 1
        if kw == "require":
            commas = [p for p in top_level_ops_char(s, cs, ce, ",")]
            if commas: ce = commas[0]
        klass = ("guard" if kw in ("require", "_auth")
                 else classify_if(s, close) if kw == "if" else "flow")
        add(cs, ce, kw, klass)

    for m in re.finditer(r"\breturn\b", s):
        cs = m.end()
        d, j = 0, cs
        while j < len(s):
            if s[j] in "([{": d += 1
            elif s[j] in ")]}": d -= 1
            elif s[j] == ";" and d == 0: break
            j += 1
        add(cs, j, "return", "flow")

    # catch-all: connectors not inside any captured decision (assignments etc.)
    for m in re.finditer(r"&&|\|\|", s):
        p = m.start()
        if any(a <= p < b for a, b in covered): continue
        # statement bounds at local depth 0
        d, a = 0, p
        while a > 0:
            c = s[a - 1]
            if c in ")]}": d += 1
            elif c in "([{":
                if d == 0: break
                d -= 1
            elif c == ";" and d == 0: break
            a -= 1
        d, b = 0, p
        while b < len(s):
            c = s[b]
            if c in "([{": d += 1
            elif c in ")]}":
                if d == 0: break
                d -= 1
            elif c == ";" and d == 0: break
            b += 1
        seg = s[a:b]
        eq = None
        dd = 0
        for j2 in range(a, b):
            c = s[j2]
            if c in "([{": dd += 1
            elif c in ")]}": dd -= 1
            elif c == "=" and dd == 0 and s[j2-1] not in "=!<>&|+-*/%^" and (j2+1 >= len(s) or s[j2+1] != "="):
                eq = j2; break
        add((eq + 1) if eq is not None else a, b, "assign" if eq is not None else "expr", "flow")
        covered.append((a, b))

    decisions.sort(key=lambda d: d["line"])
    return text, decisions

def top_level_ops_char(s, a, b, ch):
    d, out = 0, []
    for j in range(a, b):
        c = s[j]
        if c in "([{": d += 1
        elif c in ")]}": d -= 1
        elif d == 0 and c == ch: out.append(j)
    return out

# ─── the box ─────────────────────────────────────────────────────────────────

def put(rel, text):
    for _ in range(3):
        r = subprocess.run(
            ["curl", "-s", "-m", "180", "-X", "POST", f"{U}/put?path={rel}",
             "--data-binary", "@-", "-H", "Content-Type: text/plain"],
            input=text, capture_output=True, text=True)
        if '"ok":true' in r.stdout: return True
        time.sleep(5)
    return False

def run_suite():
    q = urllib.parse.quote(SUITE_CMD)
    r = subprocess.run(["curl", "-s", "-m", "480", f"{U}/run?cmd={q}"],
                       capture_output=True, text=True)
    try:
        d = json.loads(r.stdout)
    except Exception:
        return None, ""
    return d.get("exitCode"), (d.get("stdout") or "") + (d.get("stderr") or "")

def summarise(out):
    m = re.search(r"Ran \d+ test suites[^\n]*", out)
    fails = re.findall(r"\[FAIL[^\]]*\] (\S+)", out)
    t = re.search(r"(\d+) total tests", out)
    return (m.group(0) if m else "no summary"), sorted(set(fails))[:5], int(t.group(1)) if t else -1

# ─── main ────────────────────────────────────────────────────────────────────

def census():
    all_d = {}
    for f in sorted(os.listdir(SRC)):
        if f.endswith(".sol"):
            text, ds = find_decisions(os.path.join(SRC, f))
            all_d[f] = (text, ds)
    return all_d

def main():
    argv = sys.argv[1:]
    mode = argv[argv.index("--run") + 1] if "--run" in argv else None
    all_d = census()
    flat = [d for _, (_, ds) in sorted(all_d.items()) for d in ds]

    if "--list" in argv or mode is None:
        print(f"{len(flat)} decisoes compostas em src/ "
              f"({sum(len(d['leaves']) for d in flat)} sub-condicoes)")
        for d in flat:
            print(f"  {d['file']}:{d['line']:<5} N={len(d['leaves'])} "
                  f"[{d['klass']:<11}] {d['fn']:<28} {d['cond'][:90]}")
        return

    if mode == "guards":
        sel = [d for d in flat if d["klass"] == "guard"]
    elif mode == "all":
        sel = flat
    else:  # comma-separated File.sol:LINE list, run in the order given
        sel = []
        for item in mode.split(","):
            f, ln = item.strip().split(":")
            hit = [d for d in flat if d["file"] == f and d["line"] == int(ln)]
            if not hit:
                print(f"nao encontrado: {item}"); sys.exit(2)
            sel += hit
    if not sel:
        print("nada seleccionado"); sys.exit(2)

    originals = {f: t for f, (t, _) in all_d.items()}

    # A red box proves nothing about a mutant. Refuse to judge on one, and
    # remember the baseline's test COUNT: an INERT verdict below requires the
    # same total, so a silently shrunken suite cannot fake a green.
    print("baseline: a correr a suite intacta na box...")
    code0, out0 = run_suite()
    if code0 is None:
        print("baseline SEM RESPOSTA da box — parar."); sys.exit(1)
    sm0, _, baseline_total = summarise(out0)
    if code0 != 0 or baseline_total < 0:
        print(f"baseline NAO esta verde ({sm0}) — recusar julgar mutantes."); sys.exit(1)
    print(f"baseline verde: {sm0}\n")
    inert, unverified, exercised = [], [], []
    total = sum(len(d["leaves"]) for d in sel)
    print(f"{len(sel)} decisoes, {total} sub-condicoes a neutralizar; "
          f"uma suite completa por cada.\n")
    k = 0
    try:
        for d in sel:
            base = originals[d["file"]]
            print(f"{d['file']}:{d['line']} [{d['klass']}] {d['fn']}  {d['cond'][:80]}")
            for i, lf in enumerate(d["leaves"]):
                k += 1
                a, b = lf["span"]; const = IDENT.get(lf["op"], "false")
                mut = base[:a] + const + base[b:]
                tag = f"[{k}/{total}] cond {i+1}/{len(d['leaves'])} `{lf['text'][:48]}` -> {const}"
                if not put(f"src/{d['file']}", mut):
                    unverified.append((d, lf, "UPLOAD FALHOU"))
                    print(f"    {tag}  UPLOAD FALHOU — nao verificada", flush=True); continue
                code, out = run_suite()
                if not put(f"src/{d['file']}", base):   # restore before judging
                    unverified.append((d, lf, "RESTAURO FALHOU"))
                    print(f"    {tag}  RESTAURO FALHOU — abortar", flush=True); break
                if code is None:
                    unverified.append((d, lf, "SEM RESPOSTA"))
                    print(f"    {tag}  SEM RESPOSTA — nao verificada", flush=True); continue
                summary, fails, total_seen = summarise(out)
                if "Compiler run failed" in out or ("compilation" in out.lower() and "Ran" not in out):
                    unverified.append((d, lf, "COMPILE FALHOU"))
                    print(f"    {tag}  COMPILE FALHOU — nao verificada", flush=True)
                elif code == 0 and total_seen != baseline_total:
                    unverified.append((d, lf, f"SUITE ENCOLHIDA {total_seen}!={baseline_total}"))
                    print(f"    {tag}  SUITE ENCOLHIDA ({total_seen} vs {baseline_total}) — nao verificada", flush=True)
                elif code == 0:
                    inert.append((d, lf, summary))
                    print(f"    {tag}  INERTE — {summary}", flush=True)
                elif not fails:
                    # A RED THAT PROVES NOTHING. A non-zero exit is not evidence that a
                    # test disagreed with the mutation: a compiler error phrased
                    # differently, a timeout, an OOM or a dead box all exit non-zero and
                    # would otherwise be counted as "this sub-condition is watched". We
                    # already refuse a green that cannot name its passing count; the
                    # mirror rule is that a red must name the test that went red.
                    unverified.append((d, lf, f"VERMELHA SEM TESTE NOMEADO (exit={code})"))
                    print(f"    {tag}  VERMELHA SEM TESTE NOMEADO (exit={code}) — "
                          f"nao verificada", flush=True)
                else:
                    exercised.append((d, lf, summary, fails))
                    print(f"    {tag}  exercida — {len(fails)}+ testes vermelhos "
                          f"(ex: {', '.join(fails[:3])})", flush=True)
    finally:
        for f, t in originals.items():   # belt and braces: pristine everywhere
            put(f"src/{f}", t)

    print()
    if inert:
        print("SUB-CONDICOES INERTES (nenhum teste depende delas):")
        for d, lf, sm in inert:
            print(f"  - {d['file']}:{d['line']} [{d['klass']}] {d['fn']}: "
                  f"`{lf['text']}` em `{d['cond'][:80]}` — suite VERDE neutralizada")
    if unverified:
        print("NAO VERIFICADAS (contam como falha, nunca como skip):")
        for d, lf, why in unverified:
            print(f"  - {d['file']}:{d['line']} {d['fn']}: `{lf['text'][:60]}` — {why}")
    print(f"\n{len(exercised)} exercidas, {len(inert)} inertes, "
          f"{len(unverified)} nao verificadas, de {total} seleccionadas.")
    guard_inert = [x for x in inert if x[0]["klass"] == "guard"]
    if guard_inert or unverified:
        sys.exit(1)

if __name__ == "__main__":
    main()
