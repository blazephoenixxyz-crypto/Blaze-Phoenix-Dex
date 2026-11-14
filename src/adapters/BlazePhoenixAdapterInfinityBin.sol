// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {BlazePhoenixCore as BPC} from "../BlazePhoenixCore.sol";
import {IExtAdapter} from "./IExtAdapter.sol";
import {ExtAdapterBase} from "./ExtAdapterBase.sol";
import {IInfinityVault, ILockCallback, IInfinityCLPoolManager} from "./BlazePhoenixAdapterInfinityCL.sol";

/// PancakeSwap Infinity Bin pool manager (infinity-core src/pool-bin/interfaces/IBinPoolManager.sol;
/// poolIdToPoolKey and vault from src/interfaces/IPoolManager.sol). The PoolKey is the one of
/// src/types/PoolKey.sol, the same for both managers (declared with the CL manager's interface);
/// the BalanceDelta is packed as the CL manager's.
interface IInfinityBinPoolManager {
    function swap(IInfinityCLPoolManager.PoolKey memory key, bool swapForY, int128 amountSpecified, bytes calldata hookData)
        external returns (int256 delta);
    function poolIdToPoolKey(bytes32 id) external view returns (
        address currency0, address currency1, address hooks, address poolManager, uint24 fee, bytes32 parameters
    );
    function getSlot0(bytes32 id) external view returns (uint24 activeId, uint24 protocolFee, uint24 lpFee);
    function getBin(bytes32 id, uint24 binId)
        external view returns (uint128 binReserveX, uint128 binReserveY, uint256 binLiquidity, uint256 totalShares);
    function vault() external view returns (address);
}

