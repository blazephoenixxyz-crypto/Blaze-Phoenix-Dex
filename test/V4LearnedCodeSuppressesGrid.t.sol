// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  V4 LEARNED-CODE SUPPRESSES GRID — a permissionless claim must not blind the
//  cold-start grid that is the only probe for non-canonical tiers.
//
//  Hub._scanV4 (Hub:891) drives its probes with ONE packed counter, kf, whose
//  high 128 bits count "pools found by THIS scan". The probe order is:
//    (a) learned per-token codes   — $.v4CodeOf[t0/t1], each admitted if live
//    (c) canonical Uniswap tiers   — one batched extsload
//    (d) the row's paired extras   — one batched extsload
//    (e) generator cold-start grid — the ONLY probe that reaches non-canonical
//        tiers, entered ONLY when nothing was found above:
//
//        Hub:948   if (kf >> 128 == 0) kf = _probeV4Batch(..., _v4GridTiers(), ...);
//
//  $.v4CodeOf is written by claimV4 (Hub:712, _writeV4Code) BEFORE its
//  admission-margin gate, so it is PERMISSIONLESSLY writable for ANY live pool
//  whose pair has a routable-bridge side — a dust pool the attacker will never
//  register. On the next discoverFor, that learned code is admitted in step (a),
//  bumps kf >> 128 to non-zero, and the grid in step (e) is skipped. A legit
//  deep pool that lives only at a grid tier vanishes from discovery.
//
//  This is NOT the same as the documented "a REAL canonical hit skips the grid"
//  tradeoff (steps (c)/(d)): those probes are the protocol's own, not attacker
//  input. The boundary test pins that legitimate half; the negative pins the
//  attacker half.
//
//  RED BEFORE THE FIX: test_LearnedCode_DoesNotSuppressGridDiscovery — after a
//  stranger's claimV4 of a dust tier, discoverFor no longer returns the deep
//  grid-tier pool. The fix must count learned-code hits separately from the
//  real-probe hits that gate the grid.
//
//  forge test --match-contract V4LearnedCodeSuppressesGrid -vv
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixCore as BPC, PoolInfo} from "../src/BlazePhoenixCore.sol";

/// @dev Minimal Uniswap-V4 PoolManager state mock. The derive-scan filters
///      candidate tiers with the BATCHED extsload(bytes32[]) (BPC.v4Slot0Batch,
///      selector 0xdbd035ff) and then fully verifies survivors with the SINGLE
///      extsload(bytes32) (BPC.v4SqrtAndLiq, selector 0x1e2eaeaf). The existing
///      inline V4 mocks (MockV4StateManager in HardeningA4, MockV4ManagerNative
///      in RouterV4NativeEth) implement only the single read — enough for
///      claimV4, but NOT for a discoverFor grid pass — so both reads are
///      provided here over the same settable slot map, mirroring the real
///      StateLibrary layout the Core reads.
contract MockV4DeriveManager {
    mapping(bytes32 => bytes32) public slots;

    function setSlot(bytes32 s, bytes32 v) external { slots[s] = v; }

    function extsload(bytes32 s) external view returns (bytes32) { return slots[s]; }

    function extsload(bytes32[] calldata targets) external view returns (bytes32[] memory out) {
        out = new bytes32[](targets.length);
        for (uint256 i; i < targets.length; ++i) out[i] = slots[targets[i]];
    }
}

