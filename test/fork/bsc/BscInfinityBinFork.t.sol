// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {AdapterHarness} from "../../adapters/AdapterHarness.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";
import {BlazePhoenixGate, BlazePhoenixGateWrapper} from "../../../src/BlazePhoenixGate.sol";
import {IInfinityVault} from "../../../src/adapters/BlazePhoenixAdapterInfinityCL.sol";
import {
    BlazePhoenixAdapterInfinityBin, IInfinityBinPoolManager
} from "../../../src/adapters/BlazePhoenixAdapterInfinityBin.sol";

/// The Infinity Bin adapter against the live PancakeSwap Infinity on BSC, at the block of every BSC
/// fork test (BscForkBase.FORK_BLOCK), through the Gate's real wrapper. ERC-20 pairs only. Two pools
/// without hooks from the explorer's list of 2026-11-06, each read back from the manager's own
/// poolIdToPoolKey at the block: the largest ERC-20 Bin pool, lisUSD/USD1 (bin step 5), and
/// USDT/USDC (bin step 1). The list's one Bin pool under a hook is native BNB with a dynamic fee,
/// outside v1, so the hooks rule is the unit suite's alone. Skipped when BSC_FORK_URL is unset.
contract BscInfinityBinFork is AdapterHarness {
    uint256 internal constant FORK_BLOCK = 131_960_000;
    address internal constant VAULT = 0x238a358808379702088667322f80aC48bAd5e6c4;
    address internal constant BIN = 0xC697d2898e0D09264376196696c51D7aBbbAA4a9;
    address internal constant LISUSD = 0x0782b6d8c4551B9760e74c0545a9bCD90bdc41E5;
    address internal constant USD1 = 0x8d0D000Ee44948FC98c9B98A4FA4921476f08B0d;
    address internal constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address internal constant USDC = 0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d;
    bytes32 internal constant LISUSD_USD1_67 = 0x87a668dbac7951c7a5ccd91c4c817da7de4f32bdc714c58eacc376eb41b64ee4;
    bytes32 internal constant USDT_USDC_67 = 0xa859b22e97f32d4c7b1d9788044697712cb7183d294ed7aa1832799c1739e5cf;
    uint24 internal constant LISUSD_USD1_ACTIVE = 8_388_606;
    uint8 internal constant FAM = 7;
    uint24 internal constant KEY = uint24(FAM) << 16 | 1;

    BlazePhoenixAdapterInfinityBin internal a;

    function _fork() internal returns (bool) {
        string memory u = vm.envOr("BSC_FORK_URL", string(""));
        if (bytes(u).length == 0) { vm.skip(true); return false; }
        vm.createSelectFork(u, FORK_BLOCK);
        gate = new BlazePhoenixGate(address(this));
        a = new BlazePhoenixAdapterInfinityBin(address(gate), BIN, [address(0), address(0), address(0)]);
        _accept(FAM, address(a));
        return true;
    }

    function _wrapper(bytes32 id, address x, address y) internal returns (address) {
        (t0, t1) = x < y ? (MockERC20(x), MockERC20(y)) : (MockERC20(y), MockERC20(x));
        return gate.create(address(t0), address(t1), KEY, abi.encode(id));
    }

    /// The harness's swap, funded by `deal` instead of a mint.
    function _swapReal(address w, bool zeroForOne, uint256 amt) internal returns (uint256 out) {
        (address tIn, address tOut) = zeroForOne ? (address(t0), address(t1)) : (address(t1), address(t0));
        deal(tIn, address(this), amt);
        uint256 b = MockERC20(tOut).balanceOf(address(this));
        BlazePhoenixGateWrapper(w).swap(address(this), zeroForOne, int256(amt), 0, "");
        out = MockERC20(tOut).balanceOf(address(this)) - b;
    }

    /// quoteCall, then the swap from the same state: they must agree to the wei, the Vault ends
    /// with no locker, nothing is left with the adapter or the wrapper.
    function _quoteIsExecution(bytes32 id, address tIn, address tOut, uint256 amt) internal {
        address w = _wrapper(id, tIn, tOut);
        bool z = tIn == address(t0);
        uint256 snap = vm.snapshotState();
        uint256 q = BlazePhoenixGateWrapper(w).quoteCall(z, amt);
        vm.revertToState(snap);
        assertGt(q, 0, "the live pool quotes");
        assertEq(_swapReal(w, z, amt), q, "quoteCall is the execution, to the wei");
        assertEq(IInfinityVault(VAULT).getLocker(), address(0), "the Vault is released");
        _assertEmpty(address(a), w, VAULT);
    }

    function _active(bytes32 id) internal view returns (uint24 active) {
        (active,,) = IInfinityBinPoolManager(BIN).getSlot0(id);
    }

    /// lisUSD in (swapForY): the active bin holds 1 wei of USD1 at the block, so the swap crosses
    /// into the bins below it.
    function testFork_InfBin_Bsc_LisUsdToUsd1_CrossesBins_QuoteCallIsExecution() public {
        if (!_fork()) return;
        _quoteIsExecution(LISUSD_USD1_67, LISUSD, USD1, 100e18);
        assertLt(_active(LISUSD_USD1_67), LISUSD_USD1_ACTIVE, "the swap left the block's active bin");
    }

    /// USD1 in: 100 USD1 against the 5,323.9 lisUSD of the active bin, a swap inside one bin.
    function testFork_InfBin_Bsc_Usd1ToLisUsd_InsideTheActiveBin_QuoteCallIsExecution() public {
        if (!_fork()) return;
        _quoteIsExecution(LISUSD_USD1_67, USD1, LISUSD, 100e18);
        assertEq(_active(LISUSD_USD1_67), LISUSD_USD1_ACTIVE, "the swap stayed in the active bin");
    }

    /// USDC in, USDC the Bin's Y (swapForY false), on the other pool and bin step.
    function testFork_InfBin_Bsc_UsdcToUsdt_QuoteCallIsExecution() public {
        if (!_fork()) return;
        _quoteIsExecution(USDT_USDC_67, USDC, USDT, 10e18);
    }

    /// A Bin exact-in the pool cannot fill reverts in the venue (BinPool__OutOfLiquidity, no partial
    /// fill): no quote, and the exec reverts with the venue's error. 10^12 USD1 against the pool's
    /// lisUSD (75,295 in the explorer's list of 2026-11-06).
    function testFork_InfBin_Bsc_PastThePool_NoQuote_ExecRevertsOutOfLiquidity() public {
        if (!_fork()) return;
        address w = _wrapper(LISUSD_USD1_67, USD1, LISUSD);
        bool z = address(t0) == USD1;
        assertGt(BlazePhoenixGateWrapper(w).quoteCall(z, 100e18), 0, "control: 100 USD1 quotes");
        assertEq(BlazePhoenixGateWrapper(w).quoteCall(z, 1e30), 0, "past the pool: no quote");
        deal(USD1, address(this), 1e30);
        vm.expectRevert(bytes4(0x96aa65ad)); // BinPool__OutOfLiquidity()
        BlazePhoenixGateWrapper(w).swap(address(this), z, int256(1e30), 0, "");
    }

    /// The live records the adapter reads: each key names this manager, no hooks, an empty bitmap,
    /// a static fee, its own bin step; the manager's vault() is the CL manager's Vault.
    function testFork_InfBin_Bsc_LiveKeys_TheCLsVault() public {
        if (!_fork()) return;
        assertEq(address(a.VAULT()), VAULT, "the Bin manager's vault() is the CL's Vault");
        bytes32[2] memory ids = [LISUSD_USD1_67, USDT_USDC_67];
        uint256[2] memory steps = [uint256(5), 1];
        for (uint256 k; k < 2; ++k) {
            (,, address h, address pm, uint24 fee, bytes32 params) = IInfinityBinPoolManager(BIN).poolIdToPoolKey(ids[k]);
            assertEq(h, address(0), "no hooks");
            assertEq(pm, BIN, "the pool's manager");
            assertEq(uint256(params) & 0xffff, 0, "empty bitmap");
            assertEq(uint256(params) >> 16 & 0xffff, steps[k], "the bin step");
            assertEq(fee, 67, "a static fee");
        }
    }

    function _cold(address w) internal view returns (address[] memory c) {
        c = new address[](7);
        (c[0], c[1], c[2], c[3], c[4], c[5], c[6]) = (w, address(gate), address(a), VAULT, BIN, address(t0), address(t1));
    }

    /// The Quoter's arm against the live venue: GATE_QUOTE_GAS is enough for a swap that crosses bins.
    function testFork_InfBin_Bsc_GateQuoteGas_LisUsdToUsd1_CrossesBins() public {
        if (!_fork()) return;
        address w = _wrapper(LISUSD_USD1_67, LISUSD, USD1);
        _armUnderCap(w, address(t0) == LISUSD, 100e18, _cold(w));
    }

    /// depth18 against the live Vault: outside a lock, the shorter side of the active bin's
    /// reserves (both tokens in 18 decimals), the two reads pinned at FORK_BLOCK; inside a lock
    /// this contract holds, none.
    uint256 internal _dInside;
    bool internal _ran;

    function testFork_InfBin_Bsc_Depth18_ActiveBinShortSide_ZeroInsideALock() public {
        if (!_fork()) return;
        address w = _wrapper(USDT_USDC_67, USDT, USDC);
        (uint256 o, uint256 d) = BlazePhoenixGateWrapper(w).quote(true, 100e18);
        uint24 active = _active(USDT_USDC_67);
        (uint128 rx, uint128 ry,,) = IInfinityBinPoolManager(BIN).getBin(USDT_USDC_67, active);
        assertEq(o, 0, "a Bin leg is priced only by quoteCall");
        assertEq(active, 8_388_597, "live activeId at FORK_BLOCK");
        assertEq(rx, 122_579_200_891_544_301_848, "live USDT in the active bin");
        assertEq(ry, 1_088_629_554_108_030_913, "live USDC in the active bin");
        assertEq(d, 1_088_629_554_108_030_913, "depth18: the shorter side, USDC's");
        IInfinityVault(VAULT).lock(abi.encode(w));
        assertTrue(_ran, "anti-vacuity: the read ran inside the live Vault's lock");
        assertEq(_dInside, 0, "no depth while the Vault has a locker");
    }

    /// The largest ERC-20 Bin pool at the block: its active bin holds 5,323.9 lisUSD and 1 wei of
    /// USD1 (the pool: 75,295 lisUSD and 125,806 USD1 in the explorer's list of 2026-11-06), so the
    /// depth this adapter declares, the active bin's shorter side, is 1 wei.
    function testFork_InfBin_Bsc_Depth18_LargestPool_ActiveBinShortSideIsOneWei() public {
        if (!_fork()) return;
        address w = _wrapper(LISUSD_USD1_67, LISUSD, USD1);
        (uint128 rx, uint128 ry,,) = IInfinityBinPoolManager(BIN).getBin(LISUSD_USD1_67, _active(LISUSD_USD1_67));
        assertEq(_active(LISUSD_USD1_67), LISUSD_USD1_ACTIVE, "live activeId at FORK_BLOCK");
        assertEq(rx, 5_323_914_580_517_545_983_808, "live lisUSD in the active bin");
        assertEq(ry, 1, "live USD1 in the active bin: 1 wei");
        (, uint256 d) = BlazePhoenixGateWrapper(w).quote(true, 100e18);
        assertEq(d, 1, "depth18 of the largest ERC-20 Bin pool: 1 wei");
    }

    function lockAcquired(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == VAULT);
        (, _dInside) = BlazePhoenixGateWrapper(abi.decode(data, (address))).quote(true, 100e18);
        _ran = true;
        return "";
    }
}
