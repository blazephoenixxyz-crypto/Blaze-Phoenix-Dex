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
//   - dust moves no clock: neither a tick without the anchor bit nor a trade under 2^-16 of the
//     depth;
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
    /// the clock existed, to the wei. Kills "score division removed" (v = c * S) and any change
    /// of the horizon.
    function testFuzz_FixedClock_IsTodaysVitality(uint256 slot, uint32 ts, bool unmeasured) public pure {
        slot = _withTau(slot, unmeasured ? 0 : uint32(S / M));
        assertEq(BPC.vitality(slot, ts), _vitalityOld(slot, ts), "vitality moved at the fixed clock");
    }

    function testFuzz_FixedClock_IsTodaysDecayedCount(uint256 slot, uint32 ts, bool unmeasured) public {
        ClockHarness h = new ClockHarness();
        slot = _withTau(slot, unmeasured ? 0 : uint32(S / M));
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

    /// Any tau, any instant: no revert, and dead exactly past 32 steps of m * tau (tau 0 reads
    /// the prior step S). tau at its 32-bit ceiling does not overflow the step.
    function testFuzz_AnyClock_NoDivisionByZeroOrOverflow(uint32 lastTs, uint32 count, uint32 tau, uint32 ts)
        public
        pure
    {
        lastTs = uint32(bound(lastTs, 1, type(uint32).max));
        uint256 s = _slot(lastTs, count, tau);
        uint256 v = BPC.vitality(s, ts);
        uint256 h = tau == 0 ? S : uint256(tau) * M;
        uint256 age = ts > lastTs ? ts - lastTs : 0;
        if (age / h > 31) assertEq(v, 0, "past 32 steps must be dead");
        else assertGt(v, 0, "a live slot never scores 0");
        // a tick on any clock keeps tau inside its samples and its 32 bits
        uint256 t = BPC.tickSlot(s, true, 1e18, ts);
        uint256 dt = ts > lastTs ? ts - lastTs : 0;
        uint256 nt = BPC.decodeTau(t);
        if (tau == 0) assertEq(nt, dt, "first interval");
        else {
            assertLe(nt, tau > dt ? tau : dt, "tau left its samples (above)");
            assertGe(nt, tau < dt ? tau : dt, "tau left its samples (below)");
        }
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
