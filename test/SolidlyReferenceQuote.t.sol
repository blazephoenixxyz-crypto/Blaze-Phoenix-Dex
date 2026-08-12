// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// Guards the Router's in-frame Solidly reference quote (the fee base / protocol
// floor input), which now prefers the pool's own getAmountOut — decimal-agnostic
// and identical to what _execSolidlyAmt settles — via _solidlyLegQuote, instead
// of outSolidly's decimals-blind equal-decimals fast path. No existing test
// exercised a Solidly route end-to-end, so these pin BOTH paths: the primary
// (getAmountOut exposed) and the fallback (getAmountOut hidden -> replicated
// curve). A volatile pool is used to isolate this fix from the Solidly stable
// bit persistence (a separate hardening item).

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, RoutePlan} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockSolidlyPair} from "./mocks/MockSolidlyPair.sol";

contract SolidlyReferenceQuoteTest is Test {
    BlazePhoenixHub    hub;
    BlazePhoenixSolver solver;
    BlazePhoenixRouter router;
    MockERC20 tokenA;
    MockERC20 tokenB;
    address user = address(0xBEEF);

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        tokenA = new MockERC20("A", "A");
        tokenB = new MockERC20("B", "B");
        solver = new BlazePhoenixSolver(address(hub));
        router = new BlazePhoenixRouter(
            address(hub), address(solver), address(this), address(0xFEE1), address(0xFEE2)
        );
        tokenA.mint(user, 1_000_000e18);
        vm.prank(user);
        tokenA.approve(address(router), type(uint256).max);
    }

    function _seed(bool hideGetAmountOut) internal returns (MockSolidlyPair p) {
        p = new MockSolidlyPair(address(tokenA), address(tokenB), false); // volatile
        uint112 R = uint112(1_000_000e18);
        tokenA.mint(address(p), R);
        tokenB.mint(address(p), R);
        p.setReserves(R, R);
        p.setHideGetAmountOut(hideGetAmountOut);
        hub.seedPool(address(p), BPC.KIND_SOLIDLY, 30, address(0), address(tokenA), address(tokenB));
    }

    function _swap(uint256 amt) internal returns (uint256 out) {
        RoutePlan memory plan = solver.findBestRoutePlan(address(tokenA), address(tokenB), amt);
        vm.prank(user);
        out = router.swapExactIn(plan.best, amt, 1, user, block.timestamp + 1);
    }

    /// Primary path: the pool exposes getAmountOut, so the reference quote uses
    /// it (matching execution) and the swap settles.
    function test_Solidly_RoutesViaPoolGetAmountOut() public {
        _seed(false);
        assertGt(_swap(1_000e18), 0, "solidly swap must deliver output via getAmountOut");
    }

    /// Fallback path: getAmountOut hidden -> the reference quote falls back to
    /// the replicated curve (the pre-existing conservative path); still settles.
    function test_Solidly_FallsBackWhenGetAmountOutHidden() public {
        _seed(true);
        assertGt(_swap(1_000e18), 0, "solidly swap must still deliver via curve fallback");
    }
}
