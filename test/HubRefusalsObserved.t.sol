// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  REFUSALS OBSERVED FIRING — Hub half.
//
//  Five registry refusals that had never been seen to fire, each with a
//  control test proving the SAME pipeline admits when only the refused
//  predicate is false — without the control, a "not admitted" assertion could
//  pass for setup reasons and prove nothing.
//
//    test_AddV4_UnlistedHookIsRefused              Hub:640   HubE(8)
//        guard deleted -> addV4 registers a pool behind an un-vetted hook and
//        returns; expectRevert fails. The allow-list is Layer 3 of the V4
//        no-allow-list design — this is its ONLY admission door.
//    test_ClaimV4_UnresolvableDynamicFeeIsRefused  Hub:735   HubE(9)
//        INV-20 fail-closed: dynamic-fee key + non-zero protocolFee has no
//        anchored composition, so the claim must die rather than register a
//        pool the Quoter prices at 0. guard deleted -> the claim registers
//        (poolOf set) and returns a key; expectRevert fails.
//    test_Discovery_NotLivePoolIsNotAdmitted       Hub:1038  (skip, view)
//        slot0 exists, liquidity == 0. guard deleted -> the static-fee
//        candidate passes the fee gate and IS emitted; the assertFalse on
//        discoverFor's hits fails.
//    test_Discovery_UnresolvableDynFeeNotAdmitted  Hub:1039  (skip, view)
//        live pool, dynamic fee, protocolFee != 0. guard deleted -> the
//        candidate is emitted; assertFalse fails.
//    test_Registry_FullPairEvictsInsteadOfGrowing  Hub:1685
//        the ONLY bounded-growth mechanism in the registry, never run before:
//        a 17th pool on a full pair must evict the weakest, hold the count at
//        MAX_SLOTS, and clear the evicted key's slot/poolOf. Deleting the
//        eviction block either grows ks to 17 (length assert fails) or, if
//        replaced by nothing, never lists the newcomer (membership assert
//        fails) — every mutation of the block trips at least one assertion.
//    test_Registry_EvictionClearsTheHookMapping    Hub:1702
//        guard deleted -> hooksOf survives eviction, and because _register
//        only writes hooksOf when hooks != 0, a re-registration of the SAME
//        key as hookless INHERITS the stale hook — getActivePools then
//        reports a hook the pool does not have. The assertEq on the reported
//        hooks fails. (This is why the line matters: eviction is the only
//        writer that ever clears that mapping.)
//
//  VERDICTS THAT ARE FINDINGS, NOT TESTS:
//
//  * Hub:873 `if (fac.mode >= 4 && fac.initHash == bytes32(0)) return k;`
//    UNREACHABLE from this deployment's own admission path. addFactory
//    refuses initHash == 0 for every CREATE2 mode (4-7, rule R1, Hub:593),
//    mode 8 is refused by MODES_VALID, and mode 9 — the one high mode that
//    MAY carry a zero initHash — is dispatched to _scanV4 at Hub:844, before
//    _probe can see it. The guard defends only legacy-storage rows admitted
//    under older rules. No test can take the branch through the public API;
//    fabricating one (vm.store into the factories array) would pin the
//    storage layout, not the behaviour. Either document it as
//    defence-in-depth or delete it — an owner call.
//
//  * Hub:926 `if (mgr == address(0)) return k;` — NOT INDEPENDENTLY
//    OBSERVABLE, so deliberately untested. If deleted, the scan probes
//    manager address(0): BPC.v4Slot0Batch and BPC.v4SqrtAndLiq both
//    zero-guard the manager themselves, every word reads zero, and _admitV4's
//    1038 skips the candidate anyway — identical outcome, hits and state.
//    A test here would pass with the guard's body deleted: theatre by this
//    file's own criterion. The fail-closed BEHAVIOUR (unconfigured manager
//    admits nothing) is real but is enforced three times over; 1038's test
//    below is the observable member of that family.
//
//  forge test --match-contract HubRefusalsObserved -vv
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixCore as BPC, PoolInfo} from "../src/BlazePhoenixCore.sol";

