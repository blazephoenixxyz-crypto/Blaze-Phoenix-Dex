// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {AdapterHarness} from "./AdapterHarness.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {BlazePhoenixGateWrapper} from "../../src/BlazePhoenixGate.sol";
import {
    BlazePhoenixAdapterInfinityCL, IInfinityVault, ILockCallback, IInfinityCLPoolManager
} from "../../src/adapters/BlazePhoenixAdapterInfinityCL.sol";
import {MockInfVault, MockInfCLPoolManager, PinnedHook, SecondHook, ForgingHook, OtherHook} from "./mocks/MockInfinity.sol";
import {MockERC20Dec} from "./mocks/MockERC20Dec.sol";

/// An unpinned hook whose beforeSwap works: the code a pinned hook's address may come to hold.
contract RogueHook { function beforeSwap(address) external {} }

/// PancakeSwap Infinity CL adapter behind the real wrapper: SETTLE custody against a Vault- and
/// CLPoolManager-faithful mock (ERC-20 pairs only). Red at the stub commit (the ABI, no body).
contract AdapterInfinityCLTest is AdapterHarness {
    uint8 internal constant FAM = 6;
    uint24 internal constant KEY = uint24(FAM) << 16 | 1;
    uint24 internal constant FEE = 2500; // oracle: out = amt * 997_500 / 1_000_000
    uint256 internal constant Q96 = 2 ** 96;

    MockInfVault internal vault;
    MockInfCLPoolManager internal cl;
    PinnedHook internal hook;
    SecondHook internal hook1;
    ForgingHook internal hook2;
    BlazePhoenixAdapterInfinityCL internal adapter;
    bytes32 internal id;
    address internal w;

    function setUp() public {
        _tokens();
        vault = new MockInfVault();
        cl = new MockInfCLPoolManager(address(vault));
        vault.registerApp(address(cl));
        hook = new PinnedHook();
        hook1 = new SecondHook();
        hook2 = new ForgingHook();
        t0.mint(address(vault), 1e24);
        t1.mint(address(vault), 1e24);
        adapter = new BlazePhoenixAdapterInfinityCL(address(gate), address(cl), [address(hook), address(hook1), address(hook2)]);
        _accept(FAM, address(adapter));
        id = _pool(address(0), 0, FEE);
        w = gate.create(address(t0), address(t1), KEY, abi.encode(id));
    }

    /// parameters: tick spacing at bit 16 (CLPoolParametersHelper), the hooks bitmap in the low 16 bits.
    function _key(address c0, address c1, address h, uint16 bitmap, uint24 fee)
        internal view returns (IInfinityCLPoolManager.PoolKey memory)
    {
        return IInfinityCLPoolManager.PoolKey(c0, c1, h, address(cl), fee, bytes32(uint256(50) << 16 | bitmap));
    }

    function _pool(address h, uint16 bitmap, uint24 fee) internal returns (bytes32) {
        return cl.initialize(_key(address(t0), address(t1), h, bitmap, fee), uint160(Q96), 1000e18);
    }

    function _settled() internal view {
        assertEq(vault.getLocker(), address(0), "lock released");
        assertEq(vault.unsettled(), 0, "no delta left open");
    }

    function _out(uint256 amt) internal pure returns (uint256) { return amt * 997_500 / 1_000_000; }

    // ─── execution: swap exact-in, sync + transfer exactly + settle, the Vault pays the recipient ───

    function test_InfCL_Swap_RecipientPaidByVault_Settled_NothingLeft() public {
        assertEq(_swap(w, true, 10e18), _out(10e18));
        _assertEmpty(address(adapter), w, address(vault));
        _settled();
        assertEq(_swap(w, false, 4e18), _out(4e18));
        _assertEmpty(address(adapter), w, address(vault));
        _settled();
    }

    function testFuzz_InfCL_CustodyEmptyAfterEveryExec(uint96 amt, bool zeroForOne) public {
        amt = uint96(bound(amt, 1e6, 1e23)); // <= 10 % of the Vault's 1e24
        assertEq(_swap(w, zeroForOne, amt), _out(amt));
        _assertEmpty(address(adapter), w, address(vault));
        _settled();
    }

    function test_InfCL_NoApproveInItsBytecode() public view {
        assertFalse(_hasApproveSelector(address(adapter)));
    }

    /// The mock shares the adapter's interfaces, so only the upstream signatures can catch a drift.
    function test_InfCL_InterfaceSelectorsEqualTheVenues() public pure {
        assertEq(bytes32(IInfinityVault.lock.selector), bytes32(bytes4(keccak256("lock(bytes)"))));
        assertEq(bytes32(IInfinityVault.sync.selector), bytes32(bytes4(keccak256("sync(address)"))));
        assertEq(bytes32(IInfinityVault.settle.selector), bytes32(bytes4(keccak256("settle()"))));
        assertEq(bytes32(IInfinityVault.take.selector), bytes32(bytes4(keccak256("take(address,address,uint256)"))));
        assertEq(bytes32(IInfinityVault.getLocker.selector), bytes32(bytes4(keccak256("getLocker()"))));
        assertEq(bytes32(ILockCallback.lockAcquired.selector), bytes32(bytes4(keccak256("lockAcquired(bytes)"))));
        assertEq(
            bytes32(IInfinityCLPoolManager.swap.selector),
            bytes32(bytes4(keccak256("swap((address,address,address,address,uint24,bytes32),(bool,int256,uint160),bytes)")))
        );
        assertEq(bytes32(IInfinityCLPoolManager.poolIdToPoolKey.selector), bytes32(bytes4(keccak256("poolIdToPoolKey(bytes32)"))));
        assertEq(bytes32(IInfinityCLPoolManager.getSlot0.selector), bytes32(bytes4(keccak256("getSlot0(bytes32)"))));
        assertEq(bytes32(IInfinityCLPoolManager.getLiquidity.selector), bytes32(bytes4(keccak256("getLiquidity(bytes32)"))));
        assertEq(bytes32(IInfinityCLPoolManager.vault.selector), bytes32(bytes4(keccak256("vault()"))));
    }

    function test_InfCL_QuoteCallEqualsExecution_QuoteIsZero() public {
        cl.setRate(id, true, 0.9e18); // t0->t1 prices apart: a reversed direction is seen
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
    function test_InfCL_StrayBalances_DoNotBreakSettle() public {
        t0.mint(address(vault), 1);
        t0.mint(address(adapter), 1);
        assertEq(_swap(w, true, 2e18), _out(2e18));
        _settled();
        assertEq(t0.balanceOf(address(adapter)), 1, "the dust stays where it was");
    }

    /// A pool that runs dry before the price limit consumes part of the input: the Vault's own
    /// rule (no delta open at the end of the lock) reverts the exec, and quoteCall prices nothing.
    function test_InfCL_PartialFill_RevertsCurrencyNotSettled() public {
        cl.setMaxIn(id, 1e18);
        assertEq(BlazePhoenixGateWrapper(w).quoteCall(true, 2e18), 0, "a fill the exec cannot settle is no quote");
        t0.mint(address(this), 2e18);
        vm.expectRevert(MockInfVault.CurrencyNotSettled.selector);
        BlazePhoenixGateWrapper(w).swap(address(this), true, 2e18, 0, "");
    }

    // ─── hostile callers of the callback (SETTLE: the lock's deltas are the locker's) ───

    function test_InfCL_LockAcquiredFromNonVault_Refused() public {
        vm.expectRevert(_aerr(6));
        adapter.lockAcquired(abi.encode(uint256(1)));
        // From inside the adapter's own exec: a pinned hook calling the callback mid-swap.
        bytes32 hid = _pool(address(hook), 69, FEE);
        address w2 = gate.create(address(t0), address(t1), KEY + 1, abi.encode(hid));
        hook.arm(address(adapter), abi.encodeCall(adapter.lockAcquired, (abi.encode(uint256(1)))));
        assertEq(_swap(w2, true, 1e18), _out(1e18));
        assertEq(hook.calls(), 1, "anti-vacuity: the hook ran inside the exec");
        assertFalse(hook.lastOk(), "the callback refused the hook");
        assertEq(hook.lastRet(), _aerr(6));
    }

    function test_InfCL_VaultCallbackOutsideOwnExec_Refused() public {
        t0.mint(address(adapter), 1e18); // something to steal, were the callback open
        vm.expectRevert(_aerr(6));
        vault.poke(address(adapter), abi.encodeCall(adapter.lockAcquired, (abi.encode(uint256(1)))));
    }

    function test_InfCL_ExecFromNonWrapper_Refused() public {
        t0.mint(address(adapter), 1e18);
        vm.expectRevert(_aerr(1));
        adapter.exec(address(vault), id, bytes32(0), true, 1e18, address(this));
    }

    function test_InfCL_QuoteCallFromNonWrapper_Refused() public {
        vm.expectRevert(_aerr(1));
        adapter.quoteCall(address(vault), id, bytes32(0), true, 1e18);
    }

    // ─── identity at resolve: the pool manager's own record of the id ───

    function test_InfCL_Resolve_UnknownPoolId_Refused() public {
        vm.expectRevert(_aerr(2));
        gate.create(address(t0), address(t1), KEY + 1, abi.encode(keccak256("no such pool")));
    }

    function test_InfCL_Resolve_PairNotInPool_Refused() public {
        MockERC20 x = new MockERC20("X", "X");
        (address a, address b) = address(t0) < address(x) ? (address(t0), address(x)) : (address(x), address(t0));
        bytes32 xid = cl.initialize(_key(a, b, address(0), 0, FEE), uint160(Q96), 1000e18);
        vm.expectRevert(_aerr(3));
        gate.create(address(t0), address(t1), KEY + 1, abi.encode(xid));
    }

    function test_InfCL_Resolve_MalformedHint_Refused() public {
        vm.expectRevert(_aerr(8));
        gate.create(address(t0), address(t1), KEY + 1, abi.encodePacked(bytes20(id)));
        vm.expectRevert(_aerr(8));
        gate.create(address(t0), address(t1), KEY + 1, abi.encodePacked(id, uint8(0)));
    }

    function test_InfCL_Resolve_Aux0IsThePoolId_VenueIsTheVault() public view {
        assertEq(BlazePhoenixGateWrapper(w).venuePool(), address(vault), "the Vault holds the tokens");
        assertEq(BlazePhoenixGateWrapper(w).aux0(), id);
    }

    // ─── hooks at resolve; the pin again at exec and quoteCall ───

    function _refused(address h, uint16 bitmap, uint24 fee) internal {
        bytes32 hid = _pool(h, bitmap, fee);
        vm.expectRevert(_aerr(7));
        gate.create(address(t0), address(t1), KEY + 1, abi.encode(hid));
    }

    function test_InfCL_Resolve_UnpinnedHook_Refused() public { _refused(address(new RogueHook()), 69, FEE); }

    function test_InfCL_Resolve_HookWithoutCode_Refused() public {
        BlazePhoenixAdapterInfinityCL a2 =
            new BlazePhoenixAdapterInfinityCL(address(gate), address(cl), [address(hook), address(0), address(0)]);
        _accept(FAM + 1, address(a2));
        bytes32 hid = _pool(address(0xDEAD), 69, FEE);
        vm.expectRevert(_aerr(7));
        gate.create(address(t0), address(t1), uint24(FAM + 1) << 16 | 1, abi.encode(hid));
    }

    function test_InfCL_Resolve_HookBitAfterSwap_Refused() public { _refused(address(hook), 69 | 1 << 7, FEE); }
    function test_InfCL_Resolve_BitBeforeSwapReturnsDelta_Refused() public { _refused(address(hook), 69 | 1 << 10, FEE); }
    function test_InfCL_Resolve_BitAfterSwapReturnsDelta_Refused() public { _refused(address(hook), 69 | 1 << 11, FEE); }
    function test_InfCL_Resolve_DynamicFee_Refused() public { _refused(address(hook), 69, 0x800000); }

    /// The bitmaps of the hooked pools at the top of BSC volume (Fase A): beforeInitialize,
    /// beforeAddLiquidity, (beforeRemoveLiquidity,) beforeSwap.
    function test_InfCL_Resolve_MainnetBitmaps69And85_Accepted() public {
        bytes32 h69 = _pool(address(hook), 69, FEE);
        bytes32 h85 = _pool(address(hook), 85, FEE);
        address w69 = gate.create(address(t0), address(t1), KEY + 1, abi.encode(h69));
        address w85 = gate.create(address(t0), address(t1), KEY + 2, abi.encode(h85));
        assertEq(BlazePhoenixGateWrapper(w69).aux0(), h69);
        assertEq(BlazePhoenixGateWrapper(w85).aux0(), h85);
        assertEq(_swap(w85, true, 1e18), _out(1e18));
        assertEq(hook.calls(), 1, "the pinned hook ran");
    }

    function test_InfCL_Resolve_SecondAndThirdPinSlotsCount() public {
        bytes32 i1 = _pool(address(hook1), 69, FEE);
        bytes32 i2 = _pool(address(hook2), 69, FEE);
        address w1 = gate.create(address(t0), address(t1), KEY + 1, abi.encode(i1));
        address w2 = gate.create(address(t0), address(t1), KEY + 2, abi.encode(i2));
        assertEq(BlazePhoenixGateWrapper(w2).aux0(), i2);
        assertEq(_swap(w1, true, 1e18), _out(1e18));
        assertEq(hook1.calls(), 2, "the second pinned hook ran");
    }

    function test_InfCL_PinnedHook_Runs_ThenCodeChanges_ExecRefused() public {
        bytes32 hid = _pool(address(hook), 69, FEE);
        address w2 = gate.create(address(t0), address(t1), KEY + 1, abi.encode(hid));
        assertEq(_swap(w2, true, 1e18), _out(1e18));
        assertEq(hook.calls(), 1, "anti-vacuity: the pinned hook ran in the swap");
        vm.etch(address(hook), address(new RogueHook()).code);
        assertEq(BlazePhoenixGateWrapper(w2).quoteCall(true, 1e18), 0, "quoteCall re-checks the pin");
        t0.mint(address(this), 1e18);
        vm.expectRevert(_aerr(7));
        BlazePhoenixGateWrapper(w2).swap(address(this), true, 1e18, 0, "");
    }

    /// Only the adapter's own path produces QuoteOut: a hook reverting with that payload is a
    /// failed swap (QuoteSwapFailed of its bytes), not a price.
    function test_InfCL_QuoteCall_HookForgingTheOut_NotRead() public {
        bytes32 fid = _pool(address(hook2), 69, FEE);
        address wf = gate.create(address(t0), address(t1), KEY + 1, abi.encode(fid));
        assertEq(BlazePhoenixGateWrapper(wf).quoteCall(true, 1e18), 0, "the forged out is not a quote");
        bytes memory forged = abi.encodeWithSelector(BlazePhoenixAdapterInfinityCL.QuoteOut.selector, uint256(1e30));
        vm.prank(wf);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixAdapterInfinityCL.QuoteSwapFailed.selector, forged));
        adapter.quoteCall(address(vault), fid, bytes32(0), true, 1e18);
    }

    // ─── construction ───

    function test_InfCL_Constructor_VaultIsTheManagersVault() public view {
        assertEq(address(adapter.VAULT()), address(vault));
        assertEq(address(adapter.CL_MANAGER()), address(cl));
    }

    function test_InfCL_Constructor_PinsAreTheRefHooksCodehash() public {
        assertEq(adapter.HOOK_CODEHASH0(), address(hook).codehash);
        assertEq(adapter.HOOK_CODEHASH1(), address(hook1).codehash);
        assertEq(adapter.HOOK_CODEHASH2(), address(hook2).codehash);
        BlazePhoenixAdapterInfinityCL a2 =
            new BlazePhoenixAdapterInfinityCL(address(gate), address(cl), [address(hook), address(0), address(0)]);
        assertEq(a2.HOOK_CODEHASH1(), bytes32(0), "an empty slot pins nothing");
        assertEq(a2.HOOK_CODEHASH2(), bytes32(0), "an empty slot pins nothing");
    }

    function test_InfCL_Constructor_ZeroManager_Refused() public {
        vm.expectRevert(_aerr(0));
        new BlazePhoenixAdapterInfinityCL(address(gate), address(0), [address(hook), address(0), address(0)]);
    }

    function test_InfCL_Constructor_RefHookWithoutCode_Refused() public {
        vm.expectRevert(_aerr(0));
        new BlazePhoenixAdapterInfinityCL(address(gate), address(cl), [address(hook), address(0xDEAD), address(0)]);
    }

    // ─── depth18: Core's depthFromL18 at the pool's current price, the registry's V4 arm ───

    /// Quantity: adapter depth18 (Infinity CL) = BPC.depthFromL18(getLiquidity(id),
    /// getSlot0(id).sqrtPriceX96, decimals of token0, of token1), for any amtIn and either
    /// direction; what Gate.vitalOf reads.
    function test_InfCL_Depth18_IsDepthFromLAtTheCurrentPrice() public {
        BlazePhoenixGateWrapper x = BlazePhoenixGateWrapper(w);
        (uint256 q, uint256 d) = x.quote(true, 0);
        assertEq(q, 0, "no view quote");
        assertEq(d, 1000e18, "sqrtP = Q96: both virtual reserves are L");
        cl.setState(id, uint160(2 * Q96), 1000e18);
        (, d) = x.quote(true, 0);
        assertEq(d, 500e18, "sqrtP = 2 Q96: x0 = L Q96 / sp = 500e18 < x1 = L sp / Q96 = 2000e18");
        (, uint256 d2) = x.quote(false, 6e18);
        assertEq(d2, d, "depth18 does not depend on amtIn or direction");
        (, uint256 dv, ) = gate.vitalOf(w);
        assertEq(dv, d, "vitalOf reads the adapter's word below the mass held");
    }

    /// Quantity: adapter depth18 (Infinity CL) normalises each virtual reserve by its token's
    /// decimals before the min. L = 1024e18 at a price of 2^20 (or 2^-20): the 6-decimal side
    /// holds 1e18 raw = 1e30 normalised, the 18-decimal side 1024 * L; the short side is the latter.
    function test_InfCL_Depth18_NormalisesDecimals() public {
        MockERC20Dec d6 = new MockERC20Dec(6);
        bool sixIsToken0 = address(d6) < address(t0);
        (address c0, address c1) = sixIsToken0 ? (address(d6), address(t0)) : (address(t0), address(d6));
        uint160 sp = sixIsToken0 ? uint160(Q96 << 10) : uint160(Q96 >> 10);
        bytes32 i6 = cl.initialize(_key(c0, c1, address(0), 0, FEE), sp, 1024e18);
        address w6 = gate.create(address(d6), address(t0), KEY, abi.encode(i6));
        (, uint256 d) = BlazePhoenixGateWrapper(w6).quote(true, 0);
        assertEq(d, 1024 * 1024e18, "the 18-decimal side, normalised, is the short one");
    }

    /// Quantity: adapter depth18 (Infinity CL) is asked only while the Vault has no locker
    /// (getLocker() == 0), the Balancer V3 isUnlocked probe in the Infinity Vault's form: inside
    /// a lock, a swap moves the pool before its deltas are settled.
    function test_InfCL_Depth18_ZeroWhileTheVaultIsLocked() public {
        vault.lock(abi.encode(uint256(0)));
        assertTrue(_lockRan, "anti-vacuity: read inside the lock");
        assertEq(_dLocked, 0, "locked: the adapter declares no depth");
        assertEq(_vLocked, 0, "locked: vitalOf reads no depth");
        (, uint256 d) = BlazePhoenixGateWrapper(w).quote(true, 0);
        assertEq(d, 1000e18, "no locker again: depthFromL at the price");
    }

    bool internal _lockRan;
    uint256 internal _dLocked;
    uint256 internal _vLocked;

    /// The Vault's lock callback, with this test as the locker.
    function lockAcquired(bytes calldata) external returns (bytes memory) {
        _lockRan = true;
        (, _dLocked) = BlazePhoenixGateWrapper(w).quote(true, 0);
        (, _vLocked, ) = gate.vitalOf(w);
        return "";
    }

    function test_InfCL_Depth18_OnlyForTheGatesWrapper() public {
        vm.expectRevert(_aerr(1));
        adapter.quote(address(vault), id, bytes32(0), true, 0);
    }

    /// The Quoter's kind-9 arm prices this leg under GATE_QUOTE_GAS, by quoteCall (the view says 0),
    /// at what the exec pays.
    function test_InfCL_QuoteArm_UnderGateQuoteGas() public {
        address[] memory cold = new address[](4);
        (cold[0], cold[1], cold[2], cold[3]) = (address(adapter), address(vault), address(cl), w);
        (uint256 out, , uint256 gQuoteCall) = _armUnderCap(w, true, 5e18, cold);
        assertEq(out, _out(5e18), "the arm's price is the exec's");
        assertGt(gQuoteCall, 0, "priced by quoteCall: the view answered 0");
    }
}
