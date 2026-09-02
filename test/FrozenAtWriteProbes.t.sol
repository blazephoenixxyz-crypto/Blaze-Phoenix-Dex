// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// FROZEN-AT-WRITE PROBES — one instrument per row of the pattern that the
// SHARED_QUANTITIES.md register calls OPEN.
//
// The pattern (7th bounty wave, 2026-09-02): a quantity is WRITTEN once, at
// registration, and READ later as if it were live — while the thing it
// describes has moved. Three shapes of it:
//
//   1. a bit frozen at registration, read as a live predicate
//      (`bridged`, Monoslot bit 7 — BRIDGE-01);
//   2. a field the storage has no room for, so the reader answers a constant
//      (`stable` — SLOT-01, `_readPoolInfo` returns `false` unconditionally);
//   3. a mass declared by the object being weighed, taken as measured
//      (`getReserves` of a synthetic pair — PROV-01).
//
// Every `test_probe_*` asserts the quantity FOLLOWS its source. Each was RED
// against the tree that carried the OPEN row (2026-09-02: 6400 != 5120 and
// 4096 != 5120 for the bridge bit, a `false` for `stable`, -0.99% on the
// fallback curve, 0 honest legs for the forged mass) and went green with the
// producer fixed in the same change: the bridge answer read live, the pool's
// own `stable()` persisted in bit 5, declared reserves capped by physical
// holdings. The probes are now the pins, and mutants.py guards each fix.
//
// Every `test_control_*` shows the same pattern done right elsewhere in the
// same contract (a codehash pinned at admission and compared LIVE; a tier
// refreshed in place). They exist so that a green probe cannot be mistaken
// for a probe that could never fail.

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixCore as BPC, RoutePlan, Leg, PoolInfo} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";
import {MockSolidlyPair} from "./mocks/MockSolidlyPair.sol";

