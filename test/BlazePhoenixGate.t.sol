// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  THE GATE (gate-1021, phase 2): one immutable CREATE2 factory of V3-shaped
//  wrappers in front of venues the Core cannot read. Every guard below has one
//  test that names the quantity it pins, and one mutant in mutants.py.
//
//  Oracle: the tokens' balances, the venue's own price rule, and an address
//  computed here from the CREATE2 formula; never the code under test.
//
//  Cheatcodes: vm.warp (time passing is the route), vm.prank (a stranger is the
//  route), vm.etch ONLY where the EVM offers no route: a code change under a
//  scanned adapter (no SELFDESTRUCT, so no redeploy) and an EIP-7702 designator
//  (CREATE refuses a 0xEF prefix, and the profile is Cancun).
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixGate, BlazePhoenixGateWrapper, IExtAdapter} from "../src/BlazePhoenixGate.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixQuoter} from "../src/BlazePhoenixQuoter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg, PoolInfo, RoutePlan} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV3Pool} from "./mocks/MockV3Pool.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";
import {
    MockGateVenue, MockGateRegistry, MockGateAdapter, MockGateHostileAdapter
} from "./mocks/MockGateAdapters.sol";

/// A Solver that answers a fixed plan: the best door's only input it does not choose.
contract GateBestPlanStub {
    bytes internal blob;
    function setPlan(RoutePlan memory p) external { blob = abi.encode(p); }
    function findBestRoutePlan(address, address, uint256) external view returns (RoutePlan memory) {
        return abi.decode(blob, (RoutePlan));
    }
}

