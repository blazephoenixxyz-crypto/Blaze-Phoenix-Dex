#!/usr/bin/env python3
"""Pre-registrations (docs/prereg/*.tsv): what a sampled test will run, frozen before any result.

Rows are `key<TAB>value[<TAB>value]`:
  tag            the registered tag; the seeds are sha256(tag || i) and the schedule hashes are
                 sha256(tag || name), so nobody picks a sample after seeing a result
  sol            the test file the registration binds
  seed           present when the test derives its samples from _seed(i)
  const N V      a constant the test must declare with exactly this value
  extreme N L H  the range a schedule constant is drawn from (see schedule())
  must_contain   a line the test must contain verbatim (the rule, not only its numbers)
  owner K TEXT   a number that could not be derived: the owner decides it; nothing asserts it
  note TEXT      free text
  lock H         last row: sha256 hex of every byte before this row

The test carries PREREG_TAG and PREREG_LOCK (= 0x + lock) and emits the lock in its log, so a
result is tied to the registration it ran under (check_results).

  python3 tools/fuzz-coverage/prereg.py check <prereg.tsv> [root]
  python3 tools/fuzz-coverage/prereg.py lock <prereg.tsv>              print the lock of the body
  python3 tools/fuzz-coverage/prereg.py wf-blocks <prereg.tsv> <rpc_url>    (CI only)
"""
import hashlib
import json
import os
import re
import sys
import urllib.request

SEED_BODY = "return uint256(sha256(abi.encodePacked(PREREG_TAG, i)));"
SEED_SIG = "function _seed(uint256 i) internal pure returns (uint256) {"


def lock_of(body):
    return hashlib.sha256(body.encode()).hexdigest()


def _split(text):
    i = text.rfind("lock\t")
    if i < 0 or (i > 0 and text[i - 1] != "\n"):
        return text, None
    return text[:i], text[i:].rstrip("\n").split("\t")[1]


def read(path):
    text = open(path).read()
    body, lock = _split(text)
    d = dict(tag=None, sol=None, seed=False, const={}, extreme={}, must_contain=[], owner={},
             lock=lock, body=body)
    for line in body.splitlines():
        if not line:
            continue
        k, *v = line.split("\t")
        if k in ("tag", "sol"):
            d[k] = v[0]
        elif k == "seed":
            d["seed"] = True
        elif k == "const":
            d["const"][v[0]] = v[1]
        elif k == "extreme":
            d["extreme"][v[0]] = (int(v[1]), int(v[2]))
        elif k == "must_contain":
            d["must_contain"].append(v[0])
        elif k == "owner":
            d["owner"][v[0]] = v[1]
    return d


def check_lock(path):
    try:
        d = read(path)
    except (OSError, ValueError, IndexError) as e:
        return [f"{path}: unreadable: {e}"]
    if d["lock"] is None:
        return [f"{path}: no lock row"]
    if lock_of(d["body"]) != d["lock"]:
        return [f"{path}: lock {d['lock']} is not sha256(body) {lock_of(d['body'])}: edited after the lock"]
    return []


def schedule(tag, extreme):
    """Each scheduled constant is drawn from its registered extremes by the registered hash:
    value = lo + sha256(tag || name) mod (hi - lo + 1). The tag is fixed by the file name
    (<family>-<MMDD> of the registration day), so the value is not a choice."""
    out = {}
    for name, (lo, hi) in extreme.items():
        h = int.from_bytes(hashlib.sha256(tag.encode() + name.encode()).digest(), "big")
        out[name] = lo + h % (hi - lo + 1)
    return out


def _const_in(sol, name):
    m = re.search(r"\bconstant\s+" + re.escape(name) + r"\s*=\s*([^;]+);", sol)
    return m.group(1).strip() if m else None


