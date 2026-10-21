// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixCore as BPC} from "../src/BlazePhoenixCore.sol";

/// Two salt-slot <-> kind cells addFactory refuses but no test demanded until 2026-10-21 (the
/// meta-1021 study found no registered mutant dying for them): (mode 4 = V2 salt, SOLIDLY) and
/// (mode 9 = V4 derive, V3). Since P-A1 they are bits of MODE_KINDS rows 4 and 9. Each test proves
/// the refusal is about the KIND: the very same row with the coherent kind is admitted right after.
/// Green at 85720ef as well: they pin an existing refusal, and their mutants are the proof.
contract ModeKindTableHolesTest is Test {
    BlazePhoenixHub hub;
    address constant FAC = address(0x3333);

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0xBEEF));
        hub.setRoles(address(this), address(this), address(this));
    }

    function test_AddFactory_V2SaltModeRefusesSolidly() public {
        uint24[] memory fees = new uint24[](0);
        int24[] memory spacings = new int24[](0);
        bytes32 h = bytes32(uint256(1));
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixHub.HubE.selector, 5));
        hub.addFactory(FAC, BPC.KIND_SOLIDLY, 4, h, fees, spacings);
        assertEq(hub.factoryCount(), 0, "a refused row takes no seat");
        assertEq(hub.addFactory(FAC, BPC.KIND_V2, 4, h, fees, spacings), 0, "the same row with KIND_V2 is admitted");
        assertEq(hub.factoryCount(), 1, "one seat");
    }

    function test_AddFactory_V4DeriveModeRefusesV3() public {
        uint24[] memory fees = new uint24[](0);
        int24[] memory spacings = new int24[](0);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixHub.HubE.selector, 5));
        hub.addFactory(FAC, BPC.KIND_V3, 9, bytes32(0), fees, spacings);
        assertEq(hub.factoryCount(), 0, "a refused row takes no seat");
        assertEq(hub.addFactory(FAC, BPC.KIND_V4, 9, bytes32(0), fees, spacings), 0, "the same row with KIND_V4 is admitted");
        assertEq(hub.factoryCount(), 1, "one seat");
    }
}
