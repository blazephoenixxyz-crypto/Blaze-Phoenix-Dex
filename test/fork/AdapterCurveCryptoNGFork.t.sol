// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {AdapterHarness} from "../adapters/AdapterHarness.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {BlazePhoenixGate, BlazePhoenixGateWrapper} from "../adapters/vendor/BlazePhoenixGateSnapshot.sol";
import {BlazePhoenixAdapterCurveCryptoNG} from "../../src/adapters/BlazePhoenixAdapterCurveCryptoNG.sol";

/// The crypto NG adapter against the live Curve factories on Base, behind the vendored Gate
/// snapshot, at the latest block of the public endpoint (the `base` alias, no key). Skips, never
/// passes, when the fork cannot be opened.
/// Factories: curvefi/docs static/deployments.json (base.factory.twocrypto / .tricrypto, 21/10).
/// Pools: read from the factories (pool_list, get_coins) and from the pools (version, coins,
/// balances, WETH20) on 21/10; each one passes through the adapter's own `resolve`.
contract AdapterCurveCryptoNGForkTest is AdapterHarness {
    address internal constant TWO_FACTORY = 0xc9Fe0C63Af9A39402e8a5514f9c43Af0322b665F;
    address internal constant TRI_FACTORY = 0xA5961898870943c68037F6848d2D866Ed2016bcB;

    address internal constant WETH = 0x4200000000000000000000000000000000000006;
    address internal constant CRVUSD = 0x417Ac0e078398C154EdFadD9Ef675d30Be60Af93;
    address internal constant FROK = 0x42069BAbe14fB1802C5CB0F50BB9D2Ad6FEf55e2;
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant ARAT = 0x088232cC24527eDf13BCF99B10f534cAF1Dad77C;
    address internal constant SNL = 0xC5a861787f3e173F2b004d5cfA6a717f5DC5484D;
    address internal constant TOP = 0x9dba38E9cAdcf67D1959390A8c0c1DEeE619f0f2;

    address internal constant TWO_V200_FROK_WETH = 0xa0D3911349e701A1F49C1Ba2dDA34b4ce9636569; // version v2.0.0
    // pool_list(274) is v2.1.0 too, but its cbZEC answers balanceOf with code the fork's EVM rejects
    // (OpcodeNotFound, code starts 0xef): a tool limit, so the swap test uses pool_list(210).
    address internal constant TWO_V210_ARAT_USDC = 0xa719BBBBabAdbC724CA4E80b2b62CC0A15408E2a; // pool_list(210), v2.1.0
    address internal constant LCAP = 0x4dA9A0f397dB1397902070f93a4D6ddBC0E0E6e8;
    address internal constant EUSD = 0xCfA3Ef56d303AE4fAabA0592388F19d7C3399FB4;
    // The deepest Base twocrypto (api.curve.finance lead, re-read on chain 21/10: get_coins, v2.1.0,
    // balances 2.28e22 LCAP / 1.62e23 eUSD).
    address internal constant TWO_V210_LCAP_EUSD = 0xba0C274085A078D19C46F2D902698A841cBFb289;
    address internal constant FX_V210D_USDC_WETH = 0xbc2c6645431F7C4A96748f2c9f290B909F8A1113; // pool_list(240), FXSwap v2.1.0d
    address internal constant TRI_SNL_TOP_BCOW = 0xdbf876301953031e103780b3F66eFb984900706f; // Optimized, no WETH20
    address internal constant TRI_WETH_CRVUSD_TBTC = 0x6e53131F68a034873b6bFA15502aF094Ef0c5854; // OptimizedWETH

    function _fork() internal returns (bool) {
        try vm.createSelectFork("base") {} catch { vm.skip(true); return false; }
        gate = new BlazePhoenixGate(address(this));
        return true;
    }

    function _pair(address a, address b) internal {
        (t0, t1) = a < b ? (MockERC20(a), MockERC20(b)) : (MockERC20(b), MockERC20(a));
    }

    function _swapReal(address w, bool zeroForOne, uint256 amt) internal returns (uint256 out) {
        (address tIn, address tOut) = zeroForOne ? (address(t0), address(t1)) : (address(t1), address(t0));
        deal(tIn, address(this), amt);
        uint256 b = MockERC20(tOut).balanceOf(address(this));
        BlazePhoenixGateWrapper(w).swap(address(this), zeroForOne, int256(amt), 0, "");
        out = MockERC20(tOut).balanceOf(address(this)) - b;
    }

    /// quoteCall (the adapter's `_quote`, the SDK's number) == what the live pool pays.
    function _run(uint8 fam, address factory, address pool, address tIn, address tOut, uint256 amt) internal {
        _pair(tIn, tOut);
        BlazePhoenixAdapterCurveCryptoNG a = new BlazePhoenixAdapterCurveCryptoNG(address(gate), factory);
        _accept(fam, address(a));
        address w = gate.create(tIn, tOut, uint24(fam) << 16 | 1, abi.encode(pool));
        bool z = address(t0) == tIn;
        uint256 q = a.quoteCall(w, z, amt);
        assertGt(q, 0);
        assertEq(_swapReal(w, z, amt), q, "get_dy == exchange_received on the same state");
        _assertEmpty(address(a), w, pool);
    }

    function testFork_CryptoNG_Base_Twocrypto200_WethToFrok_QuoteIsExecution() public {
        if (!_fork()) return;
        _run(4, TWO_FACTORY, TWO_V200_FROK_WETH, WETH, FROK, 0.001e18);
    }

    function testFork_CryptoNG_Base_Twocrypto210_UsdcToArat_QuoteIsExecution() public {
        if (!_fork()) return;
        _run(4, TWO_FACTORY, TWO_V210_ARAT_USDC, USDC, ARAT, 1e6);
    }

    function testFork_CryptoNG_Base_Twocrypto210_EusdToLcap_DeepPool_QuoteIsExecution() public {
        if (!_fork()) return;
        _run(4, TWO_FACTORY, TWO_V210_LCAP_EUSD, EUSD, LCAP, 1000e18);
    }

    /// FXSwap, the newest family, comes out of the same Twocrypto factory (curvefi/docs fxswap).
    function testFork_CryptoNG_Base_FxSwap210d_UsdcToWeth_QuoteIsExecution() public {
        if (!_fork()) return;
        _run(4, TWO_FACTORY, FX_V210D_USDC_WETH, USDC, WETH, 10e6);
    }

    function testFork_CryptoNG_Base_Tricrypto_TopToSnl_QuoteIsExecution() public {
        if (!_fork()) return;
        _run(5, TRI_FACTORY, TRI_SNL_TOP_BCOW, TOP, SNL, 1e18);
    }

    /// The live native-enabled tricrypto answers WETH20(): refused at resolve (code 4).
    function testFork_CryptoNG_Base_NativeTricryptoRefused() public {
        if (!_fork()) return;
        BlazePhoenixAdapterCurveCryptoNG a = new BlazePhoenixAdapterCurveCryptoNG(address(gate), TRI_FACTORY);
        _accept(5, address(a));
        vm.expectRevert(_aerr(4));
        gate.create(CRVUSD, WETH, uint24(5) << 16 | 1, abi.encode(TRI_WETH_CRVUSD_TBTC));
    }

    /// A real crypto NG pool, but of the other factory: the twocrypto factory's record of a
    /// tricrypto pool is all zeros (code 2), whatever the pool itself says.
    function testFork_CryptoNG_Base_PoolOfAnotherFactoryRefused() public {
        if (!_fork()) return;
        BlazePhoenixAdapterCurveCryptoNG a = new BlazePhoenixAdapterCurveCryptoNG(address(gate), TWO_FACTORY);
        _accept(4, address(a));
        vm.expectRevert(_aerr(2));
        gate.create(TOP, SNL, uint24(4) << 16 | 1, abi.encode(TRI_SNL_TOP_BCOW));
    }
}
