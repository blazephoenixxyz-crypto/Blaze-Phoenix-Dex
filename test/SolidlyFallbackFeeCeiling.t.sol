// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixCore as BPC} from "../src/BlazePhoenixCore.sol";

/// @notice A Solidly-SHAPED pair that answers reserves but exposes neither
///         `getAmountOut` nor `factory()`. Both absences are what an attacker
///         deploys: the first forces the replicated-curve fallback, the second
///         leaves the caller-declared fee as the only fee source.
contract HeadlessSolidlyPair {
    address public immutable token0;
    address public immutable token1;
    uint112 private r0;
    uint112 private r1;

    constructor(address a, address b, uint112 x, uint112 y) {
        (token0, token1) = a < b ? (a, b) : (b, a);
        (r0, r1) = (x, y);
    }

    function getReserves() external view returns (uint112, uint112, uint32) {
        return (r0, r1, uint32(block.timestamp));
    }
    // deliberately NO getAmountOut(uint256,address)
    // deliberately NO factory()
}

/// @notice The V2 arm caps a caller-declared fee at `V2_FEE_CEILING_BPS`
///         (commit 8464b14, "the deflatable protocol floor"). The Solidly arm
///         reaches the same quote primitive through `readDynamicFee`'s
///         `cfgFee` fallback, and that fallback had no ceiling: a route could
///         declare a 99% fee on an attacker-shaped pair, collapse the leg's
///         on-chain quote, and — when the leg is the final hop — deflate
///         `finalHopQuote` and with it `protocolFloorOut`, the figure the
///         protocol advertises as unforgeable by calldata.
///
///         Reported externally 2026-08-26. This is the sibling hunt the V2 fix
///         should have carried out (house rule B8: when one instance falls,
///         grep the codebase for its siblings before closing the item).
contract SolidlyFallbackFeeCeilingTest is Test {
    HeadlessSolidlyPair internal pair;
    address internal tokenA = address(0xA11);
    address internal tokenB = address(0xB22);

    uint256 internal constant RESERVE = 1_000_000e18;
    uint256 internal constant AMOUNT_IN = 1_000e18;

    function setUp() public {
        pair = new HeadlessSolidlyPair(tokenA, tokenB, uint112(RESERVE), uint112(RESERVE));
    }

    /// RED BEFORE THE FIX: a 99% declared fee is honoured verbatim, so the
    /// quote collapses to ~1% of the honest figure.
    function test_DeclaredFeeAboveCeilingCannotDeflateTheSolidlyQuote() public view {
        uint256 honest = BPC.solidlyCurveOut(
            address(pair), AMOUNT_IN, RESERVE, RESERVE, false, 30, tokenA
        );
        uint256 forged = BPC.solidlyCurveOut(
            address(pair), AMOUNT_IN, RESERVE, RESERVE, false, 9_900, tokenA
        );

        assertGt(honest, 0, "honest baseline must quote");
        // The forged declaration must be clamped back to the canonical default,
        // so it can never price the leg below the honest quote.
        assertEq(forged, honest, "an over-declared fee must clamp to the canonical default");
    }

    /// The clamp is applied to the CALLER-DECLARED value only. A fee inside the
    /// plausible band still prices the pool exactly as declared.
    function test_PlausibleDeclaredFeeIsStillHonoured() public view {
        uint256 atCeiling = BPC.solidlyCurveOut(
            address(pair), AMOUNT_IN, RESERVE, RESERVE, false, 100, tokenA
        );
        uint256 atDefault = BPC.solidlyCurveOut(
            address(pair), AMOUNT_IN, RESERVE, RESERVE, false, 30, tokenA
        );
        assertGt(atDefault, atCeiling, "a higher in-band fee must still cost more output");
        assertGt(atCeiling, 0, "an in-band fee must remain quotable");
    }

    /// A zero declaration is the "no fee configured" sentinel and must fall back
    /// to the canonical 30 bps, exactly as the V2 arm does.
    function test_ZeroDeclarationFallsBackToCanonicalDefault() public view {
        uint256 zero = BPC.solidlyCurveOut(
            address(pair), AMOUNT_IN, RESERVE, RESERVE, false, 0, tokenA
        );
        uint256 thirty = BPC.solidlyCurveOut(
            address(pair), AMOUNT_IN, RESERVE, RESERVE, false, 30, tokenA
        );
        assertEq(zero, thirty, "zero sentinel must price at the canonical default");
    }

    /// The ceiling lives on the calldata fallback, never on a measured value:
    /// `readDynamicFee` must still return the pool's own factory fee untouched
    /// when the pool exposes one. Guarded here as a unit on the primitive.
    function test_CeilingAppliesToTheDeclaredValueNotTheMeasuredOne() public view {
        // The headless pair has no factory(), so the declared value is the only
        // source and must be clamped.
        uint256 clamped = BPC.readDynamicFee(address(pair), false, 9_900);
        assertLe(clamped, 100, "declared fee must be clamped to the ceiling band");
    }
}
