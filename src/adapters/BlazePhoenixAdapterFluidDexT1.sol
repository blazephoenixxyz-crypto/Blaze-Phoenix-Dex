// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {BlazePhoenixCore as BPC} from "../BlazePhoenixCore.sol";
import {IExtAdapter} from "./IExtAdapter.sol";
import {ExtAdapterBase} from "./ExtAdapterBase.sol";

/// Fluid DEX T1 (fluid-contracts-public, contracts/protocols/dex/interfaces/iDexT1.sol): the
/// subset this adapter calls. `constantsView` is the pool's immutables, all static words.
interface IFluidDexT1 {
    error FluidDexSwapResult(uint256 amountOut);

    struct Implementations {
        address shift;
        address admin;
        address colOperations;
        address debtOperations;
        address perfectOperationsAndSwapOut;
    }

    struct ConstantViews {
        uint256 dexId;
        address liquidity;
        address factory;
        Implementations implementations;
        address deployerContract;
        address token0;
        address token1;
        bytes32 supplyToken0Slot;
        bytes32 borrowToken0Slot;
        bytes32 supplyToken1Slot;
        bytes32 borrowToken1Slot;
        bytes32 exchangePriceToken0Slot;
        bytes32 exchangePriceToken1Slot;
        uint256 oracleMapping;
    }

    function constantsView() external view returns (ConstantViews memory);
    function readFromStorage(bytes32 slot) external view returns (uint256);
    function swapIn(bool swap0to1, uint256 amountIn, uint256 amountOutMin, address to) external payable returns (uint256);
    function swapInWithCallback(bool swap0to1, uint256 amountIn, uint256 amountOutMin, address to)
        external payable returns (uint256);
}

/// Fluid Liquidity: the one contract that holds every Fluid DEX's tokens.
interface IFluidLiquidity {
    function readFromStorage(bytes32 slot) external view returns (uint256);
}

