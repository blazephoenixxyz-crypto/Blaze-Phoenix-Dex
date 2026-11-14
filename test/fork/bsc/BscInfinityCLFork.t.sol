// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {AdapterHarness} from "../../adapters/AdapterHarness.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";
import {BlazePhoenixGate, BlazePhoenixGateWrapper} from "../../../src/BlazePhoenixGate.sol";
import {
    BlazePhoenixAdapterInfinityCL, IInfinityCLPoolManager, IInfinityVault
} from "../../../src/adapters/BlazePhoenixAdapterInfinityCL.sol";
import {InfinityCLPinProbe} from "../../adapters/mocks/InfinityPinProbes.sol";

interface IHooksBitmap {
    function getHooksRegistrationBitmap() external view returns (uint16);
}

/// The Infinity CL adapter against the live PancakeSwap Infinity on BSC, at the block of every BSC
/// fork test (BscForkBase.FORK_BLOCK), through the Gate's real wrapper. ERC-20 pairs only. Three
/// pools from the explorer's list of 2026-11-06, each read back from the manager's own
/// poolIdToPoolKey at the block: the largest one without hooks, and the largest one under each of
/// the two hooks this adapter pins here (bitmap 69: beforeInitialize, beforeAddLiquidity,
/// beforeSwap). Skipped when BSC_FORK_URL is unset.
contract BscInfinityCLFork is AdapterHarness {
    uint256 internal constant FORK_BLOCK = 131_960_000;
    address internal constant VAULT = 0x238a358808379702088667322f80aC48bAd5e6c4;
    address internal constant CL = 0xa0FfB9c1CE1Fe56963B0321B32E7A0302114058b;
    address internal constant HOOK_B0BA = 0xb0BAa371b899950B4Ef6A27c21bAf5ef7c434d0f;
    address internal constant HOOK_B0BB = 0xb0bb171D333569CfD28a37F5c5DdDAAa90aD46af;
    address internal constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address internal constant U = 0xcE24439F2D9C6a2289F741120FE202248B666666;
    address internal constant DNA = 0xA991F61940095AEA0724ef54077223B048c5CF7b;
    address internal constant NES = 0x097acf27503753e77bCA940277806156C5925B81;
    bytes32 internal constant USDT_U_15 = 0x1e923c7179135a0c9ff76d0d8b1b75decf58f8a1ef5088320d8e743bdc043d6e;
    bytes32 internal constant USDT_DNA_67 = 0xd0949ad5874cee7991ccd4cc2c5f7f80a7be4a220689cf5947ccb12a946fa50d;
    bytes32 internal constant NES_USDT_67 = 0x24993d0e8ef738b3bac36a753c00b39793e416e05db87c2bafbb25c4351b34fd;
    uint8 internal constant FAM = 6;
    uint24 internal constant KEY = uint24(FAM) << 16 | 1;

    BlazePhoenixAdapterInfinityCL internal a;

    function _fork(address[3] memory pins) internal returns (bool) {
        string memory u = vm.envOr("BSC_FORK_URL", string(""));
        if (bytes(u).length == 0) { vm.skip(true); return false; }
        vm.createSelectFork(u, FORK_BLOCK);
        gate = new BlazePhoenixGate(address(this));
        a = new BlazePhoenixAdapterInfinityCL(address(gate), CL, pins);
        _accept(FAM, address(a));
        return true;
    }

    function _pins() internal pure returns (address[3] memory) { return [HOOK_B0BA, HOOK_B0BB, address(0)]; }

    function _pair(address x, address y) internal {
        (t0, t1) = x < y ? (MockERC20(x), MockERC20(y)) : (MockERC20(y), MockERC20(x));
    }

    /// The harness's swap, funded by `deal` instead of a mint.
    function _swapReal(address w, bool zeroForOne, uint256 amt) internal returns (uint256 out) {
        (address tIn, address tOut) = zeroForOne ? (address(t0), address(t1)) : (address(t1), address(t0));
        deal(tIn, address(this), amt);
        uint256 b = MockERC20(tOut).balanceOf(address(this));
        BlazePhoenixGateWrapper(w).swap(address(this), zeroForOne, int256(amt), 0, "");
        out = MockERC20(tOut).balanceOf(address(this)) - b;
    }

    /// quoteCall, then the swap from the same state and the same tx.origin (Infinity asks no eth_call
    /// context, and a hook may read the origin): they must agree to the wei,
    /// the Vault ends with no locker, nothing is left with the adapter or the wrapper.
    function _quoteIsExecution(bytes32 id, address x, address y, bool usdtIn, uint256 amt) internal {
        _pair(x, y);
        address w = gate.create(address(t0), address(t1), KEY, abi.encode(id));
        bool z = usdtIn == (address(t0) == USDT);
        uint256 snap = vm.snapshotState();
        uint256 q = BlazePhoenixGateWrapper(w).quoteCall(z, amt);
        vm.revertToState(snap);
        assertGt(q, 0, "the live pool quotes");
        assertEq(_swapReal(w, z, amt), q, "quoteCall is the execution, to the wei");
        assertEq(IInfinityVault(VAULT).getLocker(), address(0), "the Vault is released");
        _assertEmpty(address(a), w, VAULT);
    }

    function testFork_InfCL_Bsc_NoHooks_UsdtToU_QuoteCallIsExecution() public {
        if (!_fork(_pins())) return;
        _quoteIsExecution(USDT_U_15, USDT, U, true, 100e18);
    }

    function testFork_InfCL_Bsc_HookB0BA_UsdtToDna_QuoteCallIsExecution() public {
        if (!_fork(_pins())) return;
        _quoteIsExecution(USDT_DNA_67, USDT, DNA, true, 100e18);
    }

    function testFork_InfCL_Bsc_HookB0BB_UsdtToNes_QuoteCallIsExecution() public {
        if (!_fork(_pins())) return;
        _quoteIsExecution(NES_USDT_67, NES, USDT, true, 100e18);
    }

    /// The live records the adapter reads: the bitmap in the key's parameters is the hook's own
    /// registration (69 for both), the identity names this manager, and each hook's code is the
    /// codehash the adapter pinned.
    function testFork_InfCL_Bsc_LiveKeysAndPins() public {
        if (!_fork(_pins())) return;
        assertEq(address(a.VAULT()), VAULT, "the manager's vault() is the Vault");
        bytes32[2] memory ids = [USDT_DNA_67, NES_USDT_67];
        address[2] memory hs = [HOOK_B0BA, HOOK_B0BB];
        for (uint256 k; k < 2; ++k) {
            (,, address h, address pm,, bytes32 params) = IInfinityCLPoolManager(CL).poolIdToPoolKey(ids[k]);
            assertEq(h, hs[k], "the pool's hooks");
            assertEq(pm, CL, "the pool's manager");
            assertEq(uint256(params) & 0xffff, 69, "bitmap 69 in the key");
            assertEq(IHooksBitmap(h).getHooksRegistrationBitmap(), 69, "the hook registers 69");
        }
        (bytes32 c0, bytes32 c1,) = new InfinityCLPinProbe(address(gate), CL, _pins()).pins();
        assertEq(c0, HOOK_B0BA.codehash);
        assertEq(c1, HOOK_B0BB.codehash);
        assertTrue(HOOK_B0BA.codehash != HOOK_B0BB.codehash, "two codes, two pins");
    }

    /// An adapter that pins only 0xb0ba...: the 0xb0bb... pool is refused at resolve, by
    /// `_requireHookPinned` on the live hook's code.
    function testFork_InfCL_Bsc_UnpinnedLiveHookRefused() public {
        if (!_fork([HOOK_B0BA, address(0), address(0)])) return;
        _pair(NES, USDT);
        vm.expectRevert(_aerr(7));
        gate.create(address(t0), address(t1), KEY, abi.encode(NES_USDT_67));
    }

    /// The Quoter's arm against the live venue: GATE_QUOTE_GAS is enough, with the hook running.
    function _cold(address w) internal view returns (address[] memory c) {
        c = new address[](7);
        (c[0], c[1], c[2], c[3], c[4], c[5], c[6]) = (w, address(gate), address(a), VAULT, CL, address(t0), address(t1));
    }

    function testFork_InfCL_Bsc_GateQuoteGas_NoHooks_UsdtToU() public {
        if (!_fork(_pins())) return;
        _pair(USDT, U);
        address w = gate.create(address(t0), address(t1), KEY, abi.encode(USDT_U_15));
        _armUnderCap(w, address(t0) == USDT, 100e18, _cold(w));
    }

    function testFork_InfCL_Bsc_GateQuoteGas_HookB0BA_UsdtToDna() public {
        if (!_fork(_pins())) return;
        _pair(USDT, DNA);
        address w = gate.create(address(t0), address(t1), KEY, abi.encode(USDT_DNA_67));
        _armUnderCap(w, address(t0) == USDT, 100e18, _cold(w));
    }

    /// depth18 against the live Vault: outside a lock, depthFromL18 of the live liquidity at the
    /// live price; inside a lock this contract holds, none.
    uint256 internal _dInside;
    bool internal _ran;

    function testFork_InfCL_Bsc_Depth18_QuietOutside_ZeroInsideALock() public {
        if (!_fork(_pins())) return;
        _pair(USDT, U);
        address w = gate.create(address(t0), address(t1), KEY, abi.encode(USDT_U_15));
        (uint256 o, uint256 d) = BlazePhoenixGateWrapper(w).quote(true, 100e18);
        (uint160 sp,,,) = IInfinityCLPoolManager(CL).getSlot0(USDT_U_15);
        assertEq(o, 0, "a CL leg is priced only by quoteCall");
        assertGt(d, 0);
        // The oracle is not the Core's depthFromL18, the function under test: the two live reads are
        // pinned at FORK_BLOCK and the depth is derived from them off-chain. The virtual sides at the
        // price, floored: L * 2^96 / sp of USDT and L * sp / 2^96 of U, both tokens in 18 decimals;
        // the depth is the shorter one, U's (P < 1 at tick -6).
        assertEq(sp, 79207778552616586454630729555, "live sqrtPriceX96 at FORK_BLOCK");
        assertEq(IInfinityCLPoolManager(CL).getLiquidity(USDT_U_15), 1861814672722618875862458518, "live L");
        assertEq(d, 1861335661753796199613787866, "depth18: the shorter virtual side, U's");
        IInfinityVault(VAULT).lock(abi.encode(w));
        assertTrue(_ran, "anti-vacuity: the read ran inside the live Vault's lock");
        assertEq(_dInside, 0, "no depth while the Vault has a locker");
    }

    function lockAcquired(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == VAULT);
        (, _dInside) = BlazePhoenixGateWrapper(abi.decode(data, (address))).quote(true, 100e18);
        _ran = true;
        return "";
    }
}
