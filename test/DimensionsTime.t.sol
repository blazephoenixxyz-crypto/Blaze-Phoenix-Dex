// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// Extrapolating the invariants-and-time lens (docs/INVARIANTS_AND_TIME.md in the Staking
// repository, https://github.com/blazephoenixxyz-crypto/Blaze-Phoenix-Staking, written for the
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
import {Origin} from "./mocks/MockOriginFactory.sol";

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
        // and, since rizki-3107, on a wired factory deriving it.
        Origin.wire(hub, pool, tokenA, tokenB, BPC.KIND_V2, 30);
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
        // fix-1102 A: was block.timestamp; now the cheatcode, because the history below warps from t0 and a via_ir build may re-read block.timestamp after a warp (the note above)
        uint256 t0 = vm.getBlockTimestamp();

        // Build up 50 "real" swaps worth of history.
        // fix-1102 A: was 50 dust swaps in one second; now 50 material ones a second apart, because only an anchored tick that closes a real interval moves the clock (BlazePhoenixCore.sol:2898)
        for (uint256 i; i < 50; ++i) {
            vm.warp(t0 + i);
            hub.recordSwap(pool, BPC.KIND_V2, 0, address(0), tokenA, tokenB, 1e18, 1e18, 1_000_000e18 | BPC.TICK_ANCHORED);
        }
        uint256 tLast = t0 + 49;
        uint32 scAfterHistory = BPC.decodeSwapCount(hub.getSlot(key));
        // fix-1102 A: was 50 because the registration ticked the new row; now 49 because a row is born with swapCount 0 (BlazePhoenixHub.sol:2168) and the chord takes c * 1 / (2 * 4 * tau) = 0 from each one-second interval while 8 * tau > c (tau ends at 7: 56 > 49) (BlazePhoenixCore.sol:2642)
        assertEq(scAfterHistory, 49);
        uint256 vitalityAfterHistory = BPC.vitality(hub.getSlot(key), uint32(tLast));
        // fix-1102 A: was 50, the count on the unmeasured step (h = 24 576); now 43 008 = 49 * 24 576 / (4 * 7), because the 49 one-second intervals pulled tau from 24 576 / 4 down to 7 and the score is the rate on that step (BlazePhoenixCore.sol:2904-2908, :2598)
        assertEq(vitalityAfterHistory, 43_008, "fresh activity: vitality should read the real recent rate");

        // Go fully quiet for longer than the full-decay window (32 steps * 24_576s ~= 9.11 days).
        uint256 t1 = t0 + 10 days;
        vm.warp(t1);
        uint256 vitalityWhileDead = BPC.vitality(hub.getSlot(key), uint32(t1));
        assertEq(vitalityWhileDead, 0, "fully decayed: this pool should read as dead to any route scorer");

        // ONE small reactivating swap — the kind of dust trade anyone (including the pool's own
        // deployer) could send for a few cents of gas.
        // fix-1102 A: that dust trade now revives nothing: an unanchored tick leaves the clock, so the dead row's psi stays where it was (BlazePhoenixCore.sol:2898)
        uint256 psiDead = BPC.psi(hub.getSlot(key), uint32(t1), false, false);
        hub.recordSwap(pool, BPC.KIND_V2, 0, address(0), tokenA, tokenB, 1e18, 1e18, 1_000_000e18);
        assertEq(BPC.psi(hub.getSlot(key), uint32(t1), false, false), psiDead, "dust does not pump psi");
        // fix-1102 A: was the dust trade above; now a material one, because only an anchored tick counts: decayed 0 + 1 = 1, tau 7 + (863 951 - 7 + 7) / 8 = 108 000, score 24 576 / (4 * 108 000) = 0, floor 1 (BlazePhoenixCore.sol:2637, :2900-2907, :2599)
        hub.recordSwap(pool, BPC.KIND_V2, 0, address(0), tokenA, tokenB, 1e18, 1e18, 1_000_000e18 | BPC.TICK_ANCHORED);

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

    // ── tau's EMA, the falling branch ─────────────────────────────────────────────────────────────
    // RED at d2cf5c9 with mutant "Core:3242" applied (src/BlazePhoenixCore.sol:3242, the
    // falling step flipped to `+=`); GREEN at HEAD. Spec: tau moves 1/8 of the way to the interval
    // just closed, rounded up (a non-zero gap moves it by at least 1), and never past it.

    uint32 internal constant TAU_LAST_TS = 1_000;

    function _tauAfter(uint32 tau0, uint32 dt, bool anchored) internal pure returns (uint32) {
        uint256 slot = (uint256(tau0) << 224) | (uint256(TAU_LAST_TS) << 64);
        return BPC.decodeTau(BPC.tickSlot(slot, anchored, 1e18, TAU_LAST_TS + dt));
    }

    function test_TauFallsWhenTheIntervalShrinks() public pure {
        // dt 1 000 < tau 100 000: 100 000 - ceil(99 000 / 8) = 100 000 - 12 375
        assertEq(_tauAfter(100_000, 1_000, true), 87_625, "a shorter interval pulls tau down");
        // control, the rising side: 100 000 + ceil(100 000 / 8)
        assertEq(_tauAfter(100_000, 200_000, true), 112_500, "a longer interval pushes tau up");
        // edges: dt == tau leaves it; dt == tau - 1 moves it by exactly 1 (ceil(1/8) = 1)
        assertEq(_tauAfter(100_000, 100_000, true), 100_000, "dt == tau: no step");
        assertEq(_tauAfter(100_000, 99_999, true), 99_999, "one second shorter: one second down");
        assertEq(_tauAfter(100_000, 100_001, true), 100_001, "one second longer: one second up");
        // an unanchored tick leaves the clock (REG-DUST-CLOCK)
        assertEq(_tauAfter(100_000, 1_000, false), 100_000, "an unanchored tick moves no tau");
    }

    function testFuzz_TauMovesTowardDtAndNeverPastIt(uint32 tau0, uint32 dt) public pure {
        tau0 = uint32(bound(tau0, 1, 1 << 31));
        dt = uint32(bound(dt, 1, 1 << 31));
        uint32 t = _tauAfter(tau0, dt, true);
        uint32 lo = tau0 < dt ? tau0 : dt;
        uint32 hi = tau0 < dt ? dt : tau0;
        assertGe(t, lo, "tau never passes dt from above");
        assertLe(t, hi, "tau never passes dt from below");
        uint256 gap = hi - lo;
        uint256 step = t > tau0 ? t - tau0 : tau0 - t;
        assertEq(step, (gap + 7) / 8, "one eighth of the gap, rounded up");
        if (dt > tau0) assertGe(t, tau0, "a longer interval never lowers tau");
        if (dt < tau0) assertLe(t, tau0, "a shorter interval never raises tau");
    }
}
