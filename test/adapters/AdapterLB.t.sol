// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {AdapterHarness} from "./AdapterHarness.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockV2Pair} from "../mocks/MockV2Pair.sol";
import {BlazePhoenixGateWrapper} from "../../src/BlazePhoenixGate.sol";
import {BlazePhoenixCore as BPC} from "../../src/BlazePhoenixCore.sol";
import {BlazePhoenixAdapterLB, ILBFactory, ILBPair} from "../../src/adapters/BlazePhoenixAdapterLB.sol";
import {MockLBFactory, MockLBPair, MockLBHooks} from "./mocks/MockLB.sol";
import {MockERC20Dec} from "./mocks/MockERC20Dec.sol";

/// Answers like a wrapper and is not one.
contract FakeWrapperLB {
    address public token0;
    address public token1;

    constructor(address a, address b) {
        (token0, token1) = (a, b);
    }
}

/// Liquidity Book adapter (LFJ v2.1 / v2.2, Pharaoh DLMM) behind the real wrapper. Red-first at
/// 0cb3af4: every test below was written before the adapter body, against a stub with the
/// same ABI; the guard each one watches has its mutant in .github/scripts/mutants.py
/// ([LB-01]..[LB-46], the build report's tags kept). Oracles: the mock pair's own
/// maths (test/adapters/mocks/MockLB.sol) and values fixed by hand at 1 X = 2 Y and 30 bps.
contract AdapterLBTest is AdapterHarness {
    uint8 internal constant FAM = 1;
    uint24 internal constant KEY = uint24(FAM) << 16 | 1;
    uint16 internal constant BS = 10;
    uint256 internal constant BEFORE_SWAP = 1 << 160;
    uint256 internal constant AFTER_SWAP = 1 << 161;
    uint256 internal constant BEFORE_MINT = 1 << 164;
    /// The live flags of LFJ v2.2 and Pharaoh DLMM WAVAX/USDC (desenho-lb sec 2, by RPC):
    /// BEFORE_SWAP | BEFORE_MINT | BEFORE_BURN | BEFORE_TRANSFER.
    uint256 internal constant LIVE_FLAGS = 0x151 << 160;

    MockLBFactory internal factory;
    MockLBPair internal pair; // tokenX = t1, tokenY = t0 (X is token1); v2.2 shape, no hooks
    BlazePhoenixAdapterLB internal adapter;
    address internal w;

    function setUp() public {
        _tokens();
        factory = new MockLBFactory();
        pair = _pair(address(t1), address(t0), BS);
        adapter = new BlazePhoenixAdapterLB(address(gate), address(factory));
        _accept(FAM, address(adapter));
        w = gate.create(address(t0), address(t1), KEY, abi.encode(uint256(BS)));
    }

    /// X 1_000e18 and Y 3_000e18 on the books, registered under its own tokens.
    function _pair(address x, address y, uint16 bs) internal returns (MockLBPair p) {
        p = new MockLBPair(x, y);
        MockERC20(x).mint(address(p), 1_000e18);
        MockERC20(y).mint(address(p), 3_000e18);
        p.sync();
        factory.register(p, bs);
    }

    function _hp(uint256 flags, address hook) internal pure returns (bytes32) {
        return bytes32(flags | uint160(hook));
    }

    /// A pair with the live flags and hook `h` at create (so `h` is pinned), X = token1.
    function _hookedPair(uint16 bs) internal returns (MockLBPair p, MockLBHooks h, address w2) {
        p = _pair(address(t1), address(t0), bs);
        h = new MockLBHooks();
        p.setHooks(_hp(LIVE_FLAGS, address(h)));
        w2 = gate.create(address(t0), address(t1), KEY + 1, abi.encode(uint256(bs)));
    }

    /// Anti-vacuity for every refusal: the same wrapper answers and swaps before the change.
    /// Only for an untouched pair from `_pair` with X = token1.
    function _assertLive(address wr) internal {
        (uint256 q, uint256 d) = BlazePhoenixGateWrapper(wr).quote(true, 1e18);
        assertEq(q, 4.985e17, "live: 1 Y less 30 bps, at 2 Y per X");
        assertEq(d, 1_000e18, "live: the short side");
        assertEq(_swap(wr, true, 1e18), q, "live: the swap pays the quote");
    }

    /// Paused by the pair's hooks: the adapter's own quote answers (0, 0) and its quoteCall 0
    /// (asked directly, so a revert would show), the wrapper's likewise, and an exec through
    /// the wrapper reverts AdapterE(7).
    function _assertPaused(address wr) internal {
        BlazePhoenixGateWrapper x = BlazePhoenixGateWrapper(wr);
        (address vp, bytes32 a0, bytes32 a1) = (x.venuePool(), x.aux0(), x.aux1());
        (uint256 q, uint256 d) = adapter.quote(vp, a0, a1, true, 1e18);
        assertEq(q, 0, "adapter quote");
        assertEq(d, 0, "adapter depth");
        assertEq(adapter.quoteCall(vp, a0, a1, false, 1e18), 0, "adapter quoteCall");
        (q, d) = x.quote(false, 1e18);
        assertEq(q + d, 0, "wrapper quote");
        assertEq(x.quoteCall(true, 1e18), 0, "wrapper quoteCall");
        t0.mint(address(this), 1e18);
        vm.expectRevert(_aerr(7));
        x.swap(address(this), true, 1e18, 0, "");
    }

    // ─── execution: PUSH custody, the venue's own output, nothing left behind ───

    /// X is token1: zeroForOne sells token0 = Y for X, the other way sells X for Y
    /// (swapForY = zeroForOne == X0, both directions), against values fixed by hand.
    function test_LB_Swap_XIsToken1_BothWays() public {
        assertEq(_swap(w, true, 10e18), 4.985e18, "10 Y less 30 bps, at 2 Y per X");
        _assertEmpty(address(adapter), w, address(pair));
        assertEq(_swap(w, false, 10e18), 19.94e18, "10 X less 30 bps, at 2 Y per X");
        _assertEmpty(address(adapter), w, address(pair));
    }

    /// X is token0, on a v2.1-shaped pair (no getLBHooksParameters: no hooks, nothing pinned).
    function test_LB_Swap_XIsToken0_V21Shape_BothWays() public {
        MockLBPair p = _pair(address(t0), address(t1), 20);
        p.setHooksMode(1);
        address w2 = gate.create(address(t0), address(t1), KEY + 1, abi.encode(uint256(20)));
        BlazePhoenixGateWrapper x = BlazePhoenixGateWrapper(w2);
        assertEq(x.venuePool(), address(p));
        assertEq(uint256(x.aux0()), 1, "X0 set, HOOKED not set");
        assertEq(x.aux1(), bytes32(0));
        assertEq(_swap(w2, true, 10e18), 19.94e18, "10 X less 30 bps, at 2 Y per X");
        _assertEmpty(address(adapter), w2, address(p));
        assertEq(_swap(w2, false, 10e18), 4.985e18, "10 Y less 30 bps, at 2 Y per X");
        _assertEmpty(address(adapter), w2, address(p));
    }

    /// exec's own return (advisory: the wrapper measures at the recipient) is the output side
    /// of the pair's word: X in the low 128 bits, Y in the high. Interface only: the wrapper's
    /// `swap`, exec's one caller, discards the return (IExtAdapter: "advisory and never read"),
    /// so [LB-19] is equivalent on every wrapper path; there the recipient's balance is pinned.
    function test_LB_ExecReturnsTheOutputSideOfTheVenueWord() public {
        BlazePhoenixGateWrapper x = BlazePhoenixGateWrapper(w);
        (bytes32 a0, bytes32 a1) = (x.aux0(), x.aux1());
        t0.mint(address(adapter), 10e18);
        vm.prank(w);
        uint256 out = adapter.exec(address(pair), a0, a1, true, 10e18, address(this));
        assertEq(out, 4.985e18, "X out: the low half");
        assertEq(t1.balanceOf(address(this)), out);
        t1.mint(address(adapter), 10e18);
        vm.prank(w);
        out = adapter.exec(address(pair), a0, a1, false, 10e18, address(this));
        assertEq(out, 19.94e18, "Y out: the high half");
        assertEq(t0.balanceOf(address(this)), out);
    }

    function testFuzz_LB_CustodyEmptyAfterEveryExec(uint96 amt, bool zeroForOne) public {
        amt = uint96(bound(amt, 1e6, 1_000e18)); // inside the output side's reserve, both ways
        _swap(w, zeroForOne, amt);
        _assertEmpty(address(adapter), w, address(pair));
    }

    function test_LB_PushHasNoApproveInItsBytecode() public view {
        assertFalse(_hasApproveSelector(address(adapter)));
    }

    /// `_out` is the one body behind quote and quoteCall (SHARED_QUANTITIES): the adapter's
    /// view and quoteCall, the wrapper's view and quoteCall, and the swap give one number.
    function test_LB_QuoteEqualsQuoteCallEqualsExecution_BothWays() public {
        BlazePhoenixGateWrapper x = BlazePhoenixGateWrapper(w);
        (address vp, bytes32 a0, bytes32 a1) = (x.venuePool(), x.aux0(), x.aux1());
        (uint256 q, ) = adapter.quote(vp, a0, a1, true, 7e18);
        assertEq(q, 3.4895e18, "7 Y less 30 bps, at 2 Y per X");
        assertEq(adapter.quoteCall(vp, a0, a1, true, 7e18), q);
        (uint256 qw, ) = x.quote(true, 7e18);
        assertEq(qw, q);
        assertEq(x.quoteCall(true, 7e18), q);
        assertEq(_swap(w, true, 7e18), q);
        (q, ) = adapter.quote(vp, a0, a1, false, 7e18);
        assertEq(q, 13.958e18, "7 X less 30 bps, at 2 Y per X");
        assertEq(adapter.quoteCall(vp, a0, a1, false, 7e18), q);
        (qw, ) = x.quote(false, 7e18);
        assertEq(qw, q);
        assertEq(x.quoteCall(false, 7e18), q);
        assertEq(_swap(w, false, 7e18), q);
    }

    // ─── depth18: what the pair reports for its LPs, the shorter side in 18 decimals ───

    /// Quantity: adapter depth18 (LB) = min(to18(rX), to18(rY)) of getReserves (the books less
    /// the protocol's fees), not of the pair's balanceOf, for any amtIn and either direction;
    /// what Gate.vitalOf reads below the mass held; and what the registry reads for a native
    /// pair holding the same reserves (one mass, one depth on both doors).
    function test_LB_Depth18_IsTheReportedShortSide_ForAnyAmtIn() public {
        pair.setProtocolFees(5e18, 0); // X (token1): 1_000e18 on the books, 5e18 the protocol's
        t1.mint(address(pair), 50e18); // a donation the books have not taken
        BlazePhoenixGateWrapper x = BlazePhoenixGateWrapper(w);
        (, uint256 d) = x.quote(true, 0);
        assertEq(d, 995e18, "the short side the pair reports, not its books nor its balance");
        (, uint256 d2) = x.quote(false, 7e18);
        assertEq(d2, d, "depth18 does not depend on amtIn or direction");
        (, d2) = adapter.quote(address(pair), x.aux0(), x.aux1(), true, uint256(type(uint128).max) + 1);
        assertEq(d2, d, "nor on an amtIn the venue cannot take");
        (, uint256 dv, ) = gate.vitalOf(w);
        assertEq(dv, d, "vitalOf reads the word below the mass held");
        MockV2Pair v2 = new MockV2Pair(address(t0), address(t1));
        v2.setReserves(uint112(3_000e18), uint112(995e18));
        t0.mint(address(v2), 3_000e18);
        t1.mint(address(v2), 995e18);
        assertEq(BPC.registryDepth18(address(v2), BPC.KIND_V2, address(t0), address(t1), address(0), bytes32(0)), d,
            "a native pair holding the same reserves reads the same depth");
    }

    /// Quantity: adapter depth18 (LB) normalises each side by its token's decimals before the
    /// min: 2M of a 6-decimal X (2e12 raw) is deeper than 1M of an 18-decimal Y (1e24 raw).
    function test_LB_Depth18_NormalisesDecimalsBeforeTheMin() public {
        MockERC20Dec d6 = new MockERC20Dec(6);
        MockLBPair p = new MockLBPair(address(d6), address(t1));
        d6.mint(address(p), 2_000_000e6);
        t1.mint(address(p), 1_000_000e18);
        p.sync();
        (, uint256 d) = adapter.quote(address(p), bytes32(0), bytes32(0), true, 0);
        assertEq(d, 1_000_000e18, "normalised, the 6-decimal side is the deeper one");
    }

    // ─── the venue's answer, taken only when it is the whole answer ───

    /// An amtIn above uint128 is not truncated into a smaller one: the quote is 0.
    function test_LB_Quote_AmtInAboveUint128_IsZero_NotTruncated() public view {
        BlazePhoenixGateWrapper x = BlazePhoenixGateWrapper(w);
        (bytes32 a0, bytes32 a1) = (x.aux0(), x.aux1());
        uint256 big = (uint256(1) << 128) + 10e18;
        (uint256 q, ) = adapter.quote(address(pair), a0, a1, true, uint256(uint128(big)));
        assertEq(q, 4.985e18, "anti-vacuity: the truncated amount has an answer");
        uint256 d;
        (q, d) = adapter.quote(address(pair), a0, a1, true, big);
        assertEq(q, 0, "quote");
        assertEq(d, 1_000e18, "the depth is still declared");
        assertEq(adapter.quoteCall(address(pair), a0, a1, true, big), 0, "quoteCall");
    }

    /// amountInLeft != 0 is the swap's OutOfLiquidity in the same state (the same loop): a
    /// partial fill is not a quote. The venue's raw answer first: input left over, output > 0.
    function test_LB_Quote_InputLeftOver_IsZero_AndTheSwapReverts() public {
        (uint128 left, uint128 o, ) = pair.getSwapOut(2_000e18, true);
        assertGt(left, 0, "the venue leaves input over");
        assertEq(o, 3_000e18, "and fills what it holds");
        BlazePhoenixGateWrapper x = BlazePhoenixGateWrapper(w);
        (uint256 q, uint256 d) = adapter.quote(address(pair), x.aux0(), x.aux1(), false, 2_000e18);
        assertEq(q, 0, "quote");
        assertEq(d, 1_000e18, "depth");
        assertEq(x.quoteCall(false, 2_000e18), 0, "quoteCall");
        t1.mint(address(this), 2_000e18);
        vm.expectRevert(MockLBPair.LBPair__OutOfLiquidity.selector);
        x.swap(address(this), false, 2_000e18, 0, "");
    }

    /// A venue read that reverts (BinHelper__MaxLiquidityPerBinExceeded, or out of gas) is a 0,
    /// not a revert: the adapter's own view still answers, with the depth.
    function test_LB_Quote_VenueReverts_IsZero_NotARevert() public {
        BlazePhoenixGateWrapper x = BlazePhoenixGateWrapper(w);
        (bytes32 a0, bytes32 a1) = (x.aux0(), x.aux1());
        (uint256 q, ) = adapter.quote(address(pair), a0, a1, true, 1e18);
        assertEq(q, 4.985e17, "anti-vacuity: the same call answers");
        pair.setSwapOutReverts(true);
        uint256 d;
        (q, d) = adapter.quote(address(pair), a0, a1, true, 1e18);
        assertEq(q, 0, "quote");
        assertEq(d, 1_000e18, "the depth is the pair's");
        assertEq(adapter.quoteCall(address(pair), a0, a1, true, 1e18), 0, "quoteCall");
    }

    // ─── who may call: ExtAdapterBase._requireWrapper (SHARED_QUANTITIES) ───

    function test_LB_ExecFromNonWrapper_Refused() public {
        BlazePhoenixGateWrapper x = BlazePhoenixGateWrapper(w);
        (bytes32 a0, bytes32 a1) = (x.aux0(), x.aux1());
        t0.mint(address(adapter), 1e18);
        vm.expectRevert(_aerr(1));
        adapter.exec(address(pair), a0, a1, true, 1e18, address(this));
    }

    /// HUNT-001, the class itself: a contract that answers token0/token1 like a wrapper, names
    /// a pair, and asks the adapter to move what it holds.
    function test_LB_FakeWrapperWithRealTokens_Refused() public {
        FakeWrapperLB fake = new FakeWrapperLB(address(t0), address(t1));
        BlazePhoenixGateWrapper x = BlazePhoenixGateWrapper(w);
        (bytes32 a0, bytes32 a1) = (x.aux0(), x.aux1());
        t0.mint(address(adapter), 1e18);
        vm.prank(address(fake));
        vm.expectRevert(_aerr(1));
        adapter.exec(address(pair), a0, a1, true, 1e18, address(fake));
    }

    /// AdapterE(1) comes before the hooks: a caller that is not a wrapper runs nothing of the
    /// pair and learns nothing of it.
    function test_LB_ExecFromNonWrapper_RefusedBeforeTheHooks() public {
        BlazePhoenixGateWrapper x = BlazePhoenixGateWrapper(w);
        (bytes32 a0, bytes32 a1) = (x.aux0(), x.aux1());
        pair.setHooks(_hp(AFTER_SWAP, address(new MockLBHooks())));
        t0.mint(address(adapter), 1e18);
        vm.expectRevert(_aerr(1));
        adapter.exec(address(pair), a0, a1, true, 1e18, address(this));
    }

    /// The pinned BEFORE_SWAP hook runs inside our exec: calling the adapter from there is a
    /// caller that is not a wrapper (the wrapper's own lock, GateE(11), guards its door).
    function test_LB_PinnedHookReentersExec_Refused() public {
        (MockLBPair p, MockLBHooks h, address w2) = _hookedPair(30);
        BlazePhoenixGateWrapper x = BlazePhoenixGateWrapper(w2);
        h.setReenter(address(adapter),
            abi.encodeCall(BlazePhoenixAdapterLB.exec, (address(p), x.aux0(), x.aux1(), true, 1, address(h))));
        t0.mint(address(this), 1e18);
        vm.expectRevert(_aerr(1));
        x.swap(address(this), true, 1e18, 0, "");
    }

    // ─── identity and refusals at resolve (asked of the factory, once) ───

    function test_LB_Resolve_RecordsTheFactorysPairAndItsShape() public view {
        BlazePhoenixGateWrapper x = BlazePhoenixGateWrapper(w);
        assertEq(x.venuePool(), address(pair), "the factory's record of (t0, t1, binStep)");
        assertEq(uint256(x.aux0()), 2, "HOOKED (v2.2 shape), X0 not set (X is token1)");
        assertEq(x.aux1(), bytes32(0), "no BEFORE_SWAP hook to pin");
    }

    function test_LB_Resolve_PinsTheBeforeSwapHook() public {
        (, MockLBHooks h, address w2) = _hookedPair(30);
        assertEq(BlazePhoenixGateWrapper(w2).aux1(), bytes32(uint256(uint160(address(h)))), "the hook seen at create");
        assertEq(uint256(BlazePhoenixGateWrapper(w2).aux0()), 2, "HOOKED, X is token1");
    }

    function test_LB_Resolve_PairNotInTheRegistry_Refused() public {
        vm.expectRevert(_aerr(2));
        gate.create(address(t0), address(t1), KEY + 1, abi.encode(uint256(25)));
    }

    /// A registry record whose pair trades another token is not a pair of (t0, t1).
    function test_LB_Resolve_RecordTradesAnotherToken_Refused() public {
        MockERC20 other = new MockERC20("O", "O");
        MockLBPair stray = new MockLBPair(address(other), address(t1));
        factory.registerAs(address(t0), address(t1), 40, address(stray));
        vm.expectRevert(_aerr(3));
        gate.create(address(t0), address(t1), KEY + 1, abi.encode(uint256(40)));
    }

    /// The hint is one word, the bin step: longer or shorter is malformed.
    function test_LB_Resolve_MalformedHint_Refused() public {
        vm.expectRevert(_aerr(8));
        gate.create(address(t0), address(t1), KEY + 1, abi.encode(uint256(BS), uint256(0)));
        vm.expectRevert(_aerr(8));
        gate.create(address(t0), address(t1), KEY + 1, abi.encodePacked(uint16(BS)));
    }

    /// Bin step 0 is no pair: refused as a malformed hint even where a registry holds a record
    /// under it (so the guard is the adapter's, not the registry's).
    function test_LB_Resolve_BinStepZero_Refused() public {
        factory.registerAs(address(t0), address(t1), 0, address(pair));
        vm.expectRevert(_aerr(8));
        gate.create(address(t0), address(t1), KEY + 1, abi.encode(uint256(0)));
    }

    /// The bin step is a uint16 at the venue: a larger word is malformed, never read mod 2^16.
    function test_LB_Resolve_BinStepAboveUint16_Refused() public {
        vm.expectRevert(_aerr(8));
        gate.create(address(t0), address(t1), KEY + 1, abi.encode(uint256(type(uint16).max) + 1 + BS));
    }

    /// AFTER_SWAP runs after the pair releases its reentrancy guard, inside our exec: refused at create.
    function test_LB_Resolve_AfterSwapHookRefused() public {
        MockLBPair p = _pair(address(t1), address(t0), 50);
        p.setHooks(_hp(LIVE_FLAGS | AFTER_SWAP, address(new MockLBHooks())));
        vm.expectRevert(_aerr(7));
        gate.create(address(t0), address(t1), KEY + 1, abi.encode(uint256(50)));
    }

    /// Each creation sits behind its own external call: with dynamic test linking an inline `new`
    /// is a cheatcode call, and an expected revert on it ends the test body at the first creation.
    function test_LB_Constructor_ZeroAddress_Refused() public {
        vm.expectRevert(_aerr(0));
        this.deployLB(address(gate), address(0));
        vm.expectRevert(_aerr(0));
        this.deployLB(address(0), address(factory));
        assertGt(this.deployLB(address(gate), address(factory)).code.length, 0, "control: both addresses set deploys");
    }

    function deployLB(address g, address f) external returns (address) {
        return address(new BlazePhoenixAdapterLB(g, f));
    }

    // ─── hooks: `_hooksOk`, the pair's hooks of now, on every exec, quote and quoteCall ───

    function test_LB_Hooks_AfterSwapSetAfterCreate_Refused() public {
        _assertLive(w);
        pair.setHooks(_hp(AFTER_SWAP, address(new MockLBHooks())));
        _assertPaused(w);
    }

    function test_LB_Hooks_BeforeSwapWithAnotherHook_Refused() public {
        (MockLBPair p, MockLBHooks h, address w2) = _hookedPair(30);
        _assertLive(w2);
        assertEq(h.beforeCalls(), 1, "the pinned hook ran once");
        p.setHooks(_hp(LIVE_FLAGS, address(new MockLBHooks())));
        _assertPaused(w2);
    }

    /// BEFORE_SWAP added after create by the hook that then held only other flags: nothing was
    /// pinned, so it is not the pinned hook.
    function test_LB_Hooks_BeforeSwapAddedAfterCreate_Refused() public {
        MockLBPair p = _pair(address(t1), address(t0), 60);
        MockLBHooks h = new MockLBHooks();
        p.setHooks(_hp(BEFORE_MINT, address(h)));
        address w2 = gate.create(address(t0), address(t1), KEY + 1, abi.encode(uint256(60)));
        _assertLive(w2);
        assertEq(h.beforeCalls(), 0, "BEFORE_MINT never runs in a swap");
        p.setHooks(_hp(BEFORE_SWAP | BEFORE_MINT, address(h)));
        _assertPaused(w2);
    }

    /// Absent is not zero: a HOOKED pair whose hooks cannot be read is refused, not hook-free.
    function test_LB_Hooks_ReadFailsAfterCreate_Refused() public {
        _assertLive(w);
        pair.setHooksMode(1);
        _assertPaused(w);
    }

    /// An answer shorter than a word is not an answer.
    function test_LB_Hooks_ShortAnswerAfterCreate_Refused() public {
        _assertLive(w);
        pair.setHooksMode(3);
        _assertPaused(w);
    }

    function test_LB_Hooks_PinnedBeforeSwapHookPasses() public {
        (MockLBPair p, MockLBHooks h, address w2) = _hookedPair(30);
        BlazePhoenixGateWrapper x = BlazePhoenixGateWrapper(w2);
        (uint256 q, ) = x.quote(false, 10e18);
        assertEq(q, 19.94e18, "10 X less 30 bps, at 2 Y per X");
        assertEq(x.quoteCall(false, 10e18), q);
        assertEq(_swap(w2, false, 10e18), q);
        assertEq(h.beforeCalls(), 1, "the pinned hook ran, once");
        assertEq(h.afterCalls(), 0);
        _assertEmpty(address(adapter), w2, address(p));
    }

    /// Flags that never run in a swap (mint, burn, transfer), by any hook: admitted.
    function test_LB_Hooks_NonSwapFlagsByAnotherHookPass() public {
        MockLBHooks h = new MockLBHooks();
        pair.setHooks(_hp(LIVE_FLAGS & ~BEFORE_SWAP, address(h)));
        _assertLive(w);
        assertEq(h.beforeCalls() + h.afterCalls(), 0);
    }

    /// removeLBHooksOnPair after create: nothing runs in the swap, admitted.
    function test_LB_Hooks_RemovedAfterCreatePass() public {
        (MockLBPair p, MockLBHooks h, address w2) = _hookedPair(30);
        p.setHooks(bytes32(0));
        _assertLive(w2);
        assertEq(h.beforeCalls(), 0);
    }

    // ─── the venue's ABI and the Gate's scan ───

    /// The adapter's interfaces against the selectors read from the deployed venue code
    /// (desenho-lb sec 2, cast and eth_getCode): a wrong parameter type would still compile and
    /// pass against a mock written from the same interface.
    function test_LB_InterfaceSelectorsAreTheVenues() public pure {
        assertEq(uint256(uint32(ILBFactory.getLBPairInformation.selector)), 0x704037bd);
        assertEq(uint256(uint32(ILBPair.getTokenX.selector)), 0x05e8746d);
        assertEq(uint256(uint32(ILBPair.getTokenY.selector)), 0xda10610c);
        assertEq(uint256(uint32(ILBPair.getReserves.selector)), 0x0902f1ac);
        assertEq(uint256(uint32(ILBPair.getSwapOut.selector)), 0xe77366f8);
        assertEq(uint256(uint32(ILBPair.swap.selector)), 0x53c059a0);
        assertEq(uint256(uint32(MockLBPair.getLBHooksParameters.selector)), 0x781a8915);
        assertEq(uint256(uint32(MockLBHooks.beforeSwap.selector)), 0xfeee3735);
        assertEq(uint256(uint32(MockLBHooks.afterSwap.selector)), 0x53e8079b);
    }

    function test_LB_CodeIsCleanForTheGate() public view {
        assertTrue(gate.codeIsClean(address(adapter)));
    }
}
