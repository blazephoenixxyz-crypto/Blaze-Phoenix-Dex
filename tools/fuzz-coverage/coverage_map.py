#!/usr/bin/env python3
"""Fuzz coverage map: every external/public function of src/ against the fuzzed tests that call it.

Derived by pattern matching over the source text, never by hand, so the table can be regenerated
and diffed in CI (`--check`). What counts:

  SURFACE  every `function NAME(` in src/**/*.sol whose header carries `external` or `public`.
           Core and Math are libraries whose surface is `internal`; their `internal` functions are
           counted as surface too (marked lib), since that is how the other contracts reach them.
  FUZZED   a test function that forge fuzzes: a `test*` function with at least one parameter, or
           an `invariant_*` function. Its body is the text from its header to the next function.
  CREDIT   a fuzzed test credits NAME when its body contains `.NAME(` or, for a library, `NAME(`.
           An invariant credits NAME when ANY text of its file (the handlers live there) contains
           `.NAME(`: invariant reach is file-level, a coarser and more generous measure.

Known approximations (stated in the generated doc, never hidden): credit is per NAME, so two
contracts sharing a name (`quote`) share the credit; a call made through a helper in another
file is not seen. Both err toward reporting coverage, so a GAP row is a real gap of this measure.

Usage: coverage_map.py [--tsv] [--md PATH] [--check PATH]   (run from the repo root)
"""
import os, re, sys

FN = re.compile(r'\bfunction\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(')
UNIT = re.compile(r'^\s*(?:abstract\s+)?(contract|library|interface)\s+([A-Za-z0-9_]+)', re.M)
TESTFN = re.compile(r'\bfunction\s+((?:test|invariant)[A-Za-z0-9_]*)\s*\(([^)]*)\)')


def sol_files(root):
    for d, _, fs in os.walk(root):
        for f in sorted(fs):
            if f.endswith('.sol'):
                yield os.path.join(d, f)


def strip_comments(s):
    s = re.sub(r'/\*.*?\*/', lambda m: '\n' * m.group(0).count('\n'), s, flags=re.S)
    return re.sub(r'//[^\n]*', '', s)


def header(src, start):
    """The function header: from `function` to the first `{` or `;`."""
    end = len(src)
    for ch in '{;':
        j = src.find(ch, start)
        if j != -1:
            end = min(end, j)
    return src[start:end]


def surface(src_root='src'):
    rows = []
    for path in sorted(sol_files(src_root)):
        text = strip_comments(open(path).read())
        units = [(m.start(), m.group(1), m.group(2)) for m in UNIT.finditer(text)]
        for m in FN.finditer(text):
            unit = None
            for pos, kind, name in units:
                if pos < m.start():
                    unit = (kind, name)
            if unit is None or unit[0] == 'interface':
                continue
            h = header(text, m.start())
            vis = next((v for v in ('external', 'public', 'internal', 'private') if re.search(r'\b' + v + r'\b', h)), '')
            lib = unit[0] == 'library'
            if vis in ('external', 'public') or (lib and vis == 'internal'):
                rows.append(dict(file=path, unit=unit[1], fn=m.group(1), vis=vis, lib=lib,
                                 view=bool(re.search(r'\b(view|pure)\b', h))))
    seen, out = set(), []
    for r in rows:  # overloads collapse to one row per (unit, name)
        k = (r['unit'], r['fn'])
        if k not in seen:
            seen.add(k); out.append(r)
    return out


def fuzzed(test_root='test'):
    tests = []
    for path in sorted(sol_files(test_root)):
        text = strip_comments(open(path).read())
        ms = list(FN.finditer(text))
        for i, m in enumerate(ms):
            t = TESTFN.match(text, m.start())
            if not t:
                continue
            name, params = t.group(1), t.group(2).strip()
            inv = name.startswith('invariant')
            if not inv and not params:
                continue
            body = text[m.start(): ms[i + 1].start() if i + 1 < len(ms) else len(text)]
            tests.append(dict(file=path, name=name, inv=inv, body=body, filetext=text))
    return tests


def credit(rows, tests):
    for r in rows:
        dot = re.compile(r'\.' + re.escape(r['fn']) + r'\s*[({]')
        bare = re.compile(r'(?<![A-Za-z0-9_])' + re.escape(r['fn']) + r'\s*\(')
        fz, iv = [], []
        for t in tests:
            if t['inv']:
                if dot.search(t['filetext']):
                    iv.append(t['name'])
            elif dot.search(t['body']) or (r['lib'] and bare.search(t['body'][9:])):
                fz.append(t['name'])
        r['fuzz'], r['inv'] = sorted(set(fz)), sorted(set(iv))
    return rows


def tsv(rows):
    out = ['unit\tfn\tvis\tview\tfuzz_n\tinv_n\tstatus']
    for r in rows:
        st = 'GAP' if not r['fuzz'] and not r['inv'] else ('INV_ONLY' if not r['fuzz'] else 'FUZZED')
        out.append(f"{r['unit']}\t{r['fn']}\t{r['vis']}{'(lib)' if r['lib'] else ''}\t{int(r['view'])}\t{len(r['fuzz'])}\t{len(r['inv'])}\t{st}")
    return '\n'.join(out) + '\n'


def md(rows, tests):
    gaps = [r for r in rows if not r['fuzz'] and not r['inv']]
    invo = [r for r in rows if not r['fuzz'] and r['inv']]
    L = ['# Fuzz coverage map', '',
         'Generated by `python3 tools/fuzz-coverage/coverage_map.py --md docs/assurance/FUZZ_COVERAGE.md`;',
         'CI regenerates it with `--check` and fails on drift. Do not edit by hand.', '',
         'Surface: external/public functions of `src/` (library `internal` functions for Core and Math).',
         'Fuzzed: `test*` functions with parameters and `invariant_*` functions under `test/`.',
         'Credit: the fuzzed body contains `.name(` (library: `name(`); an invariant credits every `.name(`',
         'in its file, since its handlers live there. Credit is per name, so it errs toward coverage:',
         'a GAP row is a gap of this measure, an FUZZED row is not proof of depth.', '',
         f"Totals: {len(rows)} functions, {len(tests)} fuzzed tests "
         f"({sum(t['inv'] for t in tests)} invariants); {len(gaps)} GAP, {len(invo)} INV_ONLY.", '',
         '| unit | function | visibility | view | fuzz | inv | status |', '|---|---|---|---|---|---|---|']
    for r in rows:
        st = 'GAP' if not r['fuzz'] and not r['inv'] else ('INV_ONLY' if not r['fuzz'] else 'FUZZED')
        L.append(f"| {r['unit']} | `{r['fn']}` | {r['vis']}{' (lib)' if r['lib'] else ''} | {'y' if r['view'] else 'n'} "
                 f"| {len(r['fuzz'])} | {len(r['inv'])} | {st} |")
    return '\n'.join(L) + '\n'


def main(argv):
    rows = credit(surface(), tests := fuzzed())
    if '--tsv' in argv:
        sys.stdout.write(tsv(rows))
    if '--md' in argv:
        open(argv[argv.index('--md') + 1], 'w').write(md(rows, tests))
    if '--check' in argv:
        p = argv[argv.index('--check') + 1]
        if open(p).read() != md(rows, tests):
            sys.exit(f'{p} is stale: regenerate it with --md {p}')
    if not any(a in argv for a in ('--tsv', '--md', '--check')):
        sys.stdout.write(tsv(rows))


if __name__ == '__main__':
    main(sys.argv[1:])
