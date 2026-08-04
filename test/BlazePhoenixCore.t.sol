// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixCore as BPC} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {CoreHarness} from "./mocks/CoreHarness.sol";

contract BlazePhoenixCoreTest is Test {
    // ─── vitality() — regression for the 128x decay bug ─────────────

    function test_Vitality_FullValueBeforeFirstDecayStep() public {
        uint32 lastTs = 1_000_000;
        uint32 swapCount = 777;
        uint256 slot = BPC.encodeSlot(true, 30, 0, 0, 0, lastTs, 0, 0, swapCount, 0, 0);

        uint32 age = uint32(BPC.VITALITY_DECAY_STEP_SECONDS) - 1;
        uint256 v = BPC.vitality(slot, lastTs + age);
        assertEq(v, swapCount, "vitality should equal swapCount before first decay step");
    }

    function test_Vitality_HalvesEveryDecayStep() public {
        uint32 lastTs = 1_000_000; // must be nonzero: 0 is vitality()'s "never ticked" sentinel
        uint32 swapCount = 1000;
        uint256 slot = BPC.encodeSlot(true, 30, 0, 0, 0, lastTs, 0, 0, swapCount, 0, 0);

        uint256 step = BPC.VITALITY_DECAY_STEP_SECONDS;
        assertEq(BPC.vitality(slot, uint32(lastTs + step)), swapCount >> 1);
        assertEq(BPC.vitality(slot, uint32(lastTs + step * 2)), swapCount >> 2);
    }

    function test_Vitality_FullDecayAt32Steps() public {
        uint32 lastTs = 1_000_000; // must be nonzero: 0 is vitality()'s "never ticked" sentinel
        uint256 slot = BPC.encodeSlot(true, 30, 0, 0, 0, lastTs, 0, 0, 1_000_000, 0, 0);
        uint256 step = BPC.VITALITY_DECAY_STEP_SECONDS;

        assertGt(BPC.vitality(slot, uint32(lastTs + step * 32 - 1)), 0);
        // NOTE: shift==31 (one step short) floors to 1 via the `if (v==0)
        // v=1` guard, but shift==32 exactly takes the EARLIER `if (shift >
        // 31) return 0` branch, which bypasses that floor — a real
        // inconsistency (a non-empty, real pool can score literal 0 once
        // fully decayed, unlike every lesser decay level) worth a deliberate
        // design decision, not silently "fixed" as part of a test pass.
        assertEq(BPC.vitality(slot, uint32(lastTs + step * 32)), 0,
            "documents the shift>31 early-return: literal 0, NOT floored to 1 like shift==31 is");
    }

    function test_Vitality_DecaysOverRealNineDayWindow() public {
        // Sanity-check against the documented ~9.1 day / 65 536 block (@12s)
        // design intent, now expressed in wall-clock seconds. Before the fix,
        // the equivalent block-counted window decayed ~128x too fast.
        uint256 fullDecaySeconds = BPC.VITALITY_DECAY_STEP_SECONDS * 32;
        assertEq(fullDecaySeconds / 1 days, 9);
    }

    function test_Vitality_ZeroSlotOrNeverTicked() public {
        assertEq(BPC.vitality(0, 12345), 0);
        uint256 slotNeverTicked = BPC.encodeSlot(true, 30, 0, 0, 0, 0, 0, 0, 500, 0, 0);
        assertEq(BPC.vitality(slotNeverTicked, 12345), 0);
    }

    // ─── mulDiv / mulDivUp ───────────────────────────────────────────

    function test_MulDiv_BasicCase() public {
        assertEq(BPC.mulDiv(10, 20, 5), 40);
    }

    function test_MulDiv_MatchesNaiveWhenNoOverflow(uint128 a, uint128 b, uint128 d) public {
        vm.assume(d != 0);
        uint256 expected = (uint256(a) * uint256(b)) / uint256(d);
        assertEq(BPC.mulDiv(a, b, d), expected);
    }

    function test_MulDivUp_RoundsUpOnRemainder() public {
        assertEq(BPC.mulDiv(10, 1, 3), 3);
        assertEq(BPC.mulDivUp(10, 1, 3), 4);
    }

    function test_MulDivUp_ExactDivisionNoRoundUp() public {
        assertEq(BPC.mulDivUp(10, 2, 5), 4);
    }

    // ─── ironFloorBps — sealed 80% hard floor ────────────────────────

    function test_IronFloorBps_CleanSingleLegSwap() public {
        assertEq(BPC.ironFloorBps(0, 1, 0), 9_600);
    }

    function test_IronFloorBps_NeverBelowHardFloor() public {
        assertEq(BPC.ironFloorBps(10_000, 10, 0), 8_000,
            "floor must clamp at the 80% hard cap (raised from 75%), never looser");
    }

    function test_IronFloorBps_LoosensWithLegsAndImpact() public {
        uint256 floorClean = BPC.ironFloorBps(0, 1, 0);
        uint256 floorImpacted = BPC.ironFloorBps(100, 3, 0);
        assertLt(floorImpacted, floorClean);
    }

    // ─── hookAltersDeltas ────────────────────────────────────────────

    function test_HookAltersDeltas_FlagsSet() public {
        assertTrue(BPC.hookAltersDeltas(address(uint160(1 << 3)))); // BEFORE_SWAP_RETURNS_DELTA
        assertTrue(BPC.hookAltersDeltas(address(uint160(1 << 2)))); // AFTER_SWAP_RETURNS_DELTA
    }

    function test_HookAltersDeltas_OtherFlagsDoNotTrigger() public {
        assertFalse(BPC.hookAltersDeltas(address(uint160(1 << 7)))); // BEFORE_SWAP, not a delta flag
        assertFalse(BPC.hookAltersDeltas(address(0)));
    }

    // ─── encodeSlot / decode round-trip ──────────────────────────────

    function test_EncodeDecodeSlot_RoundTrip() public {
        uint256 slot = BPC.encodeSlot(true, 3000, 1, 2, 500, 111, 222, 333, 444, 555, 666);
        assertTrue(BPC.isActive(slot));
        assertEq(BPC.decodeFee(slot), 3000);
        assertEq(BPC.decodeKind(slot), 1);
        assertEq(BPC.decodeSwapCount(slot), 444);
        assertEq(BPC.decodeLastUpdateTs(slot), 111);
        assertEq(BPC.decodeLastBlk(slot), 666);
    }

    function test_EncodeSlot_ConcentrationBitsNeverOverlapDepthBucket() public {
        uint256 slot = BPC.encodeSlot(true, 0, 0, 0, type(uint16).max, 0, 0, 0, 0, 0, 0);
        assertEq(BPC.decodeBucket(slot), 0);
        uint256 afterBucket = BPC.setBucket(slot, 7);
        assertEq(BPC.decodeBucket(afterBucket), 7);
    }

    // ─── safeTransfer / safeTransferFrom / safeApprove / balanceOf ────
    // Exercised via CoreHarness, a thin external wrapper (a library's
    // internal functions cannot be called directly from a test contract).

    CoreHarness harness;
    MockERC20 token;
    address alice = address(0xA11CE);
    address bob   = address(0xB0B);

    function setUp() public {
        harness = new CoreHarness();
        token = new MockERC20("T", "T");
    }

    function test_SafeTransfer_NormalToken() public {
        token.mint(address(harness), 100e18);
        harness.safeTransfer(address(token), bob, 40e18);
        assertEq(token.balanceOf(bob), 40e18);
        assertEq(token.balanceOf(address(harness)), 60e18);
    }

    function test_SafeTransfer_NoReturnDataToken_Succeeds() public {
        // USDT-style: transfer() returns no data at all. safeTransfer must
        // treat this as success as long as the token address has code.
        token.setNoReturnData(true);
        token.mint(address(harness), 100e18);
        harness.safeTransfer(address(token), bob, 40e18);
        assertEq(token.balanceOf(bob), 40e18);
    }

    function test_SafeTransfer_RevertsOnReturnFalse() public {
        token.setReturnFalseOnFail(true);
        // harness holds nothing -> _transfer's balance check fails -> false.
        vm.expectRevert("BPC:transfer");
        harness.safeTransfer(address(token), bob, 1e18);
    }

    function test_SafeTransferFrom_NormalToken() public {
        token.mint(alice, 100e18);
        vm.prank(alice);
        token.approve(address(harness), 100e18);
        harness.safeTransferFrom(address(token), alice, bob, 40e18);
        assertEq(token.balanceOf(bob), 40e18);
        assertEq(token.balanceOf(alice), 60e18);
    }

    function test_SafeTransferFrom_FeeOnTransfer_DeliversLess() public {
        token.setFeeOnTransferBps(500); // 5%
        token.mint(alice, 100e18);
        vm.prank(alice);
        token.approve(address(harness), 100e18);
        // Must NOT revert even though the recipient receives less than amt —
        // it is the CALLER's job (Router) to measure the real delta.
        harness.safeTransferFrom(address(token), alice, bob, 100e18);
        assertEq(token.balanceOf(bob), 95e18);
    }

    function test_SafeTransferFrom_RevertsOnInsufficientAllowance() public {
        token.mint(alice, 100e18);
        vm.prank(alice);
        token.approve(address(harness), 10e18);
        // safeTransferFrom uses a raw `call`, not a Solidity-level call, so
        // the callee's own revert reason ("MockERC20: allowance") is NOT
        // bubbled up — only the boolean success is inspected, and the
        // wrapper reverts with its own fixed message on failure.
        vm.expectRevert("BPC:transferFrom");
        harness.safeTransferFrom(address(token), alice, bob, 40e18);
    }

    function test_SafeApprove_NormalToken() public {
        harness.safeApprove(address(token), bob, 50e18);
        assertEq(token.allowance(address(harness), bob), 50e18);
    }

    function test_SafeApprove_NoReturnDataToken_Succeeds() public {
        token.setNoReturnData(true);
        harness.safeApprove(address(token), bob, 50e18);
        assertEq(token.allowance(address(harness), bob), 50e18);
    }

    function test_BalanceOf_NormalToken() public {
        token.mint(bob, 77e18);
        assertEq(harness.balanceOf(address(token), bob), 77e18);
    }

    /// @notice Regression: balanceOf() must return exactly 0 for a codeless
    ///         "token" address (EOA, or any address with no bytecode), not
    ///         leftover scratch-memory garbage. A staticcall to a codeless
    ///         address succeeds trivially with zero returndata, and the EVM
    ///         does not zero unwritten destination memory — an unguarded
    ///         read would return the selector/argument bytes staged just
    ///         before the call instead of 0.
    function test_BalanceOf_CodelessAddress_ReturnsZeroNotGarbage() public {
        assertEq(harness.balanceOf(bob /* EOA, no code */, alice), 0);
        assertEq(harness.balanceOf(address(0), alice), 0);
    }

    // ─── impactV2Bps / impactV3Bps / depth+psi primitives ──────────────

    function test_ImpactV2Bps_ZeroReserveIsFullImpact() public pure {
        assertEq(BPC.impactV2Bps(1e18, 0), BPC.BPS);
    }

    function test_ImpactV2Bps_MonotonicWithAmount() public pure {
        uint256 small = BPC.impactV2Bps(10e18, 100_000e18);
        uint256 large = BPC.impactV2Bps(50_000e18, 100_000e18);
        assertLt(small, large);
    }

    function test_ImpactV3Bps_ZeroInputsAreFullImpact() public pure {
        assertEq(BPC.impactV3Bps(0, 1, 1, 3000, true), BPC.BPS);
        assertEq(BPC.impactV3Bps(1e18, 0, 1, 3000, true), BPC.BPS);
        assertEq(BPC.impactV3Bps(1e18, 1, 0, 3000, true), BPC.BPS);
    }

    function test_DepthBucket_MonotonicSteps() public pure {
        assertEq(BPC.depthBucket(0), 0);
        assertEq(BPC.depthBucket(999e12), 0); // below 1e15
        assertGt(BPC.depthBucket(1e18), BPC.depthBucket(1e15));
        assertEq(BPC.depthBucket(type(uint256).max), 15, "clamped at 15");
    }

    function test_BucketWeight_PowersOfTwo() public pure {
        assertEq(BPC.bucketWeight(0), 1);
        assertEq(BPC.bucketWeight(4), 16);
        assertEq(BPC.bucketWeight(15), 1 << 15);
    }

    function test_Psi_BridgeAndConcentrationBonusesStack() public pure {
        uint32 lastTs = 1_000_000; // must be nonzero: 0 is vitality()'s "never ticked" sentinel
        uint256 slot = BPC.encodeSlot(true, 30, 0, 0, 0, lastTs, 0, 0, 1000, 0, 0);
        uint256 base = BPC.psi(slot, lastTs, false, false);
        uint256 withBridge = BPC.psi(slot, lastTs, true, false);
        uint256 withBoth = BPC.psi(slot, lastTs, true, true);
        assertGt(withBridge, base);
        assertGt(withBoth, withBridge);
    }

    function test_Psi_ZeroVitalityIsZeroScore() public pure {
        assertEq(BPC.psi(0, 12345, true, true), 0);
    }

    function test_TickSlot_IncrementsSwapCountAndResetsBucket() public pure {
        uint256 slot = BPC.encodeSlot(true, 30, 0, 0, 0, 100, 0, 0, 5, 0, 0);
        uint256 slotWithBucket = BPC.setBucket(slot, 9);
        uint256 ticked = BPC.tickSlot(slotWithBucket, 999, 1e18);
        assertEq(BPC.decodeSwapCount(ticked), 6);
        assertEq(BPC.decodeLastBlk(ticked), 999);
        assertEq(BPC.decodeBucket(ticked), BPC.depthBucket(1e18), "bucket is recomputed from the new depth");
    }

    // ─── outV2 / outV3 / sortTokens / hasCode ───────────────────────────

    function test_OutV2_ZeroInputsReturnZero() public pure {
        assertEq(BPC.outV2(0, 100, 100, 30), 0);
        assertEq(BPC.outV2(100, 0, 100, 30), 0);
        assertEq(BPC.outV2(100, 100, 0, 30), 0);
    }

    function test_OutV2_FeeAtOrAboveHundredPercentIsUnquotable() public pure {
        assertEq(BPC.outV2(100e18, 1000e18, 1000e18, 10_000), 0);
    }

    function test_SortTokens_OrdersAscending() public pure {
        (address lo, address hi) = BPC.sortTokens(address(0xBEEF), address(0xAAAA));
        assertLt(uint160(lo), uint160(hi));
    }

    function test_HasCode_TrueForContractFalseForEOA() public {
        assertTrue(BPC.hasCode(address(harness)));
        assertFalse(BPC.hasCode(bob));
    }
}
