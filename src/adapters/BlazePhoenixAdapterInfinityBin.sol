// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

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

    IInfinityVault public immutable VAULT;
    IInfinityBinPoolManager public immutable BIN_MANAGER;
    bytes32 public immutable HOOK_CODEHASH0;
    bytes32 public immutable HOOK_CODEHASH1;
    bytes32 public immutable HOOK_CODEHASH2;

    /// STUB (red commit): the ABI only.
    constructor(address gate, address binManager, address[3] memory) ExtAdapterBase(gate) {
        BIN_MANAGER = IInfinityBinPoolManager(binManager);
        VAULT = IInfinityVault(IInfinityBinPoolManager(binManager).vault());
    }

    function resolve(address, address, uint24, bytes calldata hint)
        external view returns (address venuePool, bytes32 aux0, bytes32 aux1)
    {
        (venuePool, aux0, aux1) = (address(VAULT), bytes32(hint), bytes32(0));
    }

    function exec(address, bytes32, bytes32, bool, uint256, address) external returns (uint256) {}
    function lockAcquired(bytes calldata) external returns (bytes memory) {}
    function quote(address, bytes32, bytes32, bool, uint256) external view returns (uint256, uint256) {}
    function quoteCall(address, bytes32, bytes32, bool, uint256) external returns (uint256) {}
}
