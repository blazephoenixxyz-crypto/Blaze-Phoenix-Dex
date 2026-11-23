// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// PROPERTY: the view preview's `netOut` (`Quoter._pack`) never promises more than the Router
// delivers, at every size of the charged hop's input, including the coarse ones.
//
// The Router charges the protocol fee in the charged hop's INPUT token, rounded up
// (`Router._chargeHopFee`: feeH = mulDivUp(base, PROTOCOL_FEE_BPS, BPS), base = the hop's
// committed `_legSum` on hop 0). In coarse units (a 0-2 decimal token, or dust) the fee is a
// larger fraction of that base than the constant's 28 bps: base 100 pays 1, i.e. 100 bps. The
// preview took the fee as a fixed 28 bps of the OUTPUT, so its `netOut` sat above the delivery.
//
// RED at 9b2855e: one hop, no bridge, input worth 1e18 output wei per wei: amountIn 100 previews
// netOut ~ 99.42e18 and the Router delivers ~ 98.70e18 (fee 1 of 100). Every amountIn in
// 100..356 is red there; 357 and 358 are the round-up boundary (fee 1 -> 2 at 358).
// GREEN once `_pack` takes, at each hop the Router charges, the fee the Router takes from that
// hop's committed input, `mulDivUp(b, PROTOCOL_FEE_BPS, BPS)` over `b`, and scales the output by
// what is left (`(b - f) / b`, rounded down). A venue's output is concave in its input, so the
// proportional scale understates the delivery: the safe side.
//
// Decimals: no contract reads `decimals()` on this path (the fee and the venue math are in wei),
// so a token of `dec` decimals is modelled by its price: one input wei is worth 10^(18-dec)
// output wei. The domain of the fuzz is amountIn in [1, rIn / 100], so the Router fills.

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixQuoter} from "../src/BlazePhoenixQuoter.sol";
import {BlazePhoenixCore as BPC, Route} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";

