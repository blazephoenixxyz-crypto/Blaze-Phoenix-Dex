// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {BlazePhoenixCore as BPC} from "../../src/BlazePhoenixCore.sol";

interface IERC20Alg {
    function transfer(address to, uint256 amt) external returns (bool);
    function balanceOf(address who) external view returns (uint256);
}

interface IAlgebraSwapCallback {
    function algebraSwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external;
}

/// @notice Minimal Algebra-shaped (Camelot V3) pool mock — the EXECUTABLE
///         sibling of the quote-only mock in test/AlgebraFeeMeasured.t.sol.
///         Modelled on MockV3Pool; only what the family actually differs in
///         is changed:
///
///         • NO slot0(). Core.v3StateAndDynFee (Core:918) tries slot0()
///           (0x3850c7bd, Core:924) FIRST and only falls back to Algebra's
///           globalState() (0xe76c01e4, Core:943) when slot0 yields no price.
///           The absence of slot0 IS how the codebase tells Algebra from V3
///           (Hub:1592 derives KIND_ALGEBRA from exactly this shape), so a
///           mock that answered slot0 would be classified — and priced — as
///           a static V3 pool and never exercise the family.
///
///         • NO fee() getter. Algebra pools do not expose fee()
///           (Router:775-777); the live fee is word 2 of globalState()'s
///           return payload (Core:947-949 masks it with 0xffffff; the field
///           is uint16 on Algebra V1/Integral, Core:930-931). The dynamic-fee
///           storage variable is deliberately NOT named `fee` — a public
///           `fee` would synthesize the 0xddca3f43 getter (Core:790) and
///           silently turn this into a V3-quotable pool.
///
///         • The fee is DYNAMIC. setDynamicFee() moves it between
///           transactions (quote-then-execute across blocks), and
///           setFeeShiftOnSwap() arms a one-shot shift applied at swap()
///           ENTRY — i.e. after the Router's in-frame quote of the leg
///           (Router:752-816 runs before _execScaled) but before execution
///           prices the trade. That models the real Algebra behaviour: the
///           adaptive fee is recomputed when the swap runs, so the fee
///           globalState() reported at quote time is not necessarily the fee
///           the swap charges. A static-fee mock cannot express this, which
///           is the family's characteristic risk and the reason this mock
///           exists.
///
///         Like MockV3Pool, it quotes via the SAME BPC.outV3 formula the
///         Router uses on never-mutating price/liquidity state, so for any
///         FIXED fee quote == execution by construction; every divergence in
///         a test is then attributable to the fee having moved.
contract MockAlgebraPool {
    address public token0;
    address public token1;
    uint160 public sqrtPriceX96;
    /// @dev liquidity() — selector 0x1a686502, read by Core.getLiquidity
    ///      (Core:772-775); same shape as V3.
    uint128 public liquidity;

    /// @dev The live dynamic fee (ppm), reported in globalState() word 2 and
    ///      charged by swap(). uint16 like the real Algebra V1 field.
    uint16 internal dynFee;

    /// @dev One-shot fee shift applied at swap() entry — see the header.
    uint16 internal shiftTo;
    bool   internal shiftArmed;

    constructor(address _token0, address _token1, uint16 _dynFee) {
        (token0, token1) = _token0 < _token1 ? (_token0, _token1) : (_token1, _token0);
        dynFee = _dynFee;
    }

    function setState(uint160 _sqrtPriceX96, uint128 _liquidity) external {
        sqrtPriceX96 = _sqrtPriceX96;
        liquidity = _liquidity;
    }

    /// @notice Move the dynamic fee between the quote and the execution tx.
    function setDynamicFee(uint16 f) external { dynFee = f; }

    /// @notice Arm a one-shot fee shift that fires at swap() entry — AFTER
    ///         the Router's in-frame quote has read globalState(), BEFORE the
    ///         swap is priced.
    function setFeeShiftOnSwap(uint16 f) external { shiftTo = f; shiftArmed = true; }

    /// @notice The fee the pool would charge right now — test convenience.
    function currentDynFee() external view returns (uint16) { return dynFee; }

    /// @dev globalState() — selector 0xe76c01e4, the Algebra V1 tuple
    ///      (price, tick, fee, timepointIndex, cf0, cf1, unlocked).
    ///      Core.v3StateAndDynFee reads word 0 (price) and word 2 (fee) and
    ///      asserts `dyn` only on a >= 96-byte payload (Core:947-950); this
    ///      7-word answer satisfies both readers.
    function globalState()
        external view
        returns (uint160, int24, uint16, uint16, uint8, uint8, bool)
    {
        return (sqrtPriceX96, 0, dynFee, 0, 0, 0, true);
    }

    /// @dev Same signature the Router calls through IUniswapV3PoolMin
    ///      (Router:102-107); Algebra's swap is V3-shaped except for the
    ///      callback name, and the Router's universal callback fallback
    ///      (Router:1711) is selector-agnostic on the (int256,int256,bytes)
    ///      layout — so this mock calls the REAL Algebra callback selector.
    function swap(
        address recipient, bool zeroForOne, int256 amountSpecified,
        uint160 /*sqrtPriceLimitX96*/, bytes calldata data
    ) external returns (int256 amount0, int256 amount1) {
        // The adaptive fee is recomputed at swap time — the shift lands here,
        // after every quote of this tx and before the trade is priced.
        if (shiftArmed) {
            dynFee = shiftTo;
            shiftArmed = false;
        }

        require(amountSpecified > 0, "MockAlgebraPool: exact-out unsupported");
        uint256 amtIn = uint256(amountSpecified);
        // The fee is the pool's own MEASURED dynamic fee — never calldata.
        uint256 amtOut = BPC.outV3(amtIn, sqrtPriceX96, liquidity, dynFee, zeroForOne, 0);
        require(amtOut > 0, "MockAlgebraPool: zero out");

        address tokenIn  = zeroForOne ? token0 : token1;
        address tokenOut = zeroForOne ? token1 : token0;

        amount0 = zeroForOne ? int256(amtIn) : -int256(amtOut);
        amount1 = zeroForOne ? -int256(amtOut) : int256(amtIn);

        uint256 balBefore = IERC20Alg(tokenIn).balanceOf(address(this));
        IAlgebraSwapCallback(msg.sender).algebraSwapCallback(amount0, amount1, data);
        uint256 received = IERC20Alg(tokenIn).balanceOf(address(this)) - balBefore;
        require(received >= amtIn, "MockAlgebraPool: insufficient input");

        IERC20Alg(tokenOut).transfer(recipient, amtOut);
    }
}
