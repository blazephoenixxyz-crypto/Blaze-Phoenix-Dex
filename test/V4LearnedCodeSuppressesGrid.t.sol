// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  V4 LEARNED CODE SUPPRESSES GRID - a permissionless claim must not switch off
//  the scan's own probes.
//
//  `v4CodeOf` is written by the permissionless `claimV4` before its admission
//  gate, so anyone can plant a learned code for a dust pool. The scan admits that
//  code first (stage a). It once shared one counter with the cold-start grid's
//  gate, so the planted hit switched the grid off and a deep pool at a grid tier
//  vanished from discovery (reported by Mohd Huzaifa).
//
//  The grid is gone (poda-1027): no stage of `_scanV4` is gated on another's hits,
//  so the rule holds by construction. What these tests pin now:
//    - a tier outside the table (canonical tiers, the row's extras) is not probed
//      cold, and its learned code reaches it;
//    - a planted code and a real canonical hit together do not switch off the
//      row's extras (the mutant gates the extras on the canonical batch);
//    - a tier outside the table stays unlisted with or without hits.
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
    // claimV4 is permissionless - always called from a roleless stranger.
    address attacker = address(0xA11CE);
    address dummyFactory = address(0xFAC7);

    // MODE_V4_DERIVE (Hub:286) - internal constant, pinned here.
    uint8 constant MODE_V4_DERIVE = 9;

    // A generator Pi_K tier (fee = 10_000 * j, ts = 100 * j, j = 99): outside
    // the table, reached only through a learned code.
    uint24 constant GRID_FEE = 990_000;
    int24  constant GRID_TS  = 9_900;

    // The row's one extra tier, probed on every scan.
    uint24 constant EXTRA_FEE = 6000;
    int24  constant EXTRA_TS  = 120;

    // Canonical Uniswap tier - found by probe (c).
    uint24 constant CANON_FEE = 3000;
    int24  constant CANON_TS  = 60;

    // Dust tier the attacker claims: outside the table, reachable only through
    // the learned code claimV4 writes for it.
    uint24 constant DUST_FEE = 777;
    int24  constant DUST_TS  = 5;

    uint128 constant DEEP_LIQ = 1e24; // real depth
    uint128 constant DUST_LIQ = 1e14; // dust - but liveness is all step (a) needs

    function setUp() public {
        mgr = new MockV4DeriveManager();
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(mgr));
        // Router role is deliberately left unset (address(0)): weth() is zero and
        // the native-ETH pass does not run, keeping this a pure ERC20-pair scan.
        // The tokens are bare addresses and this manager has no exttload, so the
        // solvency gate cannot measure and lets the scan run (fail open).
        hub.addBridge(bridge);
        uint24[] memory fees = new uint24[](1);
        int24[]  memory spacings = new int24[](1);
        fees[0] = EXTRA_FEE;
        spacings[0] = EXTRA_TS;
        // A V4 derive-scan row. The factory address is never called (the scan
        // reads the PoolManager); it only has to be non-zero.
        hub.addFactory(dummyFactory, BPC.KIND_V4, MODE_V4_DERIVE, bytes32(0), fees, spacings);
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

    // --- a Pi_K tier is reached through its learned code, not a cold grid ---

    function test_PiKTier_IsReachedThroughItsLearnedCode() public {
        address deep = _plant(GRID_FEE, GRID_TS, DEEP_LIQ);

        assertFalse(_contains(hub.discoverFor(bridge, counter), deep),
            "no cold grid: a tier outside the table is not probed");

        // Anyone may teach the code (claimV4 writes it before its admission gate).
        vm.prank(attacker);
        hub.claimV4(bridge, counter, GRID_FEE, GRID_TS);

        assertTrue(_contains(hub.discoverFor(bridge, counter), deep),
            "the learned code reaches the Pi_K tier");
    }

    // --- a planted code and a canonical hit do not switch off the extras ---

    function test_LearnedCode_DoesNotSuppressTheExtras() public {
        address deep  = _plant(EXTRA_FEE, EXTRA_TS, DEEP_LIQ); // the row's extra
        address canon = _plant(CANON_FEE, CANON_TS, DEEP_LIQ); // a real canonical hit
        address dust  = _plant(DUST_FEE, DUST_TS, DUST_LIQ);

        // A roleless stranger plants a learned code for the dust tier.
        vm.prank(attacker);
        hub.claimV4(bridge, counter, DUST_FEE, DUST_TS);

        PoolInfo[] memory hits = hub.discoverFor(bridge, counter);
        assertTrue(_contains(hits, dust), "the planted code fired (stage a)");
        assertTrue(_contains(hits, canon), "the canonical tier is listed");
        assertTrue(_contains(hits, deep),
            "a learned code and a canonical hit switched off the row's extras and hid the deep pool");
    }

    // --- a tier outside the table stays unlisted, with or without hits ----

    function test_Boundary_TierOutsideTheTableIsNotProbed() public {
        address canon  = _plant(CANON_FEE, CANON_TS, DEEP_LIQ); // found by probe (c)
        address exotic = _plant(GRID_FEE,  GRID_TS,  DEEP_LIQ); // outside the table
        _plant(DUST_FEE, DUST_TS, DUST_LIQ);                    // for the learned code

        vm.prank(attacker);
        hub.claimV4(bridge, counter, DUST_FEE, DUST_TS);

        PoolInfo[] memory hits = hub.discoverFor(bridge, counter);
        assertTrue(_contains(hits, canon), "a canonical-tier pool must remain discoverable");
        // Only its own learned code reaches it (claimV4, or a swap the Hub learns from).
        assertFalse(_contains(hits, exotic),
            "a tier outside the table is left to its learned code");
    }
}
