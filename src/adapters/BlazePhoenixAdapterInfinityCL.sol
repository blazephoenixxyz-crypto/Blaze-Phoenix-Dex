// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {BlazePhoenixCore as BPC} from "../BlazePhoenixCore.sol";
import {IExtAdapter} from "./IExtAdapter.sol";
import {ExtAdapterBase} from "./ExtAdapterBase.sol";

/// PancakeSwap Infinity Vault (infinity-core src/interfaces/IVault.sol). Currency is an address.
interface IInfinityVault {
    function lock(bytes calldata data) external returns (bytes memory result);
    function sync(address currency) external;
    function settle() external payable returns (uint256 paid);
    function take(address currency, address to, uint256 amount) external;
    function getLocker() external view returns (address);
}

/// infinity-core src/interfaces/ILockCallback.sol.
interface ILockCallback {
    function lockAcquired(bytes calldata data) external returns (bytes memory);
}

/// PancakeSwap Infinity CL pool manager (infinity-core src/pool-cl/interfaces/ICLPoolManager.sol;
/// PoolKey from src/types/PoolKey.sol). PoolId is bytes32; BalanceDelta is an int256 with amount0
/// in the high 128 bits and amount1 in the low 128 bits.
interface IInfinityCLPoolManager {
    struct PoolKey {
        address currency0;
        address currency1;
        address hooks;
        address poolManager;
        uint24 fee;
        bytes32 parameters;
    }

    struct SwapParams {
        bool zeroForOne;
        int256 amountSpecified;
        uint160 sqrtPriceLimitX96;
    }

    function swap(PoolKey memory key, SwapParams memory params, bytes calldata hookData) external returns (int256 delta);
    function poolIdToPoolKey(bytes32 id) external view returns (
        address currency0, address currency1, address hooks, address poolManager, uint24 fee, bytes32 parameters
    );
    function getSlot0(bytes32 id) external view returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee);
    function getLiquidity(bytes32 id) external view returns (uint128 liquidity);
    function vault() external view returns (address);
}