/// @title  BlazePhoenixAdapterInfinityBin — Gate adapter for one PancakeSwap Infinity Bin pool manager.
/// @notice BlazePhoenixAdapterInfinityCL on the Bin manager of the same Vault: the same custody
///         (SETTLE: lock, swap exact-in, sync, transfer exactly the input, settle, the Vault pays
///         `recipient`; no allowance), the same identity (hint = PoolId, read back from the
///         manager's own record), the same hooks rule (afterSwap and the returns-delta bits refused,
///         dynamic fee refused, a hooks contract only with one of three codehashes pinned at
///         construction, checked again at every `exec` and `quoteCall`) and the same quote
///         (`quote` answers out = 0; `quoteCall` swaps inside a lock that always reverts, and only
///         this adapter's own QuoteOut is a price). ERC-20 pairs only.
///         SWAP: no price limit; swapForY = zeroForOne (currency0 is the Bin's X). The venue takes
///         the input as an int128: an amtIn above its range is refused (AdapterE(9)), never
///         truncated. A Bin exact-in spends the whole input or reverts BinPool__OutOfLiquidity
///         (infinity-core BinPool.sol:188-199), so no fill can be partial.
///         DEPTH: the shorter side of the active bin's reserves (getBin at getSlot0's activeId),
///         through ExtAdapterBase._depth18; none while the Vault has a locker.
///         venuePool = the Vault; aux0 = PoolId; aux1 unused.
contract BlazePhoenixAdapterInfinityBin is ExtAdapterBase, IExtAdapter, ILockCallback {
    error QuoteOut(uint256 out);
    error QuoteSwapFailed(bytes reason);

    /// Bits of the hooks bitmap (the low 16 bits of PoolKey.parameters), infinity-core
    /// src/pool-bin/interfaces/IBinHooks.sol:17,20,21 (the CL manager's offsets).
    uint8 internal constant HOOKS_AFTER_SWAP_OFFSET = 7;
    uint8 internal constant HOOKS_BEFORE_SWAP_RETURNS_DELTA_OFFSET = 10;
    uint8 internal constant HOOKS_AFTER_SWAP_RETURNS_DELTA_OFFSET = 11;
    uint256 internal constant REFUSED_HOOK_BITS =
        (1 << HOOKS_AFTER_SWAP_OFFSET)
        | (1 << HOOKS_BEFORE_SWAP_RETURNS_DELTA_OFFSET)
        | (1 << HOOKS_AFTER_SWAP_RETURNS_DELTA_OFFSET);
    /// src/libraries/LPFeeLibrary.sol:19.
    uint24 internal constant DYNAMIC_FEE_FLAG = 0x800000;

    IInfinityVault public immutable VAULT;
    IInfinityBinPoolManager public immutable BIN_MANAGER;

    /// `refHooks`: deployed hooks whose code may run under this adapter, pinned by codehash into
    /// the base's three slots (ExtAdapterBase._requireHookPinned); a slot left at address(0) pins nothing.
    constructor(address gate, address binManager, address[3] memory refHooks)
        ExtAdapterBase(gate, [_pin(refHooks[0]), _pin(refHooks[1]), _pin(refHooks[2])])
    {
        if (binManager == address(0)) revert AdapterE(0);
        BIN_MANAGER = IInfinityBinPoolManager(binManager);
        VAULT = IInfinityVault(IInfinityBinPoolManager(binManager).vault());
    }

    function _pin(address h) private view returns (bytes32 c) {
        if (h == address(0)) return bytes32(0);
        if (h.code.length == 0) revert AdapterE(0);
        c = h.codehash;
    }

    function resolve(address t0, address t1, uint24, bytes calldata hint)
        external view returns (address venuePool, bytes32 aux0, bytes32 aux1)
    {
        if (hint.length != 32) revert AdapterE(8);
        bytes32 id = bytes32(hint);
        IInfinityCLPoolManager.PoolKey memory key = _key(id);
        if (key.poolManager != address(BIN_MANAGER)) revert AdapterE(2);
        if (key.currency0 != t0 || key.currency1 != t1) revert AdapterE(3);
        if (uint256(key.parameters) & REFUSED_HOOK_BITS != 0) revert AdapterE(7);
        if (key.fee & DYNAMIC_FEE_FLAG != 0) revert AdapterE(7);
        _requireHookPinned(key.hooks); // one of the pinned codehashes, or none
        (venuePool, aux0, aux1) = (address(VAULT), id, bytes32(0));
    }

    /// The manager's record of the id: a key written once, at initialize, so it cannot change.
    function _key(bytes32 id) private view returns (IInfinityCLPoolManager.PoolKey memory k) {
        (k.currency0, k.currency1, k.hooks, k.poolManager, k.fee, k.parameters) = BIN_MANAGER.poolIdToPoolKey(id);
    }

    function exec(address, bytes32 aux0, bytes32, bool zeroForOne, uint256 amtIn, address recipient)
        external returns (uint256)
    {
        IInfinityCLPoolManager.PoolKey memory key = _key(aux0);
        (address tIn, address tOut) = _wrapperTokens(zeroForOne);
        _requireHookPinned(key.hooks); // again at exec, like the Router's isHookLive
        _inExec = true;
        VAULT.lock(abi.encode(false, key, zeroForOne, amtIn, tIn, tOut, recipient));
        _inExec = false;
        return 0; // advisory and never read: the wrapper measures the recipient
    }

    /// The Vault's callback. Only the Vault, and only inside this adapter's own `exec` or
    /// `quoteCall`: the deltas of a lock belong to whoever runs inside it.
    function lockAcquired(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(VAULT) || !_inExec) revert AdapterE(6);
        (bool quoting, IInfinityCLPoolManager.PoolKey memory key, bool z, uint256 amtIn, address tIn, address tOut, address recipient)
            = abi.decode(data, (bool, IInfinityCLPoolManager.PoolKey, bool, uint256, address, address, address));
        if (amtIn > uint128(type(int128).max)) revert AdapterE(9);
        int128 spec = -int128(int256(amtIn));
        if (quoting) {
            try BIN_MANAGER.swap(key, z, spec, "") returns (int256 d) {
                (, uint256 out) = _amounts(d, z);
                revert QuoteOut(out);
            } catch (bytes memory r) {
                revert QuoteSwapFailed(r);
            }
        }
        (, uint256 got) = _amounts(BIN_MANAGER.swap(key, z, spec, ""), z);
        VAULT.sync(tIn);
        BPC.safeTransfer(tIn, address(VAULT), amtIn);
        VAULT.settle();
        VAULT.take(tOut, recipient, got);
        return "";
    }

    /// BalanceDelta: amount0 in the high 128 bits, amount1 in the low 128; negative is owed to
    /// the Vault. Returns the input consumed and the output owed, for the direction `z`.
    function _amounts(int256 d, bool z) private pure returns (uint256 used, uint256 out) {
        (int256 a0, int256 a1) = (d >> 128, int256(int128(d)));
        (int256 i, int256 o) = z ? (a0, a1) : (a1, a0);
        (used, out) = (uint256(-i), uint256(o));
    }

    /// No depth while the Vault has a locker (a read mid-lock may be a flash loan's: see the CL
    /// adapter). Otherwise the bin the price sits in: the one bin a swap of any size starts in.
    function quote(address, bytes32 aux0, bytes32, bool, uint256)
        external view returns (uint256 out, uint256 depth18)
    {
        (address a, address b) = _pairOf(msg.sender, true);
        if (VAULT.getLocker() != address(0)) return (0, 0);
        (uint24 active, , ) = BIN_MANAGER.getSlot0(aux0);
        (uint128 rx, uint128 ry, , ) = BIN_MANAGER.getBin(aux0, active);
        (out, depth18) = (0, _depth18(a, rx, b, ry));
    }

    /// eth_call by the Quoter: the swap runs inside a lock that always reverts, so nothing
    /// persists; only this adapter's own QuoteOut is read as the output.
    function quoteCall(address, bytes32 aux0, bytes32, bool zeroForOne, uint256 amtIn) external returns (uint256 out) {
        IInfinityCLPoolManager.PoolKey memory key = _key(aux0);
        _wrapperTokens(zeroForOne); // the caller is a wrapper of the Gate, as in exec
        _requireHookPinned(key.hooks); // and at quoteCall: what exec refuses has no quote
        _inExec = true;
        try VAULT.lock(abi.encode(true, key, zeroForOne, amtIn, address(0), address(0), address(0))) {}
        catch (bytes memory r) {
            if (r.length != 36 || bytes4(r) != QuoteOut.selector) {
                assembly ("memory-safe") { revert(add(r, 32), mload(r)) }
            }
            assembly ("memory-safe") { out := mload(add(r, 36)) }
        }
        _inExec = false;
    }
}
