// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {IExtAdapter} from "./IExtAdapter.sol";
import {ExtAdapterBase} from "./ExtAdapterBase.sol";

/// Balancer V2 Vault (balancer-v2-monorepo pkg/interfaces/contracts/vault/IVault.sol).
interface IBalancerV2Vault {
    enum SwapKind { GIVEN_IN, GIVEN_OUT }
    enum PoolSpecialization { GENERAL, MINIMAL_SWAP_INFO, TWO_TOKEN }

    struct SingleSwap {
        bytes32 poolId;
        SwapKind kind;
        address assetIn;
        address assetOut;
        uint256 amount;
        bytes userData;
    }

    struct BatchSwapStep {
        bytes32 poolId;
        uint256 assetInIndex;
        uint256 assetOutIndex;
        uint256 amount;
        bytes userData;
    }

    struct FundManagement {
        address sender;
        bool fromInternalBalance;
        address payable recipient;
        bool toInternalBalance;
    }

    function swap(SingleSwap memory singleSwap, FundManagement memory funds, uint256 limit, uint256 deadline)
        external payable returns (uint256);
    function queryBatchSwap(SwapKind kind, BatchSwapStep[] memory swaps, address[] memory assets, FundManagement memory funds)
        external returns (int256[] memory assetDeltas);
    function getPool(bytes32 poolId) external view returns (address, PoolSpecialization);
    function getPoolTokens(bytes32 poolId)
        external view returns (address[] memory tokens, uint256[] memory balances, uint256 lastChangeBlock);
}

/// pool-utils BasePoolFactory.
interface IBalancerPoolFactory {
    function isPoolFromFactory(address pool) external view returns (bool);
}

/// @title  BlazePhoenixAdapterBalancerV2 — Gate adapter for one Balancer V2 Vault.
/// @notice Custody PULL: the Vault is the spender (shared by every pool), so the approval is
///         exactly this call's input and must be consumed to zero by the swap.
///         `FundManagement` is fixed: sender = this adapter, no internal balance either way,
///         recipient = the wrapper's recipient. GIVEN_IN, limit 1, userData empty.
///         IDENTITY: hint = poolId; the Vault answers which pool it is (`getPool`) and which
///         tokens it holds (`getPoolTokens`); one of up to four factories fixed at construction
///         answers `isPoolFromFactory` (anyone can deploy a factory, so the list is the adapter's).
///         venuePool = the Vault; aux0 = poolId; aux1 unused.
///         QUOTE: Balancer V2 has no view quote (`queryBatchSwap` writes and reverts), so `quote`
///         answers 0 and the SDK uses `quoteCall` by eth_call; the leg then travels attested.
contract BlazePhoenixAdapterBalancerV2 is ExtAdapterBase, IExtAdapter {
    IBalancerV2Vault public immutable VAULT;
    address public immutable FACTORY0;
    address public immutable FACTORY1;
    address public immutable FACTORY2;
    address public immutable FACTORY3;

    constructor(address gate, address vault, address[4] memory factories) ExtAdapterBase(gate) {
        if (vault == address(0) || factories[0] == address(0)) revert AdapterE(0);
        VAULT = IBalancerV2Vault(vault);
        (FACTORY0, FACTORY1, FACTORY2, FACTORY3) = (factories[0], factories[1], factories[2], factories[3]);
    }

    function resolve(address t0, address t1, uint24, bytes calldata hint)
        external view returns (address venuePool, bytes32 aux0, bytes32 aux1)
    {
        if (hint.length != 32) revert AdapterE(8);
        bytes32 poolId = abi.decode(hint, (bytes32));
        (address pool, ) = VAULT.getPool(poolId);
        if (pool == address(0) || !_fromListedFactory(pool)) revert AdapterE(2);
        (address[] memory tokens, , ) = VAULT.getPoolTokens(poolId);
        _indices(tokens, t0, t1);
        (venuePool, aux0, aux1) = (address(VAULT), poolId, bytes32(0));
    }

    function _fromListedFactory(address pool) private view returns (bool) {
        address[4] memory f = [FACTORY0, FACTORY1, FACTORY2, FACTORY3];
        for (uint256 k; k < 4; ) {
            if (f[k] != address(0) && IBalancerPoolFactory(f[k]).isPoolFromFactory(pool)) return true;
            unchecked { ++k; }
        }
        return false;
    }

    function exec(address, bytes32 aux0, bytes32, bool zeroForOne, uint256 amtIn, address recipient)
        external returns (uint256 out)
    {
        (address tIn, address tOut) = _wrapperTokens(zeroForOne);
        _approveExact(tIn, address(VAULT), amtIn);
        out = VAULT.swap(
            IBalancerV2Vault.SingleSwap(aux0, IBalancerV2Vault.SwapKind.GIVEN_IN, tIn, tOut, amtIn, ""),
            IBalancerV2Vault.FundManagement(address(this), false, payable(recipient), false),
            1,
            block.timestamp
        );
        _requireNoAllowance(tIn, address(VAULT));
    }

    function quote(address, bytes32, bytes32, bool, uint256) external pure returns (uint256, uint256) {
        return (0, 0);
    }

    /// eth_call only: `queryBatchSwap` is non-view by design (Swaps.sol, "query" section). The
    /// pair is the calling wrapper's, as in `exec`: a caller the Gate did not create is refused.
    function quoteCall(address, bytes32 poolId, bytes32, bool zeroForOne, uint256 amtIn) external returns (uint256 out) {
        (address tIn, address tOut) = _wrapperTokens(zeroForOne);
        IBalancerV2Vault.BatchSwapStep[] memory steps = new IBalancerV2Vault.BatchSwapStep[](1);
        steps[0] = IBalancerV2Vault.BatchSwapStep(poolId, 0, 1, amtIn, "");
        address[] memory assets = new address[](2);
        (assets[0], assets[1]) = (tIn, tOut);
        int256[] memory d = VAULT.queryBatchSwap(
            IBalancerV2Vault.SwapKind.GIVEN_IN,
            steps,
            assets,
            IBalancerV2Vault.FundManagement(address(this), false, payable(address(this)), false)
        );
        if (d.length == 2 && d[1] < 0) out = uint256(-d[1]);
    }
}
