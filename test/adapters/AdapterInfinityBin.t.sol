// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {AdapterHarness} from "./AdapterHarness.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {BlazePhoenixGateWrapper} from "../../src/BlazePhoenixGate.sol";
import {IInfinityCLPoolManager} from "../../src/adapters/BlazePhoenixAdapterInfinityCL.sol";
import {BlazePhoenixAdapterInfinityBin, IInfinityBinPoolManager} from "../../src/adapters/BlazePhoenixAdapterInfinityBin.sol";
import {MockInfVault, MockInfBinPoolManager, PinnedHook, SecondHook, ForgingHook} from "./mocks/MockInfinity.sol";
import {MockERC20Dec} from "./mocks/MockERC20Dec.sol";
import {BlazePhoenixHub} from "../../src/BlazePhoenixHub.sol";
import {BlazePhoenixQuoter} from "../../src/BlazePhoenixQuoter.sol";
import {BlazePhoenixRouter} from "../../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../../src/BlazePhoenixCore.sol";

/// An unpinned hook whose beforeSwap works: the code a pinned hook's address may come to hold.
contract RogueBinHook { function beforeSwap(address) external {} }

/// PancakeSwap Infinity Bin adapter behind the real wrapper: SETTLE custody against a Vault- and
/// BinPoolManager-faithful mock (ERC-20 pairs only). Red at the stub commit (the ABI, no body).
contract AdapterInfinityBinTest is AdapterHarness {
    uint8 internal constant FAM = 7;
    uint24 internal constant KEY = uint24(FAM) << 16 | 1;
    uint24 internal constant FEE = 2500; // oracle: out = amt * 997_500 / 1_000_000
    uint24 internal constant ACTIVE = 2 ** 23; // the bin of price 1
    uint256 internal constant INT128_MAX = uint256(uint128(type(int128).max));

    MockInfVault internal vault;
    MockInfBinPoolManager internal bin;
    PinnedHook internal hook;
    SecondHook internal hook1;
    ForgingHook internal hook2;
    BlazePhoenixAdapterInfinityBin internal adapter;
    bytes32 internal id;
    address internal w;

    function setUp() public {
        _tokens();
        vault = new MockInfVault();
        bin = new MockInfBinPoolManager(address(vault));
        vault.registerApp(address(bin));
        hook = new PinnedHook();
        hook1 = new SecondHook();
        hook2 = new ForgingHook();
        t0.mint(address(vault), 1e24);
        t1.mint(address(vault), 1e24);
        adapter = new BlazePhoenixAdapterInfinityBin(address(gate), address(bin), [address(hook), address(hook1), address(hook2)]);
        _accept(FAM, address(adapter));
        id = _pool(address(0), 0, FEE);
        w = gate.create(address(t0), address(t1), KEY, abi.encode(id));
    }

    /// parameters: bin step at bit 16 (BinPoolParametersHelper.sol:16), the hooks bitmap in the low 16 bits.
    function _key(address c0, address c1, address h, uint16 bitmap, uint24 fee)
        internal view returns (IInfinityCLPoolManager.PoolKey memory)
    {
        return IInfinityCLPoolManager.PoolKey(c0, c1, h, address(bin), fee, bytes32(uint256(10) << 16 | bitmap));
    }

    /// Active bin: 600 X / 400 Y; the next bin: 0 X / 900 Y (a read of the wrong bin is seen).
    function _pool(address h, uint16 bitmap, uint24 fee) internal returns (bytes32 i) {
        i = bin.initialize(_key(address(t0), address(t1), h, bitmap, fee), ACTIVE);
        bin.setBin(i, ACTIVE, 600e18, 400e18);
        bin.setBin(i, ACTIVE + 1, 0, 900e18);
    }

    function _settled() internal view {
        assertEq(vault.getLocker(), address(0), "lock released");
        assertEq(vault.unsettled(), 0, "no delta left open");
    }

    function _out(uint256 amt) internal pure returns (uint256) { return amt * 997_500 / 1_000_000; }

    // ─── execution: swap exact-in, sync + transfer exactly + settle, the Vault pays the recipient ───

    function test_InfBin_Swap_RecipientPaidByVault_Settled_NothingLeft() public {
        assertEq(_swap(w, true, 10e18), _out(10e18));
        _assertEmpty(address(adapter), w, address(vault));
        _settled();
        assertEq(_swap(w, false, 4e18), _out(4e18));
        _assertEmpty(address(adapter), w, address(vault));
        _settled();
    }

    function testFuzz_InfBin_CustodyEmptyAfterEveryExec(uint96 amt, bool zeroForOne) public {
        amt = uint96(bound(amt, 1e6, 1e23)); // <= 10 % of the Vault's 1e24
        assertEq(_swap(w, zeroForOne, amt), _out(amt));
        _assertEmpty(address(adapter), w, address(vault));
        _settled();
    }

    function test_InfBin_NoApproveInItsBytecode() public view {
        assertFalse(_hasApproveSelector(address(adapter)));
    }

    /// The mock shares the adapter's interface, so only the upstream signatures can catch a drift
    /// (IBinPoolManager.sol:138,146,191; IPoolManager.sol:32). The Vault's are pinned by the CL suite.
    function test_InfBin_InterfaceSelectorsEqualTheVenues() public pure {
        assertEq(
            bytes32(IInfinityBinPoolManager.swap.selector),
            bytes32(bytes4(keccak256("swap((address,address,address,address,uint24,bytes32),bool,int128,bytes)")))
        );
        assertEq(bytes32(IInfinityBinPoolManager.poolIdToPoolKey.selector), bytes32(bytes4(keccak256("poolIdToPoolKey(bytes32)"))));
        assertEq(bytes32(IInfinityBinPoolManager.getSlot0.selector), bytes32(bytes4(keccak256("getSlot0(bytes32)"))));
        assertEq(bytes32(IInfinityBinPoolManager.getBin.selector), bytes32(bytes4(keccak256("getBin(bytes32,uint24)"))));
        assertEq(bytes32(IInfinityBinPoolManager.vault.selector), bytes32(bytes4(keccak256("vault()"))));
    }

    function test_InfBin_QuoteCallEqualsExecution_QuoteIsZero() public {
        bin.setRate(id, true, 0.9e18); // X->Y prices apart: a reversed direction is seen
        (uint256 q, ) = BlazePhoenixGateWrapper(w).quote(false, 6e18);
        assertEq(q, 0, "no view quote");
        uint256 qc = BlazePhoenixGateWrapper(w).quoteCall(false, 6e18);
        assertEq(qc, _out(6e18), "quoteCall prices t1->t0");
        _settled();
        assertEq(_swap(w, false, 6e18), qc);
        uint256 qc1 = BlazePhoenixGateWrapper(w).quoteCall(true, 6e18);
        assertEq(qc1, _out(6e18) * 0.9e18 / 1e18, "quoteCall prices t0->t1");
        assertEq(_swap(w, true, 6e18), qc1);
    }

    /// The input paid is this call's amtIn: neither a donation the Vault never synced nor dust
    /// sitting in the adapter is counted.
    function test_InfBin_StrayBalances_DoNotBreakSettle() public {
        t0.mint(address(vault), 1);
        t0.mint(address(adapter), 1);
        assertEq(_swap(w, true, 2e18), _out(2e18));
        _settled();
        assertEq(t0.balanceOf(address(adapter)), 1, "the dust stays where it was");
    }

    /// A Bin exact-in that the bins cannot fill reverts in the venue (no partial fill): no quote,
    /// and the exec reverts with the venue's error.
    function test_InfBin_OutOfLiquidity_NoQuote_ExecReverts() public {
        bin.setMaxIn(id, 1e18);
        assertEq(BlazePhoenixGateWrapper(w).quoteCall(true, 1e18), _out(1e18), "control: what the bins hold");
        assertEq(BlazePhoenixGateWrapper(w).quoteCall(true, 1e18 + 1), 0, "one wei past the bins: no quote");
        t0.mint(address(this), 2e18);
        vm.expectRevert(MockInfBinPoolManager.BinPool__OutOfLiquidity.selector);
        BlazePhoenixGateWrapper(w).swap(address(this), true, 2e18, 0, "");
    }

    /// The venue takes the input as an int128: the largest one reaches it, one wei more is refused
    /// by the adapter (AdapterE(9)), at quoteCall and at exec, and is never truncated.
    function test_InfBin_AmountPastInt128_Refused() public {
        assertEq(BlazePhoenixGateWrapper(w).quoteCall(true, INT128_MAX), _out(INT128_MAX), "int128 max reaches the venue");
        assertEq(BlazePhoenixGateWrapper(w).quoteCall(true, INT128_MAX + 1), 0, "past it: no quote");
        vm.prank(w);
        vm.expectRevert(_aerr(9));
        adapter.quoteCall(address(vault), id, bytes32(0), true, INT128_MAX + 1);
        t0.mint(address(this), INT128_MAX + 1);
        vm.expectRevert(_aerr(9));
        BlazePhoenixGateWrapper(w).swap(address(this), true, int256(INT128_MAX + 1), 0, "");
    }

    /// Past 2^128 the cast to int128 keeps the low 128 bits: 2^128 + 1e18 would reach the venue
    /// as 1e18, an ordinary amount. Refused (AdapterE(9)) at quoteCall and at exec all the same.
    function test_InfBin_AmountPast2Pow128_RefusedNotTruncated() public {
        uint256 amt = (uint256(1) << 128) + 1e18;
        assertEq(int256(int128(int256(amt))), 1e18, "anti-vacuity: its low 128 bits are 1e18");
        assertEq(BlazePhoenixGateWrapper(w).quoteCall(true, amt), 0, "no quote");
        vm.prank(w);
        vm.expectRevert(_aerr(9));
        adapter.quoteCall(address(vault), id, bytes32(0), true, amt);
        t0.mint(address(this), amt);
        vm.expectRevert(_aerr(9));
        BlazePhoenixGateWrapper(w).swap(address(this), true, int256(amt), 0, "");
    }

    // ─── hostile callers of the callback (SETTLE: the lock's deltas are the locker's) ───

    /// A payload the callback would act on: 1e18 of t0 swapped in the plain pool, the output paid
    /// by the Vault to `thief`. 384 bytes, the length of the adapter's own, so a probe carrying it
    /// is refused by the guard's sender or `_inExec` half and by nothing else.
    function _steal(address thief) internal view returns (bytes memory) {
        return abi.encode(
            false, _key(address(t0), address(t1), address(0), 0, FEE), true, uint256(1e18), address(t0), address(t1), thief
        );
    }

    function test_InfBin_LockAcquiredFromNonVault_Refused() public {
        address thief = makeAddr("thief");
        assertEq(_steal(thief).length, 384, "anti-vacuity: a payload of the real length");
        t0.mint(address(adapter), 1e18); // the bait
        vm.expectRevert(_aerr(6));
        adapter.lockAcquired(_steal(thief));
        // From inside the adapter's own exec: a pinned hook calling the callback mid-swap.
        bytes32 hid = _pool(address(hook), 69, FEE);
        address w2 = gate.create(address(t0), address(t1), KEY + 1, abi.encode(hid));
        hook.arm(address(adapter), abi.encodeCall(adapter.lockAcquired, (_steal(thief))));
        assertEq(_swap(w2, true, 1e18), _out(1e18));
        assertEq(hook.calls(), 1, "anti-vacuity: the hook ran inside the exec");
        assertFalse(hook.lastOk(), "the callback refused the hook");
        assertEq(hook.lastRet(), _aerr(6));
        assertEq(t1.balanceOf(thief), 0, "nothing reached the thief");
        assertEq(t0.balanceOf(address(adapter)), 1e18, "the bait stayed where it was");
    }

    /// Defence in depth, as in the CL suite: the mock's `poke` is a Vault that calls back out of
    /// turn, so these pin the `_inExec` half of the guard, not a path the live Vault offers.
    function test_InfBin_VaultCallbackOutsideOwnExec_Refused() public {
        address thief = makeAddr("thief");
        t0.mint(address(adapter), 1e18); // something to steal, were the callback open
        vm.expectRevert(_aerr(6));
        vault.poke(address(adapter), abi.encodeCall(adapter.lockAcquired, (_steal(thief))));
        assertEq(t1.balanceOf(thief), 0, "nothing reached the thief");
        assertEq(t0.balanceOf(address(adapter)), 1e18, "the bait stayed where it was");
    }

    /// The flag is cleared when the exec (or the quoteCall) returns; both run in one call frame of
    /// the test with the callback after them, one transaction whether or not calls are isolated.
    function test_InfBin_VaultCallbackAfterOwnExec_Refused() public { this.runThenPoke(true); }

    function test_InfBin_VaultCallbackAfterOwnQuoteCall_Refused() public { this.runThenPoke(false); }

    function runThenPoke(bool exec) external {
        require(msg.sender == address(this), "test only");
        if (exec) {
            assertEq(_swap(w, true, 1e18), _out(1e18), "the exec ran");
        } else {
            assertEq(BlazePhoenixGateWrapper(w).quoteCall(true, 1e18), _out(1e18), "the quoteCall ran");
            _settled();
        }
        address thief = makeAddr("thief");
        t0.mint(address(adapter), 1e18);
        bytes memory steal = abi.encode(
            false, _key(address(t0), address(t1), address(0), 0, FEE), true, uint256(1e18), address(t0), address(t1), thief
        );
        vm.expectRevert(_aerr(6));
        vault.poke(address(adapter), abi.encodeCall(adapter.lockAcquired, (steal)));
        assertEq(t1.balanceOf(thief), 0, "nothing reached the thief");
        assertEq(t0.balanceOf(address(adapter)), 1e18, "the bait stayed where it was");
    }

    function test_InfBin_ExecFromNonWrapper_Refused() public {
        t0.mint(address(adapter), 1e18);
        vm.expectRevert(_aerr(1));
        adapter.exec(address(vault), id, bytes32(0), true, 1e18, address(this));
    }

    function test_InfBin_QuoteCallFromNonWrapper_Refused() public {
        vm.expectRevert(_aerr(1));
        adapter.quoteCall(address(vault), id, bytes32(0), true, 1e18);
    }

    // ─── identity at resolve: the Bin manager's own record of the id ───

    function test_InfBin_Resolve_UnknownPoolId_Refused() public {
        vm.expectRevert(_aerr(2));
        gate.create(address(t0), address(t1), KEY + 1, abi.encode(keccak256("no such pool")));
    }

    /// A key recorded under another manager (the CL manager of the same Vault, say) is not a Bin pool.
    function test_InfBin_Resolve_KeyOfAnotherManager_Refused() public {
        IInfinityCLPoolManager.PoolKey memory k = _key(address(t0), address(t1), address(0), 0, FEE);
        k.poolManager = makeAddr("CL manager");
        bytes32 xid = bin.initialize(k, ACTIVE);
        vm.expectRevert(_aerr(2));
        gate.create(address(t0), address(t1), KEY + 1, abi.encode(xid));
    }

    function test_InfBin_Resolve_EachSideOfThePair_RefusedAlone() public {
        address lo = address(uint160(address(t1)) - 1); // the pool (lo, t1): only currency0 differs
        address hi = address(uint160(address(t0)) + 1); // the pool (t0, hi): only currency1 differs
        assertTrue(lo != address(t0) && hi != address(t1), "fixture: t0 and t1 are not adjacent");
        bytes32 i0 = bin.initialize(_key(lo, address(t1), address(0), 0, FEE), ACTIVE);
        bytes32 i1 = bin.initialize(_key(address(t0), hi, address(0), 0, FEE), ACTIVE);
        vm.expectRevert(_aerr(3));
        gate.create(address(t0), address(t1), KEY + 1, abi.encode(i0));
        vm.expectRevert(_aerr(3));
        gate.create(address(t0), address(t1), KEY + 2, abi.encode(i1));
    }

    function test_InfBin_Resolve_MalformedHint_Refused() public {
        vm.expectRevert(_aerr(8));
        gate.create(address(t0), address(t1), KEY + 1, abi.encodePacked(bytes20(id)));
        vm.expectRevert(_aerr(8));
        gate.create(address(t0), address(t1), KEY + 1, abi.encodePacked(id, uint8(0)));
    }

    function test_InfBin_Resolve_Aux0IsThePoolId_VenueIsTheVault() public view {
        assertEq(BlazePhoenixGateWrapper(w).venuePool(), address(vault), "the Vault holds the tokens");
        assertEq(BlazePhoenixGateWrapper(w).aux0(), id);
    }

    // ─── hooks at resolve (IBinHooks bits 7, 10, 11; dynamic fee); the pin again at exec and quoteCall ───
    // `_requireHookPinned` (SHARED_QUANTITIES): none, or code with one of the three pinned codehashes.

    function _refused(address h, uint16 bitmap, uint24 fee) internal {
        bytes32 hid = _pool(h, bitmap, fee);
        vm.expectRevert(_aerr(7));
        gate.create(address(t0), address(t1), KEY + 1, abi.encode(hid));
    }

    function test_InfBin_Resolve_UnpinnedHook_Refused() public { _refused(address(new RogueBinHook()), 69, FEE); }
    function test_InfBin_Resolve_HookBitAfterSwap_Refused() public { _refused(address(hook), 69 | 1 << 7, FEE); }
    function test_InfBin_Resolve_BitBeforeSwapReturnsDelta_Refused() public { _refused(address(hook), 69 | 1 << 10, FEE); }
    function test_InfBin_Resolve_BitAfterSwapReturnsDelta_Refused() public { _refused(address(hook), 69 | 1 << 11, FEE); }
    function test_InfBin_Resolve_DynamicFee_Refused() public { _refused(address(hook), 69, 0x800000); }

    /// An address without code has codehash 0, which an empty pin slot also holds.
    function test_InfBin_Resolve_HookWithoutCode_Refused() public {
        BlazePhoenixAdapterInfinityBin a2 =
            new BlazePhoenixAdapterInfinityBin(address(gate), address(bin), [address(hook), address(0), address(0)]);
        _accept(FAM + 1, address(a2));
        bytes32 hid = _pool(address(0xDEAD), 69, FEE);
        vm.expectRevert(_aerr(7));
        gate.create(address(t0), address(t1), uint24(FAM + 1) << 16 | 1, abi.encode(hid));
    }

    function test_InfBin_Resolve_PinnedHookBitmaps69And85_Accepted() public {
        bytes32 h69 = _pool(address(hook), 69, FEE);
        bytes32 h85 = _pool(address(hook), 85, FEE);
        address w69 = gate.create(address(t0), address(t1), KEY + 1, abi.encode(h69));
        address w85 = gate.create(address(t0), address(t1), KEY + 2, abi.encode(h85));
        assertEq(BlazePhoenixGateWrapper(w69).aux0(), h69);
        assertEq(BlazePhoenixGateWrapper(w85).aux0(), h85);
        assertEq(_swap(w85, true, 1e18), _out(1e18));
        assertEq(hook.calls(), 1, "the pinned hook ran");
    }

    function test_InfBin_Resolve_SecondAndThirdPinSlotsCount() public {
        bytes32 i1 = _pool(address(hook1), 69, FEE);
        bytes32 i2 = _pool(address(hook2), 69, FEE);
        address w1 = gate.create(address(t0), address(t1), KEY + 1, abi.encode(i1));
        address w2 = gate.create(address(t0), address(t1), KEY + 2, abi.encode(i2));
        assertEq(BlazePhoenixGateWrapper(w2).aux0(), i2);
        assertEq(_swap(w1, true, 1e18), _out(1e18));
        assertEq(hook1.calls(), 2, "the second pinned hook ran");
    }

    function test_InfBin_PinnedHook_Runs_ThenCodeChanges_ExecRefused() public {
        bytes32 hid = _pool(address(hook), 69, FEE);
        address w2 = gate.create(address(t0), address(t1), KEY + 1, abi.encode(hid));
        assertEq(_swap(w2, true, 1e18), _out(1e18));
        assertEq(hook.calls(), 1, "anti-vacuity: the pinned hook ran in the swap");
        vm.etch(address(hook), address(new RogueBinHook()).code);
        assertEq(BlazePhoenixGateWrapper(w2).quoteCall(true, 1e18), 0, "quoteCall re-checks the pin");
        t0.mint(address(this), 1e18);
        vm.expectRevert(_aerr(7));
        BlazePhoenixGateWrapper(w2).swap(address(this), true, 1e18, 0, "");
    }

    /// Only the adapter's own path produces QuoteOut: a hook reverting with that payload reaches
    /// the adapter inside the manager's ERC-7751 envelope and is reported as QuoteSwapFailed.
    function test_InfBin_QuoteCall_HookForgingTheOut_NotRead() public {
        bytes32 fid = _pool(address(hook2), 69, FEE);
        address wf = gate.create(address(t0), address(t1), KEY + 1, abi.encode(fid));
        assertEq(BlazePhoenixGateWrapper(wf).quoteCall(true, 1e18), 0, "the forged out is not a quote");
        bytes memory forged = abi.encodeWithSelector(BlazePhoenixAdapterInfinityBin.QuoteOut.selector, uint256(1e30));
        bytes memory wrapped = abi.encodeWithSelector(
            MockInfBinPoolManager.WrappedError.selector, address(hook2), ForgingHook.beforeSwap.selector, forged,
            abi.encodePacked(MockInfBinPoolManager.HookCallFailed.selector)
        );
        vm.prank(wf);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixAdapterInfinityBin.QuoteSwapFailed.selector, wrapped));
        adapter.quoteCall(address(vault), fid, bytes32(0), true, 1e18);
    }

    /// The same forgery with no envelope (the mock's switch; the live manager wraps a hook's
    /// revert): the bare QuoteOut leaves the venue's swap, and the adapter's own catch still
    /// reports it as QuoteSwapFailed, never as an output.
    function test_InfBin_QuoteCall_RawForgedOutFromTheManager_NotRead() public {
        bytes32 fid = _pool(address(hook2), 69, FEE);
        address wf = gate.create(address(t0), address(t1), KEY + 1, abi.encode(fid));
        bin.setRawHookRevert(true);
        bytes memory forged = abi.encodeWithSelector(BlazePhoenixAdapterInfinityBin.QuoteOut.selector, uint256(1e30));
        vm.expectRevert(forged); // anti-vacuity: the venue's swap reverts with the bare 36 bytes
        bin.swap(_key(address(t0), address(t1), address(hook2), 69, FEE), true, -1e18, "");
        assertEq(BlazePhoenixGateWrapper(wf).quoteCall(true, 1e18), 0, "the forged out is not a quote");
        vm.prank(wf);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixAdapterInfinityBin.QuoteSwapFailed.selector, forged));
        adapter.quoteCall(address(vault), fid, bytes32(0), true, 1e18);
    }

    // ─── construction ───

    function test_InfBin_Constructor_VaultIsTheManagersVault() public view {
        assertEq(address(adapter.VAULT()), address(vault));
        assertEq(address(adapter.BIN_MANAGER()), address(bin));
    }

    function test_InfBin_Constructor_PinsAreTheRefHooksCodehash() public {
        assertEq(adapter.HOOK_CODEHASH0(), address(hook).codehash);
        assertEq(adapter.HOOK_CODEHASH1(), address(hook1).codehash);
        assertEq(adapter.HOOK_CODEHASH2(), address(hook2).codehash);
        BlazePhoenixAdapterInfinityBin a2 =
            new BlazePhoenixAdapterInfinityBin(address(gate), address(bin), [address(hook), address(0), address(0)]);
        assertEq(a2.HOOK_CODEHASH1(), bytes32(0), "an empty slot pins nothing");
        assertEq(a2.HOOK_CODEHASH2(), bytes32(0), "an empty slot pins nothing");
    }

    function test_InfBin_Constructor_ZeroManager_Refused() public {
        vm.expectRevert(_aerr(0));
        new BlazePhoenixAdapterInfinityBin(address(gate), address(0), [address(hook), address(0), address(0)]);
    }

    function test_InfBin_Constructor_RefHookWithoutCode_Refused() public {
        vm.expectRevert(_aerr(0));
        new BlazePhoenixAdapterInfinityBin(address(gate), address(bin), [address(hook), address(0xDEAD), address(0)]);
    }

    // ─── depth18: the shorter side of the active bin, normalised (ExtAdapterBase._depth18) ───

    function test_InfBin_Depth18_IsTheActiveBinsShortSide() public {
        (, uint256 d) = BlazePhoenixGateWrapper(w).quote(true, 0);
        assertEq(d, 400e18, "active bin 600 X / 400 Y: the Y side");
        bin.setActiveId(id, ACTIVE + 1);
        bin.setBin(id, ACTIVE + 1, 700e18, 300e18);
        (, d) = BlazePhoenixGateWrapper(w).quote(false, 0);
        assertEq(d, 300e18, "the price moved one bin: the depth follows it");
    }

    function test_InfBin_Depth18_NormalisesDecimals() public {
        MockERC20Dec d6 = new MockERC20Dec(6);
        bool sixIsX = address(d6) < address(t0);
        (address c0, address c1) = sixIsX ? (address(d6), address(t0)) : (address(t0), address(d6));
        bytes32 i6 = bin.initialize(_key(c0, c1, address(0), 0, FEE), ACTIVE);
        (uint128 rx, uint128 ry) = sixIsX ? (uint128(500e6), uint128(800e18)) : (uint128(800e18), uint128(500e6));
        bin.setBin(i6, ACTIVE, rx, ry);
        address w6 = gate.create(address(d6), address(t0), KEY, abi.encode(i6));
        (, uint256 d) = BlazePhoenixGateWrapper(w6).quote(true, 0);
        assertEq(d, 500e18, "500 of the 6-decimal token, normalised, is the short side");
    }

    function test_InfBin_Depth18_ZeroWhileTheVaultIsLocked() public {
        vault.lock(abi.encode(uint256(0)));
        assertTrue(_lockRan, "anti-vacuity: read inside the lock");
        assertEq(_dLocked, 0, "locked: the adapter declares no depth");
        assertEq(_vLocked, 0, "locked: vitalOf reads no depth");
        (, uint256 d) = BlazePhoenixGateWrapper(w).quote(true, 0);
        assertEq(d, 400e18, "no locker again: the active bin's short side");
    }

    bool internal _lockRan;
    uint256 internal _dLocked;
    uint256 internal _vLocked;
    bool internal _lockQuotes;
    uint256 internal _qLocked;

    /// The Vault's lock callback, with this test as the locker.
    function lockAcquired(bytes calldata) external returns (bytes memory) {
        _lockRan = true;
        (, _dLocked) = BlazePhoenixGateWrapper(w).quote(true, 0);
        (, _vLocked, ) = gate.vitalOf(w);
        if (_lockQuotes) {
            _qLocked = BlazePhoenixGateWrapper(w).quoteCall(true, 1e18);
            vm.prank(w);
            vm.expectRevert(abi.encodeWithSelector(MockInfVault.LockerAlreadySet.selector, address(this)));
            adapter.quoteCall(address(vault), id, bytes32(0), true, 1e18);
        }
        return "";
    }

    /// A 36-byte revert that is not this adapter's QuoteOut is never read as an output: the
    /// Vault's LockerAlreadySet(address) while another contract holds the lock.
    function test_InfBin_QuoteCall_A36ByteRevertNotQuoteOut_IsNoQuote() public {
        assertEq(BlazePhoenixGateWrapper(w).quoteCall(true, 1e18), _out(1e18), "control: unlocked, the arm quotes");
        _lockQuotes = true;
        vault.lock(abi.encode(uint256(0)));
        assertTrue(_lockRan, "anti-vacuity: quoted inside another locker's lock");
        assertEq(_qLocked, 0, "LockerAlreadySet(address) has QuoteOut's length: not an out");
    }

    function test_InfBin_Depth18_OnlyForTheGatesWrapper() public {
        vm.expectRevert(_aerr(1));
        adapter.quote(address(vault), id, bytes32(0), true, 0);
    }

    /// The Quoter's kind-9 arm prices this leg under GATE_QUOTE_GAS, by quoteCall (the view says 0),
    /// at what the exec pays.
    function test_InfBin_QuoteArm_UnderGateQuoteGas() public {
        address[] memory cold = new address[](4);
        (cold[0], cold[1], cold[2], cold[3]) = (address(adapter), address(vault), address(bin), w);
        (uint256 out, , uint256 gQuoteCall) = _armUnderCap(w, true, 5e18, cold);
        assertEq(out, _out(5e18), "the arm's price is the exec's");
        assertGt(gQuoteCall, 0, "priced by quoteCall: the view answered 0");
    }

    // ─── the real Quoter and Router: the kind-9 route through this leg ───

    /// The arm above is a copy of the Quoter's; here the Quoter itself prices the route
    /// (previewRouteExact: Core.gateQuote, then dryQuoteCall under the Quoter's own cap when the
    /// view answers 0), every account cold as an eth_call starts, at the venue's price, and the
    /// real Router delivers what the Quoter promised, the Vault settled and no custody left.
    function test_InfBin_RealQuoterKind9Route_PricedAtTheVenue_RouterDeliversIt() public {
        (BlazePhoenixQuoter quoter, BlazePhoenixRouter router, BlazePhoenixHub hub) = _quoterAndRouter();
        uint256 amt = 5e18;
        (uint256 v, ) = BlazePhoenixGateWrapper(w).quote(true, amt);
        assertEq(v, 0, "setup: the view has no answer, the arm asks quoteCall");
        address[8] memory cold =
            [address(hub), address(gate), w, address(adapter), address(vault), address(bin), address(t0), address(t1)];
        for (uint256 k; k < cold.length; ++k) vm.cool(cold[k]);
        (Route memory q, uint256 exactOut) = quoter.previewRouteExact(_kind9Route(amt), amt);
        assertEq(q.hops[0].legs[0].expectedOut, _out(amt), "the Quoter prices the leg at the venue's price");
        assertGt(exactOut, 0, "a route to execute");
        _settled();
        address u = address(0xA11CE);
        t0.mint(u, amt);
        vm.startPrank(u);
        t0.approve(address(router), type(uint256).max);
        uint256 out = router.swapExactIn(q, amt, exactOut, u, block.timestamp + 1);
        vm.stopPrank();
        assertEq(out, exactOut, "quote == execution, through the real Router");
        assertEq(t1.balanceOf(u), out, "delivered to the user");
        _assertEmpty(address(adapter), w, address(vault));
        _settled();
    }

    /// A Hub that admits this Gate (its factory row, by which BPC.gateWrapperLive finds `w`), and
    /// the Quoter and the Router over it.
    function _quoterAndRouter() internal returns (BlazePhoenixQuoter quoter, BlazePhoenixRouter router, BlazePhoenixHub hub) {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0xBEEF));
        hub.setRoles(address(this), address(this), address(this));
        uint24[] memory fees = new uint24[](1);
        fees[0] = KEY;
        hub.addFactory(address(gate), BPC.KIND_EXTERNAL, 5, gate.WRAPPER_INIT_HASH(), fees, new int24[](0)); // 5: MODE_CREATE2_V3
        quoter = new BlazePhoenixQuoter(address(hub), address(0xD0D0));
        router = new BlazePhoenixRouter(address(hub), address(0xD0D0), address(this), address(0xFEE1), address(0xFEE2));
    }

    /// One hop t0 -> t1, one kind-9 leg: the wrapper `w` under its venue key.
    function _kind9Route(uint256 amt) internal view returns (Route memory) {
        Leg[] memory l = new Leg[](1);
        l[0] = Leg({pool: w, hooks: address(0), kind: BPC.KIND_EXTERNAL, fee: KEY, tickSpacing: 0,
            zeroForOne: true, stable: false, amountIn: amt, expectedOut: 0, auxId: bytes32(0)});
        Hop[] memory hs = new Hop[](1);
        hs[0] = Hop({tokenIn: address(t0), tokenOut: address(t1), amountIn: amt, expectedOut: 0, legs: l});
        return Route({hops: hs, totalOut: 0, singleOut: 0, singleOutFloor: 0, expectedImpactBps: 0,
            confidenceWad: 0, estGas: 0, hasSurplus: false, isV4Bundle: false});
    }
}
