// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {MockV3Pool} from "./MockV3Pool.sol";

/// @notice MockV3Pool with a tick book: `tickSpacing()`, `tickBitmap(int16)` and
///         `ticks(int24)` (liquidityNet in word 1, as on Uniswap V3), so the read-only
///         walk of a V3-shaped book (Core.v4WalkOut with a zero poolId) has initialized ticks to cross.
///         The price stays at sqrtPriceX96 = 2^96 (tick 0), which is what the parent's
///         slot0() reports. Swaps still settle single-tick through the parent: use the book
///         for planning tests, and a book with no initialized ticks where a test executes.
contract MockV3BookPool is MockV3Pool {
    int24 public tickSpacing;
    mapping(int16 => uint256) public tickBitmap;
    mapping(int24 => int128) internal net;

    constructor(address a, address b, uint24 f, int24 ts) MockV3Pool(a, b, f) {
        tickSpacing = ts;
    }

    /// @dev Initialises tick `t` (a multiple of the spacing) with liquidityNet `n`.
    function setTick(int24 t, int128 n) external {
        require(t % tickSpacing == 0, "spacing");
        int24 c = t / tickSpacing;
        tickBitmap[int16(c >> 8)] |= uint256(1) << (uint256(uint24(c)) & 0xff);
        net[t] = n;
    }

    function ticks(int24 t)
        external view
        returns (uint128, int128, uint256, uint256, int56, uint160, uint32, bool)
    {
        return (1, net[t], 0, 0, 0, 0, 0, true);
    }
}
