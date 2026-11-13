#!/usr/bin/env python3
"""Offline tests for build_spec.py (synthetic inventory, no RPC, no key).
Run: python3 -I tools/g7-gas-campaign/test_build_spec.py

Each test names the mutant of build_spec.py that turns it red; mutants_build_spec.py applies
every one of them and checks that its test goes red. Run the mutants in a separate command.
"""
import json
import os
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import build_spec as bs  # noqa: E402
import inventory  # noqa: E402

INV_COLS = ("chain,family,factory,pool,token0,token1,fee,tick_spacing,hooks,created_block,code_len,codehash,b_inv,"
            "bal0,bal1,liquidity_raw,liq_usd,class,source,liq_method,ref,note").split(",")


def a(n):
    return "0x" + format(n, "040x")


# base
W, U = a(0x1001), a(0x1002)
C1, C2, CX, B2, B3 = a(0xC1), a(0xC2), a(0xCF), a(0xB2), a(0xB3)
V3A, V3B, V2P = a(0xA1), a(0xA2), a(0xA3)
V4ID = "0x" + "ab" * 12 + "cd" * 20  # PoolId; the Hub keys it by its last 20 bytes
B2ID = "0x" + B2[2:] + "000200000000000000000103"
# avalanche
X, U2 = a(0x2001), a(0x2002)
LBF1, LBF2 = "0x8e42f2F4101563bf679975178e880Fd87d3eFd4e", "0xb43120c4745967fa9b93E79C149E66B0f2D6Fe0c"
L1, L2, L3, AL1, AL2 = a(0x21), a(0x22), a(0x23), a(0x24), a(0x25)
DEP = "0x5D433A94A4a2aA8f9AA34D8D15692Dc2E9960584"
# bsc
BN, U3 = a(0x3001), a(0x3002)
IC1, IB1 = "0x" + "9a" * 32, "0x" + "9b" * 32
# optimism / arbitrum
O, U4, AR, U5, ACRV = a(0x4001), a(0x4002), a(0x5001), a(0x5002), a(0x51)


def row(chain, fam, pool, t0, t1, liq, cls, bal0=10 ** 18, bal1=10 ** 18, ts="", factory=a(0xF), hooks=""):
    r = dict.fromkeys(INV_COLS, "")
    r.update(chain=chain, family=fam, factory=factory, pool=pool, token0=t0, token1=t1, fee="500", tick_spacing=ts,
             hooks=hooks, bal0=str(bal0), bal1=str(bal1), liq_usd="" if liq is None else str(liq), **{"class": cls})
    return r


