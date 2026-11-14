// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// PLACE (2026-10-28): A LEG OF THE SPLIT PAYS FOR ITS PLACE. Two honest venues A and B behind 0.3%
// at price 1, and a third, C, at the same price behind a 10% fee. Since MED (3975a50) the band
// judges prices (BlazePhoenixMath, THE BAND), so C sits inside it, and the split weighed every
// survivor by depth alone (`BlazePhoenixMath._weights`): C took its depth's share of the order.
// The gate (Solver, MIN_SPLIT_IMPROVEMENT_PPM) asked only whether the whole split beat the best
// leg alone, never whether each leg earned its place. Measured at 3975a50:
//   minority (C holds 0.3x the honest depth, the order a tenth of each honest venue): C took
//   2307692307692307692 of 10e18, its depth share (60/260), and the route paid
//   9366202448592925025 against 9470004286326618086 without C (-1.10%);
//   majority (C holds 1.02x the honest depth, the order a hundredth of each): the split with C
//   lost to A alone, the gate collapsed on A and paid 984393991900749526 against
//   989276854878431020 without C (-0.49%).
// Before MED (b4138ee) the +-5% band on rates left C out of the minority, and in the majority C
// set the base and took the whole order (-9.68%). The Solver now keeps a leg of a split of three
// or more only while the split with it pays at least MIN_SPLIT_IMPROVEMENT_PPM more than the
// split without it (`Solver._placed`, EVERY LEG PAYS FOR ITS PLACE). Red at 3975a50 before that.
// The pins hold the seat of the remainder through a trial: when a leg leaves, the legs that stay
// split the order to the wei as they do without it, the seat where
// `BlazePhoenixMath._seatTheSplit` puts it, whether the leg that left held it or not. A third
// venue that pays for its place keeps it, tried (5%) or not (0.3%).
// A trial is judged at the caps, as every build is (`Solver._capacity`, MAX_CONC_DRAIN_BPS): where
// only the split without the leg on trial asks a book past its cap, the trial marks the build held,
// whichever split is kept, and the walk settles it (`findBestRoutePlan`). Without that mark a trial
// refused at the caps keeps a 10% venue whose books would pay more without it (mutant [1080]).
import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixQuoter} from "../src/BlazePhoenixQuoter.sol";
import {BlazePhoenixCore as BPC} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV3Pool} from "./mocks/MockV3Pool.sol";
import {MockV3BookPool} from "./mocks/MockV3BookPool.sol";
import {Origin} from "./mocks/MockOriginFactory.sol";

contract SplitLegPaysForItsPlaceTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    BlazePhoenixRouter router;
    BlazePhoenixQuoter quoter;
    MockERC20 tA;
    MockERC20 tB;
    address recipient = makeAddr("recipient");
    uint128 constant HONEST_L = 100e18;
    /// A concentrated book that declares far more liquidity than it holds (`_book`).
    uint128 constant BOOK_L = 1_000_000e18;
    uint256 constant BOOK_HELD = 60e18;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        tA = new MockERC20("A", "A");
        tB = new MockERC20("B", "B");
        solver = new BlazePhoenixSolver(address(hub), address(0));
        router = new BlazePhoenixRouter(address(hub), address(solver), address(this), makeAddr("t1"), makeAddr("t2"));
        quoter = new BlazePhoenixQuoter(address(hub), address(solver));
    }

    /// A coherent venue at price 1: factory tier = fee() = the fee the swap charges; liquidity `l`
    /// and `l` of each token held.
    function _venue(uint24 fee, uint128 l) internal returns (MockV3Pool p) {
        p = new MockV3Pool(address(tA), address(tB), fee);
        p.setState(uint160(BPC.Q96), l);
        tA.mint(address(p), l);
        tB.mint(address(p), l);
        Origin.wire(hub, address(p), address(tA), address(tB), BPC.KIND_V3, fee);
        hub.seedPool(address(p), BPC.KIND_V3, fee, address(0), address(tA), address(tB));
    }

    function _preview(uint256 amt) internal returns (BlazePhoenixQuoter.Preview memory pv) {
        vm.roll(block.number + 1);
        (pv, ) = quoter.previewAndEncode(address(tA), address(tB), amt, recipient, block.timestamp);
    }

    function _inOf(BlazePhoenixQuoter.Preview memory pv, address p) internal pure returns (uint256 s) {
        for (uint256 h; h < pv.route.hops.length; ++h) {
            for (uint256 l; l < pv.route.hops[h].legs.length; ++l) {
                if (pv.route.hops[h].legs[l].pool == p) s += pv.route.hops[h].legs[l].amountIn;
            }
        }
    }

    /// The two honest venues are listed and the order is previewed; then the third venue (fee
    /// `fC`, liquidity `lC`) is listed and the same order previewed again. Returns both outputs and
    /// the input the second preview routes to the third venue.
    function _withAndWithout(uint256 amt, uint24 fC, uint128 lC)
        internal returns (uint256 without, uint256 with_, uint256 inC)
    {
        _venue(3000, HONEST_L);
        _venue(3000, HONEST_L);
        hub.addBridge(address(tB));
        without = _preview(amt).netOut;
        MockV3Pool c = _venue(fC, lC);
        BlazePhoenixQuoter.Preview memory pv = _preview(amt);
        with_ = pv.netOut;
        inC = _inOf(pv, address(c));
        emit log_named_uint("netOut, the two honest venues", without);
        emit log_named_uint("netOut, with the third venue", with_);
        emit log_named_uint("input routed to the third venue", inC);
    }

    /// RED at 3975a50 (-1.10%): a 10% venue at the fair price, 0.3x the honest depth, took its
    /// depth share of an order a tenth of each honest venue.
    function test_AMinorityVenueBehindATenPercentFeeNeverLowersTheSplit() public {
        (uint256 without, uint256 with_, ) = _withAndWithout(10e18, 100_000, 60e18);
        assertGe(with_, without, "a 10% venue holding 0.3x the honest depth lowered the split");
    }

    /// RED at 3975a50 (-0.49%) and at b4138ee (-9.68%): the same venue at 1.02x the honest depth,
    /// the order a hundredth of each honest venue.
    function test_AMajorityVenueBehindATenPercentFeeNeverLowersTheSplit() public {
        (uint256 without, uint256 with_, ) = _withAndWithout(1e18, 100_000, 204e18);
        assertGe(with_, without, "a 10% venue holding 1.02x the honest depth lowered the split");
    }

    /// Any depth from a hundredth to ten times the honest one, any order up to a tenth of each
    /// honest venue: every unit C pays is under 0.9, every unit either honest venue pays on half
    /// such an order is over 0.997 * (100 / 105)^2 > 0.904, so a split without C pays more than
    /// any split with it.
    function testFuzz_AVenueBehindATenPercentFeeNeverLowersTheSplit(uint256 lC, uint256 amt) public {
        lC = bound(lC, 1e18, 1_000e18);
        amt = bound(amt, 1e16, 10e18);
        (uint256 without, uint256 with_, ) = _withAndWithout(amt, 100_000, uint128(lC));
        assertGe(with_, without, "a 10% venue at the fair price lowered the split");
    }

    /// A THIRD VENUE THAT PAYS FOR ITS PLACE KEEPS IT (green before and after). Beside the two
    /// honest venues, an order a tenth of each. A third honest venue (0.3%, 0.6x the depth of
    /// each) is never tried: its probe pays more than either honest venue does on average. A venue
    /// behind 5% holding as much is tried (its probe pays about 0.948, A about 0.960 on average)
    /// and keeps its place: the split with it pays more than MIN_SPLIT_IMPROVEMENT_PPM over the
    /// split without it.
    function test_AThirdVenueThatPaysForItsPlaceKeepsIt() public {
        (uint256 without, uint256 with_, uint256 inC) = _withAndWithout(10e18, 3000, 60e18);
        assertGt(inC, 0, "an honest third venue is no leg");
        assertGt(with_, without, "an honest third venue did not raise the output");
        _market();
        (without, with_, inC) = _withAndWithout(10e18, 50_000, 60e18);
        assertGt(inC, 0, "a 5% venue that pays for its place lost it");
        assertGt(with_, without, "a 5% venue that pays for its place did not raise the output");
    }

    /// PIN, THE SEAT STAYS (`_leave`, the leg that leaves sits below the seat). A 100e18 and B
    /// 50e18 at 0.3%, C at 10% holding 30e18: the seat of the remainder is A, the deepest
    /// (`BlazePhoenixMath._seatTheSplit`). C leaves and A keeps the seat, so each honest venue is
    /// routed, to the wei, what it is routed without C: the order 1e18 + 1 leaves a wei of
    /// rounding to the seat, and a seat moved to B would take it.
    function test_Pin_TheSeatStaysWhenAnotherLegLeaves() public {
        uint128[] memory ls = new uint128[](2);
        (ls[0], ls[1]) = (100e18, 50e18);
        _pin(1e18 + 1, ls, 30e18);
    }

    /// PIN, THE SEAT LEAVES. A 100e18, B 50e18 and D 25e18 at 0.3%, C at 10% holding 200e18: C,
    /// the deepest, holds the seat. When C leaves, the seat goes to A, the deepest of the legs left
    /// (`BlazePhoenixMath.seatOf`), not to the leg that sat before C; to the wei, as without C.
    function test_Pin_TheSeatGoesToTheDeepestWhenItsLegLeaves() public {
        uint128[] memory ls = new uint128[](3);
        (ls[0], ls[1], ls[2]) = (100e18, 50e18, 25e18);
        _pin(1e18 + 1, ls, 200e18);
    }

    /// Fresh tokens, so a test can open a second market.
    function _market() internal {
        tA = new MockERC20("A", "A");
        tB = new MockERC20("B", "B");
    }

    /// One market: honest venues at 0.3% holding `ls`, the order previewed; then a venue behind
    /// 10% holding `lC` is listed and the order previewed again. The 10% venue gets nothing, and
    /// each honest venue gets, to the wei, the input it got without it.
    function _pin(uint256 amt, uint128[] memory ls, uint128 lC) internal {
        _market();
        MockV3Pool[] memory h = new MockV3Pool[](ls.length);
        for (uint256 i; i < ls.length; ++i) h[i] = _venue(3000, ls[i]);
        hub.addBridge(address(tB));
        BlazePhoenixQuoter.Preview memory pv = _preview(amt);
        uint256[] memory without = new uint256[](ls.length);
        for (uint256 i; i < ls.length; ++i) without[i] = _inOf(pv, address(h[i]));
        MockV3Pool c = _venue(100_000, lC);
        pv = _preview(amt);
        assertEq(_inOf(pv, address(c)), 0, "pin: the 10% venue kept a leg");
        for (uint256 i; i < ls.length; ++i) {
            emit log_named_uint("input to an honest venue, without and with the 10% venue", without[i]);
            assertEq(_inOf(pv, address(h[i])), without[i], "pin: an honest venue's input moved when the 10% venue left");
        }
    }

    /// A concentrated book at price 1 behind 0.3% (spacing 60, no initialized tick, so its walk and
    /// its swap settle at one tick): it declares BOOK_L and holds `holdings` of each token, so the
    /// Solver weighs it by what it holds and promises at most MAX_CONC_DRAIN_BPS of it.
    function _book(uint256 holdings) internal returns (MockV3BookPool p) {
        p = new MockV3BookPool(address(tA), address(tB), 3000, 60);
        p.setState(uint160(BPC.Q96), BOOK_L);
        tA.mint(address(p), holdings);
        tB.mint(address(p), holdings);
        Origin.wire(hub, address(p), address(tA), address(tB), BPC.KIND_V3, 3000);
        hub.seedPool(address(p), BPC.KIND_V3, 3000, address(0), address(tA), address(tB));
    }

    /// Two books holding BOOK_HELD each and the order previewed; then C, an honest venue behind
    /// 10% holding `lC`, is listed and the same order previewed again (as `_withAndWithout`).
    function _heldTrial(uint256 amt, uint128 lC) internal returns (uint256 without, uint256 with_, uint256 inC) {
        // The order runs token1 -> token0: there a flat book's walk pays its single-range quote to
        // the wei (`Core._v4Step` against `Core.outV3`). Token0 -> token1 the walk rounds the price
        // up and the quote down, so the walk may pay a wei less, a fall (`_paysWhatItWalks`) that
        // takes the book out of the rebuild.
        if (address(tA) < address(tB)) (tA, tB) = (tB, tA);
        _book(BOOK_HELD);
        _book(BOOK_HELD);
        hub.addBridge(address(tB));
        without = _preview(amt).netOut;
        MockV3Pool c = _venue(100_000, lC);
        BlazePhoenixQuoter.Preview memory pv = _preview(amt);
        with_ = pv.netOut;
        inC = _inOf(pv, address(c));
        emit log_named_uint("netOut, the two books", without);
        emit log_named_uint("netOut, with the 10% venue", with_);
        emit log_named_uint("input routed to the 10% venue", inC);
        assertGt(without, 2 * BPC.mulDiv(BOOK_HELD, 3_000, BPC.BPS), "precondition: the walk pays the two books past their caps");
    }

    /// A TRIAL REFUSED AT THE CAPS IS SETTLED BY THE WALK (`_placed`, the held mark of the split
    /// without the leg on trial). Two books behind 0.3% hold 60e18 each (cap 18e18) and declare far
    /// more; C, behind 10%, holds 1000e18. The order, 64e18, splits by what each holds: each book is
    /// asked about 3.43e18, inside its cap, C about 57.14e18, and the three pay about 55.75e18 with
    /// no leg held. C is tried: without it each book is asked 32e18, past its cap and inside what it
    /// holds, so the split of two is judged at the caps (36e18) and refused. No single is held (a
    /// book alone would pay more than it holds; C alone pays about 54.46e18, inside its cap), so
    /// only the trial marks the build held. The walk pays the two books about 63.81e18, C leaves,
    /// and the route is the one the two books give alone. Without the mark the walk never runs and
    /// C keeps about 89% of the order, about -12.6% (mutant [1080]).
    function test_ATrialRefusedAtTheCapIsSettledByTheWalk() public {
        (uint256 without, uint256 with_, uint256 inC) = _heldTrial(64e18, 1_000e18);
        assertEq(inC, 0, "a 10% venue kept its leg where the books pay more without it");
        assertGe(with_, without, "a trial refused at the caps lowered the split");
    }

    /// The same for orders from 61e18 to 66e18 (each book asked half the order: past its cap,
    /// inside what it holds; a book alone asked more than it holds) and C holding 200e18 to
    /// 10_000e18 (C alone inside its cap; the split of three above C alone and below the two books
    /// walked, every leg of it inside its cap).
    function testFuzz_ATrialRefusedAtTheCapIsSettledByTheWalk(uint256 amt, uint256 lC) public {
        amt = bound(amt, 61e18, 66e18);
        lC = bound(lC, 200e18, 10_000e18);
        (uint256 without, uint256 with_, uint256 inC) = _heldTrial(amt, uint128(lC));
        assertEq(inC, 0, "a 10% venue kept its leg where the books pay more without it");
        assertGe(with_, without, "a trial refused at the caps lowered the split");
    }
}