/// @title  BlazePhoenixAdapterFluidDexT1 — Gate adapter for the Fluid DEX T1 pools of one factory.
/// @notice IDENTITY (derived, never declared): hint = abi.encode(uint256 dexId). The pool is the
///         address the factory's CREATE at nonce dexId produced (DexFactory.getDexAddress, the
///         factory's own `isDex`), computed here; no caller ever names a pool. That code must then
///         answer its own dexId and this adapter's Liquidity, and trade exactly the wrapper's pair.
///         Pools of native ETH are refused (AdapterE(4)).
///         venuePool = Fluid Liquidity, which holds the pools' tokens (the Gate's cap and use
///         threshold read what the venue holds); aux0 = pool; aux1 = 0.
///         CUSTODY (callback, no allowance anywhere): `exec` calls `swapInWithCallback`; the pool
///         asks for the input through `dexCallback`, which pays Liquidity at most this call's
///         input, once, only to the pool `exec` is running, and only inside it. Liquidity sends
///         the output straight to `recipient`; the wrapper measures both.
///         QUOTE: Fluid prices only by a reverting simulation, so `quote` answers out = 0 and
///         `quoteCall` reads `swapIn(.., to = 0x…dEaD)`'s FluidDexSwapResult.
///         DEPTH: the pool's collateral supply in Liquidity, decoded as the pool decodes it
///         (`_getLiquidityCollateral`), the shorter side (ExtAdapterBase._depth18); none while the
///         pool's reentrancy bit is set. Smart-debt reserves are not counted (an under-statement).
contract BlazePhoenixAdapterFluidDexT1 is ExtAdapterBase, IExtAdapter {
    address public immutable FACTORY;
    address public immutable LIQUIDITY;

    address internal constant NATIVE = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    address internal constant SIMULATE = 0x000000000000000000000000000000000000dEaD;
    uint256 internal constant X64 = 0xffffffffffffffff;

    /// The one pending callback: the pool `exec` is calling, the token and the most it may ask.
    address transient private _cbDex;
    address transient private _cbToken;
    uint256 transient private _cbCap;

    constructor(address gate, address factory, address liquidity) ExtAdapterBase(gate) {
        if (factory == address(0) || liquidity == address(0)) revert AdapterE(0);
        (FACTORY, LIQUIDITY) = (factory, liquidity);
    }

    function resolve(address t0, address t1, uint24, bytes calldata hint)
        external view returns (address venuePool, bytes32 aux0, bytes32 aux1)
    {
        if (hint.length != 32) revert AdapterE(8);
        uint256 id = abi.decode(hint, (uint256));
        if (id == 0 || id > 0xffffff) revert AdapterE(8);
        address dex = _createAddress(FACTORY, id);
        IFluidDexT1.ConstantViews memory c = IFluidDexT1(dex).constantsView();
        if (c.dexId != id || c.liquidity != LIQUIDITY) revert AdapterE(2);
        if (c.token0 != t0 || c.token1 != t1) revert AdapterE(3);
        if (t0 == NATIVE || t1 == NATIVE) revert AdapterE(4);
        (venuePool, aux0, aux1) = (LIQUIDITY, bytes32(uint256(uint160(dex))), bytes32(0));
    }

    /// The address CREATE gives `deployer`'s n-th creation, 1 <= n <= 0xffffff: keccak256 of the
    /// RLP list [deployer, n] (Fluid's AddressCalcs.addressCalc, the yellow paper's eq. 86).
    function _createAddress(address deployer, uint256 n) internal pure returns (address) {
        bytes memory rlp;
        if (n <= 0x7f) rlp = abi.encodePacked(bytes2(0xd694), deployer, uint8(n));
        else if (n <= 0xff) rlp = abi.encodePacked(bytes2(0xd794), deployer, bytes1(0x81), uint8(n));
        else if (n <= 0xffff) rlp = abi.encodePacked(bytes2(0xd894), deployer, bytes1(0x82), uint16(n));
        else rlp = abi.encodePacked(bytes2(0xd994), deployer, bytes1(0x83), uint24(n));
        return address(uint160(uint256(keccak256(rlp))));
    }

    /// Fluid's swap0to1 is the wrapper's zeroForOne: both order the same two tokens ascending.
    function exec(address, bytes32 aux0, bytes32, bool zeroForOne, uint256 amtIn, address recipient)
        external returns (uint256)
    {
        address tIn = _wrapperTokenIn(zeroForOne);
        address dex = address(uint160(uint256(aux0)));
        (_cbDex, _cbToken, _cbCap) = (dex, tIn, amtIn);
        IFluidDexT1(dex).swapInWithCallback(zeroForOne, amtIn, 1, recipient);
        return 0; // advisory and never read: the wrapper measures the recipient
    }

    /// The pool's request for the input (main.sol liquidityCallback -> IDexCallback). Only the
    /// pool `exec` is calling, only for its input token, at most this call's input, and once:
    /// the slot is cleared before paying. A pool that never asks leaves the input here, and the
    /// wrapper refuses that (GateE(14)).
    function dexCallback(address token, uint256 amount) external {
        if (msg.sender != _cbDex || token != _cbToken || amount > _cbCap) revert AdapterE(6);
        _cbDex = address(0);
        BPC.safeTransfer(token, LIQUIDITY, amount);
    }

    /// No depth while the pool's reentrancy bit (dexVariables bit 0) is set: inside a Fluid
    /// operation the pool's supply in Liquidity moves before the operation settles.
    function quote(address, bytes32 aux0, bytes32, bool, uint256)
        external view returns (uint256 out, uint256 depth18)
    {
        IFluidDexT1 dex = IFluidDexT1(address(uint160(uint256(aux0))));
        if (dex.readFromStorage(bytes32(0)) & 1 != 0) return (0, 0);
        IFluidDexT1.ConstantViews memory c = dex.constantsView();
        depth18 = _depth18(
            c.token0, _collateral(c.supplyToken0Slot, c.exchangePriceToken0Slot),
            c.token1, _collateral(c.supplyToken1Slot, c.exchangePriceToken1Slot)
        );
    }

    /// The pool's supply of one token in Liquidity, in token units: the 64-bit BigMath amount
    /// (coefficient 56 | exponent 8) at bit 1, scaled by the stored supply exchange price
    /// (bits 91..154, 1e12 precision) when the position earns interest (bit 0).
    function _collateral(bytes32 supplySlot, bytes32 priceSlot) private view returns (uint256 amt) {
        uint256 d = IFluidLiquidity(LIQUIDITY).readFromStorage(supplySlot);
        uint256 x = (d >> 1) & X64;
        amt = (x >> 8) << (x & 0xff);
        if (d & 1 != 0) amt = amt * ((IFluidLiquidity(LIQUIDITY).readFromStorage(priceSlot) >> 91) & X64) / 1e12;
    }

    /// eth_call only: Fluid's simulation writes the pool's reentrancy bit before reverting.
    /// The pair is the calling wrapper's, as in `exec`: a caller the Gate did not create is refused.
    function quoteCall(address, bytes32 aux0, bytes32, bool zeroForOne, uint256 amtIn) external returns (uint256 out) {
        _wrapperTokens(zeroForOne);
        try IFluidDexT1(address(uint160(uint256(aux0)))).swapIn(zeroForOne, amtIn, 0, SIMULATE) returns (uint256) {
            return 0; // the simulation never returns; a pool that does is not priced
        } catch (bytes memory r) {
            if (r.length != 36 || bytes4(r) != IFluidDexT1.FluidDexSwapResult.selector) {
                assembly ("memory-safe") { revert(add(r, 32), mload(r)) }
            }
            assembly ("memory-safe") { out := mload(add(r, 36)) }
        }
    }
}