def inventory_rows():
    t = lambda n: a(0x1100 + n)
    R = [
        # gates, base: C2 listed before the deeper C1 (rank comes from liq, not file order)
        row("base", "curve_ng", C2, W, U, 100, "gate_top3"),
        row("base", "curve_ng", C1, W, U, 5000, "gate_top3,major"),
        row("base", "curve_ng", CX, W, U, 9999, "major"),  # gate family, not gate_top3: no wrapper
        row("base", "balancer_v2", B2, W, U, 50, "gate_top3"),
        row("base", "balancer_v3", B3, W, U, None, "gate_top3", bal0=5 * 10 ** 17),  # liq absent, balances measured
        # seedable pools of W/U
        row("base", "v3", V3A, W, U, 1000, "major"),
        row("base", "v4", V4ID, W, U, 950, ""),
        row("base", "v3", V3B, W, U, 900, ""),
        row("base", "v2", V2P, W, U, 800, "", bal0=10 ** 9),
        # majors: W/U plus 5 more pairs, quota 5
        row("base", "v3", a(0x1203), W, t(3), 600, "major,fee_high"),
        row("base", "v2", a(0x1204), U, t(4), 500, "major"),
        row("base", "v3", a(0x1205), W, t(5), 400, "major"),
        row("base", "v3", a(0x1206), W, t(6), 300, "major"),
        row("base", "v3", a(0x1207), W, t(7), 200, "major"),
        row("base", "v3", a(0x1208), W, t(8), 150, "major"),
        row("base", "v3", a(0x1209), t(9), t(10), 90, "midtail"),
        row("base", "v3", a(0x1211), t(11), t(12), 80, "midtail"),
        row("base", "v3", a(0x1213), t(13), t(14), 70, "fee_high"),
        row("base", "v2", a(0x1215), t(15), t(16), 60, "family_rep"),
        row("base", "v2", a(0x1217), t(17), t(18), 55, "family_rep"),  # same family as the one above
        row("base", "solidly", a(0x1219), t(19), t(20), 50, "family_rep"),
        # shallow: ascending liq, absent liq never chosen
        row("base", "v2", a(0x1221), t(21), t(22), 5, "shallow", 150, 150),
        row("base", "v2", a(0x1223), t(23), t(24), 1, "shallow", 150, 150),
        row("base", "v2", a(0x1225), t(25), t(26), None, "shallow", 150, 150),
        row("base", "v2", a(0x1227), t(27), t(28), 3, "shallow", 150, 150),
        row("base", "v2", a(0x1229), t(29), t(30), 10, "shallow", 150, 150),
        # avalanche: LB per factory, Algebra with and without a custom deployer
        row("avalanche", "lb", L1, X, U2, 300, "gate_top3", ts="25", factory=LBF1),
        row("avalanche", "lb", L2, X, U2, 200, "gate_top3", ts="10", factory=LBF1),
        row("avalanche", "lb", L3, X, U2, 100, "gate_top3", ts="20", factory=LBF2),
        row("avalanche", "algebra_integral", AL1, X, U2, 400, "gate_top3"),
        row("avalanche", "algebra_integral", AL2, X, U2, 350, "gate_top3"),
        row("avalanche", "v3", a(0x2101), X, U2, 50, "major"),
        # bsc: Infinity pools carry a PoolId
        dict(row("bsc", "inf_cl", IC1, BN, U3, 100, "gate_top3", hooks=a(0xB0BA)),
             liq_method="CLPoolManager.getLiquidity(id);bal=virtual(L,sqrtP);liq_virtual_at_price, n\u00e3o TVL"),
        row("bsc", "inf_bin", IB1, BN, U3, 90, "gate_top3"),
        row("bsc", "v3", a(0x3101), BN, U3, 20, "major"),
        # optimism: no gate family at all; arbitrum: a gate family with no adapter number
        row("optimism", "v3", a(0x4101), O, U4, 10, "major"),
        row("arbitrum", "curve_ng", ACRV, AR, U5, 10, "gate_top3"),
        row("arbitrum", "v3", a(0x5101), AR, U5, 10, "major"),
    ]
    return R


TOKENS = [("base", W, "WETH", "test/fork/MultichainProbe.t.sol"), ("base", a(0x1999), "WETH", "pool-token"),
          ("avalanche", X, "WAVAX", "avax-adapters-1106:x"), ("bsc", BN, "WBNB", "bsc-infinity-1106:x"),
          ("optimism", O, "WETH", "test/fork/MultichainProbe.t.sol"), ("arbitrum", AR, "WETH", "test/fork/MultichainProbe.t.sol")]

ONCHAIN = ([{"chain": c, "key": "block_time", "subject": c, "value": "2.0", "source": "t"}
            for c in ("base", "avalanche", "bsc", "optimism", "arbitrum")] +
           [{"chain": "base", "key": "balv2_poolid", "subject": B2, "value": B2ID.upper().replace("0X", "0x"), "source": "t"},
            {"chain": "avalanche", "key": "algebra_deployer", "subject": AL1, "value": DEP, "source": "t"},
            {"chain": "avalanche", "key": "algebra_deployer", "subject": AL2, "value": "none", "source": "t"}])


def write_inputs(d, rows=None):
    with open(os.path.join(d, "inventory.tsv"), "w") as f:
        f.write("\t".join(INV_COLS) + "\n")
        for r in rows or inventory_rows():
            f.write("\t".join(r[c] for c in INV_COLS) + "\n")
    with open(os.path.join(d, "tokens.tsv"), "w") as f:
        f.write("chain\ttoken\tsymbol\tdecimals\tcode_len\tsource\tref\n")
        for c, t, s, src in TOKENS:
            f.write(f"{c}\t{t}\t{s}\t18\t100\t{src}\tx\n")


