// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IERC20Min} from "./MockV2Pair.sol";

/// @notice A V2-shaped pair that answers honest reserves but pays a fixed `pay` set by
///         the test, whatever the caller asks for. The lying leg of a route: its quote is
///         measured from the reserves, its delivery is chosen by the attacker.
contract MockPayingPair {
    address public token0;
    address public token1;
    uint112 public reserve0;
    uint112 public reserve1;
    uint256 public pay;

    constructor(address a, address b) {
        (token0, token1) = a < b ? (a, b) : (b, a);
    }

    function setReserves(uint112 r0, uint112 r1) external { (reserve0, reserve1) = (r0, r1); }

    function setPay(uint256 p) external { pay = p; }

    function getReserves() external view returns (uint112, uint112, uint32) {
        return (reserve0, reserve1, uint32(block.timestamp));
    }

    function swap(uint256 amount0Out, uint256, address to, bytes calldata) external {
        if (pay != 0) IERC20Min(amount0Out > 0 ? token0 : token1).transfer(to, pay);
    }
}
