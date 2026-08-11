// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  Rescue with 48h timelock. The Router holds no user funds at rest, so
//  rescue only moves accidental direct sends; the delay + events make every
//  rescue publicly observable before it can execute, and the power dies with
//  renounceControl like every other control power.
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract RouterRescueTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixRouter router;
    MockERC20 token;

    address to = address(0xD00D);

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        router = new BlazePhoenixRouter(
            address(hub), address(0xBEEF), address(this), address(0xFEE1), address(0xFEE2)
        );
        token = new MockERC20("Stuck", "STK");
        token.mint(address(router), 1_000e18);
    }

    function test_Rescue_RevertsBeforeQueue() public {
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, 14));
        router.executeRescue(address(token), to);
    }

    function test_Rescue_RevertsInsideTimelock() public {
        router.queueRescue(address(token), to);
        vm.warp(block.timestamp + 48 hours - 1);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, 14));
        router.executeRescue(address(token), to);
    }

    function test_Rescue_ExecutesAfterTimelock() public {
        router.queueRescue(address(token), to);
        vm.warp(block.timestamp + 48 hours);
        router.executeRescue(address(token), to);
        assertEq(token.balanceOf(to), 1_000e18);
        assertEq(token.balanceOf(address(router)), 0);
        // The eta is consumed: a second execute needs a fresh queue + delay.
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, 14));
        router.executeRescue(address(token), to);
    }

    function test_Rescue_CancelClearsEta() public {
        router.queueRescue(address(token), to);
        router.cancelRescue(address(token), to);
        vm.warp(block.timestamp + 48 hours);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, 14));
        router.executeRescue(address(token), to);
    }

    function test_Rescue_OnlyControl() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, 1));
        router.queueRescue(address(token), to);
    }

    function test_Rescue_DiesWithRenounce() public {
        router.queueRescue(address(token), to);
        router.renounceControl();
        vm.warp(block.timestamp + 48 hours);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, 1));
        router.executeRescue(address(token), to);
    }
}
