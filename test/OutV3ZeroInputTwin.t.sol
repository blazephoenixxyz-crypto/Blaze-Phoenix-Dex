// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  C6 - outV3's ZERO-INPUT PIN: the missing twin of outV2's.
//
//  CLAIM. BlazePhoenixCore.outV3 must answer 0 - never a fabricated quote and
//  never a panic - when the input amount is zero, in BOTH directions and with
//  or without a sqrtLimit. Its sibling outV2 has carried that pin since
//  BlazePhoenixCore.t.sol:284 (test_OutV2_ZeroInputsReturnZero); outV3 never
//  had one. One property, two producers, one pinned and one not - the house
//  defect signature, recorded as row #14 of the MC/DC triage of 2026-09-03
//  (the triage of the non-guard MC/DC census).
//
//  EXPECTED TODAY (main @ 6438fe4): GREEN. This file is a
//  PIN, not a bug report. Core:1170
//      if (ain == 0 || liq == 0 || sqrtP == 0) return 0;
//  answers first, and the general path would answer 0 as well (derivation in
//  this cluster's README). Nothing here is expected red, and nothing here may
//  be allowed to go red by a later change.
//
//  WHY IT IS NOT VACUOUS. Every zero-input assertion is made against a state
//  that DOES quote: the same (sqrtP, liq, fee, limit) with a non-zero input
//  answers a strictly positive amount, asserted in the same test body. A green
//  "== 0" here therefore demonstrates a refusal, not a dead fixture.
//
//  THE CONTROL IS INSIDE THE ONE TEST. The two `assertGt` lines at the end of
//  the body are the witness that the fixture is alive; there is no second test
//  to keep green, and none is needed for a pure library function.
//
//  REPAIR PASS, 2026-09-03. Two of the three drafted tests were DELETED as
//  duplicates, on the finding of two independent rechecks:
//
//   * test_OutV3_ZeroSqrtLimitQuotesBothDirections
//       -> test/ConditionAdequacyCore.t.sol:266
//          test_OutV3_NonBindingUpperLimitDoesNotBendTheQuote makes the
//          IDENTICAL oneForZero call, outV3(1e18, SQRT_P_1, 1e18, 0, false, 0),
//          and asserts the identical 5e17. Mutant C6-2 was therefore already
//          killed by it - and by RouterV4NativeEth.t.sol:280/:304,
//          ConditionAdequacyRouter.t.sol:487 and the Algebra execution file.
//          The zeroForOne half was new, but it sits on the INERT side of the
//          twin (Core:1186) and can kill nothing by construction, which is
//          exactly what INERT_COMMENT_BLOCKS.md is for. C6-2 now names the
//          existing test.
//   * test_OutV3_NonBindingLowerLimitDoesNotBendTheQuote
//       -> test/TickBoundaryClamp.t.sol:62 test_SwapPequenaNaoEAfectada already
//          pins exactly this: a non-binding zeroForOne limit yields a
//          byte-identical quote. It killed no mutant and was drafted as
//          documentation for the comment block; the comment block is where that
//          argument now lives, and it is shipped in INERT_COMMENT_BLOCKS.md.
//
//  What survives is the one property nothing in test/ had: outV3's `ain == 0`
//  arm. `grep -rn "outV3(0" test/` returned one comment and no assertion.
//
//  No mocks, no cheatcodes, no state: pure library maths, so this file has no
//  struct-before-cheatcode hazard and nothing to unwind after a fix.
//
//  forge test --match-contract OutV3ZeroInputTwin -vv
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixCore as BPC} from "../src/BlazePhoenixCore.sol";

contract OutV3ZeroInputTwinTest is Test {
    // price 1.0 in Q96 sqrt space (== BPC.Q96), same literal as
    // ConditionAdequacyCore.t.sol:87
    uint160 constant SQRT_P_1 = 79228162514264337593543950336;
    uint128 constant LIQ      = 1e18;
    uint24  constant FEE      = 3000;   // 0.3% in ppm, the canonical CL tier
    uint256 constant AMT      = 1e18;

    // ---------------------------------------------------------------------
    //  Core:1170  outV3: `ain == 0 || liq == 0 || sqrtP == 0` - the `ain`
    //  arm, the one with no test. Its two siblings are pinned by
    //  ConditionAdequacyCore (`liq == 0` at :208, `sqrtP == 0` at :217).
    // ---------------------------------------------------------------------

    /// A zero input is not a quote. Six calls: both directions crossed with
    /// no limit, a limit BELOW the current price, and a limit ABOVE it - so
    /// that neither the "no clamp configured" nor the "clamp would fire"
    /// shape can be the reason the answer is zero.
    ///
    /// Non-vacuity is asserted in this same body: the identical state quotes
    /// a strictly positive amount for a non-zero input, in both directions.
    /// Without those two lines a broken fixture (dead price, dead liquidity)
    /// would make every assertEq below true for the wrong reason.
    function test_OutV3_ZeroInputsReturnZero() public pure {
        uint160 limitBelow = uint160(BPC.Q96 / 2);   // 0.25 in price terms
        uint160 limitAbove = uint160(2 * BPC.Q96);   // 4.00 in price terms

        // --- the pin: zero in, zero out, whatever the direction or limit ---
        assertEq(BPC.outV3(0, SQRT_P_1, LIQ, FEE, true,  0), 0,
            "zeroForOne, no limit: zero input must not be quoted");
        assertEq(BPC.outV3(0, SQRT_P_1, LIQ, FEE, false, 0), 0,
            "oneForZero, no limit: zero input must not be quoted");
        assertEq(BPC.outV3(0, SQRT_P_1, LIQ, FEE, true,  limitBelow), 0,
            "zeroForOne with a binding-side limit: zero input must not be quoted");
        assertEq(BPC.outV3(0, SQRT_P_1, LIQ, FEE, false, limitAbove), 0,
            "oneForZero with a binding-side limit: zero input must not be quoted");
        assertEq(BPC.outV3(0, SQRT_P_1, LIQ, FEE, true,  limitAbove), 0,
            "zeroForOne with a limit on the wrong side: zero input must not be quoted");
        assertEq(BPC.outV3(0, SQRT_P_1, LIQ, FEE, false, limitBelow), 0,
            "oneForZero with a limit on the wrong side: zero input must not be quoted");

        // --- the non-vacuity witness: this state is alive ---
        assertGt(BPC.outV3(AMT, SQRT_P_1, LIQ, FEE, true, 0), 0,
            "control: the same state must quote a non-zero amount for a real input");
        assertGt(BPC.outV3(AMT, SQRT_P_1, LIQ, FEE, false, 0), 0,
            "control: the same state must quote a non-zero amount for a real input");
    }

    // ---------------------------------------------------------------------
    //  Core:1186 / Core:1199 - the two clamps that look identical.
    //  No test here. The load-bearing one (:1199) is already killed by
    //  test/ConditionAdequacyCore.t.sol:266, which mutant C6-2 now names; the
    //  inert one (:1186) can be killed by nothing, and gets the comment block
    //  in INERT_COMMENT_BLOCKS.md instead of a mutant that would be reported
    //  DECORATIVO for ever.
    // ---------------------------------------------------------------------
}
