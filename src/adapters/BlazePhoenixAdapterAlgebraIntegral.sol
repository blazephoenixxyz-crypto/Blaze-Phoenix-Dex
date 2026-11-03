// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {BlazePhoenixCore as BPC} from "../BlazePhoenixCore.sol";
import {IExtAdapter} from "./IExtAdapter.sol";
import {ExtAdapterBase} from "./ExtAdapterBase.sol";

/// Algebra Integral factory: the registry of custom venues (AlgebraFactory.customPoolByPair).
interface IAlgebraCustomFactory {
    function customPoolByPair(address deployer, address token0, address token1) external view returns (address);
}

/// Algebra Integral venue (AlgebraPool).
interface IAlgebraVenue {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function plugin() external view returns (address);
    function safelyGetStateOfAMM()
        external view returns (uint160 sqrtPrice, int24 tick, uint16 lastFee, uint8 pluginConfig,
            uint128 activeLiquidity, int24 nextTick, int24 previousTick);
    function ticks(int24 tick)
        external view returns (uint256 liquidityTotal, int128 liquidityDelta, int24 prevTick, int24 nextTick,
            uint256 outerFeeGrowth0Token, uint256 outerFeeGrowth1Token);
    function getReserves() external view returns (uint128, uint128);
    function swap(address recipient, bool zeroToOne, int256 amountRequired, uint160 limitSqrtPrice, bytes calldata data)
        external returns (int256 amount0, int256 amount1);
}

/// The Gate's own code scan.
interface IGateCodeScan {
    function codeIsClean(address a) external view returns (bool);
}

/// STUB (red run): the ABI of the adapter, bodies empty. resolve names the factory's record
/// without a guard, so the Gate's create (which refuses a zero venue) lets the suite run.
contract BlazePhoenixAdapterAlgebraIntegral is ExtAdapterBase, IExtAdapter {
    IAlgebraCustomFactory public immutable FACTORY;
    address public immutable POOL_DEPLOYER;
    bytes32 public immutable POOL_INIT_CODE_HASH;

    constructor(address gate, address factory, address poolDeployer, bytes32 initHash) ExtAdapterBase(gate) {
        (FACTORY, POOL_DEPLOYER, POOL_INIT_CODE_HASH) = (IAlgebraCustomFactory(factory), poolDeployer, initHash);
    }

    function resolve(address t0, address t1, uint24, bytes calldata hint)
        external view returns (address venue, bytes32 aux0, bytes32 aux1)
    {
        venue = FACTORY.customPoolByPair(abi.decode(hint, (address)), t0, t1);
    }

    function exec(address venue, bytes32 aux0, bytes32 aux1, bool zeroForOne, uint256 amtIn, address recipient)
        external returns (uint256 out)
    {}

    function algebraSwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {}

    function quote(address venue, bytes32 aux0, bytes32 aux1, bool zeroForOne, uint256 amtIn)
        external view returns (uint256 out, uint256 depth18)
    {}

    function quoteCall(address venue, bytes32 aux0, bytes32 aux1, bool zeroForOne, uint256 amtIn)
        external view returns (uint256 out)
    {}
}
