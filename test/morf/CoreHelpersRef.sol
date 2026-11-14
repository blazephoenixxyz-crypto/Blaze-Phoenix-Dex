// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;
import {BlazePhoenixCore as BPC} from "../../src/BlazePhoenixCore.sol";

/// @notice The Core's five Solidly and impact helpers AS cb1d7d9 WROTE THEM, the last commit in
///         which they were doors of the library (`public`): `solidlyGetAmountOut`, `outSolidly`,
///         `solidlyCurveOut`, `readDynamicFee`, `impactV3FromOut`. FROZEN. This file is the
///         reference of `test/CoreHelpersSameAnswer.t.sol` and of nothing else; it is never
///         edited to follow the Core - an answer that moves in the Core and not here is what the
///         differential exists to show.
///
/// @dev    WHAT IS FROZEN AND WHAT IS NOT. The five bodies below are byte-for-byte copies; the
///         one word that differs is their visibility (`internal` here, so the reference is
///         inlined into its harness and needs no link). `_askWord` and `_decimalsOf` are private
///         to the Core, so the bodies cannot reach the live ones: they are frozen copies too,
///         with the two gas figures `_askWord` reads written as cb1d7d9 had them. Everything
///         else the bodies stand on - `outV2`, `mulDiv`, `token0Of`, `token1Of`,
///         `outSolidlyStable` and the constants - is the LIVE Core's, through the forwarders
///         right below. So this reference is blind to a change in those primitives, on purpose:
///         it answers one question, "do these five still say what they said", not "is the curve
///         right" (SolidlyReferenceQuote, SolidlyStableDecimals and the n-version lane ask that).
///
///         `_solidlyStable` is private as well, and `outSolidly` calls it with (18, 18).
///         `outSolidlyStable` is its internal door: the same six arguments behind two guards
///         (`ain == 0 || rIn == 0 || rOut == 0`, `fee >= BPS`) that `outSolidly` has already
///         passed when it gets there, so the forwarder below is that call and no other.
library CoreHelpersRef {
    uint256 private constant BPS = BPC.BPS;
    uint256 private constant Q96 = BPC.Q96;
    uint24 private constant V2_FEE_CEILING_BPS = BPC.V2_FEE_CEILING_BPS;
    // Core:185 and Core:193 at cb1d7d9. Literals: inline assembly reads them.
    uint256 private constant GAS_CAP = 100_000;
    uint256 private constant ASK_GAS_FLOOR = 104_587;

    function mulDiv(uint256 a, uint256 b, uint256 d) private pure returns (uint256) {
        return BPC.mulDiv(a, b, d);
    }
    function outV2(uint256 ain, uint256 rIn, uint256 rOut, uint256 fee) private pure returns (uint256) {
        return BPC.outV2(ain, rIn, rOut, fee);
    }
    function token0Of(address pool) private view returns (address) {
        return BPC.token0Of(pool);
    }
    function token1Of(address pool) private view returns (address) {
        return BPC.token1Of(pool);
    }
    function outSolidlyStable(
        uint256 ain, uint256 rIn, uint256 rOut, uint256 fee, uint8 dIn, uint8 dOut
    ) private pure returns (uint256) {
        return BPC.outSolidlyStable(ain, rIn, rOut, fee, dIn, dOut);
    }
    function _solidlyStable(
        uint256 ain, uint256 rIn, uint256 rOut, uint256 fee, uint8 dIn, uint8 dOut
    ) private pure returns (uint256) {
        return BPC.outSolidlyStable(ain, rIn, rOut, fee, dIn, dOut);
    }

    // ── frozen: Core:1442-1451 at cb1d7d9 ──
    function _askWord(address target, bytes memory cd) private view returns (bool ok, uint256 word) {
        assembly ("memory-safe") {
            if lt(gas(), ASK_GAS_FLOOR) { revert(0, 0) }
            // Two statements, not one: Yul evaluates arguments right to left, so a size check
            // written as the call's sibling would read the returndata of the call before it.
            ok := staticcall(GAS_CAP, target, add(cd, 32), mload(cd), 0x00, 0x20)
            ok := and(ok, iszero(lt(returndatasize(), 32)))
            if ok { word := mload(0x00) }
        }
    }

    // ── frozen: Core:1002-1027 at cb1d7d9 ──
    function _decimalsOf(address token) private view returns (uint8 d) {
        d = 18;
        assembly ("memory-safe") {
            let m := mload(0x40)
            mstore(m, 0x313ce56700000000000000000000000000000000000000000000000000000000)
            if staticcall(GAS_CAP, token, m, 4, m, 32) {
                if eq(returndatasize(), 32) {
                    let v := mload(m)
                    // SEVENTY-EIGHT, not 256. `to18` does `10 ** (dec - 18)`
                    // in CHECKED arithmetic: with `dec >= 96` that overflows
                    // uint256 and gives Panic 0x11 — which violates the
                    // contract written in this file ("SATURATES instead of
                    // reverting") and opens a real griefing vector: a token
                    // with `decimals() = 200` makes the swap EXECUTE every leg
                    // and only then revert in the Router's `_recordHits`, which
                    // runs OUTSIDE the try/catch. The user's gas burns in full.
                    // It also kills the Solver's `decimalsOf(tIn) + 1`, which
                    // overflows the uint8 with `decimals() == 255`.
                    // 10^77 is the largest value that fits in uint256, so 77 is
                    // the largest usable exponent; above that we fall back to
                    // the default of 18 (fail-open, coherent with the rest).
                    if lt(v, 78) { d := v }
                }
            }
        }
    }

    // ── frozen: Core:1427-1433 at cb1d7d9 ──
    function solidlyGetAmountOut(address pool, uint256 amountIn, address tokenIn)
        internal view returns (uint256 out)
    {
        (bool ok, uint256 w) = _askWord(pool, abi.encodeWithSelector(0x0ea099c1, amountIn, tokenIn));
        if (!ok) (ok, w) = _askWord(pool, abi.encodeWithSelector(0xf140a35a, amountIn, tokenIn));
        if (ok) out = w;
    }

    // ── frozen: Core:1489-1505 at cb1d7d9 ──
    function outSolidly(
        uint256 ain, uint256 rIn, uint256 rOut, uint256 fee, bool stable
    ) internal pure returns (uint256) {
        if (ain == 0 || rIn == 0 || rOut == 0) return 0;
        if (!stable) return outV2(ain, rIn, rOut, fee);
        if (fee >= BPS) return 0;
        // Stable path with EQUAL decimals (the common case: USDC/USDbC, etc.).
        // The k = x³y+xy³ invariant is homogeneous of degree 4, so when both
        // reserves share a scale the result is scale-invariant and no decimal
        // normalisation is needed. For pairs with DIFFERENT decimals the caller
        // must use outSolidlyStable(...,dIn,dOut) instead, which normalises.
        // 18, not 0: this caller's reserves are already comparable, and `10 ** (18 - 18)`
        // is 1. Passing zero here used to select a special case; it now selects the
        // scaling that a 0-decimal token actually needs, which is not what this path
        // means. Saying 18 says the intent in the value domain instead of beside it.
        return _solidlyStable(ain, rIn, rOut, fee, 18, 18);
    }

    // ── frozen: Core:1599-1608 at cb1d7d9 ──
    function solidlyCurveOut(
        address pool, uint256 ain, uint256 rIn, uint256 rOut,
        bool stable, uint256 cfgFee, address tokenIn
    ) internal view returns (uint256) {
        uint256 liveFee = readDynamicFee(pool, stable, cfgFee);
        if (!stable) return outV2(ain, rIn, rOut, liveFee);
        address t0 = token0Of(pool);
        address other = t0 == tokenIn ? token1Of(pool) : t0;
        return outSolidlyStable(ain, rIn, rOut, liveFee, _decimalsOf(tokenIn), _decimalsOf(other));
    }

    // ── frozen: Core:1691-1720 at cb1d7d9 ──
    function readDynamicFee(address pool, bool stable, uint256 cfgFee)
        internal view returns (uint256 fee)
    {
        // CEILING ON THE DECLARED FALLBACK — the sibling of `effV2Fee`.
        // `cfgFee` is `leg.fee`, i.e. CALLDATA, at all three call sites of
        // `solidlyCurveOut` (Router quote, Router execution, Core.universalQuote).
        // A Solidly-shaped pair that exposes neither `getAmountOut` nor a working
        // `factory()`/`getFee` leaves this declaration as the ONLY fee source, and
        // an over-declared value (9_900 = 99%) collapses the leg's on-chain quote
        // to ~1% of the truth. When that leg is the final hop it drags
        // `finalHopQuote` — and therefore `protocolFloorOut`, the figure this
        // protocol advertises as unforgeable by calldata — down with it.
        // The V2 arm closed exactly this in `effV2Fee` (V2_FEE_CEILING_BPS); the
        // Solidly arm reached the same primitive through here and was missed.
        // House rule B8: a defect found once is a pattern to hunt everywhere.
        fee = (cfgFee == 0 || cfgFee > V2_FEE_CEILING_BPS) ? 30 : cfgFee;
        (bool ok, uint256 word) = _askWord(pool, abi.encodeWithSignature("factory()"));
        if (!ok) return fee;
        // AN ANSWER THAT IS NOT AN ADDRESS IS A LIE ABOUT THE POOL'S ORIGIN. Decoded as an
        // address, a word with its upper bits set reverted in the ABI decoder, inside the
        // planner's per-candidate quote, and took the whole pair's planning down with it
        // (ninth wave, mohaseenbasha #15). It is read as a word (`_askWord`), and a word that
        // is not an address makes the pool unquotable: a fee of 100% prices it at zero, and
        // the pair's other venues are planned as before.
        if (word >> 160 != 0) return BPS;
        address fac = address(uint160(word));
        if (fac == address(0)) return fee;
        (ok, word) = _askWord(fac, abi.encodeWithSignature("getFee(address,bool)", pool, stable));
        if (ok && word > 0 && word < BPS) fee = word;
    }

    // ── frozen: Core:3186-3203 at cb1d7d9 ──
    function impactV3FromOut(uint256 out, uint256 amountIn, uint160 sqrtP, bool zeroForOne)
        internal pure returns (uint256)
    {
        if (out == 0 || amountIn == 0 || sqrtP == 0) return BPS;
        uint256 P = uint256(sqrtP);
        uint256 ratioBps;
        if (zeroForOne) {
            uint256 t1 = mulDiv(out, Q96, amountIn);
            uint256 t2 = mulDiv(t1, Q96, P);
            ratioBps   = mulDiv(t2, BPS, P);
        } else {
            uint256 t1 = mulDiv(out, P, amountIn);
            uint256 t2 = mulDiv(t1, P, Q96);
            ratioBps   = mulDiv(t2, BPS, Q96);
        }
        if (ratioBps >= BPS) return 0;
        return BPS - ratioBps;
    }

}
