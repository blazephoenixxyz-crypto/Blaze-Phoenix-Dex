// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  HARDENING A4 — BlazePhoenixHub.claimV4 admission margin + depth persistence.
//
//  claimV4 is PERMISSIONLESS: its trust comes from the on-chain existence /
//  liquidity proof (extsload of slot0 + liquidity on the PoolManager), not a
//  role. Two properties this suite pins:
//
//    (a) DEPTH PERSISTENCE: after a successful claim, the registry slot must
//        carry the pool's MEASURED liquidity bucket (tickSlot with depth = liq,
//        mirroring recordSwap's new-pool path) — NOT the bucket-0 default of a
//        bare _register. Otherwise the pool that just won admission on its
//        depth scores psi ~1 and becomes the pair's next eviction target the
//        instant it registers. Proven by decoding the bucket from getSlot and
//        by getPsi: a deep-liq claim must clearly outscore a thin-liq claim.
//
//    (b) ADMISSION MARGIN: on a FULL 16-slot pair, a claim whose measured liq
//        does NOT clear the same strict 25% _canInsert margin recordSwap
//        applies must be a NO-OP registration-wise (getPool(key) == 0, all 16
//        healthy incumbents survive, no V4Entry pushed) — _register alone
//        evicts UNCONDITIONALLY, so without the gate a dust pool displaces a
//        healthy incumbent. A claim that DOES clear the margin registers and
//        evicts exactly the weakest incumbent.
//
//  Margin math mirrors test_RecordSwap_EvictsWeakestWhenFullAndNewcomerClears-
//  Margin / _RejectsInsertWhenMarginNotCleared in BlazePhoenixHub.t.sol:
//  16 incumbents at depth 1e18 (bucket 3, psi 8 each) => equal-depth newcomer
//  (projected psi 8 <= 10) is rejected, a 1000x newcomer (bucket 6, psi 64)
//  clears. The bridge anchor claimV4 requires is added AFTER the incumbents
//  register, so their packed bridge bit stays 0 and the numbers are identical.
//
//  forge test --match-contract HardeningA4ClaimV4Margin -vv
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixCore as BPC, PoolInfo} from "../src/BlazePhoenixCore.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";

/// @dev Minimal V4 PoolManager state mock: exactly the single-slot extsload
///      read claimV4's on-chain proof (BPC.v4SqrtAndLiq) performs. Mirrors the
///      slots/setSlot/extsload idiom of MockV4ManagerNative in
///      RouterV4NativeEth.t.sol, stripped of the settlement machinery this
///      suite never touches.
contract MockV4StateManager {
    mapping(bytes32 => bytes32) public slots;
    function setSlot(bytes32 s, bytes32 v) external { slots[s] = v; }
    function extsload(bytes32 s) external view returns (bytes32) { return slots[s]; }
}

