// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

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

contract DimensionsTimeTest is Test {
    BlazePhoenixHub hub;
    address tokenA = address(0x1111);
    address tokenB = address(0x2222);
    address pool = address(0x3333);

    function setUp() public {
        hub = new BlazePhoenixHub();
        hub.initialize(address(this), address(0xBEEF));
        hub.setRoles(address(this), address(this), address(this));
    }

    /// @notice R3 violation: tickSlot() increments the RAW stored swapCount forever and never
    ///         resets it — vitality()'s right-shift-by-age is applied only at READ time, purely
    ///         for display/scoring, and never written back. A pool that fully decays to zero
    ///         (no activity for >32 decay steps, ~9.1 days) then receives a SINGLE new swap does
    ///         not resume from "freshly seen, low history" — it instantly regains its ENTIRE
    ///         historical swapCount as vitality, because that count was never actually reduced in
    ///         storage. One trivial trade (e.g. the pool operator's own dust swap) can therefore
    ///         instantly resurrect a long-dead pool to its all-time-high route priority.
    function test_R3_SingleReactivatingSwapResurrectsFullHistoricalVitality() public {
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

        // What SHOULD happen for "price by what remains": a pool with zero recent activity that
        // just saw its first swap in 10 days should score like a brand-new/low-history pool
        // (vitality close to 1), not like one with 50 swaps of unbroken recent history.
        assertEq(scAfterRevival, 51,
            "the raw counter keeps 100% of the pre-decay history instead of resetting on revival");
        assertEq(vitalityAfterRevival, 51,
            "BUG: one dust swap after full decay instantly restores the ENTIRE historical vitality, "
            "identical to a pool that traded continuously for all 50 swaps with no quiet period");
    }
}
