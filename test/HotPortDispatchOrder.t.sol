// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";

// =============================================================================
//  Where the hot ports sit in the Router's selector dispatcher, pinned.
//
//  Under via-IR the Router dispatches with one linear chain of compares in
//  ascending selector order, each entry `DUP1 PUSH4 sel EQ PUSH2 dest JUMPI`,
//  3 + 3 + 3 + 3 + 10 = 22 gas. A call pays every entry before its own, and a
//  pool callback that lands in `fallback()` pays all of them. So a new external
//  function whose selector sorts below a hot port charges that port 22 gas on
//  every swap, and any new external function charges the fallback 22 gas,
//  without a line of the swap path changing.
//
//  The compiler ends the chain in one of two ways, and both are read as its
//  end (read out of the two builds, 2026-11-10):
//    - at cb1d7d9 the last entry is inverted (`PUSH4 sel SUB PUSH2 fallback
//      JUMPI`) and falls through into the last function's body;
//    - since the nine control doors share one gate body (R2, 04439da) the last
//      entry is a plain compare and what follows it is `POP PUSH2 fallback JUMP`.
//  The count, the order and the six indices are the same in the two builds.
//
//  The test reads the chain out of the deployed runtime code, not out of the
//  ABI. It is GREEN at cb1d7d9; with the first ending alone it was RED on R2.
//  Mutant [morf-ACP1-T4] (an empty `a()`, selector 0x0dbe671f, below
//  swapExactIn's 0x36457c51) turns it red. If a new function is intended, update
//  the count and the indices here and record the gas it moves; that is the
//  point of the pin.
// =============================================================================
contract HotPortDispatchOrderTest is Test {
    BlazePhoenixRouter router;

    uint256 constant ENTRIES = 29;

    function setUp() public {
        BlazePhoenixHub hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        router = new BlazePhoenixRouter(address(hub), address(0xD0D0), address(this), address(0xFEE1), address(0xFEE2));
    }

    function _pushLen(uint8 op) private pure returns (uint256) {
        return (op >= 0x60 && op <= 0x7f) ? op - 0x5f : 0;
    }

    /// @dev An entry at `i`: PUSH4 sel, then EQ (or SUB for the closing entry), PUSHn dest, JUMPI.
    ///      Returns the offset after the JUMPI, or 0 when no entry starts at `i`.
    function _entry(bytes memory c, uint256 i) private pure returns (uint256 next, bytes4 sel, bool last) {
        if (i + 7 >= c.length || uint8(c[i]) != 0x63) return (0, 0, false);
        uint8 cmp = uint8(c[i + 5]);
        if (cmp != 0x14 && cmp != 0x03) return (0, 0, false);
        uint256 p = _pushLen(uint8(c[i + 6]));
        if (p == 0 || i + 7 + p >= c.length || uint8(c[i + 7 + p]) != 0x57) return (0, 0, false);
        sel = bytes4(uint32(uint8(c[i + 1])) << 24 | uint32(uint8(c[i + 2])) << 16
            | uint32(uint8(c[i + 3])) << 8 | uint32(uint8(c[i + 4])));
        return (i + 8 + p, sel, cmp == 0x03);
    }

    /// @dev The dispatcher: from the selector extraction (`PUSH1 0xe0 SHR`), the run of entries,
    ///      with only stack shuffles (DUP1, DUP2, SWAP1, POP) between them.
    function _dispatcher() private view returns (bytes4[] memory sels, bool closed) {
        bytes memory c = address(router).code;
        uint256 i;
        while (i + 2 < c.length && !(uint8(c[i]) == 0x60 && uint8(c[i + 1]) == 0xe0 && uint8(c[i + 2]) == 0x1c)) {
            i += 1 + _pushLen(uint8(c[i]));
        }
        require(i + 2 < c.length, "no selector extraction in the runtime code");
        i += 3;
        sels = new bytes4[](64);
        uint256 n;
        while (i < c.length && n < 64) {
            uint8 op = uint8(c[i]);
            if (op == 0x80 || op == 0x81 || op == 0x90 || op == 0x50) { ++i; continue; }
            (uint256 next, bytes4 sel, bool last) = _entry(c, i);
            if (next == 0) {
                // The other ending: every entry was a plain compare, and what follows the last
                // one is the unconditional jump to fallback() (`PUSH2 dest JUMP`).
                closed = n != 0 && i + 3 < c.length && uint8(c[i]) == 0x61 && uint8(c[i + 3]) == 0x56;
                break;
            }
            sels[n++] = sel;
            i = next;
            if (last) { closed = true; break; }
        }
        assembly ("memory-safe") { mstore(sels, n) }
    }

    function _indexOf(bytes4[] memory sels, bytes4 s) private pure returns (uint256) {
        for (uint256 k; k < sels.length; ++k) if (sels[k] == s) return k;
        return type(uint256).max;
    }

    /// @notice The hot ports keep their place in the dispatcher: one closed chain of 29 entries
    ///         in ascending selector order, with swapExactIn 5th (it pays 22 gas for each of the
    ///         five entries up to its own), selfExecutePrePulled 12th, unlockCallback 20th, swapExactInNative 21st,
    ///         swapBestExactIn 25th and swapExactInWithPermit2 26th.
    function test_hotPortDispatchIndex() public view {
        (bytes4[] memory sels, bool closed) = _dispatcher();
        assertTrue(closed, "the chain was not read to its end (the inverted compare, or the jump to fallback())");
        for (uint256 k = 1; k < sels.length; ++k) {
            assertLt(uint32(sels[k - 1]), uint32(sels[k]), "the chain is in ascending selector order");
        }
        assertEq(sels.length, ENTRIES, "a new external function charges fallback() callbacks 22 gas each");
        assertEq(_indexOf(sels, BlazePhoenixRouter.swapExactIn.selector), 4, "swapExactIn");
        assertEq(_indexOf(sels, BlazePhoenixRouter.selfExecutePrePulled.selector), 11, "selfExecutePrePulled");
        assertEq(_indexOf(sels, BlazePhoenixRouter.unlockCallback.selector), 19, "unlockCallback");
        assertEq(_indexOf(sels, BlazePhoenixRouter.swapExactInNative.selector), 20, "swapExactInNative");
        assertEq(_indexOf(sels, BlazePhoenixRouter.swapBestExactIn.selector), 24, "swapBestExactIn");
        assertEq(_indexOf(sels, BlazePhoenixRouter.swapExactInWithPermit2.selector), 25, "swapExactInWithPermit2");
    }
}
