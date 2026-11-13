"""Join the MUTANTS_VERDICTS files of the mutation shards into one verdict per mutant, and fail
unless every mutant of the catalogue was judged once and killed, or its verdict is explained.

    python3 .github/scripts/mutants_join.py <explained.tsv> <verdicts.tsv>... [--out all.tsv]

ONE DENOMINATOR (2026-11-13, selar F01). The denominator is len(M) of mutants.py, read here, never
a number copied into a doc. A shard proves it finished by its closing `SHARD k/n of N` row; a
shard without it was cut short and its missing mutants are UNJUDGED. The join fails on:
  - a shard missing, cut short, or run against another catalogue size or another shard count;
  - a mutant judged twice, or not at all (UNJUDGED);
  - a baseline row (BASELINE RED, BASELINE MISSING, BASELINE FAILED);
  - a survivor (SURVIVED) or an inconclusive verdict (anything but KILLED) that has no row in
    explained.tsv: `mutant<TAB>verdict<TAB>reason`, the mutant by its name in mutants.py.
It prints one line per shard: killed, survivors, inconclusive, explained, unjudged.
"""
import os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
SHARD = re.compile(r"^(\d+)/(\d+) of (\d+)$")


def catalogue():
    sys.path.insert(0, HERE)
    import mutants
    return [m["nome"] for m in mutants.M]


def read(path):
    with open(path) as f:
        lines = [l.rstrip("\n").split("\t") for l in f if l.strip()]
    if not lines or lines[0][:2] != ["idx", "verdict"]:
        return []
    return [l + [""] * (7 - len(l)) for l in lines[1:]]


def join(names, explained, files):
    """(problems, per-shard lines, {idx: (verdict, mutant)}) of the shard files against the catalogue."""
    problems, verdicts, shards, counts = [], {}, {}, []
    for path in files:
        rows = read(path)
        done = [r for r in rows if r[0] == "-" and r[1] == "SHARD"]
        sh = SHARD.match(done[-1][5]) if done else None
        if not sh:
            problems.append(f"{path}: no closing SHARD row, the shard was cut short")
        else:
            k, n, total = (int(x) for x in sh.groups())
            if total != len(names):
                problems.append(f"{path}: shard ran against {total} mutants, the catalogue has {len(names)}")
            if k in shards:
                problems.append(f"{path}: shard {k}/{n} reported twice")
            shards[k] = n
        mine = {}
        for r in rows:
            if r[0] == "-":
                if r[1].startswith("BASELINE"):
                    problems.append(f"{path}: {r[1]} {r[3]} {r[6]}".rstrip())
                continue
            mine.setdefault(int(r[0]), (r[1], r[5]))
        for i, v in mine.items():
            if i in verdicts:
                problems.append(f"[{i}] judged twice: {verdicts[i][0]} and {v[0]}")
            verdicts[i] = v
        c = {"killed": 0, "survived": 0, "inconclusive": 0, "explained": 0}
        for i, (v, nome) in mine.items():
            if v == "KILLED":
                c["killed"] += 1
            elif (nome, v) in explained:
                c["explained"] += 1
            else:
                c["survived" if v == "SURVIVED" else "inconclusive"] += 1
                problems.append(f"[{i}] {v}: {nome}")
        label = f"{sh.group(1)}/{sh.group(2)}" if sh else "cut"
        counts.append((label, path, c))
    ns = set(shards.values())
    if len(ns) > 1:
        problems.append(f"shards ran with different shard counts: {sorted(ns)}")
    elif ns:
        n = ns.pop()
        for k in sorted(set(range(1, n + 1)) - set(shards)):
            problems.append(f"shard {k}/{n}: no verdict file")
    unjudged = sorted(set(range(1, len(names) + 1)) - set(verdicts))
    for i in unjudged:
        problems.append(f"[{i}] UNJUDGED: {names[i - 1]}")
    for i in sorted(set(verdicts) - set(range(1, len(names) + 1))):
        problems.append(f"[{i}] outside the catalogue of {len(names)}")
    return problems, counts, verdicts, unjudged


def main(argv, names=None):
    out = None
    if "--out" in argv:
        j = argv.index("--out"); out = argv[j + 1]; argv = argv[:j] + argv[j + 2:]
    if len(argv) < 2:
        sys.exit(__doc__)
    names = catalogue() if names is None else names
    explained = set()
    with open(argv[0]) as f:
        for l in f.read().splitlines()[1:]:
            p = l.split("\t")
            if len(p) >= 3 and p[2].strip():
                explained.add((p[0], p[1]))
    problems, counts, verdicts, unjudged = join(names, explained, argv[1:])
    print("shard\tkilled\tsurvived\tinconclusive\texplained\tfile")
    for label, path, c in sorted(counts):
        print(f"{label}\t{c['killed']}\t{c['survived']}\t{c['inconclusive']}\t{c['explained']}\t{os.path.basename(path)}")
    killed = sum(1 for v, _ in verdicts.values() if v == "KILLED")
    print(f"total: {killed} killed of {len(names)} mutants; {len(verdicts) - killed} not killed; "
          f"{len(unjudged)} unjudged")
    if out:
        with open(out, "w") as f:
            f.write("idx\tverdict\tmutant\n")
            for i in sorted(verdicts):
                f.write(f"{i}\t{verdicts[i][0]}\t{verdicts[i][1]}\n")
    if problems:
        print(f"\n{len(problems)} problems:")
        for p in problems[:400]:
            print("  -", p)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
