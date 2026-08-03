// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { BlazePhoenixRouter } from "../src/BlazePhoenixRouter.sol";

/// @notice renounceControl on the Router permanently freezes the control
///         powers (treasuries, permit2, pause, admin transfer).
contract RouterAdminTest is Test {
    BlazePhoenixRouter router;

    function setUp() public {
        // hub/solver only matter for swaps; admin paths don't touch them.
        router = new BlazePhoenixRouter(address(0x1), address(0x2), address(this), address(0x711), address(0x722));
    }

    function test_admin_setBeforeRenounce() public {
        router.setTreasuries(address(0xAA), address(0xBB));
        assertEq(router.treasury1(), address(0xAA));
        router.setPaused(true);
        assertTrue(router.paused());
        router.setPaused(false);
    }

    function test_renounceControl_freezesAll() public {
        router.renounceControl();
        assertTrue(router.controlRenounced());

        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, uint16(1)));
        router.setTreasuries(address(0xAA), address(0xBB));
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, uint16(1)));
        router.setPaused(true);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, uint16(1)));
        router.setAdmin(address(0xCAFE));
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, uint16(1)));
        router.setPermit2(address(0xDD));
    }
}
