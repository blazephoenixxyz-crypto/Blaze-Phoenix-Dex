// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// A BOOK WHOSE CURRENT TICK IS EMPTY ANSWERS ITS WALK. A V4 book whose price sits in a gap (no
// liquidity in range) still pays whatever its next stretches hold: the swap crosses the gap for
// free and fills on the liquidity ahead. `BlazePhoenixCore._v4Quote` quoted such a book as a dead
// pool on the current tick's liquidity alone, and the frame's door (`v4LegOut`) answered zero for
// it. Both now ask the walk: the book is quoted when it holds anything within the promise's
// sixteen stretches (`V4_WALK_MAX_STEPS`, `v4Held`), and for nothing otherwise - an initialized
// and empty book costs sixteen reads, never the ranking's 256.
//
// What the quoted book says: `out` is what the pool pays (the specification's swap), `mass` and
// `depthWad` stay zero (the current tick declares nothing: the book casts no vote in the band),
// and the frame promises the number the arm quoted.
//
// Oracle: `MockV4TickManager.specSwap`, the V4 swap loop written from the specification with
// its own arithmetic; the stretch counts below are derived by hand from
// TickBitmap.nextInitializedTickWithinOneWord (tick spacing 1, price at tick 0, nothing in range):
//   price falling: stretch 1 is tick 0 to tick 0, then one stretch per word edge (-256k) or
//     initialized tick. A position whose upper tick is -(256g + 10) is entered on stretch g + 2
//     and pays on stretch g + 3;
//   price rising: stretch k ends at 256k - 1 or at an initialized tick. A position whose lower
//     tick is 256g + 10 is entered on stretch g + 1 and pays on stretch g + 2.
//
// Red before the fix (9b2855e): the tests marked RED below.
// Mutants (.github/scripts/mutants.py, block «caixa-1123 v4walk»):
//   the cut reads the current tick alone again -> `..._IsQuotedForWhatItPays` red;
//   the cut removed (an empty book is walked) -> `..._NothingWithinSixteenStretches_QuotesNothing` red;
//   the cut asks the ranking's 256 stretches -> `..._LiquidityPastThePromiseHorizon_QuotesNothing` red;
//   the frame's door reads the current tick alone again -> `..._TheFramePromisesWhatTheArmQuoted` red.

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixQuoter} from "../src/BlazePhoenixQuoter.sol";
import {BlazePhoenixCore as BPC, QuoteCtx, RoutePlan, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV4TickManager} from "./mocks/MockV4TickManager.sol";

