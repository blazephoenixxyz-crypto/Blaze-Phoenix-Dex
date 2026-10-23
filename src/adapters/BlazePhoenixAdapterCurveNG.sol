// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {BlazePhoenixCore as BPC} from "../BlazePhoenixCore.sol";
import {IExtAdapter} from "./IExtAdapter.sol";
import {ExtAdapterBase} from "./ExtAdapterBase.sol";

/// Curve StableSwap-NG factory (curvefi/stableswap-ng CurveStableSwapFactoryNG.vy).
interface ICurveNGFactory {
    function get_implementation_address(address pool) external view returns (address);
    function get_coins(address pool) external view returns (address[] memory);
    function get_pool_asset_types(address pool) external view returns (uint8[] memory);
    function is_meta(address pool) external view returns (bool);
}

/// Curve StableSwap-NG plain pool (curvefi/stableswap-ng CurveStableSwapNG.vy).
interface ICurveNGPool {
    function exchange_received(int128 i, int128 j, uint256 dx, uint256 minDy, address receiver)
        external returns (uint256);
    function get_dy(int128 i, int128 j, uint256 dx) external view returns (uint256);
    function get_virtual_price() external view returns (uint256);
}

/// @title  BlazePhoenixAdapterCurveNG — Gate adapter for Curve StableSwap-NG plain pools.
/// @notice Custody PUSH: the input is transferred to the pool and `exchange_received` swaps what
///         arrived, paying `recipient` directly. The adapter never grants an allowance.
///         IDENTITY: the pool is the factory's (`get_implementation_address != 0`), its coins
///         and asset types are the factory's record, asked once at `resolve`.
///         REFUSED at resolve: a metapool (its implementation is not the one read here), any coin
///         of asset type 1 (rate oracle, which may be an EOA) or 2 (rebasing, where
///         `exchange_received` is disabled), and any coin that is the raw-ETH sentinel.
///         aux0 = index of token0 | index of token1 << 8. aux1 unused.
contract BlazePhoenixAdapterCurveNG is ExtAdapterBase, IExtAdapter {
    address internal constant ETH_SENTINEL = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    ICurveNGFactory public immutable FACTORY;

    constructor(address gate, address factory) ExtAdapterBase(gate) {
        if (factory == address(0)) revert AdapterE(0);
        FACTORY = ICurveNGFactory(factory);
    }

    function resolve(address t0, address t1, uint24, bytes calldata hint)
        external view returns (address pool, bytes32 aux0, bytes32 aux1)
    {
        if (hint.length != 32) revert AdapterE(8);
        pool = abi.decode(hint, (address));
        if (FACTORY.get_implementation_address(pool) == address(0)) revert AdapterE(2);
        if (FACTORY.is_meta(pool)) revert AdapterE(4);
        address[] memory coins = FACTORY.get_coins(pool);
        uint8[] memory types = FACTORY.get_pool_asset_types(pool);
        if (types.length != coins.length) revert AdapterE(4);
        for (uint256 k; k < coins.length; ) {
            if (types[k] == 1 || types[k] == 2) revert AdapterE(4);
            if (coins[k] == ETH_SENTINEL) revert AdapterE(4);
            unchecked { ++k; }
        }
        (uint256 i0, uint256 i1) = _indices(coins, t0, t1);
        aux0 = bytes32(i0 | (i1 << 8));
        aux1 = bytes32(0);
    }

    function exec(address pool, bytes32 aux0, bytes32, bool zeroForOne, uint256 amtIn, address recipient)
        external returns (uint256 out)
    {
        address tIn = _wrapperTokenIn(zeroForOne);
        (int128 i, int128 j) = _ij(aux0, zeroForOne);
        BPC.safeTransfer(tIn, pool, amtIn);
        // min_dy = 1: the floors are the Router's, never a quote.
        out = ICurveNGPool(pool).exchange_received(i, j, amtIn, 1, recipient);
    }

    function quote(address pool, bytes32 aux0, bytes32, bool zeroForOne, uint256 amtIn)
        external view returns (uint256 out, uint256 depth18)
    {
        bool live;
        (out, live) = _quote(pool, aux0, zeroForOne, amtIn);
        // DEPTH BY THE VENUE'S FORM (index): the pool's own balances of the pair, the shorter side
        // in 18 decimals; asked only when the pool is not mid-operation, the price's own probe.
        if (live) {
            (int128 i, int128 j) = _ij(aux0, true);
            depth18 = _indexedDepth18(pool, uint256(uint128(i)), uint256(uint128(j)));
        }
    }

    /// Same body as `quote` (M4): the SDK's number and the on-chain number cannot differ.
    function quoteCall(address pool, bytes32 aux0, bytes32, bool zeroForOne, uint256 amtIn)
        external view returns (uint256 out)
    {
        (out, ) = _quote(pool, aux0, zeroForOne, amtIn);
    }

    /// Ask the pool, and only while it is not in the middle of an operation: `get_virtual_price`
    /// is `nonreentrant('lock')` on NG (read-only reentrancy guard), `get_dy` is not.
    function _quote(address pool, bytes32 aux0, bool zeroForOne, uint256 amtIn)
        private view returns (uint256 out, bool live)
    {
        try ICurveNGPool(pool).get_virtual_price() returns (uint256) {} catch { return (0, false); }
        live = true;
        (int128 i, int128 j) = _ij(aux0, zeroForOne);
        try ICurveNGPool(pool).get_dy(i, j, amtIn) returns (uint256 dy) { out = dy; } catch {}
    }

    function _ij(bytes32 aux0, bool zeroForOne) private pure returns (int128 i, int128 j) {
        uint256 v = uint256(aux0);
        int128 a = int128(uint128(v & 0xff));
        int128 b = int128(uint128((v >> 8) & 0xff));
        (i, j) = zeroForOne ? (a, b) : (b, a);
    }
}
