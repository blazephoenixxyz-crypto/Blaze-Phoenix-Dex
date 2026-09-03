// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  C7 / #10 - Core:1639 `universalQuote`, the `k == KIND_V4_NATIVE` arm.
//
//  THE CLAIM. The one Core quote dispatcher must price a NATIVE Uniswap-V4
//  pool - a pool whose currency0 is address(0) - and must answer with BOTH a
//  non-zero output and a non-zero, token-denominated depth. Today the arm is
//  written as a disjunction shared with the wrapped kind:
//
//      Core:1639   if (k == KIND_V4 || k == KIND_V4_NATIVE) {
//
//  and the MC/DC census of the non-guard decisions (row 10 of its triage)
//  recorded that the `k == KIND_V4_NATIVE` sub-condition is INERT: no test in
//  the suite ever quotes a native candidate at the Core level. Delete that half
//  of the disjunction and every native V4 candidate falls through to the
//  function's default `(0, 0)` return - the Solver's funnel would silently
//  drop 62.9% of the ETH-denominated V4 liquidity the Core's own KIND_V4_NATIVE
//  note measures (Arbitrum 99.6%, Optimism 95.0%, Base 48.9%) and no test in
//  915 would go red.
//
//  STATE AGAINST main 6438fe4: GREEN. Every test in this file is expected to
//  pass today. This file is not a bug report; it is the missing WATCHMAN for a
//  live arm that currently has none. What proves it is not decorative is the
//  paired mutants in .github/scripts/mutants.py, each of which must turn a NAMED test
//  in this file red.
//
//  WHAT EXERCISES WHAT (the "no unexplained pass" column):
//    - the native arm itself .......... _ZeroForOne_ and _OneForZero_
//    - the sort that puts address(0)
//      in the currency0 seat .......... _OneForZero_ (the zfo direction cannot
//                                       see it: (0, T) is already sorted)
//    - the depth decimal ordering ..... _DepthIsDirectionIndependent...
//    - the INV-20 fee measurement
//      on the native arm .............. _DynamicFeeKeyIsMeasured... and its
//                                       fail-closed twin
//    - the kind-agnosticism of the
//      shared branch .................. _MatchesTheWrappedKind...
//
//  CONTROLS THAT MUST SURVIVE ANY FUTURE FIX (anti-rigidity). Three refusals
//  are asserted here so that a later change cannot buy a native property by
//  making the arm answer for things it must not answer for:
//    - _UnplantedPoolIsZero              (no price without state)
//    - _WithoutTheNativeSubstitution...  (no price under the wrong pool id)
//    - _ZeroAmountInIsZero               (no output from no input)
//  and one control in the other direction: _MatchesTheWrappedKind... pins that
//  the wrapped kind keeps quoting, so a native "fix" cannot be bought by
//  splitting the branch and degrading the twin.
//
//  APPARATUS NOTE. No cheatcode is used anywhere in this file, so the
//  build-the-struct-before-the-prank hazard cannot arise; every QuoteCtx is
//  nevertheless fully built before the call that consumes it. `c.pool` is left
//  at address(0) on purpose: the V4 arm derives its pool id from the two
//  currencies and never reads `c.pool`. Reading it would be the defect.
//
//  forge test --match-contract CoreNativeV4Quote -vv
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixCore as BPC, QuoteCtx} from "../src/BlazePhoenixCore.sol";

/// @dev Minimal Uniswap-V4-shaped singleton: `extsload(bytes32)` answers from a
///      settable slot map. Exactly the single-slot read `BPC.v4SqrtAndLiq`
///      performs, and the only read the Core quote dispatcher makes - the
///      batched `extsload(bytes32[])` twin that MockV4DeriveManager
///      (test/V4LearnedCodeSuppressesGrid.t.sol) carries exists for the Hub's
///      derive scan and is deliberately absent here, so that a quote which
///      started using it would not silently keep passing.
///      Same idiom as MockV4StateManager in test/HardeningA4_ClaimV4Margin.t.sol.
contract MockV4SingletonForNativeQuote {
    mapping(bytes32 => bytes32) public slots;
    function setSlot(bytes32 s, bytes32 v) external { slots[s] = v; }
    function extsload(bytes32 s) external view returns (bytes32) { return slots[s]; }
}

