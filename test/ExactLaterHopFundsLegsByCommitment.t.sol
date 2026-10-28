// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// Q773 (transplant 2, 2026-10-27): the exact door funds a LATER hop's legs as the Router does.
// From hop 1 on, the Router splits what arrived over the legs in proportion to the hop
// commitment, `Σ leg.amountIn` (`_hopScaleImpactAndQuote`: `quotedIn = _legSum(hop)`), and never
// reads `hop.amountIn`. `Quoter._exact` divided by `hop.amountIn` instead, so a route built
// off-chain whose later hop declares a figure other than its legs' sum was priced on legs the
// Router never funds: at twice the sum, each leg was priced at half its real input and the exact
// scalar fell to about half of delivery. `_fundedOut` and the Router already read the sum; the
// change is the divisor at hops >= 1 only. Hop 0 is untouched (its cap and divisor are the
// committed `hop.amountIn`; T04, put to the owner). Red at the commit before this file.
import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixQuoter} from "../src/BlazePhoenixQuoter.sol";
import {BlazePhoenixCore as BPC, Route, RoutePlan} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";
import {Origin} from "./mocks/MockOriginFactory.sol";

contract ExactLaterHopFundsLegsByCommitmentTest is Test {
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

    /// @notice The hop commitment (`Σ leg.amountIn`) is the divisor at a later hop: the legs the
    ///         exact door prices are the legs the Router funds, whatever `hop.amountIn` declares,
    ///         and the exact scalar is the Router's delivery, not half of it.
    function test_LaterHopCommitmentFundsTheLegsTheRouterFunds() public {
        RoutePlan memory plan = solver.findBestRoutePlan(address(tA), address(tC), AMOUNT_IN);
        Route memory route = plan.best;
        assertEq(route.hops.length, 2, "premise: a two-hop route through the bridge");
        uint256 legSum1;
        for (uint256 l; l < route.hops[1].legs.length; l++) legSum1 += route.hops[1].legs[l].amountIn;
        assertGt(legSum1, 0, "premise: hop 1 commits something");
        // Built off-chain: hop 1 declares twice what its legs commit. The Router never reads it.
        route.hops[1].amountIn = 2 * legSum1;

        (Route memory back, uint256 exactOut) = quoter.previewRouteExact(route, AMOUNT_IN);
        uint256 funded1;
        for (uint256 l; l < back.hops[1].legs.length; l++) funded1 += back.hops[1].legs[l].amountIn;
        // One leg per hop here, so the pro-rata split has no rounding: the leg is funded with
        // the whole of what reached hop 1 after the fee, as the Router funds it.
        assertEq(funded1, back.hops[1].amountIn,
            "hop 1's legs are funded with what reached the hop, pro rata to the commitment");

        uint256 before = tC.balanceOf(user);
        uint256 deadline = block.timestamp;
        vm.prank(user);
        router.swapExactIn(route, AMOUNT_IN, 1, user, deadline);
        uint256 delivered = tC.balanceOf(user) - before;
        assertGt(delivered, 0, "control: the Router fills the route");
        assertLe(exactOut, delivered, "exactOut is a floor the Router honours in this block");
        assertEq(exactOut, delivered, "and the floor is the delivery, not a fraction of it");
    }
}
