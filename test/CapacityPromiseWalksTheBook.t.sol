// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  3073 (M2000 Slash; 3212, 3230). A concentrated leg the capacity cap binds
//  (cap < F <= holdings, MAX_CONC_DRAIN_BPS) keeps its whole input, and its
//  promise is the pool's own book, walked read-only, held between the old
//  promise and the single-tick quote:
//
//      P = min(max(W, cap), F)        (Solver._capacity)
//
//  W = the walk of the pool's initialized ticks (Core.v4WalkOut, V3 mode), F = the
//  single-tick quote the Solver already computed. Pinned here: each bound on
//  its own (a book that empties below the cap, one that deepens past F, one in
//  between, a flat one), the unreadable book (the old promise), and both Solver
//  sites (single leg and split) at the committed input. A single leg's P is then
//  re-asked in frame (`_paysWhatItWalks`, DEX-01), which only lowers it: since G3
//  (ac580b5) a book that empties under P is promised what it pays, cap or not.
//
//  forge test --match-path test/CapacityPromiseWalksTheBook.t.sol -vv
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixCore as BPC, RoutePlan, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV3Pool} from "./mocks/MockV3Pool.sol";
import {MockV3BookPool} from "./mocks/MockV3BookPool.sol";

contract CapacityPromiseWalksTheBookTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    MockERC20 tokenA;
    MockERC20 tokenB;

    uint160 constant SP   = uint160(1 << 96);   // price 1, tick 0
    uint128 constant L    = 1_000e18;           // virtual reserves 1,000 a side
    uint24  constant FEE  = 3_000;
    int24   constant TS   = 60;
    uint256 constant IN   = 200e18;             // moves the price to ~0.69: one bitmap word at TS 60
    uint256 constant HELD = 400e18;             // cap = 120e18 < F (~166e18) <= HELD

    // Oracles derived by hand, not by the walk or the Solver under test (Uniswap V3 TickMath and
    // SqrtPriceMath in exact integers; the real-number figures beside them).
    // F_IN: the single-tick quote of IN. At price 1 one range is the constant product on virtual
    // reserves (L, L): L * a / (L + a), a = IN less the 30 bps fee = 199.4e18. Real: 166.2497915...e18.
    uint256 constant F_IN = 166249791562447890611;
    // PAYS_600: a book that empties at tick -600 pays the stretch from price 1 down to it at L and
    // nothing past it: L * (Q96 - sqrtAt(-600)) / Q96, sqrtAt(-600) = 76886731765546235930195592750.
    // Real: L * (1 - 1.0001^-300) = 29553010879137169680.83. Reaching -600 spends 30.54e18 of IN.
    uint256 constant PAYS_600 = 29553010879137169680;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        solver = new BlazePhoenixSolver(address(hub), address(0));
        tokenA = new MockERC20("A", "A");
        tokenB = new MockERC20("B", "B");
    }

    function _book() internal returns (MockV3BookPool p) {
        p = new MockV3BookPool(address(tokenA), address(tokenB), FEE, TS);
        p.setState(SP, L);
    }

    function _f(uint256 amt) internal pure returns (uint256) {
        return BPC.outV3(amt, SP, L, FEE, true, 0);
    }

    function _cap(uint256 held) internal pure returns (uint256) {
        return BPC.mulDiv(held, 3_000, BPC.BPS);
    }

    function _walk(address p, uint256 amt, bool zfo) internal view returns (uint256) {
        return BPC.v4WalkOut(p, bytes32(0), amt, 0, 0, zfo);
    }

    // ─── Core: the V3 walk (v4WalkOut with a zero poolId) ───────────────

    function test_3073_V3Walk_FlatBook_IsTheSingleTickFigure() public {
        MockV3BookPool p = _book();
        uint256 f = _f(IN);
        uint256 w = _walk(address(p), IN, true);
        assertLe(w, f, "the walk never exceeds the single-tick figure on a flat book");
        assertLe(f - w, f / 1e9, "a flat book walks to the single-tick figure");
        uint256 f1 = BPC.outV3(IN, SP, L, FEE, false, 0);
        uint256 w1 = _walk(address(p), IN, false);
        assertLe(w1, f1, "rising price: never above the single-tick figure");
        assertLe(f1 - w1, f1 / 1e9, "rising price: a flat book walks to the single-tick figure");
    }

    function test_3073_V3Walk_AsksThePoolForFeeAndSpacing() public {
        MockV3BookPool p = _book();
        p.setTick(-600, int128(700e18));
        uint256 w = _walk(address(p), IN, true);
        assertGt(w, 0, "precondition: the book answers");
        assertEq(BPC.v4WalkOut(address(p), bytes32(0), IN, 999_999, 1, true), w, "the caller's fee and spacing are not asked");
    }

    /// A pool whose slot0 tick disagrees with its price (tick 0 reported, price ~0.81):
    /// the walk's first target lies above the price on a falling swap. It stops there
    /// rather than stepping the wrong way.
    function test_3073_V3Walk_TickAbovePrice_Stops() public {
        MockV3BookPool p = _book();
        p.setState(SP * 9 / 10, L);
        assertEq(_walk(address(p), IN, true), 0, "an inconsistent book walks nothing");
    }

    function test_3073_V3Walk_UnreadableBook_IsZero() public {
        MockV3Pool p = new MockV3Pool(address(tokenA), address(tokenB), FEE);   // no tickSpacing()
        p.setState(SP, L);
        assertEq(_walk(address(p), IN, true), 0, "no book: nothing walked");
    }

    // ─── Solver: both sites at the committed input ──────────────────────

    function _seed(uint256 held) internal returns (MockV3BookPool p) {
        p = _book();
        MockERC20(_tOut()).mint(address(p), held);
        hub.seedPool(address(p), BPC.KIND_V3, FEE, address(0), address(tokenA), address(tokenB));
    }

    // token0 in, token1 out: zeroForOne, the direction every figure above is computed in.
    function _tIn() internal view returns (address) {
        return address(tokenA) < address(tokenB) ? address(tokenA) : address(tokenB);
    }

    function _tOut() internal view returns (address) {
        return address(tokenA) < address(tokenB) ? address(tokenB) : address(tokenA);
    }

    function _single(MockV3BookPool p) internal view returns (uint256 promised) {
        RoutePlan memory plan = solver.findBestRoutePlan(_tIn(), _tOut(), IN);
        Leg memory leg = plan.best.hops[0].legs[0];
        assertEq(plan.best.hops[0].legs.length, 1, "precondition: one leg");
        assertEq(leg.pool, address(p), "the booked pool");
        assertEq(leg.amountIn, IN, "aggressive but possible: the whole input commits");
        assertGt(_f(IN), _cap(HELD), "precondition: the cap binds");
        return leg.expectedOut;
    }

    function test_3073_Solver_SingleLeg_FlatBook_PromiseIsTheWalk() public {
        MockV3BookPool p = _seed(HELD);
        uint256 got = _single(p);
        assertEq(got, _walk(address(p), IN, true), "the book's answer");
        assertGt(got, _cap(HELD), "above the old promise");
    }

    /// The book empties at its first crossing, so the pool pays the stretch down to it and nothing
    /// past it. `_capacity` still hands the cap up as the leg's promise, but the in-frame check
    /// (`_paysWhatItWalks`, DEX-01) re-asks the book and a promise only falls: since G3 (ac580b5)
    /// a walk that runs out of reads on the empty range beyond the crossing is priced at what it
    /// crossed plus nothing, not at the band, so the promise is what the book pays, under the cap.
    /// The oracle is PAYS_600, by hand: the walk reads the same book the Solver does, so a walk
    /// that misreads a crossing (mutants.py [706]) would agree with itself.
    function test_3073_Solver_SingleLeg_BookEmptiesBelowTheCap_PromiseIsWhatTheBookPays() public {
        MockV3BookPool p = _seed(HELD);
        p.setTick(-600, int128(L));            // crossing down removes all liquidity
        assertLt(PAYS_600, _cap(HELD), "precondition: the book pays under the cap");
        assertEq(_single(p), PAYS_600, "the book's answer by hand: the stretch to -600, nothing past it");
        assertEq(_walk(address(p), IN, true), PAYS_600, "and the walk reads that book");
    }

    /// [706] family: the book empties at any crossing the order reaches (-3600 .. -60; reaching
    /// -3600 spends 197.8e18 of IN), and the pool holds anything from the quote up, so the cap
    /// binds or not. Either way the promise is the stretch down to the crossing, by hand from the
    /// tick's price: L * (Q96 - sqrtAt(t)) / Q96 (`sqrtPriceAtTick`, certified by
    /// test/TickMathCertificate.t.sol), never the walk under test.
    function testFuzz_3073_Solver_SingleLeg_BookEmptiesAtAnyCrossing_PromiseIsTheStretchToIt(uint256 k, uint256 held)
        public
    {
        int24 t = -int24(int256(bound(k, 1, 60))) * TS;
        held = bound(held, F_IN, 1e30);
        MockV3BookPool p = _seed(held);
        p.setTick(t, int128(L));               // crossing down removes all liquidity
        uint256 s = BPC.sqrtPriceAtTick(t);
        uint256 pays = BPC.mulDiv(L, SP - s, BPC.Q96);
        uint256 reach = BPC.mulDivUp(L, SP - s, s);   // token0 that moves price 1 to the crossing
        assertLt(reach + BPC.mulDivUp(reach, FEE, 1_000_000 - FEE), IN, "precondition: the order reaches the crossing");
        assertLt(pays, F_IN, "precondition: the book pays under the quote");
        RoutePlan memory plan = solver.findBestRoutePlan(_tIn(), _tOut(), IN);
        Leg memory leg = plan.best.hops[0].legs[0];
        assertEq(leg.pool, address(p), "the booked pool");
        assertEq(leg.amountIn, IN, "the whole input commits");
        assertEq(leg.expectedOut, pays, "the promise is the stretch to the crossing, nothing past it");
    }

    function test_3073_Solver_SingleLeg_BookDeepensPastF_PromiseIsTheQuote() public {
        MockV3BookPool p = _seed(HELD);
        p.setTick(-600, -int128(9_000e18));    // crossing down adds 9,000e18
        assertGt(_walk(address(p), IN, true), _f(IN), "precondition: the walk passes the single-tick quote");
        assertEq(_single(p), _f(IN), "upper bound: the single-tick quote");
    }

    function test_3073_Solver_SingleLeg_BookThinsBetween_PromiseIsTheWalk() public {
        MockV3BookPool p = _seed(HELD);
        p.setTick(-600, int128(700e18));       // crossing down leaves 300e18
        uint256 got = _single(p);
        assertEq(got, _walk(address(p), IN, true), "the book's answer");
        assertGt(got, _cap(HELD), "between the bounds: above the cap");
        assertLt(got, _f(IN), "between the bounds: below the single-tick quote");
    }

    /// The book thins on the other side of the price: its only crossing lies above it, where
    /// a rising swap lands. The leg sells token0 (falling price), so its own walk never reaches
    /// that tick and pays the flat figure, and that is its promise. Walked the wrong way the
    /// book crosses the tick and pays less, and a promise handed down lower stays lower: the
    /// in-frame check (`_paysWhatItWalks`) only lowers a promise, it never lifts one back to
    /// the leg's own walk.
    function test_3073_Solver_SingleLeg_BookThinsAboveThePrice_PromiseIsTheLegsOwnWalk() public {
        MockV3BookPool p = _seed(HELD);
        p.setTick(600, -int128(700e18));       // crossing up leaves 300e18; a falling swap never crosses it
        uint256 own = _walk(address(p), IN, true);
        uint256 wrong = _walk(address(p), IN, false);
        emit log_named_uint("own walk", own);
        emit log_named_uint("wrong-way walk", wrong);
        assertGt(wrong, _cap(HELD), "precondition: the wrong-way walk still clears the cap");
        assertLt(wrong, own, "precondition: the wrong-way walk pays less than the leg's own");
        uint256 got = _single(p);
        emit log_named_uint("promised", got);
        assertEq(got, own, "the book's answer in the leg's own direction");
        assertLe(_f(IN) - got, _f(IN) / 1e9, "flat on the leg's side: the walk is the single-tick quote");
    }

    function test_3073_Solver_SingleLeg_UnreadableBook_PromiseIsTheCap() public {
        MockV3Pool p = new MockV3Pool(address(tokenA), address(tokenB), FEE);
        p.setState(SP, L);
        MockERC20(_tOut()).mint(address(p), HELD);
        hub.seedPool(address(p), BPC.KIND_V3, FEE, address(0), address(tokenA), address(tokenB));
        RoutePlan memory plan = solver.findBestRoutePlan(_tIn(), _tOut(), IN);
        assertEq(plan.best.hops[0].legs[0].amountIn, IN, "the whole input commits");
        assertEq(plan.best.hops[0].legs[0].expectedOut, _cap(HELD), "no book: the old promise");
    }

    /// The same unreadable book beside a booked one (held 250e18 each: cap 75e18 per leg). At
    /// the cap the two split (150e18); walked, the booked book alone pays more. The book that
    /// does not answer is refused on its own, before the walk steps, so the rebuild completes
    /// and the booked book is promised its walk - never a failed rebuild that drops it back to
    /// the cap. Whatever the shape: a leg on the unreadable book keeps its cap, a leg on the
    /// booked one is promised its walk, and the hop beats the plan at the cap.
    function test_3073_Solver_Split_UnreadableBookBesideABook_OnlyItKeepsTheCap() public {
        uint256 held = 250e18;
        uint256 c = _cap(held);
        MockV3Pool u = new MockV3Pool(address(tokenA), address(tokenB), FEE);   // no tickSpacing()
        u.setState(SP, L);
        MockERC20(_tOut()).mint(address(u), held);
        hub.seedPool(address(u), BPC.KIND_V3, FEE, address(0), address(tokenA), address(tokenB));
        MockV3BookPool b = _seed(held);
        RoutePlan memory plan = solver.findBestRoutePlan(_tIn(), _tOut(), IN);
        Leg[] memory legs = plan.best.hops[0].legs;
        uint256 booked;
        uint256 sum;
        for (uint256 i; i < legs.length; ++i) {
            assertGt(BPC.outV3(legs[i].amountIn, SP, L, FEE, true, 0), c, "precondition: the cap binds the leg");
            sum += legs[i].expectedOut;
            if (legs[i].pool == address(u)) {
                assertEq(legs[i].expectedOut, c, "no book: the old promise");
            } else {
                assertEq(legs[i].pool, address(b), "precondition: the booked pool");
                uint256 w = _walk(address(b), legs[i].amountIn, true);
                assertGt(w, c, "precondition: the book pays past the cap");
                assertEq(legs[i].expectedOut, w, "the booked leg is promised its book's answer");
                ++booked;
            }
        }
        assertGt(booked, 0, "the booked book carries the order");
        assertGt(sum, 2 * c, "and the hop beats the plan at the cap");
    }

    /// The cap does not bind (F <= cap): `_capacity` hands the quote up without walking the book.
    /// The in-frame check (`_paysWhatItWalks`, DEX-01) then asks the book what it pays, and on a
    /// book that empties under the quote the promise falls to that walk (G3, ac580b5). Read
    /// without `_single`, whose precondition is that the cap binds.
    function test_3073_Solver_SingleLeg_UnderTheCap_PromiseIsWhatTheBookPays() public {
        uint256 held = 1_000e18;               // cap 300e18 > F (~166e18)
        MockV3BookPool p = _seed(held);
        p.setTick(-600, int128(L));            // a book that empties: its walk sits under the quote
        RoutePlan memory plan = solver.findBestRoutePlan(_tIn(), _tOut(), IN);
        Leg memory leg = plan.best.hops[0].legs[0];
        assertEq(leg.pool, address(p), "the booked pool");
        assertEq(leg.amountIn, IN, "the whole input commits");
        assertLe(F_IN, _cap(held), "precondition: the cap does not bind");
        assertEq(leg.expectedOut, PAYS_600, "an unbound leg is promised what its book pays (by hand)");
    }

    /// The cap does not bind and the book DEEPENS at its nearest crossing: walked, it pays more
    /// than the single-tick quote, and an unbound leg is still promised the quote, never more
    /// (P <= F). The cap (300e18) sits above anything IN can be paid at price 1 or below, so a
    /// leg walked anyway would be lifted to it and the in-frame check would lower it only to its
    /// walk, above F (mutants.py [703]). F_IN is the hand figure, not the Solver's quote.
    function test_3073_Solver_SingleLeg_UnderTheCap_BookDeepensPastF_PromiseIsTheQuote() public {
        uint256 held = 1_000e18;               // cap 300e18 >= IN
        MockV3BookPool p = _seed(held);
        p.setTick(-60, -int128(9_000e18));     // crossing down adds 9,000e18
        assertGe(_cap(held), IN, "precondition: no output of IN reaches the cap");
        RoutePlan memory plan = solver.findBestRoutePlan(_tIn(), _tOut(), IN);
        Leg memory leg = plan.best.hops[0].legs[0];
        assertEq(leg.pool, address(p), "the booked pool");
        assertEq(leg.amountIn, IN, "the whole input commits");
        assertEq(leg.expectedOut, F_IN, "an unbound leg is promised the single-tick quote, by hand");
        assertEq(_f(IN), F_IN, "the Core's single tick is the hand figure");
        assertGt(_walk(address(p), IN, true), F_IN, "and its book would pay more: the figure an unbound leg is never promised");
    }

    /// [703] family: any crossing the order reaches (-3600 .. -60) adds anything from 1e18 to
    /// 1e27, and the pool holds anything from IN * 10/3 up (the cap at or above IN). The promise
    /// is F_IN on every one of them, by hand; walked, every such book pays more.
    function testFuzz_3073_Solver_SingleLeg_UnderTheCap_BookDeepens_PromiseIsTheQuote(uint256 k, uint256 add, uint256 held)
        public
    {
        int24 t = -int24(int256(bound(k, 1, 60))) * TS;
        add = bound(add, 1e18, 1e27);
        held = bound(held, 667e18, 1e30);
        MockV3BookPool p = _seed(held);
        p.setTick(t, -int128(int256(add)));    // crossing down adds `add`
        assertGe(_cap(held), IN, "precondition: no output of IN reaches the cap");
        RoutePlan memory plan = solver.findBestRoutePlan(_tIn(), _tOut(), IN);
        Leg memory leg = plan.best.hops[0].legs[0];
        assertEq(leg.pool, address(p), "the booked pool");
        assertEq(leg.amountIn, IN, "the whole input commits");
        assertEq(leg.expectedOut, F_IN, "an unbound leg is promised the single-tick quote, by hand");
        assertGt(_walk(address(p), IN, true), F_IN, "and its book would pay more");
    }

    function test_3073_Solver_Split_EveryLegAsksTheBook() public {
        uint256 held = 250e18;                 // per pool: cap 75e18 < F(100e18) ~ 90.6e18 <= 250e18
        _seed(held);
        _seed(held);
        RoutePlan memory plan = solver.findBestRoutePlan(_tIn(), _tOut(), IN);
        Leg[] memory legs = plan.best.hops[0].legs;
        assertEq(legs.length, 2, "precondition: the split survives");
        for (uint256 i; i < legs.length; ++i) {
            uint256 c = _cap(held);
            assertGt(BPC.outV3(legs[i].amountIn, SP, L, FEE, true, 0), c, "precondition: the cap binds the leg");
            assertGt(legs[i].expectedOut, c, "the leg's promise is lifted off the cap");
            assertEq(
                legs[i].expectedOut,
                _walk(legs[i].pool, legs[i].amountIn, true),
                "the leg's promise is the book's answer at its committed input"
            );
        }
    }

    /// Two held books split the order. `a` empties at its first crossing, so at its share its
    /// book pays less than its cap; `b` holds 150e18, so the whole order is past its holdings
    /// and only its share is held. The split is built on the books: `a` keeps the cap as its
    /// lower bound and `b` is promised what its book pays.
    function test_3073_Solver_Split_BookEmptiesBelowTheCap_BesideAWalkedLeg() public {
        MockV3BookPool a = _seed(250e18);
        a.setTick(-600, int128(L));            // crossing down removes all liquidity
        _seed(150e18);
        RoutePlan memory plan = solver.findBestRoutePlan(_tIn(), _tOut(), IN);
        Leg[] memory legs = plan.best.hops[0].legs;
        assertEq(legs.length, 2, "precondition: the split survives");
        for (uint256 i; i < legs.length; ++i) {
            bool isA = legs[i].pool == address(a);
            uint256 c = _cap(isA ? 250e18 : 150e18);
            uint256 w = _walk(legs[i].pool, legs[i].amountIn, true);
            emit log_named_uint("leg in", legs[i].amountIn);
            emit log_named_uint("  walk", w);
            emit log_named_uint("  promised", legs[i].expectedOut);
            if (isA) {
                assertLt(w, c, "precondition: a's book pays under its cap at its share");
                assertEq(legs[i].expectedOut, c, "lower bound: the cap");
            } else {
                assertGt(w, c, "precondition: b's book pays past its cap at its share");
                assertEq(legs[i].expectedOut, w, "b is promised its book's answer");
            }
        }
    }
}
