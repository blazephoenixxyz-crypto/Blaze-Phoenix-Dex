// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  N1 (fix-1019, matrix round E; email 3073): on a concentrated pool whose real
//  holdings are thin, the default preview's promise is cut by the Solver's
//  capacity clamp (MAX_CONC_DRAIN_BPS = 30 % of the pool's tokenOut balance,
//  Solver:822-847) while the capital share stays whole, so the Router delivers
//  close to the exact dry-run figure. Measured live: 24-31 % between
//  previewPlanWithMinOut and previewPlanExact on cbBTC>cbETH.
//
//  The property pinned here, in the clamp regime and outside it:
//      pv.netOut (default)  <=  exactOut (previewPlanExact)  <=  delivered
//  and exactOut is TIGHT against delivery (a floor, not a guess). The clamp
//  itself is pinned as by-design (Q1: an approximation rounds DOWN): red iff
//  the promise stops being capped, which is a design change, not a fix.
//
//  forge test --match-path test/Fix1019PreviewExactVsDefault.t.sol -vv
// =============================================================================

import {Test, console2} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixQuoter} from "../src/BlazePhoenixQuoter.sol";
import {BlazePhoenixCore as BPC, Route} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV3Pool} from "./mocks/MockV3Pool.sol";

abstract contract Fix1019N1Base is Test {
    BlazePhoenixHub    hub;
    BlazePhoenixSolver solver;
    BlazePhoenixRouter router;
    BlazePhoenixQuoter quoter;
    MockERC20 A;
    MockERC20 B;
    address user = address(0xBEEF);

    uint128 constant THIN_L    = 1e24;   // deep virtual liquidity: price impact ~0
    uint256 constant THIN_HOLD = 100e18; // ...on thin real holdings: the clamp reads these
    uint256 constant CAP       = 30e18;  // MAX_CONC_DRAIN_BPS (30 %) of THIN_HOLD

    function _core() internal {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        solver = new BlazePhoenixSolver(address(hub));
        router = new BlazePhoenixRouter(address(hub), address(solver), address(this), address(0xFEE1), address(0xFEE2));
        quoter = new BlazePhoenixQuoter(address(hub), address(solver));
        hub.setRoles(address(router), address(solver), address(quoter));
        A = new MockERC20("A", "A");
        B = new MockERC20("B", "B");
    }

    function _v3(address t0, address t1, uint128 L, address payToken, uint256 hold) internal returns (MockV3Pool p) {
        p = new MockV3Pool(t0, t1, 100);
        p.setState(uint160(BPC.Q96), L);
        MockERC20(payToken).mint(address(p), hold);
        hub.seedPool(address(p), BPC.KIND_V3, 100, address(0), t0, t1);
    }

    function _fund(uint256 amt) internal {
        A.mint(user, amt);
        vm.prank(user);
        A.approve(address(router), type(uint256).max);
    }

    function _swap(Route memory r, uint256 amt, uint256 minOut) internal returns (uint256 got) {
        uint256 before = B.balanceOf(user);
        vm.prank(user);
        got = router.swapExactIn(r, amt, minOut, user, block.timestamp + 1);
        assertEq(B.balanceOf(user) - before, got, "delivered to the recipient");
    }

    /// The property: default <= exact <= delivered, exact tight within `tightBps`.
    function _property(uint256 amt, uint256 tightBps) internal returns (uint256 net, uint256 exactOut, uint256 got) {
        (BlazePhoenixQuoter.Preview memory pv,,) = quoter.previewPlan(address(A), address(B), amt);
        Route memory rEx;
        (rEx, exactOut) = quoter.previewPlanExact(address(A), address(B), amt);
        net = pv.netOut;
        assertGt(net, 0, "setup: the default preview prices the route");
        assertLe(net, exactOut, "Q1: the default preview never promises more than the exact figure");
        _fund(amt);
        got = _swap(rEx, amt, exactOut); // userMinOut = exactOut: the floor the docstring offers
        assertGe(got, exactOut, "exactOut is a floor the Router honours");
        assertLe((got - exactOut) * 10_000, got * tightBps, "exactOut is tight against delivery");
        console2.log("default netOut:", net);
        console2.log("exactOut      :", exactOut);
        console2.log("delivered     :", got);
    }
}

