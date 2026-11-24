// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// V4-BAND (2026-11-24): THE PROBE'S BOUND IS MEASURED WHERE THE PROBE'S RATE IS WALKED.
//
// The band's premise (`BlazePhoenixMath`: "a measured price sits within its probe's bound e of
// its spot, s(1-e) <= p") is the reason a row priced ABOVE the base by more than the
// no-arbitrage width may be dropped. On a singleton book the probe's rate is WALKED through the
// book's own ticks while its bound was MODELLED from the virtual depth at the current price: a
// book holding one thin slice at the market and nothing until a far resting ask paid the probe a
// quarter of its spot and declared a bound of 5e-5. As the hop's base it then dropped the honest
// pair "from above" and took the whole order at 1.25 % of what the pair pays alone.
//
// red at 833c3b1 (the eight settlement rows, the premise pins, the exact-value pin and
// test_Limit_ABookOnItsEdgePaysNothingAndItsShareStaysWithTheUser, whose plan reverted there).
//
// Spec, from the premise and not from the code:
//   (S1) premise: every live singleton row has rank / n >= spot * (1 - err), n the probe net of
//        the fee, spot the book's own price at rest;
//   (S2) the measure is the walked shortfall itself, rounded up: err = ceil((s - rank) / s) with
//        s the probe's fee-net output at the spot, whenever that exceeds the modelled bound;
//   (S3) identity: where the walk never leaves one range the modelled bound already covers the
//        shortfall: err is the modelled figure, plus at most the rounding of the measure's own
//        reference (the spot output is rounded up, so the measure only ever over-states);
//   (S4) errOrder >= err still holds (the lower edge reads it);
//   (S5) limit: a probe whose spot output cannot be carried in 128 bits keeps the modelled bound;
//   (S6) settlement: the order is never routed below what the honest pair pays alone.
//   (S7) limit: a book whose price rests ON the edge the order leaves through pays the probe
//        the far ask's price, next to nothing, so its measure is the whole shortfall and it
//        drops nobody from above. It keeps its depth-weighted share of the split, promises
//        nothing for it, and that share is never charged: the order fills the pair's share at
//        the pair's own curve and the rest stays with the user.

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, RoutePlan, Hop, QuoteCtx} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV4TickManager} from "./mocks/MockV4TickManager.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";

