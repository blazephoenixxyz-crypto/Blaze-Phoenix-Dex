// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// Parity pin for the BP-14/P4 dedup (the Quoter's local V2 pricing branch was
// replaced by a call to the ONE Core dispatcher). This file proves, and then
// permanently guards, that BPC.universalQuote's KIND_V2 branch computes
// EXACTLY the formula the Quoter used to inline — including the 0 -> 30 bps
// fee default — and that the fail-soft guards (zero reserves, fee >= 100%)
// behave as outV2 documents. It also exercises the library THROUGH the
// deployed-artifact path: with universalQuote public, every BPC.universalQuote
// call below compiles as a delegatecall into the auto-deployed library, so a
// linking regression fails loudly here.
//
// forge test --match-contract CoreV2QuoteParity -vvv

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixCore as BPC, QuoteCtx} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";

contract CoreV2QuoteParityTest is Test {
    MockERC20 tokenA;
    MockERC20 tokenB;
    MockV2Pair pair;

    function setUp() public {
        tokenA = new MockERC20("A", "A");
        tokenB = new MockERC20("B", "B");
        pair = new MockV2Pair(address(tokenA), address(tokenB));
    }

    function _ctx(uint24 fee, bool zfo) private view returns (QuoteCtx memory qc) {
        qc.kind       = BPC.KIND_V2;
        qc.pool       = address(pair);
        qc.zeroForOne = zfo;
        qc.fee        = fee;
    }

    /// @notice Fuzz pin: inside the sane domain (non-zero reserves, fee <
    ///         100%), the dispatcher's V2 branch equals the literal constant-
    ///         product formula the Quoter used to carry. Bounds exist because
    ///         the LITERAL formula (unlike outV2) has no fail-soft guards:
    ///         fee > BPS would underflow-revert and zero reserves would
    ///         divide by zero — those regions are pinned by the deterministic
    ///         edge cases below, against outV2 itself.
    ///
    ///         THE EXPECTATION MIRRORS effV2Fee, IT DOES NOT RE-DERIVE IT.
    ///         This test used to hard-code `fee == 0 ? 30 : fee` — a second
    ///         copy of the very number the Core exists to produce once, and it
    ///         went red the day the producer grew a CEILING (finding F2,
    ///         2026-08-25: a V2 pair has no `fee()` to contradict calldata, so
    ///         a declared 99% deflated the quote to ~1% and collapsed
    ///         `protocolFloorOut` with it). A parity pin that re-derives the
    ///         thing it is pinning tests its own copy. It now CALLS the
    ///         producer, so the pin follows the doctrine instead of freezing
    ///         one version of it.
    function testFuzz_V2BranchMatchesLiteralFormula(
        uint112 r0, uint112 r1, uint96 ain, uint24 fee, bool zfo
    ) public {
        r0  = uint112(bound(uint256(r0), 1, type(uint112).max));
        r1  = uint112(bound(uint256(r1), 1, type(uint112).max));
        fee = uint24(bound(uint256(fee), 0, BPC.BPS - 1));
        pair.setReserves(r0, r1);

        (uint256 out, uint256 depth) = BPC.universalQuote(_ctx(fee, zfo), ain);

        uint256 rIn  = zfo ? r0 : r1;
        uint256 rOut = zfo ? r1 : r0;
        uint256 f    = BPC.effV2Fee(fee);     // the ONE producer — default AND ceiling
        uint256 amtFee = uint256(ain) * (BPC.BPS - f);
        uint256 expected = ain == 0 ? 0 : (amtFee * rOut) / (rIn * BPC.BPS + amtFee);

        assertEq(out, expected, "V2 branch diverged from the constant-product formula");
        if (ain != 0) assertEq(depth, rIn < rOut ? rIn : rOut, "V2 depth must be min(reserves)");
    }

    /// @notice Deterministic edges, asserted against BPC.outV2 semantics (NOT
    ///         the literal formula — outside the fuzz domain the formula
    ///         reverts where outV2 fail-softs to 0).
    function test_V2Branch_EdgeGuards() public {
        pair.setReserves(uint112(1e24), uint112(2e24));
        // fee == 0 -> the 30 bps default lives in the dispatcher alone.
        (uint256 outDefault, ) = BPC.universalQuote(_ctx(0, true), 1e18);
        assertEq(outDefault, BPC.outV2(1e18, 1e24, 2e24, 30), "fee=0 must default to 30 bps");
        // fee == 100 (1%): the heaviest PLAUSIBLE V2 fee passes through intact.
        (uint256 outCeil, ) = BPC.universalQuote(_ctx(100, true), 1e18);
        assertEq(outCeil, BPC.outV2(1e18, 1e24, 2e24, 100), "1% is plausible and must pass intact");
        assertGt(outCeil, 0);
        // fee == 9999: ADVERSARIAL. Was "heaviest legal fee still quotes" — and
        // that was the defect (F2): quoting it is what let calldata deflate the
        // protocol floor. It now falls back to the house default, so the quote
        // is IDENTICAL to the honest one and there is nothing to deflate.
        (uint256 outAdversarial, ) = BPC.universalQuote(_ctx(9999, true), 1e18);
        assertEq(outAdversarial, outDefault, "F2: an over-declared fee must quote as the 30 bps default");
        // fee >= BPS (100%): also above the ceiling, so it defaults like any
        // other over-declaration. The outV2 fail-soft at fee >= 1e6 stays as the
        // last line of defence for a fee that reaches it by another path.
        (uint256 outBad, ) = BPC.universalQuote(_ctx(10_000, true), 1e18);
        assertEq(outBad, outDefault, "a fee at/above 100% is over-declared: defaults, never quotes 0");
        assertEq(BPC.outV2(1e18, 1e24, 2e24, 1_000_000), 0, "outV2 still fail-softs a >=100% fee to 0");
        // Zero input -> 0 (dispatcher early-return).
        (uint256 outZeroIn, ) = BPC.universalQuote(_ctx(30, true), 0);
        assertEq(outZeroIn, 0);
        // Zero reserve (either side) -> 0.
        pair.setReserves(0, uint112(2e24));
        (uint256 outZeroR, ) = BPC.universalQuote(_ctx(30, true), 1e18);
        assertEq(outZeroR, 0, "zero reserves must fail-soft to 0");
    }
}
