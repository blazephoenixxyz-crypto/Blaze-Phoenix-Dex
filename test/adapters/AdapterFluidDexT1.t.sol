// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {AdapterHarness} from "./AdapterHarness.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {BlazePhoenixGateWrapper} from "../../src/BlazePhoenixGate.sol";
import {BlazePhoenixCore as BPC} from "../../src/BlazePhoenixCore.sol";
import {BlazePhoenixAdapterFluidDexT1} from "../../src/adapters/BlazePhoenixAdapterFluidDexT1.sol";
import {MockFluidFactory, MockFluidLiquidity, MockFluidDexT1, Intruder, MockWETH9} from "./mocks/MockFluidDexT1.sol";
import {MockERC20Dec} from "./mocks/MockERC20Dec.sol";

/// Exposes the adapter's CREATE-address derivation.
contract FluidAdapterProbe is BlazePhoenixAdapterFluidDexT1 {
    constructor(address g) BlazePhoenixAdapterFluidDexT1(g, address(1), address(1), address(1)) {}
    function createAddress(address d, uint256 n) external pure returns (address) { return _createAddress(d, n); }
}

/// Fluid DEX T1 adapter behind the real wrapper: callback custody against a Fluid-faithful mock.
contract AdapterFluidDexT1Test is AdapterHarness {
    uint8 internal constant FAM = 5;
    uint24 internal constant KEY = uint24(FAM) << 16 | 1;
    address internal constant NATIVE = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    /// Fixed addresses so the native side sorts both ways: LO < WETH < HI < NATIVE.
    address internal constant WETH = 0x4200000000000000000000000000000000000006;
    address internal constant LO = 0x1111111111111111111111111111111111111111;
    address internal constant HI = 0x9999999999999999999999999999999999999999;

    MockFluidFactory internal factory;
    MockFluidLiquidity internal liq;
    MockFluidDexT1 internal dex;
    BlazePhoenixAdapterFluidDexT1 internal adapter;
    address internal w;

    function setUp() public {
        _tokens();
        vm.etch(WETH, address(new MockWETH9()).code);
        factory = new MockFluidFactory();
        liq = new MockFluidLiquidity(address(factory));
        dex = factory.deploy(address(liq), address(t0), address(t1)); // dexId 1
        t0.mint(address(liq), 1_000_000e18);
        t1.mint(address(liq), 1_000_000e18);
        adapter = new BlazePhoenixAdapterFluidDexT1(address(gate), address(factory), address(liq), WETH);
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

    /// A token that returns nothing from `transfer` (USDT): the callback pays it all the same.
    function test_Fluid_Swap_TokenWithoutReturnValue_Settles() public {
        t0.setNoReturnData(true);
        assertEq(_swap(w, true, 7e18), 7e18 * 9_970 / 10_000);
        _assertEmpty(address(adapter), w, address(liq));
        assertEq(t0.balanceOf(address(liq)), 1_000_007e18, "Liquidity received exactly the input");
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

    // ─── native ETH: the path speaks WETH; unwrap and wrap at the venue boundary ───

    MockFluidDexT1 internal nLo; // (LO, NATIVE): as WETH, the wrapper's order
    MockFluidDexT1 internal nHi; // (HI, NATIVE): as WETH, the reverse order (FLIPPED)
    address internal wLo;
    address internal wHi;

    /// Pools 2 and 3; Liquidity holds ETH and both tokens. Fluid 0 -> 1 at 99.70 %, 1 -> 0 at
    /// 90 %: a direction read the wrong way prices differently.
    function _native() internal {
        vm.etch(LO, address(t0).code);
        vm.etch(HI, address(t0).code);
        nLo = factory.deploy(address(liq), LO, NATIVE);
        nHi = factory.deploy(address(liq), HI, NATIVE);
        nLo.setRate1to0(9_000);
        nHi.setRate1to0(9_000);
        MockERC20(LO).mint(address(liq), 1_000_000e18);
        MockERC20(HI).mint(address(liq), 1_000_000e18);
        vm.deal(address(liq), 1_000_000e18);
        wLo = gate.create(LO, WETH, KEY, abi.encode(uint256(2)));
        wHi = gate.create(HI, WETH, KEY, abi.encode(uint256(3)));
    }

    /// Router-shaped swap on a wrapper with a WETH side; the WETH input is backed by real ETH.
    function _swapN(address x, bool zeroForOne, uint256 amt) internal returns (uint256 out) {
        BlazePhoenixGateWrapper wr = BlazePhoenixGateWrapper(x);
        (address tIn, address tOut) = zeroForOne ? (wr.token0(), wr.token1()) : (wr.token1(), wr.token0());
        if (tIn == WETH) {
            vm.deal(address(this), amt);
            MockWETH9(payable(WETH)).deposit{value: amt}();
        } else {
            MockERC20(tIn).mint(address(this), amt);
        }
        uint256 b = MockERC20(tOut).balanceOf(address(this));
        wr.swap(address(this), zeroForOne, int256(amt), 0, "");
        out = MockERC20(tOut).balanceOf(address(this)) - b;
    }

    /// Nothing at rest: no ETH, no WETH and no token in the adapter or the wrapper; WETH backed.
    function _assertEmptyN(address x, address tok) internal view {
        assertEq(address(adapter).balance, 0, "adapter ETH");
        assertEq(MockERC20(WETH).balanceOf(address(adapter)), 0, "adapter WETH");
        assertEq(MockERC20(tok).balanceOf(address(adapter)), 0, "adapter token");
        assertEq(MockERC20(WETH).balanceOf(x), 0, "wrapper WETH");
        assertEq(MockERC20(tok).balanceOf(x), 0, "wrapper token");
        assertEq(x.balance, 0, "wrapper ETH");
        assertEq(WETH.balance, MockERC20(WETH).totalSupply(), "WETH fully backed");
    }

    function test_Fluid_Native_Resolve_WethSideAndOrder() public {
        _native();
        assertEq(BlazePhoenixGateWrapper(wLo).token0(), LO);
        assertEq(BlazePhoenixGateWrapper(wLo).aux0(), bytes32(uint256(uint160(address(nLo)))));
        assertEq(BlazePhoenixGateWrapper(wLo).aux1(), bytes32(uint256(2)), "native, same order");
        assertEq(BlazePhoenixGateWrapper(wHi).token0(), WETH);
        assertEq(BlazePhoenixGateWrapper(wHi).aux1(), bytes32(uint256(3)), "native, reversed order");
        // NATIVE next to the ERC20 WETH reads as WETH/WETH: never a Gate pair.
        factory.deploy(address(liq), WETH, NATIVE); // id 4
        vm.expectRevert(_aerr(3));
        gate.create(WETH, LO, KEY, abi.encode(uint256(4)));
    }

    /// WETH in: exactly the input is unwrapped and sent as the swap's value; Liquidity holds it.
    function test_Fluid_Native_EthIn_RecipientPaid_NothingLeft() public {
        _native();
        uint256 e = address(liq).balance;
        // LO pool: WETH is the wrapper's token1 (zeroForOne false), Fluid 1 -> 0.
        uint256 q = BlazePhoenixGateWrapper(wLo).quoteCall(false, 2e18);
        assertEq(q, 2e18 * 9_000 / 10_000, "the simulation reads Fluid's direction");
        assertEq(_swapN(wLo, false, 2e18), q, "quoteCall == execution");
        assertEq(address(liq).balance, e + 2e18, "Liquidity received the input as ETH");
        _assertEmptyN(wLo, LO);
        // HI pool, reversed: WETH is token0 (zeroForOne true), Fluid still 1 -> 0.
        q = BlazePhoenixGateWrapper(wHi).quoteCall(true, 3e18);
        assertEq(q, 3e18 * 9_000 / 10_000, "the simulation reads Fluid's direction");
        assertEq(_swapN(wHi, true, 3e18), q, "quoteCall == execution");
        assertEq(address(liq).balance, e + 5e18);
        _assertEmptyN(wHi, HI);
    }

    /// WETH out: Liquidity pays the ETH to the adapter, which wraps exactly it for the recipient.
    function test_Fluid_Native_EthOut_WrappedToRecipient_NothingLeft() public {
        _native();
        uint256 e = address(liq).balance;
        uint256 q = BlazePhoenixGateWrapper(wLo).quoteCall(true, 4e18);
        assertEq(q, 4e18 * 9_970 / 10_000);
        assertEq(_swapN(wLo, true, 4e18), q, "quoteCall == execution, in WETH");
        assertEq(address(liq).balance, e - q, "Liquidity paid ETH");
        _assertEmptyN(wLo, LO);
        q = BlazePhoenixGateWrapper(wHi).quoteCall(false, 1e18);
        assertEq(q, 1e18 * 9_970 / 10_000);
        assertEq(_swapN(wHi, false, 1e18), q);
        _assertEmptyN(wHi, HI);
    }

    /// A native input opens no callback: a pool asking for WETH anyway reaches nothing.
    function test_Fluid_Native_InputOpensNoCallback() public {
        _native();
        vm.deal(address(this), 2e18);
        MockWETH9(payable(WETH)).deposit{value: 2e18}();
        MockERC20(WETH).transfer(address(adapter), 1e18); // a donation a request could reach
        nLo.setAskToken(WETH);
        nLo.setMode(MockFluidDexT1.Mode.AskOnNative);
        vm.expectRevert(_aerr(6));
        BlazePhoenixGateWrapper(wLo).swap(address(this), false, int256(1e18), 0, "");
    }

    /// ETH already in the adapter (forced) is not the output: only the swap's delta is wrapped.
    function test_Fluid_Native_OutputWrapsOnlyTheDelta() public {
        _native();
        vm.deal(address(adapter), 1 ether);
        uint256 q = BlazePhoenixGateWrapper(wHi).quoteCall(false, 5e18);
        assertEq(_swapN(wHi, false, 5e18), q, "the recipient gets the swap's output, no more");
        assertEq(address(adapter).balance, 1 ether, "the forced ETH stays where it was");
        assertEq(MockERC20(WETH).balanceOf(address(adapter)), 0);
    }

    function _pay(address from, address to) internal returns (bool ok) {
        vm.deal(from, 1);
        vm.prank(from);
        (ok, ) = to.call{value: 1}("");
    }

    /// `receive`: no one sends ETH outside the instant of an unwrap or a native payment.
    function test_Fluid_Native_EthRefusedOutsideExec() public {
        _native();
        assertFalse(_pay(address(0xBEEF), address(adapter)), "a stranger");
        assertFalse(_pay(WETH, address(adapter)), "WETH outside an unwrap");
        assertFalse(_pay(address(liq), address(adapter)), "Liquidity outside a native payment");
    }

    /// The window is one call wide: later in the same transaction as a native input (or a
    /// native output), WETH (or Liquidity) can no longer send ETH to the adapter. Both happen
    /// inside one call of `NativeSwapThenPush`: Foundry resets transient storage between the
    /// test's own top-level calls, so a check made from here would pass with the window open.
    function test_Fluid_Native_EthWindowClosesAfterExec() public {
        _native();
        NativeSwapThenPush b = new NativeSwapThenPush();
        vm.deal(address(this), 1e18);
        MockWETH9(payable(WETH)).deposit{value: 1e18}();
        MockERC20(WETH).transfer(address(b), 1e18);
        MockERC20(LO).mint(address(b), 1e18);
        assertFalse(b.run(wLo, false, 1e18, WETH, address(adapter)), "WETH after the unwrap");
        assertFalse(b.run(wLo, true, 1e18, address(liq), address(adapter)), "Liquidity after the payment");
        assertEq(address(adapter).balance, 0, "adapter ETH");
    }

    /// The native side's depth is read as WETH's (18 decimals), short side of the collateral.
    function test_Fluid_Native_Depth_ShortSide() public {
        _native();
        (uint256 d0, uint256 d1) = _setSupply(nLo, 100e18, 40e18);
        (, uint256 depth) = BlazePhoenixGateWrapper(wLo).quote(true, 0);
        assertEq(depth, BPC.shortSide18(d0, 18, d1, 18));
        assertEq(depth, d1);
    }
}

/// A native swap through the wrapper, then, in the same call frame, `from` sends 1 wei to the
/// adapter. Pays the wrapper as the Router does (by transfer in the callback).
contract NativeSwapThenPush is Test {
    function run(address wr, bool zeroForOne, uint256 amt, address from, address adapter)
        external returns (bool pushed)
    {
        BlazePhoenixGateWrapper(wr).swap(address(this), zeroForOne, int256(amt), 0, "");
        vm.deal(from, from.balance + 1);
        vm.prank(from);
        (pushed, ) = adapter.call{value: 1}("");
    }

    function uniswapV3SwapCallback(int256 a0, int256 a1, bytes calldata) external {
        BlazePhoenixGateWrapper w = BlazePhoenixGateWrapper(msg.sender);
        (address t, int256 amt) = a0 > 0 ? (w.token0(), a0) : (w.token1(), a1);
        if (amt > 0) MockERC20(t).transfer(msg.sender, uint256(amt));
    }
}
