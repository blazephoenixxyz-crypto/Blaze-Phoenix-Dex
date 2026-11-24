// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {BlazePhoenixCore as BPC} from "../../src/BlazePhoenixCore.sol";

interface IERC20V3 {
    function transfer(address to, uint256 amt) external returns (bool);
    function balanceOf(address who) external view returns (uint256);
}

interface IV3SwapCallback {
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external;
}

/// @notice Exact output on the mocks' single range (UniswapV3Pool.swap with a negative amount):
///         the output the range can pay of `amtOut` (strictly inside it, as the swap stops at its
///         price limit) and the input it asks for that output, rounded up as the pool rounds an
///         exact-output input, its fee taken on top.
library MockExactOut {
    function inFor(uint256 amtOut, uint160 sqrtP, uint128 liq, uint24 fee, bool zeroForOne)
        internal pure returns (uint256 paid, uint256 amtIn)
    {
        uint256 L = uint256(liq);
        uint256 P = uint256(sqrtP);
        if (zeroForOne) {
            // token1 out: sqrtNew = sqrtP - out * Q96 / L.
            uint256 maxOut = BPC.mulDiv(L, P, BPC.Q96);
            require(maxOut > 1, "MockExactOut: empty range");
            paid = amtOut < maxOut ? amtOut : maxOut - 1;
            uint256 pn = P - BPC.mulDivUp(paid, BPC.Q96, L);
            require(pn != 0, "MockExactOut: range exhausted");
            amtIn = BPC.mulDivUp(BPC.mulDivUp(L, P - pn, pn), BPC.Q96, P);
        } else {
            // token0 out: 1 / sqrtNew = 1 / sqrtP - out / (L * Q96).
            uint256 maxOut = BPC.mulDiv(L, BPC.Q96, P);
            require(maxOut > 1, "MockExactOut: empty range");
            paid = amtOut < maxOut ? amtOut : maxOut - 1;
            uint256 lq = L * BPC.Q96;
            uint256 pn = BPC.mulDivUp(lq, P, lq - paid * P);
            amtIn = BPC.mulDivUp(L, pn - P, BPC.Q96);
        }
        amtIn = BPC.mulDivUp(amtIn, 1_000_000, 1_000_000 - fee);
    }
}

/// @notice Minimal Uniswap-V3-shaped pool mock: single-tick (no crossing),
///         configurable sqrtPriceX96 + liquidity, quotes via the SAME outV3
///         formula BlazePhoenixCore uses so quote == execution by
///         construction (never diverges) — enough surface to exercise the
///         Router's V3 leg dispatch + universal callback auth, and the
///         Solver's/Quoter's V3 quoting paths.
contract MockV3Pool {
    address public token0;
    address public token1;
    uint24  public fee;
    uint160 public sqrtPriceX96;
    uint128 public liquidity;

    /// @notice When true, swap() demands more input than the caller intended
    ///         to spend — used to exercise the Router's per-leg "pool cannot
    ///         demand more than maxAmt" guard.
    bool public overDemand;

    /// @notice When non-zero, swap() fills with THIS liquidity while the
    ///         `liquidity()` getter keeps reporting the state value: a
    ///         liquidity GAP at the current tick (the quoter reads 0) that
    ///         execution still fills by crossing into the next initialised
    ///         tick. Used to drive the "last hop cannot be quoted in-frame"
    ///         state (NM-002) on a pool that nonetheless delivers.
    uint128 public swapLiquidity;

    /// @notice When non-zero, an exact-output swap pays at most this much: the book on the far
    ///         side of the price is shorter than the amount asked, and the pool fills part.
    uint256 public exactOutCap;

    constructor(address _token0, address _token1, uint24 _fee) {
        (token0, token1) = _token0 < _token1 ? (_token0, _token1) : (_token1, _token0);
        fee = _fee;
    }

    function setState(uint160 _sqrtPriceX96, uint128 _liquidity) external {
        sqrtPriceX96 = _sqrtPriceX96;
        liquidity = _liquidity;
    }

    function setOverDemand(bool b) external { overDemand = b; }
    function setSwapLiquidity(uint128 l) external { swapLiquidity = l; }
    function setExactOutCap(uint256 c) external { exactOutCap = c; }

    /// @dev Only the first word (sqrtPriceX96) is read by BlazePhoenixCore's
    ///      raw-assembly getSqrtPriceX96 — matches the real slot0() layout.
    function slot0()
        external view
        returns (uint160, int24, uint16, uint16, uint16, uint8, bool)
    {
        return (sqrtPriceX96, 0, 0, 0, 0, 0, true);
    }

    function swap(
        address recipient, bool zeroForOne, int256 amountSpecified,
        uint160 sqrtPriceLimitX96, bytes calldata data
    ) external returns (int256 amount0, int256 amount1) {
        require(amountSpecified != 0, "MockV3Pool: zero amount");
        // The price limit, checked as UniswapV3Pool.swap checks it ('SPL'): on the side the swap
        // moves the price to, and strictly inside TickMath's domain. Before this, the mock ignored
        // the 4th argument, so a Router or Quoter that passed the limit of the other direction
        // (a pool that would refuse every swap on chain) stayed green here.
        require(
            zeroForOne
                ? sqrtPriceLimitX96 < sqrtPriceX96 && sqrtPriceLimitX96 > 4295128739
                : sqrtPriceLimitX96 > sqrtPriceX96
                    && sqrtPriceLimitX96 < 1461446703485210103287273052203988822378723970342,
            "SPL"
        );
        uint128 execL = swapLiquidity != 0 ? swapLiquidity : liquidity;
        uint256 amtIn;
        uint256 amtOut;
        if (amountSpecified > 0) {
            amtIn = uint256(amountSpecified);
            amtOut = BPC.outV3(amtIn, sqrtPriceX96, execL, fee, zeroForOne, 0);
        } else {
            // Exact output (a negative amount), as UniswapV3Pool.swap reads it: pays this much
            // of the output, or what the range holds of it, and asks the input for that.
            uint256 want = uint256(-amountSpecified);
            if (exactOutCap != 0 && exactOutCap < want) want = exactOutCap;
            (amtOut, amtIn) = MockExactOut.inFor(want, sqrtPriceX96, execL, fee, zeroForOne);
        }
        require(amtOut > 0, "MockV3Pool: zero out");

        address tokenIn  = zeroForOne ? token0 : token1;
        address tokenOut = zeroForOne ? token1 : token0;

        uint256 demand = overDemand ? amtIn + 1 : amtIn;

        amount0 = zeroForOne ? int256(demand) : -int256(amtOut);
        amount1 = zeroForOne ? -int256(amtOut) : int256(demand);

        // The output is paid BEFORE the callback, as UniswapV3Pool.swap pays it: the caller
        // holds it while it settles the input. Until 2026-11-11 the mock paid it after, so
        // nothing a caller measured inside the callback was what a real pool shows it.
        IERC20V3(tokenOut).transfer(recipient, amtOut);
        uint256 balBefore = IERC20V3(tokenIn).balanceOf(address(this));
        IV3SwapCallback(msg.sender).uniswapV3SwapCallback(amount0, amount1, data);
        uint256 received = IERC20V3(tokenIn).balanceOf(address(this)) - balBefore;
        require(received >= demand, "MockV3Pool: insufficient input");
    }
}
