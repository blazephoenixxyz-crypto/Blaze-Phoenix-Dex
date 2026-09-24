// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  A NATIVE V4 LEG ATTESTS WHAT ITS OWN NATIVE POOL PAYS.
//
//  The planner quotes a native V4 candidate on its real currencies - the wrapped
//  side substituted by address(0) before the pool id is derived - and the Router
//  executes it the same way. The separate promise layer (#74) re-derived the pool
//  from the leg's WETH-canonical fields without that substitution: it read an
//  empty WETH-including pool, found no promise, and left the leg at the unclamped
//  figure, so a thin native range was attested at the model's capacity and the
//  Router refused the plan its own preview endorsed (ninth wave, dex-20). Since
//  the walk the attestation IS the planner's quote of the native pool; there is
//  no second derivation to miss it.
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixQuoter} from "../src/BlazePhoenixQuoter.sol";
import {BlazePhoenixCore as BPC, Leg, RoutePlan} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV4TickManager} from "./mocks/MockV4TickManager.sol";
import {MockWETH9} from "./RouterV4NativeEth.t.sol";

contract V4NativeLegAttestsItsOwnPoolTest is Test {
    MockV4TickManager mgr;
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    BlazePhoenixRouter router;
    MockWETH9 weth;
    MockERC20 tok;

    address user = address(0xBEEF);
    uint24 constant FEE = 3000;
    int24  constant TS  = 60;
    uint256 constant AMT = 1e18;
    bytes32 pid;

    function setUp() public {
        mgr = new MockV4TickManager();
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(mgr));
        solver = new BlazePhoenixSolver(address(hub));
        router = new BlazePhoenixRouter(address(hub), address(solver), address(this), address(0xFEE1), address(0xFEE2));
        BlazePhoenixQuoter quoter = new BlazePhoenixQuoter(address(hub), address(solver));
        hub.setRoles(address(router), address(solver), address(quoter));
        weth = new MockWETH9();
        router.setWeth(address(weth));
        tok = new MockERC20("TOK", "TOK");

        // The NATIVE pool (address(0), tok): [0, 60) with the price at tick 59. The ETH side is
        // currency0, so WETH in swaps zeroForOne - 59 ticks of range below, nothing beyond.
        pid = BPC.computeV4PoolId(address(0), address(tok), FEE, TS, address(0));
        mgr.initialize(pid, mgr.sqrtAt(59), 59, FEE);
        mgr.addPosition(pid, 0, 60, TS, 1e18);
        hub.addV4(address(0), address(tok), FEE, TS, address(0));

        vm.deal(address(weth), 100e18);
        vm.deal(address(mgr), 100e18);
        tok.mint(address(mgr), 1e24);
        weth.mint(user, AMT);
        vm.prank(user);
        weth.approve(address(router), type(uint256).max);
    }

    /// What the native pool pays for `amt` of ETH in, from the specification's swap.
    function _pays(uint256 amt) internal view returns (uint256 out) {
        (, out, , , ) = mgr.specSwap(pid, amt, FEE, TS, true);
    }

    function test_ANativeLegAttestsWhatItsNativePoolPays() public {
        RoutePlan memory plan = solver.findBestRoutePlan(address(weth), address(tok), AMT);
        Leg memory lg = plan.best.hops[0].legs[0];
        assertEq(lg.kind, BPC.KIND_V4_NATIVE, "setup: the leg is the native pool's");
        uint256 pays = _pays(lg.amountIn);
        emit log_named_uint("attested      ", lg.expectedOut);
        emit log_named_uint("the pool pays ", pays);
        emit log_named_uint("floor         ", plan.best.singleOutFloor);
        assertApproxEqAbs(lg.expectedOut, pays, 4, "the native leg attests other than what its own pool pays");
        assertLe(plan.best.singleOutFloor, pays, "the published floor asks for more than the native pool pays");
    }

    function test_ANativeRouteThePlannerEmitsSettles() public {
        RoutePlan memory plan = solver.findBestRoutePlan(address(weth), address(tok), AMT);
        uint256 before = tok.balanceOf(user);
        vm.prank(user);
        router.swapExactIn(plan.best, AMT, 1, user, block.timestamp + 1);
        assertGt(tok.balanceOf(user) - before, 0, "the native route did not deliver");
    }
}
