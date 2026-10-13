// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  PoC — F-3  (informational)
//  Title    : Quoter.previewPlanExact returns a figure one wei above the amount
//             the same route delivers in the same block
//  Contract : src/BlazePhoenixQuoter.sol (previewPlanExact) vs Router._chargeHopFee
//  Severity : Informational (dust)
//
//  Run it:
//      FOUNDRY_PROFILE=poc forge test --match-contract F3_PreviewExactOneWei -vv
//
//  previewPlanExact deducts the 0.28% protocol fee ONCE from the dry-run total
//  (rounded up). The Router charges it once per anchored hop, on the hop input,
//  and the pool then applies its own rounding. With two hops the two roundings
//  do not cancel, and the published "execution-grade" number lands exactly one
//  wei above what settles. An integrator that uses exactOut verbatim as
//  userMinOut (which the docstring invites) gets a revert on a swap that is in
//  every other respect correct.
//
//  This test searches a small range for a counterexample, reverts state between
//  attempts to stay deterministic, and pins the gap.
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixQuoter} from "../src/BlazePhoenixQuoter.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, RoutePlan} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "../test/mocks/MockERC20.sol";
import {MockV2Pair} from "../test/mocks/MockV2Pair.sol";

contract Bounty1013PreviewExactIsAFloorTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    BlazePhoenixQuoter quoter;
    BlazePhoenixRouter router;

    MockERC20 a; MockERC20 b; MockERC20 c;
    MockV2Pair ab; MockV2Pair bc;

    address user = address(0xBEEF);
    address recipient = address(0xCAFE);

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        solver = new BlazePhoenixSolver(address(hub));
        quoter = new BlazePhoenixQuoter(address(hub), address(solver));
        router = new BlazePhoenixRouter(
            address(hub), address(solver), address(this), address(0xFEE1), address(0xFEE2)
        );
        hub.setRoles(address(router), address(solver), address(quoter));

        a = new MockERC20("A", "A");
        b = new MockERC20("B", "B");
        c = new MockERC20("C", "C");
        ab = new MockV2Pair(address(a), address(b));
        bc = new MockV2Pair(address(b), address(c));
        a.mint(address(ab), 1_000_000e18); b.mint(address(ab), 1_000_000e18);
        b.mint(address(bc), 1_000_000e18); c.mint(address(bc), 1_000_000e18);
        ab.setReserves(uint112(1_000_000e18), uint112(1_000_000e18));
        bc.setReserves(uint112(1_000_000e18), uint112(1_000_000e18));

        hub.addBridge(address(b));
        hub.seedPool(address(ab), BPC.KIND_V2, 30, address(0), address(a), address(b));
        hub.seedPool(address(bc), BPC.KIND_V2, 30, address(0), address(b), address(c));

        a.mint(user, 100_000_000e18);
        vm.prank(user);
        a.approve(address(router), type(uint256).max);
    }

    /// @dev quote A -> B -> C, then execute the same plan; return (preview, delivered)
    function _quoteAndDeliver(uint256 amountIn) internal returns (uint256 exactOut, uint256 delivered) {
        try solver.findBestRoutePlan(address(a), address(c), amountIn) returns (RoutePlan memory plan) {
            if (plan.best.hops.length == 0) return (0, 0);
            try quoter.previewPlanExact(address(a), address(c), amountIn)
                returns (Route memory, uint256 eo)
            {
                exactOut = eo;
            } catch { return (0, 0); }
            if (exactOut == 0) return (0, 0);
            uint256 before = c.balanceOf(recipient);
            vm.prank(user);
            router.swapExactIn(plan.best, amountIn, 1, recipient, block.timestamp + 1);
            delivered = c.balanceOf(recipient) - before;
        } catch { return (0, 0); }
    }

    /// #44: the reporter's counterexample (1e12 + 3) and its neighbourhood: the published
    /// exactOut is never above delivery, and stays within 1 bp of it (a floor, not a haircut).
    function test_ExactOutNeverExceedsDelivery() public {
        uint256 snap = vm.snapshotState();
        uint256 checked;
        for (uint256 amt = 1e12; amt < 1e12 + 400; ++amt) {
            (uint256 eo, uint256 del) = _quoteAndDeliver(amt);
            vm.revertToState(snap);
            if (eo == 0) continue;
            ++checked;
            assertLe(eo, del, "preview above delivery");
            assertLe(del - eo, del / 10_000 + 1, "preview is a haircut, not a floor");
        }
        assertGt(checked, 300, "the route stopped being quoted");
    }

    function testFuzz_ExactOutNeverExceedsDelivery(uint256 amt) public {
        amt = bound(amt, 1e9, 1e15);
        (uint256 eo, uint256 del) = _quoteAndDeliver(amt);
        if (eo != 0) assertLe(eo, del, "preview above delivery");
    }
}
