// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// T04 (2026-10-27): the exact door funds HOP 0's legs as the Router does. At hop 0 the Router
// takes the fee, when hop 0 pays on its input, as ceil(28 bps) of min(order, Σ leg.amountIn)
// (`_chargeHopFee`), then caps what is left at the legs' sum and splits it over the legs pro rata
// to that sum (`_hopScaleImpactAndQuote`: `quotedIn = _legSum(hop)`); `hop.amountIn` is never
// read. `Quoter._exact` capped and divided by the declared `hop.amountIn` and took the fee after
// the cap. Two shapes followed. A route built off-chain whose hop 0 declares less than its legs
// commit was priced at the legs' full size: on a direct route into a bridge, where `_fundedOut`
// does not bound the scalar (the fee is the output deduction), the exact door promised about
// twice what the Router fills, and the Router refused the route it returned (RouterE(5), even at
// userMinOut = 1). And an order above the commitment paid, in the quote, the fee out of the
// committed legs, where the Router takes it from the surplus: the scalar fell short of delivery.
// The fix is the Router's arithmetic at hop 0, in the Quoter only (the Router is unchanged).
// The later hops are Q773's (`ExactLaterHopFundsLegsByCommitment.t.sol`). Red at 3293d7f.
import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixQuoter} from "../src/BlazePhoenixQuoter.sol";
import {BlazePhoenixCore as BPC, Route, RoutePlan} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";
import {Origin} from "./mocks/MockOriginFactory.sol";

