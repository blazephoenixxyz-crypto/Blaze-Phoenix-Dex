// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  ONE WALK, TWO QUESTIONS: THE FRAME ANSWERS WHAT IT WALKED, THE PROMISE PRICES THE REST.
//
//  `Core.v3PaysOnBudget` walks a concentrated book on a budget of reads. Where the reads cut
//  the walk, the PROMISE (`rest` true, the Solver) adds the input it did not walk, priced on
//  the last range it read: it defends against a state that moves and errs toward refusing.
//  The FRAME (`rest` false, `Core.legQuoteImpact`, the Router's in-frame quote) answers only
//  what the stretches it read pay. The frame is compared with a delivery from the SAME state
//  in the same transaction, and its walk takes the pool's own first stretches, so by
//  induction on (price, liquidity, input left) it is never above what the pool pays. Until
//  this fix the frame asked the promise's question: on a book that thins past the cut it
//  quoted above the pool and the protocol's floor refused a fill the market honours
//  (RouterE(5); 12 G7 rows on a BSC fork, 12839378017277891192820 quoted against
//  8057336833845326459693 paid).
//
//  The oracle is MockV3TickPool.specSwap, a second implementation of the swap (its own tick
//  prices, one compressed tick at a time), never the Core under test.
//
//  Red before the fix (the frame priced the rest): T1, T1b, T2, T2b, T3. T4 and T5 are guards,
//  green before too: their reds are mutants [wc-2] and [g3-3]. T10 (two hops settle) is green
//  before and under [wc-1] alike: its book does not thin past the cut. Mutants [wc-1]-[wc-5] in
//  .github/scripts/mutants.py.
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixQuoter} from "../src/BlazePhoenixQuoter.sol";
import {BlazePhoenixCore as BPC, Leg, RoutePlan} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV3TickPool} from "./mocks/MockV3TickPool.sol";

