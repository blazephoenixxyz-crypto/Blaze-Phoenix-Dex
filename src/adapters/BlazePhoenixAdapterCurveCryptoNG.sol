// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {BlazePhoenixCore as BPC} from "../BlazePhoenixCore.sol";
import {IExtAdapter, IExtAdapterQuoteCall} from "./IExtAdapter.sol";
import {ExtAdapterBase} from "./ExtAdapterBase.sol";

/// Curve crypto NG factories: curvefi/twocrypto-ng TwocryptoFactory.vy (get_coins L357, address[2])
/// and curvefi/tricrypto-ng CurveTricryptoFactory.vy / CurveL2TricryptoFactory.vy (get_coins,
/// address[3]). Both write `pool_data[pool].coins` only in `deploy_pool`, and both treat
/// `coins[0] == empty(address)` as "unknown pool" (TwocryptoFactory.vy L217).
interface ICurveCryptoNGFactory {
    function get_coins(address pool) external view returns (address[2] memory);
}

/// Curve crypto NG pool: Twocrypto.vy (v2.0.0, v2.1.0, FXSwap v2.1.0d) and
/// CurveTricryptoOptimized.vy (v2.0.0, native disabled). Indices are uint256.
interface ICurveCryptoNGPool {
    function exchange_received(uint256 i, uint256 j, uint256 dx, uint256 minDy, address receiver)
        external returns (uint256);
    function get_dy(uint256 i, uint256 j, uint256 dx) external view returns (uint256);
    function get_virtual_price() external view returns (uint256);
}

/// The native-enabled tricrypto (CurveTricryptoOptimizedWETH.vy) has this getter and no
/// `exchange_received`; the other implementations have neither it nor a fallback.
interface ICurveTricryptoWETH {
    function WETH20() external view returns (address);
}

/// @title  BlazePhoenixAdapterCurveCryptoNG — Gate adapter for Curve Twocrypto-NG (FXSwap included)
///         and Tricrypto-NG pools.
/// @notice Custody PUSH, as the StableSwap-NG adapter: the input is transferred to the pool and
///         `exchange_received` swaps what arrived (balance minus stored balance, asserted >= dx),
///         paying `recipient` directly. The adapter never grants an allowance.
///         IDENTITY: the pool is the factory's: `FACTORY.get_coins(pool)` is the factory's own
///         record, written only when it deployed the pool; an unknown pool reads all zeros. The
///         record is 2 or 3 words (two- or three-coin factory), read once at `resolve`.
///         REFUSED at resolve: a native-enabled tricrypto (it has `WETH20()` and no
///         `exchange_received`; the call would fail at every exec).
///         aux0 = index of token0 | index of token1 << 8. aux1 unused.
contract BlazePhoenixAdapterCurveCryptoNG is ExtAdapterBase, IExtAdapter, IExtAdapterQuoteCall {
    address public immutable FACTORY;

    constructor(address gate, address factory) ExtAdapterBase(gate) {
        if (factory == address(0)) revert AdapterE(0);
        FACTORY = factory;
    }

    function resolve(address t0, address t1, uint24, bytes calldata hint)
        external view returns (address pool, bytes32 aux0, bytes32 aux1)
    {
        if (hint.length != 32) revert AdapterE(8);
        pool = abi.decode(hint, (address));
        address[] memory coins = _factoryCoins(pool);
        try ICurveTricryptoWETH(pool).WETH20() returns (address) { revert AdapterE(4); } catch {}
        (uint256 i0, uint256 i1) = _indices(coins, t0, t1);
        aux0 = bytes32(i0 | (i1 << 8));
        aux1 = bytes32(0);
    }

    function exec(address pool, bytes32 aux0, bytes32, bool zeroForOne, uint256 amtIn, address recipient)
        external returns (uint256 out)
    {
        address tIn = _wrapperTokenIn(zeroForOne);
        (uint256 i, uint256 j) = _ij(aux0, zeroForOne);
        BPC.safeTransfer(tIn, pool, amtIn);
        // min_dy = 1: the floors are the Router's, never a quote.
        out = ICurveCryptoNGPool(pool).exchange_received(i, j, amtIn, 1, recipient);
    }

    function quote(address pool, bytes32 aux0, bytes32, bool zeroForOne, uint256 amtIn)
        external view returns (uint256 out, uint256 depth18)
    {
        out = _quote(pool, aux0, zeroForOne, amtIn);
        depth18 = 0; // the Core's registryDepth18 is the one depth producer; kind 9 has no arm yet
    }

    /// Same body as `quote` (M4): the SDK's number and the on-chain number cannot differ.
    function quoteCall(address wrapper, bool zeroForOne, uint256 amtIn) external view returns (uint256 out) {
        (address pool, bytes32 aux0, , , ) = _legOf(wrapper, zeroForOne);
        out = _quote(pool, aux0, zeroForOne, amtIn);
    }

    /// The factory's record of `pool`: exactly 2 or 3 words (address[N_COINS]), the first one
    /// non-zero. Anything else is not this factory's pool (or not a crypto NG factory).
    function _factoryCoins(address pool) private view returns (address[] memory coins) {
        (bool ok, bytes memory r) =
            FACTORY.staticcall(abi.encodeWithSelector(ICurveCryptoNGFactory.get_coins.selector, pool));
        if (!ok || (r.length != 64 && r.length != 96)) revert AdapterE(2);
        uint256 n = r.length / 32;
        coins = new address[](n);
        for (uint256 k; k < n; ) {
            uint256 word;
            assembly ("memory-safe") { word := mload(add(r, mul(add(k, 1), 32))) }
            if (word >> 160 != 0) revert AdapterE(2);
            coins[k] = address(uint160(word));
            unchecked { ++k; }
        }
        if (coins[0] == address(0)) revert AdapterE(2);
    }

    /// Ask the pool, and only while it is not in the middle of an operation: `get_virtual_price`
    /// is nonreentrant on both implementations (read-only reentrancy guard), `get_dy` is not.
    function _quote(address pool, bytes32 aux0, bool zeroForOne, uint256 amtIn) private view returns (uint256 out) {
        try ICurveCryptoNGPool(pool).get_virtual_price() returns (uint256) {} catch { return 0; }
        (uint256 i, uint256 j) = _ij(aux0, zeroForOne);
        try ICurveCryptoNGPool(pool).get_dy(i, j, amtIn) returns (uint256 dy) { out = dy; } catch {}
    }

    function _ij(bytes32 aux0, bool zeroForOne) private pure returns (uint256 i, uint256 j) {
        uint256 v = uint256(aux0);
        uint256 a = v & 0xff;
        uint256 b = (v >> 8) & 0xff;
        (i, j) = zeroForOne ? (a, b) : (b, a);
    }
}