contract ExactHopZeroFundsLegsByCommitmentTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    BlazePhoenixQuoter quoter;
    BlazePhoenixRouter router;
    MockERC20 tA;
    MockERC20 tB;
    MockERC20 tC;
    address user = address(0x5E4);
    uint256 constant AMOUNT_IN = 1_000e18;
    uint112 constant RESERVE = 1_000_000e18;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0xBEEF));
        solver = new BlazePhoenixSolver(address(hub), address(0));
        quoter = new BlazePhoenixQuoter(address(hub), address(solver));
        router = new BlazePhoenixRouter(
            address(hub), address(solver), address(this), address(0x7451), address(0x7452)
        );
        tA = new MockERC20("A", "A");
        tB = new MockERC20("B", "B");
        tC = new MockERC20("C", "C");
        MockV2Pair ab = _pair(tA, tB);
        MockV2Pair bc = _pair(tB, tC);
        hub.setRoles(address(this), address(solver), address(quoter));
        _seed(ab, tA, tB);
        _seed(bc, tB, tC);
        hub.setRoles(address(router), address(solver), address(quoter));
        hub.addBridge(address(tB));
        tA.mint(user, 10_000e18);
        vm.prank(user);
        tA.approve(address(router), type(uint256).max);
    }

    function _pair(MockERC20 x, MockERC20 y) private returns (MockV2Pair p) {
        p = new MockV2Pair(address(x), address(y));
        Origin.wire(hub, address(p), address(x), address(y), BPC.KIND_V2, 30);
        x.mint(address(p), RESERVE);
        y.mint(address(p), RESERVE);
        p.setReserves(RESERVE, RESERVE);
    }

    function _seed(MockV2Pair p, MockERC20 x, MockERC20 y) private {
        for (uint256 i; i < 5; i++) {
            hub.recordSwap(address(p), BPC.KIND_V2, 30, address(0),
                address(x), address(y), 1e18, 1e18, RESERVE);
        }
    }

    /// @notice Hop 0's commitment (`Σ leg.amountIn`) is its cap and divisor: a direct route into
    ///         a bridge whose hop 0 declares half its legs' sum is priced on the legs the Router
    ///         funds, the Router fills the route the exact door returns, and the scalar is the
    ///         delivery, not twice it.
    function test_HopZeroCommitmentFundsTheLegsTheRouterFunds() public {
        RoutePlan memory plan = solver.findBestRoutePlan(address(tA), address(tB), AMOUNT_IN);
        Route memory route = plan.best;
        assertEq(route.hops.length, 1, "premise: a direct route");
        assertTrue(hub.isBridgeToken(address(tB)), "premise: into a bridge, the fee comes off the output");
        assertEq(route.hops[0].legs.length, 1, "premise: one leg, so the pro-rata split has no rounding");
        uint256 legSum0 = route.hops[0].legs[0].amountIn;
        assertGt(legSum0, 0, "premise: hop 0 commits something");
        // Built off-chain: hop 0 declares, and the order brings, half of what its legs commit.
        uint256 order = legSum0 / 2;
        route.hops[0].amountIn = order;
        (Route memory back, uint256 exactOut) = quoter.previewRouteExact(route, order);
        // The Router funds hop 0's legs with min(order, Σ leg.amountIn), split by the sum.
        assertEq(back.hops[0].legs[0].amountIn, order,
            "hop 0's leg is funded with what the Router funds, not the legs' full commitment");
        uint256 before = tB.balanceOf(user);
        uint256 deadline = block.timestamp;
        vm.prank(user);
        router.swapExactIn(back, order, exactOut, user, deadline);
        uint256 delivered = tB.balanceOf(user) - before;
        assertGt(delivered, 0, "control: the Router fills the route the exact door returned");
        assertEq(exactOut, delivered, "the exact scalar is the delivery, not twice it");
    }

    /// @notice Hop 0's fee is taken as the Router takes it, before the cap and on
    ///         min(order, Σ leg.amountIn): an order above the commitment pays the fee out of the
    ///         surplus, the legs keep what the Router leaves them, and the scalar is the delivery.
    function test_HopZeroFeeIsTakenBeforeTheCapAsTheRouterTakesIt() public {
        // Hop 0's input is a bridge too: the fee anchors on hop 0 and is paid on its input.
        hub.addBridge(address(tA));
        RoutePlan memory plan = solver.findBestRoutePlan(address(tA), address(tC), AMOUNT_IN);
        Route memory route = plan.best;
        assertEq(route.hops.length, 2, "premise: a two-hop route through the bridge");
        (uint256 feeHop, bool feeOnOut) = quoter.feeCalendarOf(route.hops, address(tC));
        assertEq(feeHop, 0, "premise: hop 0's input is the first bridge, so hop 0 pays on its input");
        assertFalse(feeOnOut, "premise: not a direct route into a bridge");
        assertEq(route.hops[0].legs.length, 1, "premise: one leg, so the pro-rata split has no rounding");
        uint256 legSum0 = route.hops[0].legs[0].amountIn;
        // The Router's charge at hop 0: ceil(28 bps) of min(order, Σ leg.amountIn).
        uint256 fee0 = (legSum0 * BPC.PROTOCOL_FEE_BPS + BPC.BPS - 1) / BPC.BPS;
        assertGt(fee0, 1, "premise: a fee of more than one wei");
        // The order exceeds the commitment by less than the fee: the Router charges the fee on
        // the commitment and leaves the legs order - fee0, under their sum.
        uint256 order = legSum0 + fee0 / 2;
        (Route memory back, uint256 exactOut) = quoter.previewRouteExact(route, order);
        assertEq(back.hops[0].legs[0].amountIn, order - fee0,
            "hop 0's leg is funded with what the Router leaves it once the fee is taken");
        uint256 before = tC.balanceOf(user);
        uint256 deadline = block.timestamp;
        vm.prank(user);
        router.swapExactIn(route, order, 1, user, deadline);
        uint256 delivered = tC.balanceOf(user) - before;
        assertGt(delivered, 0, "control: the Router fills the route");
        assertLe(exactOut, delivered, "exactOut is a floor the Router honours in this block");
        assertEq(exactOut, delivered, "and the floor is the delivery, not the delivery less a fee");
    }
}
