// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  F2 — `v4Entries` IS UNBOUNDED AND PERMISSIONLESSLY GROWN, AND TWO CONSUMERS
//       STILL WALK IT LINEARLY.
//
//  Every V4 registration door writes the O(1) index `v4EntryOf`:
//      addV4              Hub:734
//      claimV4            Hub:825
//      recordSwap V4      Hub:1562
//      recordSwap NATIVE  Hub:1589
//  `seedPool` (Hub:1826-1834) does not — and it deliberately does NOT filter
//  kind (stated as guarantee H2, Hub:31-33), so `kind = KIND_V4` is a legal
//  argument to it. The row it creates then falls into the linear scan the index
//  exists to avoid:
//
//      Hub:1351   uint256 ep = $.v4EntryOf[key];
//      Hub:1352   if (ep != 0) { ... return p; }          // the O(1) path
//      Hub:1364   uint256 vn = $.v4Entries.length;
//      Hub:1365   for (uint256 vi; vi < vn; ) { ... }     // the O(N) path
//
//  whose own comment calls itself "unreachable for pools registered after this
//  fix". `_readPoolInfo` is reached from `getActivePools`, which the Solver
//  calls once per hop of per topology (`_topKPools`, Solver:1253) — and
//  `swapBestExactIn` runs that solve ON CHAIN.
//
//  The second consumer is `_recoverV4Ts` step 5 (Hub:1279-1290), reached from
//  `recordSwap` through `_noteV4Code` (Hub:1518) on EVERY routed V4 swap whose
//  learned code, generator inverse, canonical tiers and factory extras all
//  miss. `recordSwap` sits inside the Router's try/catch (Router:2015) — and a
//  callee that runs out of gas leaves the caller 1/64 of what it had, which is
//  usually not enough to finish `_execute`. The USER'S SWAP dies, not just the
//  registration.
//
//  GROWTH IS PERMISSIONLESS. `claimV4` (Hub:771) pushes one entry per new key,
//  gated by "one side is a routable bridge", "the pool is live with non-zero
//  liquidity" and `_canInsert` — none of which binds an attacker who mints a
//  FRESH token per pool: a fresh pair has zero occupied slots, so the insert
//  always succeeds. No ceiling exists anywhere in the contract.
//
//  THIS FILE USES `addV4` AS THE FLOOD VECTOR, not `claimV4`, purely to avoid
//  standing up a PoolManager mock: the two push byte-identical entries onto the
//  same array, and the property under test is the SCAN, not the door. Substitute
//  claimV4 against a fork PoolManager to price the attack in real money.
//
//  forge test --match-contract V4EntryScanUnbounded -vv
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixCore as BPC, PoolInfo} from "../src/BlazePhoenixCore.sol";

