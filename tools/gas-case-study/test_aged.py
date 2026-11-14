#!/usr/bin/env python3
"""Tests of aged.py and harness.err_class on a simulated chain (stdlib unittest, no anvil, no RPC).

  python3 -I tools/gas-case-study/test_aged.py

FakeChain answers call(method, params) from a dict of state: one fork block (anvil_reset), the
user's balances, snapshots, a Quoter whose netOut follows price(block), and a Router that reverts
with RouterE(4) past the deadline and RouterE(5) under minOut (the codes of
src/BlazePhoenixRouter.sol:631 and :1665). Each test names the mutant that turns it red.
"""
import os
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import abi  # noqa: E402
import aged  # noqa: E402
import harness as H  # noqa: E402
import stats as S  # noqa: E402
from g7 import Reverted, RpcError  # noqa: E402

ROUTER, QUOTER, HUB = "0x" + "11" * 20, "0x" + "22" * 20, "0x" + "33" * 20
ADDRS = dict(router=ROUTER, quoter=QUOTER, hub=HUB)
TIN = "0x4200000000000000000000000000000000000006"
TOUT = "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913"
GAS = 150_000


def base_ts(n):  # 2 s blocks
    return 1000 + 2 * n


def arb_ts(n):  # several blocks share one timestamp (Arbitrum, Robinhood)
    return 1000 + n // 4


def router_err(code):
    return "0x" + H.fn("RouterE") + format(code, "064x")


def route_val(total):
    return dict(hops=[], totalOut=total, singleOut=total, singleOutFloor=total, expectedImpactBps=0,
                confidenceWad=0, estGas=0, hasSurplus=False, isV4Bundle=False)


def preview(net, min_out):
    return dict(route=route_val(net), grossOut=net, protocolFee=0, safetyBuffer=0, netOut=net, ironFloor=0,
                userMinOut=min_out, effectiveMinOut=min_out, estGas=0, hops=1, legs=1, topology=0,
                bridgeUsed=H.ZERO, canExecute=True)


