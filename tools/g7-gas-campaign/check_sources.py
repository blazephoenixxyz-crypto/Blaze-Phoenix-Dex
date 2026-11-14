#!/usr/bin/env python3
"""G7-S2: check that every address / pool id in inventory.CHAINS appears at the repo
file:line it cites. Main files are read at origin/main; branch files ("<branch>:<path>")
with `git show <branch>:<path>`. Each branch is resolved to its sha so the output carries
the label "branch <branch>@<sha>, not main".

Usage: python3 -I check_sources.py [repo_dir] > sources_check.tsv
Exit 1 if any item is not on its cited line (status != ok)."""
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import inventory as inv  # noqa: E402

REPO = sys.argv[1] if len(sys.argv) > 1 else os.path.abspath(
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
MAIN_REF = "origin/main"
_cache = {}


def git(*a):
    return subprocess.run(["git", "-C", REPO] + list(a), capture_output=True, text=True, check=True).stdout


def split_src(src):
    """'<branch>:<path>:<line>' or '<path>:<line>' -> (ref, path, line)."""
    parts = src.split(":")
    if len(parts) == 3:
        return parts[0], parts[1], int(parts[2])
    return MAIN_REF, parts[0], int(parts[1])


def lines_of(ref, path):
    k = (ref, path)
    if k not in _cache:
        try:
            _cache[k] = git("show", "%s:%s" % (ref, path)).split("\n")
        except subprocess.CalledProcessError:
            _cache[k] = None
    return _cache[k]


def items():
    """(chain, role, value, src) for every address / id in CHAINS."""
    for ch, c in inv.CHAINS.items():
        for key in ("native", "num", "pm", "v1_router"):
            if c.get(key):
                yield ch, key, c[key][0], c[key][1]
        for role, lst in c.get("roles", {}).items():
            for a, s in lst:
                yield ch, "role:" + role, a, s
        for a, s in c.get("midtail", []):
            yield ch, "midtail", a, s
        for v in c.get("venues", []):
            yield ch, "venue:" + v["fam"], v["addr"], v["src"]
        for fam, vault, pool, s, vs in c.get("ext", []):
            yield ch, "ext_vault:" + fam, vault, vs
            yield ch, "ext_pool:" + fam, pool, s
        for a, s in c.get("repo_pools", []):
            yield ch, "repo_pool", a, s
        for fam, mgr, s, ids in c.get("inf", []):
            yield ch, "inf_mgr:" + fam, mgr, s
            for pid, ps in ids:
                yield ch, "inf_id:" + fam, pid, ps


def check(value, src):
    ref, path, ln = split_src(src)
    ls = lines_of(ref, path)
    sha = git("rev-parse", "--short", ref).strip()
    label = "main@%s" % sha if ref == MAIN_REF else "branch %s@%s, not main" % (ref, sha)
    if ls is None:
        return "no_file", label, ""
    needle = value.lower()[2:]
    at = [i + 1 for i, s in enumerate(ls) if needle in s.lower()]
    if ln in at:
        return "ok", label, ln
    return ("moved" if at else "absent"), label, ",".join(map(str, at[:5]))


def main():
    print("\t".join(["chain", "role", "value", "cited", "status", "ref", "found_lines"]))
    bad = 0
    for ch, role, val, src in items():
        st, label, found = check(val, src)
        bad += st != "ok"
        print("\t".join([ch, role, val, src, st, label, str(found)]))
    print("# items_not_ok=%d" % bad, file=sys.stderr)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