contract FrozenAtWriteProbes is Test {
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    MockERC20 tA;
    MockERC20 tB;

    // Large on purpose: with a tiny impact the Solver takes one leg and the
    // single-leg path never meets the band (see BandBaseBreakdownPoint).
    uint256 constant ORDER = 300_000e18;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0xBEEF));
        solver = new BlazePhoenixSolver(address(hub));
        // this = router (recordSwap) and quoter; admin/operator/control = this (initialize).
        hub.setRoles(address(this), address(solver), address(this));
        tA = new MockERC20("A", "A");
        tB = new MockERC20("B", "B");
    }

    // ─── helpers ────────────────────────────────────────────────────────────

    /// @dev A funded V2 pair at (rA of tA, rB of tB), registered through the
    ///      router door four times (vitality 4, so psi is divisible by 4 and
    ///      the +25% bridge bonus is exact).
    function _v2(uint112 rA, uint112 rB) private returns (MockV2Pair p) {
        p = new MockV2Pair(address(tA), address(tB));
        tA.mint(address(p), rA);
        tB.mint(address(p), rB);
        _setOriented(p, rA, rB);
        uint256 depth = rA < rB ? rA : rB;
        for (uint256 i; i < 4; i++) {
            hub.recordSwap(address(p), BPC.KIND_V2, 30, address(0),
                address(tA), address(tB), 1e18, 1e18, depth);
        }
    }

    /// @dev Reserves by TOKEN, not by slot: the mock sorts token0/token1 by
    ///      address, and a price that is bad for tA→tB must stay bad whichever
    ///      side tA landed on.
    function _setOriented(MockV2Pair p, uint112 rA, uint112 rB) private {
        if (p.token0() == address(tA)) p.setReserves(rA, rB);
        else p.setReserves(rB, rA);
    }

    function _key(address pool) private view returns (bytes32) {
        (address t0, address t1) = BPC.sortTokens(address(tA), address(tB));
        return hub.keyOf(pool, t0, t1);
    }

    function _legsOn(address pool) private view returns (uint256 onPool, uint256 elsewhere) {
        RoutePlan memory p = solver.findBestRoutePlan(address(tA), address(tB), ORDER);
        assertGt(p.best.hops.length, 0, "pre-condition: there must be a route");
        Leg[] memory legs = p.best.hops[0].legs;
        assertGt(legs.length, 0, "pre-condition: there must be legs");
        for (uint256 i; i < legs.length; i++) {
            if (legs[i].pool == pool) onPool++;
            else elsewhere++;
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  1. `bridged` (Monoslot bit 7) — register row BRIDGE-01
    // ═══════════════════════════════════════════════════════════════════════

    /// The bonus must LEAVE with the bridge. Registered while tA is a bridge,
    /// psi carries +25%; after removeBridge the live predicate says "not a
    /// bridge" and psi must say the same.
    function test_probe_bridgedBit_removeBridge_psiFollowsTheLiveBridge() public {
        hub.addBridge(address(tA));
        MockV2Pair p = _v2(400_000e18, 400_000e18);
        uint256 withBridge = hub.getPsi(address(p), address(tA), address(tB));
        assertGt(withBridge, 0, "pre-condition: live slot");

        hub.removeBridge(0);
        assertFalse(hub.isBridgeToken(address(tA)), "pre-condition: the mapping was cleared");

        uint256 without = hub.getPsi(address(p), address(tA), address(tB));
        // withBridge = f + f/4  =>  without must be f  =>  without * 5 == withBridge * 4
        assertEq(without * 5, withBridge * 4,
            "BRIDGE-01: psi keeps the +25% bridge bonus after the bridge is removed");
    }

    /// The mirror image: the bonus must ARRIVE with the bridge. A pool
    /// registered before tA became a bridge is anchored on it just the same.
    function test_probe_bridgedBit_addBridge_psiFollowsTheLiveBridge() public {
        MockV2Pair p = _v2(400_000e18, 400_000e18);
        uint256 without = hub.getPsi(address(p), address(tA), address(tB));
        assertGt(without, 0, "pre-condition: live slot");

        hub.addBridge(address(tA));
        assertTrue(hub.isBridgeToken(address(tA)), "pre-condition: the mapping was set");

        uint256 withBridge = hub.getPsi(address(p), address(tA), address(tB));
        assertEq(withBridge * 4, without * 5,
            "BRIDGE-01 (mirror): a pool registered before addBridge never earns the bonus");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  2. `stable` — register row SLOT-01
    // ═══════════════════════════════════════════════════════════════════════

    function _stablePool() private returns (MockSolidlyPair sp) {
        sp = new MockSolidlyPair(address(tA), address(tB), true);
        tA.mint(address(sp), 1_000_000e18);
        tB.mint(address(sp), 1_000_000e18);
        sp.setReserves(1_000_000e18, 1_000_000e18);
        hub.seedPool(address(sp), BPC.KIND_SOLIDLY, 0, address(0), address(tA), address(tB));
    }

    /// The registry must answer what the pool answers. The pool says
    /// stable() == true; the row read back through getActivePools must too.
    function test_probe_stableField_registryReadReturnsThePoolsAnswer() public {
        MockSolidlyPair sp = _stablePool();
        PoolInfo[] memory rows = hub.getActivePools(address(tA), address(tB));
        bool seen;
        for (uint256 i; i < rows.length; i++) {
            if (rows[i].pool != address(sp)) continue;
            seen = true;
            assertTrue(rows[i].stable, "SLOT-01: the registry reports a stable pool as volatile");
        }
        assertTrue(seen, "pre-condition: the seeded row is listed");
    }

    /// Standard Solidly pools expose getAmountOut, and every quote channel asks
    /// the pool FIRST — so on a standard pool the frozen flag never reaches the
    /// price. This is the bound on SLOT-01's blast radius, stated as a test.
    function test_control_stableField_standardPoolIsPricedByItsOwnGetter() public {
        MockSolidlyPair sp = _stablePool();
        uint256 order = 10_000e18;
        RoutePlan memory p = solver.findBestRoutePlan(address(tA), address(tB), order);
        assertGt(p.best.hops.length, 0, "pre-condition: there must be a route");
        assertEq(p.best.hops[0].expectedOut, sp.getAmountOut(order, address(tA)),
            "control: with getAmountOut available the quote is the pool's own number");
    }

    /// Forks without getAmountOut fall back to the replicated curve, and THAT
    /// path reads the registry flag. With the flag frozen at `false`, a stable
    /// pool is priced on the volatile curve: ~1% under the truth on a balanced
    /// 1M/1M pool for a 10k order (on top of the 200 bps haircut the fallback
    /// applies on purpose).
    function test_probe_stableField_fallbackCurveReadsTheRegistryFlag() public {
        MockSolidlyPair sp = _stablePool();
        sp.setHideGetAmountOut(true);
        uint256 order = 10_000e18;
        RoutePlan memory p = solver.findBestRoutePlan(address(tA), address(tB), order);
        assertGt(p.best.hops.length, 0, "pre-condition: there must be a route");
        // The curve the pool actually enforces, with the fallback's own haircut.
        uint256 truth = (BPC.outSolidly(order, 1_000_000e18, 1_000_000e18, 30, true) * 9800) / BPC.BPS;
        assertApproxEqRel(p.best.hops[0].expectedOut, truth, 1e14,
            "SLOT-01: the fallback priced a stable pool on the volatile curve");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  3. pool depth SOURCE — register row PROV-01
    // ═══════════════════════════════════════════════════════════════════════

    /// Three honest pools at the fair price hold 1.2M of real mass. A pair
    /// that DECLARES 3e30 of reserves while holding 1 token of each — at a
    /// price of 1:0.5 — must not capture the route: mass that nobody can
    /// verify is not mass. (BandBaseBreakdownPoint proves the weighted median
    /// is captured by >50% of the mass; this probe asks who gets to declare it.)
    function test_probe_forgedMass_cannotCaptureTheRouteWithoutCapital() public {
        _v2(400_000e18, 400_000e18);
        _v2(400_000e18, 400_000e18);
        _v2(400_000e18, 400_000e18);

        MockV2Pair forged = new MockV2Pair(address(tA), address(tB));
        tA.mint(address(forged), 1e18);
        tB.mint(address(forged), 1e18);
        _setOriented(forged, uint112(2e30), uint112(1e30));   // says: 1 tA buys 0.5 tB
        for (uint256 i; i < 4; i++) {
            // What the Router would record: depth read from the pool's own getReserves.
            hub.recordSwap(address(forged), BPC.KIND_V2, 30, address(0),
                address(tA), address(tB), 1e18, 1e18, 1e30);
        }

        (uint256 onForged, uint256 onHonest) = _legsOn(address(forged));
        assertGt(onHonest, 0, "PROV-01: the honest pools were pushed out of the route");
        assertEq(onForged, 0, "PROV-01: a pair with forged reserves and no capital captured the route");
    }

    /// Control: the same bad price with TRUE small mass is kept out. Without
    /// this, the probe above could pass because nobody was routed at all.
    function test_control_trueSmallMass_atABadPrice_isKeptOut() public {
        _v2(400_000e18, 400_000e18);
        _v2(400_000e18, 400_000e18);
        _v2(400_000e18, 400_000e18);
        MockV2Pair small = _v2(100_000e18, 50_000e18);   // real, funded, priced 1:0.5

        (uint256 onSmall, uint256 onHonest) = _legsOn(address(small));
        assertGt(onHonest, 0, "control: honest pools route");
        assertEq(onSmall, 0, "control: a small badly-priced pool is outside the band");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  The pattern done right — controls
    // ═══════════════════════════════════════════════════════════════════════

    /// hookCodehash is pinned at admission and compared LIVE: change the code
    /// and liveness follows. The shape BRIDGE-01 lacks, in the same contract.
    function test_control_hookCodehash_isPinnedAtAdmissionAndReadLive() public {
        address h = makeAddr("hook");
        vm.etch(h, hex"6001600155");
        hub.allowHook(h, true);
        assertTrue(hub.isHookLive(h), "pre-condition: admitted with its code pinned");

        vm.etch(h, hex"600160015500");
        assertFalse(hub.isHookLive(h), "control: liveness must follow the live codehash");

        hub.allowHook(h, true);   // re-admission re-pins
        assertTrue(hub.isHookLive(h), "control: re-listing pins the new code");
    }

    /// The tier is refreshed IN PLACE when an operator seeds a pool the router
    /// had already registered: one key, tier 0. The shape SLOT-01 lacks.
    function test_control_tier_isRefreshedInPlaceBySeedPool() public {
        MockV2Pair p = _v2(400_000e18, 400_000e18);
        bytes32 key = _key(address(p));
        assertEq(BPC.decodeTier(hub.getSlot(key)), 2, "pre-condition: router-registered rows are tier 2");

        hub.seedPool(address(p), BPC.KIND_V2, 0, address(0), address(tA), address(tB));
        assertEq(BPC.decodeTier(hub.getSlot(key)), 0, "control: seedPool promotes to tier 0");
        assertEq(hub.getActivePools(address(tA), address(tB)).length, 1,
            "control: the refresh happened in place, no duplicate key");
    }
}
