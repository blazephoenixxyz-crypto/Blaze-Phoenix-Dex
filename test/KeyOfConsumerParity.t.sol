// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  `keyOf` - the registry key every consumer reads and writes through.
//
//  One definition (Hub.keyOf, also what the Solver asks), so consumer parity rests on
//  two relational properties any coherent definition must hold, pinned here without
//  asserting the formula: the key does not depend on the order the pair is named in
//  (a consumer that asks "in/out" and one that asks "pair" must land on the same row),
//  and it separates pools and pairs (a constant key would pass the first property
//  vacuously). An order-sensitive key would write and read one pool under two keys -
//  duplicated state no unit test of keyOf alone would see.
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";

contract KeyOfConsumerParityTest is Test {
    BlazePhoenixHub hub;

    address constant POOL_A = address(0xA11CE);
    address constant POOL_B = address(0xB0B);
    address constant TOK_LO = address(0x1111);
    address constant TOK_HI = address(0x9999);

    function setUp() public { hub = new BlazePhoenixHub(address(this)); }

    function test_KeyIsOrderInvariant() public view {
        assertEq(hub.keyOf(POOL_A, TOK_LO, TOK_HI), hub.keyOf(POOL_A, TOK_HI, TOK_LO),
            "keyOf moved with the token order: two consumers would see two keys");
    }

    /// The negative control the property above needs: a keyOf that always returned the
    /// same value would pass it.
    function test_KeyDistinguishesPoolAndPair() public view {
        bytes32 kAPair1 = hub.keyOf(POOL_A, TOK_LO, TOK_HI);
        bytes32 kBPair1 = hub.keyOf(POOL_B, TOK_LO, TOK_HI);
        bytes32 kAPair2 = hub.keyOf(POOL_A, TOK_LO, address(0xF00D));
        assertTrue(kAPair1 != kBPair1, "two pools on one pair share a key");
        assertTrue(kAPair1 != kAPair2, "one pool on two pairs shares a key");
        assertTrue(kAPair1 != bytes32(0), "the key collides with the zero sentinel");
    }
}