def run_build(rows=None, universe=None, swaps=bs.SWAPS_PER_CHAIN):
    with tempfile.TemporaryDirectory() as d:
        write_inputs(d, rows)
        spec, ad, wr, nc = bs.build(d, ONCHAIN, d, universe, swaps)
        files = {n: open(os.path.join(d, "prereg", n)).read() for n in os.listdir(os.path.join(d, "prereg"))}
        on_disk = json.load(open(os.path.join(d, "spec.json")))
    return spec, ad, wr, nc, files, on_disk


class Build(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.spec, cls.ad, cls.wr, cls.nc, cls.files, cls.disk = run_build()
        cls.wrap = {(w[0], w[6]): w for w in cls.wr}  # (chain, pool) -> wrapper row

    def strata(self, chain, kind=None):
        return [s for s in self.spec["chains"][chain]["strata"] if kind is None or s["kind"] == kind]

    def by_id(self, chain, sid):
        return next(s for s in self.strata(chain) if s["id"] == sid)

    # Mutant: the liq_method translation dropped (an inventory row with the old wording reaches prereg).
    def test_prereg_and_spec_are_ascii_english(self):
        import json as _j
        texts = dict(self.files, **{"spec.json": _j.dumps(self.spec, ensure_ascii=False)})
        for name, text in texts.items():
            self.assertTrue(text.isascii(), name)
        self.assertIn("liq_virtual_at_price, not TVL", self.files["gate_wrappers.tsv"])
        self.assertIn("not main", self.spec["chains"]["bsc"]["label"])

    # Mutant: venueKey without the slot (key = family<<16, refused by Gate.sol:214 as slot 0).
    def test_venue_key_is_family_shifted_or_liquidity_rank(self):
        self.assertEqual(self.wrap[("base", C1)][2], (1 << 16) | 1)
        self.assertEqual(self.wrap[("base", C2)][2], (1 << 16) | 2)
        self.assertEqual(self.wrap[("base", B2)][2], (2 << 16) | 1)
        self.assertEqual(self.wrap[("base", B3)][2], (3 << 16) | 1)
        self.assertEqual(self.wrap[("avalanche", L1)][2], (1 << 16) | 1)
        self.assertEqual(self.wrap[("avalanche", L2)][2], (1 << 16) | 2)
        self.assertEqual(self.wrap[("avalanche", L3)][2], (2 << 16) | 1)
        self.assertEqual(self.wrap[("avalanche", AL1)][2], (4 << 16) | 1)
        self.assertEqual(self.wrap[("bsc", IC1)][2], (6 << 16) | 1)
        self.assertEqual(self.wrap[("bsc", IB1)][2], (7 << 16) | 1)
        self.assertTrue(all(w[2] & 0xFFFF for w in self.wr))

    # Mutant: gate rows ranked by ascending liquidity (the shallower curve pool gets slot 1).
    def test_slot_follows_measured_liquidity_not_file_order(self):
        self.assertEqual(self.by_id("base", "gate-1-1")["gate_pool"], C1)
        self.assertEqual(self.by_id("base", "gate-1-2")["gate_pool"], C2)

    def test_only_gate_top3_rows_become_wrappers(self):
        self.assertNotIn(("base", CX), self.wrap)
        self.assertEqual(sorted(p for c, p in self.wrap if c == "base"), sorted([C1, C2, B2, B3]))

    # Mutants: curve/balancer_v3 hint zero; balancer_v2 hint = pool word instead of the on-chain poolId.
    def test_hint_curve_and_balancer(self):
        self.assertEqual(self.wrap[("base", C1)][5], bs.word(C1))
        self.assertEqual(self.wrap[("base", B3)][5], bs.word(B3))
        self.assertEqual(self.wrap[("base", B2)][5], B2ID.lower())

    # Mutant: LB hint from another column than tick_spacing (= binStep).
    def test_hint_lb_is_bin_step(self):
        self.assertEqual(self.wrap[("avalanche", L1)][5], "0x" + format(25, "064x"))
        self.assertEqual(self.wrap[("avalanche", L2)][5], "0x" + format(10, "064x"))

    # Mutant: an Algebra pool that is no customPoolByPair of the deploy-script deployers gets a hint.
    def test_hint_algebra_is_deployer_or_no_hint(self):
        self.assertEqual(self.wrap[("avalanche", AL1)][5], bs.word(DEP))
        self.assertNotIn(("avalanche", AL2), self.wrap)
        self.assertTrue(any(c == "avalanche" and s == "algebra_integral" and r.startswith("no_hint") and AL2 in r
                            for c, s, r in self.nc))

    # Mutant: Infinity hint = the 20-byte Hub key instead of the 32-byte PoolId.
    def test_hint_infinity_is_pool_id(self):
        self.assertEqual(self.wrap[("bsc", IC1)][5], IC1)
        self.assertEqual(self.wrap[("bsc", IB1)][5], IB1)

    # Mutant: the not_covered row for a chain without gate rows dropped.
    def test_chain_without_gates_is_not_covered_without_a_number(self):
        rows = [r for r in self.nc if r[0] == "optimism"]
        self.assertEqual([r[1] for r in rows], ["gates"])
        self.assertTrue(rows[0][2].startswith("not covered"))
        self.assertFalse(any(ch.isdigit() for ch in rows[0][2]))
        self.assertFalse(any(w[0] == "optimism" for w in self.wr))
        self.assertTrue(self.files["not_covered.tsv"].startswith("chain\tscope\treason\n"))
        self.assertIn("\noptimism\tgates\tnot covered", self.files["not_covered.tsv"])

    # Mutant: family without an adapter number passes the guard (falls to the ctor reason instead).
    def test_family_without_adapter_number_is_not_covered(self):
        self.assertTrue(any(c == "arbitrum" and r.startswith("not covered: no adapter number") for c, s, r in self.nc))
        self.assertFalse(any(w[0] == "arbitrum" for w in self.wr))

    def test_chain_without_wrap_token_is_not_covered(self):
        for c in ("robinhood", "ethereum"):
            self.assertNotIn(c, self.spec["chains"])
            self.assertIn((c, "*"), [(r[0], r[1]) for r in self.nc])

    # Mutant: forge create rows for every adapter number, used or not.
    def test_adapters_only_for_families_used(self):
        self.assertEqual([(r[0], r[1]) for r in self.ad], [("base", 1), ("base", 2), ("base", 3), ("bsc", 6), ("bsc", 7)])

    # Mutants: seed_pools[:4]; v4 keyed by the first 20 bytes of the PoolId; a gate family made seedable.
    def test_seed_pools_three_deepest_seedable_v4_by_last_20_bytes(self):
        for st in self.strata("base", "gates") + [self.by_id("base", "major-1")]:
            self.assertEqual([p["pool"] for p in st["seed_pools"]], [V3A, "0x" + V4ID[-40:], V3B])
            self.assertEqual([p["kind"] for p in st["seed_pools"]], [1, 4, 1])
        for c in self.spec["chains"]:
            for st in self.strata(c):
                self.assertLessEqual(len(st["seed_pools"]), 3)

    def test_seed_kind_excludes_gate_families(self):
        self.assertFalse(set(bs.SEED_KIND) & bs.GATE_FAMS)

    # Mutant: mid_pool = shallowest instead of deepest v2/v3/algebra.
    def test_mid_pool_is_deepest_direct(self):
        self.assertEqual(self.by_id("base", "major-1")["mid_pool"], {"pool": V3A, "family": "v3", "token0": W})

    # Mutants: FRACTIONS reversed; zero amounts kept.
    def test_amounts_increasing_and_positive(self):
        for c in self.spec["chains"]:
            for st in self.strata(c):
                for side in ("A", "B"):
                    v = st["amounts"][side]
                    self.assertTrue(v, st["id"])
                    self.assertTrue(all(x > 0 for x in v), (st["id"], v))
                    self.assertEqual(v, sorted(set(v)), (st["id"], v))
        self.assertEqual(self.by_id("base", "major-1")["amounts"]["A"], [10 ** 11, 10 ** 13, 10 ** 15, 10 ** 16, 10 ** 17])
        self.assertEqual(self.by_id("base", "shallow-1")["amounts"]["A"], [1, 15])
        self.assertEqual(self.by_id("base", "gate-3-1")["amounts"]["A"], [5 * 10 ** 10, 5 * 10 ** 12, 5 * 10 ** 14, 5 * 10 ** 15, 5 * 10 ** 16])

    # Mutant: remainder not spread (each stratum gets 100 // len).
    def test_swaps_per_chain_sum_to_100(self):
        for c in self.spec["chains"]:
            ns = [st["n"] for st in self.strata(c)]
            self.assertEqual(sum(ns), 100, c)
            self.assertLessEqual(max(ns) - min(ns), 1)
        self.assertEqual(len(self.strata("base")) % 100 != 0 and 100 % len(self.strata("base")) != 0, True)

    # Mutant: pair dedupe dropped (W/U is both gate_top3+major and major via V3A).
    def test_pair_strata_have_distinct_pairs(self):
        prs = [tuple(sorted((s["tA"], s["tB"]))) for s in self.strata("base") if s["kind"] != "gates"]
        self.assertEqual(len(prs), len(set(prs)))
        self.assertEqual([s["tB"] for s in self.strata("base", "major")][:1] + [len(self.strata("base", "major"))], [U, 5])

    # Mutant: family_rep distinct-family check dropped.
    def test_family_rep_one_per_family(self):
        fams = [s["seed_pools"][0]["kind"] for s in self.strata("base", "family_rep")]
        self.assertEqual(len(self.strata("base", "family_rep")), 2)
        self.assertEqual(len(fams), len(set(fams)))

    # Mutants: shallow ranked descending; absent liq_usd read as a small number.
    def test_shallow_ascending_and_absent_liq_never_chosen(self):
        got = [s["tA"] for s in self.strata("base", "shallow")]
        t = lambda n: a(0x1100 + n)
        self.assertEqual(got, [t(23), t(27), t(21)])
        all_t = {s["tA"] for c in self.spec["chains"] for s in self.strata(c)}
        self.assertNotIn(t(25), all_t)

    def test_spec_on_disk_matches_and_carries_the_labels(self):
        self.assertEqual(self.disk, json.loads(json.dumps(self.spec)))
        self.assertEqual(self.spec["chains"]["base"]["label"], "fix123@2e4fdaa (selar), not main")
        self.assertEqual(self.spec["chains"]["base"]["max_hops"], 2)
        self.assertEqual(self.spec["chains"]["bsc"]["max_hops"], 3)
        self.assertEqual(self.spec["chains"]["base"]["native_wrap"], W)
        self.assertEqual(self.spec["ages"], {"M0": 0, "M1h": 3600, "M6h": 21600, "M24h": 86400, "M72h": 259200})
        self.assertEqual(self.spec["mf_ages"], ["M24h", "M72h"])


class CtorGuard(unittest.TestCase):
    # Mutant: the «no ctor source in the repo» guard removed (a wrapper whose adapter is never deployed).
    def test_family_without_ctor_source_is_not_covered(self):
        ad = {k: v for k, v in bs.ADAPTERS.items() if k != ("base", 2)}
        with mock.patch.object(bs, "ADAPTERS", ad):
            _, ads, wr, nc, _, _ = run_build()
        self.assertFalse(any(w[0] == "base" and w[1] == 2 for w in wr))
        self.assertIn(("base", "balancer_v2", "not covered: no ctor source in the repo"), nc)
        self.assertNotIn(2, [r[1] for r in ads if r[0] == "base"])


class SeedGuards(unittest.TestCase):
    """Two independent guards keep gate pools out of seed_pools (kind 9 enters only by the wrapper):
    SEED_KIND has no gate family, and build() filters GATE_FAMS. Each is tested with the other off."""

    # Mutant: a gate family made seedable in SEED_KIND.
    def test_seed_pools_unit_skips_gate_families(self):
        rows = [row("base", "curve_ng", C1, W, U, 5000, ""), row("base", "v3", V3A, W, U, 1000, "")]
        self.assertEqual([p["pool"] for p in bs.seed_pools(rows)], [V3A])

    # Mutants: the GATE_FAMS filter dropped in the gates stratum / in the pair strata.
    def test_build_filters_gate_families_even_if_seedable(self):
        with mock.patch.dict(bs.SEED_KIND, {"curve_ng": 9}):
            spec = run_build()[0]
        st = spec["chains"]["base"]["strata"]
        gate = next(x for x in st if x["id"] == "gate-1-1")
        major = next(x for x in st if x["id"] == "major-1")
        for x in (gate, major):
            self.assertNotIn(C1, [p["pool"] for p in x["seed_pools"]], x["id"])

    # Mutant: the GATE_FAMS filter dropped in the site strata (C1 shares USDC/WETH with V3A).
    def test_site_strata_filter_gate_families_even_if_seedable(self):
        with mock.patch.dict(bs.SEED_KIND, {"curve_ng": 9}):
            spec = run_build(SITE_ROWS, UNIVERSE, swaps=7)[0]
        site = next(x for x in spec["chains"]["base"]["strata"] if x["id"] == "site-USDC-WETH")
        self.assertEqual([p["pool"] for p in site["seed_pools"]], [V3A])


class Wiring(unittest.TestCase):
    def test_rebuild_keeps_the_addbridge_rows_of_wiring_tsv(self):
        # mutant: the kept non-addFactory rows of the existing wiring.tsv dropped
        derived = run_build()[4]["wiring.tsv"]
        br = "base\taddBridge(address)\t%s\n" % a(0xB1)
        with tempfile.TemporaryDirectory() as d:
            write_inputs(d)
            os.makedirs(os.path.join(d, "prereg"))
            p = os.path.join(d, "prereg", "wiring.tsv")
            with open(p, "w") as f:
                f.write("base\t%s\t%s\n" % (bs.ADD_FACTORY_SIG, a(0xDEAD)) + br)
            bs.build(d, ONCHAIN, d, None, bs.SWAPS_PER_CHAIN)
            t = open(p).read()
        self.assertEqual(t, derived + br)  # stale addFactory rows are re-derived, addBridge rows kept


class AddFactory(unittest.TestCase):
    # Real calldata: tx 0x5d932d0efa8e4d46255c3cb864ff002a7ddadcd518dd65b68dc115be26104e9e (ethereum,
    # block 25487895, registry 0xc4fa9a5720fe3294d3aa9fc427e2a760591e57ae), read via dRPC 13/11.
    TX = ("0xfa1b58b00000000000000000000000001f98431c8ad98523631ae4a59f267346ea31f98400000000000000000000000000"
          "0000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000"
          "05e34f199b19b2b4f47f68442619d555527d244f78a3297ea89325f843f87b8b540000000000000000000000000000000000"
          "0000000000000000000000000000c00000000000000000000000000000000000000000000000000000000000000160000000"
          "0000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000"
          "000000000000000000006400000000000000000000000000000000000000000000000000000000000001f400000000000000"
          "00000000000000000000000000000000000000000000000bb800000000000000000000000000000000000000000000000000"
          "0000000000271000000000000000000000000000000000000000000000000000000000000000040000000000000000000000"
          "0000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000"
          "00000a000000000000000000000000000000000000000000000000000000000000003c000000000000000000000000000000"
          "00000000000000000000000000000000c8")

    # Mutants: kind/mode swapped; init hash from the wrong word; array offset in words read as bytes/64.
    def test_real_uniswap_v3_registration(self):
        self.assertEqual(bs.decode_add_factory(self.TX),
                         "0x1f98431c8ad98523631ae4a59f267346ea31f984 1 5 "
                         "0xe34f199b19b2b4f47f68442619d555527d244f78a3297ea89325f843f87b8b54 [100,500,3000,10000] [1,10,60,200]")

    # Mutant: int24 read unsigned (a negative spacing becomes 2**256-1).
    def test_negative_int24_is_signed(self):
        w = lambda x: format(x % (1 << 256), "064x")
        data = "0x" + bs.ADD_FACTORY_SEL + w(0xAB) + w(0) + w(0) + "00" * 32 + w(6 * 32) + w(7 * 32) + w(0) + w(1) + w(-1)
        self.assertEqual(bs.decode_add_factory(data), "0x" + "0" * 38 + "ab 0 0 0x" + "0" * 64 + " [] [-1]")

    def test_other_selector_refused(self):
        with self.assertRaises(AssertionError):
            bs.decode_add_factory("0xdeadbeef" + "00" * 64)


class Parity(unittest.TestCase):
    # Mutant: a family dropped from build_spec.GATE_FAMS (its pools would be seeded / never gated).
    def test_gate_fams_equal_inventory(self):
        self.assertEqual(bs.GATE_FAMS, inventory.GATE_FAMS)


# site universe (build --universe): base listed, bsc not
TA, TB, TU, TD = a(0x1103), a(0x1104), a(0x1105), a(0x1106)
SITE_ROWS = [
    row("base", "curve_ng", C1, W, U, 5000, "gate_top3"),            # gate stratum, kept as it is
    row("base", "v3", V3A, W, U, 4000, "major"),                       # USDC/WETH: site_weth (and not site_stable again)
    row("base", "v2", V2P, TA, W, 300, "midtail", bal0=5 * 10 ** 18),  # TKA/WETH: site_weth
    row("base", "v3", V3B, TA, U, 200, "midtail"),                     # TKA/USDC: site_stable
    row("base", "v3", a(0xA4), TU, TD, 150, "midtail"),                # USDT/DAI: site_major
    row("bsc", "v3", a(0x31), BN, U3, 1000, "major"),                  # outside the universe: classes
]
UNIVERSE = {"stable": {"base": "USDC"}, "chains": {"base": {"chain_id": 8453, "tokens": [
    {"symbol": "WETH", "address": W.upper().replace("0X", "0x"), "decimals": 18, "featured": True},
    {"symbol": "USDC", "address": U, "decimals": 6, "featured": True},
    {"symbol": "TKA", "address": TA, "decimals": 18, "featured": False},
    {"symbol": "TKB", "address": TB, "decimals": 18, "featured": False},  # no pool in the inventory
    {"symbol": "USDT", "address": TU, "decimals": 6, "featured": False},
    {"symbol": "DAI", "address": TD, "decimals": 18, "featured": False}]}}}


class SiteUniverse(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.spec, cls.ad, cls.wr, cls.nc, cls.files, cls.on_disk = run_build(SITE_ROWS, UNIVERSE, swaps=7)
        cls.base = cls.spec["chains"]["base"]["strata"]

    # Mutant: the site_stable loop dropped (TKA/USDC missing); or SITE_MAJORS ignored (USDT/DAI missing).
    def test_site_pairs_replace_the_classes_and_keep_the_gates(self):
        kinds = {st["id"]: st["kind"] for st in self.base}
        self.assertEqual(kinds, {"gate-1-1": "gates", "site-USDC-WETH": "site_weth", "site-TKA-WETH": "site_weth",
                                 "site-TKA-USDC": "site_stable", "site-USDT-DAI": "site_major"})
        self.assertEqual(len(self.wr), 1)

    # Mutant: dedupe by address pair removed (USDC/WETH appears again as site-WETH-USDC under site_stable).
    def test_pairs_are_deduped_by_address(self):
        pairs = [tuple(sorted((st["tA"], st["tB"]))) for st in self.base if st["kind"] != "gates"]
        self.assertEqual(len(pairs), len(set(pairs)))
        self.assertEqual(pairs.count(tuple(sorted((W, U)))), 1)

    # Mutant: the not_covered append for a site pair without a pool removed.
    def test_site_pair_without_a_pool_is_not_covered(self):
        reasons = [r for c, scope, r in self.nc if c == "base" and scope == "site"]
        self.assertIn("site pair without a pool in the inventory (absent, not zero): TKB/WETH", reasons)
        self.assertIn("site pair without a pool in the inventory (absent, not zero): TKB/USDC", reasons)
        self.assertIn("TKB/WETH", self.files["not_covered.tsv"])

    # Mutant: amounts not taken from the inventory balances of the pair's pool.
    def test_amounts_come_from_the_inventory_balance(self):
        st = next(s for s in self.base if s["id"] == "site-TKA-WETH")
        self.assertEqual(st["amounts"]["A"], bs.amounts(5 * 10 ** 18))
        self.assertEqual(st["amounts"]["B"], bs.amounts(10 ** 18))
        self.assertEqual(st["mid_pool"]["pool"], V2P)

    # Mutant: `chain in universe["chains"]` test dropped (bsc goes through the site path).
    def test_chain_outside_the_universe_keeps_the_classes(self):
        self.assertEqual([st["kind"] for st in self.spec["chains"]["bsc"]["strata"]], ["major"])

    # Mutant: the --swaps value ignored (SWAPS_PER_CHAIN used instead).
    def test_swaps_argument_sets_the_sample_size(self):
        self.assertEqual(sum(st["n"] for st in self.base), 7)
        self.assertEqual(self.spec["swaps_per_chain"], 7)
        self.assertEqual(self.on_disk["swaps_per_chain"], 7)


if __name__ == "__main__":
    unittest.main(verbosity=1)
