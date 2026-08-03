// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { BlazePhoenixSolver } from "../src/BlazePhoenixSolver.sol";
import { PoolInfo, RoutePlan, Hop, Leg } from "../src/BlazePhoenixCore.sol";
import { MockERC20, MockV3Pool, MockHub } from "./mocks/Mocks.sol";

// =============================================================================
//  TWO-TIER CAPACITY CLAMP — capital is cut only for PHYSICALLY IMPOSSIBLE
//  promises; aggressive-but-possible fills keep their full commit.
//
//  Field case A (Base, USDC->USDS, $10k): the allocator sent 89% of the order
//  into a V3 pool holding only $6.2k of tokenOut — the quote exceeded the
//  pool's WHOLE holdings. The promise clamp crushed the number but the full
//  share still executed: -27% one-way, 7M gas, masked as "surplus". Quotes
//  past holdings are phantom by definition: the committed input must be cut.
//
//  Field case B (Base, USDC->SEAM, $10k): the quote exceeded the 30% cap but
//  NOT the holdings — and the pool filled the whole order at 43bps. Cutting
//  capital there degraded a healthy full fill into a half-filled order. Fills
//  that are aggressive but physically possible keep their full commit; only
//  the promise is capped.
//
//  Invariants pinned here:
//    INV-CAP-1  every concentrated leg's expectedOut <= 30% of the pool's
//               real tokenOut holdings (the promise clamp, both tiers)
//    INV-CAP-2  no leg commits input whose honest-rate output exceeds the
//               pool's WHOLE holdings (the phantom tier cuts capital)
//    INV-CAP-3  when phantom capacity binds, committed input sums to
//               STRICTLY less than the order (the residual is swept back to
//               the caller by the Router); when fills are merely aggressive,
//               the FULL order commits (the SEAM regression guard)
//
//    forge test --match-contract SolverCapacity -vv
// =============================================================================
contract SolverCapacityTest {
    uint256 constant Q96 = 0x1000000000000000000000000;
    uint256 constant ORDER = 10_000e18;
    // Deep L so the mock's probe impact is negligible (~0.01% at ORDER) and
    // the raw quote is ~1:1 — the over-promising shape the clamp exists for.
    uint128 constant DEEP_L = 1e26;

    address tokenA;
    address tokenB;

    // Field-case-A holdings shape (sum 9.7k < order 10k).
    uint256 constant BAL_0 = 1_600e18;
    uint256 constant BAL_1 = 6_200e18;
    uint256 constant BAL_2 = 1_900e18;

    function setUp() public {
        MockERC20 x = new MockERC20(18);
        MockERC20 y = new MockERC20(18);
        (tokenA, tokenB) = address(x) < address(y)
            ? (address(x), address(y))
            : (address(y), address(x));
    }

    function _req(bool c, string memory m) internal pure { require(c, m); }

    function _mkPool(MockHub hub, uint256 balOut) internal returns (address) {
        MockV3Pool p = new MockV3Pool(tokenA, tokenB, uint160(Q96), DEEP_L);
        MockERC20(tokenB).setBalance(address(p), balOut);
        hub.register(tokenA, tokenB, PoolInfo({
            active: true, stable: false, kind: 1 /*V3*/, fee: 100,
            tickSpacing: 60, token0: tokenA, token1: tokenB,
            pool: address(p), hooks: address(0)
        }), 1);
        return address(p);
    }

    /// Split path, phantom tier: three thin pools, order >> combined holdings.
    function test_capacity_split_capitalFollowsPromise() public {
        MockHub hub = new MockHub();
        _mkPool(hub, BAL_0);
        _mkPool(hub, BAL_1);
        _mkPool(hub, BAL_2);
        BlazePhoenixSolver solver = new BlazePhoenixSolver(address(hub));

        RoutePlan memory plan = solver.findBestRoutePlan(tokenA, tokenB, ORDER);
        _req(plan.best.hops.length == 1, "cap: expected a 1-hop route");
        Hop memory hop = plan.best.hops[0];
        _req(hop.legs.length >= 1, "cap: expected legs");

        uint256 sumIn;
        uint256 sumOut;
        for (uint256 i; i < hop.legs.length; ++i) {
            Leg memory leg = hop.legs[i];
            uint256 bal = MockERC20(tokenB).balanceOf(leg.pool);
            // INV-CAP-1: promise never exceeds 30% of real holdings.
            _req(leg.expectedOut <= (bal * 3_000) / 10_000 + 1, "cap: promise exceeds capacity");
            // INV-CAP-2: committed input can never buy more than the pool
            // holds (price ~1 here, +2% slack for fee/impact/rounding). The
            // old solver committed shares up to 2x a pool's whole holdings.
            _req(leg.amountIn <= (bal * 102) / 100,
                "cap: committed input exceeds physical holdings");
            sumIn  += leg.amountIn;
            sumOut += leg.expectedOut;
        }
        // INV-CAP-3 (phantom tier): capacity binds, so the route must commit
        // STRICTLY less than the order (old solver: sumIn == ORDER always).
        // The unrouted remainder is the Router sweep's job.
        _req(sumIn < ORDER, "cap: full order committed past phantom capacity");
        // The hop's promise is the sum of the leg promises.
        _req(hop.expectedOut == sumOut, "cap: hop promise != sum of leg promises");
    }

    /// Single-leg path, phantom tier: quote > holdings, input must be cut.
    function test_capacity_singleLeg_inputCut() public {
        MockHub hub = new MockHub();
        _mkPool(hub, BAL_1);
        BlazePhoenixSolver solver = new BlazePhoenixSolver(address(hub));

        RoutePlan memory plan = solver.findBestRoutePlan(tokenA, tokenB, ORDER);
        _req(plan.best.hops.length == 1, "cap1: expected a 1-hop route");
        Hop memory hop = plan.best.hops[0];
        _req(hop.legs.length == 1, "cap1: expected a single leg");

        uint256 cap = (BAL_1 * 3_000) / 10_000;
        _req(hop.legs[0].expectedOut <= cap + 1, "cap1: promise exceeds capacity");
        _req(hop.legs[0].amountIn < ORDER, "cap1: full order committed to a phantom pool");
        // Committed input commensurate with the cut promise (price ~1, +2%
        // slack for fee/impact/rounding).
        _req(hop.legs[0].amountIn <= (hop.legs[0].expectedOut * 102) / 100,
            "cap1: committed input not commensurate with promise");
    }

    /// Aggressive-but-possible tier (the SEAM regression guard): quote above
    /// the 30% cap but BELOW the holdings — the FULL order must commit and
    /// only the promise is capped. Cutting capital here is the regression the
    /// two-tier design exists to prevent.
    function test_capacity_aggressiveButPossible_fullCommit() public {
        MockHub hub = new MockHub();
        _mkPool(hub, 12_000e18); // order ~10k quote <= 12k holdings, > 3.6k cap
        BlazePhoenixSolver solver = new BlazePhoenixSolver(address(hub));

        RoutePlan memory plan = solver.findBestRoutePlan(tokenA, tokenB, ORDER);
        _req(plan.best.hops.length == 1, "agg: expected a 1-hop route");
        Hop memory hop = plan.best.hops[0];
        _req(hop.legs.length == 1, "agg: expected a single leg");
        _req(hop.legs[0].amountIn == ORDER, "agg: full order must commit");
        uint256 cap = (12_000e18 * 3_000) / 10_000;
        _req(hop.legs[0].expectedOut <= cap + 1, "agg: promise must be capped");
        _req(hop.legs[0].expectedOut >= (cap * 99) / 100, "agg: promise far below cap");
    }

    /// Deep pool control: holdings dwarf the order, neither tier may touch it.
    function test_capacity_deepPool_untouched() public {
        MockHub hub = new MockHub();
        _mkPool(hub, 10_000_000e18);
        BlazePhoenixSolver solver = new BlazePhoenixSolver(address(hub));

        RoutePlan memory plan = solver.findBestRoutePlan(tokenA, tokenB, ORDER);
        _req(plan.best.hops.length == 1, "deep: expected a 1-hop route");
        Hop memory hop = plan.best.hops[0];
        _req(hop.legs.length == 1, "deep: expected a single leg");
        _req(hop.legs[0].amountIn == ORDER, "deep: full order must commit");
        // ~1:1 promise minus the 1bp fee — nowhere near the 3M cap.
        _req(hop.legs[0].expectedOut > (ORDER * 99) / 100, "deep: promise off spot");
    }
}
