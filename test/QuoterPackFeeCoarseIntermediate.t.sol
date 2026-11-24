// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// PROPERTY (an accepted limit, docs/KNOWN_ISSUES.md): on a route that pays the fee at every hop
// (no hop's input is a registered bridge: the exhaustion calendar) with a COARSE token between the
// hops, the view preview's `netOut` (`Quoter._pack`) can sit above the Router's delivery, but by
// less than two units of that token, valued at the plan's own rate on hop 1:
//
//     netOut - delivered < (2 - PROTOCOL_FEE_BPS / BPS) * grossOut / b1 + 1
//
// with `b1` hop 1's commitment (the sum of its legs' `amountIn`) and `grossOut` the route's quoted
// output.
//
// DERIVATION. `_pack` scales grossOut A by r = p0 (b1 - f1) / b1, p0 = (b0 - f0) / b0, f the
// Router's rounded-up fee on each hop's commitment, each step rounded down: netOut <= A r. The
// Router charges hop 1 on what ARRIVED (`_owned`, measured): b1' = floor(Out0(b0 - f0)), and it
// trades y = b1' - ceil(28 b1' / 1e4) > 0.9972 b1' - 1. Out0 is concave through the origin and the
// plan commits b1 <= Out0(b0), so Out0(b0 - f0) >= p0 b1 and b1' > p0 b1 - 1; and
// p0 (b1 - f1) <= 0.9972 p0 b1. So the traded input falls short of b1 r by less than
// 0.9972 + 1 units: the arrival floors one unit (less the 28 bps the fee would have taken of it)
// and the fee's round-up takes at most one more. Out1 is concave through the origin and y <= b1,
// so delivered = floor(Out1(y)) > (A / b1) y - 1, hence netOut - delivered < (A / b1)(b1 r - y) + 1.
//
// WHY IT STAYS: the overshoot fails closed. The Router enforces the caller's minimum, so a minimum
// set from this `netOut` reverts (RouterE(5)) and no one loses funds; and the regime is reachable
// only on a route the caller writes, or with a bridge removed between the plan and the preview
// (every multi-hop plan of the Solver is anchored). Reading each later hop in its arrival units
// instead loses up to one coarse unit of the intermediate and previews `canExecute = false` on
// routes the Router fills (measured: below ~27 units of the intermediate in this shape).
//
// MEASURED at 8b76ca3 on these 28 rows: 9 preview above the delivery (sizes 200, 357, 358 and 359
// units at both prices, and 1e9 units at 1e16); the widest is 200 units at 1e18 per unit, netOut
// 196853263199960943720 against a delivery of 196408999999961423504 (+0.226 %, under half a unit).
//
// Shape: fine -> coarse -> fine, the coarse token a bridge when the Solver plans (so the plan has
// two hops) and removed before the preview, so both the preview and the Router meet the calendar
// that charges every hop.

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixQuoter} from "../src/BlazePhoenixQuoter.sol";
import {BlazePhoenixCore as BPC, Route} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";

contract QuoterPackFeeCoarseIntermediateTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    BlazePhoenixRouter router;
    BlazePhoenixQuoter quoter;
    MockERC20 fineIn;
    MockERC20 mid; // the coarse token between the hops
    MockERC20 fineOut;
    address recipient = makeAddr("recipient");

    uint256 constant DEEP = 1e33; // fits uint112 (5.19e33)

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        fineIn = new MockERC20("I", "I");
        mid = new MockERC20("M", "M");
        fineOut = new MockERC20("O", "O");
        solver = new BlazePhoenixSolver(address(hub), address(0));
        router = new BlazePhoenixRouter(address(hub), address(solver), address(this), makeAddr("t1"), makeAddr("t2"));
        hub.setRoles(address(router), address(0), address(0)); // seat the Router: the preview asks it whether it takes swaps
        quoter = new BlazePhoenixQuoter(address(hub), address(solver));
    }

    function _pair(MockERC20 x, MockERC20 y, uint256 rx, uint256 ry) internal {
        MockV2Pair p = new MockV2Pair(address(x), address(y));
        x.mint(address(p), rx);
        y.mint(address(p), ry);
        if (p.token0() == address(x)) p.setReserves(uint112(rx), uint112(ry));
        else p.setReserves(uint112(ry), uint112(rx));
        hub.seedPool(address(p), BPC.KIND_V2, 30, address(0), address(x), address(y));
    }

    /// @dev One coarse wei is worth `perMid` fine wei on both sides. No contract reads
    ///      `decimals()` on this path, so the price is the whole model of a coarse token.
    function _build(uint256 perMid) internal {
        uint256 rMid = DEEP / perMid;
        _pair(fineIn, mid, DEEP, rMid);
        _pair(mid, fineOut, rMid, DEEP);
        hub.addBridge(address(mid));
    }

    /// @dev The Solver's two-hop plan, previewed again once the bridge is gone: the same route
    ///      under the calendar that charges every hop. `planned` is false when the Solver did
    ///      not plan two hops.
    function _preview(uint256 amountIn) internal returns (BlazePhoenixQuoter.Preview memory pv, bool planned) {
        (pv,,) = quoter.previewPlan(address(fineIn), address(fineOut), amountIn);
        if (pv.route.hops.length != 2) return (pv, false);
        hub.removeBridge(0);
        pv = quoter.previewRoute(pv.route, 0);
        planned = true;
    }

    function _deliver(Route memory route, uint256 amountIn) internal returns (uint256 out) {
        fineIn.mint(address(this), amountIn);
        fineIn.approve(address(router), amountIn);
        out = router.swapExactIn(route, amountIn, 1, recipient, block.timestamp + 1);
    }

    /// @dev The derived bound, from the plan's own figures (never from `_pack`): two units of the
    ///      intermediate less the fee's 28 bps of one, at hop 1's rate grossOut / b1, rounded up,
    ///      plus the delivery's rounding wei.
    function _twoIntermediateUnits(Route memory route, uint256 grossOut) internal pure returns (uint256) {
        uint256 b1;
        for (uint256 i; i < route.hops[1].legs.length; ++i) b1 += route.hops[1].legs[i].amountIn;
        uint256 num = grossOut * (2 * BPC.BPS - BPC.PROTOCOL_FEE_BPS);
        uint256 den = b1 * BPC.BPS;
        return (num + den - 1) / den + 1;
    }

    function deliverExt(Route calldata route, uint256 amountIn) external returns (uint256) {
        require(msg.sender == address(this));
        return _deliver(route, amountIn);
    }

    /// 2 prices of the coarse unit x 14 sizes (in units of it): the dust the fee eats (2), the
    /// coarse sizes where the fee rounds up a whole unit (3..359, across the 357/358 step), and
    /// the sizes where one unit is a rounding error (1e3..1e9). A route the Router refuses
    /// delivers 0 and is held to the same bound; that the preview also says `cannot` there is
    /// asked once every row has met the bound.
    function test_Exhaustion_CoarseIntermediate_NetOutAboveDeliveryByUnderTwoIntermediateUnits() public {
        uint256[2] memory perMids = [uint256(1e18), 1e16];
        uint256[14] memory ks =
            [uint256(2), 3, 10, 50, 100, 101, 200, 357, 358, 359, 1000, 10000, 1000000, 1000000000];
        uint256 refused;
        uint256 refusedButPreviewed;
        for (uint256 p; p < perMids.length; ++p) {
            for (uint256 i; i < ks.length; ++i) {
                uint256 snap = vm.snapshotState();
                uint256 amountIn = ks[i] * perMids[p];
                _build(perMids[p]);
                (BlazePhoenixQuoter.Preview memory pv, bool planned) = _preview(amountIn);
                assertTrue(planned, "the Solver plans two hops through the coarse bridge");
                uint256 delivered;
                try this.deliverExt(pv.route, amountIn) returns (uint256 out) {
                    delivered = out;
                } catch (bytes memory err) {
                    // The fee eats hop 1's arrival (1 unit arrives, 1 is charged).
                    assertEq(err, abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, 8), "refused by RouterE(8)");
                    ++refused;
                    if (pv.canExecute || pv.netOut != 0) ++refusedButPreviewed;
                }
                assertLe(
                    pv.netOut,
                    delivered + _twoIntermediateUnits(pv.route, pv.grossOut),
                    "netOut exceeds the delivery by two units of the coarse intermediate"
                );
                vm.revertToState(snap);
            }
        }
        assertEq(refused, 2, "the dust row (2 units) is refused at both prices");
        assertEq(refusedButPreviewed, 0, "a route the Router refuses previews cannot, netOut 0");
    }
}