def check_sol(path, root):
    try:
        d = read(path)
        sol = open(os.path.join(root, d["sol"])).read()
    except (OSError, ValueError, IndexError, TypeError) as e:
        return [f"{path}: cannot bind: {e}"]
    errs = []
    for name, want in sorted(d["const"].items()):
        got = _const_in(sol, name)
        if got is None or got.replace("_", "") != want.replace("_", ""):
            errs.append(f"{d['sol']}: constant {name} = {got}, registered {want}")
    for name, value in sorted(schedule(d["tag"], d["extreme"]).items()):
        if d["const"].get(name) != str(value):
            errs.append(f"{path}: {name} = {d['const'].get(name)}, the schedule draws {value}")
    tag = _const_in(sol, "PREREG_TAG")
    if tag != f'"{d["tag"]}"':
        errs.append(f"{d['sol']}: PREREG_TAG = {tag}, registered \"{d['tag']}\"")
    lk = _const_in(sol, "PREREG_LOCK")
    if lk is None or lk.lower() != "0x" + str(d["lock"]):
        errs.append(f"{d['sol']}: PREREG_LOCK = {lk}, registered 0x{d['lock']}")
    if d["seed"]:
        lines = sol.splitlines()
        at = [i for i, s in enumerate(lines) if s.strip() == SEED_SIG]
        if len(at) != 1 or at[0] + 1 >= len(lines) or lines[at[0] + 1].strip() != SEED_BODY:
            errs.append(f"{d['sol']}: _seed must be exactly `{SEED_SIG} {SEED_BODY}`")
    have = set(sol.splitlines())
    for line in d["must_contain"]:
        if line not in have:
            errs.append(f"{d['sol']}: missing the registered line `{line.strip()}`")
    return errs


def check_results(path, text):
    want = read(path)["lock"]
    m = re.search(r"PREREG_LOCK: 0x([0-9a-fA-F]{64})", text)
    if m is None:
        return [f"results carry no PREREG_LOCK line: not tied to {path}"]
    seen = m.group(1).lower()
    if seen != want:
        return [f"results ran under lock {seen}, registered {want}"]
    return []


def first_block_at(ts_of, lo, hi, target):
    """The first block whose timestamp is >= target. A target past ts_of(hi) is absent: it is
    never read as the head."""
    if ts_of(hi) < target:
        raise ValueError(f"target {target} is past block {hi} (ts {ts_of(hi)})")
    while lo < hi:
        mid = (lo + hi) // 2
        if ts_of(mid) >= target:
            hi = mid
        else:
            lo = mid + 1
    return lo


def seeds(tag, n):
    return [int.from_bytes(hashlib.sha256(tag.encode() + i.to_bytes(32, "big")).digest(), "big")
            for i in range(n)]


def _rpc(url, method, params):
    req = urllib.request.Request(url, json.dumps(dict(jsonrpc="2.0", id=1, method=method, params=params)).encode(),
                                 {"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=30) as r:
        res = json.load(r)
    if res.get("result") is None:
        raise RuntimeError(f"{method}{params}: no result ({res.get('error')})")
    return res["result"]


def wf_blocks(path, url):
    """WF_BLOCKS for the registered schedule: block k = first block at WF_T0 + k * WF_DT, for
    k < WF_N, stopping at the first target past the head (absent, never the head)."""
    d = read(path)
    t0, dt, n = (int(d["const"][k]) for k in ("WF_T0", "WF_DT", "WF_N"))
    head = int(_rpc(url, "eth_blockNumber", []), 16)
    cache = {}

    def ts_of(b):
        if b not in cache:
            cache[b] = int(_rpc(url, "eth_getBlockByNumber", [hex(b), False])["timestamp"], 16)
        return cache[b]

    out, lo = [], 1
    for k in range(n):
        try:
            b = first_block_at(ts_of, lo, head, t0 + k * dt)
        except ValueError:
            break
        out.append(b)
        lo = b
    return out


if __name__ == "__main__":
    a = sys.argv[1:]
    if a[:1] == ["lock"]:
        print(lock_of(read(a[1])["body"]))
    elif a[:1] == ["check"]:
        root = a[2] if len(a) > 2 else os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
        e = check_lock(a[1]) + check_sol(a[1], root)
        print("\n".join(e) or f"{a[1]}: lock and binding hold")
        sys.exit(1 if e else 0)
    elif a[:1] == ["wf-blocks"]:
        b = wf_blocks(a[1], a[2])
        if not b:
            sys.exit("no registered target is at or before the head yet")
        print(",".join(map(str, b)))
    else:
        sys.exit(__doc__)