contract HardeningA4ClaimV4MarginTest is Test {
    BlazePhoenixHub hub;
    MockV4StateManager mgr;

    // Sorted bare-address tokens, same style as BlazePhoenixHub.t.sol.
    address bridgeTok = address(0x1111); // the claim's required bridge anchor
    address tokenB    = address(0x2222);
    address tokenC    = address(0x3333);
    // claimV4 is permissionless — always called from a roleless stranger.
    address claimer   = address(0xCA11);

    uint24  constant FEE_THIN = 500;
    int24   constant TS_THIN  = 10;
    uint24  constant FEE_DEEP = 3000;
    int24   constant TS_DEEP  = 60;

    uint128 constant DEEP_LIQ = 1e24; // depthBucket 9 — clearly not bucket 0
    uint128 constant THIN_LIQ = 1e14; // < 1e15 => depthBucket 0

    function setUp() public {
        mgr = new MockV4StateManager();
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(mgr));
        // router = this so recordSwap can seed incumbents, as in BlazePhoenixHub.t.sol.
        hub.setRoles(address(this), address(this), address(this));
    }

    /// @dev Plant a live hookless V4 pool in the manager mock at the exact
    ///      storage layout BPC.v4SqrtAndLiq reads (mirrors RouterV4NativeEth's
    ///      setUp): base = keccak256(abi.encode(pid, 6)) holds slot0 with
    ///      sqrtPriceX96 = Q96 in the low 160 bits (lpFee/protocolFee = 0, so
    ///      the static-fee INV-20 gate passes), liquidity at base + 3.
    function _plantV4Pool(address tA, address tB, uint24 fee, int24 ts, uint128 liq)
        private returns (address poolAddr, bytes32 key)
    {
        (address s0, address s1) = tA < tB ? (tA, tB) : (tB, tA);
        bytes32 pid = BPC.computeV4PoolId(s0, s1, fee, ts, address(0));
        bytes32 base = keccak256(abi.encode(pid, uint256(6)));
        mgr.setSlot(base, bytes32(uint256(BPC.Q96)));
        mgr.setSlot(bytes32(uint256(base) + 3), bytes32(uint256(liq)));
        poolAddr = address(uint160(uint256(pid)));
        key = hub.keyOf(poolAddr, s0, s1);
    }

    /// @dev Fill all 16 slots of (bridgeTok, tokenB) with equal, shallow-depth
    ///      (1e18) V2 incumbents — the exact setup of the recordSwap margin
    ///      tests. The bridge term of psi is read live since 2026-09-02, so
    ///      once addBridge(bridgeTok) runs every incumbent carries the +25%
    ///      (psi 8 -> 10) and the newcomer's projection, which assumes no
    ///      bonus, faces a proportionally higher bar: below-margin stays
    ///      below, the 1000x claim still clears by a wide margin.
    function _fillPair() private returns (address[] memory pools) {
        pools = new address[](16);
        for (uint256 i; i < 16; ++i) {
            pools[i] = address(new MockV2Pair(bridgeTok, tokenB));
            hub.recordSwap(pools[i], BPC.KIND_V2, 30, address(0), bridgeTok, tokenB, 1e18, 1e18, 1e18);
        }
        assertEq(hub.getActivePools(bridgeTok, tokenB).length, 16, "pair must start full");
    }

    // ── (a) depth-bucket persistence ─────────────────────────────────────

    function test_ClaimV4_PersistsMeasuredDepthBucket_NotBucketZero() public {
        hub.addBridge(bridgeTok);
        (address poolAddr, bytes32 key) =
            _plantV4Pool(bridgeTok, tokenB, FEE_DEEP, TS_DEEP, DEEP_LIQ);

        vm.prank(claimer);
        bytes32 ret = hub.claimV4(bridgeTok, tokenB, FEE_DEEP, TS_DEEP);

        assertEq(ret, key, "claim must return the keyOf-formula key");
        assertEq(hub.getPool(key), poolAddr, "empty pair: the claim must register");

        uint256 s = hub.getSlot(key);
        assertTrue(BPC.isActive(s), "registered slot must be active");
        // THE A4 CORE: the persisted bucket is the pool's MEASURED liquidity
        // bucket (tickSlot with depth = liq), not _register's bucket-0 default.
        assertEq(
            BPC.decodeBucket(s), BPC.depthBucket(uint256(DEEP_LIQ)),
            "slot must persist the measured depth bucket"
        );
        assertGt(BPC.decodeBucket(s), 0, "a deep-liq claim must not land in bucket 0");
        assertEq(BPC.decodeSwapCount(s), 1, "claim must tick the slot once (recordSwap parity)");
        // psi reflects the bucket: at least the raw bucket weight (bonuses only
        // add), and clearly above the bucket-0 minimum of ~1.
        assertGe(
            hub.getPsi(poolAddr, bridgeTok, tokenB), BPC.bucketWeight(BPC.depthBucket(uint256(DEEP_LIQ))),
            "psi must carry the measured bucket weight"
        );
        assertGt(hub.getPsi(poolAddr, bridgeTok, tokenB), 1, "psi must not be the bucket-0 minimum");
    }

    function test_ClaimV4_DeepClaimScoresAboveThinClaim() public {
        hub.addBridge(bridgeTok);
        (address deepAddr, bytes32 deepKey) =
            _plantV4Pool(bridgeTok, tokenB, FEE_DEEP, TS_DEEP, DEEP_LIQ);
        (address thinAddr, bytes32 thinKey) =
            _plantV4Pool(bridgeTok, tokenC, FEE_THIN, TS_THIN, THIN_LIQ);

        vm.prank(claimer);
        hub.claimV4(bridgeTok, tokenB, FEE_DEEP, TS_DEEP);
        vm.prank(claimer);
        hub.claimV4(bridgeTok, tokenC, FEE_THIN, TS_THIN);

        assertEq(hub.getPool(deepKey), deepAddr, "deep claim registers (empty pair)");
        assertEq(hub.getPool(thinKey), thinAddr, "thin claim registers (empty pair)");
        assertEq(BPC.decodeBucket(hub.getSlot(thinKey)), 0, "thin liq measures into bucket 0");

        uint256 psiDeep = hub.getPsi(deepAddr, bridgeTok, tokenB);
        uint256 psiThin = hub.getPsi(thinAddr, bridgeTok, tokenC);
        assertGe(psiThin, 1, "a registered pool never scores 0");
        assertGt(
            psiDeep, psiThin,
            "a deep-liq claim must outscore a thin-liq claim -- depth was persisted"
        );
    }

    // ── (b) full pair: the 25% _canInsert margin gates the claim ─────────

    function test_ClaimV4_FullPair_ThinClaimBelowMarginDoesNotEvict() public {
        address[] memory pools = _fillPair();
        hub.addBridge(bridgeTok); // anchor for the claim; incumbents already sealed
        // Measured liq == incumbents' depth (1e18): projected psi 8 fails the
        // strict 25% margin over the worst incumbent (psi 10 with the live
        // bridge bonus; the claim would need > 12).
        (, bytes32 key) = _plantV4Pool(bridgeTok, tokenB, FEE_THIN, TS_THIN, uint128(1e18));

        uint256 entriesBefore = hub.v4EntryCount();
        vm.prank(claimer);
        bytes32 ret = hub.claimV4(bridgeTok, tokenB, FEE_THIN, TS_THIN);

        assertEq(ret, key, "rejected claim still returns the would-be key");
        assertEq(hub.getPool(key), address(0), "below-margin claim must NOT register");
        assertEq(hub.getSlot(key), 0, "no slot state may be written for a rejected claim");
        assertEq(hub.v4EntryCount(), entriesBefore, "no V4Entry may be pushed for a rejected claim");

        PoolInfo[] memory active = hub.getActivePools(bridgeTok, tokenB);
        assertEq(active.length, 16, "all 16 slots still occupied");
        for (uint256 i; i < 16; ++i) {
            bool found;
            for (uint256 j; j < active.length; ++j) {
                if (active[j].pool == pools[i]) { found = true; break; }
            }
            assertTrue(found, "every healthy incumbent must survive a below-margin claim");
        }
    }

    function test_ClaimV4_FullPair_DeepClaimClearsMarginAndEvictsWeakest() public {
        address[] memory pools = _fillPair();
        hub.addBridge(bridgeTok);
        // 1000x the incumbents' depth (bucket 6, psi 64 > 10): clears the margin.
        (address claimAddr, bytes32 key) =
            _plantV4Pool(bridgeTok, tokenB, FEE_DEEP, TS_DEEP, uint128(1e21));

        vm.prank(claimer);
        hub.claimV4(bridgeTok, tokenB, FEE_DEEP, TS_DEEP);

        assertEq(hub.getPool(key), claimAddr, "margin-clearing claim must register");

        PoolInfo[] memory active = hub.getActivePools(bridgeTok, tokenB);
        assertEq(active.length, 16, "count stays capped at MAX_SLOTS");
        bool sawEvictedPool;
        bool sawClaimant;
        for (uint256 i; i < active.length; ++i) {
            if (active[i].pool == pools[0]) sawEvictedPool = true;
            if (active[i].pool == claimAddr) sawClaimant = true;
        }
        assertFalse(sawEvictedPool, "weakest incumbent (first inserted, tie-break) must be evicted");
        assertTrue(sawClaimant, "the deep claimant must occupy a slot");

        // A4 persistence holds on the eviction path too: the admitted pool is
        // ranked by its measured depth, not parked at the pair's bottom.
        assertEq(
            BPC.decodeBucket(hub.getSlot(key)), BPC.depthBucket(1e21),
            "evicting claim must persist its measured depth bucket"
        );
        assertGt(hub.getPsi(claimAddr, bridgeTok, tokenB), 1, "admitted claimant must not score the bucket-0 minimum");
    }
}
