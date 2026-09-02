// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  swapBestExactIn is the one door where the route is NOT the caller's. It
//  verified the plan's INPUT end (hops[0].tokenIn == tokenIn, which guards the
//  pull) and nothing verified the OUTPUT end: the recipient received whatever
//  the Solver's last hop named, and userMinOut was compared in those units.
//  The Solver is immutable and honest, so this is a belt — but the check was
//  missing for no reason other than sibling asymmetry on one line.
//  RED on main 19b2f08 (review 2026-09-02).
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg, RoutePlan} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";

/// @dev A Solver that answers every request with a one-hop plan from tIn to
///      the token it was told to end in, through the pair it was given.
contract SolverEndsWhereItLikes {
    address public pair;
    address public endsIn;
    constructor(address p, address e) { pair = p; endsIn = e; }

    function findBestRoutePlan(address tIn, address, uint256 amountIn)
        external view returns (RoutePlan memory plan)
    {
        Leg[] memory legs = new Leg[](1);
        legs[0] = Leg({
            pool: pair, hooks: address(0), kind: BPC.KIND_V2, fee: 30,
            tickSpacing: 0, zeroForOne: tIn < endsIn, stable: false,
            amountIn: amountIn, expectedOut: 1, auxId: bytes32(0)
        });
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({ tokenIn: tIn, tokenOut: endsIn, amountIn: amountIn, expectedOut: 1, legs: legs });
        plan.best = Route({
            hops: hops, totalOut: 1, singleOut: 1, singleOutFloor: 0, expectedImpactBps: 0,
            confidenceWad: 0, estGas: 0, hasSurplus: false, isV4Bundle: false
        });
    }
}

contract SwapBestExactInChecksBothEndsTest is Test {
    BlazePhoenixHub hub;
    MockERC20 tokenA;
    MockERC20 tokenB;
    MockERC20 tokenZ;
    address user = address(0xBEEF);
    uint256 constant AMT = 1e18;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        tokenA = new MockERC20("A", "A");
        tokenB = new MockERC20("B", "B");
        tokenZ = new MockERC20("Z", "Z");
        tokenA.mint(user, 100e18);
    }

    function _pair(address x, address y) private returns (MockV2Pair p) {
        p = new MockV2Pair(x, y);
        MockERC20(x).mint(address(p), 1_000_000e18);
        MockERC20(y).mint(address(p), 1_000_000e18);
        p.setReserves(uint112(1_000_000e18), uint112(1_000_000e18));
    }

    function _router(address solver) private returns (BlazePhoenixRouter r) {
        r = new BlazePhoenixRouter(address(hub), solver, address(this), address(0xFEE1), address(0xFEE2));
        vm.prank(user);
        tokenA.approve(address(r), type(uint256).max);
    }

    /// RED on main: the user asked for B, the plan ends in Z, the swap settles
    /// in Z. The refusal must come BEFORE the pull (no A leaves the user).
    function test_PlanEndingInAnotherToken_IsRefusedBeforeThePull() public {
        MockV2Pair pAZ = _pair(address(tokenA), address(tokenZ));
        BlazePhoenixRouter r = _router(address(new SolverEndsWhereItLikes(address(pAZ), address(tokenZ))));
        uint256 balBefore = tokenA.balanceOf(user);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, uint16(3)));
        r.swapBestExactIn(address(tokenA), address(tokenB), AMT, 1, user, block.timestamp + 1);

        assertEq(tokenA.balanceOf(user), balBefore, "refused before any pull");
        assertEq(tokenZ.balanceOf(user), 0, "nothing settled in the wrong token");
    }

    /// Control: a plan that ends where the user asked settles through the
    /// same door with the same mock Solver.
    function test_Control_PlanEndingInTheRequestedToken_Settles() public {
        MockV2Pair pAB = _pair(address(tokenA), address(tokenB));
        BlazePhoenixRouter r = _router(address(new SolverEndsWhereItLikes(address(pAB), address(tokenB))));

        vm.prank(user);
        uint256 out = r.swapBestExactIn(address(tokenA), address(tokenB), AMT, 1, user, block.timestamp + 1);
        assertGt(out, 0, "the honest plan settles");
        assertEq(tokenB.balanceOf(user), out, "delivered in the requested token");
    }
}
