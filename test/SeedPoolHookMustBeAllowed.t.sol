// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixCore as BPC} from "../src/BlazePhoenixCore.sol";

/// @notice The Hub has two registration doors. `addV4` admits a hook only if it is listed;
///         `seedPool` now admits a hook on exactly the same terms. A row seeded with an unlisted
///         hook would be filtered out of every read by `isHookLive` - a dead seat on the pair -
///         and after renunciation nothing could take it back. Both doors refuse the same way.
contract SeedPoolHookMustBeAllowedTest is Test {
    BlazePhoenixHub hub;
    address operator = makeAddr("operator");
    address tA = address(0xAAA1);
    address tB = address(0xBBB2);
    address pool = address(0xF00D);
    address hookUnlisted = address(uint160(0x1000));   // no delta bits, simply never listed
    address hookListed   = address(uint160(0x2000));

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0xBEEF));
        hub.setRoles(address(this), address(this), address(this));
        hub.setOperator(operator, true);
        hub.allowHook(hookListed, true);
    }

    /// @notice An unlisted hook is refused at the second door with the first door's code.
    function test_SeedPoolRefusesAnUnlistedHook() public {
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixHub.HubE.selector, uint16(8)));
        hub.seedPool(pool, BPC.KIND_V2, 30, hookUnlisted, tA, tB);
    }

    /// @notice Positive control, without which the refusal above would pass on a door that
    ///         refuses everything: no hook at all is admitted.
    function test_SeedPoolAdmitsNoHook() public {
        vm.prank(operator);
        bytes32 key = hub.seedPool(pool, BPC.KIND_V2, 30, address(0), tA, tB);
        assertEq(hub.getPool(key), pool, "a hookless row is seeded");
    }

    /// @notice And a LISTED hook is admitted - the guard is about listing, not about hooks.
    function test_SeedPoolAdmitsAListedHook() public {
        vm.prank(operator);
        bytes32 key = hub.seedPool(address(0xF00E), BPC.KIND_V2, 30, hookListed, tA, tB);
        assertEq(hub.getPool(key), address(0xF00E), "a row with a listed hook is seeded");
    }
}
