// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// PLACE, LINE BY LINE (2026-11-11). `Solver._placed` tries the legs of a split of three or more one
// at a time (`_onTrial`), takes the leg that does not pay for its place out of the four arrays in
// lockstep (`_leave`, `_swap`) and builds the split again. test/SplitLegPaysForItsPlace.t.sol holds
// the cases the rule was written for: one venue behind 10% beside honest ones, one trial. The lines
// a single trial never reads had no mutant: the second trial of a build, the build no leg is tried
// in, the held mark of a build whose trial is not held, the lockstep of the holdings and of the
// probe rates, the tie of the seat, and a trial on each hop of a two-hop route. Each test below
// names the mutant that turns it red (.github/scripts/mutants.py, [ATQ-mutacao-n]).
//
// The fixtures are those of SplitLegPaysForItsPlace: full-range V3 venues at price 1 whose factory
// tier is the fee they charge, and concentrated books that declare more than they hold.

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixSolver, MIN_SPLIT_IMPROVEMENT_PPM} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixQuoter} from "../src/BlazePhoenixQuoter.sol";
import {BlazePhoenixCore as BPC} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV3Pool} from "./mocks/MockV3Pool.sol";
import {MockV3BookPool} from "./mocks/MockV3BookPool.sol";
import {Origin} from "./mocks/MockOriginFactory.sol";

/// The market, the venues and the readings of a preview, shared with test/SplitPlaceKnownRed.t.sol.
abstract contract SplitPlaceFixture is Test {
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    BlazePhoenixRouter router;
    BlazePhoenixQuoter quoter;
    MockERC20 tA;
    MockERC20 tB;
    address recipient = makeAddr("recipient");
    uint128 constant HONEST_L = 100e18;
    uint24 constant HONEST_FEE = 3000;
    uint24 constant DEAR_FEE = 100_000;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        solver = new BlazePhoenixSolver(address(hub), address(0));
        router = new BlazePhoenixRouter(address(hub), address(solver), address(this), makeAddr("t1"), makeAddr("t2"));
        quoter = new BlazePhoenixQuoter(address(hub), address(solver));
        _market();
    }

    /// Fresh tokens, so a test can open a second market.
    function _market() internal {
        tA = new MockERC20("A", "A");
        tB = new MockERC20("B", "B");
    }

    /// A coherent venue at price 1 on (a, b): liquidity `l`, holding `l + extra` of each token.
    function _venueOn(MockERC20 a, MockERC20 b, uint24 fee, uint128 l, uint256 extra) internal returns (MockV3Pool p) {
        p = new MockV3Pool(address(a), address(b), fee);
        p.setState(uint160(BPC.Q96), l);
        a.mint(address(p), l + extra);
        b.mint(address(p), l + extra);
        Origin.wire(hub, address(p), address(a), address(b), BPC.KIND_V3, fee);
        hub.seedPool(address(p), BPC.KIND_V3, fee, address(0), address(a), address(b));
    }

    function _venue(uint24 fee, uint128 l) internal returns (MockV3Pool) {
        return _venueOn(tA, tB, fee, l, 0);
    }

    /// A book behind `fee` at price 1 (spacing 60, no initialized tick): it declares a million
    /// times HONEST_L and holds `held` of each token.
    function _book(uint24 fee, uint256 held) internal returns (MockV3BookPool p) {
        p = new MockV3BookPool(address(tA), address(tB), fee, 60);
        p.setState(uint160(BPC.Q96), 1_000_000 * HONEST_L);
        tA.mint(address(p), held);
        tB.mint(address(p), held);
        Origin.wire(hub, address(p), address(tA), address(tB), BPC.KIND_V3, fee);
        hub.seedPool(address(p), BPC.KIND_V3, fee, address(0), address(tA), address(tB));
    }

    function _previewOn(MockERC20 a, MockERC20 b, uint256 amt) internal returns (BlazePhoenixQuoter.Preview memory pv) {
        vm.roll(block.number + 1);
        (pv, ) = quoter.previewAndEncode(address(a), address(b), amt, recipient, block.timestamp);
    }

    function _preview(uint256 amt) internal returns (BlazePhoenixQuoter.Preview memory) {
        return _previewOn(tA, tB, amt);
    }

    function _inOf(BlazePhoenixQuoter.Preview memory pv, address p) internal pure returns (uint256 s) {
        for (uint256 h; h < pv.route.hops.length; ++h) {
            for (uint256 l; l < pv.route.hops[h].legs.length; ++l) {
                if (pv.route.hops[h].legs[l].pool == p) s += pv.route.hops[h].legs[l].amountIn;
            }
        }
    }

    function _outOf(BlazePhoenixQuoter.Preview memory pv, address p) internal pure returns (uint256 s) {
        for (uint256 h; h < pv.route.hops.length; ++h) {
            for (uint256 l; l < pv.route.hops[h].legs.length; ++l) {
                if (pv.route.hops[h].legs[l].pool == p) s += pv.route.hops[h].legs[l].expectedOut;
            }
        }
    }

}

