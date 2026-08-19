// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixCore as BPC, PoolInfo} from "../src/BlazePhoenixCore.sol";

// Recovered from adversarial audit workflow wf_8e3fd5d8 (2026-08-18).
// _register (BlazePhoenixHub.sol) has no key-existence guard, so addV4/seedPool on an
// already-registered pair unconditionally `ks.push(key)` a DUPLICATE key into pairKeys,
// and getActivePools does not dedup -> the same pool is listed twice, inflating the O(n)
// hot-path scan getActivePools walks on every quote.
// RED-FIRST: getActivePools must return exactly one entry for a pair seeded/added twice
// with identical params. Present code returns 2 -> these assertions FAIL. After a fix that
// guards _register (or dedups getActivePools): return 1 -> green.
contract DupKeyReproTest is Test {
    BlazePhoenixHub hub;
    address tokenA = address(0x1111);
    address tokenB = address(0x2222);

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0xBEEF));
        hub.setRoles(address(this), address(this), address(this));
    }

    function test_AddV4TwiceDuplicatesPairKey() public {
        bytes32 k1 = hub.addV4(tokenA, tokenB, 500, 10, address(0));
        bytes32 k2 = hub.addV4(tokenA, tokenB, 500, 10, address(0));
        assertEq(k1, k2, "same params -> same key");
        PoolInfo[] memory pools = hub.getActivePools(tokenA, tokenB);
        emit log_named_uint("getActivePools length after double addV4", pools.length);
        emit log_named_uint("v4EntryCount", hub.v4EntryCount());
        assertEq(pools.length, 1, "duplicate pair key: same V4 pool listed twice by getActivePools");
    }

    function test_SeedPoolTwiceDuplicatesPairKey() public {
        address pool = address(0xdeadbeef);
        hub.seedPool(pool, BPC.KIND_V2, 30, address(0), tokenA, tokenB);
        hub.seedPool(pool, BPC.KIND_V2, 30, address(0), tokenA, tokenB);
        PoolInfo[] memory pools = hub.getActivePools(tokenA, tokenB);
        emit log_named_uint("getActivePools length after double seedPool", pools.length);
        assertEq(pools.length, 1, "duplicate pair key: same seeded pool listed twice by getActivePools");
    }
}
