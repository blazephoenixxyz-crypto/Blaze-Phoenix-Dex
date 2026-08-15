// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  V1 / I11 regression — per-key O(1) v4EntryOf map replaces the unbounded
//  linear scan of the global v4Entries array when getActivePools recovers a
//  V4 pool's tickSpacing (_readPoolInfo).
//
//  Why the scan was wrong, not just slow: it matched a registered pool's
//  V4Entry on (currency0, currency1, fee, hooks) and broke on the FIRST hit.
//  A V4 poolId also hashes tickSpacing, so the SAME pair at the SAME fee can
//  legitimately exist twice with different tickSpacings — two distinct pools,
//  two distinct registry keys — and the scan reported the first entry's
//  tickSpacing for BOTH. Since tickSpacing is part of the poolId the quote
//  path recomputes, the second pool would be quoted at a poolId that does not
//  exist (zero state, dead venue). The map is written at every registration
//  site (addV4 / claimV4 / recordSwap-side registration) under keyOf(poolAddr,
//  s0, s1), so each pool recovers exactly its OWN entry, and the lookup cost
//  no longer grows with the global entry count.
//
//  This suite pins, functionally (gas-boundedness itself is not asserted):
//    (a) several same-pair V4 pools at DIFFERENT (fee, tickSpacing) tiers each
//        come back from getActivePools with their own tickSpacing;
//    (b) the aliasing case the old scan got WRONG: same pair, same fee,
//        different tickSpacings — each pool resolves its own entry;
//    (c) after many extra v4Entries for OTHER pairs (including same-fee
//        decoys) flood the global array, a specific pool's tickSpacing still
//        resolves correctly — the map hits regardless of array size.
//
//  forge test --match-contract HardeningV1_V4ScanBounded -vv
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixCore as BPC, PoolInfo} from "../src/BlazePhoenixCore.sol";