contract SplitPlaceEveryLineTest is SplitPlaceFixture {
    // ───────────────────────── two trials in one build ─────────────────────────

    /// Two honest venues (0.3%, `lA` and `lB`) and the order previewed; then two venues behind 10%
    /// (`lC1`, `lC2`) are listed and the order previewed again. Both leave, one trial after the
    /// other, and each honest venue is routed, to the wei, what it is routed without them.
    function _twoLeave(uint256 amt, uint128 lA, uint128 lB, uint128 lC1, uint128 lC2) internal {
        _market();
        MockV3Pool a = _venue(HONEST_FEE, lA);
        MockV3Pool b = _venue(HONEST_FEE, lB);
        hub.addBridge(address(tB));
        BlazePhoenixQuoter.Preview memory pv = _preview(amt);
        (uint256 inA, uint256 inB, uint256 without) = (_inOf(pv, address(a)), _inOf(pv, address(b)), pv.netOut);
        assertGt(inA, 0, "precondition: the first honest venue is no leg");
        assertGt(inB, 0, "precondition: the second honest venue is no leg");
        MockV3Pool c1 = _venue(DEAR_FEE, lC1);
        MockV3Pool c2 = _venue(DEAR_FEE, lC2);
        pv = _preview(amt);
        assertEq(_inOf(pv, address(c1)), 0, "the first 10% venue kept a leg");
        assertEq(_inOf(pv, address(c2)), 0, "the second 10% venue kept a leg");
        assertEq(_inOf(pv, address(a)), inA, "the first honest venue's input moved when the 10% venues left");
        assertEq(_inOf(pv, address(b)), inB, "the second honest venue's input moved when the 10% venues left");
        assertGe(pv.netOut, without, "two 10% venues lowered the split");
    }

    /// The second 10% venue is the deepest of the four and holds the seat; the first is the
    /// shallowest and leaves first, from below the seat.
    function test_TwoDearVenuesBothLeave_TheDeepestOfThemHeldTheSeat() public {
        _twoLeave(1e18 + 1, 100e18, 50e18, 30e18, 200e18);
        _twoLeave(10e18 + 1, 100e18, 50e18, 30e18, 200e18);
    }

    /// The same two listed the other way round, so their addresses and the funnel's order swap.
    function test_TwoDearVenuesBothLeave_TheDeepestListedFirst() public {
        _twoLeave(1e18 + 1, 100e18, 50e18, 200e18, 30e18);
        _twoLeave(10e18 + 1, 50e18, 100e18, 200e18, 30e18);
    }

    /// Both 10% venues are shallower than either honest one: the seat is honest and never moves.
    function test_TwoDearVenuesBothLeave_TheSeatIsHonest() public {
        _twoLeave(1e18 + 1, 100e18, 50e18, 30e18, 20e18);
        _twoLeave(5e18 + 1, 50e18, 100e18, 20e18, 30e18);
    }

    /// The first 10% venue holds a fiftieth of an honest venue's share of the order, so a leg
    /// judged at the holdings of the venue that stood in its place is cut (`_capacity`): the
    /// holdings move with the candidates when a leg leaves.
    function test_TwoDearVenuesBothLeave_TheFirstHoldsLessThanAnHonestLegPays() public {
        _twoLeave(10e18 + 1, 100e18, 50e18, 2e17, 200e18);
        _twoLeave(10e18 + 1, 50e18, 100e18, 200e18, 2e17);
        _twoLeave(10e18 + 1, 100e18, 100e18, 2e17, 3e17);
    }

    /// Every depth is the same, so every weight ties and the lower address decides.
    function test_TwoDearVenuesBothLeave_EveryDepthTies() public {
        _twoLeave(1e18 + 1, 100e18, 100e18, 100e18, 100e18);
    }

    /// A depth for a 10% venue that leaves the honest weights whole. A weight is the venue's
    /// depth in ten-thousandths of the deepest of the set, rounded down (`BlazePhoenixMath
    /// ._weights`), and it is not weighed again when a leg leaves: beside honest venues of
    /// HONEST_L and HONEST_L / 2 the honest weights are whole numbers where the 10% venue is no
    /// deeper than HONEST_L, or a multiple of it that divides 5,000.
    function _depth(uint256 seed) internal pure returns (uint128) {
        if (seed & 1 == 0) return uint128(bound(seed >> 1, 1e18, HONEST_L));
        return HONEST_L * [uint128(2), 4, 5, 8, 10, 20][(seed >> 1) % 6];
    }

    /// Depths of the 10% venues from a hundredth to twenty times the deeper honest one, orders up
    /// to a thirtieth of the honest depth: every unit a 10% venue pays is under 0.9, every unit
    /// an honest venue pays on such an order is over 0.997 * (100 / 105)^2 > 0.904.
    function testFuzz_TwoDearVenuesBothLeave(uint256 s1, uint256 s2, uint256 amt) public {
        amt = bound(amt, 1e16, 5e18);
        _twoLeave(amt, HONEST_L, HONEST_L / 2, _depth(s1), _depth(s2));
    }

    // ───────────────────────── the build no leg is tried in ─────────────────────────

    /// Three venues of one depth behind one fee, the order `k` gate prices of that depth
    /// (k * MIN_SPLIT_IMPROVEMENT_PPM / 1e6 of it). Each leg's probe is a hundredth of the order
    /// and its share a third, so every probe pays more than every leg pays on average and no leg
    /// is tried (`_onTrial`): the three stay. The precondition is that a trial would have taken
    /// one out: the three pay less than the gate's price over two (a third venue adds about a
    /// sixth of the order's impact, under the gate's price while k < 6).
    function _noLegIsTried(uint256 k) internal {
        _market();
        uint256 amt = uint256(HONEST_L) * k * MIN_SPLIT_IMPROVEMENT_PPM / 1_000_000;
        MockV3Pool a = _venue(HONEST_FEE, HONEST_L);
        MockV3Pool b = _venue(HONEST_FEE, HONEST_L);
        hub.addBridge(address(tB));
        uint256 two = _preview(amt).netOut;
        MockV3Pool d = _venue(HONEST_FEE, HONEST_L);
        BlazePhoenixQuoter.Preview memory pv = _preview(amt);
        assertLt(pv.netOut * 1_000_000, two * (1_000_000 + MIN_SPLIT_IMPROVEMENT_PPM),
            "precondition: the third venue pays the gate's price, so a trial would keep it too");
        assertGt(_inOf(pv, address(a)), 0, "a leg no trial asked for left the split");
        assertGt(_inOf(pv, address(b)), 0, "a leg no trial asked for left the split");
        assertGt(_inOf(pv, address(d)), 0, "a leg no trial asked for left the split");
    }

    function test_NoLegIsTriedWhereEveryProbeBeatsEveryAverage() public {
        _noLegIsTried(2);
        _noLegIsTried(4);
        _noLegIsTried(5);
    }

    function testFuzz_NoLegIsTriedWhereEveryProbeBeatsEveryAverage(uint256 k) public {
        _noLegIsTried(bound(k, 2, 5));
    }

    // ───────────────────────── a held build stays held ─────────────────────────

    /// A HELD BUILD STAYS HELD THROUGH A TRIAL THAT IS NOT (`_placed`, the held mark). Two honest
    /// venues hold ten times their liquidity, so no order here asks them past their cap. A book
    /// behind 40% holds `held` and is weighed by it. The order is 0.55 of the summed weights: the
    /// book is asked 0.55 of what it holds and would pay 0.33 of it, past its cap and inside its
    /// holdings, so the split of three is held. The book's probe pays 0.6 and an honest venue
    /// about 0.64 on average, so the book is tried; the split without it has no held leg. The
    /// build was held before the trial and stays held, the walk settles it (`findBestRoutePlan`)
    /// and the book is promised what its walk pays, above its cap. A mark overwritten by the
    /// trial's leaves the book promised its cap.
    function _heldThroughATrial(uint256 held) internal {
        _market();
        // token1 -> token0, where a flat book's walk pays its single-range quote to the wei.
        if (address(tA) < address(tB)) (tA, tB) = (tB, tA);
        _venueOn(tA, tB, HONEST_FEE, HONEST_L, 9 * uint256(HONEST_L));
        _venueOn(tA, tB, HONEST_FEE, HONEST_L, 9 * uint256(HONEST_L));
        hub.addBridge(address(tB));
        MockV3BookPool c = _book(400_000, held);
        uint256 amt = (2 * uint256(HONEST_L) + held) * 55 / 100;
        BlazePhoenixQuoter.Preview memory pv = _preview(amt);
        uint256 inC = _inOf(pv, address(c));
        uint256 outC = _outOf(pv, address(c));
        emit log_named_uint("input routed to the book", inC);
        emit log_named_uint("output promised by the book", outC);
        assertGt(inC, 0, "precondition: the book is no leg");
        assertLe(outC, held, "precondition: the book is promised more than it holds");
        // The book charges 40% at price 1 and its declared liquidity leaves the price where it was.
        assertApproxEqRel(outC, inC * 6 / 10, 1e14, "a build held before its trial was not walked: the book is not promised what it pays");
    }

    function test_AHeldBuildStaysHeldThroughATrialThatIsNot() public {
        _heldThroughATrial(20e18);
    }

    function testFuzz_AHeldBuildStaysHeldThroughATrialThatIsNot(uint256 held) public {
        _heldThroughATrial(bound(held, 5e18, 40e18));
    }

    // ───────────────────────── the committed input of the split kept ─────────────────────────

    /// THE HOP COMMITS WHAT ITS LEGS TAKE (`_placed`, the split kept). A book at the honest fee
    /// holds `heldX`, more than the depth of any venue beside it, so it takes the remainder; two
    /// honest venues hold ten times their liquidity. The order is `pct` percent of the summed
    /// depths, above them: the book is asked more than it holds, its input is cut to what its cap
    /// pays, and the cut stays uncommitted (`_capacity`, CUT). A venue one pip under 90% takes its
    /// depth's share, is tried and leaves; the honest venues then take more, the book is asked
    /// more and is cut to the same input, so the split kept commits less than the split before
    /// it did. The hop states the sum of its own legs' inputs, the one it states where the 90%
    /// venue was never listed. A committed input carried over from the split before states more
    /// than the legs take. The ranges stop where the split without the 90% venue still pays
    /// more than the split with it: past them the venue stays (test/SplitPlaceKnownRed.t.sol).
    /// ONE PIP UNDER, NOT AT (2026-11-14). The venue stood at 900,000 pips when this was written
    /// (35b0839). Since 25ac1fc a row whose fee reaches the route's ceiling on a leg's impact
    /// (`MAX_ROUTE_IMPACT_BPS`, 9,000 bps = 900,000 pips) is not quoted (`Solver._buildHop`;
    /// test/DestroyerLegAtBirth.t.sol), so at 900,000 the venue was no leg, no leg was tried and
    /// the line that keeps the split after a trial was not read: at a4ac71f this test was green
    /// with [ATQ-mutacao-7] applied. One pip under the ceiling the venue is a row again and the
    /// trial runs: with the mutant the hop of the first case commits 345.124e18 while its legs
    /// take 319.409e18.
    uint24 constant UNDER_THE_CEILING_FEE = 899_999;

    function _cutThroughATrial(uint256 heldX, uint128 lC, uint256 pct) internal {
        _market();
        if (address(tA) < address(tB)) (tA, tB) = (tB, tA);
        _venueOn(tA, tB, HONEST_FEE, HONEST_L, 9 * uint256(HONEST_L));
        _venueOn(tA, tB, HONEST_FEE, HONEST_L, 9 * uint256(HONEST_L));
        hub.addBridge(address(tB));
        MockV3BookPool x = _book(HONEST_FEE, heldX);
        uint256 amt = (2 * uint256(HONEST_L) + heldX + lC) * pct / 100;
        BlazePhoenixQuoter.Preview memory pv = _preview(amt);
        assertEq(pv.route.hops.length, 1, "precondition: the route without the 90% venue is not direct");
        uint256 without = pv.route.hops[0].amountIn;
        emit log_named_uint("order", amt);
        emit log_named_uint("committed without the 90% venue", without);
        assertEq(pv.route.hops[0].legs.length, 3, "precondition: the three venues are not the legs");
        assertGt(_inOf(pv, address(x)), 0, "precondition: the book is no leg");
        assertLt(without, amt, "precondition: the book's input was not cut");
        MockV3Pool c = _venueOn(tA, tB, UNDER_THE_CEILING_FEE, lC, 9 * uint256(lC));
        pv = _preview(amt);
        assertEq(pv.route.hops.length, 1, "the route is not direct");
        assertEq(_inOf(pv, address(c)), 0, "the 90% venue kept a leg");
        uint256 taken;
        for (uint256 l; l < pv.route.hops[0].legs.length; ++l) taken += pv.route.hops[0].legs[l].amountIn;
        emit log_named_uint("committed with the 90% venue listed", pv.route.hops[0].amountIn);
        emit log_named_uint("taken by the legs", taken);
        assertEq(pv.route.hops[0].amountIn, taken, "the hop commits an input its legs do not take");
        assertEq(pv.route.hops[0].amountIn, without, "the committed input moved when the 90% venue left");
    }

    function test_TheHopCommitsWhatTheLegsOfTheSplitKeptTake() public {
        _cutThroughATrial(150e18, 50e18, 120);
        _cutThroughATrial(120e18, 20e18, 110);
        _cutThroughATrial(200e18, 90e18, 120);
    }

    function testFuzz_TheHopCommitsWhatTheLegsOfTheSplitKeptTake(uint256 heldX, uint128 lC, uint256 pct) public {
        _cutThroughATrial(bound(heldX, 120e18, 200e18), uint128(bound(lC, 20e18, 90e18)), bound(pct, 110, 120));
    }

    // ───────────────────────── the tie of the seat ─────────────────────────

    /// THE SEAT OF A TIE (`BlazePhoenixMath.seatOf`). Two venues of one depth and an odd order:
    /// the first leg takes half rounded down and the seat the remainder, one wei more. The seat
    /// of a tie is the lower address, whichever was listed first.
    function test_Pin_TheOddWeiGoesToTheLowerAddressOfATie() public {
        for (uint256 round; round < 2; ++round) {
            _market();
            MockV3Pool a = _venue(HONEST_FEE, HONEST_L);
            MockV3Pool b = _venue(HONEST_FEE, HONEST_L);
            hub.addBridge(address(tB));
            (address lo, address hi) = address(a) < address(b) ? (address(a), address(b)) : (address(b), address(a));
            BlazePhoenixQuoter.Preview memory pv = _preview(1e18 + 1);
            assertEq(_inOf(pv, lo), _inOf(pv, hi) + 1, "the seat of a tie is not the lower address");
            // A deeper third venue takes the seat from both, and the tie splits evenly.
            MockV3Pool d = _venue(HONEST_FEE, 2 * HONEST_L);
            pv = _preview(1e18 + 1);
            assertEq(_inOf(pv, lo), _inOf(pv, hi), "a venue below the seat took the remainder");
            assertGt(_inOf(pv, address(d)), 2 * _inOf(pv, lo), "the deepest venue does not hold the seat");
        }
    }

    // ───────────────────────── a trial on each hop ─────────────────────────

    /// TWO HOPS, A TRIAL ON EACH. No venue lists (in, out); two honest venues list (in, mid) and
    /// two list (mid, out). Then a venue behind 10% is listed on each pair. Each leaves its hop,
    /// and every honest venue is routed, to the wei, what it is routed without them: the hop is
    /// built twice (`_planViaBridges`) and the second pass reads the lists as the trial left them.
    function _twoHops(uint256 amt, uint128 lC1, uint128 lC2) internal {
        _market();
        MockERC20 tM = new MockERC20("M", "M");
        MockV3Pool[4] memory h;
        h[0] = _venueOn(tA, tM, HONEST_FEE, HONEST_L, 0);
        h[1] = _venueOn(tA, tM, HONEST_FEE, HONEST_L / 2, 0);
        h[2] = _venueOn(tM, tB, HONEST_FEE, HONEST_L, 0);
        h[3] = _venueOn(tM, tB, HONEST_FEE, HONEST_L / 2, 0);
        hub.addBridge(address(tM));
        BlazePhoenixQuoter.Preview memory pv = _preview(amt);
        assertEq(pv.route.hops.length, 2, "precondition: the route is not two hops");
        uint256[4] memory without;
        for (uint256 i; i < 4; ++i) {
            without[i] = _inOf(pv, address(h[i]));
            assertGt(without[i], 0, "precondition: an honest venue is no leg");
        }
        uint256 out = pv.netOut;
        MockV3Pool c1 = _venueOn(tA, tM, DEAR_FEE, lC1, 0);
        MockV3Pool c2 = _venueOn(tM, tB, DEAR_FEE, lC2, 0);
        pv = _preview(amt);
        assertEq(pv.route.hops.length, 2, "the route is not two hops");
        assertEq(_inOf(pv, address(c1)), 0, "the 10% venue of the first hop kept a leg");
        assertEq(_inOf(pv, address(c2)), 0, "the 10% venue of the second hop kept a leg");
        for (uint256 i; i < 4; ++i) {
            assertEq(_inOf(pv, address(h[i])), without[i], "an honest venue's input moved when the 10% venues left");
        }
        assertGe(pv.netOut, out, "a 10% venue on each hop lowered the route");
    }

    function test_TwoHops_ADearVenueOnEachHopLeavesIt() public {
        _twoHops(1e18 + 1, 30e18, 200e18);
        _twoHops(1e18 + 1, 200e18, 30e18);
    }

    function test_TwoHops_ADeepDearVenueOnEachHopLeavesIt() public {
        _twoHops(5e18 + 1, 200e18, 200e18);
        _twoHops(1e17 + 1, 1_000e18, 400e18);
    }

    function testFuzz_TwoHops_ADearVenueOnEachHopLeavesIt(uint256 s1, uint256 s2, uint256 amt) public {
        amt = bound(amt, 1e16, 5e18);
        _twoHops(amt, _depth(s1), _depth(s2));
    }
}
