// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {BlazePhoenixCore as BPC} from "../BlazePhoenixCore.sol";
import {IExtAdapter} from "./IExtAdapter.sol";
import {ExtAdapterBase} from "./ExtAdapterBase.sol";

/// Balancer V3 Vault (balancer-v3-monorepo pkg/interfaces/contracts/vault/{IVaultMain,
/// IVaultExtension,VaultTypes}.sol). The extension functions are reached at the Vault's address.
interface IBalancerV3Vault {
    enum SwapKind { EXACT_IN, EXACT_OUT }

    struct VaultSwapParams {
        SwapKind kind;
        address pool;
        address tokenIn;
        address tokenOut;
        uint256 amountGivenRaw;
        uint256 limitRaw;
        bytes userData;
    }

    struct HooksConfig {
        bool enableHookAdjustedAmounts;
        bool shouldCallBeforeInitialize;
        bool shouldCallAfterInitialize;
        bool shouldCallComputeDynamicSwapFee;
        bool shouldCallBeforeSwap;
        bool shouldCallAfterSwap;
        bool shouldCallBeforeAddLiquidity;
        bool shouldCallAfterAddLiquidity;
        bool shouldCallBeforeRemoveLiquidity;
        bool shouldCallAfterRemoveLiquidity;
        address hooksContract;
    }

    function unlock(bytes calldata data) external returns (bytes memory result);
    function settle(address token, uint256 amountHint) external returns (uint256 credit);
    function sendTo(address token, address to, uint256 amount) external;
    function swap(VaultSwapParams memory params)
        external returns (uint256 amountCalculatedRaw, uint256 amountInRaw, uint256 amountOutRaw);
    function quote(bytes calldata data) external returns (bytes memory result);
    function isPoolRegistered(address pool) external view returns (bool);
    function getPoolTokens(address pool) external view returns (address[] memory tokens);
    function getHooksConfig(address pool) external view returns (HooksConfig memory);
    /// VaultTypes.TokenInfo; `tokenType` read as its uint8 word, so a new enum member cannot
    /// make the decode revert.
    struct TokenInfo {
        uint8 tokenType;
        address rateProvider;
        bool paysYieldFees;
    }
    function getPoolTokenInfo(address pool) external view returns (
        address[] memory tokens, TokenInfo[] memory tokenInfo, uint256[] memory balancesRaw,
        uint256[] memory lastBalancesLiveScaled18
    );
    /// IVaultExtension: true while an `unlock` (or a query) is running.
    function isUnlocked() external view returns (bool);
}

/// IBasePoolFactory.
interface IBalancerV3PoolFactory {
    function isPoolFromFactory(address pool) external view returns (bool);
}

