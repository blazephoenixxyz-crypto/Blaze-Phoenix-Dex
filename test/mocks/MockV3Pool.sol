// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BlazePhoenixCore as BPC} from "../../src/BlazePhoenixCore.sol";

interface IERC20V3 {
    function transfer(address to, uint256 amt) external returns (bool);
    function balanceOf(address who) external view returns (uint256);
}

interface IV3SwapCallback {
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external;
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

    constructor(address _token0, address _token1, uint24 _fee) {
        (token0, token1) = _token0 < _token1 ? (_token0, _token1) : (_token1, _token0);
        fee = _fee;
    }

    function setState(uint160 _sqrtPriceX96, uint128 _liquidity) external {
        sqrtPriceX96 = _sqrtPriceX96;
        liquidity = _liquidity;
    }

    function setOverDemand(bool b) external { overDemand = b; }

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
        uint160 /*sqrtPriceLimitX96*/, bytes calldata data
    ) external returns (int256 amount0, int256 amount1) {
        require(amountSpecified > 0, "MockV3Pool: exact-out unsupported");
        uint256 amtIn = uint256(amountSpecified);
        uint256 amtOut = BPC.outV3(amtIn, sqrtPriceX96, liquidity, fee, zeroForOne);
        require(amtOut > 0, "MockV3Pool: zero out");

        address tokenIn  = zeroForOne ? token0 : token1;
        address tokenOut = zeroForOne ? token1 : token0;

        uint256 demand = overDemand ? amtIn + 1 : amtIn;

        amount0 = zeroForOne ? int256(demand) : -int256(amtOut);
        amount1 = zeroForOne ? -int256(amtOut) : int256(demand);

        uint256 balBefore = IERC20V3(tokenIn).balanceOf(address(this));
        IV3SwapCallback(msg.sender).uniswapV3SwapCallback(amount0, amount1, data);
        uint256 received = IERC20V3(tokenIn).balanceOf(address(this)) - balBefore;
        require(received >= demand, "MockV3Pool: insufficient input");

        IERC20V3(tokenOut).transfer(recipient, amtOut);
    }
}
