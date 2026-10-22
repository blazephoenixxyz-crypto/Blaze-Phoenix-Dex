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
//  sites (single leg and split) at the committed input.
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

    function test_3073_Solver_SingleLeg_BookEmptiesBelowTheCap_PromiseIsTheCap() public {
        MockV3BookPool p = _seed(HELD);
        p.setTick(-600, int128(L));            // crossing down removes all liquidity
        assertLt(_walk(address(p), IN, true), _cap(HELD), "precondition: the walk ends under the cap");
        assertEq(_single(p), _cap(HELD), "lower bound: the old promise");
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

    function test_3073_Solver_SingleLeg_UnreadableBook_PromiseIsTheCap() public {
        MockV3Pool p = new MockV3Pool(address(tokenA), address(tokenB), FEE);
        p.setState(SP, L);
        MockERC20(_tOut()).mint(address(p), HELD);
        hub.seedPool(address(p), BPC.KIND_V3, FEE, address(0), address(tokenA), address(tokenB));
        RoutePlan memory plan = solver.findBestRoutePlan(_tIn(), _tOut(), IN);
        assertEq(plan.best.hops[0].legs[0].amountIn, IN, "the whole input commits");
        assertEq(plan.best.hops[0].legs[0].expectedOut, _cap(HELD), "no book: the old promise");
    }

    /// The cap does not bind (F <= cap): the promise is the quote, and the book is not asked.
    function test_3073_Solver_SingleLeg_UnderTheCap_PromiseIsTheQuote() public {
        uint256 held = 1_000e18;               // cap 300e18 > F (~166e18)
        MockV3BookPool p = _seed(held);
        p.setTick(-600, int128(L));            // a book that empties: its walk sits under the quote
        RoutePlan memory plan = solver.findBestRoutePlan(_tIn(), _tOut(), IN);
        Leg memory leg = plan.best.hops[0].legs[0];
        assertEq(leg.pool, address(p), "the booked pool");
        assertLe(_f(IN), _cap(held), "precondition: the cap does not bind");
        assertLt(_walk(address(p), IN, true), _f(IN), "precondition: the walk is below the quote");
        assertEq(leg.expectedOut, _f(IN), "an unbound leg keeps its quote");
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
}
