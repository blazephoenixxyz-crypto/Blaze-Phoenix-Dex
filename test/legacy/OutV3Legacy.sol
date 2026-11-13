// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  outV3 as it stood at 2e4fdaa (src/BlazePhoenixCore.sol:1437-1486), frozen.
//
//  The one-range quote had its own two-branch Q96 algebra with its own rounding:
//  zeroForOne floored the new sqrt price (the pool rounds it up), oneForZero
//  floored L * dSqrt / sqrtNew before scaling by Q96 / sqrtP (the pool floors
//  once, after). The body below is the text of that function, unchanged but for
//  its name and its library, so the step-parity suite can state how far the old
//  figure sat from the pool's own step. Nothing in src/ calls it.
// =============================================================================

import {BlazePhoenixCore as BPC} from "../../src/BlazePhoenixCore.sol";

library OutV3Legacy {
    uint256 internal constant Q96 = 2 ** 96;

    function mulDiv(uint256 a, uint256 b, uint256 d) private pure returns (uint256) {
        return BPC.mulDiv(a, b, d);
    }

    function outV3At2e4fdaa(
        uint256 ain, uint160 sqrtP, uint128 liq, uint24 fee, bool zeroForOne,
        uint160 sqrtLimit
    ) internal pure returns (uint256 outAmt) {
        if (ain == 0 || liq == 0 || sqrtP == 0) return 0;
        if (fee >= 1_000_000) return 0;   // guard: fee ≥ 100% → unquotable
        uint256 amtAfterFee = (ain * (1_000_000 - fee)) / 1_000_000;
        uint256 L = uint256(liq);
        uint256 P = uint256(sqrtP);
        if (zeroForOne) {
            // Canonical Uniswap V3 SqrtPriceMath.getNextSqrtPriceFromAmount0:
            //     sqrtNew = (L · sqrtP) / (L + amtIn · sqrtP / Q96)
            //
            // To avoid the L·P overflow path (L ≤ 2¹²⁸, P ≤ 2¹⁶⁰ → 2²⁸⁸),
            // we factor through mulDiv so every intermediate fits in 256 bits.
            uint256 product = mulDiv(amtAfterFee, P, Q96);
            uint256 sqrtNew = mulDiv(L, P, L + product);
            if (sqrtNew >= P || sqrtNew == 0) return 0;
            // zeroForOne: the price FALLS. Truncating means not letting it drop
            // below the boundary.
            if (sqrtLimit != 0 && sqrtNew < sqrtLimit) sqrtNew = sqrtLimit;
            outAmt = mulDiv(L, P - sqrtNew, Q96);
        } else {
            // Uniswap V3 SqrtPriceMath.getNextSqrtPriceFromAmount1:
            //     sqrtNew = sqrtP + amtIn · Q96 / L
            //     amtOut0 = L · Q96 · (sqrtNew − sqrtP) / (sqrtP · sqrtNew)
            //
            // sqrtP · sqrtNew may exceed 2²⁵⁶, so we split the division into
            // two stages: first scale by sqrtNew, then by sqrtP.
            uint256 dSqrt = mulDiv(amtAfterFee, Q96, L);
            uint256 sqrtNew = P + dSqrt;
            if (sqrtNew <= P) return 0;
            // oneForZero: the price RISES. The boundary is a ceiling.
            if (sqrtLimit != 0 && sqrtNew > sqrtLimit) sqrtNew = sqrtLimit;
            uint256 a = mulDiv(L, sqrtNew - P, sqrtNew);
            outAmt = mulDiv(a, Q96, P);
        }
    }


    /// @notice Ask a Solidly-class pair for its own exact output. Same doctrine
    ///         as an ask-the-pool adapter (quote fn == exec fn => cannot diverge):
    ///         the pair's quote is computed by its own bytecode — live fee,
    ///         stable curve and rounding included — so a swap requesting
    ///         exactly this figure satisfies the K invariant by construction
    ///         and no safety haircut is needed. Two selectors, asked in order:
    ///         getAmountOutWithTotalFee(amountIn, tokenIn) (0x0ea099c1) and,
    ///         only when that ask fails, getAmountOut(amountIn, tokenIn)
    ///         (0xf140a35a). Returns 0 when the pool exposes neither (caller
}