contract CoreNativeV4QuoteTest is Test {
    MockV4SingletonForNativeQuote mgr;

    /// The native currency. This is the whole point of the kind: address(0) is
    /// the one token identifier that is identical on every EVM chain, and it
    /// sorts below every real token, so it always takes the currency0 seat.
    address constant NATIVE  = address(0);
    /// The counterpart ERC20. A bare address with no code: `_decimalsOf`
    /// staticcalls it, gets empty returndata and falls back to 18, which is
    /// what a WETH-side counterpart would answer anyway. The tests that care
    /// about decimals set them explicitly through the ctx instead.
    address constant COUNTER = address(0xC0FFEE);
    /// Stands in for WETH in the wrong-referent control: a caller that forgot
    /// to substitute address(0) would key the pool on this instead.
    address constant WRAPPED = address(0xEEEE);

    uint24  constant FEE   = 3000;      // static key: the key IS the fee
    int24   constant TS    = 60;
    uint24  constant DYN   = 0x800000;  // the dynamic-fee sentinel
    int24   constant TS_D  = 10;
    uint24  constant LP_D  = 500;       // the fee slot0 really carries

    uint128 constant LIQ = 1e21;
    uint256 constant AMT = 1e18;

    /// sqrtPriceX96 = 2 * 2**96, i.e. price 4.0. NOT price 1.0, and the reason
    /// is the assertion below: at price 1 the two virtual reserves both equal L
    /// itself, so a depth that wrongly returned the raw sqrt-scale liquidity
    /// would be numerically indistinguishable from the correct
    /// token-denominated answer. At price 4 they are L/2 and 2L.
    uint160 constant SQRT_P_4 = 158456325028528675187087900672;

    /// The two virtual reserves at SQRT_P_4 with LIQ, exact (no rounding):
    ///   x0 = mulDiv(L, Q96, sqrtP) = 1e21 / 2
    ///   x1 = mulDiv(L, sqrtP, Q96) = 1e21 * 2
    uint256 constant X0 = 5e20;
    uint256 constant X1 = 2e21;

    function setUp() public {
        mgr = new MockV4SingletonForNativeQuote();
    }

    // --- apparatus -----------------------------------------------------------

    /// @dev Plant a live V4 pool at the exact StateLibrary layout
    ///      `BPC.v4SqrtAndLiq` reads: base = keccak256(abi.encode(pid, 6))
    ///      holds slot0 packed as [0,160) sqrtPriceX96 | [160,184) tick |
    ///      [184,208) protocolFee | [208,232) lpFee, and liquidity sits at
    ///      base + 3. Mirrors `_seed` in test/V4DynamicFeeQuote.t.sol and
    ///      `_plantV4Pool` in test/HardeningA4_ClaimV4Margin.t.sol.
    function _plant(
        address cA, address cB, uint24 keyFee, int24 ts,
        uint24 lpFee, uint24 protoFee, uint160 sp, uint128 liq
    ) private {
        (address s0, address s1) = BPC.sortTokens(cA, cB);
        bytes32 pid  = BPC.computeV4PoolId(s0, s1, keyFee, ts, address(0));
        bytes32 base = keccak256(abi.encode(pid, uint256(6)));
        bytes32 word0 = bytes32(
            uint256(sp) | (uint256(protoFee) << 184) | (uint256(lpFee) << 208)
        );
        mgr.setSlot(base, word0);
        mgr.setSlot(bytes32(uint256(base) + 3), bytes32(uint256(liq)));
    }

    /// @dev The native QuoteCtx, in the exact shape `Solver._quoteWithDepth`
    ///      builds it (Solver:1197-1234): for KIND_V4_NATIVE the caller
    ///      substitutes address(0) on whichever side is the pool's token0 -
    ///      `if (zfo) qIn = address(0); else other = address(0);` - and
    ///      `zeroForOne` needs no branch, because under the registry's
    ///      WETH-canonical orientation "token0 == tIn" already means "the input
    ///      is currency0".
    function _nativeCtx(bool zfo) private view returns (QuoteCtx memory c) {
        c.kind        = BPC.KIND_V4_NATIVE;
        c.pool        = address(0);   // never read by this arm - see header
        c.zeroForOne  = zfo;
        c.fee         = FEE;
        c.tickSpacing = TS;
        c.stable      = false;
        c.tokenIn     = zfo ? NATIVE  : COUNTER;
        c.tokenOther  = zfo ? COUNTER : NATIVE;
        c.hooks       = address(0);
        c.v4Manager   = address(mgr);
        c.decIn1      = 0;            // unfilled: the Core reads them itself
        c.decOther1   = 0;
    }

    // --- the arm itself ------------------------------------------------------

    /// CLAIM: a native V4 pool, quoted with the native currency as the INPUT,
    /// returns a non-zero output and a non-zero, token-denominated depth.
    /// GREEN today. RED under mutant C7-10-A (the `k == KIND_V4_NATIVE` half of
    /// the disjunction removed): the ctx then matches no arm and the function
    /// falls through to its default (0, 0).
    /// NOT VACUOUS: the output is pinned to the one producer with the exact
    /// coordinates the arm must have chosen - static key fee (not the sentinel,
    /// not a measured lpFee) and sqrtLimit 0 (the ranking layer applies no
    /// boundary clamp) - and it is bracketed independently, below the 4:1 spot
    /// and above 97.5% of it, so an arm that answered with some other pool's
    /// number would have to coincide to the wei.
    function test_NativeV4_Quote_ZeroForOne_HasOutputAndDepth() public {
        _plant(NATIVE, COUNTER, FEE, TS, 0, 0, SQRT_P_4, LIQ);
        QuoteCtx memory c = _nativeCtx(true);

        (uint256 out, uint256 depth) = BPC.universalQuote(c, AMT);

        assertGt(out, 0, "a live native V4 pool must quote non-zero");
        assertEq(out, BPC.outV3(AMT, SQRT_P_4, LIQ, FEE, true, 0),
            "the native arm must price through outV3 at the static key fee, unclamped");
        assertLt(out, 4 * AMT,
            "fee and impact bound the quote strictly below the 4:1 spot");
        assertGt(out, (39 * AMT) / 10,
            "0.30 percent of fee on a trade of 1e-3 of L cannot cost 2.5 percent");

        assertGt(depth, 0, "a live native V4 pool must carry depth");
        assertEq(depth, X0,
            "depth is the SHORT virtual reserve in token units, not the long one");
        assertTrue(depth != uint256(LIQ),
            "depth must not be the raw sqrt-scale L: that is the cross-family bias");
        assertTrue(depth != X1, "and not the long side either");
    }

    /// CLAIM: the same pool quoted in the OTHER direction - the counterpart
    /// token in, the native currency out - also returns a non-zero output and
    /// the same depth.
    /// GREEN today. RED under mutant C7-10-A, and RED under mutant C7-10-C
    /// (`sortTokens` dropped from the pool-id derivation).
    /// WHY THIS DIRECTION EXISTS SEPARATELY, and it is the whole reason the
    /// MC/DC census flagged this row: with the native currency as the input,
    /// (c.tokenIn, c.tokenOther) is ALREADY (address(0), COUNTER), so an
    /// unsorted derivation produces the identical pool id and the zfo test
    /// cannot see the defect. Only this direction hands `sortTokens` an
    /// out-of-order pair and so only this direction proves that the native
    /// currency is put in the currency0 seat rather than left where the caller
    /// happened to put it.
    /// NOT VACUOUS: same producer pin, plus the independent 1:0.25 spot
    /// bracket in the opposite direction.
    function test_NativeV4_Quote_OneForZero_HasOutputAndDepth() public {
        _plant(NATIVE, COUNTER, FEE, TS, 0, 0, SQRT_P_4, LIQ);
        QuoteCtx memory c = _nativeCtx(false);

        (uint256 out, uint256 depth) = BPC.universalQuote(c, AMT);

        assertGt(out, 0, "the counter-to-native direction must quote non-zero");
        assertEq(out, BPC.outV3(AMT, SQRT_P_4, LIQ, FEE, false, 0),
            "the native arm must price the reverse direction through the same producer");
        assertLt(out, AMT / 4,
            "fee and impact bound the quote strictly below the 1:0.25 spot");
        assertGt(out, (24 * AMT) / 100,
            "0.30 percent of fee cannot cost 4 percent in the reverse direction");

        assertEq(depth, X0,
            "depth is a property of the pool, not of the direction it is read in");
    }

    /// CLAIM: the two V4 kinds share ONE pricing branch. Over identical
    /// currencies, fee, spacing and hooks, KIND_V4 and KIND_V4_NATIVE must
    /// return the identical output and the identical depth; only settlement
    /// differs, and settlement lives in the Router.
    /// GREEN today. RED under mutant C7-10-A (native half removed: the native
    /// side goes to zero while the wrapped side keeps quoting) and RED under
    /// mutant C7-10-B (wrapped half removed: the mirror image).
    /// DOUBLE DUTY: this is also the ANTI-RIGIDITY control. If some future
    /// change gives the native kind its own arm, this test is what refuses to
    /// let the two arms drift - which is this codebase's documented defect
    /// signature, a fix applied to one of two symmetric channels.
    /// NOT VACUOUS: both sides are asserted non-zero first, so the equality
    /// cannot be satisfied by 0 == 0.
    function test_NativeV4_Quote_MatchesTheWrappedKindOverTheSameCurrencies() public {
        _plant(NATIVE, COUNTER, FEE, TS, 0, 0, SQRT_P_4, LIQ);
        QuoteCtx memory nat = _nativeCtx(true);
        QuoteCtx memory wrp = _nativeCtx(true);
        wrp.kind = BPC.KIND_V4;

        (uint256 outN, uint256 depthN) = BPC.universalQuote(nat, AMT);
        (uint256 outW, uint256 depthW) = BPC.universalQuote(wrp, AMT);

        assertGt(outN, 0, "sanity: the native kind prices this pool");
        assertGt(outW, 0, "sanity: the wrapped kind prices the same currencies");
        assertEq(outN, outW,
            "both V4 kinds quote identically; nothing in the pricing sees nativeness");
        assertEq(depthN, depthW, "and they report one depth");
    }

    // --- the depth decimal ordering ------------------------------------------

    /// CLAIM: the depth of a native pool whose two sides have DIFFERENT
    /// decimals is the same number read from either direction. The arm maps
    /// (decIn, decOther) onto (token0, token1) with a direction ternary; if
    /// that mapping ever stops following the direction, the two reads diverge.
    /// GREEN today. RED under mutant C7-10-D (the ternary collapsed to
    /// `(dIn4, dOt4)`): direction A is unaffected, direction B then normalises
    /// the 18-decimal side as if it had 6 and reports 2e21 instead of 5e20.
    /// NOT VACUOUS, and this is the point: the equality is the load-bearing
    /// assertion, not the literal. `assertEq(depthA, X0)` alone stays GREEN
    /// under C7-10-D, because the mutant only damages the direction the
    /// existing suite never reads. Asymmetric decimals are required too - with
    /// 18/18 on both sides the ternary is a no-op and the mutant is invisible.
    /// The decimals are declared through the ctx (the `+1` encoding), which is
    /// the production path: `Solver._quoteWithDepth` hoists them once per pair.
    function test_NativeV4_Quote_DepthIsDirectionIndependentUnderAsymmetricDecimals() public {
        _plant(NATIVE, COUNTER, FEE, TS, 0, 0, SQRT_P_4, LIQ);

        QuoteCtx memory inNative = _nativeCtx(true);
        inNative.decIn1    = 19;  // the native side: 18 decimals, encoded +1
        inNative.decOther1 = 7;   // the counterpart: 6 decimals, encoded +1

        QuoteCtx memory inCounter = _nativeCtx(false);
        inCounter.decIn1    = 7;  // now the 6-decimal token is the input
        inCounter.decOther1 = 19;

        (, uint256 depthA) = BPC.universalQuote(inNative,  AMT);
        (, uint256 depthB) = BPC.universalQuote(inCounter, AMT);

        assertGt(depthA, 0, "sanity: the pool has depth in the covered direction");
        assertEq(depthA, X0,
            "currency0 - the native side, 18 decimals - is the short side at price 4");
        assertEq(depthB, depthA,
            "the same pool must report the same depth read from the other side");
    }

    // --- INV-20 on the native arm --------------------------------------------

    /// CLAIM: a NATIVE pool with a dynamic-fee key is priced at slot0's
    /// measured lpFee, not at the 0x800000 sentinel. The wrapped twin of this
    /// property is pinned by test_DynamicFeePool_NowQuotesNonZero
    /// (test/V4DynamicFeeQuote.t.sol); the native cell of that table is empty.
    /// GREEN today. RED under mutant C7-10-A.
    /// NOT VACUOUS: the assertion is the exact output at fee 500. If the
    /// sentinel reached outV3 the guard `fee >= 1_000_000` would return 0, and
    /// if the key fee were used instead of the measured one the number would be
    /// the fee-3000 quote, which differs.
    function test_NativeV4_Quote_DynamicFeeKeyIsMeasuredOnTheNativeArm() public {
        _plant(NATIVE, COUNTER, DYN, TS_D, LP_D, 0, SQRT_P_4, LIQ);
        QuoteCtx memory c = _nativeCtx(true);
        c.fee         = DYN;
        c.tickSpacing = TS_D;

        (uint256 out, uint256 depth) = BPC.universalQuote(c, AMT);

        assertGt(out, 0, "the dynamic-fee sentinel must not reach outV3 as a fee");
        assertEq(out, BPC.outV3(AMT, SQRT_P_4, LIQ, LP_D, true, 0),
            "the native arm must price at the measured lpFee, not the sentinel");
        assertTrue(out != BPC.outV3(AMT, SQRT_P_4, LIQ, FEE, true, 0),
            "sanity: the measured fee and the static-key fee are distinguishable here");
        assertEq(depth, X0, "and the depth is unaffected by which fee was measured");
    }

    /// CLAIM (control, and a refusal): a native dynamic-fee pool carrying a
    /// non-zero protocolFee fails CLOSED on output while still reporting the
    /// depth it measured. That separation is the evidence that the refusal came
    /// from effV4Fee and not from a failed state read - the "no unexplained
    /// pass" rule applied to a zero.
    /// GREEN today, and it must STAY green after any fix: a native fix that
    /// starts quoting through an unanchored protocolFee composition would turn
    /// this red, which is the intended alarm.
    function test_NativeV4_Quote_DynamicFeeWithProtocolFeeFailsClosed() public {
        _plant(NATIVE, COUNTER, DYN, TS_D, LP_D, 1, SQRT_P_4, LIQ);
        QuoteCtx memory c = _nativeCtx(true);
        c.fee         = DYN;
        c.tickSpacing = TS_D;

        (uint256 out, uint256 depth) = BPC.universalQuote(c, AMT);

        assertEq(out, 0, "a non-zero protocolFee must fail closed on the native arm too");
        assertEq(depth, X0,
            "the refusal is in the fee composition, not in the state read");
    }

    // --- controls: the refusals that must survive any fix --------------------

    /// CONTROL. No state, no price. An uninitialised native pool id reads
    /// sqrtPriceX96 = 0 and must yield (0, 0) - never a fabricated quote.
    /// GREEN today and under every mutant in this cluster; that is what makes
    /// it a control rather than a watchman.
    function test_NativeV4_Quote_UnplantedPoolIsZero() public view {
        QuoteCtx memory c = _nativeCtx(true);

        (uint256 out, uint256 depth) = BPC.universalQuote(c, AMT);

        assertEq(out, 0, "an uninitialised native pool must quote zero");
        assertEq(depth, 0, "and carry no depth");
    }

    /// CONTROL (wrong referent, axis 2a). The substitution of address(0) is the
    /// CALLER's duty - Solver._quoteWithDepth performs it. A caller that
    /// declares KIND_V4_NATIVE but hands the wrapped token over derives a
    /// DIFFERENT pool id, and must therefore get a refusal, not the native
    /// pool's price under a key that does not name it.
    /// GREEN today. Must stay green after any fix: the failure mode it forbids
    /// is an arm that "helpfully" substitutes address(0) itself and thereby
    /// prices a pool the caller did not ask for.
    function test_NativeV4_Quote_WithoutTheNativeSubstitutionFailsClosed() public {
        _plant(NATIVE, COUNTER, FEE, TS, 0, 0, SQRT_P_4, LIQ);
        QuoteCtx memory c = _nativeCtx(true);
        c.tokenIn = WRAPPED;   // the caller forgot the substitution

        (uint256 out, uint256 depth) = BPC.universalQuote(c, AMT);

        assertEq(out, 0,
            "the wrapped key names another pool id; the native price must not leak into it");
        assertEq(depth, 0, "and no depth either");
    }

    /// CONTROL. No input, no output - on the native arm as on every other.
    /// GREEN today and under every mutant here (the guard sits above the kind
    /// dispatch), which is exactly its job: it forbids a fix that manufactures
    /// output from an empty order.
    function test_NativeV4_Quote_ZeroAmountInIsZero() public {
        _plant(NATIVE, COUNTER, FEE, TS, 0, 0, SQRT_P_4, LIQ);
        QuoteCtx memory c = _nativeCtx(true);

        (uint256 out, uint256 depth) = BPC.universalQuote(c, 0);

        assertEq(out, 0, "zero in, zero out");
        assertEq(depth, 0, "and the depth channel is not a side door");
    }

    /// CONTROL (the assumption the arm's own comment rests on). The Core states
    /// that "a native currency is just address(0), which sorts first". Pinned
    /// here so that the arm's justification is falsifiable and not merely
    /// asserted in prose.
    function test_NativeV4_PoolIdIsOrientationIndependent() public pure {
        (address a0, address a1) = BPC.sortTokens(NATIVE, COUNTER);
        (address b0, address b1) = BPC.sortTokens(COUNTER, NATIVE);

        assertEq(a0, address(0), "the native currency takes the currency0 seat");
        assertEq(a0, b0, "and takes it whichever way the caller ordered the pair");
        assertEq(a1, b1, "so the counterpart takes currency1 either way");
        assertEq(
            BPC.computeV4PoolId(a0, a1, FEE, TS, address(0)),
            BPC.computeV4PoolId(b0, b1, FEE, TS, address(0)),
            "one pool, one id, regardless of the order the pair was handed in"
        );
    }
}
