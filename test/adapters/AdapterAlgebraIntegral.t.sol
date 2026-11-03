// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {AdapterHarness, GateQuoteArm} from "./AdapterHarness.sol";
import {BlazePhoenixGateWrapper} from "../../src/BlazePhoenixGate.sol";
import {BlazePhoenixCore as BPC} from "../../src/BlazePhoenixCore.sol";
import {
    BlazePhoenixAdapterAlgebraIntegral, IAlgebraCustomFactory, IAlgebraVenue
} from "../../src/adapters/BlazePhoenixAdapterAlgebraIntegral.sol";
import {
    MockAlgebraFactory, MockAlgebraVenue, MockAlgebraPlugin, MockAlgebraDirtyPlugin
} from "./mocks/MockAlgebraIntegral.sol";
import {MockERC20Dec} from "./mocks/MockERC20Dec.sol";

/// Answers like a wrapper and is not one.
contract FakeWrapperAI {
    address public token0;
    address public token1;

    constructor(address a, address b) {
        (token0, token1) = (a, b);
    }
}

/// Algebra Integral adapter (Blackhole CLMM custom venues) behind the real wrapper. Red-first at
/// REDCOMMIT: every test below was written before the adapter body, against a stub with the
/// same ABI; the guard each one watches has its mutant in .github/scripts/mutants.py ([AI-..]).
/// Oracles: values fixed by an independent Python model of Algebra's exact-input loop
/// (SwapCalculation, PriceMovementMath, TokenDeltaMath, TickMath; build report), the mock
/// venue's own port of that loop for the swaps, and the selectors by `cast sig`.
contract AdapterAlgebraIntegralTest is AdapterHarness {
    uint8 internal constant FAM = 1;
    uint24 internal constant KEY = uint24(FAM) << 16 | 1;
    address internal constant CUSTOM = address(0xB1AC4);
    /// The Python model, from the book of `_venueFor` (price 1, fee 3000, ranges +-40, +-96,
    /// +-200 of 1e21 each): 1e18 either way at the start; 15e18 token0 in, then 15e18 token1 in.
    uint256 internal constant Q1 = 996_668_773_744_192_346;
    uint256 internal constant S1 = 14_862_209_078_405_986_199;
    uint256 internal constant S2 = 15_047_788_051_631_072_538;
    /// D9, measured on this mock (build report): ticks a walk crosses under GATE_QUOTE_GAS.
    uint256 internal constant FLOOR = 24;
    uint256 internal constant PER_TICK_MAX = 16_000;
    uint256 internal constant OVER = 120;

    MockAlgebraFactory internal factory;
    MockAlgebraVenue internal venue;
    MockAlgebraPlugin internal plugin;
    BlazePhoenixAdapterAlgebraIntegral internal adapter;
    bytes32 internal INIT;
    address internal w;

    function setUp() public {
        _tokens();
        factory = new MockAlgebraFactory();
        INIT = keccak256(type(MockAlgebraVenue).creationCode);
        plugin = new MockAlgebraPlugin();
        venue = _venueFor(CUSTOM, address(plugin));
        adapter = new BlazePhoenixAdapterAlgebraIntegral(address(gate), address(factory), address(factory.deployer()), INIT);
        _accept(FAM, address(adapter));
        w = _wrap(CUSTOM, KEY);
    }

    /// Price 1 (tick 0), three ranges, 1 000 token0 and 2 000 token1 in the reserves.
    function _venueFor(address d, address plug) internal returns (MockAlgebraVenue v) {
        v = factory.createCustomVenue(d, address(t0), address(t1), plug);
        v.initialize(uint160(BPC.Q96), 0);
        v.mintRange(-200, 200, 1e21);
        v.mintRange(-96, 96, 1e21);
        v.mintRange(-40, 40, 1e21);
        t0.mint(address(v), 1_000e18);
        t1.mint(address(v), 2_000e18);
        v.sync();
    }

    /// A backstop range of 1e21 and `m` rungs below the price, 8 ticks apart: a 40e18 token0 in
    /// crosses every rung and fills inside the backstop.
    function _ladder(address d, uint256 m) internal returns (MockAlgebraVenue v) {
        v = factory.createCustomVenue(d, address(t0), address(t1), address(0));
        v.initialize(uint160(BPC.Q96), 0);
        v.mintRange(-800_000, 800_000, 1e21);
        for (uint256 k = 1; k <= m; ++k) v.mintRange(-int24(int256(8 * k)), 800_000, 1e9);
        t0.mint(address(v), 1_000e18);
        t1.mint(address(v), 1_000e18);
        v.sync();
    }

    function _wrap(address d, uint24 key) internal returns (address) {
        return gate.create(address(t0), address(t1), key, abi.encode(d));
    }

    function _leg(address wr) internal view returns (address, bytes32, bytes32) {
        BlazePhoenixGateWrapper x = BlazePhoenixGateWrapper(wr);
        return (x.venuePool(), x.aux0(), x.aux1());
    }

    /// Anti-vacuity: a wrapper on an untouched `_venueFor` book answers and swaps.
    function _assertLive(address wr) internal {
        (uint256 q, uint256 d) = BlazePhoenixGateWrapper(wr).quote(true, 1e18);
        assertEq(q, Q1, "live: the model's 1e18");
        assertEq(d, 1_000e18, "live: the short side of the reserves");
        assertEq(_swap(wr, true, 1e18), q, "live: the swap pays the quote");
    }

    /// Paused by the plugin policy: the adapter's quote (0, 0) and quoteCall 0, asked directly,
    /// the wrapper's likewise, and an exec through the wrapper reverts AdapterE(7).
    function _assertPaused(address wr) internal {
        BlazePhoenixGateWrapper x = BlazePhoenixGateWrapper(wr);
        (address vp, bytes32 a0, bytes32 a1) = _leg(wr);
        (uint256 q, uint256 d) = adapter.quote(vp, a0, a1, true, 1e18);
        assertEq(q + d, 0, "adapter quote");
        assertEq(adapter.quoteCall(vp, a0, a1, false, 1e18), 0, "adapter quoteCall");
        (q, d) = x.quote(false, 1e18);
        assertEq(q + d, 0, "wrapper quote");
        assertEq(x.quoteCall(true, 1e18), 0, "wrapper quoteCall");
        t0.mint(address(this), 1e18);
        vm.expectRevert(_aerr(7));
        x.swap(address(this), true, 1e18, 0, "");
    }

    // ─── execution: PULL by algebraSwapCallback, the venue's own output, nothing left behind ───

    function test_AI_Swap_BothWays_MultiTick_AgainstTheModel() public {
        assertEq(_swap(w, true, 15e18), S1, "15e18 token0 in: crosses -40 and -96");
        _assertEmpty(address(adapter), w, address(venue));
        assertEq(_swap(w, false, 15e18), S2, "15e18 token1 in: back up across -96 and -40");
        _assertEmpty(address(adapter), w, address(venue));
    }

    function test_AI_ExecReturnsTheOutputSideOfTheVenue() public {
        (address vp, bytes32 a0, bytes32 a1) = _leg(w);
        t0.mint(address(adapter), 1e18);
        uint256 b = t1.balanceOf(address(this));
        vm.prank(w);
        uint256 r = adapter.exec(vp, a0, a1, true, 1e18, address(this));
        assertEq(r, Q1, "zeroForOne: -amount1");
        assertEq(t1.balanceOf(address(this)) - b, r, "and the recipient got it");
        t1.mint(address(adapter), 1e18);
        b = t0.balanceOf(address(this));
        vm.prank(w);
        r = adapter.exec(vp, a0, a1, false, 1e18, address(this));
        assertGt(r, 0, "oneForZero answers");
        assertEq(t0.balanceOf(address(this)) - b, r, "oneForZero: -amount0");
    }

    function testFuzz_AI_CustodyEmptyAfterEveryExec(uint96 amt, bool zeroForOne) public {
        uint256 a = bound(amt, 1e6, 15e18);
        assertGt(_swap(w, zeroForOne, a), 0, "the swap pays");
        _assertEmpty(address(adapter), w, address(venue));
    }

    function test_AI_PullHasNoApproveInItsBytecode() public view {
        assertFalse(_hasApproveSelector(address(adapter)), "the venue pulls by callback, never by allowance");
    }

    function test_AI_QuoteEqualsQuoteCallEqualsExecution_BothWays() public {
        (address vp, bytes32 a0, bytes32 a1) = _leg(w);
        (uint256 q, ) = adapter.quote(vp, a0, a1, true, 15e18);
        assertEq(q, S1, "the walk is the model");
        assertEq(adapter.quoteCall(vp, a0, a1, true, 15e18), q, "quoteCall == quote");
        assertEq(_swap(w, true, 15e18), q, "the swap pays the quote");
        (q, ) = adapter.quote(vp, a0, a1, false, 15e18);
        assertEq(q, S2, "the walk is the model, the other way");
        assertEq(adapter.quoteCall(vp, a0, a1, false, 15e18), q, "quoteCall == quote");
        assertEq(_swap(w, false, 15e18), q, "the swap pays the quote");
    }

    // ─── depth18 and amounts: the reserves, the whole answer or 0 ───

    function test_AI_Depth18_IsTheReserves_NotTheBalances_ForAnyAmtIn() public {
        (address vp, bytes32 a0, bytes32 a1) = _leg(w);
        t0.mint(vp, 5_000e18);
        (uint256 q, uint256 d) = adapter.quote(vp, a0, a1, true, 0);
        assertEq(q, 0, "amtIn 0");
        assertEq(d, 1_000e18, "the reserves' short side, the donation ignored");
        (q, d) = adapter.quote(vp, a0, a1, false, 1e18);
        assertEq(q, Q1, "amtIn 1e18");
        assertEq(d, 1_000e18, "depth does not read amtIn");
    }

    function test_AI_Depth18_NormalisesDecimalsBeforeTheMin() public {
        MockERC20Dec d6 = new MockERC20Dec(6);
        MockAlgebraVenue v = factory.createCustomVenue(address(0xD6), address(d6), address(t1), address(0));
        v.initialize(uint160(BPC.Q96), 0);
        d6.mint(address(v), 1_000e6);
        t1.mint(address(v), 2_000e18);
        v.sync();
        (, uint256 d) = adapter.quote(address(v), 0, 0, true, 0);
        assertEq(d, 1_000e18, "1 000 of the 6-decimal token is the short side");
    }

    function test_AI_Quote_AmtInZeroOrAboveInt256_IsZero_WithDepth() public {
        (address vp, bytes32 a0, bytes32 a1) = _leg(w);
        uint256 big = uint256(type(int256).max) + 1;
        (uint256 q, uint256 d) = adapter.quote(vp, a0, a1, true, 0);
        assertEq(q, 0, "amtIn 0");
        assertEq(d, 1_000e18, "depth with amtIn 0");
        (q, d) = adapter.quote(vp, a0, a1, false, big);
        assertEq(q, 0, "above int256 max");
        assertEq(d, 1_000e18, "depth above int256 max");
        assertEq(adapter.quoteCall(vp, a0, a1, true, big), 0, "quoteCall above int256 max");
    }

    function test_AI_Quote_PartialFill_IsZero_AndTheSwapReverts() public {
        (address vp, bytes32 a0, bytes32 a1) = _leg(w);
        (uint256 q, ) = adapter.quote(vp, a0, a1, true, 15e18);
        assertEq(q, S1, "15e18 fits");
        (q, ) = adapter.quote(vp, a0, a1, true, 30e18);
        assertEq(q, 0, "30e18 runs past the last range: 0, not the part");
        assertEq(adapter.quoteCall(vp, a0, a1, true, 30e18), 0, "quoteCall likewise");
        t0.mint(address(this), 30e18);
        vm.expectRevert(_gerr(14));
        BlazePhoenixGateWrapper(w).swap(address(this), true, 30e18, 0, "");
    }

    function test_AI_Quote_VenueMidOperation_WrapperZero_AdapterReverts() public {
        _assertLive(w);
        (address vp, bytes32 a0, bytes32 a1) = _leg(w);
        venue.setIdle(false);
        (uint256 q, uint256 d) = BlazePhoenixGateWrapper(w).quote(true, 1e18);
        assertEq(q + d, 0, "wrapper quote");
        assertEq(BlazePhoenixGateWrapper(w).quoteCall(true, 1e18), 0, "wrapper quoteCall");
        vm.expectRevert(abi.encodeWithSelector(bytes4(0xcf309012)));
        adapter.quote(vp, a0, a1, true, 1e18);
    }

    function test_AI_Fee_IsTheLiveOne() public {
        venue.setFee(500);
        (uint256 q, ) = BlazePhoenixGateWrapper(w).quote(true, 1e18);
        assertGt(q, Q1, "fee 500 after create pays more than 3000");
        assertEq(_swap(w, true, 1e18), q, "and the swap agrees");
    }

    // ─── who may call: ExtAdapterBase (SHARED_QUANTITIES), then the callback ───

    function test_AI_ExecFromNonWrapper_Refused() public {
        (address vp, bytes32 a0, bytes32 a1) = _leg(w);
        t0.mint(address(adapter), 1e18);
        vm.expectRevert(_aerr(1));
        adapter.exec(vp, a0, a1, true, 1e18, address(this));
    }

    function test_AI_FakeWrapperWithRealTokens_Refused() public {
        (address vp, bytes32 a0, bytes32 a1) = _leg(w);
        address f = address(new FakeWrapperAI(address(t0), address(t1)));
        t0.mint(address(adapter), 1e18);
        vm.prank(f);
        vm.expectRevert(_aerr(1));
        adapter.exec(vp, a0, a1, true, 1e18, address(this));
    }

    function test_AI_ExecFromNonWrapper_RefusedBeforeThePlugin() public {
        (address vp, bytes32 a0, bytes32 a1) = _leg(w);
        venue.setPluginConfig(1);
        vm.expectRevert(_aerr(1));
        adapter.exec(vp, a0, a1, true, 1e18, address(this));
    }

    function test_AI_Exec_AmtInAboveInt256_Refused() public {
        (address vp, bytes32 a0, bytes32 a1) = _leg(w);
        uint256 big = uint256(type(int256).max) + 1;
        vm.prank(w);
        vm.expectRevert(_aerr(8));
        adapter.exec(vp, a0, a1, true, big, address(this));
    }

    function test_AI_Callback_OutsideExec_Refused() public {
        vm.expectRevert(_aerr(6));
        adapter.algebraSwapCallback(1, 0, "");
        vm.prank(address(venue));
        vm.expectRevert(_aerr(6));
        adapter.algebraSwapCallback(1, 0, "");
    }

    function test_AI_Callback_AsksMoreThanAmtIn_Refused() public {
        _assertLive(w);
        venue.setPay(MockAlgebraVenue.Pay.PlusOne);
        t0.mint(address(this), 1e18);
        vm.expectRevert(_aerr(6));
        BlazePhoenixGateWrapper(w).swap(address(this), true, 1e18, 0, "");
    }

    function test_AI_Callback_ZeroDeltas_Refused() public {
        _assertLive(w);
        venue.setPay(MockAlgebraVenue.Pay.Zero);
        t1.mint(address(this), 1e18);
        vm.expectRevert(_aerr(6));
        BlazePhoenixGateWrapper(w).swap(address(this), false, 1e18, 0, "");
    }

    // ─── identity and refusals at resolve (asked of the factory and CREATE2, once) ───

    function test_AI_Resolve_RecordsTheVenueAndPinsThePlugin() public view {
        (address vp, bytes32 a0, bytes32 a1) = _leg(w);
        assertEq(vp, address(venue), "the factory's custom venue");
        assertEq(a0, bytes32(uint256(uint160(address(plugin)))), "aux0: the plugin");
        assertEq(a1, address(plugin).codehash, "aux1: its code hash");
    }

    function test_AI_Resolve_MalformedHint_Refused() public {
        bytes[4] memory hs = [bytes(""), new bytes(31), abi.encodePacked(CUSTOM, bytes13(0)), abi.encode(CUSTOM, CUSTOM)];
        for (uint256 i; i < 4; ++i) {
            bytes memory h = hs[i];
            vm.expectRevert(_aerr(8));
            gate.create(address(t0), address(t1), KEY + 1, h);
        }
    }

    function test_AI_Resolve_DeployerZeroOrDirtyWord_Refused() public {
        bytes memory h = abi.encode(address(0));
        vm.expectRevert(_aerr(8));
        gate.create(address(t0), address(t1), KEY + 1, h);
        h = abi.encode(uint256(1) << 160 | uint160(CUSTOM));
        vm.expectRevert(_aerr(8));
        gate.create(address(t0), address(t1), KEY + 1, h);
    }

    function test_AI_Resolve_NotInTheRegistry_Refused() public {
        bytes memory h = abi.encode(address(0xD0));
        vm.expectRevert(_aerr(2));
        gate.create(address(t0), address(t1), KEY + 1, h);
    }

    function test_AI_Resolve_RegistryThatLies_Refused() public {
        address d = address(0xD2);
        factory.registerAs(d, address(t0), address(t1), address(venue));
        bytes memory h = abi.encode(d);
        vm.expectRevert(_aerr(2));
        gate.create(address(t0), address(t1), KEY + 1, h);
        MockAlgebraVenue other = factory.deployer().deploy(bytes32(uint256(7)), address(0), address(t0), address(t1));
        factory.registerAs(d, address(t0), address(t1), address(other));
        vm.expectRevert(_aerr(2));
        gate.create(address(t0), address(t1), KEY + 1, h);
    }

    function test_AI_Resolve_OtherTokensAtTheRightAddress_Refused() public {
        address d = address(0xD3);
        bytes32 salt = keccak256(abi.encode(d, address(t0), address(t1)));
        MockAlgebraVenue v = factory.deployer().deploy(salt, address(0), address(t1), address(t0));
        factory.registerAs(d, address(t0), address(t1), address(v));
        bytes memory h = abi.encode(d);
        vm.expectRevert(_aerr(3));
        gate.create(address(t0), address(t1), KEY + 1, h);
    }

    function test_AI_Resolve_BeforeSwapOrDynamicFee_Refused() public {
        MockAlgebraVenue v = _venueFor(address(0xD8), address(plugin));
        bytes memory h = abi.encode(address(0xD8));
        v.setPluginConfig(1);
        vm.expectRevert(_aerr(7));
        gate.create(address(t0), address(t1), KEY + 1, h);
        v.setPluginConfig(128);
        vm.expectRevert(_aerr(7));
        gate.create(address(t0), address(t1), KEY + 1, h);
        v.setPluginConfig(2 | 4 | 8 | 16 | 32 | 64);
        _assertLive(_wrap(address(0xD8), KEY + 1));
    }

    function test_AI_Resolve_PluginTheGateScanRefuses_Refused() public {
        address p = address(new MockAlgebraDirtyPlugin());
        assertFalse(gate.codeIsClean(p), "DELEGATECALL in the plugin");
        _venueFor(address(0xDA), p);
        bytes memory h = abi.encode(address(0xDA));
        vm.expectRevert(_aerr(7));
        gate.create(address(t0), address(t1), KEY + 1, h);
    }

    function test_AI_Resolve_PluginWithoutCode_Passes() public {
        _venueFor(address(0xD7), address(0xBEEF));
        address w2 = _wrap(address(0xD7), KEY + 1);
        (, bytes32 a0, bytes32 a1) = _leg(w2);
        assertEq(a0, bytes32(uint256(0xBEEF)), "aux0: the plugin address");
        assertEq(a1, bytes32(0), "aux1: no code");
        _assertLive(w2);
    }

    function test_AI_Constructor_ZeroArgument_Refused() public {
        (address g, address f, address dp, bytes32 ih) = (address(gate), address(factory), address(factory.deployer()), INIT);
        vm.expectRevert(_aerr(0));
        new BlazePhoenixAdapterAlgebraIntegral(g, address(0), dp, ih);
        vm.expectRevert(_aerr(0));
        new BlazePhoenixAdapterAlgebraIntegral(g, f, address(0), ih);
        vm.expectRevert(_aerr(0));
        new BlazePhoenixAdapterAlgebraIntegral(g, f, dp, bytes32(0));
    }

    // ─── plugins after create: `_pluginOk` on every exec, quote and quoteCall ───

    function test_AI_Plugin_RefusedFlagsAfterCreate_Pause() public {
        _assertLive(w);
        venue.setPluginConfig(1);
        _assertPaused(w);
        venue.setPluginConfig(128);
        _assertPaused(w);
    }

    function test_AI_Plugin_AfterSwapWithThePinnedPlugin_Passes() public {
        venue.setPluginConfig(2);
        _assertLive(w);
        assertEq(plugin.calls(), 1, "the venue ran afterSwap");
    }

    function test_AI_Plugin_AfterSwapWithAnotherPlugin_Pause() public {
        _assertLive(w);
        venue.setPlugin(address(new MockAlgebraPlugin()));
        venue.setPluginConfig(2);
        _assertPaused(w);
    }

    function test_AI_Plugin_AfterSwapSamePluginNewCode_Pause() public {
        _assertLive(w);
        venue.setPluginConfig(2);
        vm.etch(address(plugin), hex"00");
        _assertPaused(w);
    }

    function test_AI_Plugin_AfterSwapOff_ThePluginIsNotRead() public {
        venue.setPlugin(address(new MockAlgebraPlugin()));
        _assertLive(w);
    }

    function test_AI_Plugin_OtherFlagsIgnored() public {
        venue.setPluginConfig(4 | 8 | 16 | 32 | 64);
        _assertLive(w);
    }

    function test_AI_Plugin_AfterSwapReenters_Refused() public {
        (address vp, bytes32 a0, bytes32 a1) = _leg(w);
        venue.setPluginConfig(2);
        _assertLive(w);
        BlazePhoenixGateWrapper x = BlazePhoenixGateWrapper(w);
        t0.mint(address(this), 3e18);
        plugin.setReenter(address(adapter), abi.encodeCall(adapter.exec, (vp, a0, a1, true, 1, address(this))));
        vm.expectRevert(_aerr(1));
        x.swap(address(this), true, 1e18, 0, "");
        plugin.setReenter(address(adapter), abi.encodeCall(adapter.algebraSwapCallback, (int256(1), int256(0), bytes(""))));
        vm.expectRevert(_aerr(6));
        x.swap(address(this), true, 1e18, 0, "");
        plugin.setReenter(w, abi.encodeCall(x.swap, (address(this), true, int256(1), uint160(0), bytes(""))));
        vm.expectRevert(_gerr(11));
        x.swap(address(this), true, 1e18, 0, "");
    }

    // ─── D9: the walk is closed by GATE_QUOTE_GAS, never by a tick counter ───

    function test_AI_Walk_FloorOfTicksFitsUnderTheCap() public {
        _ladder(address(0xD91), FLOOR);
        address w2 = _wrap(address(0xD91), KEY + 1);
        address[] memory cold = new address[](1);
        cold[0] = _venueOf(w2);
        (uint256 out, , ) = _armUnderCap(w2, true, 40e18, cold);
        assertEq(_swap(w2, true, 40e18), out, "the capped walk is the swap");
    }

    function test_AI_Walk_PastTheCap_IsZero_NotARevert() public {
        _ladder(address(0xD92), OVER);
        address w2 = _wrap(address(0xD92), KEY + 1);
        GateQuoteArm arm = new GateQuoteArm();
        vm.cool(_venueOf(w2));
        (uint256 capped, , ) = arm.price(w2, true, 40e18, GATE_QUOTE_GAS);
        assertEq(capped, 0, "past the cap: 0, and the caller goes on");
        (uint256 free, , ) = arm.price(w2, true, 40e18, 30_000_000);
        assertGt(free, 0, "without the cap the walk answers");
        assertEq(_swap(w2, true, 40e18), free, "and it is the swap");
    }

    function test_AI_Walk_GasPerCrossedTick() public {
        MockAlgebraVenue a = _ladder(address(0xD93), 8);
        MockAlgebraVenue b = _ladder(address(0xD94), 32);
        (uint256 ga, uint256 oa) = _quoteGas(a);
        (uint256 gb, uint256 ob) = _quoteGas(b);
        assertGt(oa, 0, "8 rungs answer");
        assertGt(ob, 0, "32 rungs answer");
        uint256 per = (gb - ga) / 24;
        emit log_named_uint("gas per crossed tick (cold venue)", per);
        emit log_named_uint("gas of the 8-rung quote", ga);
        assertLe(per, PER_TICK_MAX, "one read of the tick per crossing");
    }

    function _venueOf(address wr) internal view returns (address vp) {
        (vp, , ) = _leg(wr);
    }

    function _quoteGas(MockAlgebraVenue v) internal returns (uint256 g, uint256 out) {
        vm.cool(address(v));
        vm.cool(address(adapter));
        uint256 g0 = gasleft();
        (out, ) = adapter.quote(address(v), 0, 0, true, 40e18);
        g = g0 - gasleft();
    }

    // ─── the venue's ABI and the Gate's scan ───

    /// `cast sig` of Algebra Integral's own signatures (IAlgebraPoolState, IAlgebraPoolActions,
    /// IAlgebraFactory, IAlgebraSwapCallback).
    function test_AI_InterfaceSelectorsAreTheVenues() public pure {
        assertEq(IAlgebraVenue.safelyGetStateOfAMM.selector, bytes4(0x97ce1c51), "safelyGetStateOfAMM()");
        assertEq(IAlgebraVenue.ticks.selector, bytes4(0xf30dba93), "ticks(int24)");
        assertEq(IAlgebraVenue.swap.selector, bytes4(0x128acb08), "swap(address,bool,int256,uint160,bytes)");
        assertEq(IAlgebraVenue.getReserves.selector, bytes4(0x0902f1ac), "getReserves()");
        assertEq(IAlgebraVenue.plugin.selector, bytes4(0xef01df4f), "plugin()");
        assertEq(IAlgebraCustomFactory.customPoolByPair.selector, bytes4(0x23da36cc), "customPoolByPair(address,address,address)");
        assertEq(BlazePhoenixAdapterAlgebraIntegral.algebraSwapCallback.selector, bytes4(0x2c8958f6), "algebraSwapCallback(int256,int256,bytes)");
    }

    function test_AI_CodeIsCleanForTheGate() public view {
        assertTrue(gate.codeIsClean(address(adapter)), "the Gate's scan");
    }
}
