// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// Bounty #82 (Ronksok Gaming, 2026-10-12; root in mohaseenbasha dex-12, 2026-09-17).
// psi is the swap count times 2^bucket, and the bucket buys one doubling per DECADE of
// mass while each unit of count costs one dust swap. Eight pools holding 1/100 of the
// honest venue's mass, pumped with 3-10 dust swaps each, out-ranked it, took all eight
// funnel seats, and the honest venue was cut before it was quoted: a victim who signed
// 99.5 % of the Solver's quote received about half of the honest output, every floor
// passing. The funnel now always seats the row holding the most mass measured now:
// Solver._capByLiveDepth measures every row and names the deepest, Solver._seatDeepest
// gives it the last seat. Red on 982c1de: the honest pool is absent from the route in
// every test below except the two controls, which are green on both trees.

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg, RoutePlan} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "../test/mocks/MockERC20.sol";
import {MockV2Pair} from "../test/mocks/MockV2Pair.sol";
import {MockV2Factory} from "../test/mocks/MockV2Factory.sol";

contract Bounty1013TopKResistsDustPsiTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    BlazePhoenixRouter router;
    MockERC20 tA;
    MockERC20 tB;
    address user = address(0xBEEF);
    address atk  = address(0xA77AC);
    uint256 constant ORDER = 1_000e18;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        solver = new BlazePhoenixSolver(address(hub));
        router = new BlazePhoenixRouter(address(hub), address(solver), address(this), address(0xFEE1), address(0xFEE2));
        hub.setRoles(address(router), address(solver), address(this));
        tA = new MockERC20("A", "A");
        tB = new MockERC20("B", "B");
    }

    // ── fixtures ────────────────────────────────────────────────────────────────

    /// A V2 pair holding `a` of tA and `b` of tB, reserves equal to balances.
    function _pool(uint256 a, uint256 b) internal returns (MockV2Pair p) {
        p = new MockV2Pair(address(tA), address(tB));
        tA.mint(address(p), a);
        tB.mint(address(p), b);
        p.setReserves(uint112(MockERC20(p.token0()).balanceOf(address(p))),
                      uint112(MockERC20(p.token1()).balanceOf(address(p))));
    }

    /// The honest venue, curated (seedPool) or only discoverable through a factory.
    function _honest(uint256 a, uint256 b, bool seeded) internal returns (MockV2Pair h) {
        h = _pool(a, b);
        if (seeded) {
            hub.seedPool(address(h), BPC.KIND_V2, 30, address(0), address(tA), address(tB));
        } else {
            MockV2Factory f = new MockV2Factory();
            f.setPair(address(tA), address(tB), address(h));
            hub.addFactory(address(f), BPC.KIND_V2, 0, bytes32(0), new uint24[](0), new int24[](0));
        }
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

    /// The victim signs 99.5 % of the Solver's quote and executes it.
    function _victim(Route memory r) internal returns (uint256 got) {
        tA.mint(user, ORDER);
        vm.startPrank(user);
        tA.approve(address(router), ORDER);
        uint256 b0 = tB.balanceOf(user);
        router.swapExactIn(r, ORDER, r.totalOut * 995 / 1000, user, block.timestamp + 1);
        vm.stopPrank();
        got = tB.balanceOf(user) - b0;
    }

    /// Eight attacker pools at a 2:1 price against the taker, each pumped `pumps` times;
    /// the honest 1M/1M venue must stay in the route and the victim must be paid what the
    /// honest venue paid before the pump (the pre-pump plan, same code, honest state).
    function _attack(bool seeded, uint256 pumps, uint256 atkA, uint256 atkB) internal {
        MockV2Pair h = _honest(1_000_000e18, 1_000_000e18, seeded);
        MockV2Pair[8] memory a;
        for (uint256 i; i < 8; ++i) a[i] = _pool(atkA, atkB);
        RoutePlan memory p0 = solver.findBestRoutePlan(address(tA), address(tB), ORDER);
        assertTrue(_routes(p0.best, address(h)), "setup: the honest venue routes before the pump");
        for (uint256 i; i < 8; ++i) for (uint256 k; k < pumps; ++k) _dust(a[i]);
        // The pump is real: every attacker row out-ranks the honest one on psi.
        address[] memory pl = new address[](2);
        address[] memory t0 = new address[](2);
        address[] memory t1 = new address[](2);
        (pl[0], pl[1]) = (address(h), address(a[0]));
        (t0[0], t0[1]) = (address(tA), address(tA));
        (t1[0], t1[1]) = (address(tB), address(tB));
        uint256[] memory psi = hub.psisOf(pl, t0, t1);
        emit log_named_uint("psi honest  ", psi[0]);
        emit log_named_uint("psi attacker", psi[1]);
        assertGt(psi[1], psi[0], "setup: the pump must out-rank the honest venue");

        RoutePlan memory p1 = solver.findBestRoutePlan(address(tA), address(tB), ORDER);
        assertTrue(_routes(p1.best, address(h)), "the honest venue was cut from the funnel by dust psi");
        uint256 got = _victim(p1.best);
        emit log_named_uint("pre-pump quote ", p0.best.totalOut);
        emit log_named_uint("victim received", got);
        assertGe(got, p0.best.totalOut * 995 / 1000, "the victim was paid below the honest venue");
    }

    // ── the report, on V2 ───────────────────────────────────────────────────────

    function test_SeededHonestVenueSurvivesTenDustSwapsPerPool() public { _attack(true, 10, 20_000e18, 10_000e18); }

    function test_SeededHonestVenueSurvivesFortyDustSwapsPerPool() public { _attack(true, 40, 20_000e18, 10_000e18); }

    /// psi 0 floored to 1: a discovered venue is the row the score cannot see at all.
    function test_DiscoveredHonestVenueSurvivesThreeDustSwapsPerPool() public { _attack(false, 3, 20_000e18, 10_000e18); }

    /// Pools ONE bucket shallower: short side 1.01e23 (bucket 8) against 1e24 (bucket 9).
    /// Capping the count at 4 inside psi would still lose here: 4 * 2^8 = 1024 > 1 * 2^9 = 512.
    /// The depth seat does not. The eight pools together stay below the honest venue's mass
    /// (8.08e23 < 1e24): above it they would carry the depth-weighted median that anchors the
    /// band, which is capital voting, a different question from the funnel's seats.
    function test_OneDecadeShallowerStillCannotCutTheDeepest() public { _attack(true, 4, 202_000e18, 101_000e18); }

    // ── controls ────────────────────────────────────────────────────────────────

    /// CONTROL 1 — honest funnel, deepest already seated: the seat changes nothing. Nine
    /// honest 1:1 venues; the ninth is the shallowest and ranks last, so adding it must leave
    /// the plan byte-identical to the plan without it.
    function test_control_FunnelUnchangedWhenTheDeepestIsSeated() public {
        _honest(1_000_000e18, 1_000_000e18, true);
        for (uint256 i; i < 7; ++i) _honest(100_000e18 + i * 1e18, 100_000e18 + i * 1e18, true);
        RoutePlan memory before = solver.findBestRoutePlan(address(tA), address(tB), ORDER);
        _honest(10_000e18, 10_000e18, true);
        RoutePlan memory afterCut = solver.findBestRoutePlan(address(tA), address(tB), ORDER);
        assertEq(abi.encode(afterCut.best), abi.encode(before.best), "a cut that kept the deepest moved the plan");
    }

    /// CONTROL 2 — the live-depth cap still guards every seat but the deepest. Eight pools
    /// registered at 5M a side and pumped, then drained to 5k: their cached bucket out-ranks
    /// both honest venues, their live mass does not. The second honest venue (better priced)
    /// is not the deepest, so only the cap keeps it in the funnel.
    function test_control_LiveCapStillSeatsTheSecondHonestVenue() public {
        _honest(2_000_000e18, 2_000_000e18, true);
        MockV2Pair h2 = _honest(1_000_000e18, 1_020_000e18, true);
        for (uint256 i; i < 8; ++i) {
            MockV2Pair d = _pool(5_000_000e18, 5_000_000e18);
            _dust(d); _dust(d);
            (uint112 r0, uint112 r1, ) = d.getReserves();
            d.swap(uint256(r0) - 5_000e18, uint256(r1) - 5_000e18, atk, "");
        }
        RoutePlan memory p = solver.findBestRoutePlan(address(tA), address(tB), ORDER);
        assertTrue(_routes(p.best, address(h2)), "a drained row kept its cached seat over the second honest venue");
    }
}
