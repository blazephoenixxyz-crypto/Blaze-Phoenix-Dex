// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// poda-1027, item 3. The Solver's funnel kept the eight rows psi ranked best
// (MAX_CANDIDATES = 8), and a count is what dust buys: psi multiplies a swap count anyone
// can pump by 2^bucket (bounty #82, Ronksok Gaming; root in mohaseenbasha dex-12). The
// 10-14 fix seated only the deepest row, so eight pumped shallow pools still cut the
// SECOND honest venue before it was quoted. No count cuts the funnel now: every row of a
// pair is measured by the registry's depth producer and a row is dropped only when it
// holds under MIN_SPLIT_IMPROVEMENT_PPM (25 ppm) of the rest of its pair
// (Solver._dropDust). A dropped row is measured and never quoted; a row alone on its
// pair, or holding all of its pair's measured depth, is never dropped.
//
// Observable for "quoted": a Solidly row is quoted by asking the pool itself
// (getAmountOutWithTotalFee 0x0ea099c1, then getAmountOut 0xf140a35a; Core
// solidlyGetAmountOut), and the depth measure reads only its reserves and balances.

import {Test} from "forge-std/Test.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg, RoutePlan} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";
import {MockSolidlyPair} from "./mocks/MockSolidlyPair.sol";
import {MockOriginFactory, Origin} from "./mocks/MockOriginFactory.sol";

contract DustIsMeasuredAgainstThePairTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    BlazePhoenixRouter router;
    MockERC20 tA;
    MockERC20 tB;
    address atk = address(0xA77AC);
    uint256 constant ORDER = 1_000e18;
    /// Solver.MIN_SPLIT_IMPROVEMENT_PPM, the share below which a row is dust.
    uint256 constant GAMMA_PPM = 25;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        solver = new BlazePhoenixSolver(address(hub), address(0));
        router = new BlazePhoenixRouter(address(hub), address(solver), address(this), address(0xFEE1), address(0xFEE2));
        hub.setRoles(address(router), address(solver), address(this));
        tA = new MockERC20("A", "A");
        tB = new MockERC20("B", "B");
    }

    // ── fixtures ────────────────────────────────────────────────────────────────

    /// A V2 pair holding `a` of x and `b` of y, reserves equal to balances.
    function _v2(MockERC20 x, MockERC20 y, uint256 a, uint256 b) internal returns (MockV2Pair p) {
        p = new MockV2Pair(address(x), address(y));
        x.mint(address(p), a);
        y.mint(address(p), b);
        p.setReserves(uint112(MockERC20(p.token0()).balanceOf(address(p))),
                      uint112(MockERC20(p.token1()).balanceOf(address(p))));
    }

    function _seed(MockV2Pair p) internal {
        hub.seedPool(address(p), BPC.KIND_V2, 30, address(0), p.token0(), p.token1());
    }

    /// A curated V2 venue between tA and tB.
    function _honest(uint256 a, uint256 b) internal returns (MockV2Pair h) {
        h = _v2(tA, tB, a, b);
        _seed(h);
    }

    /// A curated volatile Solidly pair holding `a` of tA and `b` of tB.
    function _solidly(uint256 a, uint256 b) internal returns (MockSolidlyPair s) {
        s = new MockSolidlyPair(address(tA), address(tB), false);
        tA.mint(address(s), a);
        tB.mint(address(s), b);
        s.setReserves(uint112(MockERC20(s.token0()).balanceOf(address(s))),
                      uint112(MockERC20(s.token1()).balanceOf(address(s))));
        hub.seedPool(address(s), BPC.KIND_SOLIDLY, 30, address(0), s.token0(), s.token1());
    }

    /// An attacker pool a wired factory vouches for (rizki-3107), one fee tier per pool.
    MockOriginFactory internal origin;
    uint24 internal nextTier;
    function _vouched(uint256 a, uint256 b) internal returns (MockV2Pair p) {
        p = _v2(tA, tB, a, b);
        if (address(origin) == address(0)) origin = Origin.tiers(hub, BPC.KIND_V2, 16);
        origin.list(address(p), address(tA), address(tB), ++nextTier, false);
    }

    /// One dust swap tA -> tB through the Router: registers the pool and ticks its count.
    function _dust(MockV2Pair p) internal {
        uint256 dust = 1e15;
        (uint112 r0, uint112 r1, ) = p.getReserves();
        bool aIs0 = p.token0() == address(tA);
        uint256 exp = BPC.outV2(dust, aIs0 ? r0 : r1, aIs0 ? r1 : r0, 30) / 2;
        tA.mint(atk, dust);
        vm.startPrank(atk);
        tA.approve(address(router), dust);
        Leg[] memory legs = new Leg[](1);
        legs[0] = Leg({pool: address(p), hooks: address(0), kind: BPC.KIND_V2, fee: 30, tickSpacing: 0,
            zeroForOne: aIs0, stable: false, amountIn: dust, expectedOut: exp, auxId: bytes32(0)});
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({tokenIn: address(tA), tokenOut: address(tB), amountIn: dust, expectedOut: exp, legs: legs});
        Route memory r = Route({hops: hops, totalOut: exp, singleOut: exp, singleOutFloor: 1, expectedImpactBps: 0,
            confidenceWad: 0, estGas: 0, hasSurplus: true, isV4Bundle: false});
        router.swapExactIn(r, dust, 1, atk, block.timestamp + 1);
        vm.stopPrank();
    }

    function _routes(Route memory r, address pool) internal pure returns (bool) {
        for (uint256 x; x < r.hops.length; ++x)
            for (uint256 y; y < r.hops[x].legs.length; ++y)
                if (r.hops[x].legs[y].pool == pool) return true;
        return false;
    }

    /// The calls one plan of tA -> tB makes, recorded.
    function _planCalls(uint256 amt) internal returns (VmSafe.AccountAccess[] memory acc) {
        vm.startStateDiffRecording();
        solver.findBestRoutePlan(address(tA), address(tB), amt);
        acc = vm.stopAndReturnStateDiff();
    }

    /// How many times the plan asked `pool` for its own quote.
    function _asks(VmSafe.AccountAccess[] memory acc, address pool) internal pure returns (uint256 n) {
        for (uint256 i; i < acc.length; ++i) {
            if (acc[i].account != pool || acc[i].data.length < 4) continue;
            bytes4 sel = bytes4(acc[i].data);
            if (sel == bytes4(0x0ea099c1) || sel == bytes4(0xf140a35a)) ++n;
        }
    }

    /// How many calls the plan made to `pool` at all.
    function _touches(VmSafe.AccountAccess[] memory acc, address pool) internal pure returns (uint256 n) {
        for (uint256 i; i < acc.length; ++i) {
            if (acc[i].account == pool && acc[i].kind == VmSafe.AccountAccessKind.StaticCall) ++n;
        }
    }

    function _depthV2(address p) internal view returns (uint256) {
        return BPC.registryDepth18(p, BPC.KIND_V2, MockV2Pair(p).token0(), MockV2Pair(p).token1(), address(0), bytes32(0));
    }

    function _depthSolidly(MockSolidlyPair s) internal view returns (uint256) {
        return BPC.registryDepth18(address(s), BPC.KIND_SOLIDLY, s.token0(), s.token1(), address(0), bytes32(0));
    }

    // ── no count cuts the funnel ────────────────────────────────────────────────

    /// Bounty #82 one seat further: eight shallow pools (1/20 of the deepest each, real
    /// mass at the market price) pumped until each out-ranks the second honest venue on
    /// psi. With eight seats the deepest took the last one and the second honest venue,
    /// the best priced, was cut before it was quoted. Every row here holds far more than
    /// 25 ppm of its pair, so all ten are quoted and the best priced venue is routed. It is
    /// 0.5% better priced: since MED (2026-10-28) the band is the one of no arbitrage, which
    /// keeps a 0.3% venue up to about 0.9% above a 0.3% base (BlazePhoenixMath, THE BAND),
    /// so the 1% this test used until then put the venue out of the band, and the test read
    /// the band instead of the count.
    function test_ASecondHonestVenue_IsNotCutByCount() public {
        _honest(2_000_000e18, 2_000_000e18);
        MockV2Pair h2 = _honest(1_000_000e18, 1_005_000e18);
        MockV2Pair[8] memory a;
        for (uint256 i; i < 8; ++i) a[i] = _vouched(100_000e18, 100_000e18);
        for (uint256 i; i < 8; ++i) for (uint256 k; k < 6; ++k) _dust(a[i]);

        address[] memory pl = new address[](2);
        address[] memory t0 = new address[](2);
        address[] memory t1 = new address[](2);
        (pl[0], pl[1]) = (address(h2), address(a[0]));
        (t0[0], t0[1]) = (address(tA), address(tA));
        (t1[0], t1[1]) = (address(tB), address(tB));
        uint256[] memory psi = hub.psisOf(pl, t0, t1);
        assertGt(psi[1], psi[0], "setup: every pumped row out-ranks the second honest venue");

        RoutePlan memory p = solver.findBestRoutePlan(address(tA), address(tB), ORDER);
        assertTrue(_routes(p.best, address(h2)), "the best priced venue was cut by a count");
    }

    // ── dust is measured against its pair, never quoted ─────────────────────────

    /// One deep venue, one Solidly row well above 25 ppm of the pair and one under it:
    /// the second is asked for its quote, the third is only measured.
    function test_DustBesideADeepVenue_IsMeasuredNeverQuoted() public {
        _honest(1_000_000e18, 1_000_000e18);
        MockSolidlyPair kept = _solidly(100_000e18, 100_000e18);
        MockSolidlyPair dust = _solidly(10e18, 10e18);
        VmSafe.AccountAccess[] memory acc = _planCalls(ORDER);
        assertGt(_asks(acc, address(kept)), 0, "control: a row above 25 ppm of its pair is quoted");
        assertEq(_asks(acc, address(dust)), 0, "a row under 25 ppm of its pair was quoted");
        assertGt(_touches(acc, address(dust)), 0, "the dropped row is still measured");
    }

    /// The boundary is inclusive: a row whose depth times 1e6 equals 25 times the rest
    /// of its pair stays. Depths are read from the producer the funnel uses.
    function test_Boundary_At25PpmOfThePairIsKept() public {
        MockV2Pair h = _honest(1_000_000e18, 1_000_000e18);
        uint256 rest = _depthV2(address(h));
        uint256 side = rest * GAMMA_PPM / 1e6;
        MockSolidlyPair b = _solidly(side, side);
        assertEq(_depthSolidly(b) * 1e6, GAMMA_PPM * rest, "setup: exactly at the boundary");
        VmSafe.AccountAccess[] memory acc = _planCalls(ORDER);
        assertGt(_asks(acc, address(b)), 0, "a row at exactly 25 ppm of the rest of its pair was dropped");
    }

    /// One wei under the boundary, the row is dropped before any quote.
    function test_Boundary_OneWeiUnder25PpmIsDropped() public {
        MockV2Pair h = _honest(1_000_000e18, 1_000_000e18);
        uint256 rest = _depthV2(address(h));
        uint256 side = rest * GAMMA_PPM / 1e6 - 1;
        MockSolidlyPair b = _solidly(side, side);
        assertLt(_depthSolidly(b) * 1e6, GAMMA_PPM * rest, "setup: under the boundary");
        VmSafe.AccountAccess[] memory acc = _planCalls(ORDER);
        assertEq(_asks(acc, address(b)), 0, "a row under 25 ppm of the rest of its pair was quoted");
    }

    // ── a rare token's pool is never dust ───────────────────────────────────────

    /// A new pool of a rare token, alone on its pair, is never measured and never
    /// dropped, however small it is next to the deep pools of other pairs.
    function test_ARareTokensOnlyPool_IsNeverDropped() public {
        _honest(1_000_000e18, 1_000_000e18);
        MockERC20 r = new MockERC20("R", "R");
        MockV2Pair p = _v2(r, tB, 1e18, 1e18);
        _seed(p);
        RoutePlan memory plan = solver.findBestRoutePlan(address(r), address(tB), 1e15);
        assertTrue(_routes(plan.best, address(p)), "a rare token's only pool was dropped");
        assertGt(plan.best.totalOut, 0, "and it pays");
    }

    /// The measure is per pair: the rare token's tiny pool is the first hop of a route
    /// whose second hop is a million times deeper, and it stays.
    function test_ARareTokensTinyPool_IsMeasuredAgainstItsOwnPairOnly() public {
        MockV2Pair deep = _honest(1_000_000e18, 1_000_000e18);
        hub.addBridge(address(tA));
        MockERC20 r = new MockERC20("R", "R");
        MockV2Pair p = _v2(r, tA, 1e18, 1e18);
        _seed(p);
        RoutePlan memory plan = solver.findBestRoutePlan(address(r), address(tB), 1e15);
        assertTrue(_routes(plan.best, address(p)), "the rare token's pool was measured against another pair");
        assertTrue(_routes(plan.best, address(deep)), "control: the route crosses the deep hop");
        assertGt(plan.best.totalOut, 0, "and it pays");
    }

    /// Two rows on the rare token's pair, one tiny and one whose reserves are not held
    /// (it measures 0): the tiny one holds all the pair's measured depth and is routed.
    function test_ARareTokensTinyPool_HoldingAllOfItsPair_IsNeverDropped() public {
        MockERC20 r = new MockERC20("R", "R");
        MockV2Pair p = _v2(r, tB, 1e18, 1e18);
        _seed(p);
        MockV2Pair dead = new MockV2Pair(address(r), address(tB));
        dead.setReserves(uint112(1e24), uint112(1e24));
        _seed(dead);
        assertEq(_depthV2(address(dead)), 0, "setup: reserves it does not hold measure 0");
        assertGt(_depthV2(address(p)), 0, "setup: the tiny pool measures its mass");
        RoutePlan memory plan = solver.findBestRoutePlan(address(r), address(tB), 1e15);
        assertTrue(_routes(plan.best, address(p)), "a row holding all of its pair was dropped");
    }
}
