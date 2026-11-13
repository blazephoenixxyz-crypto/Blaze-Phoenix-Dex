// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

// =============================================================================
//  The pool's own step, as an oracle: Uniswap v3-core FullMath, UnsafeMath,
//  SqrtPriceMath and SwapMath.computeSwapStep, ported from
//  https://github.com/Uniswap/v3-core/tree/main/contracts/libraries
//  (SwapMath.sol, SqrtPriceMath.sol: BUSL-1.1 with Change Date 2023-04-01 and
//  Change License GPL-2.0-or-later; FullMath.sol: MIT; UnsafeMath.sol: MIT).
//
//  The port is textual. Only what solc 0.8 forces changed: the wrapping
//  arithmetic v3 relied on (<0.8) sits in `unchecked`, `-denominator` is
//  `0 - denominator`, LowGasSafeMath.add / SafeCast.toUint160 are checked
//  0.8 arithmetic and an explicit require. Nothing here calls the Core: the
//  oracle is not the object under test.
// =============================================================================

library FullMathRef {
    function mulDiv(uint256 a, uint256 b, uint256 denominator) internal pure returns (uint256 result) {
        unchecked {
            uint256 prod0;
            uint256 prod1;
            assembly {
                let mm := mulmod(a, b, not(0))
                prod0 := mul(a, b)
                prod1 := sub(sub(mm, prod0), lt(mm, prod0))
            }
            if (prod1 == 0) {
                require(denominator > 0);
                assembly {
                    result := div(prod0, denominator)
                }
                return result;
            }
            require(denominator > prod1);
            uint256 remainder;
            assembly {
                remainder := mulmod(a, b, denominator)
            }
            assembly {
                prod1 := sub(prod1, gt(remainder, prod0))
                prod0 := sub(prod0, remainder)
            }
            uint256 twos = (0 - denominator) & denominator;
            assembly {
                denominator := div(denominator, twos)
            }
            assembly {
                prod0 := div(prod0, twos)
            }
            assembly {
                twos := add(div(sub(0, twos), twos), 1)
            }
            prod0 |= prod1 * twos;
            uint256 inv = (3 * denominator) ^ 2;
            inv *= 2 - denominator * inv;
            inv *= 2 - denominator * inv;
            inv *= 2 - denominator * inv;
            inv *= 2 - denominator * inv;
            inv *= 2 - denominator * inv;
            inv *= 2 - denominator * inv;
            result = prod0 * inv;
            return result;
        }
    }

    function mulDivRoundingUp(uint256 a, uint256 b, uint256 denominator) internal pure returns (uint256 result) {
        result = mulDiv(a, b, denominator);
        if (mulmod(a, b, denominator) > 0) {
            require(result < type(uint256).max);
            result++;
        }
    }

    function divRoundingUp(uint256 x, uint256 y) internal pure returns (uint256 z) {
        assembly {
            z := add(div(x, y), gt(mod(x, y), 0))
        }
    }
}

library SqrtPriceMathRef {
    uint8 internal constant RESOLUTION = 96;
    uint256 internal constant Q96 = 0x1000000000000000000000000;

    function getNextSqrtPriceFromAmount0RoundingUp(uint160 sqrtPX96, uint128 liquidity, uint256 amount, bool add)
        internal pure returns (uint160)
    {
        if (amount == 0) return sqrtPX96;
        uint256 numerator1 = uint256(liquidity) << RESOLUTION;
        if (add) {
            unchecked {
                uint256 product;
                if ((product = amount * sqrtPX96) / amount == sqrtPX96) {
                    uint256 denominator = numerator1 + product;
                    if (denominator >= numerator1) {
                        return uint160(FullMathRef.mulDivRoundingUp(numerator1, sqrtPX96, denominator));
                    }
                }
            }
            return uint160(FullMathRef.divRoundingUp(numerator1, (numerator1 / sqrtPX96) + amount));
        } else {
            uint256 product;
            unchecked {
                require((product = amount * sqrtPX96) / amount == sqrtPX96 && numerator1 > product);
            }
            uint256 denominator = numerator1 - product;
            uint256 r = FullMathRef.mulDivRoundingUp(numerator1, sqrtPX96, denominator);
            require(r <= type(uint160).max);
            return uint160(r);
        }
    }

    function getNextSqrtPriceFromAmount1RoundingDown(uint160 sqrtPX96, uint128 liquidity, uint256 amount, bool add)
        internal pure returns (uint160)
    {
        if (add) {
            uint256 quotient = (
                amount <= type(uint160).max
                    ? (amount << RESOLUTION) / liquidity
                    : FullMathRef.mulDiv(amount, Q96, liquidity)
            );
            uint256 r = uint256(sqrtPX96) + quotient;
            require(r <= type(uint160).max);
            return uint160(r);
        } else {
            uint256 quotient = (
                amount <= type(uint160).max
                    ? FullMathRef.divRoundingUp(amount << RESOLUTION, liquidity)
                    : FullMathRef.mulDivRoundingUp(amount, Q96, liquidity)
            );
            require(sqrtPX96 > quotient);
            return uint160(sqrtPX96 - quotient);
        }
    }

    function getNextSqrtPriceFromInput(uint160 sqrtPX96, uint128 liquidity, uint256 amountIn, bool zeroForOne)
        internal pure returns (uint160 sqrtQX96)
    {
        require(sqrtPX96 > 0);
        require(liquidity > 0);
        return zeroForOne
            ? getNextSqrtPriceFromAmount0RoundingUp(sqrtPX96, liquidity, amountIn, true)
            : getNextSqrtPriceFromAmount1RoundingDown(sqrtPX96, liquidity, amountIn, true);
    }

    function getNextSqrtPriceFromOutput(uint160 sqrtPX96, uint128 liquidity, uint256 amountOut, bool zeroForOne)
        internal pure returns (uint160 sqrtQX96)
    {
        require(sqrtPX96 > 0);
        require(liquidity > 0);
        return zeroForOne
            ? getNextSqrtPriceFromAmount1RoundingDown(sqrtPX96, liquidity, amountOut, false)
            : getNextSqrtPriceFromAmount0RoundingUp(sqrtPX96, liquidity, amountOut, false);
    }

    function getAmount0Delta(uint160 sqrtRatioAX96, uint160 sqrtRatioBX96, uint128 liquidity, bool roundUp)
        internal pure returns (uint256 amount0)
    {
        if (sqrtRatioAX96 > sqrtRatioBX96) (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);
        uint256 numerator1 = uint256(liquidity) << RESOLUTION;
        uint256 numerator2 = sqrtRatioBX96 - sqrtRatioAX96;
        require(sqrtRatioAX96 > 0);
        return roundUp
            ? FullMathRef.divRoundingUp(FullMathRef.mulDivRoundingUp(numerator1, numerator2, sqrtRatioBX96), sqrtRatioAX96)
            : FullMathRef.mulDiv(numerator1, numerator2, sqrtRatioBX96) / sqrtRatioAX96;
    }

    function getAmount1Delta(uint160 sqrtRatioAX96, uint160 sqrtRatioBX96, uint128 liquidity, bool roundUp)
        internal pure returns (uint256 amount1)
    {
        if (sqrtRatioAX96 > sqrtRatioBX96) (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);
        return roundUp
            ? FullMathRef.mulDivRoundingUp(liquidity, sqrtRatioBX96 - sqrtRatioAX96, Q96)
            : FullMathRef.mulDiv(liquidity, sqrtRatioBX96 - sqrtRatioAX96, Q96);
    }
}