/// @title  BlazePhoenixAdapterInfinityCL — Gate adapter for one PancakeSwap Infinity CL pool manager.
/// @notice Custody SETTLE: `exec` locks the Vault; inside the callback (from the Vault, and only
///         while this adapter's own `exec` or `quoteCall` is running) it swaps exact-in to the
///         price limit, syncs the input currency, transfers exactly the input to the Vault,
///         settles, and has the Vault pay the output straight to `recipient`. No allowance
///         anywhere. A fill short of the input leaves the input's delta open, and the Vault's own
///         rule (no delta open when the lock ends: CurrencyNotSettled) reverts the whole exec.
///         ERC-20 pairs only: the Gate refuses address(0) as a token, and the pool's currencies
///         must equal the wrapper's pair.
///         IDENTITY: hint = PoolId; the manager's own record of it (`poolIdToPoolKey`, written at
///         initialize) names this manager and the pair.
///         HOOKS: refused if the bitmap sets afterSwap or either returns-delta bit, or if the fee
///         is dynamic; a hooks contract must have one of the three codehashes pinned at
///         construction. The pin is checked again on every `exec` and `quoteCall`.
///         venuePool = the Vault; aux0 = PoolId; aux1 unused.
///         QUOTE: a CL swap is priced only by running it, so `quote` answers out = 0 and
///         `quoteCall` runs the swap inside a lock that always reverts, carrying the output out
///         as QuoteOut; any other revert is the swap's failure, never a price.
///         DEPTH: Core's depthFromL18 of the pool's liquidity at its current price (the
///         registry's own V4 arm); none while the Vault has a locker.
contract BlazePhoenixAdapterInfinityCL is ExtAdapterBase, IExtAdapter, ILockCallback {
    error QuoteOut(uint256 out);
    error QuoteSwapFailed(bytes reason);

    /// Bits of the hooks bitmap (the low 16 bits of PoolKey.parameters), infinity-core
    /// src/pool-cl/interfaces/ICLHooks.sol:18,21,22: hooks that act after the swap, or rewrite
    /// its amounts, are refused.
    uint8 internal constant HOOKS_AFTER_SWAP_OFFSET = 7;
    uint8 internal constant HOOKS_BEFORE_SWAP_RETURNS_DELTA_OFFSET = 10;
    uint8 internal constant HOOKS_AFTER_SWAP_RETURNS_DELTA_OFFSET = 11;
    uint256 internal constant REFUSED_HOOK_BITS =
        (1 << HOOKS_AFTER_SWAP_OFFSET)
        | (1 << HOOKS_BEFORE_SWAP_RETURNS_DELTA_OFFSET)
        | (1 << HOOKS_AFTER_SWAP_RETURNS_DELTA_OFFSET);
    /// src/libraries/LPFeeLibrary.sol:19.
    uint24 internal constant DYNAMIC_FEE_FLAG = 0x800000;
    /// src/pool-cl/libraries/TickMath.sol:27,29; CLPool.sol:212-214 wants the limit strictly
    /// between the bound and the current price.
    uint160 internal constant MIN_SQRT_RATIO = 4295128739;
    uint160 internal constant MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342;

    IInfinityVault public immutable VAULT;
    IInfinityCLPoolManager public immutable CL_MANAGER;
    bytes32 public immutable HOOK_CODEHASH0;
    bytes32 public immutable HOOK_CODEHASH1;
    bytes32 public immutable HOOK_CODEHASH2;

    bool transient private _inExec;

    /// `refHooks`: deployed hooks whose code may run under this adapter, pinned by codehash; a
    /// slot left at address(0) pins nothing.
    constructor(address gate, address clManager, address[3] memory refHooks) ExtAdapterBase(gate) {
        if (clManager == address(0)) revert AdapterE(0);
        CL_MANAGER = IInfinityCLPoolManager(clManager);
        VAULT = IInfinityVault(IInfinityCLPoolManager(clManager).vault());
        HOOK_CODEHASH0 = _pin(refHooks[0]);
        HOOK_CODEHASH1 = _pin(refHooks[1]);
        HOOK_CODEHASH2 = _pin(refHooks[2]);
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
        if (key.poolManager != address(CL_MANAGER)) revert AdapterE(2);
        if (key.currency0 != t0 || key.currency1 != t1) revert AdapterE(3);
        if (uint256(key.parameters) & REFUSED_HOOK_BITS != 0) revert AdapterE(7);
        if (key.fee & DYNAMIC_FEE_FLAG != 0) revert AdapterE(7);
        _requireHookPinned(key.hooks); // one of the pinned codehashes, or none
        (venuePool, aux0, aux1) = (address(VAULT), id, bytes32(0));
    }

    /// The manager's record of the id: a key written once, at initialize, so it cannot change.
    function _key(bytes32 id) private view returns (IInfinityCLPoolManager.PoolKey memory k) {
        (k.currency0, k.currency1, k.hooks, k.poolManager, k.fee, k.parameters) = CL_MANAGER.poolIdToPoolKey(id);
    }

    /// The ONE producer of "may this pool's hooks run under us": none, or code that is one of
    /// the three pinned codehashes.
    function _requireHookPinned(address hooks) private view {
        if (hooks == address(0)) return;
        bytes32 h = hooks.codehash;
        if (h == bytes32(0) || (h != HOOK_CODEHASH0 && h != HOOK_CODEHASH1 && h != HOOK_CODEHASH2)) revert AdapterE(7);
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
        IInfinityCLPoolManager.SwapParams memory p =
            IInfinityCLPoolManager.SwapParams(z, -int256(amtIn), z ? MIN_SQRT_RATIO + 1 : MAX_SQRT_RATIO - 1);
        if (quoting) {
            try CL_MANAGER.swap(key, p, "") returns (int256 d) {
                (uint256 used, uint256 out) = _amounts(d, z);
                if (used != amtIn) revert QuoteSwapFailed(""); // a fill the exec could not settle
                revert QuoteOut(out);
            } catch (bytes memory r) {
                revert QuoteSwapFailed(r);
            }
        }
        (, uint256 got) = _amounts(CL_MANAGER.swap(key, p, ""), z);
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

    /// No depth while the Vault has a locker: inside a lock a swap moves the pool's price and
    /// liquidity before its deltas are settled (Vault.lock checks them only when the callback
    /// returns), so a read mid-lock may be a flash loan's. Balancer V3's isUnlocked, in the
    /// Infinity Vault's words (IVault.getLocker).
    function quote(address, bytes32 aux0, bytes32, bool, uint256)
        external view returns (uint256 out, uint256 depth18)
    {
        (address a, address b) = _pairOf(msg.sender, true);
        if (VAULT.getLocker() != address(0)) return (0, 0);
        (uint160 sp, , , ) = CL_MANAGER.getSlot0(aux0);
        (out, depth18) = (0, BPC.depthFromL18(CL_MANAGER.getLiquidity(aux0), sp, BPC.decimalsOf(a), BPC.decimalsOf(b)));
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