contract V3WalkFrameAnswersWhatItWalks is Test {
    uint24 constant FEE = 3000;

    // --- T1: a cut at a bitmap word ----------------------------------------------------------

    /// Spacing 1, the price at tick 0: a thick range [-10, 10) over a book that thins once more
    /// at -1100. Twelve reads take the walk to -1024 and the order goes past -1100, into a book
    /// that pays less than the last range read: the promise answers above the pool, the frame
    /// never does. The edge of the thick range is walked at -1, +0 and +1 wei of the input
    /// that reaches it.
    function test_AFrameQuoteCutAtABitmapWordIsAtMostWhatThePoolPays() public {
        MockV3TickPool pool = _pool(1);
        pool.addPosition(-887272, 887272, 1e16);
        pool.addPosition(-1100, 887272, 1e18);
        pool.addPosition(-10, 10, 1e21);
        (uint256 frame, uint256 promised, uint256 left, uint256 pays) = _both(pool, 1e18, BPC.V3_PAY_READS);
        assertEq(left, 0, "premise: the walk spends every read");
        assertGt(promised, pays, "premise: the promise prices a rest the thinning book does not pay");
        assertLe(frame, pays, "the frame quotes above what the pool pays");
        assertLt(frame, promised, "the frame priced the rest");

        (uint256 edge, , , , ) = pool.specSwap(type(uint128).max, true, pool.sqrtAt(-10));
        for (uint256 d; d < 3; ++d) {
            (frame, , , pays) = _both(pool, edge + d - 1, BPC.V3_PAY_READS);
            assertLe(frame, pays, "at the edge of the range the frame quotes above the pool");
        }
    }

    /// The Router's own call (`Core.legQuoteImpact`, the A_CONC_POOL arm) on the book of the
    /// test above (the thick range inside a book that thins at +-1100): the in-frame quote of a cut
    /// leg is at most what the pool pays.
    function test_TheRoutersInFrameQuoteOfACutLegIsAtMostWhatThePoolPays() public {
        MockV3TickPool pool = _pool(1);
        pool.addPosition(-887272, 887272, 1e16);
        pool.addPosition(-1100, 1100, 1e18);
        pool.addPosition(-10, 10, 1e21);
        Leg memory leg;
        leg.pool = address(pool);
        leg.kind = BPC.KIND_V3;
        leg.fee = FEE;
        leg.zeroForOne = true;
        leg.amountIn = 1e18;
        (uint256 q, , bool held) = BPC.legQuoteImpact(leg, address(0xA), address(0xB), 1e18);
        (, uint256 pays, , , ) = pool.specSwap(1e18, true, BPC.MIN_SQRT_PRICE_PLUS_ONE);
        assertTrue(held, "premise: the leg is live");
        assertGt(q, 0, "premise: the frame quotes the leg");
        assertLe(q, pays, "the Router's in-frame quote is above what the pool pays");
    }

    // --- T2: a cut at a crossing, and four positions of one wei ------------------------------

    /// Spacing 60, the price at tick 0: a thick range [-60, 60) and a range on every spacing
    /// below it. Twelve reads reach -180 with no read left for its crossing.
    function test_AFrameQuoteCutAtACrossingIsAtMostWhatThePoolPays() public {
        MockV3TickPool pool = _pool(60);
        pool.addPosition(-60, 60, 1e21);
        for (int24 k = -60; k < 0; ++k) pool.addPosition(k * 60, (k + 1) * 60, 1e19);
        (uint256 frame, uint256 promised, uint256 left, uint256 pays) = _both(pool, 3.5e18, BPC.V3_PAY_READS);
        assertEq(left, 0, "premise: the walk spends every read");
        assertLe(frame, pays, "a frame cut at a crossing quotes above what the pool pays");
        assertLt(frame, promised, "the frame priced the rest");
    }

    /// Anyone can open a position. Four of one wei on the price's path spend the reads on
    /// crossings that move nothing, so the walk is cut in the thick range, and the rest priced
    /// on it is more than the thin book past it pays. The frame still answers at most the pool.
    function test_FourPositionsOfOneWeiOnThePathLeaveTheFrameUnderThePool() public {
        MockV3TickPool pool = _pool(1);
        pool.addPosition(-887272, 887272, 1e18);
        pool.addPosition(-10, 10, 1e21);
        for (int24 k = 1; k <= 4; ++k) pool.addPosition(-2 * k, -2 * k + 1, 1);
        (uint256 frame, uint256 promised, uint256 left, uint256 pays) = _both(pool, 7e17, BPC.V3_PAY_READS);
        assertEq(left, 0, "premise: the walk spends every read");
        assertGt(promised, pays, "premise: the cut lands where the rest is overpriced");
        assertLe(frame, pays, "positions of one wei lift the frame above the pool");
    }

    // --- T3: the theorem, fuzzed -------------------------------------------------------------

    /// Random books (a whole-line range and up to four more, from one wei of liquidity),
    /// orders from one wei, 6 to 40 reads: the frame is never above what the pool pays, and
    /// never above the promise.
    function testFuzz_TheFrameQuoteNeverExceedsThePay(uint256 seed, uint256 amt, uint256 reads) public {
        MockV3TickPool pool = _pool(60);
        uint128 base = uint128(bound(uint256(keccak256(abi.encode(seed, "base"))), 1e15, 1e22));
        pool.addPosition(-887220, 887220, base);
        uint256 n = seed % 5;
        for (uint256 i; i < n; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            int24 lo = -int24(int256(r % 200)) * 60;
            int24 hi = lo + int24(int256(1 + (r >> 16) % 100)) * 60;
            pool.addPosition(lo, hi, uint128(bound(r >> 32, 1, 1e22)));
        }
        amt = bound(amt, 1, uint256(base) * 4);
        reads = bound(reads, 6, 40);
        (uint256 frame, uint256 promised, , uint256 pays) = _both(pool, amt, reads);
        assertLe(frame, pays, "the frame quotes above what the pool pays");
        assertLe(frame, promised, "the frame quotes above the promise");
    }

    // --- T4: the promise is unchanged --------------------------------------------------------

    /// A uniform dense book through the Solver: twelve reads do not finish it, and the plan's
    /// leg is promised what the pool pays (the walked part and the rest on the last range,
    /// which the uniform book pays alike). The frame on the same leg answers less: the promised
    /// did not become the frame.
    function test_ThePromiseOfAUniformDenseBookCutByTheReadsStaysWhatItPays() public {
        BlazePhoenixHub hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        BlazePhoenixSolver solver = new BlazePhoenixSolver(address(hub), address(0));
        BlazePhoenixRouter router = new BlazePhoenixRouter(address(hub), address(solver), address(this), address(0xFEE1), address(0xFEE2));
        BlazePhoenixQuoter quoter = new BlazePhoenixQuoter(address(hub), address(solver));
        hub.setRoles(address(router), address(solver), address(quoter));
        MockERC20 a = new MockERC20("AAA", "AAA");
        MockERC20 b = new MockERC20("BBB", "BBB");
        bool z = address(a) < address(b);
        MockV3TickPool pool = new MockV3TickPool(address(a), address(b), FEE, 60);
        pool.initialize(0);
        for (int24 k = -60; k < 60; ++k) pool.addPosition(k * 60, (k + 1) * 60, 1e20);
        a.mint(address(pool), 1e24);
        b.mint(address(pool), 1e24);
        hub.seedPool(address(pool), BPC.KIND_V3, FEE, address(0), address(a), address(b));

        Leg memory lg = solver.findBestRoutePlan(address(a), address(b), 5e18).best.hops[0].legs[0];
        assertEq(lg.pool, address(pool), "premise: the book is the leg");
        (uint256 used, uint256 pays, , int24 tickEnd, ) =
            pool.specSwap(lg.amountIn, z, z ? BPC.MIN_SQRT_PRICE_PLUS_ONE : BPC.MAX_SQRT_PRICE_MINUS_ONE);
        assertEq(used, lg.amountIn, "premise: the pool takes the whole leg");
        assertGt(z ? -tickEnd : tickEnd, 240, "premise: the order goes past where twelve reads cut the walk");
        uint256 f = BPC.outV3(lg.amountIn, pool.sqrtAt(0), pool.liquidity(), FEE, z, 0);
        (uint256 frame, ) = BPC.v3PaysOnBudget(address(pool), lg.amountIn, z, f, BPC.V3_PAY_READS, false);
        assertApproxEqRel(lg.expectedOut, pays, 1e12, "the promise of a uniform book is other than what it pays");
        assertLt(frame, lg.expectedOut, "premise: the reads cut the walk");
    }

    // --- T5: a book that thickens ------------------------------------------------------------

    /// A thin head and a thick book from -300: the promise is held at the band, the frame
    /// answers what the thin head pays, under both the band and the pool.
    function test_AFrameQuoteOnABookThatThickensStaysUnderTheBand() public {
        MockV3TickPool pool = _pool(1);
        pool.addPosition(-887272, 887272, 1e17);
        pool.addPosition(-200000, -300, 1e19);
        (uint160 sp0, , , , , , ) = pool.slot0();
        uint256 f = BPC.outV3(1e18, sp0, pool.liquidity(), FEE, true, 0);
        (uint256 frame, uint256 promised, uint256 left, uint256 pays) = _both(pool, 1e18, BPC.V3_PAY_READS);
        assertEq(left, 0, "premise: the walk spends every read");
        assertGt(pays, f, "premise: the book thickens past the head");
        assertEq(promised, f, "the promise rose above the band");
        assertLe(frame, f, "the frame rose above the band");
        assertLe(frame, pays, "the frame quotes above what the pool pays");
    }

    // --- T10: two hops, the cut leg in hop 0 and in the final hop ----------------------------

    /// A route of two cut books, A -> B -> C, through the Router: each hop's leg is a walk the
    /// reads cut, the frame quotes what it read, the protocol's floor on the final hop is made of
    /// it, and the route settles. A guard, green before the fix too: on a book that thins past
    /// the cut the Solver's promise, which prices the rest, refuses first (RouterE(5)), by design.
    function test_TwoHopsWithACutLegInEachSettleAtTheFrame() public {
        BlazePhoenixHub hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        BlazePhoenixSolver solver = new BlazePhoenixSolver(address(hub), address(0));
        BlazePhoenixRouter router = new BlazePhoenixRouter(address(hub), address(solver), address(this), address(0xFEE1), address(0xFEE2));
        BlazePhoenixQuoter quoter = new BlazePhoenixQuoter(address(hub), address(solver));
        hub.setRoles(address(router), address(solver), address(quoter));
        MockERC20 a = new MockERC20("AAA", "AAA");
        MockERC20 b = new MockERC20("BBB", "BBB");
        MockERC20 c = new MockERC20("CCC", "CCC");
        hub.addBridge(address(b));
        MockV3TickPool p0 = _thinning(hub, a, b);
        MockV3TickPool p1 = _thinning(hub, b, c);

        RoutePlan memory plan = solver.findBestRoutePlan(address(a), address(c), 7e17);
        assertEq(plan.best.hops.length, 2, "premise: two hops");
        assertEq(plan.best.hops[0].legs[0].pool, address(p0), "premise: hop 0 is the cut book");
        assertEq(plan.best.hops[1].legs[0].pool, address(p1), "premise: the final hop is the cut book");
        address user = address(0xBEEF);
        a.mint(user, 1e24);
        vm.startPrank(user);
        a.approve(address(router), type(uint256).max);
        uint256 b0 = c.balanceOf(user);
        router.swapExactIn(plan.best, 7e17, 1, user, block.timestamp + 1);
        vm.stopPrank();
        assertGt(c.balanceOf(user), b0, "the route did not settle");
    }

    // --- T9: the frame's gas, a walk cut by its reads and a walk that finishes ---------------

    /// The frame's walk on the T1 book, cut by the twelve reads, and the same walk on an order
    /// the thick range fills inside them. Snapshot group V3WalkFrameAnswersWhatItWalks; a frame
    /// that prices the rest again (mutant [wc-3]) moves the cut figure.
    function test_Gas_TheFrameCutByItsReadsAndTheFrameThatFinishes() public {
        MockV3TickPool pool = _pool(1);
        pool.addPosition(-887272, 887272, 1e16);
        pool.addPosition(-1100, 887272, 1e18);
        pool.addPosition(-10, 10, 1e21);
        (uint160 sp0, , , , , , ) = pool.slot0();
        uint256 f = BPC.outV3(1e18, sp0, pool.liquidity(), FEE, true, 0);
        (, uint256 left) = BPC.v3PaysOnBudget(address(pool), 1e18, true, f, BPC.V3_PAY_READS, false);
        vm.snapshotGasLastFrame("V3WalkFrameAnswersWhatItWalks", "Frame_CutByItsReads");
        assertEq(left, 0, "premise: the walk spends every read");
        f = BPC.outV3(1e15, sp0, pool.liquidity(), FEE, true, 0);
        (, left) = BPC.v3PaysOnBudget(address(pool), 1e15, true, f, BPC.V3_PAY_READS, false);
        vm.snapshotGasLastFrame("V3WalkFrameAnswersWhatItWalks", "Frame_Finishes");
        assertGt(left, 0, "premise: the walk finishes inside its reads");
    }

    // --- helpers -----------------------------------------------------------------------------

    /// A thick range over a full-range book, cut by the reads, between `x` and `y`, the price at tick 0 and the order moving it
    /// down or up as the pair's order says; seeded in the Hub as a V3 leg.
    function _thinning(BlazePhoenixHub hub, MockERC20 x, MockERC20 y) internal returns (MockV3TickPool p) {
        p = new MockV3TickPool(address(x), address(y), FEE, 1);
        p.initialize(0);
        p.addPosition(-887272, 887272, 1e18);
        p.addPosition(-10, 10, 1e21);
        x.mint(address(p), 1e24);
        y.mint(address(p), 1e24);
        hub.seedPool(address(p), BPC.KIND_V3, FEE, address(0), address(x), address(y));
    }

    function _pool(int24 ts) internal returns (MockV3TickPool pool) {
        pool = new MockV3TickPool(address(0xA), address(0xB), FEE, ts);
        pool.initialize(0);
    }

    /// The frame and the promise of one walk on `reads` reads (zeroForOne), against `f`, the
    /// single-range figure, and what the pool pays for the whole order.
    function _both(MockV3TickPool pool, uint256 amt, uint256 reads)
        internal view returns (uint256 frame, uint256 promised, uint256 left, uint256 pays)
    {
        (uint160 sp0, , , , , , ) = pool.slot0();
        uint256 f = BPC.outV3(amt, sp0, pool.liquidity(), FEE, true, 0);
        (frame, left) = BPC.v3PaysOnBudget(address(pool), amt, true, f, reads, false);
        (promised, ) = BPC.v3PaysOnBudget(address(pool), amt, true, f, reads, true);
        (, pays, , , ) = pool.specSwap(amt, true, BPC.MIN_SQRT_PRICE_PLUS_ONE);
    }
}
