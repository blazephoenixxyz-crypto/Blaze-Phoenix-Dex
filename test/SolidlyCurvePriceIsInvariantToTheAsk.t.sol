// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  THE SOLIDLY ASK LOWERS THE OUTPUT AND RAISES THE FEE IN THE SAME PROPORTION (B14b/C7, PR #124).
//
//  When a Solidly pair's own getAmountOut answers 0 or 1 (a venue gone silent mid-block, or a
//  fork without the selector) and the pair answers stable(), `Core._solidlyAsk` prices the
//  replicated curve and asks SOLIDLY_CURVE_ASK_BPS of it. That haircut is a charge, so the fee
//  the probe reports is 1 - (1 - f)(ASK / BPS), in pips. The band reads a venue's PRICE as
//  out / (1 - fee): the ask must move both numbers together or the band sees a different
//  price for the same pool. Two readers of one constant, one question (SHARED_QUANTITIES).
//
//  The oracle is the pair's own curve (MockSolidlyPair.getAmountOut, asked directly) and the
//  ask written here as 9,800 BPS, never the Core's branch. The seam test pins `out > 1`: a
//  pair answering 2 is taken at its word less one wei; a pair answering 1 is not an answer.
//
//  Guards, green at bb4cdbb: their reds are the mutants labelled `124-L2 Core:1545`,
//  `124-L2 Core:1546` and `124-L2 Core:1537` in .github/scripts/mutants.py.
//
//  forge test --match-path test/SolidlyCurvePriceIsInvariantToTheAsk.t.sol -vv
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixCore as BPC, QuoteCtx} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockSolidlyPair} from "./mocks/MockSolidlyPair.sol";

/// @dev A pair whose getAmountOut answers a set word (`ask`), or its curve when `ask` is max.
contract SilentSolidlyPair is MockSolidlyPair {
    uint256 public ask = type(uint256).max;

    constructor(address a, address b, bool s) MockSolidlyPair(a, b, s) {}

    function setAsk(uint256 w) external { ask = w; }

    /// @notice What the pair's curve pays, whatever `ask` says.
    function curve(uint256 a, address t) external view returns (uint256) { return super.getAmountOut(a, t); }

    function getAmountOut(uint256 a, address t) public view override returns (uint256) {
        return ask == type(uint256).max ? super.getAmountOut(a, t) : ask;
    }
}

contract SolidlyCurveAskTest is Test {
    uint256 constant BPS = 10_000;
    uint256 constant ASK = 9_800;     // the replicated curve less 200 bps
    uint256 constant PIPS = 1_000_000;
    MockERC20 A;
    MockERC20 B;
    SilentSolidlyPair pair;

    function setUp() public {
        A = new MockERC20("AAA", "AAA");
        B = new MockERC20("BBB", "BBB");
        pair = new SilentSolidlyPair(address(A), address(B), false);
    }

    /// Reserves in [1e15, 1e30], an order up to a tenth of the input side, the pair's fee in
    /// [1, 100] bps (the declared fee's ceiling: this pair has no factory), both directions.
    function testFuzz_ProbePriceIgnoresTheAsk(uint256 rIn, uint256 rOut, uint256 a, uint256 f, bool zfo) public {
        rIn = bound(rIn, 1e15, 1e30);
        rOut = bound(rOut, 1e15, 1e30);
        a = bound(a, 1, rIn / 10);
        f = bound(f, 1, 100);
        QuoteCtx memory c = _book(rIn, rOut, f, zfo);
        pair.setAsk(0);
        uint256 cv = pair.curve(a, c.tokenIn);

        (uint256 out, , , ) = BPC.universalQuoteRank(c, a, 0, false);
        (, , uint256 fee, , ) = BPC.universalProbe(c, a, 0, true, a);
        assertEq(out, cv * ASK / BPS, "the ask is 9,800 bps of the curve, floored");
        assertEq((PIPS - fee) * BPS, (BPS - f) * 100 * ASK, "the kept share is (1 - f) times the ask");
        // The price the band reads, out / (1 - fee), is the curve's price / (1 - f), to one wei of out.
        assertApproxEqAbs(out * (BPS - f) * 100, cv * (PIPS - fee), (BPS - f) * 100, "one price");
    }

    /// The seam `out > 1`: a pair answering 2 is taken at its word less one wei and its fee; a
    /// pair answering 1 is priced on the curve with the ask.
    function test_AskAtTheSeamMatchesTheGetAmountOutPath() public {
        uint256 f = 30;
        QuoteCtx memory c = _book(1e24, 1e24, f, true);
        uint256 a = 1e18;

        pair.setAsk(2);
        (uint256 out, , , ) = BPC.universalQuoteRank(c, a, 0, false);
        (, , uint256 fee, , ) = BPC.universalProbe(c, a, 0, true, a);
        assertEq(out, 1, "a word of 2 is taken less one wei");
        assertEq(fee, f * 100, "and charged the pair's fee");

        pair.setAsk(1);
        uint256 cv = pair.curve(a, c.tokenIn);
        (out, , , ) = BPC.universalQuoteRank(c, a, 0, false);
        (, , fee, , ) = BPC.universalProbe(c, a, 0, true, a);
        assertGt(cv, 1e17, "the curve pays");
        assertEq(out, cv * ASK / BPS, "a word of 1 is no answer: the curve, asked");
        assertEq((PIPS - fee) * BPS, (BPS - f) * 100 * ASK, "and charged the ask");
    }

    /// The pair holding what it declares, its fee `f`, and the context of an order in the
    /// direction `zfo` with `rIn` on the input side.
    function _book(uint256 rIn, uint256 rOut, uint256 f, bool zfo) internal returns (QuoteCtx memory c) {
        (uint256 r0, uint256 r1) = zfo ? (rIn, rOut) : (rOut, rIn);
        pair.setReserves(uint112(r0), uint112(r1));
        pair.setFeeBps(f);
        MockERC20(pair.token0()).mint(address(pair), r0);
        MockERC20(pair.token1()).mint(address(pair), r1);
        c.kind = BPC.KIND_SOLIDLY;
        c.pool = address(pair);
        c.zeroForOne = zfo;
        c.fee = uint24(f);
        c.stable = false;
        c.tokenIn = zfo ? pair.token0() : pair.token1();
        c.tokenOther = zfo ? pair.token1() : pair.token0();
        c.decIn1 = 19;
        c.decOther1 = 19;
    }
}
