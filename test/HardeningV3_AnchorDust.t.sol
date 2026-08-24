// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  V3 / BP-18 — the V4 pseudo-address dust anchor.
//
//  A V4 pool's registry address is the truncated poolId: a CODELESS pseudo-
//  address that custodies nothing (tokens live in the PoolManager singleton).
//  Anyone can transfer 1 wei of tokenOut to that address, and before the fix
//  Solver._buildHop read the CAPITAL ANCHOR from `balanceOf(tokenOut, pool)`
//  for every kind — so in a V4-only candidate set the dusted pool became the
//  only candidate with balsOut > 0, its (attacker-chosen) rate became the band
//  base, and the honest deep pool was filtered out as the "outlier".
//
//  The fix forces balsOut = 0 for KIND_V4 / KIND_V4_NATIVE, so the anchor is
//  sourced only from kinds that really custody tokens; a V4-only set anchors
//  on the DEEPEST candidate by measured PoolManager liquidity instead.
//
//  This suite registers a V4-only candidate set (honest deep pool at the true
//  rate vs a thin pool quoting ~4x), dusts the thin pool's pseudo-address,
//  and asserts the plan still routes to the honest venue at the honest rate:
//
//    (1) control — no dust: the depth anchor selects the honest deep pool;
//    (2) 1 wei of tokenOut on the stale pool's pseudo-address: the dust must
//        NOT forge the anchor — same honest route, same honest quote;
//    (3) a LARGE parked balance on the pseudo-address: still ignored — a V4
//        pseudo-address balance is never custody, whatever its size.
//
//  forge test --match-contract HardeningV3_AnchorDust -vv
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixCore as BPC, Leg, RoutePlan} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @dev Minimal V4 PoolManager stand-in for the Solver's VIEW path: only the
///      extsload single-slot read the quote engine uses (v4SqrtAndLiq). No
///      swap/settle — nothing executes here, the Solver only plans. Mirrors
///      the extsload backing-store idiom of MockV4ManagerNative in
///      RouterV4NativeEth.t.sol, trimmed to the planning surface.
contract MockV4StateManager {
    mapping(bytes32 => bytes32) public slots;
    function setSlot(bytes32 s, bytes32 v) external { slots[s] = v; }
    function extsload(bytes32 s) external view returns (bytes32) { return slots[s]; }
}