contract EmptyTickBookAnswersItsWalkTest is Test {
    uint256 constant WAD = 1e18;
    uint24 constant FEE = 3000;
    int24 constant TS = 1;
    uint128 constant LIQ = 1e24;
    uint256 constant ORDER = 1e18;
    /// The promise's horizon in stretches, written by hand (not read from the Core).
    uint256 constant HORIZON = 16;
    /// An initialized and empty book is refused within the promise's reads. Measured 2026-11-24:
    /// see `test_V4Arm_NothingWithinSixteenStretches_QuotesNothing`.
    uint256 constant EMPTY_BOOK_GAS_CEILING = 250_000;

    MockV4TickManager mgr;
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    BlazePhoenixRouter router;
    BlazePhoenixQuoter quoter;
    address t0;
    address t1;
    address user = address(0xBEEF);

    function setUp() public {
        mgr = new MockV4TickManager();
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(mgr));
        solver = new BlazePhoenixSolver(address(hub), address(0));
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

    function _ctx(MockV4TickManager m, bool zfo) internal view returns (QuoteCtx memory c) {
        c.kind = BPC.KIND_V4;
        c.zeroForOne = zfo;
        c.fee = FEE;
        c.tickSpacing = TS;
        (c.tokenIn, c.tokenOther) = zfo ? (t0, t1) : (t1, t0);
        c.v4Manager = address(m);
        c.decIn1 = 19;
        c.decOther1 = 19;
    }

    /// One position of `liq`, a hundred ticks wide, whose near edge sits `gap` whole bitmap words
    /// and ten ticks ahead of tick 0 in the swap's direction.
    function _ahead(MockV4TickManager m, bool zfo, uint256 gap, uint128 liq) internal {
        int24 near = int24(int256(256 * gap + 10));
        if (zfo) m.addPosition(_pid(), -near - 100, -near, TS, liq);
        else m.addPosition(_pid(), near, near + 100, TS, liq);
    }

    /// A book of its own at tick 0 with nothing in range, and `liq` (none when 0) `gap` words ahead.
    function _gapBook(bool zfo, uint256 gap, uint128 liq) internal returns (MockV4TickManager m, QuoteCtx memory c) {
        m = new MockV4TickManager();
        m.initialize(_pid(), m.sqrtAt(0), 0, FEE);
        if (liq > 0) _ahead(m, zfo, gap, liq);
        c = _ctx(m, zfo);
    }

    /// The stretch on which the position of `_ahead` pays (header).
    function _paysAt(bool zfo, uint256 gap) internal pure returns (uint256) { return gap + (zfo ? 3 : 2); }

    /// The deepest gap whose position still pays inside the horizon.
    function _lastGap(bool zfo) internal pure returns (uint256) { return HORIZON - (zfo ? 3 : 2); }

    /// Every figure of both entry points says nothing, at the bar's three corners.
    function _assertNothing(QuoteCtx memory c, uint256 a) internal view {
        uint256[3] memory bars = [uint256(0), 1, type(uint256).max];
        for (uint256 b; b < 3; ++b) {
            (uint256 out, uint256 depth, uint256 rank, uint256 hi) = BPC.universalQuoteRank(c, a, bars[b], false);
            assertEq(out, 0, "nothing held: out");
            assertEq(depth, 0, "nothing held: depth");
            assertEq(rank, 0, "nothing held: rank");
            assertEq(hi, 0, "nothing held: hi");
        }
        (uint256 mass, uint256 pRank, uint256 fee, uint256 err, uint256 errOrder) = BPC.universalProbe(c, a, 0, true, a);
        assertEq(mass, 0, "nothing held: mass");
        assertEq(pRank, 0, "nothing held: the probe's rank");
        assertEq(fee, 0, "nothing held: fee");
        assertEq(err, WAD, "nothing held: err says nothing is known");
        assertEq(errOrder, WAD, "nothing held: errOrder says nothing is known");
    }

    // ── the arm ───────────────────────────────────────────────────────────────

    /// RED before the fix (zeros). The price in a gap, liquidity from the next initialized tick
    /// on: the book is quoted what the pool pays; dust to a size past a wei of rounding, both
    /// directions.
    function test_V4Arm_EmptyCurrentTick_LiquidityAtTheNextTick_IsQuotedForWhatItPays() public {
        uint256[3] memory sizes = [uint256(1e12), 1e18, 1e21];
        for (uint256 d; d < 2; ++d) {
            (MockV4TickManager m, QuoteCtx memory c) = _gapBook(d == 0, 0, LIQ);
            assertEq(m.liquidity(_pid()), 0, "the current tick is not empty: the test is vacuous");
            for (uint256 j; j < 3; ++j) {
                (, uint256 pays, , , ) = m.specSwap(_pid(), sizes[j], FEE, TS, d == 0);
                (uint256 out, , uint256 rank, uint256 hi) = BPC.universalQuoteRank(c, sizes[j], type(uint256).max, false);
                assertGt(pays, 0, "the pool pays nothing: the test is vacuous");
                assertGt(out, 0, "a book holding the next stretch was quoted as a dead pool");
                assertLe(out, pays + 16, "the quote is above what the pool pays");
                assertApproxEqAbs(out, pays, 64, "the quote is not the pool's swap");
                assertGe(rank, out, "rank under out");
                assertGe(hi, rank, "hi under rank");
            }
        }
    }

    /// An initialized book holding nothing at all: zeros on every figure, whatever the size and
    /// the bar, both directions, and within the promise's reads (the ranking's 256 stretches
    /// are never walked for it).
    function test_V4Arm_NothingWithinSixteenStretches_QuotesNothing() public {
        uint256[3] memory sizes = [uint256(1), 1e18, type(uint112).max];
        for (uint256 d; d < 2; ++d) {
            (, QuoteCtx memory c) = _gapBook(d == 0, 0, 0);
            for (uint256 j; j < 3; ++j) _assertNothing(c, sizes[j]);
            (, QuoteCtx memory cold) = _gapBook(d == 0, 0, 0);
            uint256 g = gasleft();
            BPC.universalQuoteRank(cold, 1e18, 0, false);
            g -= gasleft();
            emit log_named_uint("empty initialized book, rank mode, cold (gas)", g);
            assertLt(g, EMPTY_BOOK_GAS_CEILING, "an empty book was walked past the promise's reads");
        }
    }

    /// The horizon, each side of it. Liquidity paying on the sixteenth stretch is quoted what the
    /// pool pays; liquidity paying on the seventeenth is past the promise and the book says
    /// nothing, the ranking figures included.
    function test_V4Arm_LiquidityPastThePromiseHorizon_QuotesNothing() public {
        for (uint256 d; d < 2; ++d) {
            bool zfo = d == 0;
            (MockV4TickManager m, QuoteCtx memory c) = _gapBook(zfo, _lastGap(zfo), LIQ);
            assertEq(_paysAt(zfo, _lastGap(zfo)), HORIZON, "the control is not on the last stretch");
            (, uint256 pays, , , ) = m.specSwap(_pid(), ORDER, FEE, TS, zfo);
            (uint256 out, , , ) = BPC.universalQuoteRank(c, ORDER, 0, false);
            assertGt(out, 0, "liquidity on the sixteenth stretch was not quoted");
            assertApproxEqAbs(out, pays, 64, "the sixteenth stretch is not quoted what the pool pays");
            (, c) = _gapBook(zfo, _lastGap(zfo) + 1, LIQ);
            _assertNothing(c, 1);
            _assertNothing(c, ORDER);
            _assertNothing(c, type(uint112).max);
        }
    }

    /// RED before the fix (rank 0). The quoted book declares nothing at its own price: no mass
    /// and no depth, so both bounds say nothing is known and it casts no vote.
    function test_V4Arm_EmptyCurrentTick_QuotedBookCastsNoVote() public {
        for (uint256 d; d < 2; ++d) {
            (, QuoteCtx memory c) = _gapBook(d == 0, 0, LIQ);
            (uint256 mass, uint256 rank, uint256 fee, uint256 err, uint256 errOrder) =
                BPC.universalProbe(c, ORDER, 0, true, ORDER);
            (, uint256 depth, , ) = BPC.universalQuoteRank(c, ORDER, 0, true);
            assertGt(rank, 0, "the book was not quoted");
            assertEq(mass, 0, "an empty current tick declared a mass");
            assertEq(depth, 0, "an empty current tick declared a depth");
            assertEq(fee, FEE, "the quoted book's fee in pips");
            assertEq(err, WAD, "err: nothing is known of a book declaring no depth");
            assertEq(errOrder, WAD, "errOrder: nothing is known of a book declaring no depth");
        }
    }

    /// Any size, any gap from none to past the horizon, any liquidity ahead, any bar, both
    /// directions: out <= rank <= hi, no depth declared, zeros when nothing pays inside the
    /// horizon and the pool's own swap when something does.
    function testFuzz_V4Arm_EmptyTick_OutLeRankLeHi(
        uint256 amountIn, uint256 gap, uint128 liqAhead, bool zfo, uint256 bar
    ) public {
        gap = bound(gap, 0, 20);
        amountIn = bound(amountIn, 1, uint256(1) << 112);
        liqAhead = uint128(bound(liqAhead, 1, uint256(1) << 100));
        uint256 pick = bar % 3;
        bar = pick == 0 ? 0 : pick == 1 ? type(uint256).max : bar % (2 * amountIn + 1);
        (MockV4TickManager m, QuoteCtx memory c) = _gapBook(zfo, gap, liqAhead);
        (uint256 out, uint256 depth, uint256 rank, uint256 hi) = BPC.universalQuoteRank(c, amountIn, bar, false);
        assertLe(out, rank, "out above rank");
        assertLe(rank, hi, "rank above hi");
        assertEq(depth, 0, "an empty current tick declared a depth");
        if (_paysAt(zfo, gap) > HORIZON) {
            assertEq(hi, 0, "nothing inside the horizon, and the book was quoted");
        } else {
            (, uint256 pays, , , ) = m.specSwap(_pid(), amountIn, FEE, TS, zfo);
            assertLe(out, pays + 16, "the quote is above what the pool pays");
            assertApproxEqAbs(out, pays, 64, "the quote is not the pool's swap");
        }
    }

    // ── the doors ─────────────────────────────────────────────────────────────

    /// The quote and the probe read one body: the same rank, and a promise the bar does not move.
    function test_Doors_EmptyTickBook_QuoterAndProbeAgree() public {
        uint256[4] memory sizes = [uint256(1), 1e12, 1e18, 1e24];
        for (uint256 d; d < 2; ++d) {
            uint256[4] memory gaps = [uint256(0), 5, _lastGap(d == 0), _lastGap(d == 0) + 1];
            for (uint256 k; k < 4; ++k) {
                (, QuoteCtx memory c) = _gapBook(d == 0, gaps[k], LIQ);
                for (uint256 j; j < 4; ++j) {
                    (uint256 out, , uint256 rank, ) = BPC.universalQuoteRank(c, sizes[j], 0, true);
                    (, uint256 pRank, , , ) = BPC.universalProbe(c, sizes[j], 0, true, sizes[j]);
                    (uint256 outTop, , , ) = BPC.universalQuoteRank(c, sizes[j], type(uint256).max, false);
                    assertEq(pRank, rank, "the probe ranked another number than the quote");
                    assertEq(outTop, out, "the promise moved with the bar");
                }
            }
        }
    }

    /// RED before the frame's door asked the walk (it answered 0 on the current tick's liquidity
    /// alone). What the arm quotes is what the frame promises, to the wei: a leg planned on a
    /// book in a gap is checked in the frame against a number, never carried on its attested
    /// figure alone. An empty book is promised nothing.
    function test_Doors_EmptyTickBook_TheFramePromisesWhatTheArmQuoted() public {
        uint256[5] memory sizes = [uint256(1), 1e12, 1e18, 1e24, type(uint112).max];
        uint256 quoted;
        for (uint256 d; d < 2; ++d) {
            uint256[4] memory gaps = [uint256(0), 5, _lastGap(d == 0), _lastGap(d == 0) + 1];
            for (uint256 k; k < 4; ++k) {
                (MockV4TickManager m, QuoteCtx memory c) = _gapBook(d == 0, gaps[k], LIQ);
                for (uint256 j; j < 5; ++j) {
                    (uint256 arm, , , ) = BPC.universalQuoteRank(c, sizes[j], type(uint256).max, false);
                    uint256 frame = BPC.v4LegOut(address(m), _pid(), sizes[j], FEE, TS, d == 0);
                    assertEq(frame, arm, "the frame promised another number than the arm quoted");
                    if (arm > 0) ++quoted;
                }
            }
            (MockV4TickManager e, ) = _gapBook(d == 0, 0, 0);
            assertEq(BPC.v4LegOut(address(e), _pid(), ORDER, FEE, TS, d == 0), 0, "an empty book was promised something");
        }
        assertGt(quoted, 0, "no book was quoted: the parity is vacuous");
    }

    // ── the plan ──────────────────────────────────────────────────────────────

    /// RED before the fix (no route). One hop, the book alone on its pair: registered in range,
    /// then the price leaves the range upward and rests at tick 0 with nothing in range. The
    /// plan routes through it, promises no more than the pool pays, and the swap delivers.
    function test_Plan_ABookSittingInAGapIsNotLeftOutOfTheRoute() public {
        mgr.initialize(_pid(), mgr.sqrtAt(-60), -60, FEE);
        mgr.addPosition(_pid(), -110, -10, TS, LIQ);
        hub.addV4(t0, t1, FEE, TS, address(0));
        // What a oneForZero swap through the range's upper tick leaves behind (PoolManager state
        // slot 6: slot0 at +0, the active liquidity at +3).
        mgr.initialize(_pid(), mgr.sqrtAt(0), 0, FEE);
        mgr.setSlot(bytes32(uint256(keccak256(abi.encode(_pid(), uint256(6)))) + 3), bytes32(0));
        assertEq(mgr.liquidity(_pid()), 0, "the current tick is not empty: the test is vacuous");

        RoutePlan memory plan = solver.findBestRoutePlan(t0, t1, ORDER);
        assertEq(plan.best.hops.length, 1, "the book in the gap was left out of the route");
        assertEq(plan.best.hops[0].legs.length, 1, "one book, one leg");
        Leg memory leg = plan.best.hops[0].legs[0];
        assertEq(uint256(leg.kind), uint256(BPC.KIND_V4), "the leg is not the V4 book");
        (, uint256 pays, , , ) = mgr.specSwap(_pid(), leg.amountIn, FEE, TS, true);
        assertGt(leg.expectedOut, 0, "the leg was planned on nothing");
        assertLe(leg.expectedOut, pays + 16, "the plan promised more than the pool pays");

        (BlazePhoenixQuoter.Preview memory pv, , ) = quoter.previewPlan(t0, t1, ORDER);
        uint256 b1 = MockERC20(t1).balanceOf(user);
        vm.prank(user);
        router.swapBestExactIn(t0, t1, ORDER, 1, user, block.timestamp + 1);
        uint256 got = MockERC20(t1).balanceOf(user) - b1;
        assertEq(MockERC20(t0).balanceOf(user), 0, "the order was only partly filled");
        assertGt(got, 0, "the route delivered nothing");
        assertLe(pv.netOut, got + got / 1000, "the preview promised more than the route delivered");
    }

    // ── the attacker ──────────────────────────────────────────────────────────

    /// One-wei positions are permissionless. Sixteen of them between the price and the book's
    /// liquidity take the promise's stretches and pay nothing: the book says nothing, exactly as
    /// it did before it was quoted at all. The dust silences no more than it did; it buys no
    /// quote, no rank and no read past the horizon.
    function test_Attacker_DustInTheGap_SilencesNoMoreThanToday() public {
        for (uint256 d; d < 2; ++d) {
            bool zfo = d == 0;
            (MockV4TickManager m, QuoteCtx memory c) = _gapBook(zfo, 1, LIQ);
            for (uint256 k = 1; k <= 16; ++k) {
                int24 a = int24(int256(4 * k));
                if (zfo) m.addPosition(_pid(), -a - 2, -a, TS, 1);
                else m.addPosition(_pid(), a, a + 2, TS, 1);
            }
            _assertNothing(c, 1);
            _assertNothing(c, ORDER);
            _assertNothing(c, type(uint112).max);
            assertEq(BPC.v4LegOut(address(m), _pid(), ORDER, FEE, TS, zfo), 0, "the frame promised through the dust");
        }
    }
}