contract BlazePhoenixGateTest is Test {
    uint8 constant FAM = 1;
    uint24 constant KEY = uint24(uint256(FAM) << 16 | 1);
    uint8 constant HFAM = 2;
    uint24 constant HKEY = uint24(uint256(HFAM) << 16 | 1);
    uint160 constant Q96 = uint160(uint256(1) << 96);

    BlazePhoenixGate gate;
    BlazePhoenixHub hub;
    MockGateRegistry reg;
    MockGateVenue venue;
    MockGateAdapter adapter;
    MockGateHostileAdapter hostile;
    MockERC20 t0;
    MockERC20 t1;

    // The callback payer (this contract, when it calls a wrapper directly).
    uint256 shortBy;

    function setUp() public {
        MockERC20 a = new MockERC20("A", "A");
        MockERC20 b = new MockERC20("B", "B");
        (t0, t1) = address(a) < address(b) ? (a, b) : (b, a);
        gate = new BlazePhoenixGate(address(this));
        reg = new MockGateRegistry();
        venue = new MockGateVenue(address(t0), address(t1));
        reg.add(address(venue));
        t0.mint(address(venue), 1_000_000e18);
        t1.mint(address(venue), 1_000_000e18);
        venue.sync();
        adapter = new MockGateAdapter(gate, reg);
        hostile = new MockGateHostileAdapter(gate, reg);
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0xBEEF));
        hub.setRoles(address(this), address(this), address(this));
    }

    // ─── helpers ───

    function _err(uint8 c) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(BlazePhoenixGate.GateE.selector, c);
    }

    function _rerr(uint16 c) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, c);
    }

    function _accept(uint8 f, address a) internal {
        gate.proposeAdapter(f, a);
        vm.warp(block.timestamp + gate.ADAPTER_DELAY());
        gate.acceptAdapter(f);
    }

    function _wrapper() internal returns (BlazePhoenixGateWrapper w) {
        _accept(FAM, address(adapter));
        w = BlazePhoenixGateWrapper(gate.create(address(t1), address(t0), KEY, abi.encode(address(venue))));
    }

    function _hostileWrapper(uint8 mode) internal returns (BlazePhoenixGateWrapper w) {
        _accept(HFAM, address(hostile));
        w = BlazePhoenixGateWrapper(gate.create(address(t0), address(t1), HKEY, abi.encode(address(venue))));
        hostile.setMode(mode);
    }

    /// Runtime `code` behind a 10-byte deployer: PUSH2 len, DUP1, PUSH1 10, PUSH0, CODECOPY, PUSH0, RETURN.
    function _deployRaw(bytes memory code) internal returns (address a) {
        bytes memory init = abi.encodePacked(hex"61", uint16(code.length), hex"80600a5f395ff3", code);
        assembly { a := create(0, add(init, 0x20), mload(init)) }
        require(a != address(0) && a.code.length == code.length, "raw deploy");
    }

    function uniswapV3SwapCallback(int256 a0, int256 a1, bytes calldata) external {
        BlazePhoenixGateWrapper w = BlazePhoenixGateWrapper(msg.sender);
        if (a0 > 0) MockERC20(w.token0()).transfer(msg.sender, uint256(a0) - shortBy);
        else if (a1 > 0) MockERC20(w.token1()).transfer(msg.sender, uint256(a1) - shortBy);
    }

    // ─── roles: create and the registry are the curator's ───

    /// Quantity: who may fix a (t0, t1, venueKey) slot for ever.
    function test_GateF2_Create_OnlyTheCurator() public {
        _accept(FAM, address(adapter));
        vm.prank(address(0xBAD));
        vm.expectRevert(_err(1));
        gate.create(address(t0), address(t1), KEY, abi.encode(address(venue)));
    }

    /// Quantity: who may propose an adapter (and accept one).
    function test_GateF2_ProposeAccept_OnlyTheCurator() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(_err(1));
        gate.proposeAdapter(FAM, address(adapter));
        gate.proposeAdapter(FAM, address(adapter));
        vm.warp(block.timestamp + 48 hours);
        vm.prank(address(0xBAD));
        vm.expectRevert(_err(1));
        gate.acceptAdapter(FAM);
    }

    // ─── create: arguments, live adapter, resolve, wrapper registry ───

    /// Quantity: venueKey 0 is the Hub's Algebra sentinel; a wrapper under it would never be found.
    /// Family 0 has a live adapter here, so without the check the create would land.
    function test_GateF2_Create_RefusesVenueKeyZero() public {
        _accept(0, address(adapter));
        vm.expectRevert(_err(3));
        gate.create(address(t0), address(t1), 0, abi.encode(address(venue)));
    }

    /// Quantity: a family with no live adapter cannot mint wrappers.
    function test_GateF2_Create_RefusesAFamilyWithoutAdapter() public {
        vm.expectRevert(_err(4));
        gate.create(address(t0), address(t1), uint24(3 << 16 | 1), abi.encode(address(venue)));
    }

    /// Quantity: the venue pool comes from the adapter's resolve, and "no pool" is refused.
    function test_GateF2_Create_RefusesAResolveWithoutPool() public {
        _accept(HFAM, address(hostile));
        hostile.setMode(hostile.ZERO_POOL());
        vm.expectRevert(_err(5));
        gate.create(address(t0), address(t1), HKEY, abi.encode(address(venue)));
    }

    /// Quantity: the wrapper's address is CREATE2(gate, Core.v3Salt(t0, t1, key), initHash), with
    /// v3Salt = keccak(abi.encode(t0, t1, key)) written out here from the formula; the Gate marks
    /// it; its fields are the resolve answer.
    function test_GateF2_Create_DerivedAddressAndRegistry() public {
        BlazePhoenixGateWrapper w = _wrapper();
        bytes32 initHash = keccak256(type(BlazePhoenixGateWrapper).creationCode);
        address expect = address(uint160(uint256(keccak256(abi.encodePacked(
            bytes1(0xff), address(gate), keccak256(abi.encode(address(t0), address(t1), KEY)), initHash)))));
        assertEq(address(w), expect, "wrapper address = CREATE2 over the V3 salt");
        assertEq(gate.wrapperAddress(address(t0), address(t1), KEY), expect, "wrapperAddress agrees");
        assertEq(gate.WRAPPER_INIT_HASH(), initHash, "the init hash the Hub row carries");
        assertTrue(gate.isWrapper(address(w)), "the Gate marks its wrapper");
        assertFalse(gate.isWrapper(address(venue)), "and nothing else");
        assertEq(w.token0(), address(t0));
        assertEq(w.token1(), address(t1));
        assertEq(w.fee(), KEY);
        assertEq(w.family(), FAM);
        assertEq(w.venuePool(), address(venue));
        assertEq(w.gate(), address(gate));
    }

    // ─── the opcode scan ───

    /// Quantity: codeIsClean refuses DELEGATECALL.
    function test_GateF2_Scan_RefusesDelegatecall() public {
        address a = _deployRaw(hex"5f5f5f5f5f5ff400");
        assertFalse(gate.codeIsClean(a));
        vm.expectRevert(_err(6));
        gate.proposeAdapter(FAM, a);
    }

    /// Quantity: codeIsClean refuses CALLCODE.
    function test_GateF2_Scan_RefusesCallcode() public {
        address a = _deployRaw(hex"5f5f5f5f5f5f5ff200");
        assertFalse(gate.codeIsClean(a));
        vm.expectRevert(_err(6));
        gate.proposeAdapter(FAM, a);
    }

    /// Quantity: codeIsClean refuses SELFDESTRUCT.
    function test_GateF2_Scan_RefusesSelfdestruct() public {
        address a = _deployRaw(hex"5fff");
        assertFalse(gate.codeIsClean(a));
        vm.expectRevert(_err(6));
        gate.proposeAdapter(FAM, a);
    }

    /// Quantity: an account with no code is no adapter.
    function test_GateF2_Scan_RefusesEmptyCode() public {
        assertFalse(gate.codeIsClean(address(0xE0A)));
        vm.expectRevert(_err(6));
        gate.proposeAdapter(FAM, address(0xE0A));
    }

    /// Quantity: an EIP-7702 designator (0xEF0100 || delegate) can be re-pointed; refused.
    /// vm.etch: CREATE refuses a 0xEF prefix (EIP-3541) and the profile is Cancun.
    function test_GateF2_Scan_Refuses7702Designator() public {
        address eoa = address(0x7702);
        vm.etch(eoa, abi.encodePacked(hex"ef0100", address(0x1111111111111111111111111111111111111111)));
        assertFalse(gate.codeIsClean(eoa));
        vm.expectRevert(_err(6));
        gate.proposeAdapter(FAM, eoa);
    }

    /// Quantity: PUSH data is stepped over (a banned byte inside it is not an opcode).
    function test_GateF2_Scan_StepsOverPushData() public {
        assertTrue(gate.codeIsClean(_deployRaw(hex"61f4f400")), "PUSH2 f4f4");
        assertTrue(gate.codeIsClean(_deployRaw(
            hex"7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff00")), "PUSH32 ff..ff");
        assertTrue(gate.codeIsClean(address(adapter)), "the honest mock passes");
        assertTrue(gate.codeIsClean(address(hostile)), "the hostile mock uses no banned opcode either");
    }

    /// The wrapper itself: clean, and it never approves (no PUSH4 0x095ea7b3). No mutant: a
    /// property of the compiled code, read here as a regression.
    function test_GateF2_Scan_WrapperIsCleanAndNeverApproves() public {
        BlazePhoenixGateWrapper w = _wrapper();
        assertTrue(gate.codeIsClean(address(w)));
        bytes memory c = address(w).code;
        for (uint256 i; i + 4 < c.length; ++i) {
            bool hit = c[i] == 0x63 && c[i + 1] == 0x09 && c[i + 2] == 0x5e && c[i + 3] == 0xa7 && c[i + 4] == 0xb3;
            assertFalse(hit, "wrapper code carries the approve selector");
        }
    }

    // ─── timelock and pin ───

    /// Quantity: accept lands at eta = propose + 48 h, not one second before.
    function test_GateF2_Accept_TimelockOf48Hours() public {
        gate.proposeAdapter(FAM, address(adapter));
        (, uint64 eta, ) = gate.pendingOf(FAM);
        assertEq(uint256(eta), block.timestamp + 48 hours);
        vm.warp(uint256(eta) - 1);
        vm.expectRevert(_err(7));
        gate.acceptAdapter(FAM);
        vm.warp(uint256(eta));
        gate.acceptAdapter(FAM);
        assertEq(gate.adapterOf(FAM), address(adapter));
        assertEq(gate.pinOf(FAM), address(adapter).codehash);
    }

    /// Quantity: the code accepted is the code proposed. vm.etch: no route changes scanned code.
    function test_GateF2_Accept_RefusesCodeMovedSinceProposal() public {
        gate.proposeAdapter(FAM, address(adapter));
        vm.etch(address(adapter), address(hostile).code);
        vm.warp(block.timestamp + 48 hours);
        vm.expectRevert(_err(9));
        gate.acceptAdapter(FAM);
    }

    /// Quantity: liveAdapter is zero once the code moves from the pin; swap and quote follow.
    function test_GateF2_LiveAdapter_DropsWhenCodeLeavesThePin() public {
        BlazePhoenixGateWrapper w = _wrapper();
        vm.etch(address(adapter), address(hostile).code);
        assertEq(gate.liveAdapter(FAM), address(0), "pin broken -> no live adapter");
        t0.mint(address(this), 10e18);
        vm.expectRevert(_err(4));
        w.swap(address(this), true, 1e18, 0, "");
        (uint256 q, ) = w.quote(true, 1e18);
        assertEq(q, 0, "quote follows the pin");
    }

    // ─── renounce: grow-only ───

    /// R1: a family that was ever live cannot be refilled after renounce.
    function test_GateF2_Renounce_RefusesReplacingAFamily() public {
        _accept(FAM, address(adapter));
        gate.renounceControl();
        vm.expectRevert(_err(10));
        gate.proposeAdapter(FAM, address(hostile));
    }

    /// R2: a proposal made before the renounce cannot land after it.
    function test_GateF2_Renounce_RefusesAPendingReplacement() public {
        _accept(FAM, address(adapter));
        gate.proposeAdapter(FAM, address(hostile));
        gate.renounceControl();
        vm.warp(block.timestamp + 48 hours);
        vm.expectRevert(_err(10));
        gate.acceptAdapter(FAM);
        assertEq(gate.adapterOf(FAM), address(adapter), "the family keeps its adapter");
    }

    /// R3: a new family still grows after renounce, wrappers included.
    function test_GateF2_Renounce_NewFamilyStillGrows() public {
        _accept(FAM, address(adapter));
        gate.renounceControl();
        uint8 f = 4;
        MockGateAdapter a2 = new MockGateAdapter(gate, reg);
        _accept(f, address(a2));
        address w = gate.create(address(t0), address(t1), uint24(uint256(f) << 16 | 1), abi.encode(address(venue)));
        assertTrue(gate.isWrapper(w));
    }

    /// Quantity: the brake and the admin seat die with control.
    function test_GateF2_Renounce_ControlDies() public {
        _accept(FAM, address(adapter));
        vm.prank(address(0xBAD));
        vm.expectRevert(_err(2));
        gate.clearAdapter(FAM);
        gate.renounceControl();
        vm.expectRevert(_err(2));
        gate.clearAdapter(FAM);
        vm.expectRevert(_err(2));
        gate.setAdmin(address(0xA2));
        assertEq(gate.liveAdapter(FAM), address(adapter));
    }

    // ─── clear: instant brake ───

    /// Quantity: after clear, the family's wrappers stop at once.
    function test_GateF2_Clear_StopsTheFamilyInstantly() public {
        BlazePhoenixGateWrapper w = _wrapper();
        gate.clearAdapter(FAM);
        assertEq(gate.adapterOf(FAM), address(0));
        assertEq(gate.liveAdapter(FAM), address(0));
        t0.mint(address(this), 10e18);
        vm.expectRevert(_err(4));
        w.swap(address(this), true, 1e18, 0, "");
    }

    /// Quantity: clear also kills what was pending.
    function test_GateF2_Clear_KillsThePending() public {
        gate.proposeAdapter(FAM, address(adapter));
        gate.clearAdapter(FAM);
        vm.warp(block.timestamp + 48 hours);
        vm.expectRevert(_err(8));
        gate.acceptAdapter(FAM);
    }

    /// Quantity: wrapper.quote is 0 for a cleared family (the adapter is never asked).
    function test_GateF2_Clear_QuoteIsZero() public {
        BlazePhoenixGateWrapper w = _wrapper();
        (uint256 q, ) = w.quote(true, 1e18);
        assertEq(q, venue.quoteSell(1e18), "the neighbour: a live family quotes");
        assertEq(w.quoteCall(true, 1e18), venue.quoteSell(1e18), "the neighbour: quoteCall agrees with quote");
        gate.clearAdapter(FAM);
        (q, ) = w.quote(true, 1e18);
        assertEq(q, 0, "a cleared family quotes 0");
        assertEq(w.quoteCall(true, 1e18), 0, "and quoteCall answers 0, it does not revert");
    }

    // ─── the wrapper's custody against a hostile adapter ───

    /// Quantity: the adapter ends with no more input token than it had.
    function test_GateF2_Wrapper_AdapterKeepsInputRefused() public {
        BlazePhoenixGateWrapper w = _hostileWrapper(1);
        t1.mint(address(hostile), 10e18);
        t0.mint(address(this), 1e18);
        vm.expectRevert(_err(14));
        w.swap(address(this), true, 1e18, 0, "");
    }

    /// Quantity: the adapter ends with no more output token than it had.
    function test_GateF2_Wrapper_AdapterSkimsOutputRefused() public {
        BlazePhoenixGateWrapper w = _hostileWrapper(2);
        t0.mint(address(this), 1e18);
        vm.expectRevert(_err(14));
        w.swap(address(this), true, 1e18, 0, "");
    }

    /// Quantity: no re-entry into a wrapper during its own swap.
    function test_GateF2_Wrapper_ReentryRefused() public {
        BlazePhoenixGateWrapper w = _hostileWrapper(3);
        t0.mint(address(this), 1e18);
        vm.expectRevert(_err(11));
        w.swap(address(this), true, 1e18, 0, "");
    }

    /// Quantity: the caller pays at least what it asked to sell.
    function test_GateF2_Wrapper_UnderpaidRefused() public {
        BlazePhoenixGateWrapper w = _wrapper();
        t0.mint(address(this), 1e18);
        shortBy = 1;
        vm.expectRevert(_err(13));
        w.swap(address(this), true, 1e18, 0, "");
    }

    /// Quantity: exact-in only (amountSpecified > 0).
    function test_GateF2_Wrapper_ExactInOnly() public {
        BlazePhoenixGateWrapper w = _wrapper();
        t0.mint(address(this), 1e18);
        vm.expectRevert(_err(12));
        w.swap(address(this), true, -1e18, 0, "");
    }

    /// Quantity: the wrapper's output is the delta at the recipient, never the adapter's word.
    /// The recipient starts with a balance, and the adapter claims ten times what it paid.
    function test_GateF2_Wrapper_OutputIsTheMeasuredDelta() public {
        BlazePhoenixGateWrapper w = _hostileWrapper(4);
        address rcpt = address(0xCAFE);
        t1.mint(rcpt, 7e18);
        t0.mint(address(this), 1e18);
        (int256 a0, int256 a1) = w.swap(rcpt, true, 1e18, 0, "");
        uint256 paid = uint256(1e18) * 9_970 / 10_000;
        assertEq(a0, 1e18, "input leg");
        assertEq(a1, -int256(paid), "output = the venue's payment, measured");
        assertEq(t1.balanceOf(rcpt), 7e18 + paid);
        assertEq(t0.balanceOf(address(w)) + t1.balanceOf(address(w)), 0, "the wrapper holds nothing");
    }

    // ─── Hub: the Gate is a factory row, the wrapper is found by derivation ───

    function _gateRow(BlazePhoenixGate g) internal {
        uint24[] memory fees = new uint24[](1);
        fees[0] = KEY;
        hub.addFactory(address(g), BPC.KIND_EXTERNAL, 5, g.WRAPPER_INIT_HASH(), fees, new int24[](0));
    }

    /// Quantity: discoverFor lists the Gate's wrapper (kind 9, fee = venueKey), and only the
    /// wrapper the admitted Gate made: another Gate's wrapper for the same tuple is not found.
    function test_GateF2_Hub_DiscoversTheWrapperByDerivation() public {
        assertEq(BPC.KIND_EXTERNAL, 9);
        _gateRow(gate);
        assertEq(hub.discoverFor(address(t0), address(t1)).length, 0, "nothing before create");
        BlazePhoenixGateWrapper w = _wrapper();
        BlazePhoenixGate g2 = new BlazePhoenixGate(address(this));
        g2.proposeAdapter(FAM, address(adapter));
        vm.warp(block.timestamp + 48 hours);
        g2.acceptAdapter(FAM);
        address w2 = g2.create(address(t0), address(t1), KEY, abi.encode(address(venue)));
        PoolInfo[] memory h = hub.discoverFor(address(t1), address(t0));
        assertEq(h.length, 1, "one hit");
        assertEq(h[0].pool, address(w), "the admitted Gate's wrapper");
        assertTrue(h[0].pool != w2, "never another Gate's");
        assertEq(h[0].kind, BPC.KIND_EXTERNAL);
        assertEq(h[0].fee, KEY);
    }

    // ─── Router: end to end through the wrapper ───

    function _router() internal returns (BlazePhoenixRouter r) {
        r = new BlazePhoenixRouter(address(hub), address(0xD0D0), address(this), address(0xFEE1), address(0xFEE2));
    }

    function _route(address pool, uint8 kind, uint24 fee, uint256 amt, uint256 exp)
        internal view returns (Route memory r)
    {
        Leg[] memory l = new Leg[](1);
        l[0] = Leg({pool: pool, hooks: address(0), kind: kind, fee: fee, tickSpacing: 0,
            zeroForOne: true, stable: false, amountIn: amt, expectedOut: exp, auxId: bytes32(0)});
        Hop[] memory hs = new Hop[](1);
        hs[0] = Hop({tokenIn: address(t0), tokenOut: address(t1), amountIn: amt, expectedOut: exp, legs: l});
        r = Route({hops: hs, totalOut: exp, singleOut: 0, singleOutFloor: 0, expectedImpactBps: 0,
            confidenceWad: 0, estGas: 0, hasSurplus: false, isV4Bundle: false});
    }

    function _user(BlazePhoenixRouter router, uint256 amt) internal returns (address u) {
        u = address(0xA11CE);
        t0.mint(u, amt);
        vm.prank(u);
        t0.approve(address(router), type(uint256).max);
    }

    /// Quantity: a kind-9 leg settles through the Router's V3 callback, every party ends at 0,
    /// and the adapter's quote is never asked during execution.
    function test_GateF2_Router_SettlesThroughTheWrapper() public {
        BlazePhoenixGateWrapper w = _wrapper();
        BlazePhoenixRouter router = _router();
        uint256 amt = 1_000e18;
        address u = _user(router, amt);
        uint256 exp = venue.quoteSell(amt);
        vm.expectCall(address(adapter), abi.encodeWithSelector(IExtAdapter.quote.selector), 0);
        vm.expectCall(address(adapter), abi.encodeWithSelector(IExtAdapter.quoteCall.selector), 0);
        vm.prank(u);
        uint256 out = router.swapExactIn(_route(address(w), BPC.KIND_EXTERNAL, KEY, amt, exp), amt, 1, u,
            block.timestamp + 1);
        assertGt(out, 0);
        assertEq(t1.balanceOf(u), out, "the user receives what the Router measured");
        assertEq(t0.balanceOf(address(router)) + t1.balanceOf(address(router)), 0, "Router at 0");
        assertEq(t0.balanceOf(address(w)) + t1.balanceOf(address(w)), 0, "wrapper at 0");
        assertEq(t0.balanceOf(address(adapter)) + t1.balanceOf(address(adapter)), 0, "adapter at 0");
        assertEq(t0.allowance(address(router), address(w)), 0, "no allowance to the wrapper");
    }

    /// Quantity: the per-leg floor binds a kind-9 leg through its attestation (claimed 10x).
    function test_GateF2_Router_InflatedAttestationRefused() public {
        BlazePhoenixGateWrapper w = _wrapper();
        BlazePhoenixRouter router = _router();
        uint256 amt = 1_000e18;
        address u = _user(router, amt);
        Route memory r = _route(address(w), BPC.KIND_EXTERNAL, KEY, amt, venue.quoteSell(amt) * 10);
        vm.prank(u);
        vm.expectRevert(_rerr(5));
        router.swapExactIn(r, amt, 1, u, block.timestamp + 1);
    }

    /// Quantity: the same floor when the venue pays half of what it quoted.
    function test_GateF2_Router_VenuePaysHalfRefused() public {
        BlazePhoenixGateWrapper w = _wrapper();
        BlazePhoenixRouter router = _router();
        uint256 amt = 1_000e18;
        address u = _user(router, amt);
        Route memory r = _route(address(w), BPC.KIND_EXTERNAL, KEY, amt, venue.quoteSell(amt));
        venue.setPayBps(5_000);
        vm.prank(u);
        vm.expectRevert(_rerr(5));
        router.swapExactIn(r, amt, 1, u, block.timestamp + 1);
    }

    /// Quantity: userMinOut is exact on a kind-9 route: out passes, out + 1 reverts.
    function testFuzz_GateF2_Router_UserMinOutIsExact(uint256 amt) public {
        amt = bound(amt, 1e12, 100_000e18);
        BlazePhoenixGateWrapper w = _wrapper();
        BlazePhoenixRouter router = _router();
        address u = _user(router, amt);
        Route memory r = _route(address(w), BPC.KIND_EXTERNAL, KEY, amt, venue.quoteSell(amt));
        uint256 snap = vm.snapshotState();
        vm.prank(u);
        uint256 out = router.swapExactIn(r, amt, 1, u, block.timestamp + 1);
        vm.revertToState(snap);
        vm.prank(u);
        vm.expectRevert(_rerr(5));
        router.swapExactIn(r, amt, out + 1, u, block.timestamp + 1);
        vm.prank(u);
        assertEq(router.swapExactIn(r, amt, out, u, block.timestamp + 1), out);
    }

    /// Quantity: after clear the kind-9 route reverts and a native V3 route still settles.
    function test_GateF2_Router_ClearStopsOnlyTheFamily() public {
        BlazePhoenixGateWrapper w = _wrapper();
        BlazePhoenixRouter router = _router();
        uint256 amt = 1_000e18;
        address u = _user(router, 2 * amt);
        gate.clearAdapter(FAM);
        Route memory r9 = _route(address(w), BPC.KIND_EXTERNAL, KEY, amt, venue.quoteSell(amt));
        vm.prank(u);
        vm.expectRevert(_err(4));
        router.swapExactIn(r9, amt, 1, u, block.timestamp + 1);
        MockV3Pool p = new MockV3Pool(address(t0), address(t1), 3000);
        p.setState(Q96, uint128(1e27));
        t1.mint(address(p), 1_000_000e18);
        uint256 exp = BPC.outV3(amt, Q96, uint128(1e27), 3000, true, 0);
        vm.prank(u);
        uint256 out = router.swapExactIn(_route(address(p), BPC.KIND_V3, 3000, amt, exp), amt, 1, u,
            block.timestamp + 1);
        assertGt(out, 0, "the native V3 leg still settles");
    }

    // ─── the best door: kind 9 enters by explicit routes only (owner's decision, 21/10) ───

    function _plan(Route memory r) internal pure returns (RoutePlan memory p) {
        p.best = r;
    }

    /// Quantity: the execution dispatch (`k == KIND_EXTERNAL && msg.sender != address(this)`)
    /// refuses kind 9 when the leg arrives through the best door (selfExecutePrePulled). The same plan settles by swapExactIn, and
    /// the same door settles a V3 plan: the refusal is the kind's, at that door.
    function test_GateF2_BestDoor_RefusesKindExternal() public {
        BlazePhoenixGateWrapper w = _wrapper();
        GateBestPlanStub stub = new GateBestPlanStub();
        BlazePhoenixRouter router =
            new BlazePhoenixRouter(address(hub), address(stub), address(this), address(0xFEE1), address(0xFEE2));
        uint256 amt = 1_000e18;
        address u = _user(router, 3 * amt);
        Route memory r9 = _route(address(w), BPC.KIND_EXTERNAL, KEY, amt, venue.quoteSell(amt));
        stub.setPlan(_plan(r9));
        vm.prank(u);
        vm.expectRevert(_rerr(8));
        router.swapBestExactIn(address(t0), address(t1), amt, 1, u, block.timestamp + 1);

        vm.prank(u);
        assertGt(router.swapExactIn(r9, amt, 1, u, block.timestamp + 1), 0, "the explicit door settles it");

        MockV3Pool p = new MockV3Pool(address(t0), address(t1), 3000);
        p.setState(Q96, uint128(1e27));
        t1.mint(address(p), 1_000_000e18);
        stub.setPlan(_plan(_route(address(p), BPC.KIND_V3, 3000, amt,
            BPC.outV3(amt, Q96, uint128(1e27), 3000, true, 0))));
        vm.prank(u);
        assertGt(router.swapBestExactIn(address(t0), address(t1), amt, 1, u, block.timestamp + 1), 0,
            "the best door settles a V3 plan");
    }

    /// Quantity: with the Gate admitted and its wrapper discovered, the real Solver plans no
    /// kind-9 leg and the best door still settles the pair through its other venue. Zero bytes
    /// in the Solver: the wrapper has no reader there, so it quotes 0 and is dropped.
    function test_GateF2_Solver_NeverPlansTheWrapper() public {
        _gateRow(gate);
        BlazePhoenixGateWrapper w = _wrapper();
        BlazePhoenixSolver solver = new BlazePhoenixSolver(address(hub));
        BlazePhoenixRouter router =
            new BlazePhoenixRouter(address(hub), address(solver), address(this), address(0xFEE1), address(0xFEE2));
        hub.setRoles(address(router), address(solver), address(this));
        MockV2Pair pair = new MockV2Pair(address(t0), address(t1));
        pair.setReserves(1_000_000e18, 1_000_000e18);
        t0.mint(address(pair), 1_000_000e18);
        t1.mint(address(pair), 1_000_000e18);
        hub.seedPool(address(pair), BPC.KIND_V2, 30, address(0), address(t0), address(t1));
        PoolInfo[] memory d = hub.discoverFor(address(t0), address(t1));
        assertEq(d.length, 1, "setup: discovery finds the wrapper");
        assertEq(d[0].pool, address(w), "setup: the hit is the wrapper");

        uint256 amt = 1_000e18;
        RoutePlan memory plan = solver.findBestRoutePlan(address(t0), address(t1), amt);
        assertGt(plan.best.hops.length, 0, "setup: the pair has a plan");
        for (uint256 h; h < plan.best.hops.length; h++) {
            for (uint256 l; l < plan.best.hops[h].legs.length; l++) {
                assertTrue(plan.best.hops[h].legs[l].kind != BPC.KIND_EXTERNAL, "no kind-9 leg in a Solver plan");
                assertTrue(plan.best.hops[h].legs[l].pool != address(w), "the wrapper is never planned");
            }
        }
        address u = _user(router, amt);
        vm.prank(u);
        assertGt(router.swapBestExactIn(address(t0), address(t1), amt, 1, u, block.timestamp + 1), 0,
            "the best door settles through the other venue");
    }

    // ─── the Quoter: Gate legs are priced by their adapter, on an off-chain route ───

    /// Quantity: Quoter._priceLeg (through previewRouteExact) prices a kind-9 leg with wrapper.quote, and its
    /// exactOut is what the Router delivers for the same route (out == exactOut).
    function test_GateF2_Quoter_PricesTheWrapperAsExecuted() public {
        BlazePhoenixGateWrapper w = _wrapper();
        BlazePhoenixRouter router = _router();
        BlazePhoenixQuoter quoter = new BlazePhoenixQuoter(address(hub), address(0xD0D0));
        uint256 amt = 1_000e18;
        address u = _user(router, amt);
        (Route memory q, uint256 exactOut) =
            quoter.previewRouteExact(_route(address(w), BPC.KIND_EXTERNAL, KEY, amt, 0), amt);
        assertEq(q.hops[0].legs[0].expectedOut, venue.quoteSell(amt), "the leg is the adapter's quote");
        assertGt(exactOut, 0);
        vm.prank(u);
        uint256 out = router.swapExactIn(q, amt, exactOut, u, block.timestamp + 1);
        assertEq(out, exactOut, "quote == execution");
    }

    /// Quantity: when the adapter's view quote is 0, the Quoter asks quoteCall; a cleared
    /// family prices 0 on both.
    function test_GateF2_Quoter_FallsBackToQuoteCall() public {
        BlazePhoenixGateWrapper w = _hostileWrapper(6);
        BlazePhoenixQuoter quoter = new BlazePhoenixQuoter(address(hub), address(0xD0D0));
        uint256 amt = 1_000e18;
        (uint256 v, ) = w.quote(true, amt);
        assertEq(v, 0, "setup: the view quote has no answer");
        assertEq(w.quoteCall(true, amt), venue.quoteSell(amt), "the wrapper relays quoteCall");
        Route memory r = _route(address(w), BPC.KIND_EXTERNAL, HKEY, amt, 0);
        (Route memory q, ) = quoter.previewRouteExact(r, amt);
        assertEq(q.hops[0].legs[0].expectedOut, venue.quoteSell(amt), "priced by quoteCall");
        gate.clearAdapter(HFAM);
        (q, ) = quoter.previewRouteExact(r, amt);
        assertEq(q.hops[0].legs[0].expectedOut, 0, "a cleared family prices 0");
    }
}
