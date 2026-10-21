// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {AdapterHarness} from "../adapters/AdapterHarness.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {BlazePhoenixGate, BlazePhoenixGateWrapper} from "../adapters/vendor/BlazePhoenixGateSnapshot.sol";
import {BlazePhoenixAdapterCurveNG} from "../../src/adapters/BlazePhoenixAdapterCurveNG.sol";
import {BlazePhoenixAdapterBalancerV2} from "../../src/adapters/BlazePhoenixAdapterBalancerV2.sol";
import {BlazePhoenixAdapterBalancerV3} from "../../src/adapters/BlazePhoenixAdapterBalancerV3.sol";

/// The three adapters against the live venues on Base, behind the vendored Gate snapshot, at the
/// latest block of the public endpoint (no key: the `base` alias of foundry.toml). Skips, never
/// passes, when the fork cannot be opened.
/// Addresses: Curve NG factory and pools read from the factory itself (pool_list, get_coins,
/// get_pool_asset_types) on 21/10; Balancer Vaults and factories from balancer-deployments
/// addresses/base.json (master, 21/10); pool ids from the Balancer API, which is why each one
/// passes through the adapter's own `resolve` (the Vault and factory vouch on chain) before use.
contract AdaptersForkTest is AdapterHarness {
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant WETH = 0x4200000000000000000000000000000000000006;
    address internal constant CRVUSD = 0x417Ac0e078398C154EdFadD9Ef675d30Be60Af93;
    address internal constant OLAS = 0x54330d28ca3357F294334BDC454a032e7f353416;

    address internal constant NG_FACTORY = 0xd2002373543Ce3527023C75e7518C274A51ce712;
    address internal constant NG_USDC_CRVUSD = 0x3df1658e3E76d14eF3C4d410829EA7575bB83B9B; // pool_list(27)
    address internal constant NG_USDC_REBASING = 0x63Eb7846642630456707C3efBb50A03c79B89D81; // pool_list(0), types [0,2]

    address internal constant V2_VAULT = 0xBA12222222228d8Ba445958a75a0704d566BF2C8;
    address internal constant V2_WEIGHTED_V4 = 0x4C32a8a8fDa4E24139B51b456B42290f51d6A1c4;
    bytes32 internal constant V2_OLAS_USDC = 0x5332584890d6e415a6dc910254d6430b8aab7e69000200000000000000000103;

    address internal constant V3_VAULT = 0xbA1333333333a1BA1108E8412f11850A5C319bA9;
    address internal constant V3_WEIGHTED_V1 = 0x5cF4928a3205728bd12830E1840F7DB85c62a4B9;
    address internal constant V3_STABLE_SURGE_V1 = 0x4fb47126Fa83A8734991E41B942Ac29A3266C968;
    address internal constant V3_WEIGHTED_5 = 0x7b4c560f33A71A9f7a500aF3C4c65b46fBBafdB7; // weETH/WETH/DAI/OLAS/USDC, no hook
    address internal constant V3_SURGE_GHO_USDC = 0x7AB124EC4029316c2A42F713828ddf2a192B36db; // StableSurgeHook
    address internal constant WAGHO = 0x88b1Cd4b430D95b406E382C3cDBaE54697a0286E;
    address internal constant WAUSDC = 0xC768c589647798a6EE01A91FdE98EF2ed046DBD6;

    function _fork() internal returns (bool) {
        try vm.createSelectFork("base") {} catch { vm.skip(true); return false; }
        gate = new BlazePhoenixGate(address(this));
        return true;
    }

    function _pair(address a, address b) internal {
        (t0, t1) = a < b ? (MockERC20(a), MockERC20(b)) : (MockERC20(b), MockERC20(a));
    }

    /// The harness's swap, funded by `deal` instead of a mint.
    function _swapReal(address w, bool zeroForOne, uint256 amt) internal returns (uint256 out) {
        (address tIn, address tOut) = zeroForOne ? (address(t0), address(t1)) : (address(t1), address(t0));
        deal(tIn, address(this), amt);
        uint256 b = MockERC20(tOut).balanceOf(address(this));
        BlazePhoenixGateWrapper(w).swap(address(this), zeroForOne, int256(amt), 0, "");
        out = MockERC20(tOut).balanceOf(address(this)) - b;
    }

    function testFork_CurveNG_Base_UsdcToCrvUsd_QuoteIsExecution() public {
        if (!_fork()) return;
        _pair(USDC, CRVUSD);
        BlazePhoenixAdapterCurveNG a = new BlazePhoenixAdapterCurveNG(address(gate), NG_FACTORY);
        _accept(1, address(a));
        address w = gate.create(USDC, CRVUSD, uint24(1) << 16 | 1, abi.encode(NG_USDC_CRVUSD));
        bool z = address(t0) == USDC;
        uint256 q = a.quoteCall(w, z, 100e6);
        assertGt(q, 0);
        assertEq(_swapReal(w, z, 100e6), q, "get_dy == exchange_received on the same state");
        _assertEmpty(address(a), w, NG_USDC_CRVUSD);
    }

    function testFork_CurveNG_Base_RebasingPoolRefused() public {
        if (!_fork()) return;
        BlazePhoenixAdapterCurveNG a = new BlazePhoenixAdapterCurveNG(address(gate), NG_FACTORY);
        _accept(1, address(a));
        vm.expectRevert(_aerr(4));
        gate.create(USDC, 0x59D9356E565Ab3A36dD77763Fc0d87fEaf85508C, uint24(1) << 16 | 1, abi.encode(NG_USDC_REBASING));
    }

    function testFork_BalV2_Base_UsdcToOlas_QuoteCallIsExecution() public {
        if (!_fork()) return;
        _pair(USDC, OLAS);
        BlazePhoenixAdapterBalancerV2 a = new BlazePhoenixAdapterBalancerV2(
            address(gate), V2_VAULT, [V2_WEIGHTED_V4, address(0), address(0), address(0)]
        );
        _accept(2, address(a));
        address w = gate.create(USDC, OLAS, uint24(2) << 16 | 1, abi.encode(V2_OLAS_USDC));
        bool z = address(t0) == USDC;
        uint256 q = a.quoteCall(w, z, 50e6);
        assertGt(q, 0);
        assertEq(_swapReal(w, z, 50e6), q);
        _assertEmpty(address(a), w, V2_VAULT);
    }

    function testFork_BalV3_Base_WethToUsdc_HooklessWeighted() public {
        if (!_fork()) return;
        _pair(WETH, USDC);
        BlazePhoenixAdapterBalancerV3 a = new BlazePhoenixAdapterBalancerV3(
            address(gate), V3_VAULT, [V3_WEIGHTED_V1, address(0)], [bytes32(0), bytes32(0)]
        );
        _accept(3, address(a));
        address w = gate.create(WETH, USDC, uint24(3) << 16 | 1, abi.encode(V3_WEIGHTED_5));
        bool z = address(t0) == WETH;
        // The Vault's quote is eth_call only (tx.origin == 0) and does not roll its swap back: an
        // eth_call discards the state, a test call does not. Measured at block 52876687 without the
        // snapshot: exec 23380974 against quote 24165350, because the quote's swap had moved the pool.
        uint256 snap = vm.snapshotState();
        vm.prank(address(this), address(0));
        uint256 q = a.quoteCall(w, z, 0.01e18);
        vm.revertToState(snap);
        assertGt(q, 0);
        assertEq(_swapReal(w, z, 0.01e18), q);
        _assertEmpty(address(a), w, V3_VAULT);
    }

    function testFork_BalV3_Base_UnpinnedSurgeHookRefused() public {
        if (!_fork()) return;
        BlazePhoenixAdapterBalancerV3 a = new BlazePhoenixAdapterBalancerV3(
            address(gate), V3_VAULT, [V3_STABLE_SURGE_V1, address(0)], [bytes32(0), bytes32(0)]
        );
        _accept(3, address(a));
        vm.expectRevert(_aerr(7));
        gate.create(WAGHO, WAUSDC, uint24(3) << 16 | 1, abi.encode(V3_SURGE_GHO_USDC));
    }
}
