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
/// @dev    STUB (red-first): the ABI only, no behaviour.
contract BlazePhoenixAdapterInfinityCL is ExtAdapterBase, IExtAdapter, ILockCallback {
    error QuoteOut(uint256 out);
    error QuoteSwapFailed(bytes reason);

    IInfinityVault public immutable VAULT;
    IInfinityCLPoolManager public immutable CL_MANAGER;
    bytes32 public immutable HOOK_CODEHASH0;
    bytes32 public immutable HOOK_CODEHASH1;
    bytes32 public immutable HOOK_CODEHASH2;

    constructor(address gate, address clManager, address[3] memory refHooks) ExtAdapterBase(gate) {
        refHooks;
        VAULT = IInfinityVault(address(0));
        CL_MANAGER = IInfinityCLPoolManager(clManager);
        (HOOK_CODEHASH0, HOOK_CODEHASH1, HOOK_CODEHASH2) = (bytes32(0), bytes32(0), bytes32(0));
    }

    function resolve(address, address, uint24, bytes calldata)
        external view returns (address venuePool, bytes32 aux0, bytes32 aux1)
    {
        (venuePool, aux0, aux1) = (address(CL_MANAGER), bytes32(0), bytes32(0));
    }

    function exec(address, bytes32, bytes32, bool, uint256, address) external returns (uint256) {
        return 0;
    }

    function lockAcquired(bytes calldata) external returns (bytes memory) {
        return "";
    }

    function quote(address, bytes32, bytes32, bool, uint256) external view returns (uint256 out, uint256 depth18) {
        (out, depth18) = (0, 0);
    }

    function quoteCall(address, bytes32, bytes32, bool, uint256) external returns (uint256 out) {
        out = 0;
    }
}