contract HardeningV1_V4ScanBoundedTest is Test {
    BlazePhoenixHub hub;
    address admin = address(this);
    address tokenA = address(0x1111);
    address tokenB = address(0x2222);

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(admin, address(0xBEEF));
        hub.setRoles(address(this), address(this), address(this));
    }

    /// @dev The truncated-poolId address a hookless V4 pool registers under —
    ///      the same derivation addV4 performs (computeV4PoolId on the sorted
    ///      pair, hooks = 0, cast to address).
    function _poolAddr(address cA, address cB, uint24 fee, int24 ts)
        internal pure returns (address)
    {
        (address s0, address s1) = BPC.sortTokens(cA, cB);
        return address(uint160(uint256(
            BPC.computeV4PoolId(s0, s1, fee, ts, address(0))
        )));
    }

    /// @dev Locate a pool by address in a getActivePools result.
    function _find(PoolInfo[] memory pools, address pool)
        internal pure returns (bool found, PoolInfo memory p)
    {
        for (uint256 i; i < pools.length; ++i) {
            if (pools[i].pool == pool) return (true, pools[i]);
        }
    }

    // ── (a) distinct tiers on one pair: each pool owns its tickSpacing ────

    function test_V4EntryOf_EachPoolResolvesItsOwnTickSpacing() public {
        // Three canonical hookless tiers on the SAME pair. Distinct fees =>
        // distinct poolIds => three registry slots and three v4Entries.
        hub.addV4(tokenA, tokenB, 500, 10, address(0));
        hub.addV4(tokenA, tokenB, 3000, 60, address(0));
        hub.addV4(tokenA, tokenB, 10000, 200, address(0));
        assertEq(hub.v4EntryCount(), 3, "three entries pushed");

        PoolInfo[] memory active = hub.getActivePools(tokenA, tokenB);
        assertEq(active.length, 3, "all three pools active on the pair");

        uint24[3] memory fees = [uint24(500), uint24(3000), uint24(10000)];
        int24[3] memory tss = [int24(10), int24(60), int24(200)];
        for (uint256 i; i < 3; ++i) {
            (bool found, PoolInfo memory p) =
                _find(active, _poolAddr(tokenA, tokenB, fees[i], tss[i]));
            assertTrue(found, "registered pool missing from getActivePools");
            assertEq(uint256(p.kind), uint256(BPC.KIND_V4), "kind must be V4");
            assertEq(uint256(p.fee), uint256(fees[i]), "fee mismatch");
            assertEq(
                int256(p.tickSpacing), int256(tss[i]),
                "v4EntryOf must resolve the pool's OWN tickSpacing"
            );
        }
    }

    // ── (b) the aliasing shape the old scan resolved WRONG ────────────────

    function test_V4EntryOf_SameFeeDifferentTickSpacing_NoCrossPoolAliasing() public {
        // Same pair, SAME fee, different tickSpacings: two DISTINCT V4 pools
        // (tickSpacing is hashed into the poolId). The removed scan matched
        // entries on (pair, fee, hooks) and broke on the first hit, so BOTH
        // pools reported tickSpacing 60 — quoting the second at a poolId that
        // does not exist. The map must give each pool its own entry.
        hub.addV4(tokenA, tokenB, 3000, 60, address(0));
        hub.addV4(tokenA, tokenB, 3000, 200, address(0));

        address pool60 = _poolAddr(tokenA, tokenB, 3000, 60);
        address pool200 = _poolAddr(tokenA, tokenB, 3000, 200);
        assertTrue(pool60 != pool200, "sanity: distinct pools");

        PoolInfo[] memory active = hub.getActivePools(tokenA, tokenB);
        assertEq(active.length, 2, "both same-fee pools active");

        (bool f60, PoolInfo memory p60) = _find(active, pool60);
        (bool f200, PoolInfo memory p200) = _find(active, pool200);
        assertTrue(f60 && f200, "both pools must be returned");
        assertEq(int256(p60.tickSpacing), int256(60), "first pool keeps ts=60");
        assertEq(
            int256(p200.tickSpacing), int256(200),
            "second pool must NOT alias to the first same-fee entry's tickSpacing"
        );
    }

    // ── (c) map hits regardless of global v4Entries size ──────────────────

    function test_V4EntryOf_ResolvesCorrectlyRegardlessOfGlobalEntryCount() public {
        // A same-pair, same-fee decoy with a DIFFERENT tickSpacing is pushed
        // FIRST, so any first-match scan over v4Entries would resolve the
        // target to ts=200; then the target itself; then 40 foreign-pair
        // entries (several sharing the target's fee) flood the global array.
        hub.addV4(tokenA, tokenB, 500, 200, address(0)); // decoy, entry index 0
        hub.addV4(tokenA, tokenB, 500, 10, address(0)); // target
        address target = _poolAddr(tokenA, tokenB, 500, 10);

        for (uint256 i; i < 40; ++i) {
            address cX = address(uint160(0xA000 + 2 * i));
            address cY = address(uint160(0xA001 + 2 * i));
            // Cycle fees so many foreign entries share the target's fee=500
            // with alien tickSpacings — none of them may pollute the target.
            uint24 fee = i % 2 == 0 ? 500 : 3000;
            int24 ts = int24(int256(20 + i));
            hub.addV4(cX, cY, fee, ts, address(0));
        }
        assertEq(hub.v4EntryCount(), 42, "global array grew: 2 + 40 foreign");

        PoolInfo[] memory active = hub.getActivePools(tokenA, tokenB);
        assertEq(active.length, 2, "foreign pairs never join this pair's slots");

        (bool found, PoolInfo memory p) = _find(active, target);
        assertTrue(found, "target pool missing");
        assertEq(uint256(p.fee), uint256(500), "target fee intact");
        assertEq(
            int256(p.tickSpacing), int256(10),
            "target must resolve ITS entry despite the earlier same-fee decoy and 40 foreign entries"
        );

        // The decoy resolves its own entry too — no bleed in either direction.
        (bool foundDecoy, PoolInfo memory d) =
            _find(active, _poolAddr(tokenA, tokenB, 500, 200));
        assertTrue(foundDecoy, "decoy pool missing");
        assertEq(int256(d.tickSpacing), int256(200), "decoy keeps its own tickSpacing");
    }
}