/// One hop, A -> B, through a concentrated pool with thin real holdings.
contract Fix1019N1SingleHopTest is Fix1019N1Base {
    function setUp() public {
        _core();
        _v3(address(A), address(B), THIN_L, address(B), THIN_HOLD);
    }

    /// By-design pin (Q1). 40 % of holdings asked: cap < quote <= holdings, so the leg's
    /// promise is exactly the cap while the exact dry-run sees the whole fill. Red iff the
    /// capacity clamp stops capping the promise (Solver:847).
    function test_N1_Clamp_DefaultPromiseIsTheCap_ExactSeesTheFill() public {
        (BlazePhoenixQuoter.Preview memory pv,,) = quoter.previewPlan(address(A), address(B), 40e18);
        assertEq(pv.route.hops.length, 1, "setup: one hop");
        assertEq(pv.route.hops[0].legs.length, 1, "setup: one leg");
        assertEq(pv.route.hops[0].legs[0].expectedOut, CAP, "the promise is capped at 30 % of real holdings");
        (, uint256 exactOut) = quoter.previewPlanExact(address(A), address(B), 40e18);
        assertGt(exactOut * 10, pv.netOut * 12, "the exact figure sits > 20 % above the clamped default");
    }

    /// Property in the clamp regime: default <= exact <= delivered, exact within 5 bps.
    function test_N1_Clamp_DefaultLeExactLeDelivered() public {
        _property(40e18, 5);
    }

    /// The default route itself, signed at the exact figure, settles: the capital share
    /// was never cut, only the promise. Red iff the clamp starts cutting the share.
    function test_N1_Clamp_DefaultRouteDeliversTheExactFigure() public {
        (BlazePhoenixQuoter.Preview memory pv,,) = quoter.previewPlan(address(A), address(B), 40e18);
        (, uint256 exactOut) = quoter.previewPlanExact(address(A), address(B), 40e18);
        _fund(40e18);
        uint256 got = _swap(pv.route, 40e18, exactOut);
        assertGe(got, exactOut, "the default route delivers at least the exact figure");
    }

    /// Control: 5 % of holdings, below the cap. Default and exact agree within the safety
    /// buffer (<= 10 bps) plus rounding.
    function test_N1_NoClamp_DefaultAgreesWithExact() public {
        (uint256 net, uint256 exactOut,) = _property(5e18, 5);
        assertLe((exactOut - net) * 10_000, exactOut * 15, "below the cap the default is within 15 bps of exact");
    }

    /// forge-config: default.fuzz.runs = 64
    function testFuzz_N1_DefaultLeExactLeDelivered(uint256 amt) public {
        amt = bound(amt, 1e18, 90e18);
        _property(amt, 5);
    }
}

/// Two hops, A -> W -> B, W a bridge (the fee is charged on the anchor hop's input):
/// the first hop deep, the second the thin concentrated pool.
contract Fix1019N1TwoHopTest is Fix1019N1Base {
    MockERC20 W;

    function setUp() public {
        _core();
        W = new MockERC20("W", "W");
        hub.addBridge(address(W));
        _v3(address(A), address(W), 1e30, address(W), 1e30);
        _v3(address(W), address(B), THIN_L, address(B), THIN_HOLD);
    }

    /// Property through a bridge in the clamp regime.
    function test_N1_TwoHopClamp_DefaultLeExactLeDelivered() public {
        (BlazePhoenixQuoter.Preview memory pv,,) = quoter.previewPlan(address(A), address(B), 40e18);
        assertEq(pv.route.hops.length, 2, "setup: routed through the bridge");
        _property(40e18, 5);
    }

    /// forge-config: default.fuzz.runs = 64
    function testFuzz_N1_TwoHop_DefaultLeExactLeDelivered(uint256 amt) public {
        amt = bound(amt, 1e18, 90e18);
        _property(amt, 5);
    }
}

/// One hop split across TWO thin concentrated pools: the Solver's split path
/// (Solver:822-847), the shape measured live (a V3 leg beside a Solidly leg on
/// the clamped hop). A single pool takes the single-best path instead
/// (Solver:1406-1416), so the contract above never reaches this clamp.
contract Fix1019N1SplitHopTest is Fix1019N1Base {
    function setUp() public {
        _core();
        _v3(address(A), address(B), THIN_L, address(B), THIN_HOLD);
        _v3(address(A), address(B), THIN_L, address(B), THIN_HOLD);
    }

    /// By-design pin (Q1) on the split path: 80e18 over two pools of 100e18 holdings.
    /// Every leg's promise is at most the cap and at least one leg is capped exactly,
    /// while the exact dry-run sees the whole fill. Red iff the split clamp stops capping.
    function test_N1_SplitClamp_LegPromisesAreCapped_ExactSeesTheFill() public {
        (BlazePhoenixQuoter.Preview memory pv,,) = quoter.previewPlan(address(A), address(B), 80e18);
        assertEq(pv.route.hops.length, 1, "setup: one hop");
        assertEq(pv.route.hops[0].legs.length, 2, "setup: the hop is split over both pools");
        bool anyCapped;
        for (uint256 i; i < 2; ++i) {
            uint256 e = pv.route.hops[0].legs[i].expectedOut;
            assertLe(e, CAP, "no leg promises more than 30 % of its pool's holdings");
            if (e == CAP) anyCapped = true;
        }
        assertTrue(anyCapped, "at least one leg's promise is the cap itself");
        (, uint256 exactOut) = quoter.previewPlanExact(address(A), address(B), 80e18);
        assertGt(exactOut * 10, pv.netOut * 12, "the exact figure sits > 20 % above the clamped default");
    }

    /// Property on the split path: default <= exact <= delivered, exact within 5 bps.
    function test_N1_SplitClamp_DefaultLeExactLeDelivered() public {
        _property(80e18, 5);
    }
}

/// One hop INTO a bridge (B is a bridge): the only single-hop shape whose protocol fee
/// the Router takes off the OUTPUT, so the only one where previewPlanExact's output
/// deduction (Quoter:691) is not shadowed by `_fundedOut` pricing a fee-reduced input.
contract Fix1019N1IntoBridgeTest is Fix1019N1Base {
    function setUp() public {
        _core();
        hub.addBridge(address(B));
        _v3(address(A), address(B), THIN_L, address(B), THIN_HOLD);
    }

    /// Property, clamp regime, fee on the output: default <= exact <= delivered, 5 bps.
    function test_N1_IntoBridge_DefaultLeExactLeDelivered() public {
        _property(40e18, 5);
    }

    /// Control below the cap, fee on the output.
    function test_N1_IntoBridge_NoClamp_DefaultLeExactLeDelivered() public {
        _property(5e18, 5);
    }
}
