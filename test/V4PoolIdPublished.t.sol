// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  The V4 pool id this code derives is the id the canonical PoolManager
//  published - checked against a real pool, with no fork and no key.
//
//  The same check lives in test/fork/V4DynamicFeeDiscovery.t.sol, where it sat
//  behind the fork's DRPC_KEY skip - and outside the fast suite's path - so the
//  only independent pin of `computeV4PoolId` never ran locally (V4 campaign,
//  2026-09-23). The id is published on-chain by the Initialize event of the
//  aeon/WETH pool on Base (Doppler hook, dynamic fee, spacing 200); nothing in
//  this repository produced it.
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixCore as BPC} from "../src/BlazePhoenixCore.sol";

contract V4PoolIdPublishedTest is Test {
    address constant BASE_WETH = 0x4200000000000000000000000000000000000006;
    address constant AEON      = 0xBf8E8f0e8866a7052F948C16508644347c57aba3;
    address constant HOOK      = 0xbB7784A4d481184283Ed89619A3e3ed143e1Adc0;
    bytes32 constant POOL_ID   = 0x4a9b9e13975d26f4e3e17c655593bb82145dd4452aedafb826d856b817c9cfd4;

    function test_ThePublishedBasePoolIdIsReproducedByOurDerivation() public pure {
        (address s0, address s1) = BPC.sortTokens(BASE_WETH, AEON);
        assertEq(BPC.computeV4PoolId(s0, s1, 0x800000, int24(200), HOOK), POOL_ID,
            "our pool id is not the one the PoolManager published");
    }
}
