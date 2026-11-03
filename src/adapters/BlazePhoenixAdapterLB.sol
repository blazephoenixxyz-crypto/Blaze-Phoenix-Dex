// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {IExtAdapter} from "./IExtAdapter.sol";
import {ExtAdapterBase} from "./ExtAdapterBase.sol";

/// Liquidity Book factory: LFJ v2.1 / v2.2 LBFactory, Pharaoh DLMMFactory (one registry form).
interface ILBFactory {
    /// (binStep, LBPair, createdByOwner, ignoredForRouting); the token order does not matter.
    function getLBPairInformation(address tokenA, address tokenB, uint256 binStep)
        external view returns (uint16, address, bool, bool);
}

/// Liquidity Book pair: LFJ v2.1 / v2.2 LBPair, Pharaoh DLMMPool.
interface ILBPair {
    function getTokenX() external view returns (address);
    function getTokenY() external view returns (address);
    function getReserves() external view returns (uint128 reserveX, uint128 reserveY);
    function getSwapOut(uint128 amountIn, bool swapForY)
        external view returns (uint128 amountInLeft, uint128 amountOut, uint128 fee);
    function swap(bool swapForY, address to) external returns (bytes32 amountsOut);
}

/// STUB (red): the ABI of the adapter with no body, so the tests compile and fail.
contract BlazePhoenixAdapterLB is ExtAdapterBase, IExtAdapter {
    ILBFactory public immutable FACTORY;

    constructor(address gate, address factory) ExtAdapterBase(gate) {
        FACTORY = ILBFactory(factory);
    }

    function resolve(address, address, uint24, bytes calldata)
        external view returns (address pair, bytes32 aux0, bytes32 aux1)
    {
        pair = address(FACTORY);
        (aux0, aux1) = (bytes32(0), bytes32(0));
    }

    function exec(address, bytes32, bytes32, bool, uint256, address) external returns (uint256 out) {}

    function quote(address, bytes32, bytes32, bool, uint256)
        external view returns (uint256 out, uint256 depth18) {}

    function quoteCall(address, bytes32, bytes32, bool, uint256) external view returns (uint256 out) {}
}
