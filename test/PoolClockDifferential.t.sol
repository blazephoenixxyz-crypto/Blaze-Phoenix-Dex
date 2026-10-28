// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// THE POOL'S OWN CLOCK (2026-10-27). Vitality decayed every pool by one fixed step of
// 24 576 s: a pool that trades every ten seconds kept a stale row for 9 days after it stopped,
// and a pool that trades once a week died between two honest trades. Each row now carries tau,
// the exponential mean of the intervals between its anchored ticks, in the 32 bits that held a
// last-touch block nobody read, and decays one step per m taus. The score is the decayed count
// per step, scaled to trades per 24 576 s.
//
// What this file pins, each with the mutant it kills (.github/scripts/mutants.py, "VT:" rows):
//   - the DIFFERENTIAL: at tau = 24 576 / m, and at tau = 0 (not yet measured), vitality and the
//     decayed count are the pre-change functions to the wei;
//   - a fast pool dies after 32 * m of its own intervals of silence; a weekly pool outlives the
//     old 9-day horizon;
//   - the clock: the first anchored interval IS tau, later ones move it by 2^-k, over the
//     PREVIOUS stamp, and it converges;
//   - tau = 0 and the extremes of tau never divide by zero or overflow;
//   - any clock, read and ticked, is its definition, written here by hand (fuzz, every regime
//     drawn by construction);
//   - a tick decays the count on the OLD clock before it moves it; the count saturates;
//   - dust moves no clock: neither a tick without the anchor bit nor a trade under 2^-16 of the
//     depth, nor a zero leg, nor a trade on a pool with no depth;
//   - the score is a rate: equal counts on different clocks score in inverse ratio.
//
// forge test --match-path test/PoolClockDifferential.t.sol -vv

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixCore as BPC} from "../src/BlazePhoenixCore.sol";
import {MockOriginFactory, Origin} from "./mocks/MockOriginFactory.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";
import {MockPair} from "./DiscoveryRefreshMonoslot.t.sol";

/// A token whose decimals the test picks: the anchor compares normalised amounts.
contract ClockToken {
    uint8 public immutable decimals;
    mapping(address => uint256) public balanceOf;
    constructor(uint8 d) { decimals = d; }
    function mint(address to, uint256 a) external { balanceOf[to] += a; }
}

/// Exposes the Core's internal decayed count for the differential.
contract ClockHarness {
    function decayed(uint256 s, uint32 ts) external pure returns (uint32) { return BPC._decayedSwapCount(s, ts); }
}

