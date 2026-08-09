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
        uint256 f    = fee == 0 ? 30 : fee;   // the ONE fee default, Core-only now
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
        // fee == 9999: heaviest legal fee still quotes.
        (uint256 outMax, ) = BPC.universalQuote(_ctx(9999, true), 1e18);
        assertEq(outMax, BPC.outV2(1e18, 1e24, 2e24, 9999));
        assertGt(outMax, 0);
        // fee >= BPS (100%): unquotable -> fail-soft 0.
        (uint256 outBad, ) = BPC.universalQuote(_ctx(10_000, true), 1e18);
        assertEq(outBad, 0, "fee >= 100% must fail-soft to 0");
        // Zero input -> 0 (dispatcher early-return).
        (uint256 outZeroIn, ) = BPC.universalQuote(_ctx(30, true), 0);
        assertEq(outZeroIn, 0);
        // Zero reserve (either side) -> 0.
        pair.setReserves(0, uint112(2e24));
        (uint256 outZeroR, ) = BPC.universalQuote(_ctx(30, true), 1e18);
        assertEq(outZeroR, 0, "zero reserves must fail-soft to 0");
    }
}