contract V4EntryScanUnboundedTest is Test {
    BlazePhoenixHub hub;

    uint24 constant FEE = 3000;
    int24  constant TS  = 60;

    /// A tier that is NOT canonical (500/10, 3000/60, 10000/200, 100/1), NOT a
    /// generator tier (fee % 10_000 == 0) and in no factory's extras — so
    /// `_recoverV4Ts` must fall all the way through to the step-5 array scan.
    uint24 constant ODD_FEE = 777;
    int24  constant ODD_TS  = 13;

    /// How many entries the flood adds. Kept modest so the suite stays fast;
    /// the attack has no ceiling, so scale this to taste.
    uint256 constant FLOOD = 200;

    /// Growth budget. An O(1) lookup must not move at all; this leaves room for
    /// memory-expansion noise and still fails loudly on a linear scan
    /// (~2.5k gas per scanned entry x 200 = ~500k).
    uint256 constant GROWTH_BUDGET = 50_000;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0xBEEF));
        // The test contract plays every role, including the Router, so
        // recordSwap can be driven directly.
        hub.setRoles(address(this), address(this), address(this));
    }

    // ─── helpers ─────────────────────────────────────────────────────────────

    /// The truncated-poolId address a hookless V4 pool registers under — the
    /// same derivation addV4 and claimV4 perform.
    function _poolAddr(address cA, address cB, uint24 fee, int24 ts)
        internal pure returns (address)
    {
        (address s0, address s1) = BPC.sortTokens(cA, cB);
        return address(uint160(uint256(
            BPC.computeV4PoolId(s0, s1, fee, ts, address(0))
        )));
    }

    function _tok(uint256 i) internal pure returns (address) {
        return address(uint160(0x1000_0000 + i));
    }

    /// Grow `v4Entries` by `n`, each on its OWN fresh pair so no pair ever
    /// reaches MAX_SLOTS and every push succeeds — the same shape an attacker
    /// gets from claimV4 with a freshly minted token per pool.
    function _flood(uint256 n) internal {
        for (uint256 i; i < n; ++i) {
            hub.addV4(_tok(2 * i + 1000), _tok(2 * i + 1001), FEE, TS, address(0));
        }
    }

    // ─── CONSUMER 1: getActivePools -> _readPoolInfo (the Solver's hot path) ──

    /// RED. A V4-kind row created through `seedPool` carries no `v4EntryOf`, so
    /// every `getActivePools` for its pair walks the whole global array. The
    /// cost of reading ONE pool must not depend on how many OTHER pools exist.
    function test_SeedPoolV4Row_FallsIntoUnboundedScan() public {
        address tX = _tok(1);
        address tY = _tok(2);
        address pool = _poolAddr(tX, tY, FEE, TS);

        // A V4 pool seeded through the generic operator door. Legal: seedPool
        // does not filter kind (H2, Hub:31-33).
        hub.seedPool(pool, BPC.KIND_V4, FEE, address(0), tX, tY);

        // Prove the row is live and the index is genuinely absent.
        PoolInfo[] memory before = hub.getActivePools(tX, tY);
        assertEq(before.length, 1, "the seeded V4 row must be an active candidate");
        // Since 2026-09-02 seedPool recovers the tickSpacing and writes the O(1)
        // index itself; before that this read 0 and the array walk was the only path.
        assertEq(before[0].tickSpacing, TS,
            "the seeded V4 row must resolve its V4Entry through the O(1) index");

        uint256 g0 = gasleft();
        hub.getActivePools(tX, tY);
        uint256 costEmpty = g0 - gasleft();

        _flood(FLOOD);
        // FLOOD + 1: the seeded row wrote its own entry (that is the fix).
        assertEq(hub.v4EntryCount(), FLOOD + 1, "the flood must have grown the global array");

        uint256 g1 = gasleft();
        hub.getActivePools(tX, tY);
        uint256 costFlooded = g1 - gasleft();

        emit log_named_uint("getActivePools gas, 0 other entries      ", costEmpty);
        emit log_named_uint("getActivePools gas, FLOOD other entries  ", costFlooded);
        emit log_named_uint("growth per foreign entry (gas)           ",
            costFlooded > costEmpty ? (costFlooded - costEmpty) / FLOOD : 0);

        assertLt(costFlooded, costEmpty + GROWTH_BUDGET,
            "reading ONE pool got more expensive because OTHER pools exist: the Solver's per-solve cost grows with a permissionlessly grown array");
    }

    /// CONTROL (green today). The same pool registered through `addV4` writes
    /// `v4EntryOf`, so the lookup is O(1) and the flood is invisible. This is
    /// what the seedPool row should look like.
    function test_AddV4Row_IsO1_Control() public {
        address tX = _tok(3);
        address tY = _tok(4);
        hub.addV4(tX, tY, FEE, TS, address(0));

        uint256 g0 = gasleft();
        hub.getActivePools(tX, tY);
        uint256 costEmpty = g0 - gasleft();

        _flood(FLOOD);

        uint256 g1 = gasleft();
        PoolInfo[] memory after_ = hub.getActivePools(tX, tY);
        uint256 costFlooded = g1 - gasleft();

        assertEq(after_[0].tickSpacing, TS, "the O(1) index resolved the entry");
        assertLt(costFlooded, costEmpty + GROWTH_BUDGET,
            "the indexed path must be flat in the global entry count");
    }

    // ─── CONSUMER 2: recordSwap -> _noteV4Code -> _recoverV4Ts step 5 ────────

    /// RED. Two identical V4 pools at a non-canonical tier, one registered
    /// BEFORE the flood (entry index 0) and one AFTER it (entry index FLOOD).
    /// `_recoverV4Ts` returns on the first matching entry, so the second pays
    /// for every entry the attacker inserted in between. This runs on the
    /// user's swap, inside a try/catch whose 1/64 gas remainder cannot finish
    /// `_execute`.
    function test_RecordSwap_WalksTheArrayUpToTheRowsIndex() public {
        address eA = _tok(11);
        address eB = _tok(12);
        hub.addV4(eA, eB, ODD_FEE, ODD_TS, address(0));      // entry index 0
        address poolEarly = _poolAddr(eA, eB, ODD_FEE, ODD_TS);

        _flood(FLOOD);

        address lA = _tok(21);
        address lB = _tok(22);
        hub.addV4(lA, lB, ODD_FEE, ODD_TS, address(0));      // entry index FLOOD+1
        address poolLate = _poolAddr(lA, lB, ODD_FEE, ODD_TS);

        // Tick the EARLY row: the scan stops almost immediately.
        uint256 g0 = gasleft();
        hub.recordSwap(poolEarly, BPC.KIND_V4, ODD_FEE, address(0), eA, eB, 1, 1, 1e18);
        uint256 costEarly = g0 - gasleft();

        // Tick the LATE row: same work, but the scan walks past the flood.
        uint256 g1 = gasleft();
        hub.recordSwap(poolLate, BPC.KIND_V4, ODD_FEE, address(0), lA, lB, 1, 1, 1e18);
        uint256 costLate = g1 - gasleft();

        emit log_named_uint("recordSwap gas, entry at index 0        ", costEarly);
        emit log_named_uint("recordSwap gas, entry after the flood   ", costLate);
        // The recovery must actually SUCCEED for the late pool (the learned
        // code is written only on success): otherwise a recovery that merely
        // gives up fast would pass the gas bound below for the wrong reason.
        assertTrue(hub.v4CodeOf(lA) != 0 && hub.v4CodeOf(lB) != 0,
            "the late pool's tier must be recovered through the O(1) index, not abandoned");

        assertLt(costLate, costEarly + GROWTH_BUDGET,
            "a swap's registration cost depends on how many foreign V4 entries were inserted before this pool was listed");
    }
}