/// @title  BlazePhoenixAdapterBalancerV3 — Gate adapter for one Balancer V3 Vault.
/// @notice Custody SETTLE: `exec` unlocks the Vault; inside the callback (from the Vault, and
///         only while this adapter's own `exec` is running) it swaps EXACT_IN, transfers exactly
///         the input to the Vault, settles with that amount as the hint, and has the Vault send
///         the output straight to `recipient`. No allowance anywhere.
///         IDENTITY: hint = pool; the Vault answers `isPoolRegistered` and `getPoolTokens`; one of
///         two factories fixed at construction answers `isPoolFromFactory`.
///         HOOKS: refused if `enableHookAdjustedAmounts` (the Router's own rule for V4 delta hooks)
///         or if a hooks contract is set whose codehash is not one of the two pinned here. The
///         pin is checked again on every `exec`, like the Router's `isHookLive`.
///         venuePool = the Vault; aux0 = pool; aux1 = hooks contract (0 if none).
///         QUOTE: V3 quotes only by eth_call (`Vault.quote`), so `quote` answers out = 0.
///         DEPTH: `quote` declares the pool's raw balances in the Vault (`getPoolTokenInfo`), the
///         shorter side of the wrapper's pair in 18 decimals (ExtAdapterBase._listedDepth18); none
///         while the Vault is unlocked.
contract BlazePhoenixAdapterBalancerV3 is ExtAdapterBase, IExtAdapter {
    IBalancerV3Vault public immutable VAULT;
    address public immutable FACTORY0;
    address public immutable FACTORY1;
    bytes32 public immutable HOOK_CODEHASH0;
    bytes32 public immutable HOOK_CODEHASH1;

    bool transient private _inExec;

    constructor(address gate, address vault, address[2] memory factories, bytes32[2] memory hookCodehashes)
        ExtAdapterBase(gate)
    {
        if (vault == address(0) || factories[0] == address(0)) revert AdapterE(0);
        VAULT = IBalancerV3Vault(vault);
        (FACTORY0, FACTORY1) = (factories[0], factories[1]);
        (HOOK_CODEHASH0, HOOK_CODEHASH1) = (hookCodehashes[0], hookCodehashes[1]);
    }

    function resolve(address t0, address t1, uint24, bytes calldata hint)
        external view returns (address venuePool, bytes32 aux0, bytes32 aux1)
    {
        if (hint.length != 32) revert AdapterE(8);
        address pool = abi.decode(hint, (address));
        if (!VAULT.isPoolRegistered(pool)) revert AdapterE(2);
        if (!_fromListedFactory(pool)) revert AdapterE(2);
        _indices(VAULT.getPoolTokens(pool), t0, t1);
        IBalancerV3Vault.HooksConfig memory h = VAULT.getHooksConfig(pool);
        if (h.enableHookAdjustedAmounts) revert AdapterE(7);
        _requireHookPinned(h.hooksContract);
        (venuePool, aux0, aux1) = (address(VAULT), bytes32(uint256(uint160(pool))), bytes32(uint256(uint160(h.hooksContract))));
    }

    function _fromListedFactory(address pool) private view returns (bool) {
        return IBalancerV3PoolFactory(FACTORY0).isPoolFromFactory(pool)
            || (FACTORY1 != address(0) && IBalancerV3PoolFactory(FACTORY1).isPoolFromFactory(pool));
    }

    /// The ONE producer of "may this pool's hooks run under us": none, or code that is one of
    /// the two pinned codehashes.
    function _requireHookPinned(address hooks) private view {
        if (hooks == address(0)) return;
        bytes32 h = hooks.codehash;
        if (h == bytes32(0) || (h != HOOK_CODEHASH0 && h != HOOK_CODEHASH1)) revert AdapterE(7);
    }

    function exec(address, bytes32 aux0, bytes32 aux1, bool zeroForOne, uint256 amtIn, address recipient)
        external returns (uint256)
    {
        (address tIn, address tOut) = _wrapperTokens(zeroForOne);
        _requireHookPinned(address(uint160(uint256(aux1))));
        _inExec = true;
        VAULT.unlock(abi.encodeCall(this.onUnlock, (address(uint160(uint256(aux0))), tIn, tOut, amtIn, recipient)));
        _inExec = false;
        return 0; // advisory and never read: the wrapper measures the recipient
    }

    /// The Vault's callback. Only the Vault, and only inside this adapter's own `exec`: the
    /// transient credit of an unlock belongs to whoever runs inside it.
    function onUnlock(address pool, address tIn, address tOut, uint256 amtIn, address recipient) external {
        if (msg.sender != address(VAULT) || !_inExec) revert AdapterE(6);
        (, , uint256 outRaw) = VAULT.swap(
            IBalancerV3Vault.VaultSwapParams(IBalancerV3Vault.SwapKind.EXACT_IN, pool, tIn, tOut, amtIn, 1, "")
        );
        BPC.safeTransfer(tIn, address(VAULT), amtIn);
        // The hint is what was transferred, never more: credit = min(reserve delta, hint).
        VAULT.settle(tIn, amtIn);
        VAULT.sendTo(tOut, recipient, outRaw);
    }

    /// No depth while the Vault is unlocked: a swap there writes the pool's balances before its
    /// debt is settled (Vault.sol `_swap`; settlement is checked when the outermost unlock ends),
    /// so a balance read mid-session may be a flash loan's. The Curve adapters' `live` probe, in
    /// the Vault's own words.
    function quote(address, bytes32 aux0, bytes32, bool, uint256)
        external view returns (uint256 out, uint256 depth18)
    {
        if (VAULT.isUnlocked()) return (0, 0);
        (address[] memory tokens, , uint256[] memory raw, ) = VAULT.getPoolTokenInfo(address(uint160(uint256(aux0))));
        depth18 = _listedDepth18(tokens, raw);
    }

    /// eth_call only (the Vault's `quote` requires a static-call context).
    /// The pair is the calling wrapper's, as in `exec`: a caller the Gate did not create is refused.
    function quoteCall(address, bytes32 aux0, bytes32, bool zeroForOne, uint256 amtIn) external returns (uint256 out) {
        (address tIn, address tOut) = _wrapperTokens(zeroForOne);
        bytes memory r = VAULT.quote(abi.encodeCall(this.onQuote, (address(uint160(uint256(aux0))), tIn, tOut, amtIn)));
        out = abi.decode(r, (uint256));
    }

    /// The Vault's query callback: a swap that the query context never settles or persists.
    function onQuote(address pool, address tIn, address tOut, uint256 amtIn) external returns (uint256 outRaw) {
        if (msg.sender != address(VAULT)) revert AdapterE(6);
        (, , outRaw) = VAULT.swap(
            IBalancerV3Vault.VaultSwapParams(IBalancerV3Vault.SwapKind.EXACT_IN, pool, tIn, tOut, amtIn, 1, "")
        );
    }
}
