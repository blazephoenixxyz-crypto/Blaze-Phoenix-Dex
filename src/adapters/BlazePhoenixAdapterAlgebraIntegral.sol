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
/// @title  BlazePhoenixAdapterAlgebraIntegral - Gate adapter for Algebra Integral custom venues
///         (Blackhole CLMM): one contract, one instance (and one Gate family) per factory.
/// @notice Custody PULL by callback: `swap` pays `recipient`, then asks this adapter in
///         `algebraSwapCallback`, which pays only the venue of the exec in progress, only the
///         input side and never more than `amtIn`. The adapter never grants an allowance.
///         IDENTITY: the hint names the custom deployer; the venue is the factory's record of
///         (deployer, t0, t1) and must sit at CREATE2(POOL_DEPLOYER, keccak256(abi.encode(
///         deployer, t0, t1)), POOL_INIT_CODE_HASH), with token0 == t0. Asked once, at resolve.
///         PLUGINS: BEFORE_SWAP and DYNAMIC_FEE are refused always; AFTER_SWAP runs inside our
///         exec after the venue reopens, and is admitted only with the plugin and the code the
///         curator saw at create. Checked on every exec, quote and quoteCall against the
///         venue's config of now; with AFTER_SWAP off the plugin is not read.
///         QUOTE: a view walk of the venue's tick list with the Core's step (BPC._v4Step), the
///         live fee, and 0 unless the walk fills amtIn; closed by BPC.GATE_QUOTE_GAS.
///         aux0 = the plugin pinned at create; aux1 = its code hash.
contract BlazePhoenixAdapterAlgebraIntegral is ExtAdapterBase, IExtAdapter {
    /// Plugins.sol: the hooks that run in swap, and the fee override.
    uint8 internal constant BEFORE_SWAP = 1;
    uint8 internal constant AFTER_SWAP = 2;
    uint8 internal constant DYNAMIC_FEE = 128;
    uint8 internal constant REFUSED = BEFORE_SWAP | DYNAMIC_FEE;

    IAlgebraCustomFactory public immutable FACTORY;
    address public immutable POOL_DEPLOYER;
    bytes32 public immutable POOL_INIT_CODE_HASH;

    /// The exec in progress: the venue it pays, the input token and the most it pays.
    address transient _venue;
    address transient _tIn;
    uint256 transient _amt;

    constructor(address gate, address factory, address poolDeployer, bytes32 initHash)
        ExtAdapterBase(gate, [bytes32(0), bytes32(0), bytes32(0)])
    {
        if (factory == address(0) || poolDeployer == address(0) || initHash == bytes32(0)) revert AdapterE(0);
        (FACTORY, POOL_DEPLOYER, POOL_INIT_CODE_HASH) = (IAlgebraCustomFactory(factory), poolDeployer, initHash);
    }

    function resolve(address t0, address t1, uint24, bytes calldata hint)
        external view returns (address venue, bytes32 aux0, bytes32 aux1)
    {
        if (hint.length != 32) revert AdapterE(8);
        uint256 word = abi.decode(hint, (uint256));
        if (word == 0 || word > type(uint160).max) revert AdapterE(8);
        address deployer = address(uint160(word));
        venue = FACTORY.customPoolByPair(deployer, t0, t1);
        // The CREATE2 address is never 0: one check covers the absent record and the false one.
        if (venue != BPC.create2Address(POOL_DEPLOYER, keccak256(abi.encode(deployer, t0, t1)), POOL_INIT_CODE_HASH)) {
            revert AdapterE(2);
        }
        if (IAlgebraVenue(venue).token0() != t0) revert AdapterE(3);
        (, , , uint8 cfg, , , ) = _state(venue);
        if (cfg & REFUSED != 0) revert AdapterE(7);
        address p = IAlgebraVenue(venue).plugin();
        if (p.code.length != 0 && !IGateCodeScan(address(GATE)).codeIsClean(p)) revert AdapterE(7);
        aux0 = bytes32(uint256(uint160(p)));
        aux1 = p.codehash;
    }

    function exec(address venue, bytes32 aux0, bytes32 aux1, bool zeroForOne, uint256 amtIn, address recipient)
        external returns (uint256 out)
    {
        address tIn = _wrapperTokenIn(zeroForOne);
        // A negative amountRequired is exact output at the venue.
        if (amtIn > uint256(type(int256).max)) revert AdapterE(8);
        (, , , uint8 cfg, , , ) = _state(venue);
        if (!_pluginOk(venue, cfg, aux0, aux1)) revert AdapterE(7);
        (_venue, _tIn, _amt) = (venue, tIn, amtIn);
        // No minimum at the venue: the floors are the Router's, never a quote.
        (int256 a0, int256 a1) = IAlgebraVenue(venue).swap(recipient, zeroForOne, int256(amtIn),
            zeroForOne ? BPC.MIN_SQRT_PRICE_PLUS_ONE : BPC.MAX_SQRT_PRICE_MINUS_ONE, "");
        _venue = address(0);
        int256 o = zeroForOne ? a1 : a0;
        if (o < 0) out = uint256(-o);
    }

    /// The venue's ask: only from the venue of the exec in progress, only 0 < owed <= amtIn.
    function algebraSwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
        if (msg.sender != _venue) revert AdapterE(6);
        int256 owed = amount0Delta > 0 ? amount0Delta : amount1Delta;
        if (owed <= 0 || uint256(owed) > _amt) revert AdapterE(6);
        BPC.safeTransfer(_tIn, msg.sender, uint256(owed));
    }

    function quote(address venue, bytes32 aux0, bytes32 aux1, bool zeroForOne, uint256 amtIn)
        external view returns (uint256 out, uint256 depth18)
    {
        bool ok;
        (ok, out) = _out(venue, aux0, aux1, zeroForOne, amtIn);
        if (!ok) return (0, 0);
        (uint128 r0, uint128 r1) = IAlgebraVenue(venue).getReserves();
        depth18 = _depth18(IAlgebraVenue(venue).token0(), r0, IAlgebraVenue(venue).token1(), r1);
    }

    function quoteCall(address venue, bytes32 aux0, bytes32 aux1, bool zeroForOne, uint256 amtIn)
        external view returns (uint256 out)
    {
        (, out) = _out(venue, aux0, aux1, zeroForOne, amtIn);
    }

    /// The one state read: it reverts while the venue is mid-operation (globalState would not).
    function _state(address venue) private view returns (uint160, int24, uint16, uint8, uint128, int24, int24) {
        return IAlgebraVenue(venue).safelyGetStateOfAMM();
    }

    function _pluginOk(address venue, uint8 cfg, bytes32 aux0, bytes32 aux1) private view returns (bool) {
        if (cfg & REFUSED != 0) return false;
        if (cfg & AFTER_SWAP == 0) return true;
        address p = IAlgebraVenue(venue).plugin();
        return p == address(uint160(uint256(aux0))) && p.codehash == aux1;
    }

    /// ok = false: refused by the plugin policy. amtIn 0 and above int256 max give 0 by the
    /// walk itself (nothing moves, or no venue fills it).
    function _out(address venue, bytes32 aux0, bytes32 aux1, bool zeroForOne, uint256 amtIn)
        private view returns (bool ok, uint256 out)
    {
        (uint160 sp, , uint16 fee, uint8 cfg, uint128 liq, int24 next, int24 prev) = _state(venue);
        if (!_pluginOk(venue, cfg, aux0, aux1)) return (false, 0);
        ok = true;
        out = _walk(IAlgebraVenue(venue), sp, fee, liq, next, prev, zeroForOne, amtIn);
    }

    /// SwapCalculation's exact-input loop: toward the next listed tick or the limit, crossing
    /// when the price lands on the tick, stopping when it moves short of it. 0 unless filled.
    function _walk(IAlgebraVenue v, uint160 sp, uint16 fee, uint128 liq, int24 next, int24 prev, bool zfo, uint256 rem)
        private view returns (uint256 out)
    {
        uint160 limit = zfo ? BPC.MIN_SQRT_PRICE_PLUS_ONE : BPC.MAX_SQRT_PRICE_MINUS_ONE;
        while (true) {
            int24 t = zfo ? prev : next;
            uint160 tp = BPC.sqrtPriceAtTick(t);
            (uint160 np, uint256 used, uint256 o) = BPC._v4Step(sp, (zfo == (tp < limit)) ? limit : tp, liq, rem, fee, zfo);
            rem -= used;
            out += o;
            if (np == tp) {
                (, int128 delta, int24 pT, int24 nT, , ) = v.ticks(t);
                if (zfo) {
                    delta = -delta;
                    (prev, next) = (pT, t);
                } else {
                    (prev, next) = (t, nT);
                }
                liq = delta < 0 ? liq - uint128(-delta) : liq + uint128(delta);
            } else if (np != sp) {
                break;
            }
            sp = np;
            if (rem == 0 || sp == limit) break;
        }
        if (rem != 0) out = 0;
    }
}
