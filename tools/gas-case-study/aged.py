#!/usr/bin/env python3
"""Gas case study 1114, aged passed route: a route quoted at block N, executed k blocks later.

  python3 -I tools/gas-case-study/aged.py run <chain> <gas-1114-aged.tsv> <outdir> <anvil_url> \
      --deploy "<cmd>" [--nprime 8] [--allow-unlocked]
  python3 -I tools/gas-case-study/aged.py stats <aged.tsv> <aged-stats.tsv>
  python3 -I tools/gas-case-study/aged.py block <chain> <gas-1114-aged.tsv> [--allow-unlocked]

Plan (docs/prereg/gas-1114-aged.tsv, rules seed_block, ages, execution, metrics):
  N = the first block with ts >= ts(fork_block) - back_s; for each age in the cell's ages_s,
  block_exec = the first block with ts >= ts(N) + age. Both come from the REAL chain's block
  timestamps (the block time is measured, never assumed; Arbitrum and Robinhood: L2 timestamps).
  k_blocks = block_exec - N and age_s_real = ts(block_exec) - ts(N) are written.
One anvil, forks in series (anvil_reset), never two alive:
  reset N        -> deploy -> Quoter.previewPlan -> pv.route, out_orig = pv.netOut
  reset N + k    -> deploy (the same G7_PK, so CREATE(sender, nonce) gives the same addresses
                    [derived]; if they differ the row is prereq:addr_drift, nothing is sent)
                 -> snapshot, fund, swapExactIn(pv.route, amountIn, pv.effectiveMinOut, user,
                    ts(N) + DEADLINE_S) -> status, err, gas_real, out_exec (balanceOf delta, I2)
                 -> revert, fresh quote, execute it -> out_fresh_exec -> revert
err: minOut (RouterE(5), src/BlazePhoenixRouter.sol:1665), deadline (RouterE(4), :631),
RouterE(n), Error:<text>, Panic(n), empty or 0x<selector> (harness.err_class).
The deploy command prints `G7ADDR <name> <addr>` lines (run.sh __deploy <chain> <url>).
The real RPC URL holds a key: it goes to anvil_reset and is never printed or written.
"""
import hashlib
import os
import shlex
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)
import harness as H  # noqa: E402
import stats as S  # noqa: E402
from g7 import Reverted, Rpc, RpcError, first_at_or_after  # noqa: E402

RESULT_COLS = ("chain block_quote block_exec age_s_target age_s_real k_blocks pair amount_in seed status err "
               "out_orig out_exec out_fresh_exec d_bps_vs_fresh d_bps_vs_orig gas_real").split()
# the prereg's `schema result` columns, in its order; cell_id and i are appended (the bucket and the
# draw are not recoverable from the schema's columns, and the strata are per bucket)
COLS = RESULT_COLS + ["cell_id", "i"]
BOOT_TAG = "gas-1114-aged-boot|"
CELL_REQ = ("cell_id", "chain", "fork_block", "ages_s")
DRAW_REQ = ("cell_id", "i", "token_in", "token_out", "back_s", "amount_in")


class AddrDrift(Exception):
    pass


# ── prereg ──
def read_aged(path, chain=None, allow_unlocked=False):
    """{consts, draws, outs}: every draw joined to its cell (chain, fork_block, ages, pair, bucket),
    validated; a malformed row is refused with its line number, an unlocked file too unless
    allow_unlocked (fail closed)."""
    errs = H._prereg.check_lock(path)
    if errs and not allow_unlocked:
        raise H.PreregError("; ".join(errs))
    with open(path) as fh:
        body, _ = H._prereg._split(fh.read())
    schema, consts, cells, raw, outs = {}, {}, {}, [], []
    for n, ln in enumerate(body.split("\n"), 1):
        f = ln.split("\t")
        if f[0] == "schema" and len(f) >= 3:
            schema[f[1]] = f[2].split()
        elif f[0] == "const" and len(f) >= 3:
            consts[f[1]] = f[2]
        elif f[0] in ("cell", "draw", "out"):
            raw.append((n, f[0], f[1:]))
    for t in ("cell", "draw"):
        if t not in schema:
            raise H.PreregError(f"{path}: no `schema {t}` row")
    for n, t, f in raw:
        if t == "out":
            outs.append(dict(cell_id=f[0], reason=f[1] if len(f) > 1 else ""))
            continue
        if len(f) != len(schema[t]):
            raise H.PreregError(f"{path}:{n}: {len(f)} fields, {len(schema[t])} columns")
        r = dict(zip(schema[t], f))
        for c in (CELL_REQ if t == "cell" else DRAW_REQ):
            if r.get(c, "") == "":
                raise H.PreregError(f"{path}:{n}: empty {c}")
        if t == "cell":
            r["ages"] = [int(a) for a in r["ages_s"].split(",")]
            r["pair"] = r["cell_id"].split(":")[1] if r["cell_id"].count(":") >= 2 else ""
            cells[r["cell_id"]] = r
            continue
        for c in ("token_in", "token_out"):
            if not H.ADDR.match(r[c]):
                raise H.PreregError(f"{path}:{n}: {c} is not 0x+40hex")
        if not H.UINT.match(r["amount_in"]) or int(r["amount_in"]) == 0:
            raise H.PreregError(f"{path}:{n}: amount_in is not a positive integer in wei")
        try:
            int(r["i"]), float(r["back_s"])
        except ValueError:
            raise H.PreregError(f"{path}:{n}: i or back_s is not a number")
    draws = []
    for n, t, f in raw:
        if t != "draw":
            continue
        r = dict(zip(schema["draw"], f))
        c = cells.get(r["cell_id"])
        if c is None:
            raise H.PreregError(f"{path}:{n}: draw of an unknown cell {r['cell_id']}")
        if chain is not None and c["chain"] != chain:
            continue
        r.update(chain=c["chain"], fork_block=int(c["fork_block"]), ages=c["ages"], pair=c["pair"],
                 bucket=c.get("bucket", ""), i=int(r["i"]), back_s=float(r["back_s"]), _line=n)
        r["seed"] = r.get("seed_size", r.get("seed", ""))
        draws.append(r)
    draws.sort(key=lambda r: (r["i"], r["_line"]))  # runs go i-major (rule reduction)
    return dict(consts=consts, draws=draws, outs=outs)


