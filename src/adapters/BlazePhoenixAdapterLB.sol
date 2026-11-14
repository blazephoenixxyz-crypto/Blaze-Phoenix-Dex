// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {BlazePhoenixCore as BPC} from "../BlazePhoenixCore.sol";
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
    /// What the LPs own: the pair's books less its protocol fees.
    function getReserves() external view returns (uint128 reserveX, uint128 reserveY);
    /// The swap's own loop, stopped where the swap would revert: amountInLeft != 0 is the
    /// swap's OutOfLiquidity in the same state.
    function getSwapOut(uint128 amountIn, bool swapForY)
        external view returns (uint128 amountInLeft, uint128 amountOut, uint128 fee);
    /// PUSH: trades what arrived above the books and pays `to`; X in the low 128 bits, Y high.
    function swap(bool swapForY, address to) external returns (bytes32 amountsOut);
}

/// @title  BlazePhoenixAdapterLB - Gate adapter for Liquidity Book pairs (LFJ v2.1 and v2.2,
///         Pharaoh DLMM): one contract, one instance (and one Gate family) per factory.
/// @notice Custody PUSH: the input is transferred to the pair and `swap` trades what arrived
///         above its books, paying `recipient` directly. The adapter never grants an allowance.
///         IDENTITY: the pair is the factory's record of (t0, t1, binStep), asked once at
///         `resolve`; the hint names the bin step, never the pair.
///         HOOKS (v2.2 / DLMM; v2.1 has none): of the flags only BEFORE_SWAP and AFTER_SWAP run
///         inside a swap. AFTER_SWAP runs after the pair has released its reentrancy guard,
///         inside our exec, and is refused; BEFORE_SWAP runs inside the guard and returns no
///         amounts, and is admitted only with the hook the curator saw at create. Checked on every exec, quote and quoteCall against the pair's
///         hooks of now (the factory's hooks manager changes them at any time).
///         aux0 = X0 (token0 is tokenX) | HOOKED (the pair answered getLBHooksParameters).
///         aux1 = the BEFORE_SWAP hook pinned at create (0 when none).
contract BlazePhoenixAdapterLB is ExtAdapterBase, IExtAdapter {
    uint256 internal constant X0 = 1;
    uint256 internal constant HOOKED = 2;
    /// Hooks.sol (LFJ v2.2 = DLMM): the two flags that run in swap; the hook is the low 160 bits.
    uint256 internal constant BEFORE_SWAP = 1 << 160;
    uint256 internal constant AFTER_SWAP = 1 << 161;

    ILBFactory public immutable FACTORY;

    constructor(address gate, address factory)
        ExtAdapterBase(gate, [bytes32(0), bytes32(0), bytes32(0)])
    {
        if (factory == address(0)) revert AdapterE(0);
        FACTORY = ILBFactory(factory);
    }

    function resolve(address t0, address t1, uint24, bytes calldata hint)
        external view returns (address pair, bytes32 aux0, bytes32 aux1)
    {
        if (hint.length != 32) revert AdapterE(8);
        uint256 binStep = abi.decode(hint, (uint256));
        if (binStep == 0 || binStep > type(uint16).max) revert AdapterE(8);
        (, pair, , ) = FACTORY.getLBPairInformation(t0, t1, binStep);
        if (pair == address(0)) revert AdapterE(2);
        address x = ILBPair(pair).getTokenX();
        if (x != t0 && x != t1) revert AdapterE(3);
        (bool hooked, uint256 hp) = _hooksParameters(pair);
        if ((hp & AFTER_SWAP) != 0) revert AdapterE(7);
        if ((hp & BEFORE_SWAP) != 0) aux1 = bytes32(uint256(uint160(hp)));
        aux0 = bytes32((x == t0 ? X0 : 0) | (hooked ? HOOKED : 0));
    }

    function exec(address pair, bytes32 aux0, bytes32 aux1, bool zeroForOne, uint256 amtIn, address recipient)
        external returns (uint256 out)
    {
        address tIn = _wrapperTokenIn(zeroForOne);
        if (!_hooksOk(pair, aux0, aux1)) revert AdapterE(7);
        BPC.safeTransfer(tIn, pair, amtIn);
        bool swapForY = _swapForY(aux0, zeroForOne);
        // No minimum at the venue: the floors are the Router's, never a quote.
        bytes32 amounts = ILBPair(pair).swap(swapForY, recipient);
        // Advisory: the wrapper measures the output at the recipient.
        out = swapForY ? uint256(amounts) >> 128 : uint256(uint128(uint256(amounts)));
    }

    function quote(address pair, bytes32 aux0, bytes32 aux1, bool zeroForOne, uint256 amtIn)
        external view returns (uint256 out, uint256 depth18)
    {
        if (!_hooksOk(pair, aux0, aux1)) return (0, 0);
        out = _out(pair, aux0, zeroForOne, amtIn);
        // DEPTH BY THE VENUE'S FORM (reserves): what the pair reports its LPs own (its books less
        // the protocol's fees, never above what it holds), the shorter side in 18 decimals.
        // Never reads amtIn.
        (uint128 rx, uint128 ry) = ILBPair(pair).getReserves();
        depth18 = _depth18(ILBPair(pair).getTokenX(), rx, ILBPair(pair).getTokenY(), ry);
    }

    /// Same body as `quote` (M4): the SDK's number and the on-chain number cannot differ.
    function quoteCall(address pair, bytes32 aux0, bytes32 aux1, bool zeroForOne, uint256 amtIn)
        external view returns (uint256 out)
    {
        if (_hooksOk(pair, aux0, aux1)) out = _out(pair, aux0, zeroForOne, amtIn);
    }

    /// The venue's own answer, taken only when it is the whole answer: an amtIn the pair cannot
    /// be asked (above uint128) is not truncated, input left over is the swap's OutOfLiquidity,
    /// and a read that fails (BinHelper's per-bin limit, gas) is 0.
    function _out(address pair, bytes32 aux0, bool zeroForOne, uint256 amtIn) private view returns (uint256 out) {
        if (amtIn > type(uint128).max) return 0;
        try ILBPair(pair).getSwapOut(uint128(amtIn), _swapForY(aux0, zeroForOne)) returns (uint128 left, uint128 o, uint128) {
            if (left == 0) out = o;
        } catch {}
    }

    /// zeroForOne sells token0, which is tokenX exactly when X0 is set: X is sold (swapForY)
    /// exactly when the two agree.
    function _swapForY(bytes32 aux0, bool zeroForOne) private pure returns (bool) {
        return ((uint256(aux0) & X0) != 0) == zeroForOne;
    }

    /// The pair's hooks of now, by shape: a pair without hooks (v2.1) passes; a HOOKED pair whose
    /// hooks cannot be read does not (absent is not zero); AFTER_SWAP never; BEFORE_SWAP only
    /// with the hook pinned at create. The other flags never run in a swap.
    function _hooksOk(address pair, bytes32 aux0, bytes32 aux1) private view returns (bool) {
        if ((uint256(aux0) & HOOKED) == 0) return true;
        (bool ok, uint256 hp) = _hooksParameters(pair);
        if (!ok) return false;
        if ((hp & AFTER_SWAP) != 0) return false;
        if ((hp & BEFORE_SWAP) != 0 && uint160(hp) != uint160(uint256(aux1))) return false;
        return true;
    }

    /// getLBHooksParameters() (0x781a8915) by staticcall: a v2.1 pair has no such function, so a
    /// failure, or an answer shorter than a word, is reported, never read as zero hooks.
    function _hooksParameters(address pair) private view returns (bool ok, uint256 hp) {
        assembly ("memory-safe") {
            mstore(0x00, 0x781a891500000000000000000000000000000000000000000000000000000000)
            ok := staticcall(gas(), pair, 0x00, 4, 0x00, 0x20)
            if ok {
                switch lt(returndatasize(), 32)
                case 0 { hp := mload(0x00) }
                default { ok := 0 }
            }
        }
    }
}
