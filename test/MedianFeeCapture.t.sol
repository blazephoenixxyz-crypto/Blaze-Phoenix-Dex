// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// MED (2026-10-27): THE BAND JUDGED A FEE-INCLUSIVE RATE. Two concentrated venues of one pair at
// the SAME price and the SAME depth, one charging 0.3%, the other charging v. The probe rate of
// each (`_buildHop`) is out/probe AFTER the fee, so the weighted median of the two
// (`BlazePhoenixMath._wMedian`) landed on the worse-for-the-user rate whenever that venue held half
// the voting mass or more, and the old fixed +-5% band around it then dropped the 0.3% venue as
// "too good" once (1 - 0.003) / (1 - v) > 1.05. The whole order went to the worse venue. The band
// now judges the PRICE, r * 1e6 / (1e6 - f) with f the fee the probe itself was charged
// (`BlazePhoenixMath._prices`), and its width is the no-arbitrage band of the two fees
// (BlazePhoenixMath, "THE BAND"). Red before that.
import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixQuoter} from "../src/BlazePhoenixQuoter.sol";
import {BlazePhoenixCore as BPC} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV3Pool} from "./mocks/MockV3Pool.sol";
import {Origin} from "./mocks/MockOriginFactory.sol";

contract MedianFeeCaptureTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    BlazePhoenixRouter router;
    BlazePhoenixQuoter quoter;
    MockERC20 tA;
    MockERC20 tB;
    address recipient = makeAddr("recipient");
    uint256 constant AMOUNT_IN = 1e18;
    uint128 constant L = 1e30;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        tA = new MockERC20("A", "A");
        tB = new MockERC20("B", "B");
        solver = new BlazePhoenixSolver(address(hub), address(0));
        router = new BlazePhoenixRouter(address(hub), address(solver), address(this), makeAddr("t1"), makeAddr("t2"));
        quoter = new BlazePhoenixQuoter(address(hub), address(solver));
    }

    /// A coherent venue: factory tier = fee() = the fee the swap charges; price 1; liquidity `l`
    /// and `l` of each token held (so the physical cap on the vote is the declared depth).
    function _venue(uint24 fee, uint128 l) internal returns (MockV3Pool p) {
        p = new MockV3Pool(address(tA), address(tB), fee);
        p.setState(uint160(BPC.Q96), l);
        tA.mint(address(p), l);
        tB.mint(address(p), l);
        Origin.wire(hub, address(p), address(tA), address(tB), BPC.KIND_V3, fee);
        hub.seedPool(address(p), BPC.KIND_V3, fee, address(0), address(tA), address(tB));
    }

    function _preview() internal returns (BlazePhoenixQuoter.Preview memory pv) {
        vm.roll(block.number + 1);
        (pv, ) = quoter.previewAndEncode(address(tA), address(tB), AMOUNT_IN, recipient, block.timestamp);
    }

    function _inOf(BlazePhoenixQuoter.Preview memory pv, address p) internal pure returns (uint256 s) {
        for (uint256 h; h < pv.route.hops.length; ++h) {
            for (uint256 l; l < pv.route.hops[h].legs.length; ++l) {
                if (pv.route.hops[h].legs[l].pool == p) s += pv.route.hops[h].legs[l].amountIn;
            }
        }
    }

    /// The 0.3% venue alone: what the user gets with no second venue at all.
    function _goodAlone() internal returns (uint256) {
        return _alone(3000, L);
    }

    /// One venue alone (`_venue(fee, l)`): the output the route owes the user at least.
    function _alone(uint24 fee, uint128 l) internal returns (uint256 out) {
        uint256 s = vm.snapshotState();
        _venue(fee, l);
        hub.addBridge(address(tB));
        out = _preview().netOut;
        vm.revertToState(s);
    }

    /// RED. Adding a venue that is strictly worse (same price, same depth, a higher fee) can only
    /// leave the user's output where it was: the route may ignore it, never prefer it.
    function testFuzz_AWorseVenueOfEqualDepthNeverLowersTheOutput(uint24 v) public {
        v = uint24(bound(v, 51_000, 880_000));
        uint256 alone = _goodAlone();
        MockV3Pool good = _venue(3000, L);
        MockV3Pool bad = _venue(v, L);
        hub.addBridge(address(tB));
        BlazePhoenixQuoter.Preview memory pv = _preview();
        emit log_named_uint("fee of the second venue (pips)", v);
        emit log_named_uint("netOut, 0.3% venue alone", alone);
        emit log_named_uint("netOut, both venues", pv.netOut);
        emit log_named_uint("input routed to the 0.3% venue", _inOf(pv, address(good)));
        emit log_named_uint("input routed to the worse venue", _inOf(pv, address(bad)));
        assertGe(pv.netOut, alone, "a worse venue lowered the route's output");
    }

    /// RED, deterministic (the trace's case): a 10% venue of equal depth beside the 0.3% one.
    function test_AWorseVenueOfEqualDepthAtTenPercent() public {
        uint256 alone = _goodAlone();
        _venue(3000, L);
        _venue(100_000, L);
        hub.addBridge(address(tB));
        assertGe(_preview().netOut, alone, "a 10% venue of equal depth lowered the route's output");
    }

    /// RED, not a tie: the worse venue holds MORE than half the mass (2x the depth). The tie-break
    /// of `_wMedian` is not the whole cause - any half-or-more of the voting mass captures the base.
    function test_AWorseVenueTwiceAsDeepNeverLowersTheOutput() public {
        uint256 alone = _goodAlone();
        _venue(3000, L);
        MockV3Pool bad = _venue(100_000, 2 * L);
        hub.addBridge(address(tB));
        BlazePhoenixQuoter.Preview memory pv = _preview();
        emit log_named_uint("netOut, 0.3% venue alone", alone);
        emit log_named_uint("netOut, both venues", pv.netOut);
        emit log_named_uint("input routed to the worse venue", _inOf(pv, address(bad)));
        assertGe(pv.netOut, alone, "a worse, deeper venue lowered the route's output");
    }

    /// CONTROL (green before and after the fix): the worse venue holds just under half the mass
    /// (0.99x the depth), so the 0.3% venue sets the base. Before the fix the band (a fixed 5%
    /// around that rate) dropped the 10% venue; after it the band keeps it (same price, inside the
    /// width of the two fees) and the split gives it nothing.
    function test_Control_AWorseVenueJustShallowerIsDropped() public {
        uint256 alone = _goodAlone();
        MockV3Pool good = _venue(3000, L);
        MockV3Pool bad = _venue(100_000, L / 100 * 99);
        hub.addBridge(address(tB));
        BlazePhoenixQuoter.Preview memory pv = _preview();
        assertEq(_inOf(pv, address(bad)), 0, "control: the shallower 10% venue is no leg");
        assertEq(_inOf(pv, address(good)), AMOUNT_IN, "control: the 0.3% venue takes the order");
        assertGe(pv.netOut, alone, "control: output at least the 0.3% venue alone");
    }

    /// CONTROL (green before and after the fix): a 5% venue of equal depth at the same price is in
    /// the band and is no leg - the split prices it out. Before the fix it sat just inside the
    /// fixed 5% band, (1 - 0.003) / (1 - 0.05) = 1.0495 < 1.05; after it the band is the width of
    /// the two fees and the same price is always inside.
    function test_Control_AWorseVenueInsideTheBandIsNoLeg() public {
        uint256 alone = _goodAlone();
        _venue(3000, L);
        MockV3Pool bad = _venue(50_000, L);
        hub.addBridge(address(tB));
        BlazePhoenixQuoter.Preview memory pv = _preview();
        assertEq(_inOf(pv, address(bad)), 0, "control: the 5% venue is no leg");
        assertGe(pv.netOut, alone, "control: output at least the 0.3% venue alone");
    }

    /// THE USER'S FLOOR DOES NOT HOLD IT: a floor taken from the preview (netOut, or netOut less a
    /// slippage tolerance) is computed on the same captured route, so the Router delivers the loss.
    function test_TheFloorFromThePreviewDeliversTheLoss() public {
        uint256 alone = _goodAlone();
        _venue(3000, L);
        _venue(100_000, L);
        hub.addBridge(address(tB));
        BlazePhoenixQuoter.Preview memory pv = _preview();
        tA.mint(address(this), AMOUNT_IN);
        tA.approve(address(router), AMOUNT_IN);
        uint256 minOut = pv.netOut * 9950 / 10_000;   // a 0.5% tolerance on the preview
        uint256 delivered = router.swapExactIn(pv.route, AMOUNT_IN, minOut, recipient, block.timestamp);
        emit log_named_uint("delivered", delivered);
        emit log_named_uint("0.3% venue alone (preview)", alone);
        assertGe(delivered, alone * 9950 / 10_000, "the floor from the preview let the loss through");
    }

    // A WRONG PRICE BEHIND A HIGH FEE. A 10% venue twice as deep as the 0.3% one (its mass sets the
    // base) holds a price p* under fair. Arbitrage between the two pays both fees, so the market at
    // rest leaves p* anywhere above (1 - 0.003)(1 - 0.1) = 0.8973: the edge of rest. The band
    // counts the base's fee once more above (BlazePhoenixMath, THE BAND), so the 0.3% venue falls
    // out only once p* < 0.8973 * 0.9 = 0.80757, more than 11.1% past the edge, where arbitrage
    // pays whoever closes it. With the base's fee counted once, the 0.3% venue fell out a hair past
    // the edge and the order went to the 10% venue (19.03% at 0.897, 19.84% at 0.888).

    /// Inside the edge (0.91): red before the fix (the base was the 10% venue's RATE, 0.819, and
    /// the fixed 5% band dropped the 0.3% venue at 0.997).
    function test_AFeeShieldedWrongPriceKeepsTheHonestVenue() public {
        _shielded(910e15);
    }

    /// A hair past the edge (0.897, 0.0334% under 0.8973).
    function test_AnAttackerAtTheEdgeOfRestKeepsTheHonestVenue() public {
        _shielded(897e15);
    }

    /// One percent past the edge (0.888, 1.0473% under 0.8973). The band read on RATES with the
    /// fees' width drops the 0.3% venue here: 0.997 * 0.8973 * 0.9 = 0.80515 > 0.888 * 0.9 = 0.7992.
    function test_AnAttackerOnePercentPastTheEdgeKeepsTheHonestVenue() public {
        _shielded(888e15);
    }

    function _shielded(uint256 pWad) internal {
        uint256 alone = _goodAlone();
        MockV3Pool good = _venue(3000, L);
        MockV3Pool bad = _venueAt(100_000, 2 * L, pWad);
        hub.addBridge(address(tB));
        BlazePhoenixQuoter.Preview memory pv = _preview();
        emit log_named_decimal_uint("price of the 10% venue, tB per tA", pWad, 18);
        emit log_named_uint("netOut, 0.3% venue alone", alone);
        emit log_named_uint("netOut, both venues", pv.netOut);
        emit log_named_uint("input routed to the 10% venue", _inOf(pv, address(bad)));
        assertEq(_inOf(pv, address(good)), AMOUNT_IN, "the 0.3% venue does not carry the order");
        assertGe(pv.netOut, alone, "a fee-shielded venue lowered the route's output");
    }

    // THE PROBE'S ERROR WIDENS THE BAND (BlazePhoenixCore.universalProbe, THE BOUND). Two venues
    // at price 1 behind 0.01%, of liquidity 1e19 and 5e18. The probe, a hundredth of the order,
    // reads each under the price by its own impact: the shallow venue about 0.2%, the deep one
    // about 0.1%. The gap, 0.1%, is five times the two fees, and the band crosses it only through
    // the two probes' error bounds e (their impact terms, about 0.2% and 0.1%). Mutant [979] (the
    // Solver packs the fee without e): the band is the two fees alone, the shallow venue falls out
    // below the deep base, and the order pays the deep venue's impact alone.

    function test_AShallowVenueAtTheSamePriceKeepsItsShare() public {
        uint256 alone = _alone(100, 1e19);
        _venue(100, 1e19);
        MockV3Pool shallow = _venue(100, 5e18);
        hub.addBridge(address(tB));
        BlazePhoenixQuoter.Preview memory pv = _preview();
        emit log_named_uint("netOut, the deep venue alone", alone);
        emit log_named_uint("netOut, both venues", pv.netOut);
        emit log_named_uint("input routed to the shallow venue", _inOf(pv, address(shallow)));
        assertGt(_inOf(pv, address(shallow)), 0, "the shallow venue at the same price is no leg");
        assertGt(pv.netOut, alone * 101 / 100, "the shallow venue added under 1% to the output");
    }

    /// A venue at price `pWad` (tB per tA, WAD), liquidity `l`, holding 3l of each token (more than
    /// its virtual reserves at any price used here, so its vote is its declared depth).
    function _venueAt(uint24 fee, uint128 l, uint256 pWad) internal returns (MockV3Pool p) {
        p = new MockV3Pool(address(tA), address(tB), fee);
        // The mock sorts its tokens: sqrtPriceX96 is sqrt(token1 per token0) in Q96.
        uint256 sq = address(tA) < address(tB)
            ? _sqrt(((uint256(1) << 192) / 1e18) * pWad)
            : _sqrt(((uint256(1) << 192) / pWad) * 1e18);
        p.setState(uint160(sq), l);
        tA.mint(address(p), 3 * uint256(l));
        tB.mint(address(p), 3 * uint256(l));
        Origin.wire(hub, address(p), address(tA), address(tB), BPC.KIND_V3, fee);
        hub.seedPool(address(p), BPC.KIND_V3, fee, address(0), address(tA), address(tB));
    }

    function _sqrt(uint256 x) internal pure returns (uint256 y) {
        y = x;
        uint256 z = (x + 1) / 2;
        while (z < y) { y = z; z = (x / z + z) / 2; }
    }
}