# ── blocks (real timestamps) ──
def quote_block(ts, fork_block, back_s):
    """N = the first block with ts >= ts(fork_block) - back_s (<= fork_block)."""
    t = ts(fork_block) - back_s
    step, lo = 1, fork_block - 1
    while lo > 0 and ts(lo) >= t:  # widen downwards until ts(lo) < t
        step *= 2
        lo = max(0, fork_block - step)
    if ts(lo) >= t:
        return lo
    return first_at_or_after(ts, t, lo, fork_block)


def exec_block(ts, n, age):
    """(block_exec, k_blocks, age_s_real): the first block >= N with ts >= ts(N) + age; age 0 -> N."""
    e = first_at_or_after(ts, ts(n) + age, n - 1, n + 1)
    return e, e - n, ts(e) - ts(n)


# ── one draw ──
def deploy_cmd(cmd, url):
    """A deploy callable from a shell command: it gets the anvil URL as its last argument and
    prints `G7ADDR <name> <addr>` lines."""
    def run():
        p = subprocess.run(shlex.split(cmd) + [url], capture_output=True, text=True, timeout=3600)
        if p.returncode != 0:
            raise RpcError(f"deploy exit {p.returncode}")
        out = {}
        for ln in p.stdout.splitlines():
            f = ln.split()
            if len(f) >= 3 and f[-3] == "G7ADDR" and H.ADDR.match(f[-1]):
                out[f[-2]] = f[-1]
        return out
    return run


def fork_at(node, real_url, block, deploy, want=None):
    node.call("anvil_reset", [{"forking": {"jsonRpcUrl": real_url, "blockNumber": block}}])
    a = deploy()
    if want is not None and any(a.get(k) != v for k, v in want.items() if k in ("router", "quoter", "hub")):
        raise AddrDrift(block)
    return a


def execute(s, tin, tout, amt, r, min_out):
    """(status, err, out, gas): balanceOf delta of tokenOut (I2), never the Router's return."""
    if not s.fund(tin, amt):
        return "prereq:fund", "", "", ""
    b0 = s.balance(tout)
    res = s.send(s.a["router"], H.cd("swapExactIn", r, amt, min_out, s.user, s.deadline))
    if res["status"] != "ok":
        return "revert", res["err"], "", ""
    return "ok", "", s.balance(tout) - b0, res["gas"]


def bps(a, b):
    if a == "" or b == "" or not b:
        return ""
    return 10000 * (a - b) / b


def run_draw(d, node, real_ts, real_url, deploy, deadline_s=H.DEADLINE_S, session=H.Session):
    """The rows of one draw, one per age (paired: one N, one amount, one route)."""
    tin, tout, amt = d["token_in"], d["token_out"], int(d["amount_in"])
    n = quote_block(real_ts, d["fork_block"], d["back_s"])
    base = dict(chain=d["chain"], block_quote=n, pair=d["pair"], amount_in=amt, seed=d["seed"],
                cell_id=d["cell_id"], i=d["i"])
    rows = []
    ages = []
    for age in d["ages"]:
        e, k, real = exec_block(real_ts, n, age)
        ages.append(dict(base, age_s_target=age, block_exec=e, k_blocks=k, age_s_real=real))
    try:
        a0 = fork_at(node, real_url, n, deploy)
        s = session(node, None, d["chain"], a0, n)
        pv, err = s.quote(tin, tout, amt)
    except (RpcError, Reverted) as ex:
        return [dict(r, status="prereq:fork_quote", err=type(ex).__name__) for r in ages]
    if pv is None:
        return [dict(r, status="quote_failed", err=err) for r in ages]
    deadline = real_ts(n) + deadline_s
    done = {}
    for r in ages:
        e = r["block_exec"]
        if e not in done:  # two ages on the same block_exec are the same fork: measured once
            try:
                a = fork_at(node, real_url, e, deploy, want=a0)
            except AddrDrift:
                done[e] = dict(status="prereq:addr_drift", err="")
            else:
                s = session(node, None, d["chain"], a, e)
                s.deadline = deadline
                snap = s.snapshot()
                st, er, out, gas = execute(s, tin, tout, amt, pv["route"], pv["effectiveMinOut"])
                s.revert(snap)
                snap = s.snapshot()
                fpv, ferr = s.quote(tin, tout, amt)
                fresh = ""
                if fpv is not None:
                    s.deadline = real_ts(e) + deadline_s
                    fst, _, fout, _ = execute(s, tin, tout, amt, fpv["route"], fpv["effectiveMinOut"])
                    fresh = fout if fst == "ok" else ""
                s.revert(snap)
                done[e] = dict(status=st, err=er, out_exec=out, out_fresh_exec=fresh, gas_real=gas)
        m = dict(done[e])
        m.update(out_orig=pv["netOut"], d_bps_vs_fresh=bps(m.get("out_exec", ""), m.get("out_fresh_exec", "")),
                 d_bps_vs_orig=bps(m.get("out_exec", ""), pv["netOut"]))
        rows.append(dict(r, **m))
    return rows


