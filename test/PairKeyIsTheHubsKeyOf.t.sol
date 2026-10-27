// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// T16 (transplant 2, 2026-10-27): a pool's registry key has two producers. `Hub.keyOf` writes and
// reads the registry; `BPC.pairKey` is the same word computed in the reader's own frame, so
// `Math._mutedVotes` stops asking the Hub for a pure function of its own arguments (one external
// call per muted-vote candidate). Two producers of one quantity are tied by a test or they drift:
// this file is that test (SHARED_QUANTITIES `keyOf`). The named case is deterministic, so the
// mutant that drops the sort dies on it; the fuzz case covers the rest of the domain.
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
