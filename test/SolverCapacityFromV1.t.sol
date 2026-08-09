// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// Ported from Blaze-Phoenix-Dex (V1) test/SolverCapacity.t.sol — only the scenario this repo's
// own BlazePhoenixSolver.t.sol doesn't already cover under "Capacity clamp — two-tier
// MAX_CONC_DRAIN_BPS doctrine": that file's two tests (AggressiveButPossible, PhantomPromise)
// are both SINGLE-leg. V1 additionally covered a SPLIT route across three thin pools, where the
// phantom-capacity tier must bind per-leg and the route must therefore commit STRICTLY less than
// the order (the unrouted remainder is the Router's residual-sweep job, not the Solver's).
//
// Field motivation (from V1, still true here — same MAX_CONC_DRAIN_BPS doctrine): a Base
// USDC->USDS route once sent 89% of a $10k order into a pool holding only $6.2k of tokenOut —
// the raw quote exceeded the pool's WHOLE holdings, a phantom promise. The clamp exists so
// capital follows the (capped) promise instead of over-committing into a pool that cannot pay it.
//
// forge test --match-contract SolverCapacityFromV1 -vv

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixCore as BPC, Leg, RoutePlan} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV3Pool} from "./mocks/MockV3Pool.sol";

contract SolverCapacityFromV1Test is Test {
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    MockERC20 tokenA;
    MockERC20 tokenB;

    uint256 constant ORDER = 10_000e18;
    uint128 constant DEEP_L = 1e26; // deep liquidity: raw quote is ~1:1, the over-promising shape

    // Field-case holdings shape (sum 9.7k < order 10k) — thin enough that each leg's raw share
    // of a 10k order quotes well past that pool's own whole holdings.
    uint256 constant BAL_0 = 1_600e18;
    uint256 constant BAL_1 = 6_200e18;
    uint256 constant BAL_2 = 1_900e18;

    function setUp() public {
        hub = new BlazePhoenixHub();
        hub.initialize(address(this), address(0));
        solver = new BlazePhoenixSolver(address(hub));
        tokenA = new MockERC20("A", "A");
        tokenB = new MockERC20("B", "B");
    }

    function _seedV3(uint256 realHoldingsOfB) internal returns (MockV3Pool p) {
        p = new MockV3Pool(address(tokenA), address(tokenB), 100);
        p.setState(uint160(BPC.Q96), DEEP_L);
        tokenB.mint(address(p), realHoldingsOfB);
        hub.seedPool(address(p), BPC.KIND_V3, 100, address(0), address(tokenA), address(tokenB));
    }

    /// Split path, phantom tier: three thin pools, order >> combined holdings. Every leg's
    /// promise must respect its own pool's 30% cap, and because capacity binds, the route must
    /// commit strictly less than the full order (unlike a healthy route, which always commits
    /// the full order — see test_CapacityClamp_AggressiveButPossible_CapsPromiseOnly).
    function test_Split_CapitalFollowsPromiseAcrossThreeThinPools() public {
        _seedV3(BAL_0);
        _seedV3(BAL_1);
        _seedV3(BAL_2);

        RoutePlan memory plan = solver.findBestRoutePlan(address(tokenA), address(tokenB), ORDER);
        assertEq(plan.best.hops.length, 1, "expected a 1-hop route");
        Leg[] memory legs = plan.best.hops[0].legs;
        assertGt(legs.length, 0, "expected at least one leg");

        uint256 sumIn;
        uint256 sumOut;
        for (uint256 i; i < legs.length; ++i) {
            uint256 bal = tokenB.balanceOf(legs[i].pool);
            // INV-CAP-1: promise never exceeds 30% of that pool's real holdings.
            assertLe(legs[i].expectedOut, BPC.mulDiv(bal, 3_000, BPC.BPS) + 1,
                "leg promise exceeds its pool's 30% capacity cap");
            // INV-CAP-2: committed input can never buy more than the pool holds (price ~1 here,
            // +2% slack for fee/impact/rounding).
            assertLe(legs[i].amountIn, (bal * 102) / 100,
                "committed input exceeds this pool's physical holdings");
            sumIn += legs[i].amountIn;
            sumOut += legs[i].expectedOut;
        }
        // INV-CAP-3 (phantom tier): capacity binds on every leg, so the route must commit
        // strictly less than the order — the unrouted remainder is the Router sweep's job.
        assertLt(sumIn, ORDER, "full order committed past phantom capacity on every leg");
        assertEq(plan.best.hops[0].expectedOut, sumOut, "hop promise must equal the sum of leg promises");
    }
}
