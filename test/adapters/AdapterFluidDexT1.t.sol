// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {AdapterHarness} from "./AdapterHarness.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {BlazePhoenixGateWrapper} from "../../src/BlazePhoenixGate.sol";
import {BlazePhoenixCore as BPC} from "../../src/BlazePhoenixCore.sol";
import {BlazePhoenixAdapterFluidDexT1} from "../../src/adapters/BlazePhoenixAdapterFluidDexT1.sol";
import {MockFluidFactory, MockFluidLiquidity, MockFluidDexT1, Intruder} from "./mocks/MockFluidDexT1.sol";
import {MockERC20Dec} from "./mocks/MockERC20Dec.sol";

/// Exposes the adapter's CREATE-address derivation.
contract FluidAdapterProbe is BlazePhoenixAdapterFluidDexT1 {
    constructor(address g) BlazePhoenixAdapterFluidDexT1(g, address(1), address(1)) {}
    function createAddress(address d, uint256 n) external pure returns (address) { return _createAddress(d, n); }
}

/// Fluid DEX T1 adapter behind the real wrapper: callback custody against a Fluid-faithful mock.
contract AdapterFluidDexT1Test is AdapterHarness {
    uint8 internal constant FAM = 5;
    uint24 internal constant KEY = uint24(FAM) << 16 | 1;
    address internal constant NATIVE = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    MockFluidFactory internal factory;
    MockFluidLiquidity internal liq;
    MockFluidDexT1 internal dex;
    BlazePhoenixAdapterFluidDexT1 internal adapter;
    address internal w;

    function setUp() public {
        _tokens();
        factory = new MockFluidFactory();
        liq = new MockFluidLiquidity(address(factory));
        dex = factory.deploy(address(liq), address(t0), address(t1)); // dexId 1
        t0.mint(address(liq), 1_000_000e18);
        t1.mint(address(liq), 1_000_000e18);
        adapter = new BlazePhoenixAdapterFluidDexT1(address(gate), address(factory), address(liq));
        _accept(FAM, address(adapter));
        w = gate.create(address(t0), address(t1), KEY, abi.encode(uint256(1)));
    }

    /// The pool's supply word in Liquidity: BigMath (coefficient 56 | exponent 8) at bit 1, the
    /// interest flag at bit 0. Returns the word and the amount it decodes to.
    function _supply(uint256 amt, bool interest) internal pure returns (uint256 word, uint256 decoded) {
        uint256 e;
        while ((amt >> e) >= (uint256(1) << 56)) ++e;
        uint256 big = ((amt >> e) << 8) | e;
        word = (big << 1) | (interest ? 1 : 0);
        decoded = (amt >> e) << e;
    }

    function _setSupply(MockFluidDexT1 d, uint256 a0, uint256 a1) internal returns (uint256 d0, uint256 d1) {
        uint256 word;
        (word, d0) = _supply(a0, false);
        liq.set(d.slot(0), word);
        (word, d1) = _supply(a1, false);
        liq.set(d.slot(2), word);
    }

    function _swapReverts(bytes memory err, bool zeroForOne, uint256 amt) internal {
        (zeroForOne ? t0 : t1).mint(address(this), amt);
        vm.expectRevert(err);
        BlazePhoenixGateWrapper(w).swap(address(this), zeroForOne, int256(amt), 0, "");
    }

    // ─── execution: the pool asks once, Liquidity is paid, the recipient is paid ───

    function test_Fluid_Swap_RecipientPaid_NothingLeft() public {
        assertEq(_swap(w, true, 10e18), 10e18 * 9_970 / 10_000);
        _assertEmpty(address(adapter), w, address(dex));
        _assertEmpty(address(adapter), w, address(liq));
        assertEq(t0.balanceOf(address(liq)), 1_000_010e18, "Liquidity received exactly the input");
        assertEq(_swap(w, false, 4e18), 4e18 * 9_970 / 10_000);
        _assertEmpty(address(adapter), w, address(dex));
        _assertEmpty(address(adapter), w, address(liq));
    }

    function testFuzz_Fluid_CustodyEmptyAfterEveryExec(uint96 amt, bool zeroForOne) public {
        amt = uint96(bound(amt, 1e3, 1e23)); // the pool's amountOutMin is 1
        _swap(w, zeroForOne, amt);
        _assertEmpty(address(adapter), w, address(dex));
        _assertEmpty(address(adapter), w, address(liq));
    }

    function test_Fluid_NoApproveInItsBytecode() public view {
        assertFalse(_hasApproveSelector(address(adapter)));
    }

    function test_Fluid_QuoteIsZero_QuoteCallEqualsExecution() public {
        dex.setRate(9_000);
        (uint256 q, ) = BlazePhoenixGateWrapper(w).quote(false, 6e18);
        assertEq(q, 0);
        uint256 qc = BlazePhoenixGateWrapper(w).quoteCall(false, 6e18);
        assertEq(qc, 6e18 * 9_000 / 10_000);
        assertEq(dex.dexVariables(), 0, "the simulation left no state");
        assertEq(_swap(w, false, 6e18), qc);
    }

    /// A simulation that fails for another reason is that reason, not a price read from it.
    function test_Fluid_QuoteCall_OtherRevertIsNotAPrice() public {
        dex.setMode(MockFluidDexT1.Mode.Paused);
        vm.prank(w);
        vm.expectRevert(MockFluidDexT1.Paused.selector);
        adapter.quoteCall(address(liq), bytes32(uint256(uint160(address(dex)))), bytes32(0), true, 1e18);
        assertEq(BlazePhoenixGateWrapper(w).quoteCall(true, 1e18), 0, "the wrapper reads a failed query as no price");
    }

    /// `_requireWrapper`: the pair a query prices is the calling wrapper's.
    function test_Fluid_QuoteCall_FromNonWrapper_Refused() public {
        vm.expectRevert(_aerr(1));
        adapter.quoteCall(address(liq), bytes32(uint256(uint160(address(dex)))), bytes32(0), true, 1e18);
    }

    function test_Fluid_QuoteCall_UnderTheQuoterGasCap() public {
        (uint256 out, , ) = _armUnderCap(w, true, 1e18, new address[](0));
        assertEq(out, 1e18 * 9_970 / 10_000);
    }

    /// `_requireWrapper`: only a wrapper the Gate created makes the adapter move tokens.
    function test_Fluid_ExecFromNonWrapper_Refused() public {
        t0.mint(address(adapter), 1e18);
        vm.expectRevert(_aerr(1));
        adapter.exec(address(liq), bytes32(uint256(uint160(address(dex)))), bytes32(0), true, 1e18, address(this));
    }

    // ─── the callback: only the pool exec runs, its token, at most its input, once ───

    function test_Fluid_CallbackFromNonPool_Refused() public {
        t0.mint(address(adapter), 1e18);
        vm.expectRevert(_aerr(6));
        adapter.dexCallback(address(t0), 1e18);
    }

    function test_Fluid_PoolCallbackOutsideOwnExec_Refused() public {
        t0.mint(address(adapter), 1e18); // something to move, were the callback open
        vm.prank(address(dex));
        vm.expectRevert(_aerr(6));
        adapter.dexCallback(address(t0), 1e18);
    }

    /// Another contract calling the callback while exec is open would have this call's input
    /// credited to whatever Liquidity operation it is running. Refused; the real pool then settles.
    function test_Fluid_IntruderDuringExec_Refused_SwapSettles() public {
        dex.setIntruder(new Intruder());
        dex.setMode(MockFluidDexT1.Mode.Intruder);
        assertEq(_swap(w, true, 3e18), 3e18 * 9_970 / 10_000);
        assertFalse(dex.intruderPaid(), "the intruder was paid");
        _assertEmpty(address(adapter), w, address(liq));
    }

    function test_Fluid_SecondCallback_Refused() public {
        t0.mint(address(adapter), 5e18); // a donation a second request could reach
        dex.setMode(MockFluidDexT1.Mode.Twice);
        _swapReverts(_aerr(6), true, 5e18);
    }

    function test_Fluid_CallbackAskingMoreThanTheInput_Refused() public {
        t0.mint(address(adapter), 1);
        dex.setMode(MockFluidDexT1.Mode.Over);
        _swapReverts(_aerr(6), true, 5e18);
    }

    function test_Fluid_CallbackForTheOtherToken_Refused() public {
        t1.mint(address(adapter), 5e18);
        dex.setMode(MockFluidDexT1.Mode.WrongToken);
        _swapReverts(_aerr(6), true, 5e18);
    }

    /// The custody of a request that never comes is the wrapper's: the input left here is refused.
    function test_Fluid_PoolThatNeverAsks_WrapperRefuses() public {
        dex.setMode(MockFluidDexT1.Mode.NoCallback);
        _swapReverts(_gerr(14), true, 5e18);
    }

    // ─── identity: derived from (factory, dexId), vouched by the pool, the wrapper's pair ───

    function test_Fluid_Resolve_PoolIsTheFactoryCreateAtNonceId() public {
        BlazePhoenixGateWrapper x = BlazePhoenixGateWrapper(w);
        assertEq(x.aux0(), bytes32(uint256(uint160(vm.computeCreateAddress(address(factory), 1)))));
        assertEq(x.aux0(), bytes32(uint256(uint160(address(dex)))));
        assertEq(x.venuePool(), address(liq));
        assertEq(x.aux1(), bytes32(0));
    }

    /// The Uniswap aggregator's flaw: a pool named by the caller. A perfect copy of a real pool
    /// that the factory did not create is not reachable through the hint.
    function test_Fluid_Resolve_FreePoolInHint_Refused() public {
        MockFluidDexT1 copy = new MockFluidDexT1(1, address(liq), address(t0), address(t1));
        vm.expectRevert(_aerr(8));
        gate.create(address(t0), address(t1), KEY + 1, abi.encode(address(copy)));
        // ...nor by the id of a pool that another deployer created at the same nonce.
        MockFluidFactory other = new MockFluidFactory();
        other.deploy(address(liq), address(t0), address(t1));
        MockFluidDexT1 twin = other.deploy(address(liq), address(t0), address(t1)); // id 2 elsewhere
        assertEq(twin.id(), 2);
        vm.expectRevert(); // the real factory's nonce-2 address has no code
        gate.create(address(t0), address(t1), KEY + 1, abi.encode(uint256(2)));
    }

    function test_Fluid_Resolve_PoolClaimingAnotherId_Refused() public {
        MockFluidDexT1 d2 = factory.deploy(address(liq), address(t0), address(t1));
        d2.lie(3, address(liq));
        vm.expectRevert(_aerr(2));
        gate.create(address(t0), address(t1), KEY + 1, abi.encode(uint256(2)));
    }

    function test_Fluid_Resolve_PoolOfAnotherLiquidity_Refused() public {
        MockFluidDexT1 d2 = factory.deploy(address(liq), address(t0), address(t1));
        d2.lie(2, address(0xBEEF));
        vm.expectRevert(_aerr(2));
        gate.create(address(t0), address(t1), KEY + 1, abi.encode(uint256(2)));
    }

    function test_Fluid_Resolve_PairNotInPool_Refused() public {
        MockERC20 x = new MockERC20("X", "X");
        factory.deploy(address(liq), address(t0), address(x));
        vm.expectRevert(_aerr(3));
        gate.create(address(t0), address(t1), KEY + 1, abi.encode(uint256(2)));
    }

    function test_Fluid_Resolve_NativePool_Refused() public {
        assertLt(uint160(address(t0)), uint160(NATIVE));
        factory.deploy(address(liq), address(t0), NATIVE);
        vm.expectRevert(_aerr(4));
        gate.create(address(t0), NATIVE, KEY + 1, abi.encode(uint256(2)));
    }

    function test_Fluid_Resolve_MalformedHint_Refused() public {
        vm.expectRevert(_aerr(8));
        gate.create(address(t0), address(t1), KEY + 1, abi.encodePacked(uint248(1)));
        vm.expectRevert(_aerr(8));
        gate.create(address(t0), address(t1), KEY + 1, abi.encode(uint256(1), uint256(0)));
    }

    function test_Fluid_Resolve_IdOutOfRange_Refused() public {
        vm.expectRevert(_aerr(8));
        gate.create(address(t0), address(t1), KEY + 1, abi.encode(uint256(0)));
        vm.expectRevert(_aerr(8));
        gate.create(address(t0), address(t1), KEY + 1, abi.encode(uint256(0x1000000)));
    }

    function test_Fluid_CreateAddress_AtEveryRlpBoundary() public {
        FluidAdapterProbe p = new FluidAdapterProbe(address(gate));
        uint24[10] memory ns = [uint24(1), 0x7f, 0x80, 0xff, 0x100, 0x1234, 0xffff, 0x10000, 0xabcdef, 0xffffff];
        for (uint256 i; i < ns.length; ++i) {
            assertEq(p.createAddress(address(factory), ns[i]), vm.computeCreateAddress(address(factory), ns[i]));
        }
    }

    function testFuzz_Fluid_CreateAddress(address d, uint24 n) public {
        vm.assume(n != 0);
        FluidAdapterProbe p = new FluidAdapterProbe(address(gate));
        assertEq(p.createAddress(d, n), vm.computeCreateAddress(d, n));
    }

    // ─── depth18: the short side of the pool's collateral, as the pool decodes it ───

    function test_Fluid_Depth_ShortSideOfCollateral_Normalised() public {
        MockERC20Dec a = new MockERC20Dec(6);
        MockERC20Dec b = new MockERC20Dec(18);
        (address x0, address x1) = address(a) < address(b) ? (address(a), address(b)) : (address(b), address(a));
        MockFluidDexT1 d2 = factory.deploy(address(liq), x0, x1);
        address w2 = gate.create(x0, x1, KEY + 1, abi.encode(uint256(2)));
        // the 6-decimal side holds the larger raw amount and the smaller value
        bool sixFirst = x0 == address(a);
        (uint256 r0, uint256 r1) = sixFirst ? (uint256(1_000e6), uint256(5e18)) : (uint256(5e18), uint256(1_000e6));
        (uint256 d0, uint256 d1) = _setSupply(d2, r0, r1);
        (, uint256 depth) = BlazePhoenixGateWrapper(w2).quote(true, 0);
        uint256 want = BPC.shortSide18(d0, BPC.decimalsOf(x0), d1, BPC.decimalsOf(x1));
        assertEq(depth, want);
        assertLt(depth, BPC.maxSide18(d0, BPC.decimalsOf(x0), d1, BPC.decimalsOf(x1)), "short side, not the long one");
        assertApproxEqRel(depth, 5e18, 1e12, "the 18-decimal side, 5 tokens");
    }

    function test_Fluid_Depth_InterestModeScaledByStoredExchangePrice() public {
        (uint256 word, uint256 dec0) = _supply(300e18, true);
        liq.set(dex.slot(0), word);
        liq.set(dex.slot(4), uint256(1.05e12) << 91);
        (, uint256 dec1) = _setSupply1(400e18);
        (, uint256 depth) = BlazePhoenixGateWrapper(w).quote(true, 0);
        uint256 scaled0 = dec0 * 1.05e12 / 1e12;
        assertEq(depth, scaled0 < dec1 ? scaled0 : dec1);
        assertGt(depth, dec0, "the interest-bearing side was scaled");
    }

    function _setSupply1(uint256 a1) internal returns (uint256 word, uint256 d1) {
        (word, d1) = _supply(a1, false);
        liq.set(dex.slot(2), word);
    }

    function test_Fluid_Depth_NoneWhileReentrancyBitSet() public {
        _setSupply(dex, 100e18, 200e18);
        (, uint256 before) = BlazePhoenixGateWrapper(w).quote(true, 0);
        assertGt(before, 0);
        dex.setDexVariables(1 | (123 << 1));
        (, uint256 depth) = BlazePhoenixGateWrapper(w).quote(true, 0);
        assertEq(depth, 0);
    }

    /// The read guard inside a real operation: the pool, mid-swap, asks the wrapper for its depth.
    function test_Fluid_Depth_NoneInsideALiveSwap() public {
        _setSupply(dex, 100e18, 200e18);
        dex.setProbe(w);
        dex.setMode(MockFluidDexT1.Mode.ProbeQuote);
        _swap(w, true, 1e18);
        assertEq(dex.probedDepth(), 0);
    }

    /// Gate.vitalOf caps the word by what the venue (Liquidity) holds, by the same formula.
    function test_Fluid_VitalOf_DepthIsTheAdapterWordUnderTheHoldingsCap() public {
        (uint256 d0, uint256 d1) = _setSupply(dex, 100e18, 200e18);
        (, uint256 depth, ) = gate.vitalOf(w);
        assertEq(depth, d0 < d1 ? d0 : d1);
        _setSupply(dex, 5_000_000e18, 6_000_000e18); // a word above Liquidity's 1e24 holdings
        (, depth, ) = gate.vitalOf(w);
        assertEq(depth, 1_000_000e18, "capped at the short side of what Liquidity holds");
    }
}
