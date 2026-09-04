#!/usr/bin/env python3
"""Where in the sources each compiler panic could come from, and what guards it.

panic_inventory.py reads the artefact and says which Panic(uint256) codes the deployed contract
can raise. That is the question "does this refusal exist". This is the other half: WHICH
CONSTRUCT in the sources made the compiler emit it, and whether anything of ours refuses first.

The three the artefact reports and no test asserts:

  0x12  a division or modulo whose divisor is not provably non-zero
  0x32  an index into a dynamic array or bytes that is not provably in range
  0x41  an allocation whose size is not provably bounded

For each site the enclosing function is searched for a guard that would make the panic
unreachable - a comparison of the divisor against zero, a length check before the index, a bound
on the allocation size. A site with a guard is one where our named refusal fires first and the
compiler's handler is dead weight; a site without one is a place where behaviour under an
unexpected input is the compiler's decision rather than ours.

This is a SCREEN over text, not a proof of reachability. A divisor can be non-zero by an argument
three frames up that no regex sees, and a guard can be present and not dominate the use. It
produces a reading list ordered by how little there is to read, which is the useful shape when
the alternative is reading every division in the contract.

Usage: python3 panic_sites.py <repo_root>
"""
import re, os, sys, glob, json

ROOT = sys.argv[1] if len(sys.argv) > 1 else "."

def strip_comments(src):
    src = re.sub(r"/\*.*?\*/", " ", src, flags=re.S)
    return "\n".join(l.split("//")[0] for l in src.splitlines())

def functions(src):
    out = []
    for m in re.finditer(r"function\s+(\w+)\s*\(", src):
        i = src.find("{", m.end())
        if i < 0: continue
        d, j = 0, i
        while j < len(src):
            if src[j] == "{": d += 1
            elif src[j] == "}":
                d -= 1
                if d == 0: break
            j += 1
        out.append((m.group(1), m.start(), j, src[i:j]))
    return out

CONSTANT = re.compile(r"^[A-Z][A-Z0-9_]{2,}$")

rows = []
for p in sorted(glob.glob(os.path.join(ROOT, "src", "*.sol"))):
    raw = open(p).read()
    src = strip_comments(raw)
    name = os.path.basename(p)[12:-4]
    fns = functions(src)

    def enclosing(pos):
        c = [f for f in fns if f[1] <= pos <= f[2]]
        return min(c, key=lambda f: f[2] - f[1]) if c else (None, 0, 0, "")

    # 0x12 - division or modulo by a non-constant
    for m in re.finditer(r"[)\]\w]\s*[/%]\s*([A-Za-z_]\w*)", src):
        d = m.group(1)
        if CONSTANT.match(d): continue           # named constants are non-zero by declaration
        fn, _s, _e, body = enclosing(m.start())
        if fn is None: continue                  # not inside a function: an import path
        guarded = bool(re.search(r"\b%s\s*(?:==|!=|>|>=)\s*0\b" % re.escape(d), body) or
                       re.search(r"\b0\s*(?:==|!=|<|<=)\s*%s\b" % re.escape(d), body) or
                       re.search(r"\b%s\s*>\s*0\s*\?" % re.escape(d), body))
        rows.append({"panic": "0x12", "file": name, "fn": fn, "what": d,
                     "line": src.count("\n", 0, m.start()) + 1, "guarded": guarded})

    # 0x32 - index into a dynamic array or bytes with a non-constant index
    for m in re.finditer(r"\b(\w+(?:\.\w+)*)\s*\[\s*([A-Za-z_]\w*)\s*\]", src):
        arr, idx = m.group(1), m.group(2)
        if CONSTANT.match(idx): continue
        if arr.startswith("$."):                 # a mapping: no bounds to exceed
            continue
        fn, _s, _e, body = enclosing(m.start())
        if fn is None: continue
        guarded = bool(re.search(r"\b%s\s*<\s*[\w.]*length" % re.escape(idx), body) or
                       re.search(r"\b%s\s*>=\s*[\w.]*length[^;]*revert" % re.escape(idx), body) or
                       re.search(r"for\s*\([^;]*;\s*%s\s*<\s*" % re.escape(idx), body))
        rows.append({"panic": "0x32", "file": name, "fn": fn, "what": f"{arr}[{idx}]",
                     "line": src.count("\n", 0, m.start()) + 1, "guarded": guarded})

    # 0x41 - allocation with a non-constant size
    for m in re.finditer(r"new\s+[\w.\[\]]+\s*\(\s*([A-Za-z_][\w.]*)\s*\)", src):
        n = m.group(1)
        if CONSTANT.match(n): continue
        fn, _s, _e, body = enclosing(m.start())
        if fn is None: continue
        guarded = bool(re.search(r"\b%s\s*>\s*[A-Z_]+[^;]*revert" % re.escape(n.split(".")[0]), body) or
                       re.search(r"\b%s\s*<=?\s*[A-Z_]{3,}" % re.escape(n.split(".")[0]), body) or
                       "MAX_" in body)
        rows.append({"panic": "0x41", "file": name, "fn": fn, "what": f"new [{n}]",
                     "line": src.count("\n", 0, m.start()) + 1, "guarded": guarded})

for code in ("0x12", "0x32", "0x41"):
    sel = [r for r in rows if r["panic"] == code]
    un = [r for r in sel if not r["guarded"]]
    print(f"\n=== {code} : {len(sel)} sites, {len(un)} with no guard found in the enclosing function")
    for r in sorted(un, key=lambda r: (r["file"], r["line"]))[:14]:
        print(f"  {r['file']:8}:{r['line']:<5} {r['fn']:26} {r['what']}")

tot = len(rows); ung = len([r for r in rows if not r["guarded"]])
print(f"\nsites that could raise a panic : {tot}")
print(f"  with a guard in the function : {tot - ung}")
print(f"  with none found              : {ung}")
print("\nA site with no guard FOUND is not a reachable panic: the screen reads one function and")
print("a value can be constrained elsewhere. It is a reading list, ordered so that the shortest")
print("list is the one that gets read.")
json.dump({"sites": tot, "unguarded": ung, "rows": rows},
          open(os.path.join(ROOT, "assurance-panic-sites.json"), "w"), indent=1)
