// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  The stable-curve overflow sentinel guards the WRONG TERM.
//
//  `_solidlyStable` refuses absurd reserves before solving the cubic:
//
//      if (X > 3.4e38 || Y > 3.4e38) return 0;
//      if (X + A > 3.4e38) return 0;
//
//  and its comment says why: "Guard the cubic terms against uint256 overflow on
//  absurd reserves." The intent is the one `_solK` states — a checked-arithmetic
//  revert here is a QUOTE DoS, so the pool must be refused with a zero that the
//  floors absorb, never with a revert that bricks the route.
//
//  3.4e38 is calibrated for the RAW PRODUCTS. `x*y`, `x*x` and `y*y` overflow
//  around x ~ 1.5e28 — the corpus records that as M1, and the fix was to route
//  them through 512-bit `mulDiv`. That closed the intermediates. It did not
//  close the RESULT, which must still fit in a uint256:
//
//      _solK(x, y) = mulDiv(mulDiv(x,y,WAD),
//                           mulDiv(x,x,WAD) + mulDiv(y,y,WAD),
//                           WAD)                     =  x·y·(x² + y²) / 1e54
//
//  Balanced (X = Y = Z) that is 2·Z⁴ / 1e54, which exceeds uint256 at
//
//      Z > (uintmax · 1e54 / 2)^(1/4)  ≈  4.9e32
//
//  So the sentinel admits everything up to 3.4e38 while the arithmetic dies at
//  4.9e32 — a window of roughly SIX ORDERS OF MAGNITUDE in which the guard says
//  "fine" and `mulDiv`'s own `require` reverts. The revert is not caught by
//  `solidlyCurveOut`, `universalQuote`, or the Solver's scan, so it propagates
//  and takes the pair's quoting with it.
//
//  This is the night's meta-pattern inside the guard written to prevent it: the
//  sentinel observes the RESERVES; what overflows is the RESULT of the
//  computation. Wrong referent — the object watched is not the object that
//  fails.
//
//  Reachable without privilege: ~4.9e14 whole tokens of an attacker-minted
//  18-decimal token seeding a stable pair puts X in the window.
//
//  RED BEFORE THE FIX: test_ReservesInsideTheWindow_MustNotRevert reverts
//  "BPC:mulDiv" instead of returning a refusal.
//
//  forge test --match-contract SolidlySentinelIsCalibratedToTheWrongTerm -vv
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixCore as BPC} from "../src/BlazePhoenixCore.sol";
import {CoreHarness} from "./mocks/CoreHarness.sol";

contract SolidlySentinelIsCalibratedToTheWrongTermTest is Test {
    /// Pinned from the source: the value the guards compare against.
    uint256 constant SENTINEL = 3.4e38;
    /// Where `_solK`'s result stops fitting in a uint256, balanced.
    uint256 constant K_FITS_BALANCED = 4.9e32;

    CoreHarness harness;

    function setUp() public {
        harness = new CoreHarness();
    }

    // ─── the arithmetic that opens the window ────────────────────────────────

    /// `_solK` is x·y·(x²+y²)/1e54. Balanced that is 2·Z⁴/1e54, so the result
    /// leaves uint256 far below the sentinel. Stated on the numbers so the gap
    /// cannot be argued away.
    function test_Arithmetic_TheSentinelSitsFarAboveWhereTheResultFits() public pure {
        // 2·Z⁴ must stay under uintmax·1e54 for the final mulDiv to fit.
        // At Z = 4.9e32 it just fits; one order of magnitude up it cannot.
        uint256 z = K_FITS_BALANCED;
        assertLt(z, SENTINEL, "the fitting bound is BELOW the sentinel");
        assertGt(SENTINEL / z, 690_000,
            "and not marginally: the sentinel admits ~6 orders of magnitude past it");
    }

    // ─── RED: inside the window the guard passes and the quote reverts ───────

    /// Reserves the sentinel explicitly admits (both under 3.4e38) but whose
    /// cubic cannot be computed. The contract's own doctrine for an unusable
    /// pool is a zero the floors absorb, never a revert.
    function test_ReservesInsideTheWindow_MustNotRevert() public view {
        uint256 inWindow = 1e35; // > 4.9e32, well under the 3.4e38 sentinel
        assertLt(inWindow, SENTINEL, "the sentinel admits this pool");

        // THE CLAIM: an admitted pool must be quotable or refused, never fatal.
        // Before the fix this reverts "BPC:mulDiv" from inside _solK.
        harness.outSolidlyStable(1e18, inWindow, inWindow, 30, 18, 18);
    }

    // ─── control: the honest ranges keep working ─────────────────────────────

    /// A pool comfortably below the fitting bound must still quote a real
    /// number — the fix must refuse the window, not the whole stable arm.
    function test_Control_NormalStablePoolStillQuotes() public view {
        uint256 out = harness.outSolidlyStable(1_000e18, 1_000_000e18, 1_000_000e18, 30, 18, 18);
        assertGt(out, 0, "an ordinary stable pool must still quote");
    }

    /// And a pool above the sentinel must still be refused with a zero, which
    /// is the behaviour that already works and must not regress.
    function test_Control_AboveTheSentinelStillReturnsZero() public view {
        uint256 out = harness.outSolidlyStable(1e18, 4e38, 4e38, 30, 18, 18);
        assertEq(out, 0, "beyond the sentinel the pool is refused, not fatal");
    }
}
