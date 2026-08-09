// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  Issue #1 — "Router's uniform hop input rescaling silently undoes the Solver's
//  input-side capacity clamp" (reported by NetGakarot / Gakarot). Severity: High.
//
//  ROOT CAUSE (meta-invariant view): a hop carried TWO sources of truth for how
//  much it spends — the declared field `hop.amountIn`, and the computed
//  Σ leg.amountIn. The phantom-tier clamp cut the legs but left hop.amountIn at
//  the caller's full order, and the Router's rescale trusted the caller's full
//  transfer (realIn) over the committed legs, reconstructing the pre-cut order
//  and force-feeding a thin pool.
//
//  THE FIX collapses the two truths into one invariant, enforced at the boundary
//  (BlazePhoenixRouter._execute):
//
//      a hop never spends more than its legs committed
//          Σ executed.amountIn  ≤  Σ leg.amountIn          (on the user-funded hop)
//
//  and makes the Solver report hop.amountIn == Σ leg.amountIn so nothing off-chain
//  is misled. The uncommitted remainder is returned by the existing residual
//  sweep. Fee-on-transfer is untouched: there realIn < Σ leg.amountIn, so the cap
//  never fires and the pre-existing scale-DOWN still applies.
//
//  These tests fail on the pre-fix code (force-feed / revert) and pass on the fix.
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {
    BlazePhoenixCore as BPC,
    Route, Hop, Leg, RoutePlan
} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV3Pool} from "./mocks/MockV3Pool.sol";

contract RouterUndoesSolverCapacityClampTest is Test {
    BlazePhoenixHub    hub;
    BlazePhoenixSolver solver;
    BlazePhoenixRouter router;
    MockERC20 tokenA; // tokenIn
    MockERC20 tokenB; // tokenOut

    address treasury1 = address(0xFEE1);
    address treasury2 = address(0xFEE2);
    address user      = address(0xBEEF);

    uint128 constant DEEP_L         = 1e26;      // deep L → ~1:1 quote at this price
    uint256 constant ORDER          = 50_000e18; // the caller's full exact-in order
    uint256 constant POOL_HOLDING_B = 1_000e18;  // the pool's WHOLE real tokenB balance

    function setUp() public {
        hub = new BlazePhoenixHub();
        hub.initialize(address(this), address(0));
        tokenA = new MockERC20("A", "A");
        tokenB = new MockERC20("B", "B");
        solver = new BlazePhoenixSolver(address(hub));
        router = new BlazePhoenixRouter(
            address(hub), address(solver), address(this), treasury1, treasury2
        );
        tokenA.mint(user, ORDER);
        vm.prank(user);
        tokenA.approve(address(router), type(uint256).max);
    }

    function _seedThinV3() internal returns (MockV3Pool p) {
        p = new MockV3Pool(address(tokenA), address(tokenB), 100);
        p.setState(uint160(BPC.Q96), DEEP_L);
        tokenB.mint(address(p), POOL_HOLDING_B);
        hub.seedPool(address(p), BPC.KIND_V3, 100, address(0), address(tokenA), address(tokenB));
    }

    /// The Solver still enters the phantom-tier clamp (cuts the leg, caps the
    /// promise) — AND, post-fix, reports hop.amountIn == the committed leg, not
    /// the caller's full order. This is the meta-invariant at the plan boundary.
    function test_Solver_HopAmountIn_TracksCommittedLeg() public {
        _seedThinV3();
        RoutePlan memory plan = solver.findBestRoutePlan(address(tokenA), address(tokenB), ORDER);
        assertEq(plan.best.hops.length, 1, "single hop expected");
        Hop memory hop = plan.best.hops[0];
        assertEq(hop.legs.length, 1, "single leg expected");
        Leg memory leg = hop.legs[0];

        // The clamp fired: the committed input is well below the full order and
        // the promise is capped near 30% of the pool's real holdings.
        assertLt(leg.amountIn, ORDER, "phantom clamp must cut leg.amountIn");
        assertApproxEqRel(
            leg.expectedOut, BPC.mulDiv(POOL_HOLDING_B, 3_000, BPC.BPS), 0.02e18,
            "expectedOut capped at ~30% of real holdings"
        );

        // THE FIX: hop.amountIn is the committed truth, equal to Σ leg.amountIn —
        // NOT the caller's original ORDER (which is what the pre-fix code stored).
        assertEq(hop.amountIn, leg.amountIn, "hop.amountIn must equal the committed leg");
        assertLt(hop.amountIn, ORDER, "hop.amountIn must no longer report the uncut order");
    }

    /// End-to-end anti-force-feed: feeding the Solver's own route to the real
    /// Router must NOT reconstruct the full order into the thin pool. The pool
    /// receives at most the committed leg, and the caller gets the uncommitted
    /// remainder back — the exact behaviour the clamp was built to guarantee.
    function test_Router_ExecutesCutRoute_WithoutForceFeeding() public {
        MockV3Pool p = _seedThinV3();
        RoutePlan memory plan = solver.findBestRoutePlan(address(tokenA), address(tokenB), ORDER);
        Route memory route = plan.best;
        uint256 committed = route.hops[0].legs[0].amountIn;

        uint256 poolAbefore = tokenA.balanceOf(address(p));
        uint256 userAbefore = tokenA.balanceOf(user);

        vm.prank(user);
        router.swapExactIn(route, ORDER, 1, user, block.timestamp + 1);

        // The pool was fed at most what it committed to (~committed), NOT ORDER:
        // 166× force-feeding (the reported symptom) is gone.
        uint256 poolAin = tokenA.balanceOf(address(p)) - poolAbefore;
        assertLe(poolAin, committed + 1, "pool must not receive more than the committed leg");
        assertLt(poolAin, ORDER / 10, "pool must not be force-fed the full order");

        // The caller spent only the committed input; the rest was swept back.
        uint256 userAspent = userAbefore - tokenA.balanceOf(user);
        assertApproxEqAbs(userAspent, committed, 2, "caller spends only the committed input");
        assertGt(tokenB.balanceOf(user), 0, "caller receives the honest partial fill");
    }

    /// Permissiveness: fee-on-transfer tokenIn must still route. Here realIn
    /// (what the Router actually received) is LESS than the plan's committed sum,
    /// so the hop-0 cap never fires and the pre-existing scale-DOWN handles it —
    /// the swap succeeds and nothing reverts. (Deep, non-thin pool so no clamp.)
    function test_FeeOnTransfer_TokenIn_StillRoutes() public {
        // A deep pool that can pay the whole order — no phantom clamp here.
        MockV3Pool p = new MockV3Pool(address(tokenA), address(tokenB), 100);
        p.setState(uint160(BPC.Q96), DEEP_L);
        tokenB.mint(address(p), 1_000_000e18);
        hub.seedPool(address(p), BPC.KIND_V3, 100, address(0), address(tokenA), address(tokenB));

        tokenA.setFeeOnTransferBps(100); // 1% deflationary transfer

        uint256 amt = 1_000e18;
        RoutePlan memory plan = solver.findBestRoutePlan(address(tokenA), address(tokenB), amt);
        vm.prank(user);
        uint256 out = router.swapExactIn(plan.best, amt, 1, user, block.timestamp + 1);
        assertGt(out, 0, "fee-on-transfer swap must still deliver output");
    }
}