contract QuoterPackFeeAtTheRoutersUnitsTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    BlazePhoenixRouter router;
    BlazePhoenixQuoter quoter;
    MockERC20 coarse; // the charged input
    MockERC20 bridge; // W
    MockERC20 fine;   // the output
    address recipient = makeAddr("recipient");

    uint256 constant DEEP = 1e33; // fits uint112 (5.19e33)

    // The four fee calendars of the fuzz.
    uint8 constant ONE_HOP_INPUT = 0;  // A -> B, no bridge: hop 0 pays on its input
    uint8 constant ONE_HOP_OUTPUT = 1; // A -> W, W a bridge: the fee comes off the output
    uint8 constant TWO_HOP_ANCHORED = 2; // A -> W -> B, W a bridge: hop 1 pays on its input
    uint8 constant TWO_HOP_EXHAUSTION = 3; // the same route, no bridge: both hops pay

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        coarse = new MockERC20("C", "C");
        bridge = new MockERC20("W", "W");
        fine = new MockERC20("F", "F");
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

    /// @dev The venues of `shape`, the coarse token worth 10^(18-dec) output wei per wei.
    ///      Returns the coarse reserve and the route's output token.
    function _build(uint8 shape, uint8 dec) internal returns (uint256 rIn, address tOut) {
        uint256 ratio = 10 ** (18 - uint256(dec));
        rIn = DEEP / ratio;
        if (shape == ONE_HOP_INPUT) {
            _pair(coarse, fine, rIn, DEEP);
            return (rIn, address(fine));
        }
        _pair(coarse, bridge, rIn, DEEP);
        hub.addBridge(address(bridge));
        if (shape == ONE_HOP_OUTPUT) return (rIn, address(bridge));
        _pair(bridge, fine, DEEP, DEEP);
        return (rIn, address(fine));
    }

    /// @dev The preview of `shape`'s route at `amountIn`, and the route itself. On exhaustion the
    ///      Solver's anchored route is planned first and the bridge is then removed, so the same
    ///      route meets the calendar that charges every hop, in the preview and in the Router.
    function _preview(uint8 shape, address tOut, uint256 amountIn)
        internal returns (BlazePhoenixQuoter.Preview memory pv)
    {
        (pv,,) = quoter.previewPlan(address(coarse), tOut, amountIn);
        if (shape == TWO_HOP_EXHAUSTION && pv.route.hops.length == 2) {
            hub.removeBridge(0);
            pv = quoter.previewRoute(pv.route, 0);
        }
    }

    function _deliver(Route memory route, uint256 amountIn) internal returns (uint256 out) {
        coarse.mint(address(this), amountIn);
        coarse.approve(address(router), amountIn);
        out = router.swapExactIn(route, amountIn, 1, recipient, block.timestamp + 1);
    }

    /// Whatever the preview endorses, the Router fills and delivers at least its netOut.
    function _assertNeverAbove(uint8 shape, uint8 dec, uint256 amountIn) internal {
        (, address tOut) = _build(shape, dec);
        BlazePhoenixQuoter.Preview memory pv = _preview(shape, tOut, amountIn);
        // Nothing promised: a preview that does not endorse the route (`canExecute`, which asks
        // `netOut >= effectiveMinOut`, the Router's own floor) makes no claim on the delivery.
        if (!pv.canExecute) return;
        uint256 out = _deliver(pv.route, amountIn);
        assertLe(pv.netOut, out, "preview netOut <= what the Router delivers");
    }

    function test_Pack_CoarseInput_NetOutNeverAboveDelivery() public {
        uint256[6] memory sizes = [uint256(1), 2, 100, 356, 357, 358];
        for (uint256 i; i < sizes.length; i++) {
            uint256 snap = vm.snapshotState();
            _assertNeverAbove(ONE_HOP_INPUT, 0, sizes[i]);
            vm.revertToState(snap);
        }
    }

    function testFuzz_Pack_NetOutNeverAboveDelivery(uint8 decSeed, uint256 amountIn, uint8 shape) public {
        uint8[4] memory decs = [uint8(0), 2, 6, 18];
        uint8 dec = decs[decSeed % 4];
        shape = shape % 4;
        uint256 rIn = DEEP / 10 ** (18 - uint256(dec));
        amountIn = bound(amountIn, 1, rIn / 100);
        _assertNeverAbove(shape, dec, amountIn);
    }

    /// CONTROL: where the fee is exactly 28 bps of the charged base (b a multiple of 2500), the
    /// input-side scale and today's output deduction are the same number, to the wei.
    function test_Control_18Decimals_NetOutUnchangedToTheWei() public {
        (, address tOut) = _build(ONE_HOP_INPUT, 18);
        uint256 amountIn = 1e18;
        BlazePhoenixQuoter.Preview memory pv = _preview(ONE_HOP_INPUT, tOut, amountIn);
        uint256 g = pv.route.totalOut;
        assertGt(g, 0, "the plan prices the hop");
        assertEq(pv.netOut, g - BPC.mulDivUp(g, BPC.PROTOCOL_FEE_BPS, BPC.BPS), "netOut == gross less 28 bps of it");
        assertLe(pv.netOut, _deliver(pv.route, amountIn), "and the Router delivers it");
    }

    /// A base the fee swallows whole (b = 1, fee 1) previews 0 (red at 9b2855e: ~0.994e18) and is refused by the
    /// Router with RouterE(8).
    function test_Pack_FeeEatsTheBase_NetOutZero() public {
        (, address tOut) = _build(ONE_HOP_INPUT, 0);
        BlazePhoenixQuoter.Preview memory pv = _preview(ONE_HOP_INPUT, tOut, 1);
        assertEq(pv.netOut, 0, "a hop the fee eats previews nothing");
        assertFalse(pv.canExecute, "and is not endorsed");
        assertEq(pv.route.hops.length, 1, "the Solver planned the hop: the zero is the fee's, not a missing route");
        Route memory route = pv.route;
        coarse.mint(address(this), 1);
        coarse.approve(address(router), 1);
        uint256 dl = block.timestamp + 1;
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, uint16(8)));
        router.swapExactIn(route, 1, 1, recipient, dl);
    }
}
