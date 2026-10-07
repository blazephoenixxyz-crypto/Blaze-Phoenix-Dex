// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixQuoter} from "../src/BlazePhoenixQuoter.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {
    BlazePhoenixCore as BPC,
    Route, Hop, Leg
} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";

/// @dev Bare V4-manager stand-in: non-zero so the Router passes the
///      "manager wired" gate (RouterE(8)) and reaches the hook sieve.
///      extsload reads as zero (no fallback), so quotes are 0 and no swap
///      is ever attempted — the sieve reverts first.
contract MockV4Manager {}

/// @notice THE PREVIEW REFUSES WHAT THE ROUTER REFUSES: a hook that alters deltas.
///         The Router's hook sieve has two arms (`_execV4Amt`):
///             if (BPC.hookAltersDeltas(leg.hooks)) revert RouterE(9);   // arm 1: unconditional
///             if (BPC.hookRunsInSwap(leg.hooks) && hub.hookPaused(leg.hooks)) revert RouterE(9); // arm 2
///         Until 2026-10-07 the Quoter asked arm 2 only, while its docstring claimed
///         "exactly the condition the Router refuses on": a delta-altering hook that
///         was not paused passed, the leg was priced from the plan's own claim, and
///         `canExecute` endorsed a route every execution refuses.
///         Reported by Yudha Eka Saputra through the bug bounty programme (WS-B-01);
///         this file is their proof of concept with the assertion turned to the fix.
contract PreviewRefusesDeltaHooksTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    BlazePhoenixQuoter quoter;
    BlazePhoenixRouter router;

    MockERC20 tokenA;
    MockERC20 tokenB;
    MockV2Pair pair;

    address user = address(0xBEEF);

    // bit 2 set only: hookAltersDeltas == true; unlisted => hub.hookPaused == false.
    address constant DELTA_HOOK = address(0x04);

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0)); // manager wired below
        hub.setV4Manager(address(new MockV4Manager()));
        solver = new BlazePhoenixSolver(address(hub));
        quoter = new BlazePhoenixQuoter(address(hub), address(solver));
        router = new BlazePhoenixRouter(
            address(hub), address(solver), address(this), address(this), address(this)
        );

        tokenA = new MockERC20("A", "A");
        tokenB = new MockERC20("B", "B");
        pair = new MockV2Pair(address(tokenA), address(tokenB));
        tokenA.mint(address(pair), 100_000e18);
        tokenB.mint(address(pair), 100_000e18);
        bool aIsT0 = address(tokenA) < address(tokenB);
        pair.setReserves(
            uint112(aIsT0 ? 100_000e18 : 100_000e18),
            uint112(aIsT0 ? 100_000e18 : 100_000e18)
        );

        tokenA.mint(user, 10_000e18);
        vm.prank(user);
        tokenA.approve(address(router), type(uint256).max);
    }

    function _route(uint256 amountIn, uint256 totalOut) internal view returns (Route memory route) {
        bool zfo = address(tokenA) < address(tokenB);
        Leg[] memory legs = new Leg[](2);
        // leg 0: V4 leg naming a delta-altering hook (unlisted => not paused).
        // It quotes 0 (no V4 manager), so it contributes nothing to totalOut.
        legs[0] = Leg({
            pool: address(0xDEAD),
            hooks: DELTA_HOOK,
            kind: BPC.KIND_V4,
            fee: 3000,
            tickSpacing: 60,
            zeroForOne: zfo,
            stable: false,
            amountIn: amountIn,
            expectedOut: 0,
            auxId: bytes32(uint256(uint160(address(tokenB))))
        });
        // leg 1: honest V2 leg with real reserves, so the route's totalOut is honest.
        legs[1] = Leg({
            pool: address(pair),
            hooks: address(0),
            kind: BPC.KIND_V2,
            fee: 30,
            tickSpacing: 0,
            zeroForOne: zfo,
            stable: false,
            amountIn: amountIn,
            expectedOut: totalOut,
            auxId: bytes32(0)
        });
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({
            tokenIn: address(tokenA),
            tokenOut: address(tokenB),
            amountIn: amountIn,
            expectedOut: totalOut,
            legs: legs
        });
        route = Route({
            hops: hops,
            totalOut: totalOut,
            singleOut: totalOut,
            singleOutFloor: 0,
            expectedImpactBps: 0,
            confidenceWad: 0,
            estGas: 0,
            hasSurplus: true,
            isV4Bundle: false
        });
    }

    function test_PreviewRefusesWhatTheRouterRefuses_DeltaHook() public {
        uint256 amountIn = 1_000e18;
        uint256 v2out = BPC.outV2(amountIn, 100_000e18, 100_000e18, 30);
        assertGt(v2out, 0, "sanity: V2 leg quotes positive");
        Route memory route = _route(amountIn, v2out);
        assertTrue(BPC.hookAltersDeltas(DELTA_HOOK), "setup: the hook alters deltas");
        assertFalse(hub.hookPaused(DELTA_HOOK), "setup: and it is not paused, so arm 2 alone would pass it");

        // 1. The Quoter withholds canExecute, though the netOut it publishes is positive.
        BlazePhoenixQuoter.Preview memory pv = quoter.previewRoute(route, 0);
        assertGt(pv.netOut, 0, "netOut is positive, so only the hook question can refuse");
        assertFalse(pv.canExecute, "previewRoute endorsed a route the Router always refuses");

        // 2. The Router refuses the identical route at the sieve, as before.
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, 9));
        router.swapExactIn(route, amountIn, 1, user, block.timestamp + 1);
    }

    /// @notice Control: the same route with a hookless V4 leg executes fine,
    ///         proving the revert above is the delta-hook sieve and nothing else.
    function test_Control_HooklessV4Leg_Executes() public {
        uint256 amountIn = 1_000e18;
        uint256 v2out = BPC.outV2(amountIn, 100_000e18, 100_000e18, 30);
        Route memory route = _route(amountIn, v2out);
        // Neutralise the V4 leg: hookless, and drop it from the hop so the
        // Router only executes the honest V2 leg.
        route.hops[0].legs[0].hooks = address(0);
        route.hops[0].legs[0].kind = BPC.KIND_V2;
        route.hops[0].legs[0].pool = address(pair);
        route.hops[0].legs[0].fee = 30;
        route.hops[0].legs[0].expectedOut = v2out / 2;
        route.hops[0].legs[1].amountIn = amountIn / 2;
        route.hops[0].legs[1].expectedOut = v2out / 2;
        route.totalOut = v2out;

        vm.prank(user);
        uint256 delivered = router.swapExactIn(route, amountIn, 1, user, block.timestamp + 1);
        assertGt(delivered, 0, "control route executes");
    }
}
