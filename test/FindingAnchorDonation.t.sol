// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;
import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, RoutePlan} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";

contract FindingAnchorDonationTest is Test {
    BlazePhoenixHub hub; BlazePhoenixSolver solver; BlazePhoenixRouter router;
    MockERC20 tokenA; MockERC20 tokenB; MockV2Pair honest; MockV2Pair attacker;
    address constant T1 = address(0xFEE1); address constant T2 = address(0xFEE2);
    uint256 constant AMOUNT_IN = 1000e18;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        solver = new BlazePhoenixSolver(address(hub));
        router = new BlazePhoenixRouter(address(hub), address(solver), address(this), T1, T2);
        hub.setRoles(address(router), address(solver), address(this));
        tokenA = new MockERC20("A", "A"); tokenB = new MockERC20("B", "B");
        honest = new MockV2Pair(address(tokenA), address(tokenB));
        attacker = new MockV2Pair(address(tokenA), address(tokenB));
        _setReserves(honest, 1000e18, 1000e18);
        _setReserves(attacker, 1000e18, 500e18);
        tokenB.mint(address(honest), 1000e18);
        tokenB.mint(address(attacker), 500e18);
        hub.seedPool(address(honest), BPC.KIND_V2, 30, address(0), address(tokenA), address(tokenB));
        hub.seedPool(address(attacker), BPC.KIND_V2, 30, address(0), address(tokenA), address(tokenB));
    }
    function _setReserves(MockV2Pair p, uint256 a, uint256 b) internal {
        if (p.token0() == address(tokenA)) p.setReserves(uint112(a), uint112(b));
        else p.setReserves(uint112(b), uint112(a));
    }
    function _routedPool() internal view returns (address) {
        RoutePlan memory plan = solver.findBestRoutePlan(address(tokenA), address(tokenB), AMOUNT_IN);
        return plan.best.hops[0].legs[0].pool;
    }
    function test_WithoutDonation_RoutesHonestPool() public view {
        assertEq(_routedPool(), address(honest), "anchor must select the deep honest pool");
    }
    // FIXED (T2): a raw-balance donation must NOT move the anchor. After donating
    // 2000e18 tokenOut to the attacker pool, the band must still anchor on real
    // depth (getReserves), so the honest deep pool stays selected.
    function test_WithDonation_AnchorHolds_RoutesHonest() public {
        tokenB.mint(address(this), 2000e18);
        tokenB.transfer(address(attacker), 2000e18);
        assertEq(_routedPool(), address(honest), "donation must NOT flip the anchor");
        RoutePlan memory plan = solver.findBestRoutePlan(address(tokenA), address(tokenB), AMOUNT_IN);
        // Honest output here is ~499e18: a 1000e18 order into a 1000e18/1000e18
        // pool is 100% of reserves, so constant-product delivers ~half. The
        // attacker pool (1000e18/500e18) would deliver only ~249e18. Staying on
        // honest (>=400e18) proves the donation no longer steers the route.
        assertGt(plan.best.totalOut, 400e18, "must keep the honest pool output, not the ~249e18 gamed one");
        emit log_named_uint("honest_totalOut", plan.best.totalOut);
    }

}
