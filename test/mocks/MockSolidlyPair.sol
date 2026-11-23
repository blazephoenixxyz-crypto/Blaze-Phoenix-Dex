// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {BlazePhoenixCore as BPC} from "../../src/BlazePhoenixCore.sol";

interface IERC20Solidly {
    function transfer(address to, uint256 amt) external returns (bool);
    function balanceOf(address who) external view returns (uint256);
}

/// @notice Minimal Solidly/Aerodrome-shaped pair mock: configurable
///         reserves + fee + stable flag, exposes getAmountOut(amountIn,
///         tokenIn) (the primary quote path BlazePhoenixCore prefers —
///         "ask the pool, never replicate") and a permissive swap().
contract MockSolidlyPair {
    address public token0;
    address public token1;
    uint112 public reserve0;
    uint112 public reserve1;
    bool    public stable;
    uint256 public feeBps = 30;

    /// @notice When true, getAmountOut() returns 0 to force callers onto the
    ///         Core's replicated-curve fallback path.
    bool public hideGetAmountOut;

    constructor(address _token0, address _token1, bool _stable) {
        (token0, token1) = _token0 < _token1 ? (_token0, _token1) : (_token1, _token0);
        stable = _stable;
    }

    function setReserves(uint112 r0, uint112 r1) external { reserve0 = r0; reserve1 = r1; }
    function setFeeBps(uint256 f) external { feeBps = f; }
    function setHideGetAmountOut(bool b) external { hideGetAmountOut = b; }

    function getReserves() external view returns (uint112, uint112, uint32) {
        return (reserve0, reserve1, uint32(block.timestamp));
    }

    function getAmountOut(uint256 amountIn, address tokenIn) public view virtual returns (uint256) {
        if (hideGetAmountOut) return 0;
        (uint256 rIn, uint256 rOut) = tokenIn == token0
            ? (uint256(reserve0), uint256(reserve1))
            : (uint256(reserve1), uint256(reserve0));
        if (!stable) return BPC.outSolidly(amountIn, rIn, rOut, feeBps, false);
        // A Solidly pair scales each side of the stable curve by its token's decimals, so a 6/18
        // pair quotes on comparable reserves; the equal-decimals formula would misprice it.
        address tokenOut = tokenIn == token0 ? token1 : token0;
        return BPC.outSolidlyStable(amountIn, rIn, rOut, feeBps, _decimals(tokenIn), _decimals(tokenOut));
    }

    /// @notice The token's decimals, 18 when it does not answer one word (as Core reads them).
    function _decimals(address t) internal view returns (uint8) {
        (bool ok, bytes memory r) = t.staticcall(abi.encodeWithSignature("decimals()"));
        return ok && r.length == 32 ? uint8(abi.decode(r, (uint256))) : 18;
    }

    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata) external {
        if (amount0Out > 0) IERC20Solidly(token0).transfer(to, amount0Out);
        if (amount1Out > 0) IERC20Solidly(token1).transfer(to, amount1Out);
        reserve0 = uint112(IERC20Solidly(token0).balanceOf(address(this)));
        reserve1 = uint112(IERC20Solidly(token1).balanceOf(address(this)));
    }
}