contract PoolClockDifferentialTest is Test {
    /// The constants the simulation fixed, pinned here BY VALUE: a test that read them from the
    /// Core would move with a mutant of them.
    uint256 constant S = 24_576;   // VITALITY_DECAY_STEP_SECONDS: unit of the rate, prior step
    uint256 constant K = 3;        // TAU_EMA_SHIFT
    uint256 constant M = 4;        // VITALITY_STEPS_PER_TAU

    uint256 constant TAU_MASK = uint256(0xFFFFFFFF) << 224;

    // ─── the pre-change functions, verbatim (BlazePhoenixCore.sol @ 3e150b4:2516-2570) ───

    function _vitalityOld(uint256 slot, uint32 currentTs) internal pure returns (uint256 v) {
        v = uint256(_decayedOld(slot, currentTs));
        if (v != 0) return v;
        uint32 lastTs = BPC.decodeLastUpdateTs(slot);
        if (lastTs == 0) return 0;
        uint32 age = currentTs > lastTs ? currentTs - lastTs : 0;
        if (age / S > 31) return 0;
        return 1;
    }

    function _decayedOld(uint256 slot, uint32 currentTs) internal pure returns (uint32) {
        uint32 lastTs = BPC.decodeLastUpdateTs(slot);
        if (lastTs == 0) return 0;
        uint32 swapCount = BPC.decodeSwapCount(slot);
        uint32 age = currentTs > lastTs ? currentTs - lastTs : 0;
        if (age < S) return swapCount;
        uint256 shift = age / S;
        if (shift > 31) return 0;
        return uint32(uint256(swapCount) >> shift);
    }

    function _withTau(uint256 slot, uint32 tau) internal pure returns (uint256) {
        return (slot & ~TAU_MASK) | (uint256(tau) << 224);
    }

    uint256 constant LAST_TS_MASK = uint256(0xFFFFFFFF) << 64;

    /// Any slot, restamped at a lastTs in [1, 2^32 - 1 - 40 * S] (so 40 steps after it still fit
    /// 32 bits), on the fixed clock (tau = S / m) or the unmeasured one (tau = 0).
    function _fixedClockSlot(uint256 slot, uint32 lastTs, bool unmeasured) internal pure returns (uint256) {
        lastTs = uint32(bound(lastTs, 1, type(uint32).max - 40 * S));
        slot = (slot & ~LAST_TS_MASK) | (uint256(lastTs) << 64);
        return _withTau(slot, unmeasured ? 0 : uint32(S / M));
    }

    /// THE DEFINITION, by hand, not the Core's arithmetic: a clock of tau seconds steps once per
    /// m taus (an unmeasured clock, tau 0, once per S); each whole step since the stamp halves the
    /// count; 32 whole steps kill the slot, as does never having been stamped; the score is the
    /// surviving count per step in trades per S, and a live slot never scores below 1. Steps
    /// are counted by walking the deadlines (stamp + n * step <= now) and the count is halved by
    /// division: no shift and no division of the age, so a slip in either is not mirrored here.
    function _byDefinition(uint32 lastTs, uint32 count, uint32 tau, uint32 ts)
        internal pure returns (bool dead, uint256 c, uint256 v)
    {
        uint256 step = M * uint256(tau);
        if (tau == 0) step = S;
        if (lastTs == 0 || uint256(lastTs) + 32 * step <= ts) return (true, 0, 0);
        c = count;
        for (uint256 n = 1; uint256(lastTs) + n * step <= ts; ++n) c /= 2;
        v = c * S / step;
        if (v == 0) v = 1;
    }

    function _slot(uint32 lastTs, uint32 count, uint32 tau) internal pure returns (uint256) {
        return BPC.encodeSlot(true, 500, 1, 2, 0, lastTs, 0, 0, count, 0, tau);
    }

    /// Anchored ticks every `dt` seconds from `t`, `n` of them; returns the slot and the last ts.
    function _ticks(uint256 s, uint32 t, uint32 dt, uint256 n) internal pure returns (uint256, uint32) {
        for (uint256 i; i < n; ++i) {
            t += dt;
            s = BPC.stampTs(BPC.tickSlot(s, true, 1e18, t), t);
        }
        return (s, t);
    }

    // ─── 1. THE DIFFERENTIAL ───────────────────────────────────────────────────────────────

    /// At tau = S / m the step is S: every slot, at every instant, scores what it scored before
    /// the clock existed, to the wei. Kills "score division removed" (v = c * S), any change of
    /// the horizon, and "an unmeasured clock has no prior step" (tau 0, h = 0). The instant is
    /// drawn within 40 steps of the slot's own stamp: 32 of the 40 are live, where the count
    /// halves, 8 are dead. A free uint32 pair (stamp, now) was live in ~2e-4 of the runs and
    /// compared 0 with 0; the clock running backwards and the never-stamped slot are in
    /// test_FixedClock_Cases.
    function testFuzz_FixedClock_IsTodaysVitality(uint256 slot, uint32 lastTs, uint256 age, bool unmeasured)
        public
        pure
    {
        slot = _fixedClockSlot(slot, lastTs, unmeasured);
        uint32 ts = BPC.decodeLastUpdateTs(slot) + uint32(bound(age, 0, 40 * S));
        assertEq(BPC.vitality(slot, ts), _vitalityOld(slot, ts), "vitality moved at the fixed clock");
    }

    function testFuzz_FixedClock_IsTodaysDecayedCount(uint256 slot, uint32 lastTs, uint256 age, bool unmeasured)
        public
    {
        ClockHarness h = new ClockHarness();
        slot = _fixedClockSlot(slot, lastTs, unmeasured);
        uint32 ts = BPC.decodeLastUpdateTs(slot) + uint32(bound(age, 0, 40 * S));
        assertEq(h.decayed(slot, ts), _decayedOld(slot, ts), "decayed count moved at the fixed clock");
    }

    /// The branches by hand: same step, alive-rounded, last live step, first dead step, never
    /// stamped, clock running backwards.
    function test_FixedClock_Cases() public pure {
        uint32 t0 = 1_000_000;
        uint32 tau = uint32(S / M);
        uint256 s = _slot(t0, 5, tau);
        uint32[7] memory at = [t0, t0 + uint32(S) - 1, t0 + uint32(S), t0 + uint32(3 * S),
                               t0 + uint32(32 * S) - 1, t0 + uint32(32 * S), t0 - 1];
        for (uint256 i; i < at.length; ++i) {
            assertEq(BPC.vitality(s, at[i]), _vitalityOld(s, at[i]), "case");
            assertEq(BPC.vitality(_withTau(s, 0), at[i]), _vitalityOld(s, at[i]), "case, unmeasured");
        }
        assertEq(BPC.vitality(_slot(0, 5, tau), t0), 0, "never stamped is dead");
        assertEq(BPC.vitality(s, t0 + uint32(32 * S) - 1), 1, "last live step floors to 1");
        assertEq(BPC.vitality(s, t0 + uint32(32 * S)), 0, "32 steps: dead, not rounded");
    }

    // ─── 2. DEATH ON THE POOL'S OWN CLOCK ──────────────────────────────────────────────────

    /// A pool trading every 10 s, then silent: dead after 32 * m * tau, alive one second
    /// before. On the old fixed step it lived 9 days. Kills "fixed step instead of tau".
    function test_FastPool_DiesFast_AfterItStops() public pure {
        uint32 t0 = 1_000_000;
        uint256 s = BPC.stampTs(BPC.tickSlot(_slot(t0, 0, 0), false, 1e18, t0), t0);
        (s, t0) = _ticks(s, t0, 10, 200);
        uint256 tau = BPC.decodeTau(s);
        assertEq(tau, 10, "a steady 10 s rhythm is a 10 s clock");
        uint32 death = t0 + uint32(32 * M * tau);
        assertGt(BPC.vitality(s, death - 1), 0, "alive one second before 32 * m of its intervals");
        assertEq(BPC.vitality(s, death), 0, "dead at 32 * m of its own intervals, not 9 days");
    }

    /// A pool trading once a week outlives the old horizon (32 * 24 576 s ~ 9.1 days) between
    /// two honest trades, and still dies on its own clock. Kills "fixed step instead of tau".
    function test_WeeklyPool_LivesBetweenItsTrades() public pure {
        uint32 week = 7 days;
        uint32 t0 = 1_000_000;
        uint256 s = BPC.stampTs(BPC.tickSlot(_slot(t0, 0, 0), false, 1e18, t0), t0);
        (s, t0) = _ticks(s, t0, week, 6);
        assertEq(BPC.decodeTau(s), week, "the first interval is tau, a steady rhythm keeps it");
        assertGt(BPC.vitality(s, t0 + uint32(32 * S) + 1), 0, "a weekly pool died at the old horizon");
        assertGt(BPC.vitality(s, t0 + 2 * week), 0, "a weekly pool died after one missed trade");
        assertEq(BPC.vitality(s, t0 + uint32(32 * M) * week), 0, "it still dies, on its own clock");
    }

    // ─── 3. THE CLOCK ──────────────────────────────────────────────────────────────────────

    /// The first anchored interval after registration IS tau; the next moves it by 2^-k of the
    /// difference, up and down, over the PREVIOUS stamp. Exact values: kills "swap k", "dt
    /// inverted" and "the new lastTs instead of the old".
    function test_Clock_FirstIntervalThenEma_Exact() public pure {
        uint32 t0 = 1_000_000;
        uint256 s = _slot(t0, 1, 0);
        s = BPC.stampTs(BPC.tickSlot(s, true, 1e18, t0 + 1_000), t0 + 1_000);
        assertEq(BPC.decodeTau(s), 1_000, "first interval since registration");
        s = BPC.stampTs(BPC.tickSlot(s, true, 1e18, t0 + 1_100), t0 + 1_100);
        assertEq(BPC.decodeTau(s), 1_000 - ((1_000 - 100) >> K), "a short interval pulls tau down by 2^-k");
        uint256 tau = BPC.decodeTau(s);
        s = BPC.stampTs(BPC.tickSlot(s, true, 1e18, t0 + 1_100 + 5_000), t0 + 1_100 + 5_000);
        assertEq(BPC.decodeTau(s), tau + ((5_000 - tau) >> K), "a long interval pushes tau up by 2^-k");
    }

    /// From any start, a steady rhythm pulls tau to within 2^k of it (the integer EMA's fixed
    /// band) and keeps it there: the clock converges.
    function testFuzz_Clock_Converges(uint32 tau0, uint16 dt) public pure {
        tau0 = uint32(bound(tau0, 1, 365 days));
        dt = uint16(bound(dt, 1, type(uint16).max));
        uint32 t0 = 1_000_000;
        uint256 s = _slot(t0, 1, tau0);
        (s, ) = _ticks(s, t0, dt, 400);
        uint256 tau = BPC.decodeTau(s);
        assertGe(tau + (1 << K), dt, "tau stuck below the rhythm");
        assertLe(tau, uint256(dt) + (1 << K), "tau stuck above the rhythm");
    }

    // ─── 4. ZERO AND THE EXTREMES ──────────────────────────────────────────────────────────

    /// Any clock, read and ticked, is its definition (_byDefinition, and the EMA written from the
    /// clock's own words): the score, the decayed count, and an anchored tick's new tau and count,
    /// all exact. The regimes are drawn by construction, not by luck: 1/8 unmeasured (tau 0, the
    /// prior step S); 1/8 free (any tau up to its 32-bit ceiling, any instant: no division by
    /// zero, no overflow); 1/4 an interval shorter than tau (the EMA's downward arm); 1/2 an
    /// instant within 40 steps of m * tau (32 live, where the count halves, and 8 dead).
    function testFuzz_AnyClock_DecaysAndTicksByItsDefinition(
        uint32 lastTs, uint32 count, uint32 tau, uint256 age, uint8 regime
    ) public pure {
        uint32 ts;
        regime %= 8;
        if (regime == 1) {
            lastTs = uint32(bound(lastTs, 1, type(uint32).max));
            ts = uint32(age);
        } else {
            lastTs = uint32(bound(lastTs, 1, type(uint32).max - 40 * M * 10_000));
            tau = regime == 0 ? 0 : uint32(bound(tau, 1, 10_000));
            if (regime == 2 || regime == 3) age = bound(age, 0, tau - 1);
            else age = bound(age, 0, 40 * (regime == 0 ? S : M * tau));
            ts = lastTs + uint32(age);
        }
        uint256 s = _slot(lastTs, count, tau);
        (, uint256 c, uint256 v) = _byDefinition(lastTs, count, tau, ts);
        assertEq(BPC.vitality(s, ts), v, "the score is not the definition's");
        assertEq(BPC._decayedSwapCount(s, ts), c, "the decayed count is not the definition's");

        // An anchored tick: the count it carries is what survives plus this trade, at most the
        // field's ceiling; the first interval IS tau, a later one moves it by 2^-k of the gap.
        uint256 t = BPC.tickSlot(s, true, 1e18, ts);
        uint256 dt = ts > lastTs ? ts - lastTs : 0;
        uint256 want;
        if (tau == 0) want = dt;
        else if (dt >= tau) want = tau + (dt - tau) / 2 ** K;
        else want = tau - (tau - dt) / 2 ** K;
        assertEq(BPC.decodeTau(t), want, "the tick moved tau off its EMA");
        assertEq(BPC.decodeSwapCount(t), c == type(uint32).max ? c : c + 1,
            "the tick did not count from what survives on the old clock");
    }

    /// A tick that closes an interval longer than the step (dt > m * tau) decays the count on the
    /// clock that ran over that interval, the OLD tau, and only then moves tau. 64 trades on a
    /// 100 s clock (step 400 s) ticked 1 200 s later: 3 steps, 64 / 2^3 = 8, plus this trade, 9;
    /// tau moves to 100 + (1 200 - 100) / 2^3 = 237. Decayed on the new clock (step 948 s) the
    /// same interval is one step: 64 / 2 + 1 = 33. Kills "the count decays after tau moves".
    function test_Tick_CountDecaysOnTheOldClock_ThenTheClockMoves() public pure {
        uint32 t0 = 1_000_000;
        uint256 t = BPC.tickSlot(_slot(t0, 64, 100), true, 1e18, t0 + 1_200);
        assertEq(BPC.decodeSwapCount(t), 9, "the count decays on the clock that ran over the interval");
        assertEq(BPC.decodeTau(t), 237, "and the clock moves by 2^-k of the gap");
        // The same interval unanchored moves no clock and decays the count alike.
        t = BPC.tickSlot(_slot(t0, 64, 100), false, 1e18, t0 + 1_200);
        assertEq(BPC.decodeSwapCount(t), 9, "unanchored: same decay");
        assertEq(BPC.decodeTau(t), 100, "unanchored: same clock");
    }

    /// A count at its 32-bit ceiling stays there: the trade counts as far as the field goes,
    /// never wraps to 0 and never carries into tau above it. One under the ceiling reaches it.
    /// Kills "the saturation removed".
    function test_Tick_CountSaturatesAtItsCeiling() public pure {
        uint32 t0 = 1_000_000;
        uint32 max = type(uint32).max;
        uint256 t = BPC.tickSlot(_slot(t0, max, 100), true, 1e18, t0 + 10);
        assertEq(BPC.decodeSwapCount(t), max, "the ceiling holds");
        assertEq(BPC.decodeTau(t), 100 - (100 - 10) / 2 ** K, "and tau is its own: nothing carried into it");
        t = BPC.tickSlot(_slot(t0, max - 1, 100), true, 1e18, t0 + 10);
        assertEq(BPC.decodeSwapCount(t), max, "one under the ceiling is counted to it");
    }

    function test_SmallestClock_IsSafe() public pure {
        uint256 s = _slot(1_000, 7, 1);
        assertEq(BPC.vitality(s, 1_000), 7 * S / M, "tau = 1: an m-second step, 7 trades in it");
        assertEq(BPC.vitality(s, 1_000 + uint32(32 * M)), 0, "and dead after 32 steps of it");
        assertEq(BPC.vitality(_slot(1_000, 7, type(uint32).max), type(uint32).max), 1,
            "tau at its ceiling: the step does not overflow, the live rate floors to 1");
    }

    // ─── 5. DUST MOVES NO CLOCK ────────────────────────────────────────────────────────────

    /// A tick without the anchor counts (the count's own dust vector, unchanged) but never
    /// moves tau. Kills "tickSlot ignores the anchor".
    function testFuzz_UnanchoredTick_MovesNoClock(uint32 lastTs, uint32 tau, uint32 ts, uint256 depth) public pure {
        uint256 s = _slot(lastTs, 3, tau);
        assertEq(BPC.decodeTau(BPC.tickSlot(s, false, depth, ts)), tau, "an unanchored tick moved tau");
    }

    /// The anchor is the trade's shorter normalised side against 2^-16 of the depth, the
    /// Gate's materiality rule. Just under: no bit. At it: the bit. Mixed decimals (6 / 18)
    /// read the same pool both ways. Kills "every tick anchors" in the producer.
    function test_TickDepth_AnchorsOnlyAMaterialTrade() public {
        ClockToken a = new ClockToken(6);
        ClockToken b = new ClockToken(18);
        (address t0, address t1) = address(a) < address(b) ? (address(a), address(b)) : (address(b), address(a));
        MockV2Pair p = new MockV2Pair(t0, t1);
        // 4 000 000 units of the 6-dec token against 1 000 units of the 18-dec token: price 4 000.
        uint256 r6 = 4_000_000e6;
        uint256 r18 = 1_000e18;
        (uint112 r0, uint112 r1) = t0 == address(a) ? (uint112(r6), uint112(r18)) : (uint112(r18), uint112(r6));
        p.setReserves(r0, r1);
        a.mint(address(p), r6);
        b.mint(address(p), r18);
        uint256 depth = BPC.registryDepth18(address(p), BPC.KIND_V2, t0, t1, address(0), bytes32(0));
        assertEq(depth, 1_000e18, "the short side, normalised: the 18-dec token");
        uint256 thr = depth >> 16;               // in 18-dec units of the short side's token
        bool zf18 = t0 == address(b);            // selling the 18-dec token is zeroForOne iff it is t0
        // material: thr of the 18-dec token in, thr * 4 000 of the 6-dec token out
        uint256 w = BPC.tickDepth18(address(p), BPC.KIND_V2, t0, t1, address(0), bytes32(0),
                                    thr, thr * 4_000 / 1e12, zf18);
        assertEq(w & (BPC.TICK_ANCHORED - 1), depth, "the depth word carries the depth");
        assertTrue(w >= BPC.TICK_ANCHORED, "a material trade anchors");
        // the other direction, same trade size: 6-dec token in
        w = BPC.tickDepth18(address(p), BPC.KIND_V2, t0, t1, address(0), bytes32(0),
                            thr * 4_000 / 1e12, thr, !zf18);
        assertTrue(w >= BPC.TICK_ANCHORED, "a material trade anchors from either side");
        // one unit under on the short side: dust
        w = BPC.tickDepth18(address(p), BPC.KIND_V2, t0, t1, address(0), bytes32(0),
                            thr - 1, thr * 4_000 / 1e12, zf18);
        assertEq(w, depth, "a trade under 2^-16 of the depth anchors nothing");
        // the same dust, sold from the other side
        w = BPC.tickDepth18(address(p), BPC.KIND_V2, t0, t1, address(0), bytes32(0),
                            (thr - 1) * 4_000 / 1e12, thr - 1, !zf18);
        assertEq(w, depth, "dust from the other side anchors nothing");
    }

    /// Nothing anchors without a trade or without a depth. A zero leg on a dust pool: its
    /// threshold (1 000 wei >> 16) is 0 and 0 >= 0, so only `a != 0` refuses it. A real trade
    /// on a pool whose depth reads 0: 0 >> 16 is 0 too, so only `depth != 0` refuses it. Kills the
    /// removal of either guard.
    function test_TickDepth_NoTradeOrNoDepth_AnchorsNothing() public {
        ClockToken a = new ClockToken(18);
        ClockToken b = new ClockToken(18);
        (address t0, address t1) = address(a) < address(b) ? (address(a), address(b)) : (address(b), address(a));
        MockV2Pair dust = new MockV2Pair(t0, t1);
        dust.setReserves(1_000, 1_000);
        a.mint(address(dust), 1_000);
        b.mint(address(dust), 1_000);
        uint256 depth = BPC.registryDepth18(address(dust), BPC.KIND_V2, t0, t1, address(0), bytes32(0));
        assertEq(depth, 1_000, "setup: a pool 1 000 wei deep");
        assertEq(depth >> 16, 0, "setup: its threshold rounds to 0");
        uint256 w = BPC.tickDepth18(address(dust), BPC.KIND_V2, t0, t1, address(0), bytes32(0), 5, 0, true);
        assertEq(w, depth, "a leg that paid nothing anchors nothing");
        w = BPC.tickDepth18(address(dust), BPC.KIND_V2, t0, t1, address(0), bytes32(0), 0, 5, false);
        assertEq(w, depth, "a leg that took nothing anchors nothing");
        // control: one wei each way anchors the dust pool (1 >= 0)
        w = BPC.tickDepth18(address(dust), BPC.KIND_V2, t0, t1, address(0), bytes32(0), 1, 1, true);
        assertEq(w, depth | BPC.TICK_ANCHORED, "control: a trade on the dust pool anchors");

        MockV2Pair empty = new MockV2Pair(t0, t1);
        assertEq(BPC.registryDepth18(address(empty), BPC.KIND_V2, t0, t1, address(0), bytes32(0)), 0,
            "setup: a pool with no depth");
        w = BPC.tickDepth18(address(empty), BPC.KIND_V2, t0, t1, address(0), bytes32(0), 1e18, 1e18, true);
        assertEq(w, 0, "a trade on a pool with no depth anchors nothing");
    }

    // ─── 6. THE SCORE IS A RATE ────────────────────────────────────────────────────────────

    /// Equal decayed counts on clocks 10 s and 1 000 s apart score 100x apart: the score is the
    /// count per step, in trades per S. Kills "score division removed".
    function test_Score_IsTheRate() public pure {
        uint256 fast = _slot(1_000, 4, 10);
        uint256 slow = _slot(1_000, 4, 1_000);
        assertEq(BPC.vitality(fast, 1_000), 4 * S / (10 * M), "fast");
        assertEq(BPC.vitality(slow, 1_000), 4 * S / (1_000 * M), "slow");
        assertEq(BPC.vitality(fast, 1_000) / 100, BPC.vitality(slow, 1_000), "inverse ratio");
    }
}

