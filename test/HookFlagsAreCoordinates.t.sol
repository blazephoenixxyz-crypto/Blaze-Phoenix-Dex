// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  HOOK FLAGS ARE COORDINATES.
//
//  A V4 hook's permissions are not declared, they are its address: the low 14 bits, one per
//  callback (v4-core src/libraries/Hooks.sol, ALL_HOOK_MASK = (1 << 14) - 1). The Core reads two
//  questions off those bits and nothing else:
//    * `hookAltersDeltas` - "may this hook return its own swap deltas?"
//      BEFORE_SWAP_RETURNS_DELTA (1 << 3) or AFTER_SWAP_RETURNS_DELTA (1 << 2);
//    * `hookRunsInSwap`   - "does this hook run code inside a swap?"
//      BEFORE_SWAP (1 << 7), AFTER_SWAP (1 << 6) or either swap-delta bit.
//  The oracle below is the v4-core flag table, spelled here bit by bit, not the Core's masks.
//  Every bit is checked alone (14 rows x 2 questions), then every address: the answer is the
//  table's, whatever the other 146 bits hold.
//
//  Matrix (range x vector x dimension):
//    ranges   : each of the 14 flag bits alone, no bit, all 14 bits, the 146 high bits
//    vectors  : a hook naming one callback, a hook with every callback, an address whose high bits
//               are arbitrary (a mined address)
//    dims     : unit (table), fuzz (any address), mutant (.github/scripts/mutants.py)
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixCore as BPC} from "../src/BlazePhoenixCore.sol";

contract HookFlagsHarness {
    function altersDeltas(address h) external pure returns (bool) { return BPC.hookAltersDeltas(h); }
    function runsInSwap(address h) external pure returns (bool) { return BPC.hookRunsInSwap(h); }
}

contract HookFlagsAreCoordinatesTest is Test {
    // v4-core src/libraries/Hooks.sol (checked against Uniswap/v4-core main, 2026-11-13).
    uint160 internal constant BEFORE_INITIALIZE_FLAG = 1 << 13;
    uint160 internal constant AFTER_INITIALIZE_FLAG = 1 << 12;
    uint160 internal constant BEFORE_ADD_LIQUIDITY_FLAG = 1 << 11;
    uint160 internal constant AFTER_ADD_LIQUIDITY_FLAG = 1 << 10;
    uint160 internal constant BEFORE_REMOVE_LIQUIDITY_FLAG = 1 << 9;
    uint160 internal constant AFTER_REMOVE_LIQUIDITY_FLAG = 1 << 8;
    uint160 internal constant BEFORE_SWAP_FLAG = 1 << 7;
    uint160 internal constant AFTER_SWAP_FLAG = 1 << 6;
    uint160 internal constant BEFORE_DONATE_FLAG = 1 << 5;
    uint160 internal constant AFTER_DONATE_FLAG = 1 << 4;
    uint160 internal constant BEFORE_SWAP_RETURNS_DELTA_FLAG = 1 << 3;
    uint160 internal constant AFTER_SWAP_RETURNS_DELTA_FLAG = 1 << 2;
    uint160 internal constant AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG = 1 << 1;
    uint160 internal constant AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG = 1 << 0;
    uint160 internal constant ALL_HOOK_MASK = uint160((1 << 14) - 1);

    HookFlagsHarness internal h;

    function setUp() public { h = new HookFlagsHarness(); }

    /// The table's answers, from the flag names.
    function _altersDeltas(uint160 bits) internal pure returns (bool) {
        return bits & (BEFORE_SWAP_RETURNS_DELTA_FLAG | AFTER_SWAP_RETURNS_DELTA_FLAG) != 0;
    }

    function _runsInSwap(uint160 bits) internal pure returns (bool) {
        return bits & (BEFORE_SWAP_FLAG | AFTER_SWAP_FLAG
            | BEFORE_SWAP_RETURNS_DELTA_FLAG | AFTER_SWAP_RETURNS_DELTA_FLAG) != 0;
    }

    function _row(uint160 bit, bool alters, bool runs) internal view {
        assertEq(h.altersDeltas(address(bit)), alters, "hookAltersDeltas, one bit alone");
        assertEq(h.runsInSwap(address(bit)), runs, "hookRunsInSwap, one bit alone");
    }

    /// Each of the 14 callbacks alone. Only the two swap-delta bits alter deltas; only the two swap
    /// callbacks and the two swap-delta bits run in a swap. Liquidity and donate deltas do not.
    function test_HookFlags_EachBitAlone_AltersDeltas() public view {
        _row(BEFORE_SWAP_RETURNS_DELTA_FLAG, true, true);
        _row(AFTER_SWAP_RETURNS_DELTA_FLAG, true, true);
        _row(AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG, false, false);
        _row(AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG, false, false);
    }

    function test_HookFlags_EachBitAlone_RunsInSwap() public view {
        _row(BEFORE_SWAP_FLAG, false, true);
        _row(AFTER_SWAP_FLAG, false, true);
        _row(BEFORE_SWAP_RETURNS_DELTA_FLAG, true, true);
        _row(AFTER_SWAP_RETURNS_DELTA_FLAG, true, true);
    }

    function test_HookFlags_EachBitAlone_TheRestAreSilent() public view {
        _row(BEFORE_INITIALIZE_FLAG, false, false);
        _row(AFTER_INITIALIZE_FLAG, false, false);
        _row(BEFORE_ADD_LIQUIDITY_FLAG, false, false);
        _row(AFTER_ADD_LIQUIDITY_FLAG, false, false);
        _row(BEFORE_REMOVE_LIQUIDITY_FLAG, false, false);
        _row(AFTER_REMOVE_LIQUIDITY_FLAG, false, false);
        _row(BEFORE_DONATE_FLAG, false, false);
        _row(AFTER_DONATE_FLAG, false, false);
        _row(0, false, false);
        _row(ALL_HOOK_MASK, true, true);
    }

    /// Every bit index 0..13 against the table, as one loop (the rows above, without the names).
    function test_HookFlags_TheFourteenBitsMatchTheTable() public view {
        for (uint160 i; i < 14; ++i) {
            uint160 bit = uint160(1) << i;
            assertEq(h.altersDeltas(address(bit)), _altersDeltas(bit), "alters deltas: table row");
            assertEq(h.runsInSwap(address(bit)), _runsInSwap(bit), "runs in swap: table row");
        }
    }

    /// Any address: the answer is the table's on its low 14 bits, whatever the high bits hold.
    function testFuzz_HookFlags_OnlyTheLowFourteenBitsSpeak(address a, uint160 high) public view {
        uint160 low = uint160(a) & ALL_HOOK_MASK;
        assertEq(h.altersDeltas(a), _altersDeltas(low), "alters deltas is the table on the low bits");
        assertEq(h.runsInSwap(a), _runsInSwap(low), "runs in swap is the table on the low bits");
        address mined = address((high & ~ALL_HOOK_MASK) | low);
        assertEq(h.altersDeltas(mined), h.altersDeltas(a), "high bits never move alters deltas");
        assertEq(h.runsInSwap(mined), h.runsInSwap(a), "high bits never move runs in swap");
    }
}
