// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IERC20Min {
    function transfer(address to, uint256 amt) external returns (bool);
    function balanceOf(address who) external view returns (uint256);
}

/// @notice Minimal Uniswap V2 pair mock: configurable reserves, permissive
///         swap() that pays out whatever the caller requests from its own
///         token balance (fund it via mint before swapping) and re-syncs
///         reserves from real balances afterward — mirrors how a real pair's
///         _update() would observe a fee-on-transfer input.
contract MockV2Pair {
    address public token0;
    address public token1;
    uint112 public reserve0;
    uint112 public reserve1;

    constructor(address _token0, address _token1) {
        (token0, token1) = _token0 < _token1 ? (_token0, _token1) : (_token1, _token0);
    }

    function setReserves(uint112 r0, uint112 r1) external {
        reserve0 = r0;
        reserve1 = r1;
    }

    function getReserves() external view returns (uint112, uint112, uint32) {
        return (reserve0, reserve1, uint32(block.timestamp));
    }

    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata) external {
        if (amount0Out > 0) IERC20Min(token0).transfer(to, amount0Out);
        if (amount1Out > 0) IERC20Min(token1).transfer(to, amount1Out);
        reserve0 = uint112(IERC20Min(token0).balanceOf(address(this)));
        reserve1 = uint112(IERC20Min(token1).balanceOf(address(this)));
    }
}
