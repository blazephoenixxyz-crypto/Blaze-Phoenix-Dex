// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// The Hub is the surface third parties index. Before this file the registry mutations
// had no test reading their event payloads (test/ControlEvents.t.sol covers the
// pause/setter events). This file witnesses each
// registration door's payload, and pins the one case where silence is the contract:
// re-adding an already-listed bridge must emit NOTHING (the Hub returns before the emit).
//
// Payments are not re-tested here: the event IS the payload of the registry.

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixCore as BPC} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV3Pool} from "./mocks/MockV3Pool.sol";

contract HubRegistrationTestifiesTest is Test {
    BlazePhoenixHub hub;
    MockERC20 tokenA;
    MockERC20 tokenB;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        tokenA = new MockERC20("A", "A");
        tokenB = new MockERC20("B", "B");
    }

    /// initialize writes the admin's seat AND its operator seat; the seat is the event.
    function test_InitializeTestifiesRoleZero() public {
        BlazePhoenixHub fresh = new BlazePhoenixHub(address(this));
        vm.expectEmit(false, false, false, true, address(fresh));
        emit BlazePhoenixHub.RoleSet(0, address(this));
        fresh.initialize(address(this), address(0));
    }

    function test_AddBridgeTestifiesAndRepeatIsSilent() public {
        address t = address(0xB12D6E);

        vm.expectEmit(true, false, false, true, address(hub));
        emit BlazePhoenixHub.Bridge_(t, true);
        hub.addBridge(t);

        // Idempotent re-add: the contract returns BEFORE the emit.
        vm.recordLogs();
        hub.addBridge(t);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 0, "re-adding a listed bridge must be silent");
    }

    function test_RemoveBridgeTestifiesRemoval() public {
        address t = address(0xB12D6E);
        hub.addBridge(t);

        vm.expectEmit(true, false, false, true, address(hub));
        emit BlazePhoenixHub.Bridge_(t, false);
        hub.removeBridge(0);
    }

    function test_AddFactoryTestifiesKindAndMode() public {
        address factory = makeAddr("factory");
        uint24[] memory fees = new uint24[](1);
        fees[0] = 500;
        int24[] memory spacings = new int24[](1);
        spacings[0] = 10;

        vm.expectEmit(true, false, false, true, address(hub));
        emit BlazePhoenixHub.Factory_(factory, BPC.KIND_V3, 5); // MODE_CREATE2_V3 = 5
        hub.addFactory(factory, BPC.KIND_V3, 5, keccak256("init-code"), fees, spacings);
    }

    function test_AddV4TestifiesSortedCurrencies() public {
        address c0 = address(0xAA00000000000000000000000000000000000001);
        address c1 = address(0xBb00000000000000000000000000000000000002);

        vm.expectEmit(true, false, false, true, address(hub));
        emit BlazePhoenixHub.V4Add(0, c0, c1, 3000);
        hub.addV4(c0, c1, 3000, 60, address(0));
    }

    function test_SeedPoolTestifiesRegisteredKey() public {
        MockV3Pool pool = new MockV3Pool(address(tokenA), address(tokenB), 100);
        // A pool with no price or no liquidity is refused (HubE(4)) before any emit.
        pool.setState(uint160(BPC.Q96), 1e18);
        bytes32 key = hub.keyOf(address(pool), address(tokenA), address(tokenB));

        vm.expectEmit(true, true, false, true, address(hub));
        emit BlazePhoenixHub.Registered(key, address(pool), BPC.KIND_V3);
        hub.seedPool(address(pool), BPC.KIND_V3, 100, address(0), address(tokenA), address(tokenB));
    }

    function test_SetRolesTestifiesAllThreeSeats() public {
        address r = makeAddr("router");
        address s = makeAddr("solver");
        address q = makeAddr("quoter");

        vm.expectEmit(false, false, false, true, address(hub));
        emit BlazePhoenixHub.RoleSet(1, r);
        vm.expectEmit(false, false, false, true, address(hub));
        emit BlazePhoenixHub.RoleSet(2, s);
        vm.expectEmit(false, false, false, true, address(hub));
        emit BlazePhoenixHub.RoleSet(3, q);
        hub.setRoles(r, s, q);
    }

    function test_RenounceControlTestifies() public {
        vm.expectEmit(false, false, false, true, address(hub));
        emit BlazePhoenixHub.ControlRenounced();
        hub.renounceControl();
    }
}
