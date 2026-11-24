// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// A hookless V4 book whose deep walk stops short of the hop's input (`BPC.v4Stop`) has more book
// than its quote verified. The Solver may seat it as a price-limited first leg ahead of the exact
// plan built without it: the leg spends out of the hop's whole input down to the last tick whose
// rate still pays the exact plan's average rate (`BPC.v4LimitTick`), and the exact legs share
// what it leaves.
//
// Unit: `v4LimitTick` is the last tick, in the swap's direction, that pays the bar, and refuses a
// bar the stop rate no longer pays. End to end: the book rides once, first and limited, its limit
// pays the exact plan's average, the order spends its whole input and settles at least what
// either the book or the exact plan alone would; a book that verified only dust rides no limit.

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixQuoter} from "../src/BlazePhoenixQuoter.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, RoutePlan, Leg} from "../src/BlazePhoenixCore.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";
import {PathologicalERC20} from "./mocks/PathologicalERC20.sol";
import {MockV4WindowManager} from "./mocks/MockV4WindowManager.sol";

contract V4TailLimitedLegTest is Test {
    uint256 constant Q96 = 0x1000000000000000000000000;
    int24 constant MIN_TICK = -887_272;
    int24 constant MAX_TICK = 887_272;

    MockV4WindowManager mgr;
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    BlazePhoenixRouter router;
    address user = address(0xB0B);

    address tIn;
    address tOut;
    address x0;
    address x1;
    bool zfo;
    uint256 mIn;   // one unit of tokenIn
    int24 p0;      // the market tick
    uint160 sp0;
    address pairE;
    bytes32 pidH;

    function setUp() public {
        mgr = new MockV4WindowManager();
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(mgr));
        solver = new BlazePhoenixSolver(address(hub), address(0));
        BlazePhoenixQuoter q = new BlazePhoenixQuoter(address(hub), address(solver));
        router = new BlazePhoenixRouter(address(hub), address(solver), address(this), address(0xFEE1), address(0xFEE2));
        hub.setRoles(address(router), address(solver), address(q));
    }

    // ── v4LimitTick ──────────────────────────────────────────────────────────

    function _rate(uint24 fee, int24 t, bool z0) internal pure returns (uint256) {
        return BPC.v4ValueAt(1e18, fee, BPC.sqrtPriceAtTick(t), z0);
    }

    /// The bar is the rate at a tick t0: the limit is the last tick, in the swap's direction,
    /// whose rate still pays it; the next tick past it pays less.
    function testFuzz_LimitTickIsTheLastTickThatPaysTheBar(int256 t, uint256 f, bool z0) public pure {
        int24 t0 = int24(bound(t, -200_000, 200_000));
        uint24 fee = uint24(bound(f, 0, 999_999));
        uint256 z = _rate(fee, t0, z0);
        (bool ok, int24 lim) = BPC.v4LimitTick(z, fee, BPC.sqrtPriceAtTick(t0), z0);
        assertTrue(ok, "a bar the stop rate pays is refused");
        assertGe(_rate(fee, lim, z0), z, "the limit tick pays less than the bar");
        if (z0) {
            assertLe(lim, t0, "the limit stops short of a tick that pays");
            if (lim > MIN_TICK) assertLt(_rate(fee, lim - 1, z0), z, "the tick past the limit still pays");
        } else {
            assertGe(lim, t0, "the limit stops short of a tick that pays");
            if (lim < MAX_TICK) assertLt(_rate(fee, lim + 1, z0), z, "the tick past the limit still pays");
        }
    }

    /// A zero bar is paid everywhere: the limit is the end of the tick range.
    function test_ZeroBarRunsToTheEndOfTheRange() public pure {
        (bool ok, int24 lim) = BPC.v4LimitTick(0, 3000, BPC.sqrtPriceAtTick(0), true);
        assertTrue(ok);
        assertEq(lim, MIN_TICK);
        (ok, lim) = BPC.v4LimitTick(0, 3000, BPC.sqrtPriceAtTick(0), false);
        assertTrue(ok);
        assertEq(lim, MAX_TICK);
    }

    /// One unit over the rate at the stop is refused; the rate itself is paid.
    function testFuzz_BarAboveTheStopRateIsRefused(int256 t, uint256 f, uint256 j, bool z0) public pure {
        int24 t0 = int24(bound(t, -200_000, 200_000));
        uint24 fee = uint24(bound(f, 0, 999_999));
        uint160 s = BPC.sqrtPriceAtTick(t0);
        s += uint160(bound(j, 0, BPC.sqrtPriceAtTick(t0 + 1) - s - 1));
        uint256 z = BPC.v4ValueAt(1e18, fee, s, z0);
        (bool ok, ) = BPC.v4LimitTick(z + 1, fee, s, z0);
        assertFalse(ok, "a bar the stop rate does not pay is accepted");
        (ok, ) = BPC.v4LimitTick(z, fee, s, z0);
        assertTrue(ok, "the stop rate itself is refused");
    }

    // ── the Solver seats a stopped book as a limited first leg ───────────────

    function _cfg(uint8 dIn, bool wantZfo) internal {
        PathologicalERC20 o = new PathologicalERC20("OUT", "OUT", 18);
        PathologicalERC20 i;
        for (uint256 k; ; ++k) {
            require(k < 64, "token order");
            i = new PathologicalERC20("IN", "IN", dIn);
            if ((address(i) < address(o)) == wantZfo) break;
        }
        tIn = address(i);
        tOut = address(o);
        zfo = wantZfo;
        (x0, x1) = zfo ? (tIn, tOut) : (tOut, tIn);
        mIn = 10 ** dIn;
        // raw price token1/token0 = 10^(d1-d0); log_1.0001(1e12) = 276324 -> 276400
        p0 = dIn == 18 ? int24(0) : zfo ? int24(276400) : int24(-276400);
        sp0 = mgr.sqrtAt(p0);
        i.mint(address(mgr), 1e30);
        o.mint(address(mgr), 1e30);
        i.mint(user, 1e30);
        vm.prank(user);
        i.approve(address(router), type(uint256).max);
    }

    /// E: a V2 pair `k` units deep at the market price, the side the user buys `bps` short.
    function _pairE(uint256 k, uint256 bps) internal {
        uint256 r0 = k * (zfo ? mIn : 1e18);
        uint256 r1 = BPC.mulDiv(BPC.mulDiv(r0, sp0, Q96), sp0, Q96);
        if (zfo) r1 = r1 * (10000 - bps) / 10000;
        else r0 = r0 * (10000 - bps) / 10000;
        MockV2Pair p = new MockV2Pair(x0, x1);
        PathologicalERC20(x0).mint(address(p), r0);
        PathologicalERC20(x1).mint(address(p), r1);
        p.setReserves(uint112(r0), uint112(r1));
        hub.seedPool(address(p), BPC.KIND_V2, 30, address(0), x0, x1);
        pairE = address(p);
    }

    /// H: a hookless book at the market, fee 100, spacing 1, holding about 2 units of tokenOut
    /// over +-20000 ticks, with a row of 300 one-wei positions on the order's side so its
    /// deep walk stops short of the order.
    function _bookH() internal {
        pidH = BPC.computeV4PoolId(x0, x1, 100, 1, address(0));
        mgr.initialize(pidH, sp0, p0, 100);
        uint256 l = zfo ? BPC.mulDiv(2e18, Q96, sp0) : BPC.mulDiv(2e18, sp0, Q96);
        mgr.addPosition(pidH, p0 - 20000, p0 + 20000, 1, uint128(l));
        int24 f = zfo ? p0 - 300 : p0;
        for (int24 t = f; t < f + 300; ++t) mgr.addPosition(pidH, t, t + 1, 1, 1);
        hub.addV4(x0, x1, 100, 1, address(0));
    }

    /// T: `delta` ticks better than the market, fee 500, a row of 300 one-wei positions and,
    /// inside its first tick, real liquidity that fills about `probe` of tokenIn.
    function _bookT(int24 delta, uint256 probe) internal returns (bytes32 pid) {
        int24 pt = zfo ? p0 + delta : p0 - delta;
        pid = BPC.computeV4PoolId(x0, x1, 500, 1, address(0));
        uint160 sl = mgr.sqrtAt(pt);
        uint160 su = mgr.sqrtAt(pt + 1);
        if (zfo) mgr.initialize(pid, su - 1, pt, 500);
        else mgr.initialize(pid, sl, pt, 500);
        int24 f = zfo ? pt - 299 : pt;
        for (int24 t = f; t < f + 300; ++t) mgr.addPosition(pid, t, t + 1, 1, 1);
        uint256 l = zfo ? BPC.mulDiv(BPC.mulDiv(probe, sl, Q96), su, su - sl) : BPC.mulDiv(probe, Q96, su - sl);
        mgr.addPosition(pid, pt, pt + 1, 1, uint128(l + 1));
        hub.addV4(x0, x1, 500, 1, address(0));
    }

    function _v2Out(uint256 amt) internal view returns (uint256) {
        uint256 rIn = PathologicalERC20(tIn).balanceOf(pairE);
        uint256 rOut = PathologicalERC20(tOut).balanceOf(pairE);
        return amt * 9970 * rOut / (rIn * 10000 + amt * 9970);
    }

    function _realIn(uint256 x) internal pure returns (uint256) {
        return x - BPC.mulDivUp(x, BPC.PROTOCOL_FEE_BPS, BPC.BPS);
    }

    function _limited(Leg memory l) internal pure returns (bool) {
        return (uint256(l.auxId) >> 184) & 1 != 0;
    }

    /// One hop, H and E: H rides once, first and price-limited; every unit it may fill pays the
    /// exact plan's average rate; the order spends exactly X and settles at least what H alone
    /// or E alone would.
    function _seated(uint8 dIn, bool wantZfo) internal {
        _cfg(dIn, wantZfo);
        _pairE(5, 300);
        _bookH();
        uint256 x = mIn / 10;
        Route memory r = solver.findBestRoutePlan(tIn, tOut, x).best;
        assertEq(r.hops.length, 1, "one hop");
        Leg[] memory legs = r.hops[0].legs;
        assertGt(legs.length, 1, "the limited leg rides alone");
        address h = address(uint160(uint256(pidH)));
        assertEq(legs[0].pool, h, "the stopped book is not the first leg");
        assertTrue(_limited(legs[0]), "the stopped book rides with no price limit");
        for (uint256 k = 1; k < legs.length; ++k) {
            assertTrue(legs[k].pool != h, "the stopped book rides twice");
            assertFalse(_limited(legs[k]), "a second limited leg");
        }
        // The limit pays E's average over the hop's input (the bar), and the tick past it
        // does not pay it (1 % either way covers E's quote margin).
        uint256 bar = BPC.mulDivUp(_v2Out(r.hops[0].amountIn), 1e18, r.hops[0].amountIn);
        (, int24 lim) = BPC.v4Limit(legs[0].auxId);
        assertGe(_rate(100, lim, zfo) * 100, bar * 99, "the limit pays less than the exact plan's average");
        assertLt(_rate(100, zfo ? lim - 1 : lim + 1, zfo) * 100, bar * 101, "the limit stops short of the bar");
        uint256 twinH;
        (, twinH, , , ) = mgr.specSwap(pidH, _realIn(x), 100, 1, zfo,
            zfo ? BPC.MIN_SQRT_PRICE_PLUS_ONE : BPC.MAX_SQRT_PRICE_MINUS_ONE);
        uint256 twinE = _v2Out(_realIn(x));
        uint256 b0 = PathologicalERC20(tIn).balanceOf(user);
        vm.prank(user);
        uint256 got = router.swapExactIn(r, x, 1, user, block.timestamp + 1);
        emit log_named_uint("got", got);
        emit log_named_uint("twin_book_alone", twinH);
        emit log_named_uint("twin_exact_alone", twinE);
        assertEq(b0 - PathologicalERC20(tIn).balanceOf(user), x, "the order spent other than its input");
        assertGe(got, twinH, "the hop settles less than the book alone");
        assertGe(got, twinE, "the hop settles less than the exact plan alone");
    }

    function test_StoppedBookRidesLimitedFirst_18_18_ZeroForOne() public { _seated(18, true); }
    function test_StoppedBookRidesLimitedFirst_18_18_OneForZero() public { _seated(18, false); }
    function test_StoppedBookRidesLimitedFirst_6_18_ZeroForOne() public { _seated(6, true); }
    function test_StoppedBookRidesLimitedFirst_6_18_OneForZero() public { _seated(6, false); }

    /// T verified only dust (its probe and a row of one-wei positions): its verified rank does
    /// not pay the bar over the input it verified, so no leg rides with a limit, although the
    /// rate where its walk stopped is far above the bar.
    function _dustStaysOut(bool wantZfo) internal {
        _cfg(18, wantZfo);
        _pairE(5, 0);
        _bookT(1000, 10);
        uint256 x = mIn / 10;
        Route memory r = solver.findBestRoutePlan(tIn, tOut, x).best;
        for (uint256 a; a < r.hops.length; ++a)
            for (uint256 k; k < r.hops[a].legs.length; ++k)
                assertFalse(_limited(r.hops[a].legs[k]), "a book that verified only dust rides limited");
        vm.prank(user);
        uint256 got = router.swapExactIn(r, x, 1, user, block.timestamp + 1);
        assertGe(got, _v2Out(_realIn(x)), "the hop settles less than the exact plan alone");
    }

    function test_DustVerifiedBookRidesNoLimit_ZeroForOne() public { _dustStaysOut(true); }
    function test_DustVerifiedBookRidesNoLimit_OneForZero() public { _dustStaysOut(false); }
}
