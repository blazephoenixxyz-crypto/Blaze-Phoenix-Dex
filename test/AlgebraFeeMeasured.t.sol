// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  ALGEBRA-FEE-MEASURED — the un-measured sibling of INV-20.
//
//  INV-20 established "measure, don't take the nominal" for V4's dynamic fee:
//  a dynamic-fee key carries the sentinel 0x800000 and the true fee is read
//  from slot0 (effV4Fee, Core:1032). Algebra (Camelot) is the OTHER dynamic-fee
//  family in the same dispatcher, and it never received the same treatment.
//
//  The Hub FORCES every declared Algebra fee to the 0 sentinel
//  (BlazePhoenixHub.sol:361-366, "Algebra is dynamic-fee: every declared fee
//  must be the 0 sentinel (R2)"), so QuoteCtx.fee is 0 for every Algebra pool by
//  construction. universalQuote's V3/ALGEBRA branch (Core:886) passes that 0
//  straight into outV3 — pricing the pool as if it charged NO fee at all, while
//  execution pays the pool's real live fee. A systematic over-quote on every
//  Algebra pool, in the direction that harms the user (the quote promises more
//  than the pool delivers), not an edge case.
//
//  The fee is not hidden: getSqrtPriceX96 ALREADY falls back to Algebra's
//  globalState() (Core:569-575) to read the price. The live fee sits in the
//  SAME return payload, word 2 — measuring it needs no call shape the codebase
//  does not already make.
//
//  The assertions are DIFFERENTIAL — two pools identical in every way except
//  their live dynamic fee. No internal helper access needed: if the fee is
//  measured, the expensive pool must quote strictly worse. Today they tie,
//  which is the bug stated as an equation.
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixCore as BPC, QuoteCtx} from "../src/BlazePhoenixCore.sol";

/// @dev Minimal Algebra-shaped pool. It deliberately has NO slot0() — that is
///      exactly how the Core tells Algebra from V3 — and globalState() answers
///      the Algebra V1 tuple (price, tick, fee, timepointIndex, cf0, cf1, unlocked).
contract MockAlgebraPool {
    uint160 public price;
    int24 public tickV;
    uint16 public feeV;
    uint128 public liq;
    address public t0;
    address public t1;

    constructor(uint160 p, uint16 f, uint128 l, address a, address b) {
        price = p; feeV = f; liq = l; t0 = a; t1 = b;
    }

    /// @dev globalState() — selector 0xe76c01e4.
    function globalState()
        external
        view
        returns (uint160, int24, uint16, uint16, uint8, uint8, bool)
    {
        return (price, tickV, feeV, 0, 0, 0, true);
    }

    /// @dev liquidity() — selector 0x1a686502, same shape as V3.
    function liquidity() external view returns (uint128) { return liq; }

    function token0() external view returns (address) { return t0; }
    function token1() external view returns (address) { return t1; }
}

contract AlgebraFeeMeasuredTest is Test {
    address tokenA = address(0xA11CE);
    address tokenB = address(0xB0B);

    // ~1:1 price (2^96): the arithmetic stays easy to reason about.
    uint160 constant SQRT_1_1 = 79228162514264337593543950336;
    uint128 constant LIQ = 1e21;
    uint256 constant AMOUNT_IN = 1e18;

    function _ctx(address pool) internal view returns (QuoteCtx memory c) {
        c.pool = pool;
        c.kind = BPC.KIND_ALGEBRA;
        c.tokenIn = tokenA;
        c.tokenOther = tokenB;
        // The Hub forces this to 0 for every Algebra pool (Hub:361-366).
        c.fee = 0;
        c.zeroForOne = true;
    }

    function _quoteAtFee(uint16 liveFee) internal returns (uint256 out) {
        MockAlgebraPool p = new MockAlgebraPool(SQRT_1_1, liveFee, LIQ, tokenA, tokenB);
        (out,) = BPC.universalQuote(_ctx(address(p)), AMOUNT_IN);
    }

    /// THE DEFECT, as an equation: two pools that differ ONLY in their live
    /// dynamic fee must not quote the same number.
    function test_LiveDynamicFeeChangesTheQuote() public {
        uint256 cheap = _quoteAtFee(0);      // 0% dynamic fee
        uint256 pricey = _quoteAtFee(3000);  // 0.30% dynamic fee

        assertGt(cheap, 0, "the 0% pool must quote at all");
        // RED today: the live fee is ignored, so these are equal.
        assertLt(pricey, cheap, "a 0.30% Algebra pool must quote below an identical 0% one");
    }

    /// The over-quote grows with the fee — monotone, so it is systematic and
    /// not an artefact of one fee value.
    function test_QuoteIsMonotoneInTheLiveFee() public {
        uint256 q0 = _quoteAtFee(0);
        uint256 q3 = _quoteAtFee(3000);   // 0.30%
        uint256 q10 = _quoteAtFee(10000); // 1.00%

        assertLt(q3, q0, "0.30% must quote below 0%");
        assertLt(q10, q3, "1% must quote below 0.30%");
    }

    /// The size of the error is the fee itself: at 1% the fee-blind quote
    /// overstates the deliverable by ~1% of the input. Asserted as a bound so
    /// the test states the magnitude, not just the direction.
    function test_OverQuoteMagnitudeIsAtLeastTheFee() public {
        uint256 q0 = _quoteAtFee(0);
        uint256 q10 = _quoteAtFee(10000); // 1%

        // ~1% of the output, minus a wei of rounding slack.
        uint256 minGap = (q0 * 99) / 10_000;
        assertGe(q0 - q10, minGap, "a 1% fee must move the quote by ~1%");
    }

    /// A 0% dynamic fee is legal: measuring the fee must not fail closed on it.
    function test_ZeroDynamicFeeStillQuotes() public {
        assertGt(_quoteAtFee(0), 0, "a 0% dynamic-fee pool stays quotable");
    }

    /// Depth must stay token-denominated and untouched by the fee fix, so the
    /// Solver's cross-family anchor comparison is unchanged.
    function test_DepthUnchangedByFeeFix() public {
        MockAlgebraPool p = new MockAlgebraPool(SQRT_1_1, 3000, LIQ, tokenA, tokenB);
        (, uint256 depth) = BPC.universalQuote(_ctx(address(p)), AMOUNT_IN);
        assertGt(depth, 0, "depth stays token-denominated and non-zero");
    }
}
