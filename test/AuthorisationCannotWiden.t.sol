// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixCore as BPC} from "../src/BlazePhoenixCore.sol";

/// @notice Refusals are tested by deletion here, almost never by WIDENING - and widening is the
///         shape this project's own law calls the dominant one, "absence read as permission".
///         Measured over the 165 curated mutants: 33 neutralise a guard, 21 tighten one, and
///         only 17 widen; exactly ONE adds an alternative with `||`. The corpus names the axis
///         and barely exercises it.
///
///         What that leaves open is concrete. Every privileged door on the Hub funnels through
///         `_auth`, and the existing authorisation tests prank ONE stranger at six of them. A
///         stranger is refused whether the modifier reads `msg.sender == router` or
///         `msg.sender == router || operator[msg.sender]` — so the whole suite stays green while
///         any operator gains the router's door and can forge `recordSwap`, whose rows are what
///         the fitness ranking and the eviction order are computed from.
///
///         These tests probe the identity that would be ADMITTED by a widening, not the one that
///         is already refused. They are paired with mutants that add exactly that `||`.
contract AuthorisationCannotWidenTest is Test {
    BlazePhoenixHub hub;

    address router   = makeAddr("router");
    address operator = makeAddr("operator");
    address solver   = makeAddr("solver");
    address quoter   = makeAddr("quoter");

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0xBEEF));
        hub.setRoles(router, solver, quoter);
        hub.setOperator(operator, true);
    }

    /// @dev The premise the negative arms rest on: the operator bit is really set, so a refusal
    ///      below is the refusal of an ADMITTED identity and not of a stranger. There is no
    ///      public getter for the mapping, so the bit is proved by using it - `addV4` is an
    ///      operator door, and it answers.
    function test_TheOperatorBitIsActuallyGranted() public {
        vm.prank(operator);
        bytes32 key = hub.addV4(address(0xA11CE), address(0xB0B), 500, 10, address(0));
        assertTrue(key != bytes32(0), "premise: the operator must really hold the operator bit");
    }

    /// @notice `onlyRouter` is the router and nobody else. An operator is not a router.
    function test_AnOperatorIsRefusedAtTheRouterDoor() public {
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixHub.HubE.selector, uint16(1)));
        hub.recordSwap(address(0xF001), BPC.KIND_V2, 30, address(0),
                       address(0xAAA1), address(0xBBB2), 1e18, 1e18, 1e24);
    }

    /// @notice And neither is the admin, which is the arm that makes the one above mean
    ///         something: `onlyRouter` is not "privileged", it is one address.
    function test_TheAdminIsRefusedAtTheRouterDoorToo() public {
        vm.prank(address(this));            // the admin
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixHub.HubE.selector, uint16(1)));
        hub.recordSwap(address(0xF002), BPC.KIND_V2, 30, address(0),
                       address(0xAAA1), address(0xBBB2), 1e18, 1e18, 1e24);
    }

    /// @notice The positive control, without which the two above pass on a Hub that refuses
    ///         everyone: the real router IS admitted at the same door.
    function test_TheRouterItselfIsAdmitted() public {
        vm.prank(router);
        hub.recordSwap(address(0xF003), BPC.KIND_V2, 30, address(0),
                       address(0xAAA1), address(0xBBB2), 1e18, 1e18, 1e24);
    }

    /// @notice `onlyAdmin` is the admin and nobody else - an operator must not inherit the
    ///         curator's power to admit a bridge, which survives renunciation for ever.
    function test_AnOperatorIsRefusedAtTheAdminDoor() public {
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixHub.HubE.selector, uint16(1)));
        hub.addBridge(address(0xB21D5));
    }
}