contract HardeningV3_AnchorDustTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    MockV4StateManager mgr;

    // Sorted so tokenIn == the pools' currency0 (zeroForOne = true) and every
    // planted sqrtP reads directly as "tokenOut per tokenIn".
    MockERC20 tokenIn;   // sorted token0
    MockERC20 tokenOut;  // sorted token1

    // Honest deep pool: true rate (price 1:1), deep PoolManager liquidity.
    uint24  constant FEE_HONEST = 3000;
    int24   constant TS_HONEST  = 60;
    uint128 constant LIQ_HONEST = 1e24;

    // Stale thin pool: attacker-favourable price (~4x: sqrtP = 2·Q96), 1000x
    // thinner. Its ONLY path to winning is forging the capital anchor.
    uint24  constant FEE_STALE = 500;
    int24   constant TS_STALE  = 10;
    uint128 constant LIQ_STALE = 1e21;

    bytes32 pidHonest;
    bytes32 pidStale;
    address poolHonest;  // truncated-poolId pseudo-address (codeless)
    address poolStale;   // truncated-poolId pseudo-address (codeless)

    uint256 constant AMOUNT_IN = 10e18;

    function setUp() public {
        mgr = new MockV4StateManager();
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(mgr));
        solver = new BlazePhoenixSolver(address(hub));

        MockERC20 a = new MockERC20("A", "A");
        MockERC20 b = new MockERC20("B", "B");
        (tokenIn, tokenOut) = address(a) < address(b) ? (a, b) : (b, a);

        // Register the V4-ONLY candidate set (hookless, ERC20/ERC20).
        hub.addV4(address(tokenIn), address(tokenOut), FEE_HONEST, TS_HONEST, address(0));
        hub.addV4(address(tokenIn), address(tokenOut), FEE_STALE, TS_STALE, address(0));

        pidHonest = BPC.computeV4PoolId(
            address(tokenIn), address(tokenOut), FEE_HONEST, TS_HONEST, address(0));
        pidStale = BPC.computeV4PoolId(
            address(tokenIn), address(tokenOut), FEE_STALE, TS_STALE, address(0));
        poolHonest = address(uint160(uint256(pidHonest)));
        poolStale  = address(uint160(uint256(pidStale)));

        // Plant PoolManager state at each pid (slot0 packs sqrtPriceX96 in the
        // low 160 bits with lpFee/protocolFee zero; liquidity at offset +3 —
        // same layout RouterV4NativeEth.t.sol plants for the quote path).
        _plantV4State(pidHonest, uint160(BPC.Q96), LIQ_HONEST);        // price 1
        _plantV4State(pidStale, uint160(2 * BPC.Q96), LIQ_STALE);      // price 4

        // Scenario sanity: the stale pool really does quote a marginal rate
        // far outside the honest pool's ±4% band — the trap is armed.
        uint256 probe = AMOUNT_IN / 100;
        uint256 honestOut = BPC.outV3(probe, uint160(BPC.Q96), LIQ_HONEST, FEE_HONEST, true, 0);
        uint256 staleOut  = BPC.outV3(probe, uint160(2 * BPC.Q96), LIQ_STALE, FEE_STALE, true, 0);
        assertGt(honestOut, 0, "precondition: honest pool quotable");
        assertGt(staleOut, honestOut * 3, "precondition: stale rate must sit far outside the band");
    }

    function _plantV4State(bytes32 pid, uint160 sqrtP, uint128 liq) internal {
        bytes32 base = keccak256(abi.encode(pid, uint256(6)));
        mgr.setSlot(base, bytes32(uint256(sqrtP)));
        mgr.setSlot(bytes32(uint256(base) + 3), bytes32(uint256(liq)));
    }

    /// @dev The honest full-size quote — what a plan anchored on the honest
    ///      pool must promise (single V4 leg: no clamp, no multi-leg shave).
    function _honestFullQuote() internal pure returns (uint256) {
        return BPC.outV3(AMOUNT_IN, uint160(BPC.Q96), LIQ_HONEST, FEE_HONEST, true, 0);
    }

    /// @dev Shared assertion: the plan routes EVERYTHING to the honest deep
    ///      pool at the honest rate — the band did not lock onto the stale
    ///      pool's ~4x figure.
    function _assertHonestVenueWins(RoutePlan memory plan) internal view {
        assertEq(plan.best.hops.length, 1, "direct one-hop route expected");
        assertEq(plan.best.hops[0].legs.length, 1, "stale pool must be band-filtered out");
        Leg memory leg = plan.best.hops[0].legs[0];
        assertEq(leg.pool, poolHonest, "the honest deep pool must carry the route");
        assertEq(leg.amountIn, AMOUNT_IN, "full input on the honest venue");
        for (uint256 i; i < plan.best.hops[0].legs.length; ++i) {
            assertTrue(plan.best.hops[0].legs[i].pool != poolStale,
                "no leg may touch the stale pool");
        }
        // Rate proof, not just venue proof: the promise equals the honest
        // pool's quote exactly, and sits nowhere near the stale ~4x rate.
        assertEq(plan.best.totalOut, _honestFullQuote(), "promise must be the honest quote");
        assertLt(plan.best.totalOut, 2 * AMOUNT_IN, "band locked onto the dusted pool's ~4x rate");
    }

    // =========================================================================
    //  (1) Control — V4-only set, no dust anywhere: with every balsOut forced
    //      to 0, the anchor falls to the DEEPEST candidate by measured
    //      PoolManager liquidity, and the honest deep pool sets the band.
    // =========================================================================

    function test_Control_V4OnlySet_DepthAnchorSelectsHonestDeepPool() public view {
        RoutePlan memory plan = solver.findBestRoutePlan(
            address(tokenIn), address(tokenOut), AMOUNT_IN);
        _assertHonestVenueWins(plan);
    }

    // =========================================================================
    //  (2) THE ATTACK — 1 wei of tokenOut, permissionlessly transferred to the
    //      stale pool's codeless pseudo-address. Before the fix this was the
    //      set's only non-zero balsOut: maxBal = 1 wei made the stale ~4x rate
    //      the band base, filtered the honest pool out as the "outlier", and
    //      steered the whole order into the thin manipulated pool. The fix
    //      forces balsOut = 0 for V4 kinds, so the wei must change nothing.
    // =========================================================================

    function test_BP18_DustWeiOnV4PseudoAddress_DoesNotForgeAnchor() public {
        address attacker = address(0xBAD);
        tokenOut.mint(attacker, 1);
        vm.prank(attacker);
        tokenOut.transfer(poolStale, 1);   // anyone can fund a codeless address
        assertEq(tokenOut.balanceOf(poolStale), 1, "precondition: dust landed");

        RoutePlan memory plan = solver.findBestRoutePlan(
            address(tokenIn), address(tokenOut), AMOUNT_IN);
        _assertHonestVenueWins(plan);
    }

    // =========================================================================
    //  (3) Size does not matter — a LARGE balance parked on the pseudo-address
    //      is still not custody (V4 tokens live in the PoolManager singleton),
    //      so the anchor must never read it, whatever its magnitude.
    // =========================================================================

    function test_BP18_LargeParkedBalanceOnV4PseudoAddress_StillIgnored() public {
        tokenOut.mint(poolStale, 1_000_000e18);

        RoutePlan memory plan = solver.findBestRoutePlan(
            address(tokenIn), address(tokenOut), AMOUNT_IN);
        _assertHonestVenueWins(plan);
    }
}
