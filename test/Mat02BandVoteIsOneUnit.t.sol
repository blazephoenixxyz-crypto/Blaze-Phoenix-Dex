// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// MAT-02 (audit 2026-11-06, maths): the band's median adds one token.
//
// WHAT WAS WRONG. `BlazePhoenixMath._wMedian` walks the live rows by price, ascending, to half of
// the summed votes, and the premise written above `_depthWeightedMedian` is that the votes are
// counts of one token. They were counts of two:
//   - a pair voted its short side (`Core.shortSide18`): the smaller of two normalised counts,
//     which away from price 1 is the count of the dear token;
//   - a pair-shaped or concentrated vote was then capped by what the row holds of tokenOut
//     (`Solver._buildHop`, PROV-01): a count of the bought token.
// An honest pair at 3,000 B per A holding 1,000 A + 3,000,000 B voted 1,000e18, a count of A.
// A V3 book at 1 B per A, born at a listed factory and holding only B, voted what it holds of B.
// It comes first by price, so it was the base iff its count C of B reached the honest pool's
// count of A (derived: C >= (C + 1e21 + 1) / 2 <=> C >= 1e21). 1,000 B, worth 1/3,000 of the
// honest short side, took the base; the band then dropped the honest pool (price ratio 3,000)
// and the order was planned, and paid, at the book's price.
//
// THE PROPERTY WITHOUT A NUMBER (one band, one unit): the plan cannot depend on the unit of account.
// Restating B as B' = 1,000 B - every B balance and every B price divided by 1,000 - must route the
// same legs and divide the output by 1,000.
//
// WHAT IS MEASURED NOW. Every row votes the tokenOut it can pay: the sixth return of
// `Core._quoteArms`, handed to the vote by `Core.universalProbe` and capped by the tokenOut the
// row holds. The honest pair votes its 3,000,000 B. Controls: the two fixture halves restate
// faithfully, and one wei under the old boundary the honest pool keeps the base.

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixQuoter} from "../src/BlazePhoenixQuoter.sol";
import {BlazePhoenixCore as BPC, Leg, RoutePlan} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";
import {Origin} from "./mocks/MockOriginFactory.sol";
import {PhantomBook} from "./ConcentratedMassCap.t.sol";

