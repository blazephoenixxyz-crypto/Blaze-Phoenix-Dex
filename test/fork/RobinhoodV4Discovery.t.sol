// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.36;

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../../src/BlazePhoenixHub.sol";
import {PoolInfo} from "../../src/BlazePhoenixCore.sol";

// =============================================================================
//  Robinhood Chain (id 4663) fork proof for permissionless, on-chain-VERIFIED
//  Uniswap-V4 discovery (`claimV4`). Uniswap V4 has no factory/pair enumeration
//  (a singleton PoolManager), so the only autonomous discovery shape is
//  populate-once / read-forever; `claimV4` makes that population safe by proving
//  the pool on-chain instead of trusting the caller.
//
//  SAFE-GATE asserted here (owner scope "safe gate only"): a live HOOKLESS pool
//  is admitted and becomes routable; every ineligible claim FAILS CLOSED —
//  no bridge anchor, a non-existent pool, and a native-currency key all revert.
//  Delta-hook and native-ETH deep pools stay deferred by construction.
//
//  Addresses are test-only constants (never in src/ — the PoolManager is Hub
//  runtime config, keeping the pattern universal across EVM chains). Verified
//  live 2026-08-12 against the Robinhood V4 PoolManager via extsload.
// =============================================================================
contract RobinhoodV4DiscoveryTest is Test {
    BlazePhoenixHub hub;

    address constant V4_MGR = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant WETH   = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant USDG   = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168; // Paxos USDG (the chain's dollar)
    address constant SPAC   = 0x6b711B581aDDe09158B5B26Df9ed428cAf8479B1;
    address constant MOMO   = 0xe37E4a8b3D14274a3fdE3D841dE65E83E2a943aC;

    // Verified live: a hookless SPAC/USDG V4 pool at fee 50000, tickSpacing 100.
    uint24 constant SPAC_USDG_FEE = 50000;
    int24  constant SPAC_USDG_TS  = 100;

    function setUp() public {
        vm.createSelectFork("robinhood");
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), V4_MGR);
        hub.addBridge(WETH);
        hub.addBridge(USDG);
    }

    /// A live hookless pool anchored on a bridge is claimable and becomes a
    /// routable candidate; re-claiming is idempotent (no duplicate entry).
    function test_ClaimV4_AdmitsLiveHooklessPool() public {
        bytes32 key = hub.claimV4(USDG, SPAC, SPAC_USDG_FEE, SPAC_USDG_TS);
        assertTrue(key != bytes32(0), "claim returned empty key");

        PoolInfo[] memory pools = hub.getActivePools(SPAC, USDG);
        assertGt(pools.length, 0, "claimed pool is not an active candidate");

        bytes32 key2 = hub.claimV4(USDG, SPAC, SPAC_USDG_FEE, SPAC_USDG_TS);
        assertEq(key2, key, "idempotent re-claim changed the key");
        assertEq(
            hub.getActivePools(SPAC, USDG).length, pools.length,
            "re-claim created a duplicate registry entry"
        );
    }

    /// Fail-closed: neither currency is a bridge anchor (anti-spam gate).
    function test_ClaimV4_RejectsNoBridgeAnchor() public {
        vm.expectRevert();
        hub.claimV4(SPAC, MOMO, SPAC_USDG_FEE, SPAC_USDG_TS);
    }

    /// Fail-closed: a hookless pool that does not exist on-chain (wrong
    /// fee/spacing) cannot be claimed — the existence proof reverts.
    function test_ClaimV4_RejectsNonexistentPool() public {
        vm.expectRevert();
        hub.claimV4(USDG, SPAC, 333, 7);
    }

    /// Fail-closed: a native-currency (address(0)) key is never a valid claim.
    function test_ClaimV4_RejectsNativeCurrency() public {
        vm.expectRevert();
        hub.claimV4(address(0), SPAC, 2500, 25);
    }
}
