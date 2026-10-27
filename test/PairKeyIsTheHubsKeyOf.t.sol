// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// T16 (transplant 2, 2026-10-27): `BPC.pairKey` is a pool's registry key computed in the reader's
// own frame, so `Math._mutedVotes` stops asking the Hub for a pure function of its own arguments
// (one external call per muted-vote candidate); `Solver._registryFresh` followed (T04-pairkey).
// Since T04-pairkey `Hub.keyOf`, the door the registry writes and reads through, returns
// `BPC.pairKey`: one producer. This file ties the door to it (SHARED_QUANTITIES `keyOf`): a
// `keyOf` that computes its own word drifts from `pairKey` here. With the door following the
// producer, the mutant that drops the sort in `pairKey` moves both sides and dies on the order
// invariance of `pairKey` itself (the third assertion); the fuzz case covers the rest.
import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixCore as BPC} from "../src/BlazePhoenixCore.sol";

contract PairKeyIsTheHubsKeyOfTest is Test {
    BlazePhoenixHub hub;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
    }

    /// @notice `pairKey` is `keyOf`, the pair named in either order.
    function test_PairKeyIsTheHubsKeyOf_BothOrders() public view {
        address pool = address(0xA11CE);
        address lo = address(0x1000);
        address hi = address(0x2000);
        assertEq(BPC.pairKey(pool, lo, hi), hub.keyOf(pool, lo, hi), "pairKey is keyOf, sorted order");
        assertEq(BPC.pairKey(pool, hi, lo), hub.keyOf(pool, hi, lo), "pairKey is keyOf, reversed order");
        assertEq(BPC.pairKey(pool, hi, lo), BPC.pairKey(pool, lo, hi), "the order the pair is named in does not matter");
    }

    function testFuzz_PairKeyIsTheHubsKeyOf(address pool, address tA, address tB) public view {
        assertEq(BPC.pairKey(pool, tA, tB), hub.keyOf(pool, tA, tB), "pairKey and keyOf drifted apart");
    }
}
