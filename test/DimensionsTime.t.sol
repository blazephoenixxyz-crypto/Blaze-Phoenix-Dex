// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// Extrapolating the invariants-and-time lens (docs/INVARIANTS_AND_TIME.md, written for the
// Staking contract) to the DEX's own time-integral quantity: BlazePhoenixCore.vitality(), which
// decides route priority. Rule R3 there: "Price by what remains, never by a historical scalar."
//
// forge test --match-contract DimensionsTime -vv
//
// ENVIRONMENT NOTE (see feedback_forge_stale_call_cache_bug in memory): this forge build reuses a
// stale result whenever the exact same call-site shape — including `block.timestamp` itself, or a
// call that embeds it inline — is evaluated more than once in a function, even for `pure`/inlined
// library calls. Every timestamp used below is captured into a local ONCE and reused from there.

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixCore as BPC} from "../src/BlazePhoenixCore.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";

contract DimensionsTimeTest is Test {
    BlazePhoenixHub hub;
    address tokenA = address(0x1111);
    address tokenB = address(0x2222);
    address pool;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0xBEEF));
        hub.setRoles(address(this), address(this), address(this));
        // Real pair mock: recordSwap gates first registration on token0()/token1()
        // matching the pair since fa6c847 (a codeless address is silently skipped).
        pool = address(new MockV2Pair(tokenA, tokenB));
    }

    /// @notice R3 regression: tickSlot() used to increment the RAW stored swapCount forever and
    ///         never reset it — vitality()'s right-shift-by-age was applied only at READ time,
    ///         purely for display/scoring, never written back. A pool fully decayed to zero (no
    ///         activity for >32 decay steps, ~9.1 days) that received a SINGLE new swap did not
    ///         resume from "freshly seen, low history" — it instantly regained its ENTIRE
    ///         historical swapCount as vitality, identical to a pool with no quiet period at all.
    ///         Fixed: tickSlot() now increments from _decayedSwapCount (the true decayed base),
    ///         so a reactivation after full decay starts at 1, not at the pre-decay total.
    function test_R3_ReactivationAfterFullDecayStartsFromTrueBaseNotHistoricalTotal() public {
        bytes32 key = hub.keyOf(pool, tokenA, tokenB);
        uint256 t0 = block.timestamp;

        // Build up 50 "real" swaps worth of history.
        for (uint256 i; i < 50; ++i) {
            hub.recordSwap(pool, BPC.KIND_V2, 0, address(0), tokenA, tokenB, 1e18, 1e18, 1_000_000e18);
        }
        uint32 scAfterHistory = BPC.decodeSwapCount(hub.getSlot(key));
        assertEq(scAfterHistory, 50);
        uint256 vitalityAfterHistory = BPC.vitality(hub.getSlot(key), uint32(t0));
        assertEq(vitalityAfterHistory, 50, "fresh activity: vitality should read the real recent count");

        // Go fully quiet for longer than the full-decay window (32 steps * 24_576s ~= 9.11 days).
        uint256 t1 = t0 + 10 days;
        vm.warp(t1);
        uint256 vitalityWhileDead = BPC.vitality(hub.getSlot(key), uint32(t1));
        assertEq(vitalityWhileDead, 0, "fully decayed: this pool should read as dead to any route scorer");

        // ONE small reactivating swap — the kind of dust trade anyone (including the pool's own
        // deployer) could send for a few cents of gas.
        hub.recordSwap(pool, BPC.KIND_V2, 0, address(0), tokenA, tokenB, 1e18, 1e18, 1_000_000e18);

        uint32 scAfterRevival = BPC.decodeSwapCount(hub.getSlot(key));
        uint256 vitalityAfterRevival = BPC.vitality(hub.getSlot(key), uint32(t1));

        // "Price by what remains": a pool with zero surviving activity that just saw its first
        // swap in 10 days must score like a brand-new/low-history pool (vitality == 1), never
        // like one with 50 swaps of unbroken recent history.
        assertEq(scAfterRevival, 1,
            "swapCount must restart from the decayed (zero) base plus this one swap, not the pre-decay total");
        assertEq(vitalityAfterRevival, 1,
            "a reactivation after full decay must score identically to a brand-new pool's first swap");
    }
}
