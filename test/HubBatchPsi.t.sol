// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  psisOf — the batched fitness read. Parity is the whole contract: for any
//  candidate set, psisOf must return exactly what keyOf+getPsi return per
//  element, and mismatched array lengths must revert HubE(4).
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixCore as BPC} from "../src/BlazePhoenixCore.sol";

contract HubBatchPsiTest is Test {
    BlazePhoenixHub hub;

    address constant TA = address(0xAAA1);
    address constant TB = address(0xBBB1);

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        // Codeless dummy pools, deliberately (the Hub unit-test convention):
        // slot logic is isolated from pool bytecode.
        hub.seedPool(address(0x7001), BPC.KIND_V2, 30, address(0), TA, TB);
        hub.seedPool(address(0x7002), BPC.KIND_V3, 500, address(0), TA, TB);
        hub.seedPool(address(0x7003), BPC.KIND_SOLIDLY, 0, address(0), TA, TB);
    }

    function test_PsisOf_MatchesPerKeyGetPsi() public view {
        address[] memory pools = new address[](4);
        pools[0] = address(0x7001);
        pools[1] = address(0x7002);
        pools[2] = address(0x7003);
        pools[3] = address(0x7FFF); // unregistered — must read 0, not revert
        address[] memory tAs = new address[](4);
        address[] memory tBs = new address[](4);
        for (uint256 i; i < 4; ++i) { tAs[i] = TA; tBs[i] = TB; }

        uint256[] memory batch = hub.psisOf(pools, tAs, tBs);
        assertEq(batch.length, 4);
        for (uint256 i; i < 4; ++i) {
            assertEq(
                batch[i],
                hub.getPsi(hub.keyOf(pools[i], TA, TB)),
                "batch element must equal the per-key read"
            );
        }
        assertEq(batch[3], 0, "unregistered pool reads 0");
    }

    function test_PsisOf_LengthMismatchReverts() public {
        address[] memory pools = new address[](2);
        address[] memory tAs = new address[](1);
        address[] memory tBs = new address[](2);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixHub.HubE.selector, uint16(4)));
        hub.psisOf(pools, tAs, tBs);
    }
}