contract V4LearnedCodeSuppressesGridTest is Test {
    BlazePhoenixHub hub;
    MockV4DeriveManager mgr;

    // Sorted bare-address tokens: bridge < counter, so (t0, t1) = (bridge,
    // counter) and the learned code lands on the NON-bridge side (counter).
    address bridge  = address(0x1111); // claimV4's required routable anchor
    address counter = address(0x2222);
    // claimV4 is permissionless — always called from a roleless stranger.
    address attacker = address(0xA11CE);
    address dummyFactory = address(0xFAC7);

    // MODE_V4_DERIVE (Hub:244) — internal constant, pinned here.
    uint8 constant MODE_V4_DERIVE = 9;

    // Deep pool that lives ONLY at a generator grid tier (fee = 10_000·j,
    // ts = 100·j, j = V4_GRID_MAX = 99 => the first grid probe). Not canonical,
    // not an extra — reachable by the cold-start grid alone.
    uint24 constant GRID_FEE = 990_000;
    int24  constant GRID_TS  = 9_900;

    // Canonical Uniswap tier — found by probe (c), never the grid.
    uint24 constant CANON_FEE = 3000;
    int24  constant CANON_TS  = 60;

    // Dust tier the attacker claims: arbitrary, NON-canonical, NON-grid, so it
    // is reachable only through the learned code claimV4 writes for it.
    uint24 constant DUST_FEE = 777;
    int24  constant DUST_TS  = 5;

    uint128 constant DEEP_LIQ = 1e24; // real depth
    uint128 constant DUST_LIQ = 1e14; // dust — but liveness is all step (a) needs

    function setUp() public {
        mgr = new MockV4DeriveManager();
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(mgr));
        // Router role is deliberately left unset (address(0)): _scanV4 then
        // skips its native-ETH pass (no weth() call), keeping this a pure
        // ERC20-pair derive scan.
        hub.addBridge(bridge);
        uint24[] memory noFees = new uint24[](0);
        int24[]  memory noSpacings = new int24[](0);
        // A V4 derive-scan row. The factory address is never called (the scan
        // reads the PoolManager); it only has to be non-zero.
        hub.addFactory(dummyFactory, BPC.KIND_V4, MODE_V4_DERIVE, bytes32(0), noFees, noSpacings);
    }

    /// @dev Plant a live hookless V4 pool at the exact StateLibrary layout the
    ///      Core reads (mirrors HardeningA4._plantV4Pool): base = keccak256(
    ///      abi.encode(pid, 6)) holds slot0 with sqrtPriceX96 = Q96 (lpFee /
    ///      protocolFee = 0, so the INV-20 static-fee gate passes), liquidity at
    ///      base + 3.
    function _plant(uint24 fee, int24 ts, uint128 liq) private returns (address poolAddr) {
        (address s0, address s1) = BPC.sortTokens(bridge, counter);
        bytes32 pid  = BPC.computeV4PoolId(s0, s1, fee, ts, address(0));
        bytes32 base = keccak256(abi.encode(pid, uint256(6)));
        mgr.setSlot(base, bytes32(uint256(BPC.Q96)));
        mgr.setSlot(bytes32(uint256(base) + 3), bytes32(uint256(liq)));
        poolAddr = address(uint160(uint256(pid)));
    }

    function _contains(PoolInfo[] memory hits, address pool) private pure returns (bool) {
        for (uint256 i; i < hits.length; ++i) {
            if (hits[i].pool == pool) return true;
        }
        return false;
    }

    // ─── POSITIVE (GREEN): the grid finds a live non-canonical pool ───────────

    function test_Grid_FindsNonCanonicalDeepPool() public {
        address deep = _plant(GRID_FEE, GRID_TS, DEEP_LIQ);

        PoolInfo[] memory hits = hub.discoverFor(bridge, counter);
        assertTrue(_contains(hits, deep),
            "the cold-start grid must discover a live pool at a non-canonical tier");
    }

    // ─── NEGATIVE (RED): a permissionless claim must not blind the grid ───────

    function test_LearnedCode_DoesNotSuppressGridDiscovery() public {
        address deep = _plant(GRID_FEE, GRID_TS, DEEP_LIQ);
        address dust = _plant(DUST_FEE, DUST_TS, DUST_LIQ);

        // Baseline, before any claim: the grid finds the deep pool, and the dust
        // tier is invisible (no canonical/grid probe reaches it).
        PoolInfo[] memory pre = hub.discoverFor(bridge, counter);
        assertTrue(_contains(pre, deep), "pre-condition: the grid discovers the deep pool");
        assertFalse(_contains(pre, dust), "pre-condition: the dust tier is not reachable without a learned code");

        // A roleless stranger claims the dust pool. claimV4 writes the learned
        // code for `counter` BEFORE its admission-margin gate, so the code is
        // planted whether or not the dust pool ever registers.
        vm.prank(attacker);
        hub.claimV4(bridge, counter, DUST_FEE, DUST_TS);

        PoolInfo[] memory post = hub.discoverFor(bridge, counter);

        // The learned code took effect: the dust pool is now emitted in step (a).
        assertTrue(_contains(post, dust),
            "the claimed dust tier is discovered via its learned code (step a fired)");

        // THE CLAIM: that step-(a) hit shares kf with the grid gate, so the grid
        // in step (e) is skipped and the deep pool disappears. A permissionless
        // claim of a dust pool must NOT remove a legitimate deep pool from
        // discovery.
        assertTrue(_contains(post, deep),
            "a permissionless claimV4 of a dust pool suppressed the grid and hid the deep pool");
    }

    // ─── BOUNDARY (GREEN): a REAL canonical hit legitimately skips the grid ───

    function test_Boundary_CanonicalHitLegitimatelySkipsGrid() public {
        address canon  = _plant(CANON_FEE, CANON_TS, DEEP_LIQ); // found by probe (c)
        address exotic = _plant(GRID_FEE,  GRID_TS,  DEEP_LIQ); // grid-only
        _plant(DUST_FEE, DUST_TS, DUST_LIQ);                    // for the learned code

        // Learned code present AND a canonical probe will hit.
        vm.prank(attacker);
        hub.claimV4(bridge, counter, DUST_FEE, DUST_TS);

        PoolInfo[] memory hits = hub.discoverFor(bridge, counter);

        // The user is not harmed: the canonical pool is discoverable regardless.
        assertTrue(_contains(hits, canon),
            "a canonical-tier pool must remain discoverable");

        // With a REAL canonical hit present, skipping the grid is the DOCUMENTED
        // tradeoff (the residual exotic tier is left to claimV4/learning) — not a
        // defect, because the suppression came from the protocol's own probe, not
        // from permissionless calldata. This half is intended to stay GREEN.
        assertFalse(_contains(hits, exotic),
            "with a canonical hit present, the exotic grid tier is correctly left to learning");
    }
}