/// The Hub's door: the anchor bit travels in the Router's depth word, the Hub clears it before
/// the depth is used, and ticks BEFORE it stamps, so the interval closes on the old stamp.
contract PoolClockHubTest is Test {
    BlazePhoenixHub hub;
    address constant TA = address(0xAAA1);
    address constant TB = address(0xBBB2);
    uint8 constant KIND_V3 = 1;
    uint256 constant DEPTH = 1_000_000e18;
    MockOriginFactory origem;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        hub.setRoles(address(this), address(this), address(this));
        origem = Origin.tiers(hub, KIND_V3, 2);
    }

    function _rec(address pool, uint256 depthWord) internal {
        hub.recordSwap(pool, KIND_V3, 500, address(0), TA, TB, 1e18, 1e18, depthWord);
    }

    function _seated() internal returns (address p, bytes32 key) {
        p = address(new MockPair(TA, TB));
        origem.list(p, TA, TB, 1, false);
        vm.warp(1_000_000);
        _rec(p, DEPTH | BPC.TICK_ANCHORED);         // registration: closes no interval
        key = hub.keyOf(p, TA, TB);
        assertEq(BPC.decodeTau(hub.getSlot(key)), 0, "a registration measures no clock");
    }

    /// An anchored tick 100 s after registration sets tau = 100: the Hub ticked over the OLD
    /// stamp. Kills "stamp before tick" (tau would read a 0 interval).
    function test_Hub_AnchoredTick_ClosesTheIntervalOnTheOldStamp() public {
        (address p, bytes32 key) = _seated();
        vm.warp(1_000_100);
        _rec(p, DEPTH | BPC.TICK_ANCHORED);
        uint256 s = hub.getSlot(key);
        assertEq(BPC.decodeTau(s), 100, "tau is the interval since the previous stamp");
        assertEq(BPC.decodeBucket(s), BPC.depthBucket(DEPTH), "the anchor bit never reaches the bucket");
    }

    /// The same tick without the bit counts but moves no clock. Kills "every tick anchors" at
    /// the Hub.
    function test_Hub_DustTick_MovesNoClock() public {
        (address p, bytes32 key) = _seated();
        vm.warp(1_000_100);
        _rec(p, DEPTH);
        uint256 s = hub.getSlot(key);
        assertEq(BPC.decodeTau(s), 0, "an unanchored tick moved the clock");
        assertEq(BPC.decodeSwapCount(s), 2, "it still counts, as before");
    }
}