library SwapMathRef {
    function computeSwapStep(
        uint160 sqrtRatioCurrentX96,
        uint160 sqrtRatioTargetX96,
        uint128 liquidity,
        int256 amountRemaining,
        uint24 feePips
    ) internal pure returns (uint160 sqrtRatioNextX96, uint256 amountIn, uint256 amountOut, uint256 feeAmount) {
        bool zeroForOne = sqrtRatioCurrentX96 >= sqrtRatioTargetX96;
        bool exactIn = amountRemaining >= 0;

        if (exactIn) {
            uint256 amountRemainingLessFee = FullMathRef.mulDiv(uint256(amountRemaining), 1e6 - feePips, 1e6);
            amountIn = zeroForOne
                ? SqrtPriceMathRef.getAmount0Delta(sqrtRatioTargetX96, sqrtRatioCurrentX96, liquidity, true)
                : SqrtPriceMathRef.getAmount1Delta(sqrtRatioCurrentX96, sqrtRatioTargetX96, liquidity, true);
            if (amountRemainingLessFee >= amountIn) sqrtRatioNextX96 = sqrtRatioTargetX96;
            else {
                sqrtRatioNextX96 = SqrtPriceMathRef.getNextSqrtPriceFromInput(
                    sqrtRatioCurrentX96, liquidity, amountRemainingLessFee, zeroForOne
                );
            }
        } else {
            amountOut = zeroForOne
                ? SqrtPriceMathRef.getAmount1Delta(sqrtRatioTargetX96, sqrtRatioCurrentX96, liquidity, false)
                : SqrtPriceMathRef.getAmount0Delta(sqrtRatioCurrentX96, sqrtRatioTargetX96, liquidity, false);
            if (uint256(-amountRemaining) >= amountOut) sqrtRatioNextX96 = sqrtRatioTargetX96;
            else {
                sqrtRatioNextX96 = SqrtPriceMathRef.getNextSqrtPriceFromOutput(
                    sqrtRatioCurrentX96, liquidity, uint256(-amountRemaining), zeroForOne
                );
            }
        }

        bool max = sqrtRatioTargetX96 == sqrtRatioNextX96;

        if (zeroForOne) {
            amountIn = max && exactIn
                ? amountIn
                : SqrtPriceMathRef.getAmount0Delta(sqrtRatioNextX96, sqrtRatioCurrentX96, liquidity, true);
            amountOut = max && !exactIn
                ? amountOut
                : SqrtPriceMathRef.getAmount1Delta(sqrtRatioNextX96, sqrtRatioCurrentX96, liquidity, false);
        } else {
            amountIn = max && exactIn
                ? amountIn
                : SqrtPriceMathRef.getAmount1Delta(sqrtRatioCurrentX96, sqrtRatioNextX96, liquidity, true);
            amountOut = max && !exactIn
                ? amountOut
                : SqrtPriceMathRef.getAmount0Delta(sqrtRatioCurrentX96, sqrtRatioNextX96, liquidity, false);
        }

        if (!exactIn && amountOut > uint256(-amountRemaining)) {
            amountOut = uint256(-amountRemaining);
        }

        if (exactIn && sqrtRatioNextX96 != sqrtRatioTargetX96) {
            feeAmount = uint256(amountRemaining) - amountIn;
        } else {
            feeAmount = FullMathRef.mulDivRoundingUp(amountIn, feePips, 1e6 - feePips);
        }
    }
}
