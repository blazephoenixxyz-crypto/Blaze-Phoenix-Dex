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
import {MockV2Pair} from "./mocks/MockV2Pair.sol";
import {MockV3Pool} from "./mocks/MockV3Pool.sol";
import {MockSolidlyPair} from "./mocks/MockSolidlyPair.sol";

contract HubBatchPsiTest is Test {
    BlazePhoenixHub hub;

    address constant TA = address(0xAAA1);
    address constant TB = address(0xBBB1);

    address p1;
    address p2;
    address p3;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        // One pool of each shape. The operator's door reads the shape it is told about
        // (Core.provenShape, ninth wave), so a concentrated row needs a pool that answers
        // slot0 and a Solidly row one that answers stable(); a codeless address is a pair.
        p1 = address(new MockV2Pair(TA, TB));
        MockV3Pool v3 = new MockV3Pool(TA, TB, 500);
        v3.setState(uint160(BPC.Q96), 1e18);
        p2 = address(v3);
        p3 = address(new MockSolidlyPair(TA, TB, false));
        hub.seedPool(p1, BPC.KIND_V2, 30, address(0), TA, TB);
        hub.seedPool(p2, BPC.KIND_V3, 500, address(0), TA, TB);
        hub.seedPool(p3, BPC.KIND_SOLIDLY, 0, address(0), TA, TB);
    }

    function test_PsisOf_MatchesPerKeyGetPsi() public view {
        address[] memory pools = new address[](4);
        pools[0] = p1;
        pools[1] = p2;
        pools[2] = p3;
        pools[3] = address(0x7FFF); // unregistered — must read 0, not revert
        address[] memory tAs = new address[](4);
        address[] memory tBs = new address[](4);
        for (uint256 i; i < 4; ++i) { tAs[i] = TA; tBs[i] = TB; }

        uint256[] memory batch = hub.psisOf(pools, tAs, tBs);
        assertEq(batch.length, 4);
        for (uint256 i; i < 4; ++i) {
            assertEq(
                batch[i],
                hub.getPsi(pools[i], TA, TB),
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