contract Mat02BandVoteIsOneUnitTest is Test {
    struct World {
        BlazePhoenixHub    hub;
        BlazePhoenixSolver solver;
        BlazePhoenixRouter router;
        MockERC20   a;        // token0 in every world: the dear unit, the one sold
        MockERC20   b;        // token1: the cheap unit, the one bought
        MockV2Pair  honest;
        PhantomBook book;
    }

    struct Plan {
        uint256 total;
        uint256 legs;
        bool    honest;
        bool    book;
    }

    address constant USER     = address(0xBEEF);
    address constant ATTACKER = address(0xBAD);
    uint256 constant Q96      = uint256(1) << 96;
    uint256 constant HONEST_A = 1_000e18;          // the honest short side: its vote, a count of A
    uint256 constant HONEST_B = 3_000_000e18;      // fair price 3,000 B per A
    uint256 constant ORDER    = 1e18;              // the user sells 1 A
    // The book: one spacing (60, fee 3000) at 1 B per A. Such a range carries
    // L ~= C / (sqrt(1.0001^60) - 1) ~= C / 3.0e-3 of B, so L = 8.3e23 is what ~2,500 B hold.
    // Its virtual depth (8.3e23) is above every holding used here, so the PROV-01 cap makes its
    // vote exactly the B it holds.
    uint256 constant BOOK_L   = 8.3e23;
    uint256 constant B_PRIME  = 1_000;             // B' = 1,000 B

    /// @dev One world, B counted in units of `unit` B. A fresh Hub, Solver and Router, so the
    ///      two worlds of a restatement share nothing but the test's clock.
    function _world(uint256 unit, uint256 heldB, bool withHonest) internal returns (World memory w) {
        w.hub = new BlazePhoenixHub(address(this));
        w.hub.initialize(address(this), address(0));
        w.solver = new BlazePhoenixSolver(address(w.hub), address(0));
        w.router = new BlazePhoenixRouter(
            address(w.hub), address(w.solver), address(this), address(0xFEE1), address(0xFEE2));
        w.hub.setRoles(address(w.router), address(w.solver), address(this));

        MockERC20 t1 = new MockERC20("A", "A");
        MockERC20 t2 = new MockERC20("B", "B");
        (w.a, w.b) = address(t1) < address(t2) ? (t1, t2) : (t2, t1);

        if (withHonest) {
            w.honest = new MockV2Pair(address(w.a), address(w.b));
            w.a.mint(address(w.honest), HONEST_A);
            w.b.mint(address(w.honest), HONEST_B / unit);
            w.honest.setReserves(uint112(HONEST_A), uint112(HONEST_B / unit));
            w.hub.seedPool(address(w.honest), BPC.KIND_V2, 30, address(0), address(w.a), address(w.b));
        }

        vm.prank(ATTACKER);
        w.book = new PhantomBook(address(w.a), address(w.b), 3000);
        // Born at a factory the Hub lists (a permissionless createPool at a listed tier). One
        // seeded row is under MIN_FRESH_VENUES, so the solve sweeps and lists it.
        Origin.wire(w.hub, address(w.book), address(w.a), address(w.b), BPC.KIND_V3, 3000);
        // token1 per token0 = 1 / unit: sqrtP = Q96 / sqrt(unit), L = BOOK_L / sqrt(unit).
        w.book.setState(uint160(_sqrt(Q96 * Q96 / unit)), uint128(_sqrt(BOOK_L * BOOK_L / unit)));
        w.book.setKeepInput(true);   // a pool keeps what it is paid; its LP withdraws it
        w.book.setPayBps(9_970);     // its own curve at 1 B per A, fee 0.3 %: swapped at unit 1 only
        w.b.mint(address(w.book), heldB / unit);
    }

    /// @dev The plan reads slot0 and liquidity of the book, never its swap.
    function _plan(World memory w) internal view returns (Plan memory p) {
        RoutePlan memory plan = w.solver.findBestRoutePlan(address(w.a), address(w.b), ORDER);
        p.total = plan.best.totalOut;
        if (plan.best.hops.length == 0) return p;
        Leg[] memory legs = plan.best.hops[0].legs;
        p.legs = legs.length;
        for (uint256 i; i < legs.length; ++i) {
            if (legs[i].pool == address(w.honest) && address(w.honest) != address(0)) p.honest = true;
            if (legs[i].pool == address(w.book)) p.book = true;
        }
    }

    /// @dev What the honest pool delivers for `order` A, in B / unit: constant product with its
    ///      30 bps fee, after the protocol's 28 bps on the input (Core.PROTOCOL_FEE_BPS).
    function _honestOut(uint256 order, uint256 unit) internal pure returns (uint256) {
        uint256 x = order - (order * 28 + 9_999) / 10_000;
        uint256 rb = HONEST_B / unit;
        return (x * 997 * rb) / (HONEST_A * 1000 + x * 997);
    }

    function _sqrt(uint256 x) internal pure returns (uint256 z) {
        if (x == 0) return 0;
        z = x;
        uint256 y = x / 2 + 1;
        while (y < z) { z = y; y = (x / y + y) / 2; }
    }

    function _log(string memory tag, Plan memory p, uint256 unit) internal {
        emit log_named_uint(string.concat(tag, " legs"), p.legs);
        emit log_named_uint(string.concat(tag, " honest routed (1=yes)"), p.honest ? 1 : 0);
        emit log_named_uint(string.concat(tag, " book routed (1=yes)"), p.book ? 1 : 0);
        emit log_named_uint(string.concat(tag, " totalOut x unit"), p.total * unit);
    }

    /// @dev The restatement relation: the same legs, the output divided by the unit.
    function _assertRestated(Plan memory p, Plan memory q, uint256 unit) internal {
        _log("B :", p, 1);
        _log("B':", q, unit);
        assertEq(q.honest, p.honest, "MAT-02: restating B moved the honest pool into or out of the plan");
        assertEq(q.book, p.book, "MAT-02: restating B moved the book into or out of the plan");
        assertEq(q.legs, p.legs, "MAT-02: restating B changed the number of legs");
        assertApproxEqRel(q.total * unit, p.total, 1e12, "MAT-02: restating B did not divide the output by the unit");
    }

    // ---------------------------------------------------------------- the property, no number

    /// Red before the fix. The book holds 2,500 B: in B it outvoted the honest 1,000e18 (a count of
    /// A), in B' it holds 2.5 B' and did not.
    function test_MAT02_RestatingTheOutputTokenInABiggerUnitLeavesThePlanAsItWas() public {
        _assertRestated(_plan(_world(1, 2_500e18, true)), _plan(_world(B_PRIME, 2_500e18, true)), B_PRIME);
    }

    /// Red before the fix. Over the book's holdings up to its virtual depth, with the honest pool
    /// holding more of tokenOut than the book in every case.
    /// forge-config: default.fuzz.runs = 32
    function testFuzz_MAT02_ThePlanDoesNotDependOnTheUnitOfTheOutputToken(uint256 heldB) public {
        heldB = bound(heldB, 1e18, 8e23);
        _assertRestated(_plan(_world(1, heldB, true)), _plan(_world(B_PRIME, heldB, true)), B_PRIME);
    }

    /// Control: the honest half of the fixture restates faithfully (the book holds 500 B,
    /// under the boundary in both units, and stays out of the plan in both).
    function test_MAT02_control_RestatingWithTheBookUnderTheBoundaryLeavesThePlanAsItWas() public {
        _assertRestated(_plan(_world(1, 500e18, true)), _plan(_world(B_PRIME, 500e18, true)), B_PRIME);
    }

    /// Control: the book half of the fixture restates faithfully (the book alone on its pair).
    function test_MAT02_control_RestatingTheBookAloneLeavesItsPlanAsItWas() public {
        _assertRestated(_plan(_world(1, 2_500e18, false)), _plan(_world(B_PRIME, 2_500e18, false)), B_PRIME);
    }

    // ---------------------------------------------------------------- the boundary, in numbers

    /// Red before the fix. C = 1,000e18 B, the honest pool's count of A: worth 1/3,000 of its short side.
    function test_MAT02_ABookHoldingTheHonestShortSideCountOfTheCheapTokenDoesNotTakeTheBase() public {
        Plan memory p = _plan(_world(1, HONEST_A, true));
        _log("C = 1,000e18 B:", p, 1);
        emit log_named_uint("honestOut(1 A)", _honestOut(ORDER, 1));
        assertTrue(p.honest, "MAT-02: 1,000 B took the base from 1,000 A + 3,000,000 B");
        assertGe(p.total, _honestOut(ORDER, 1) * 99 / 100, "MAT-02: the plan quotes the book's price");
    }

    /// Control: one wei under that count the honest pool keeps the base.
    function test_MAT02_control_OneWeiUnderThatCountTheHonestPoolKeepsTheBase() public {
        Plan memory p = _plan(_world(1, HONEST_A - 1, true));
        _log("C = 1,000e18 B - 1 wei:", p, 1);
        assertTrue(p.honest, "control: the honest pool keeps the base");
        assertFalse(p.book, "control: the book is out of the band");
        assertGe(p.total, _honestOut(ORDER, 1) * 99 / 100, "control: the honest price");
    }

    // ---------------------------------------------------------------- what the user is paid

    /// Red before the fix. The minOut the Router tells an integrator to sign (derive it from
    /// Quoter.previewPlanExact, which reads the same Solver plan), less 1 %, did not protect: the
    /// swap paid the book's price.
    function test_MAT02_ASwapWhoseMinOutComesFromThePreviewIsPaidTheHonestPrice() public {
        World memory w = _world(1, 2_500e18, true);
        BlazePhoenixQuoter quoter = new BlazePhoenixQuoter(address(w.hub), address(w.solver));
        (, uint256 exactOut) = quoter.previewPlanExact(address(w.a), address(w.b), ORDER);
        uint256 minOut = exactOut * 99 / 100;
        w.a.mint(USER, ORDER);
        uint256 before = w.b.balanceOf(USER);
        vm.startPrank(USER);
        w.a.approve(address(w.router), ORDER);
        w.router.swapBestExactIn(address(w.a), address(w.b), ORDER, minOut, USER, block.timestamp + 1);
        vm.stopPrank();
        uint256 got = w.b.balanceOf(USER) - before;
        emit log_named_uint("minOut from the preview", minOut);
        emit log_named_uint("delivered to USER (B)", got);
        emit log_named_uint("honestOut(1 A)", _honestOut(ORDER, 1));
        emit log_named_uint("A kept by the book", w.a.balanceOf(address(w.book)));
        assertGe(got, _honestOut(ORDER, 1) * 99 / 100, "MAT-02: the user is paid the book's price");
    }
}
