// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  A V4 POOL IS QUOTED BY WALKING ITS BOOK, THE WAY ITS SWAP WALKS IT.
//
//  The single-tick model gave two answers and both were wrong somewhere. The
//  ranking figure assumed the current liquidity went on forever, so a pool with
//  a large `L` and one tick of range out-ranked an honest pool, took the whole
//  order and filled 5% of it while the preview published twenty times the
//  delivery (ninth wave, mohaseenbasha, dex-19). The promise stopped at the
//  current range's edge, so a deep pool whose current range was narrow was
//  promised a tenth of what it delivered. `Core.v4WalkOut` reads the tick bitmap
//  and the ticks through extsload and applies the pool's own swap arithmetic
//  across initialized ticks: a range with nothing beyond it pays what it holds,
//  and liquidity beyond the current range is counted where it is.
//
//  The oracle is `MockV4TickManager`, a PoolManager for tests that stores the
//  book at the singleton's offsets and swaps it with a loop written from the
//  specification, with its own tick-to-price arithmetic - not the Core's table.
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixQuoter} from "../src/BlazePhoenixQuoter.sol";
import {BlazePhoenixCore as BPC, RoutePlan} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";
import {MockV4TickManager} from "./mocks/MockV4TickManager.sol";

contract V4TickWalkTest is Test {
    MockV4TickManager mgr;
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    BlazePhoenixRouter router;
    BlazePhoenixQuoter quoter;
    address t0;
    address t1;
    address user = address(0xBEEF);

    uint24 constant FEE = 3000;
    int24  constant TS  = 60;
    uint256 constant ORDER = 1e21;

    function setUp() public {
        mgr = new MockV4TickManager();
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(mgr));
        solver = new BlazePhoenixSolver(address(hub));
        router = new BlazePhoenixRouter(address(hub), address(solver), address(this), address(0xFEE1), address(0xFEE2));
        quoter = new BlazePhoenixQuoter(address(hub), address(solver));
        hub.setRoles(address(router), address(solver), address(quoter));
        MockERC20 a = new MockERC20("A", "A");
        MockERC20 b = new MockERC20("B", "B");
        (t0, t1) = address(a) < address(b) ? (address(a), address(b)) : (address(b), address(a));
        MockERC20(t1).mint(address(mgr), 1e30);
        MockERC20(t0).mint(address(mgr), 1e30);
        MockERC20(t0).mint(user, ORDER);
        vm.prank(user);
        MockERC20(t0).approve(address(router), type(uint256).max);
    }

    function _pid() internal view returns (bytes32) { return BPC.computeV4PoolId(t0, t1, FEE, TS, address(0)); }

    /// The V4 book: the price exactly at `tick`, then the positions.
    function _book(int24 tick, int24[] memory lo, int24[] memory hi, uint128[] memory liq) internal {
        mgr.initialize(_pid(), mgr.sqrtAt(tick), tick, FEE);
        for (uint256 i; i < lo.length; ++i) mgr.addPosition(_pid(), lo[i], hi[i], TS, liq[i]);
    }

    function _v2(uint256 r0, uint256 r1) internal {
        MockV2Pair p = new MockV2Pair(t0, t1);
        MockERC20(t0).mint(address(p), r0);
        MockERC20(t1).mint(address(p), r1);
        p.setReserves(uint112(r0), uint112(r1));
        hub.seedPool(address(p), BPC.KIND_V2, 30, address(0), t0, t1);
    }

    function _one(int24 lo, int24 hi, uint128 liq)
        internal pure returns (int24[] memory l, int24[] memory h, uint128[] memory q)
    {
        l = new int24[](1); h = new int24[](1); q = new uint128[](1);
        l[0] = lo; h[0] = hi; q[0] = liq;
    }

    // ── the table ─────────────────────────────────────────────────────────────

    function test_TickMath_TheCanonicalEndpoints() public pure {
        assertEq(BPC.sqrtPriceAtTick(0), uint160(BPC.Q96), "tick 0 is price 1");
        assertEq(BPC.sqrtPriceAtTick(-887272), uint160(4295128739), "MIN_TICK is MIN_SQRT_PRICE");
        assertEq(BPC.sqrtPriceAtTick(887272), uint160(1461446703485210103287273052203988822378723970342),
            "MAX_TICK is MAX_SQRT_PRICE");
    }

    /// Every bit of the table is exercised somewhere in the range; a wrong constant is a
    /// relative error of many orders of magnitude on every tick carrying its bit. The table
    /// itself is exact only to its own width: 1/sqrt(1.0001)^|tick| in Q128 keeps fewer
    /// significant bits as |tick| grows (about 1e-18 relative at the extremes, measured
    /// 2.2e-22 at tick 783,000) - the same value the PoolManager computes, so that is the
    /// tolerance, and nothing wider.
    function testFuzz_TickMath_AgreesWithAnIndependentFixedPoint(int24 t) public view {
        t = int24(bound(int256(t), -887271, 887271));
        uint256 ours = BPC.sqrtPriceAtTick(t);
        uint256 theirs = mgr.sqrtAt(t);
        uint256 diff = ours > theirs ? ours - theirs : theirs - ours;
        assertLe(diff, theirs / 1e17 + 2, "the table disagrees with sqrt(1.0001)^tick");
        assertGt(BPC.sqrtPriceAtTick(t + 1), ours, "the table is not increasing");
    }

    // ── the walk against the specification ───────────────────────────────────

    function test_AOneTickRangeWithNothingBeyondPaysWhatItHolds() public {
        (int24[] memory l, int24[] memory h, uint128[] memory q) = _one(-60, 0, 1e24);
        _book(-59, l, h, q);
        (, uint256 spec, , , ) = mgr.specSwap(_pid(), ORDER, FEE, TS, true);
        uint256 walk = BPC.v4WalkOut(address(mgr), _pid(), ORDER, FEE, TS, true);
        uint256 held = BPC.mulDiv(1e24, mgr.sqrtAt(-59) - mgr.sqrtAt(-60), BPC.Q96);
        assertApproxEqAbs(walk, spec, 4, "the walk is not the pool's swap");
        assertLe(walk, held + 1, "the walk paid more than the range holds");
        assertGt(walk, held * 99 / 100, "and it paid less than the range holds");
    }

    function test_LiquidityBeyondTheCurrentRangeIsCountedWhereItIs() public {
        int24[] memory l = new int24[](2); int24[] memory h = new int24[](2); uint128[] memory q = new uint128[](2);
        l[0] = -60;   h[0] = 0;    q[0] = 1e24;       // the narrow current range
        l[1] = -6000; h[1] = 6000; q[1] = 1e24;       // and the deep one it sits in
        _book(-59, l, h, q);
        (, uint256 spec, , , ) = mgr.specSwap(_pid(), ORDER, FEE, TS, true);
        uint256 walk = BPC.v4WalkOut(address(mgr), _pid(), ORDER, FEE, TS, true);
        assertApproxEqAbs(walk, spec, 8, "the walk is not the pool's swap across a crossing");
        assertGt(walk, ORDER * 9 / 10, "the liquidity beyond the narrow range was not counted");
    }

    function testFuzz_TheWalkIsTheSpecSwap(uint8 nPos, uint64 seed, uint96 amt, bool zfo) public {
        uint256 n = 1 + uint256(nPos) % 3;
        int24[] memory l = new int24[](n); int24[] memory h = new int24[](n); uint128[] memory q = new uint128[](n);
        for (uint256 i; i < n; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            int24 a = int24(int256(r % 60)) - 30;                        // compressed, within +-30
            int24 w = 1 + int24(int256((r >> 8) % 30));
            l[i] = a * TS;
            h[i] = (a + w) * TS;
            q[i] = uint128(1e18 + (r >> 16) % 1e24);
        }
        _book(-1, l, h, q);
        uint256 order = bound(uint256(amt), 1e12, 1e22);
        (, uint256 spec, , , ) = mgr.specSwap(_pid(), order, FEE, TS, zfo);
        uint256 walk = BPC.v4WalkOut(address(mgr), _pid(), order, FEE, TS, zfo);
        assertLe(walk, spec + 16, "the walk promised more than the pool pays");
        assertApproxEqAbs(walk, spec, 64, "the walk is not the pool's swap");
    }

    /// The walk against the specification across its dimensions: tick spacing, fee tier, a price
    /// on a tick or inside it (in a range or in a gap), one to four overlapping positions, an order
    /// from dust to more than the book holds, both directions.
    function testFuzz_TheWalkIsTheSpecSwap_AcrossDimensions(
        uint8 spacingSel, uint8 feeSel, int16 tickSeed, uint16 fracSeed, bool onTick,
        uint8 nPos, uint64 seed, uint96 amt, bool zfo
    ) public {
        int24 S = spacingSel % 4 == 0 ? int24(1) : spacingSel % 4 == 1 ? int24(10)
                 : spacingSel % 4 == 2 ? int24(60) : int24(200);
        uint24 F = feeSel % 4 == 0 ? uint24(100) : feeSel % 4 == 1 ? uint24(500)
                 : feeSel % 4 == 2 ? uint24(3000) : uint24(10000);
        int24 t = int24(int256(tickSeed) % (40 * int256(S)));
        // The state the PoolManager writes: TickMath(t) <= P < TickMath(t + 1). The spec prices
        // ticks on its own fixed point, a few wei from the table, so P is placed where both
        // tables agree it lies in tick t - on its lower edge, or strictly inside.
        uint256 lo = BPC.sqrtPriceAtTick(t) > mgr.sqrtAt(t) ? BPC.sqrtPriceAtTick(t) : mgr.sqrtAt(t);
        uint256 hi = BPC.sqrtPriceAtTick(t + 1) < mgr.sqrtAt(t + 1) ? BPC.sqrtPriceAtTick(t + 1) : mgr.sqrtAt(t + 1);
        uint160 P = uint160(onTick ? lo : lo + (hi - lo) * (1 + uint256(fracSeed) % 998) / 1000);
        mgr.initialize(_pid(), P, t, F);
        uint256 n = 1 + uint256(nPos) % 4;
        for (uint256 i; i < n; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            int24 a = int24(int256(r % 81)) - 40;
            int24 w = 1 + int24(int256((r >> 8) % 20));
            mgr.addPosition(_pid(), a * S, (a + w) * S, S, uint128(1e15 + (r >> 16) % 1e24));
        }
        uint256 order = bound(uint256(amt), 1e9, 1e24);
        (, uint256 spec, , , ) = mgr.specSwap(_pid(), order, F, S, zfo);
        uint256 walk = BPC.v4WalkOut(address(mgr), _pid(), order, F, S, zfo);
        assertLe(walk, spec + 64, "the walk promised more than the pool pays");
        assertApproxEqAbs(walk, spec, 64, "the walk is not the pool's swap");
    }

    // ── the route, end to end ─────────────────────────────────────────────────

    function _swapBest() internal returns (uint256 got, uint256 spent) {
        uint256 b0 = MockERC20(t0).balanceOf(user);
        uint256 b1 = MockERC20(t1).balanceOf(user);
        vm.prank(user);
        router.swapBestExactIn(t0, t1, ORDER, 1, user, block.timestamp + 1);
        got = MockERC20(t1).balanceOf(user) - b1;
        spent = b0 - MockERC20(t0).balanceOf(user);
    }

    /// dex-19. One tick of range, a large `L` and nothing beyond it, beside an honest pool.
    /// RED before the walk: the thin pool took the whole order, filled about 5% of it, and
    /// the preview published twenty times the delivery.
    function test_AOneTickRangeCannotTakeTheRouteFromAnHonestPool() public {
        (int24[] memory l, int24[] memory h, uint128[] memory q) = _one(-60, 0, 1e24);
        _book(-59, l, h, q);
        hub.addV4(t0, t1, FEE, TS, address(0));
        _v2(1e24, 99e22);                                             // honest, at 0.99
        uint256 honest = BPC.outV2(ORDER - BPC.mulDivUp(ORDER, BPC.PROTOCOL_FEE_BPS, BPC.BPS), 1e24, 99e22, 30);
        (BlazePhoenixQuoter.Preview memory pv, , ) = quoter.previewPlan(t0, t1, ORDER);
        (uint256 got, uint256 spent) = _swapBest();
        emit log_named_uint("delivered      ", got);
        emit log_named_uint("honest alone   ", honest);
        emit log_named_uint("preview netOut ", pv.netOut);
        assertEq(spent, ORDER, "the order was only partly filled");
        assertGe(got, honest * 99 / 100, "a one-tick range took the route from the honest pool");
        assertLe(pv.netOut, got + got / 1000, "the preview promised more than the route delivered");
    }

    /// The other side of the same model: a deep pool whose current range is narrow. RED before
    /// the walk on the promise: it stopped at the narrow range's edge and attested a tenth of
    /// what the pool delivers. The walk sees the liquidity beyond, ranks the pool for it, and
    /// promises it.
    function test_ADeepPoolWithANarrowCurrentRangeIsPromisedWhatItPays() public {
        int24[] memory l = new int24[](2); int24[] memory h = new int24[](2); uint128[] memory q = new uint128[](2);
        l[0] = -60;   h[0] = 0;    q[0] = 1e24;
        l[1] = -6000; h[1] = 6000; q[1] = 1e24;
        _book(-59, l, h, q);
        hub.addV4(t0, t1, FEE, TS, address(0));
        _v2(1e24, 985e21);                                            // honest, but worse: 0.985
        RoutePlan memory plan = solver.findBestRoutePlan(t0, t1, ORDER);
        bool v4;
        for (uint256 i; i < plan.best.hops[0].legs.length; ++i) {
            if (plan.best.hops[0].legs[i].kind != BPC.KIND_V4) continue;
            v4 = true;
            // What the pool pays for this leg's own input, from the specification's swap.
            (, uint256 pays, , , ) = mgr.specSwap(_pid(), plan.best.hops[0].legs[i].amountIn, FEE, TS, true);
            emit log_named_uint("V4 promised    ", plan.best.hops[0].legs[i].expectedOut);
            emit log_named_uint("V4 pays        ", pays);
            assertGt(plan.best.hops[0].legs[i].expectedOut, pays * 8 / 10,
                "the promise did not see the liquidity beyond the current range");
        }
        assertTrue(v4, "the deep V4 pool lost the route to a worse one");
        (uint256 got, uint256 spent) = _swapBest();
        emit log_named_uint("delivered      ", got);
        assertEq(spent, ORDER, "the order was only partly filled");
        assertGt(got, BPC.outV2(ORDER, 1e24, 985e21, 30), "the route delivered less than the worse pool alone");
    }
}
