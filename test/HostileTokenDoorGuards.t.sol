// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// Single guards behind the hostile-token rows, each driven over every venue kind:
//   - a call-back from the token (ERC-777 style) into EVERY door, from every transfer of a swap;
//   - the gas a burning treasury payee can cost a swap;
//   - the native door's wrap: a wrapper that credits nothing, credits less, restates balances;
//   - a treasury push answered with an oversized word that moved nothing;
//   - a restatement (rebase) at the pull, and between two swaps.

import {HostileRowsCells} from "./HostileTokenRowsByDoor.t.sol";
import {HostileERC20} from "./mocks/HostileERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";

contract HostileTokenDoorGuardsTest is HostileRowsCells {
    /// @dev the Router's cap on the gas of one treasury push (BlazePhoenixRouter.FEE_GAS, private).
    uint256 constant FEE_GAS = 150_000;
    uint256 constant NKINDS = 6;

    function _done(uint256 settled, uint256 refused) private view {
        assertEq(nViol, 0, "a cell broke its rule: see the VIOL lines");
        assertEq(nSettled, settled, "cells settled");
        assertEq(nRefused, refused, "cells refused");
    }

    // ---- re-entry: 6 payloads x 4 transfers of the swap, per kind ----
    function _reentry(Kind k) private {
        Row[4] memory rows = [Row.IN_PULL_HOOK, Row.IN_FEE_HOOK, Row.OUT_RECIP_HOOK, Row.OUT_ROUTER_HOOK];
        for (uint8 p; p < 6; ++p) {
            payload = p;
            for (uint256 i; i < 4; ++i) _cell(rows[i], k, Door.EXACT);
        }
        _done(24, 0);
    }
    function test_TokenCallback_EveryDoorRefused_FromEveryTransfer_V2()      public { _reentry(Kind.V2); }
    function test_TokenCallback_EveryDoorRefused_FromEveryTransfer_Solidly() public { _reentry(Kind.SOLIDLY); }
    function test_TokenCallback_EveryDoorRefused_FromEveryTransfer_V3()      public { _reentry(Kind.V3); }
    function test_TokenCallback_EveryDoorRefused_FromEveryTransfer_Algebra() public { _reentry(Kind.ALGEBRA); }
    function test_TokenCallback_EveryDoorRefused_FromEveryTransfer_V4()      public { _reentry(Kind.V4); }
    function test_TokenCallback_EveryDoorRefused_FromEveryTransfer_Ext()     public { _reentry(Kind.EXT); }

    // ---- the fee push is gas-capped: a payee that burns its gas costs at most the cap ----
    // Two measured swaps that differ in one thing: the payee reverts at once, or burns all the
    // gas the push gave it. The second may cost more than the first by at most the cap.
    function test_FeePush_BurningPayee_CostsAtMostThePushCap() public {
        for (uint256 k; k < NKINDS; ++k) {
            _cell(Row.IN_FEE_BLOCKED, Kind(k), Door.EXACT);
            uint256 gBlocked = lastGas;
            _cell(Row.IN_FEE_GASBURN, Kind(k), Door.EXACT);
            assertGt(lastGas, gBlocked, "the payee burnt no gas: the row is not hostile");
            assertLe(lastGas - gBlocked, FEE_GAS, "a gas-burning payee cost the swap more than the push cap");
        }
        _done(2 * NKINDS, 0);
    }

    // ---- the native door: the wrap is the pull ----
    function test_NativeDoor_WrapThatCreditsNothing_RefusedAsNothingReceived() public {
        forceWant = REFUSE;
        wrapBps = 0;
        for (uint256 k; k < NKINDS; ++k) {
            _cell(Row.PLAIN, Kind(k), Door.NATIVE);
            assertEq(lastWhat, "RouterE(8)", "a wrap that credited nothing is `nothing received`");
        }
        _done(0, NKINDS);
    }

    function test_NativeDoor_WrapThatCreditsLess_SettlesOnTheMeasuredCredit() public {
        forceWant = SETTLE;
        wrapBps = 9_900;
        for (uint256 k; k < NKINDS; ++k) _cell(Row.PLAIN, Kind(k), Door.NATIVE);
        _done(NKINDS, 0);
    }

    // ---- a push answered with 64 bytes that moved nothing is a refused push: booked, claimable ----
    function test_FeePush_OversizedAnswerThatMovedNothing_IsBooked() public {
        armOverride = true;
        armMode = HostileERC20.Mode.OVERSIZED_NO_MOVE;
        for (uint256 k; k < NKINDS; ++k) _cell(Row.IN_FEE_FALSE, Kind(k), Door.EXACT);
        _done(NKINDS, 0);
    }

    // ---- a restatement AT THE PULL, up and down (the rows aim none there) ----
    // Whatever the cell does, a settlement keeps the rules: the tokenIn the Router held before the
    // swap is still there share for share, and the user paid at most the ask.
    function test_Restatement_AtThePull_UpAndDown_RulesHold() public {
        forceWant = EITHER;
        loose = true;
        armOverride = true;
        for (uint256 k; k < NKINDS; ++k) {
            armMode = HostileERC20.Mode.REBASE_UP; _cell(Row.IN_PULL_HOOK, Kind(k), Door.EXACT);
            armMode = HostileERC20.Mode.REBASE_DN; _cell(Row.IN_PULL_HOOK, Kind(k), Door.EXACT);
        }
        assertEq(nViol, 0, "a cell broke its rule: see the VIOL lines");
        assertGt(nSettled, 0, "no cell settled: the rules were never read");
    }

    // ---- a restatement BETWEEN two swaps of the same pair: the second swap keeps the rules ----
    /// @dev what a pair's `sync()` does once its balances were restated.
    function _syncPair(Kind k) private {
        if (!_pair(k)) return;
        (uint256 bi, uint256 bo) = (tIn.balanceOf(venue), tOut.balanceOf(venue));
        (uint112 r0, uint112 r1) = address(tIn) < address(tOut) ? (uint112(bi), uint112(bo)) : (uint112(bo), uint112(bi));
        MockV2Pair(venue).setReserves(r0, r1);
    }

    function _between(uint256 n, uint256 d) private {
        forceWant = EITHER;
        loose = true;
        for (uint256 k; k < NKINDS; ++k) {
            _cell(Row.PLAIN, Kind(k), Door.EXACT);
            assertTrue(lastOk, "the first swap is an honest one");
            tIn.restate(n, d);
            tOut.restate(n, d);
            _syncPair(Kind(k));
            _again(Row.PLAIN, Kind(k), Door.EXACT);
        }
        assertEq(nViol, 0, "a cell broke its rule: see the VIOL lines");
        assertGt(nSettled, NKINDS, "no second swap settled: the rules were never read after the restatement");
    }
    function test_RestatementBetweenTwoSwaps_Up_SecondSwapKeepsTheRules()   public { _between(11, 10); }
    function test_RestatementBetweenTwoSwaps_Down_SecondSwapKeepsTheRules() public { _between(9, 10); }
}
