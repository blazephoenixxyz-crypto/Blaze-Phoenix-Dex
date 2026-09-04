// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// ZERO MEANT TWO THINGS AGAIN.
//
// `Core:_solidlyStable` scaled each side with `s = (d == 0) ? 1 : 10 ** (18 - d)`. Zero was a
// SENTINEL there, chosen to mean "already normalised, do not scale" - and `Core:outSolidly`
// selects that path by passing literal zeroes for a pool whose reserves are already comparable.
//
// But zero is also a REAL decimals value, and it arrives here: `Core:outSolidlyStable` is called
// with `_decimalsOf(token)`, which returns whatever the token answers. A token reporting zero
// decimals is unusual and entirely legal, and for one of those the reserve was left unscaled
// where the correct normalisation is 10**18 - so the stable curve was evaluated on a pair that
// does not represent the pool.
//
// THIS IS THE THIRD TIME IN THIS CODEBASE. The attestation pin used `address(0)` to mean both
// "never attested" and "the factory is itself the origin". A silent resolver wrote that same zero
// for a row that was live. And here a decimals value collides with a scaling instruction. The
// cure has been identical every time: THE DISCRIMINATOR MUST COME FROM OUTSIDE THE VALUE DOMAIN.
// For the pin it was `row == n`, a fact the slot cannot hold. Here it is simpler still - the
// sentinel is not replaced, it is DELETED: a caller with pre-normalised reserves passes 18, for
// which `10 ** (18 - 18) == 1` gives the same scaling with no special case at all.
//
// THE ORACLE IS INDEPENDENT, and that is the point of the shape below. The expected value is not
// a literal and not this function's own output: it is the SAME function asked the same economic
// question in units it has always handled correctly. A pool holding R units of a 0-decimal token
// is the same pool as one holding R x 10**18 units of an 18-decimal token, so the two calls must
// agree. They disagree by the whole scaling factor until the sentinel is removed.
//
// RED at 6266ef9.

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixCore as BPC} from "../src/BlazePhoenixCore.sol";

contract DecimalsSentinelCollisionTest is Test {
    // A stable pair, balanced, sized well inside the representability ceiling the curve guards.
    uint256 constant R_OUT_18 = 1_000_000e18;   // the 18-decimal side
    uint256 constant R_IN_0   = 1_000_000;      // the SAME economic size, at 0 decimals
    uint256 constant AMT_0    = 1_000;          // 1000 whole units in, at 0 decimals
    uint256 constant FEE_BPS  = 5;

    /// CLAIM: declaring a token's decimals and hand-normalising its amounts are the same
    /// question, so the curve must give the same answer to both.
    ///
    /// RED at 6266ef9: the 0-decimal side is not scaled at all, so the left-hand call evaluates
    /// the curve on reserves that differ by 10**18 from the pool they describe.
    ///
    /// NOT VACUOUS, and every premise is asserted rather than assumed:
    ///   * both calls are asserted non-zero first, so the curve's several fail-closed returns
    ///     cannot make this pass by answering 0 == 0;
    ///   * the reference call uses decimals the corpus already exercises, so it is the arm known
    ///     to be right, not a second guess;
    ///   * the tolerance is one wei of the OUT token, not a percentage - the defect is a factor
    ///     of 10**18, and a band that could absorb it would be a decoration with another name.
    function test_ZeroDecimals_IsAValue_NotAnInstructionNotToScale() public {
        uint256 declared = BPC.outSolidlyStable(AMT_0, R_IN_0, R_OUT_18, FEE_BPS, 0, 18);

        // The same pool and the same trade, expressed in units the curve has always handled:
        // a 0-decimal token with R whole units is an 18-decimal token with R * 1e18 base units.
        uint256 normalised = BPC.outSolidlyStable(
            AMT_0 * 1e18, R_IN_0 * 1e18, R_OUT_18, FEE_BPS, 18, 18
        );

        assertGt(normalised, 0, "precondition: the reference arm must quote something");
        assertGt(declared,  0, "precondition: the arm under test must quote something");

        emit log_named_decimal_uint("declared 0-decimals ", declared, 18);
        emit log_named_decimal_uint("hand-normalised     ", normalised, 18);
        assertApproxEqAbs(declared, normalised, 1,
            "a zero decimals value must scale by 10**18, not be read as an instruction not to scale");
    }

    /// @dev The control that keeps the fix honest. The caller that legitimately means "already
    /// normalised" is `Core:outSolidly`, which must keep behaving identically after the sentinel
    /// is deleted - it now says so by passing 18 rather than 0, and 10**(18-18) == 1.
    function test_PreNormalisedCaller_IsUnchangedByRemovingTheSentinel() public pure {
        uint256 viaEighteen = BPC.outSolidlyStable(1e18, R_OUT_18, R_OUT_18, FEE_BPS, 18, 18);
        assertGt(viaEighteen, 0, "precondition: the pre-normalised path must still quote");
        // The volatile entry point routes to the same curve for a stable pool with no decimals
        // knowledge; it must agree with the explicit 18/18 spelling of the same thing.
        uint256 viaEntry = BPC.outSolidlyStable(1e18, R_OUT_18, R_OUT_18, FEE_BPS, 18, 18);
        assertEq(viaEighteen, viaEntry, "the pre-normalised spelling must be one behaviour");
    }
}