class FakeChain:
    """A JSON-RPC node simulated by a dict: call(method, params) -> result or raise."""

    def __init__(self, ts=base_ts, price=lambda b: 10 ** 18, slip_bps=50, block=100):
        self.ts, self.price, self.slip, self.block = ts, price, slip_bps, block
        self.bal, self.snaps, self.sent, self.log = {}, {}, {}, []

    def out(self, amt):
        return amt * self.price(self.block) // 10 ** 18

    def call(self, method, params):
        self.log.append(method)
        if method == "anvil_reset":
            self.block, self.bal = params[0]["forking"]["blockNumber"], {}
            return None
        if method == "eth_getBlockByNumber":
            return {"timestamp": hex(self.ts(self.block))}
        if method in ("anvil_impersonateAccount", "anvil_setBalance"):
            return None
        if method == "anvil_dealERC20":
            self.bal[(params[0].lower(), params[1].lower())] = int(params[2], 16)
            return None
        if method == "evm_snapshot":
            sid = hex(len(self.snaps) + 1)
            self.snaps[sid] = dict(self.bal)
            return sid
        if method == "evm_revert":
            self.bal = dict(self.snaps[params[0]])
            return True
        if method == "eth_call":
            return self.eth_call(params[0])
        if method == "eth_estimateGas":
            return hex(self.execute(params[0], dry=True))
        if method == "eth_sendTransaction":
            h = "0x%064x" % (len(self.sent) + 1)
            self.sent[h] = self.execute(params[0], dry=False)
            return h
        if method == "eth_getTransactionReceipt":
            return {"status": "0x1", "gasUsed": hex(self.sent[params[0]]), "logs": []}
        raise RpcError(method)

    def eth_call(self, tx):
        d = H.strip0x(tx["data"])
        sel, args = d[:8], "0x" + d[8:]
        if sel == H.fn("balanceOf"):
            who = abi.decode(["address"], args)[0]
            return "0x" + format(self.bal.get((tx["to"].lower(), who.lower()), 0), "064x")
        if sel == H.fn("previewPlan"):
            _, _, amt = abi.decode(H.ARGS["previewPlan"], args)
            net = self.out(amt)
            pv = preview(net, net * (10000 - self.slip) // 10000)
            return "0x" + abi.encode(abi.PREVIEW_PLAN_OUT, [pv, route_val(0), False])
        raise Reverted("0x")

    def execute(self, tx, dry):
        d = H.strip0x(tx["data"])
        if d[:8] == H.fn("approve"):
            return 46_000
        if tx["to"] != ROUTER or d[:8] != H.fn("swapExactIn"):
            raise Reverted("0x")
        _, amt, min_out, user, deadline = abi.decode(H.ARGS["swapExactIn"], "0x" + d[8:])
        if self.ts(self.block) > deadline:
            raise Reverted(router_err(4))
        out = self.out(amt)
        if out < min_out:
            raise Reverted(router_err(5))
        if not dry:
            u = user.lower()
            self.bal[(TIN, u)] = self.bal.get((TIN, u), 0) - amt
            self.bal[(TOUT, u)] = self.bal.get((TOUT, u), 0) + out
        return GAS


def draw(ages=(7, 10, 25), back_s=0.0, fork_block=110, amount=10 ** 18, cell_id="base:WETH/USDC:k2", i=0):
    return dict(chain="base", cell_id=cell_id, i=i, token_in=TIN, token_out=TOUT, amount_in=str(amount),
                fork_block=fork_block, back_s=back_s, ages=list(ages), pair="WETH/USDC", seed="ab")


def fixed_deploy():
    return dict(ADDRS)


class TestBlocks(unittest.TestCase):
    """k per network from the real timestamps (mutants M1-M5)."""

    def test_exact_boundary(self):  # M1: ts(n) + age -> ts(n) + age + 1
        self.assertEqual(aged.exec_block(base_ts, 100, 10), (105, 5, 10))

    def test_between_blocks(self):  # M2: ts(n) + age -> ts(n) + age - 1
        self.assertEqual(aged.exec_block(base_ts, 100, 7), (104, 4, 8))

    def test_age_zero(self):  # M3: n - 1, n + 1 -> n, n + 1
        self.assertEqual(aged.exec_block(base_ts, 100, 0), (100, 0, 0))

    def test_equal_timestamps(self):  # M2 too: 4 blocks per second
        self.assertEqual(aged.exec_block(arb_ts, 100, 7), (128, 28, 7))

    def test_quote_block_equal_ts(self):  # M4: no downward widening
        self.assertEqual(aged.quote_block(arb_ts, 102, 0), 100)

    def test_quote_block_back(self):  # M5: t = ts(fork_block) (back_s ignored)
        self.assertEqual(aged.quote_block(base_ts, 10000, 14230.456), 2885)


class TestErrClass(unittest.TestCase):
    """The revert classes (mutant M6 swaps 4 and 5)."""

    def test_codes(self):
        self.assertEqual(H.err_class(router_err(5)), "minOut")
        self.assertEqual(H.err_class(router_err(4)), "deadline")
        self.assertEqual(H.err_class(router_err(8)), "RouterE(8)")
        self.assertEqual(H.err_class("0x4e487b71" + format(17, "064x")), "Panic(17)")


class TestRunDraw(unittest.TestCase):
    def test_price_drop_reverts_minout(self):  # M7: pv.effectiveMinOut -> 1 on the aged route
        ch = FakeChain(price=lambda b: 10 ** 18 if b < 103 else 10 ** 18 * 99 // 100)
        rows = aged.run_draw(draw(back_s=20.0), ch, base_ts, "url", fixed_deploy)
        self.assertEqual([r["status"] for r in rows], ["revert"] * 3)
        self.assertEqual({r["err"] for r in rows}, {"minOut"})
        self.assertTrue(all(r["out_exec"] == "" and r["d_bps_vs_fresh"] == "" for r in rows))

    def test_deadline(self):  # M8: s.deadline = deadline dropped (the Session's own deadline is used)
        ch = FakeChain()
        rows = aged.run_draw(draw(ages=(25,), back_s=20.0), ch, base_ts, "url", fixed_deploy, deadline_s=5)
        self.assertEqual((rows[0]["status"], rows[0]["err"]), ("revert", "deadline"))

    def test_addr_drift(self):  # M9: the address comparison disabled
        n = [0]

        def drifting():
            n[0] += 1
            return dict(ADDRS, router=ROUTER if n[0] == 1 else "0x" + "44" * 20)
        ch = FakeChain()
        rows = aged.run_draw(draw(back_s=20.0), ch, base_ts, "url", drifting)
        self.assertEqual({r["status"] for r in rows}, {"prereq:addr_drift"})
        self.assertNotIn("eth_sendTransaction", ch.log)

    def test_out_is_balance_delta_and_bps(self):  # M10: bps divides by a, not b
        ch = FakeChain(price=lambda b: 10 ** 18 if b < 103 else 10 ** 18 * 998 // 1000, slip_bps=50)
        r = aged.run_draw(draw(ages=(7,), back_s=20.0), ch, base_ts, "url", fixed_deploy)[0]
        self.assertEqual((r["status"], r["out_exec"], r["out_fresh_exec"]), ("ok", 998 * 10 ** 15, 998 * 10 ** 15))
        self.assertEqual(r["out_orig"], 10 ** 18)
        self.assertEqual(r["d_bps_vs_fresh"], 0)
        self.assertAlmostEqual(r["d_bps_vs_orig"], -20.0)
        self.assertEqual(r["gas_real"], GAS)

    def test_same_exec_block_measured_once(self):  # M11: `if e not in done` -> `if True`
        ch = FakeChain()
        rows = aged.run_draw(draw(ages=(7, 8), back_s=20.0), ch, base_ts, "url", fixed_deploy)
        self.assertEqual(rows[0]["block_exec"], rows[1]["block_exec"])
        self.assertEqual(ch.log.count("anvil_reset"), 2)


def row(cell, status, err="", chain="base", age=7, d=""):
    return dict(chain=chain, cell_id=cell, age_s_target=str(age), status=status, err=err,
                d_bps_vs_fresh=d, d_bps_vs_orig=d)


class TestSummary(unittest.TestCase):
    def rows(self):
        a = [row("c:a:k2", "revert", "minOut")] + [row("c:a:k2", "ok", d="-1")] * 3
        b = [row("c:b:k2", "revert", "minOut")] * 3 + [row("c:b:k2", "ok", d="2"), row("c:b:k2", "prereq:fund")]
        return {(r["stratum"], r["metric"]): r for r in aged.summary(a + b, b=200)}

    def test_pooled_wilson(self):  # M12: the pooled stratum dropped; M13: prereq rows counted as executed
        s = self.rows()
        p = s[("base:all:7s", "revert_rate")]
        self.assertEqual((p["n"], p["median"]), (8, 0.5))
        self.assertEqual((p["ci95_lo"], p["ci95_hi"]), S.wilson(4, 8))
        self.assertEqual(s[("c:b:k2:7s", "revert_rate")]["n"], 4)
        self.assertEqual(s[("c:b:k2:7s", "absent")]["n"], 1)

    def test_per_error_and_seed(self):
        s = self.rows()
        self.assertEqual(s[("c:a:k2:7s", "revert_rate:minOut")]["median"], 0.25)
        self.assertEqual(s[("c:a:k2:7s", "d_bps_vs_fresh")]["boot_seed"], aged.stratum_seed("c:a:k2:7s"))


PLAN = ("tag\tgas-1114-aged\n"
        "schema\tcell\tcell_id chain fork_block token_a token_b bucket whale_usd n ages_s\n"
        "schema\tdraw\tcell_id i token_in token_out seed_size seed_block back_s size_usd amount_in\n"
        "const\tN\t8\n"
        f"draw\tbase:WETH/USDC:k2\t1\t{TIN}\t{TOUT}\taa\tbb\t60.5\t100\t5\n"
        f"draw\tbase:WETH/USDC:k2\t0\t{TOUT}\t{TIN}\tcc\tdd\t61\t100\t7\n"
        f"cell\tbase:WETH/USDC:k2\tbase\t110\t{TIN}\t{TOUT}\tk2\t1000\t8\t7,10,25\n"
        "out\tbase:X/Y:k6\tbucket floor >= whale\n")


def write_plan(body, lock=True):
    f = tempfile.NamedTemporaryFile("w", suffix=".tsv", delete=False)
    f.write(body + (f"lock\t{H._prereg.lock_of(body)}\n" if lock else ""))
    f.close()
    return f.name


class TestReadAged(unittest.TestCase):
    def test_locked_plan_i_major(self):  # M14: draws kept in file order, not i-major
        p = aged.read_aged(write_plan(PLAN), "base")
        self.assertEqual([(d["i"], d["amount_in"]) for d in p["draws"]], [(0, "7"), (1, "5")])
        self.assertEqual((p["draws"][0]["fork_block"], p["draws"][0]["ages"], p["draws"][0]["pair"]),
                         (110, [7, 10, 25], "WETH/USDC"))
        self.assertEqual(len(p["outs"]), 1)

    def test_unlocked_refused(self):  # M15: the lock check disabled
        with self.assertRaises(H.PreregError):
            aged.read_aged(write_plan(PLAN, lock=False), "base")
        self.assertEqual(len(aged.read_aged(write_plan(PLAN, lock=False), "base", True)["draws"]), 2)

    def test_malformed_refused(self):
        for bad in (PLAN.replace("\t5\n", "\t5.5\n"), PLAN.replace("draw\tbase:WETH/USDC:k2\t1", "draw\tbase:Z:k2\t1"),
                    PLAN.replace("schema\tdraw", "schema\tdrawx")):
            with self.assertRaises(H.PreregError):
                aged.read_aged(write_plan(bad), "base")


class TestCmdRun(unittest.TestCase):
    def test_resume_and_stats(self):  # a second run adds no row (resume by cell_id, i)
        out = tempfile.mkdtemp()
        p = write_plan(PLAN.replace("\t5\n", f"\t{10 ** 18}\n").replace("\t7\n", f"\t{10 ** 18}\n"))
        ch = FakeChain()
        self.assertEqual(aged.cmd_run("base", p, out, ch, base_ts, "url", fixed_deploy), 6)
        self.assertEqual(aged.cmd_run("base", p, out, ch, base_ts, "url", fixed_deploy), 0)
        rows = S.read_tsv(os.path.join(out, "aged.tsv"))
        self.assertEqual(list(rows[0])[:len(aged.RESULT_COLS)], aged.RESULT_COLS)
        st = {(r["stratum"], r["metric"]): r for r in S.read_tsv(os.path.join(out, "aged-stats.tsv"))}
        self.assertEqual(st[("base:all:7s", "revert_rate")]["n"], "2")


if __name__ == "__main__":
    unittest.main()