# ── summary ──
def stratum_seed(stratum_id):
    return int(hashlib.sha256((BOOT_TAG + stratum_id).encode()).hexdigest(), 16)


def summary(rows, b=S.BOOT_B):
    """aged-stats.tsv rows (stats.tsv columns): per cell_id x age (stratum `<cell_id>:<age>s`) and
    pooled per chain x age (`<chain>:all:<age>s`): revert_rate and revert_rate:<err> with Wilson's
    interval over the executed draws (status ok or revert; prereq and quote failures are absent,
    counted in metric `absent`), d_bps_vs_fresh and d_bps_vs_orig on the ones that pass."""
    groups = {}
    for r in rows:
        age = r["age_s_target"]
        for sid in (f"{r['cell_id']}:{age}s", f"{r['chain']}:all:{age}s"):
            groups.setdefault((r["chain"], sid), []).append(r)
    out = []
    for (chain, sid), g in sorted(groups.items()):
        seed = stratum_seed(sid)
        ex = [r for r in g if r["status"] in ("ok", "revert")]
        rev = [r for r in ex if r["status"] == "revert"]
        out.append(S.rate_row(chain, sid, "revert_rate", len(rev), len(ex), ""))
        for e in sorted({r["err"] for r in rev}):
            out.append(S.rate_row(chain, sid, f"revert_rate:{e}", sum(r["err"] == e for r in rev), len(ex), ""))
        out.append(dict(chain=chain, stratum=sid, metric="absent", n=len(g) - len(ex)))
        for m in ("d_bps_vs_fresh", "d_bps_vs_orig"):
            vals = [float(r[m]) for r in ex if r["status"] == "ok" and str(r[m]) != ""]
            out.append(S.summarize(chain, sid, m, vals, seed, b))
    return out


# ── CLI ──
def cmd_run(chain, prereg, outdir, node, real_ts, real_url, deploy, nprime=8, allow_unlocked=False):
    plan = read_aged(prereg, chain, allow_unlocked)
    draws = S.reduce_prefix(plan["draws"], nprime)
    os.makedirs(outdir, exist_ok=True)
    res = os.path.join(outdir, "aged.tsv")
    done = H.read_done(res, key=("cell_id", "i"))
    n = 0
    for d in draws:
        if (d["cell_id"], str(d["i"])) in done:
            continue
        rows = run_draw(d, node, real_ts, real_url, deploy)
        H.append(res, COLS, rows)
        n += len(rows)
    S.write_tsv(os.path.join(outdir, "aged-stats.tsv"), S.STATS_COLS, summary(S.read_tsv(res)))
    return n


def main(argv):
    if len(argv) < 1:
        sys.exit(__doc__)
    if argv[0] == "block" and len(argv) >= 3:  # the cells' one fork block (run.sh --only-aged)
        bs = {d["fork_block"] for d in read_aged(argv[2], argv[1], "--allow-unlocked" in argv)["draws"]}
        if len(bs) != 1:
            sys.exit(f"{argv[1]}: {len(bs)} fork blocks in the plan, want exactly 1")
        print(bs.pop())
        return
    if argv[0] == "stats" and len(argv) >= 3:
        S.write_tsv(argv[2], S.STATS_COLS, summary(S.read_tsv(argv[1])))
        return
    if argv[0] != "run" or len(argv) < 5 or "--deploy" not in argv:
        sys.exit(__doc__)
    chain, prereg, outdir, url = argv[1:5]
    nprime = int(argv[argv.index("--nprime") + 1]) if "--nprime" in argv else 8
    real = Rpc(chain)
    n = cmd_run(chain, prereg, outdir, H.Node(url), real.ts, real._url,
                deploy_cmd(argv[argv.index("--deploy") + 1], url), nprime, "--allow-unlocked" in argv)
    print(f"rows {n}")


if __name__ == "__main__":
    main(sys.argv[1:])