/// @dev Minimal V4 PoolManager state mock — same shape as the one proven in
///      V4LearnedCodeSuppressesGrid.t.sol: BOTH extsload forms over one
///      settable slot map, mirroring the StateLibrary layout the Core reads
///      (base = keccak256(abi.encode(poolId, 6)); slot0 at base, liquidity at
///      base + 3).
contract MockV4StateMgr {
    mapping(bytes32 => bytes32) public slots;

    function setSlot(bytes32 s, bytes32 v) external { slots[s] = v; }

    function extsload(bytes32 s) external view returns (bytes32) { return slots[s]; }

    function extsload(bytes32[] calldata targets) external view returns (bytes32[] memory out) {
        out = new bytes32[](targets.length);
        for (uint256 i; i < targets.length; ++i) out[i] = slots[targets[i]];
    }
}

contract HubRefusalsObservedTest is Test {
    BlazePhoenixHub hub;
    MockV4StateMgr mgr;

    // Sorted bare-address pair for the V4 tests (bridge < counter).
    address bridgeTok = address(0x1111); // routable bridge — claimV4's anchor
    address counter   = address(0x2222);
    // A second, independent pair for the eviction tests (sorted).
    address constant TOK_A = address(0xA11A);
    address constant TOK_B = address(0xB22B);

    address stranger = address(0xA11CE);
    address hookAddr = address(0x40CC);
    address dummyFactory = address(0xFAC7);

    // Pinned internal constants (blind-constant law: if the source values
    // drift, the assertions below must break loudly).
    uint8   constant MODE_V4_DERIVE = 9;   // Hub:244
    uint256 constant MAX_SLOTS      = 16;  // Hub:87
    uint24  constant DYN_FEE        = 0x800000; // V4 dynamic-fee sentinel (Core.effV4Fee)
    int24   constant DYN_TS         = 60;
    uint24  constant CANON_FEE      = 3000; // canonical tier — probed by _v4CanonicalTiers
    int24   constant CANON_TS       = 60;
    uint128 constant LIVE_LIQ       = 1e24;

    function setUp() public {
        mgr = new MockV4StateMgr();
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(mgr));
        // Router role deliberately unset: _scanV4 skips its native-ETH pass,
        // keeping discovery a pure ERC20 derive-scan (proven pattern).
        hub.addBridge(bridgeTok);
        // One MODE_V4_DERIVE row whose paired extras name the DYNAMIC tier —
        // the only way the derive-scan ever probes a dynamic-fee poolId.
        uint24[] memory fees = new uint24[](1);
        int24[]  memory sps  = new int24[](1);
        fees[0] = DYN_FEE; sps[0] = DYN_TS;
        hub.addFactory(dummyFactory, BPC.KIND_V4, MODE_V4_DERIVE, bytes32(0), fees, sps);
    }

    // ─── plumbing ────────────────────────────────────────────────────────────

    /// @dev Plant a hookless V4 pool in the manager's state at the exact
    ///      layout BPC reads. slot0 packing (verified against Core:1652-1659):
    ///      [0,160) sqrtPriceX96 | [160,184) tick | [184,208) protocolFee |
    ///      [208,232) lpFee. liq == 0 leaves the liquidity slot untouched.
    function _plant(uint24 fee, int24 ts, uint128 liq, uint24 protoFee, uint24 lpFee)
        private returns (address poolAddr)
    {
        (address s0, address s1) = BPC.sortTokens(bridgeTok, counter);
        bytes32 pid  = BPC.computeV4PoolId(s0, s1, fee, ts, address(0));
        bytes32 base = keccak256(abi.encode(pid, uint256(6)));
        uint256 w0 = uint256(BPC.Q96)
            | (uint256(protoFee) << 184)
            | (uint256(lpFee)    << 208);
        mgr.setSlot(base, bytes32(w0));
        if (liq != 0) mgr.setSlot(bytes32(uint256(base) + 3), bytes32(uint256(liq)));
        poolAddr = address(uint160(uint256(pid)));
    }

    function _contains(PoolInfo[] memory hits, address pool) private pure returns (bool) {
        for (uint256 i; i < hits.length; ++i) {
            if (hits[i].pool == pool) return true;
        }
        return false;
    }

    function _hooksReported(PoolInfo[] memory hits, address pool) private pure returns (address) {
        for (uint256 i; i < hits.length; ++i) {
            if (hits[i].pool == pool) return hits[i].hooks;
        }
        revert("pool not listed");
    }

    // =========================================================================
    //  1. Hub:640 — the hook allow-list at its only admission door
    // =========================================================================

    /// A hooked pool key whose hook was never allow-listed must be refused.
    /// DELETION-SENSITIVE: without the guard, addV4 registers the entry and
    /// returns a key — no revert, expectRevert fails.
    function test_AddV4_UnlistedHookIsRefused() public {
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixHub.HubE.selector, 8));
        hub.addV4(bridgeTok, counter, CANON_FEE, CANON_TS, hookAddr);
    }

    /// Control: the IDENTICAL call admits once the hook is allow-listed — the
    /// allow-list bit is the only thing separating refusal from admission.
    function test_AddV4_AllowlistedHookAdmits() public {
        hub.allowHook(hookAddr, true);
        bytes32 key = hub.addV4(bridgeTok, counter, CANON_FEE, CANON_TS, hookAddr);
        assertTrue(hub.getPool(key) != address(0),
            "the same key that HubE(8) refused must register once the hook is vetted");
    }

    // =========================================================================
    //  2. Hub:735 — claimV4's INV-20 fail-closed on an unresolvable fee
    // =========================================================================

    /// A LIVE pool (sqrtP != 0, liquidity != 0 — so this is NOT the Hub:733
    /// liveness refusal) whose key carries the dynamic-fee sentinel while
    /// slot0 shows a non-zero protocolFee: effV4Fee returns 0xFFFFFF and the
    /// permissionless claim must die HubE(9) instead of registering a pool
    /// that quotes to zero.
    /// DELETION-SENSITIVE: without the guard, the claim proceeds through
    /// depth admission on an empty pair (_canInsert is true below MAX_SLOTS)
    /// and REGISTERS — no revert, expectRevert fails.
    function test_ClaimV4_UnresolvableDynamicFeeIsRefused() public {
        _plant(DYN_FEE, DYN_TS, LIVE_LIQ, /*protoFee*/ 1, /*lpFee*/ 0);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixHub.HubE.selector, 9));
        hub.claimV4(bridgeTok, counter, DYN_FEE, DYN_TS);
    }

    /// Control: the same dynamic-fee claim with protocolFee == 0 resolves
    /// (effV4Fee = the measured lpFee) and registers.
    function test_ClaimV4_ResolvedDynamicFeeAdmits() public {
        address poolAddr = _plant(DYN_FEE, DYN_TS, LIVE_LIQ, /*protoFee*/ 0, /*lpFee*/ 3000);

        vm.prank(stranger);
        bytes32 key = hub.claimV4(bridgeTok, counter, DYN_FEE, DYN_TS);
        assertEq(hub.getPool(key), poolAddr,
            "a resolvable dynamic-fee pool must register through the same pipeline");
    }

    // =========================================================================
    //  3. Hub:1038 / Hub:1039 — the derive-scan's per-candidate fail-closed
    // =========================================================================

    /// Hub:1038 — slot0 initialized, liquidity zero: the candidate survives
    /// the batched slot0 filter (word0 != 0) and must then be dropped by the
    /// full verification. DELETION-SENSITIVE: without the guard the
    /// static-fee candidate passes the 1039 fee gate (3000 < 1e6) and is
    /// EMITTED with zero liquidity — assertFalse on the hits fails.
    function test_Discovery_NotLivePoolIsNotAdmitted() public {
        address dead = _plant(CANON_FEE, CANON_TS, /*liq*/ 0, 0, 0);

        PoolInfo[] memory hits = hub.discoverFor(bridgeTok, counter);
        assertFalse(_contains(hits, dead),
            "a pool with slot0 but no liquidity must not be admitted (fail closed)");
    }

    /// Control for 1038: the same tier WITH liquidity is admitted — proving
    /// the negative above fails for the guard's reason, not for a setup one.
    function test_Discovery_LivePoolIsAdmitted() public {
        address live = _plant(CANON_FEE, CANON_TS, LIVE_LIQ, 0, 0);

        PoolInfo[] memory hits = hub.discoverFor(bridgeTok, counter);
        assertTrue(_contains(hits, live),
            "the identical tier with liquidity must be discovered");
    }

    /// Hub:1039 — a LIVE dynamic-fee pool (probed via the factory row's
    /// paired extras) whose slot0 carries a non-zero protocolFee: effV4Fee is
    /// unresolvable (>= 1e6) and the candidate must be dropped.
    /// DELETION-SENSITIVE: without the guard the candidate passes 1038 (liq
    /// set) and is EMITTED — assertFalse fails.
    function test_Discovery_UnresolvableDynamicFeeIsNotAdmitted() public {
        address unquotable = _plant(DYN_FEE, DYN_TS, LIVE_LIQ, /*protoFee*/ 1, /*lpFee*/ 0);

        PoolInfo[] memory hits = hub.discoverFor(bridgeTok, counter);
        assertFalse(_contains(hits, unquotable),
            "a dynamic-fee pool whose effective fee cannot be resolved must not be admitted");
    }

    /// Control for 1039: protocolFee == 0 resolves the fee to slot0's lpFee
    /// and the SAME tier is admitted through the same probes.
    function test_Discovery_ResolvableDynamicFeeIsAdmitted() public {
        address quotable = _plant(DYN_FEE, DYN_TS, LIVE_LIQ, /*protoFee*/ 0, /*lpFee*/ 500);

        PoolInfo[] memory hits = hub.discoverFor(bridgeTok, counter);
        assertTrue(_contains(hits, quotable),
            "the identical dynamic tier with a resolvable fee must be discovered");
    }

    // =========================================================================
    //  4. Hub:1685 / Hub:1702 — eviction, the registry's only bounded growth
    // =========================================================================

    function _seed(uint256 i, address hooks) private returns (address p) {
        p = address(uint160(0xC000 + i)); // codeless is fine: _register never calls the pool
        hub.seedPool(p, BPC.KIND_V3, 3000, hooks, TOK_A, TOK_B);
    }

    /// Fill a pair to MAX_SLOTS, then seed one more. The 17th must EVICT —
    /// not grow the list, not be refused, not leave the evicted key readable.
    /// All 16 incumbents are registered in the same block with identical
    /// slots, so their fitness ties and the strict `<` in the eviction scan
    /// picks index 0: the FIRST-seeded pool is the deterministic victim.
    ///
    /// DELETION-SENSITIVE: replace the eviction block with a push and the
    /// length assertion fails (17); delete both and the newcomer-membership
    /// assertion fails; skip the slot/poolOf clears and those getters fail.
    function test_Registry_FullPairEvictsInsteadOfGrowingOrRefusing() public {
        address victim = _seed(0, address(0));
        for (uint256 i = 1; i < MAX_SLOTS; ++i) _seed(i, address(0));
        assertEq(hub.getActivePools(TOK_A, TOK_B).length, MAX_SLOTS,
            "precondition: the pair is exactly full");

        address newcomer = _seed(MAX_SLOTS, address(0)); // the 17th

        PoolInfo[] memory ps = hub.getActivePools(TOK_A, TOK_B);
        assertEq(ps.length, MAX_SLOTS, "a full pair must stay at MAX_SLOTS, never grow");
        assertTrue(_contains(ps, newcomer), "the newcomer must occupy the evicted seat");
        assertFalse(_contains(ps, victim), "the weakest incumbent must be gone");

        bytes32 victimKey = hub.keyOf(victim, TOK_A, TOK_B);
        assertEq(hub.getPool(victimKey), address(0), "eviction must clear poolOf");
        assertEq(hub.getSlot(victimKey), 0, "eviction must clear the packed slot");
    }

    /// Hub:1702 — the hooksOf clear, and WHY it is load-bearing: _register
    /// writes hooksOf only when hooks != 0, so eviction is the ONLY writer
    /// that ever clears it. Evict a hooked pool, then re-register the same
    /// pool (same key) hookless: the registry must report hooks ==
    /// address(0).
    ///
    /// DELETION-SENSITIVE: without the clear, the stale hook survives the
    /// eviction, the hookless re-registration inherits it, and
    /// getActivePools reports a hook the pool does not have — the assertEq
    /// fails. (For a V4 kind that stale hook would also flow into the
    /// isHookLive routability filter: a ghost with consequences.)
    function test_Registry_EvictionClearsTheHookMapping() public {
        address hooked = _seed(0, hookAddr);          // index 0 — the victim
        for (uint256 i = 1; i < MAX_SLOTS; ++i) _seed(i, address(0));
        _seed(MAX_SLOTS, address(0));                 // evicts `hooked`

        bytes32 hookedKey = hub.keyOf(hooked, TOK_A, TOK_B);
        assertEq(hub.getPool(hookedKey), address(0), "precondition: the hooked pool was evicted");

        // Same pool, same pair, same key — re-registered HOOKLESS.
        hub.seedPool(hooked, BPC.KIND_V3, 3000, address(0), TOK_A, TOK_B);

        PoolInfo[] memory ps = hub.getActivePools(TOK_A, TOK_B);
        assertEq(_hooksReported(ps, hooked), address(0),
            "a hookless re-registration must not inherit the evicted entry's stale hook");
    }

    // =========================================================================
    //  5. The gates this file's own doors depend on
    // =========================================================================

    /// Every privileged door this file exercises refuses a roleless stranger
    /// with HubE(1) — enumerated here so the file is self-contained about the
    /// auth it assumes everywhere else. DELETION-SENSITIVE: remove any
    /// modifier's body and that stranger call succeeds.
    function test_Auth_PrivilegedDoorsRefuseAStranger() public {
        bytes memory e1 = abi.encodeWithSelector(BlazePhoenixHub.HubE.selector, 1);
        uint24[] memory noFees = new uint24[](0);
        int24[]  memory noSps  = new int24[](0);

        vm.startPrank(stranger);
        vm.expectRevert(e1); hub.allowHook(hookAddr, true);                       // onlyAdmin
        vm.expectRevert(e1); hub.addBridge(address(0x5555));                      // onlyAdmin
        vm.expectRevert(e1); hub.addFactory(dummyFactory, BPC.KIND_V2, 0, bytes32(0), noFees, noSps); // onlyAdmin
        vm.expectRevert(e1); hub.addV4(bridgeTok, counter, CANON_FEE, CANON_TS, address(0));          // onlyOperator
        vm.expectRevert(e1); hub.seedPool(address(0xC0DE), BPC.KIND_V2, 30, address(0), TOK_A, TOK_B); // onlyOperator
        vm.expectRevert(e1); hub.recordSwap(address(0xC0DE), BPC.KIND_V2, 30, address(0), TOK_A, TOK_B, 1, 1, 1); // onlyRouter
        vm.stopPrank();
    }
}