contract V4BandProbeBoundTest is Test {
    BlazePhoenixHub    hub;
    BlazePhoenixSolver solver;
    BlazePhoenixRouter router;
    MockV4TickManager  mgr;

    address user = address(0xBEEF);
    uint24  constant FEE  = 3000;
    int24   constant TS   = 60;
    uint256 constant ORD  = 2e18;
    uint256 constant WORD = 15360;   // one bitmap word of ticks at spacing 60
    uint256 constant Q96  = 2 ** 96;
    uint256 constant WAD  = 1e18;
    uint128 constant CUR  = 1e20;    // the liquidity of the range the price sits in

    function setUp() public {
        mgr = new MockV4TickManager();
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(mgr));
        solver = new BlazePhoenixSolver(address(hub), address(0));
        router = new BlazePhoenixRouter(address(hub), address(solver), address(this), address(0xFEE1), address(0xFEE2));
        hub.setRoles(address(router), address(solver), address(0));
    }

    // -- the book: one range at the market, the price one tick inside it, `gap` empty bitmap
    //    words, then a resting ask of `r` tokenOut over ten spacings -----------------------------
    function _book(address tin, address tout, uint128 cur, uint256 gap, uint256 r)
        internal returns (bytes32 pid, uint160 sp, bool zfo)
    {
        zfo = tin < tout;
        (address t0, address t1) = zfo ? (tin, tout) : (tout, tin);
        pid = BPC.computeV4PoolId(t0, t1, FEE, TS, address(0));
        int24 tick = zfo ? int24(1) : int24(59);
        int24 lo = zfo ? -int24(int256(gap * WORD)) - 600 : 60 + int24(int256(gap * WORD));
        sp = mgr.sqrtAt(tick);
        mgr.initialize(pid, sp, tick, FEE);
        mgr.addPosition(pid, 0, 60, TS, cur);
        if (r != 0) {
            uint256 sl = mgr.sqrtAt(lo);
            uint256 su = mgr.sqrtAt(lo + 600);
            mgr.addPosition(pid, lo, lo + 600, TS,
                uint128(zfo ? BPC.mulDiv(r, Q96, su - sl) : BPC.mulDiv(BPC.mulDiv(r, sl, Q96), su, su - sl)));
        }
    }

    function _ctx(address tin, address tout, bool zfo) internal view returns (QuoteCtx memory c) {
        c.kind        = BPC.KIND_V4;
        c.zeroForOne  = zfo;
        c.fee         = FEE;
        c.tickSpacing = TS;
        c.tokenIn     = tin;
        c.tokenOther  = tout;
        c.v4Manager   = address(mgr);
    }

    function _tokens(bool flip) internal returns (address tin, address tout) {
        address x = address(new MockERC20("TKN", "TKN"));
        address y = address(new MockERC20("TKN", "TKN"));
        (tin, tout) = flip ? (y, x) : (x, y);
    }

    /// @dev The probe's fee-net output at the book's price at rest, rounded down (the premise's
    ///      right-hand side) and up (the measure's reference): n * P going down, n / P going up.
    function _spot(uint256 amt, uint160 sp, bool zfo) internal pure returns (uint256 dn, uint256 up) {
        uint256 nDn = amt * (1_000_000 - FEE) / 1_000_000;
        uint256 nUp = BPC.mulDivUp(amt, 1_000_000 - FEE, 1_000_000);
        dn = zfo ? BPC.mulDiv(BPC.mulDiv(nDn, sp, Q96), sp, Q96) : BPC.mulDiv(BPC.mulDiv(nDn, Q96, sp), Q96, sp);
        up = zfo ? BPC.mulDivUp(BPC.mulDivUp(nUp, sp, Q96), sp, Q96) : BPC.mulDivUp(BPC.mulDivUp(nUp, Q96, sp), Q96, sp);
    }

    /// @dev The bound as modelled from the depth at the current price (the figure at 833c3b1).
    function _modelled(uint256 amt, uint256 rank, uint128 liq, uint160 sp) internal pure returns (uint256 e) {
        uint256 n = amt * (1_000_000 - FEE) / 1_000_000;
        uint256 d = BPC.depthFromL18(liq, sp, 18, 18);
        uint256 m = amt < rank ? amt : rank;
        uint256 rnd = (3 * WAD + 2 * amt) / rank + 1;
        e = n == 0 || m >= d ? WAD : rnd + 3 * WAD / n + BPC.mulDivUp(m, WAD, d);
        if (e > WAD) e = WAD;
    }

    // -- (S6) settlement: the eight rows -------------------------------------------------------
    function _pairPays(uint256 r, uint256 x) internal pure returns (uint256) {
        uint256 xf = x * 997;
        return xf * r / (r * 1000 + xf);
    }

    function _swap(address tin, address tout) internal returns (uint256 got) {
        RoutePlan memory plan = solver.findBestRoutePlan(tin, tout, ORD);
        assertGt(plan.best.hops.length, 0, "precondition: the pair is routable");
        vm.prank(user);
        got = router.swapExactIn(plan.best, ORD, plan.best.singleOutFloor, user, block.timestamp + 1);
    }

    /// @dev The oracle is the same order through the same Router with the pair alone (the Router's
    ///      own fee rides on both sides of the comparison), pinned against the pair's closed form.
    function _settle(uint256 gap, uint256 r, bool flip) internal returns (uint256 got, uint256 alone) {
        (address tin, address tout) = _tokens(flip);
        MockV2Pair p = new MockV2Pair(tin, tout);
        MockERC20(tin).mint(address(p), 5e17);
        MockERC20(tout).mint(address(p), 5e17);
        p.setReserves(5e17, 5e17);
        hub.seedPool(address(p), BPC.KIND_V2, 30, address(0), tin, tout);
        MockERC20(tin).mint(user, ORD);
        vm.prank(user);
        MockERC20(tin).approve(address(router), type(uint256).max);

        uint256 snap = vm.snapshotState();
        alone = _swap(tin, tout);
        vm.revertToState(snap);
        uint256 curve = _pairPays(5e17, ORD);
        assertLe(alone, curve, "precondition: the pair alone pays its curve, less the Router's fee");
        assertGt(alone * 100, curve * 99, "precondition: the pair alone pays its curve, less the Router's fee");

        _book(tin, tout, CUR, gap, r);
        MockERC20(tin).mint(address(mgr), 1e26);
        MockERC20(tout).mint(address(mgr), 1e26);
        hub.addV4(tin, tout, FEE, TS, address(0));
        got = _swap(tin, tout);
    }

    function _row(uint256 gap, uint256 r, bool flip) internal {
        (uint256 got, uint256 alone) = _settle(gap, r, flip);
        assertGe(got, alone, "the order settled below what the honest pair pays alone");
    }

    function test_ThinBookOverAVoid_Gap8_OneMass() public { _row(8, 5e17, false); }
    function test_ThinBookOverAVoid_Gap8_OneMass_Flipped() public { _row(8, 5e17, true); }
    function test_ThinBookOverAVoid_Gap8_TwoMass() public { _row(8, 1e18, false); }
    function test_ThinBookOverAVoid_Gap8_TwoMass_Flipped() public { _row(8, 1e18, true); }
    function test_ThinBookOverAVoid_Gap15_OneMass() public { _row(15, 5e17, false); }
    function test_ThinBookOverAVoid_Gap15_OneMass_Flipped() public { _row(15, 5e17, true); }
    function test_ThinBookOverAVoid_Gap15_TwoMass() public { _row(15, 1e18, false); }
    function test_ThinBookOverAVoid_Gap15_TwoMass_Flipped() public { _row(15, 1e18, true); }

    // -- (S1) the premise, on the same eight books and across the range ---------------------------
    function _premise(uint128 cur, uint256 gap, uint256 r, bool flip, uint256 amt, uint256 order) internal {
        (address tin, address tout) = _tokens(flip);
        (, uint160 sp, bool zfo) = _book(tin, tout, cur, gap, r);
        (, uint256 rank, , uint256 err, uint256 errOrder) = BPC.universalProbe(_ctx(tin, tout, zfo), amt, 0, true, order);
        if (rank == 0) return;
        (uint256 spotDn, ) = _spot(amt, sp, zfo);
        assertGe(rank * WAD, spotDn * (WAD - err), "premise: the probe's fee-free rate sits under spot * (1 - err)");
        assertGe(errOrder, err, "errOrder < err");
    }

    function test_Premise_OnTheEightRows() public {
        for (uint256 i; i < 8; ++i) {
            _premise(CUR, i & 1 == 0 ? 8 : 15, i & 2 == 0 ? 5e17 : 1e18, i & 4 != 0, ORD / 100, ORD);
        }
    }

    function testFuzz_Premise_EveryLiveSingletonRow(uint128 cur, uint256 gap, uint256 r, bool flip, uint256 amt, uint256 order)
        public
    {
        cur = uint128(bound(cur, 1e12, 1e26));
        gap = bound(gap, 0, 17);
        r = bound(r, 0, 1e24);
        amt = bound(amt, 1e6, 1e24);
        order = bound(order, 1, type(uint128).max);
        _premise(cur, gap, r, flip, amt, order);
    }

    // -- (S2) the measure, to the wei (the boundary cell: one wei of rounding is the difference) ---
    function _measured(uint256 gap, uint256 r, bool flip) internal {
        uint256 amt = ORD / 100;
        (address tin, address tout) = _tokens(flip);
        (, uint160 sp, bool zfo) = _book(tin, tout, CUR, gap, r);
        (, uint256 rank, , uint256 err, uint256 errOrder) = BPC.universalProbe(_ctx(tin, tout, zfo), amt, 0, true, amt);
        (, uint256 spotUp) = _spot(amt, sp, zfo);
        uint256 want = BPC.mulDivUp(spotUp - rank, WAD, spotUp);
        assertGt(want, 7e17, "precondition: the probe crossed the void");
        assertLt(_modelled(amt, rank, CUR, sp), 1e15, "precondition: the modelled bound is the small one");
        assertGt((spotUp - rank) * WAD % spotUp, 0, "precondition: the division is not exact (the rounding shows)");
        assertEq(err, want, "err is not the walked shortfall, rounded up");
        assertEq(errOrder, want, "an order at the probe reads the probe's bound");
    }

    function test_Measured_ToTheWei_Gap8() public { _measured(8, 5e17, false); }
    function test_Measured_ToTheWei_Gap8_Flipped() public { _measured(8, 5e17, true); }
    function test_Measured_ToTheWei_Gap15() public { _measured(15, 1e18, false); }
    function test_Measured_ToTheWei_Gap15_Flipped() public { _measured(15, 1e18, true); }

    // -- (S3) identity: one range, the walk never leaves it ---------------------------------------
    function testFuzz_Identity_OneRangeKeepsTheModelledBound(uint128 liq, int24 tick, bool flip, uint256 amt) public {
        // L <= 2^96 is the model's own domain: past it the sqrt-price floors move the output by
        // L / 2^96 wei, a limit the model writes down and the measure now reads on a singleton.
        liq = uint128(bound(liq, 1e15, 2 ** 96));
        tick = int24(bound(tick, -120_000, 120_000));
        (address tin, address tout) = _tokens(flip);
        bool zfo = tin < tout;
        (address t0, address t1) = zfo ? (tin, tout) : (tout, tin);
        bytes32 pid = BPC.computeV4PoolId(t0, t1, FEE, TS, address(0));
        uint160 sp = mgr.sqrtAt(tick);
        mgr.initialize(pid, sp, tick, FEE);
        mgr.addPosition(pid, -887_220, 887_220, TS, liq);
        // at most a thousandth of the input-side virtual reserve: the walk stays in the range
        uint256 vIn = zfo ? BPC.mulDiv(liq, Q96, sp) : BPC.mulDiv(liq, sp, Q96);
        vm.assume(vIn >= 1e9);
        amt = bound(amt, 1e6, vIn / 1000);
        (, uint256 rank, , uint256 err, uint256 errOrder) = BPC.universalProbe(_ctx(tin, tout, zfo), amt, 0, true, amt);
        vm.assume(rank > 0);
        uint256 want = _modelled(amt, rank, liq, sp);
        // The reference is rounded up three times (the fee, the two sqrt-price products): under
        // 1/n + 1/sqrt(n * o) + 1/o <= 1.5/n + 1.5/o of the price, and nothing else may move.
        uint256 slack = want == WAD ? 0 : 2 * WAD / (amt * (1_000_000 - FEE) / 1_000_000) + 2 * WAD / rank + 2;
        assertGe(err, want, "one range: err fell under the modelled bound");
        assertLe(err - want, slack, "one range: err left the modelled bound by more than the reference's rounding");
        assertEq(errOrder < WAD ? errOrder : WAD, err, "one range: an order at the probe reads the probe's bound");
    }

    // -- (S5) limit: a spot output past 128 bits is not a measure --------------------------------
    function test_Limit_AProbePast128BitsKeepsTheModelledBound() public {
        (address tin, address tout) = _tokens(false);
        if (tin > tout) (tin, tout) = (tout, tin);   // zeroForOne: the price is token1 per token0
        bytes32 pid = BPC.computeV4PoolId(tin, tout, FEE, TS, address(0));
        int24 tick = -360_000;                        // P ~ 2.3e-16: the rounding term 2a/o stays under a hundredth
        uint128 liq = 1e34;                           // the probe is a thousandth of the book
        uint160 sp = mgr.sqrtAt(tick);
        mgr.initialize(pid, sp, tick, FEE);
        mgr.addPosition(pid, -887_220, 887_220, TS, liq);
        uint256 amt = 2 ** 129;
        (, uint256 rank, , uint256 err, ) = BPC.universalProbe(_ctx(tin, tout, true), amt, 0, true, amt);
        assertGt(rank, 0, "precondition: the book answers");
        uint256 want = _modelled(amt, rank, liq, sp);
        assertLt(want, WAD / 10, "precondition: the modelled bound states a width");
        assertEq(err, want, "a saturated spot figure was read as a measure");
    }

    // -- (S7) limit: a book on the edge the order leaves through -------------------------------
    function _pair(address tin, address tout) internal returns (address) {
        MockV2Pair p = new MockV2Pair(tin, tout);
        MockERC20(tin).mint(address(p), 5e17);
        MockERC20(tout).mint(address(p), 5e17);
        p.setReserves(5e17, 5e17);
        hub.seedPool(address(p), BPC.KIND_V2, 30, address(0), tin, tout);
        return address(p);
    }

    function _fund(address tin, uint256 amt) internal {
        MockERC20(tin).mint(user, amt);
        vm.prank(user);
        MockERC20(tin).approve(address(router), type(uint256).max);
    }

    /// @dev The book's price rests ON the lower edge of its range [0, 60) and the order sells
    ///      downwards: the first wei leaves the range into seventeen empty words, so the probe is
    ///      paid the far ask's price, under a billionth of the spot, by a row declaring 1e20 of
    ///      depth. At 833c3b1 that row was the band's base, dropped the pair from above and left
    ///      no viable action at any size (the plan reverted). With the bound measured it stays in
    ///      the band beside the pair and takes its depth weight, 200 parts in 201, of the split;
    ///      that share is promised nothing, carries no leg and is left unrouted. The pin is what
    ///      the user is charged: the pair's 1/201 and the Router's fee on it, at the pair's own
    ///      curve; the other 200/201 never leaves the wallet.
    function test_Limit_ABookOnItsEdgePaysNothingAndItsShareStaysWithTheUser() public {
        uint256 charged = 9978109452736318;   // the pair's share of the order plus the Router's fee on it
        (address tin, address tout) = _tokens(false);
        if (tin > tout) (tin, tout) = (tout, tin);   // zeroForOne: the order leaves the range downwards

        // the differential: the same charge through the same Router with the pair alone
        uint256 snap = vm.snapshotState();
        _pair(tin, tout);
        _fund(tin, charged);
        RoutePlan memory alone = solver.findBestRoutePlan(tin, tout, charged);
        vm.prank(user);
        uint256 honest = router.swapExactIn(alone.best, charged, alone.best.singleOutFloor, user, block.timestamp + 1);
        assertEq(MockERC20(tin).balanceOf(user), 0, "precondition: the pair alone takes the whole charge");
        vm.revertToState(snap);

        bytes32 pid = BPC.computeV4PoolId(tin, tout, FEE, TS, address(0));
        int24 lo = -int24(int256(17 * WORD)) - 600;
        mgr.initialize(pid, mgr.sqrtAt(0), 0, FEE);
        mgr.addPosition(pid, 0, 60, TS, CUR);
        mgr.addPosition(pid, lo, lo + 600, TS, uint128(BPC.mulDiv(1e18, Q96, mgr.sqrtAt(lo + 600) - mgr.sqrtAt(lo))));
        MockERC20(tin).mint(address(mgr), 1e26);
        MockERC20(tout).mint(address(mgr), 1e26);
        hub.addV4(tin, tout, FEE, TS, address(0));
        address p = _pair(tin, tout);
        _fund(tin, ORD);

        (, uint256 rank, , , ) = BPC.universalProbe(_ctx(tin, tout, true), ORD, 0, true, ORD);
        assertLt(rank * 1e9, ORD, "precondition: on its edge the book pays the probe under a billionth of its spot");

        RoutePlan memory plan = solver.findBestRoutePlan(tin, tout, ORD);
        assertEq(plan.best.hops.length, 1, "one hop");
        assertEq(plan.best.hops[0].legs.length, 1, "the book's share is promised nothing and carries no leg");
        assertEq(plan.best.hops[0].legs[0].pool, p, "the surviving leg is the pair");
        assertEq(plan.best.hops[0].amountIn, ORD / 201, "the pair's depth weight: 5e17 beside the book's 1e20");
        assertEq(plan.best.hops[0].amountIn, 9950248756218905, "the pair's share, to the wei");

        vm.prank(user);
        uint256 got = router.swapExactIn(plan.best, ORD, plan.best.singleOutFloor, user, block.timestamp + 1);

        assertEq(ORD - MockERC20(tin).balanceOf(user), charged, "the user was charged for a share no venue absorbed");
        assertEq(MockERC20(tin).balanceOf(user), 1990021890547263682, "the unrouted share stays with the user");
        assertEq(MockERC20(tout).balanceOf(user), got, "the user holds what the swap returned");
        assertEq(got, plan.best.totalOut, "the fill is the planned figure");
        assertEq(got, 9727398676995726, "the fill, to the wei");
        assertEq(MockERC20(tin).balanceOf(address(router)), 0, "tokenIn left in the Router");
        assertEq(MockERC20(tout).balanceOf(address(router)), 0, "tokenOut left in the Router");
        assertEq(MockERC20(tin).balanceOf(address(hub)), 0, "tokenIn left in the Hub");
        assertEq(MockERC20(tout).balanceOf(address(hub)), 0, "tokenOut left in the Hub");
        assertEq(honest, 9727323897856121, "the pair alone on the same charge, to the wei");
        assertGe(got * 100, honest * 99, "the charged share settled below what the pair pays for it alone");
    }
}
