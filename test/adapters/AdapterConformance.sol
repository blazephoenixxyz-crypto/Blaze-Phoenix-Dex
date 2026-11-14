// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {AdapterHarness} from "./AdapterHarness.sol";
import {Vm, VmSafe} from "forge-std/Vm.sol";
import {MockV3Pool} from "../mocks/MockV3Pool.sol";
import {BlazePhoenixGateWrapper, IExtAdapter} from "../../src/BlazePhoenixGate.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {BlazePhoenixHub} from "../../src/BlazePhoenixHub.sol";
import {BlazePhoenixRouter} from "../../src/BlazePhoenixRouter.sol";
import {BlazePhoenixQuoter} from "../../src/BlazePhoenixQuoter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg, QuoteCtx} from "../../src/BlazePhoenixCore.sol";

/// Holds the real tokens of a wrapper the Gate did not create.
contract ImpostorWrapper {
    address public token0;
    address public token1;
    constructor(address a, address b) { (token0, token1) = (a, b); }
}

/// The obligations every adapter owes the Gate, observed through the real wrapper of the real
/// Gate and never through the number the adapter returns (Gate: "advisory and never read").
/// One thin file per venue implements `_mount` (venue mocks, adapter, accept, create) and
/// `_midOperation`; every obligation below then runs against it unchanged.
abstract contract AdapterConformance is AdapterHarness {
    /// What each mount gives the venue of each token (18 decimals).
    uint256 internal constant HOLD = 1_000_000e18;

    address internal adapter_;
    /// The contract that holds the venue's tokens and is the adapter's counterparty (Vault or pool).
    address internal venue_;
    address internal w_;
    uint24 internal key_;
    bytes internal hint_;

    /// Deploys the venue mocks holding HOLD of t0 and t1, the adapter, accepts it and creates
    /// the wrapper; sets adapter_, venue_, w_, key_ and hint_.
    function _mount() internal virtual;

    /// Runs `call` on this contract while the venue is in the middle of an operation of its own.
    function _midOperation(bytes memory call) internal virtual;

    function setUp() public {
        _tokens();
        _mount();
    }

    function _leg() internal view returns (address vp, bytes32 a0, bytes32 a1) {
        BlazePhoenixGateWrapper wr = BlazePhoenixGateWrapper(w_);
        (vp, a0, a1) = (wr.venuePool(), wr.aux0(), wr.aux1());
    }

    /// The Quoter's number for the leg: the view quote, or quoteCall (eth_call context) when the
    /// view answers 0. The state is restored afterwards.
    function _price(bool z, uint256 amt) internal returns (uint256 q) {
        (q, ) = BlazePhoenixGateWrapper(w_).quote(z, amt);
        if (q == 0) {
            uint256 s = vm.snapshotState();
            vm.prank(address(this), address(0));
            q = BlazePhoenixGateWrapper(w_).quoteCall(z, amt);
            vm.revertToState(s);
        }
    }

    // ─── A1: resolve proves from the venue, and is idempotent ───

    function test_Conf_A1_Resolve_IsIdempotent_AndIsTheWrappersLeg() public {
        (address vp, bytes32 a0, bytes32 a1) = _leg();
        for (uint256 k; k < 2; ++k) {
            vm.prank(address(gate));
            (address p, bytes32 x0, bytes32 x1) = IExtAdapter(adapter_).resolve(address(t0), address(t1), key_, hint_);
            assertEq(p, vp, "venuePool");
            assertEq(x0, a0, "aux0");
            assertEq(x1, a1, "aux1");
        }
    }

    function test_Conf_A1_Resolve_HintOfAnotherLength_Refused() public {
        vm.expectRevert(_aerr(8));
        gate.create(address(t0), address(t1), key_ + 1, abi.encodePacked(hint_, uint8(0)));
        bytes memory short = new bytes(hint_.length - 1);
        for (uint256 k; k < short.length; ++k) short[k] = hint_[k];
        vm.expectRevert(_aerr(8));
        gate.create(address(t0), address(t1), key_ + 1, short);
    }

    // ─── A2: exec only for a wrapper the Gate created ───

    function test_Conf_A2_ExecByNonWrapper_Refused() public {
        (address vp, bytes32 a0, bytes32 a1) = _leg();
        t0.mint(adapter_, 1e18);
        vm.expectRevert(_aerr(1));
        IExtAdapter(adapter_).exec(vp, a0, a1, true, 1e18, address(this));
        // An impostor holding the wrapper's real tokens is refused the same way.
        address fake = address(new ImpostorWrapper(address(t0), address(t1)));
        vm.prank(fake);
        vm.expectRevert(_aerr(1));
        IExtAdapter(adapter_).exec(vp, a0, a1, true, 1e18, fake);
    }

    // ─── A3 + A7: custody is empty after exec, and exec delivers at least the quote ───

    function testFuzz_Conf_A3_A7_SwapLeavesNothing_DeliversAtLeastTheQuote(bool z, uint256 amt) public {
        amt = bound(amt, 1e3, HOLD / 10);
        uint256 q = _price(z, amt);
        assertGt(q, 0, "the leg is priced");
        uint256 out = _swap(w_, z, amt);
        assertGe(out, q, "exec >= quote");
        _assertEmpty(adapter_, w_, venue_);
    }

    // ─── A4 + A9 (zero): depth does not read the amount; vitalOf caps it by the venue's holdings ───

    function testFuzz_Conf_A4_DepthIgnoresTheAmount_VitalIsCapped(bool z, uint256 amt) public view {
        amt = bound(amt, 0, HOLD / 2);
        (uint256 o0, uint256 d0) = BlazePhoenixGateWrapper(w_).quote(z, 0);
        (, uint256 da) = BlazePhoenixGateWrapper(w_).quote(z, amt);
        assertEq(o0, 0, "amtIn 0 prices nothing");
        assertGt(d0, 0, "a live venue declares its depth");
        assertEq(da, d0, "depth18 does not depend on amtIn");
        (, uint256 v, ) = gate.vitalOf(w_);
        uint256 b0 = t0.balanceOf(venue_);
        uint256 b1 = t1.balanceOf(venue_);
        assertLe(v, d0, "vitalOf <= declared depth");
        assertLe(v, b0 < b1 ? b0 : b1, "vitalOf <= the venue's short side held");
    }

    // ─── A4, a venue that declares more than it holds: vitalOf is cut to the holdings ───

    function testFuzz_Conf_A4_VenueDeclaresMoreThanItHolds_VitalIsTheHoldings(bool side, uint256 keep) public {
        keep = bound(keep, 1, HOLD / 2);
        MockERC20 t = side ? t0 : t1;
        uint256 drained = t.balanceOf(venue_) - keep; // read before the prank: a view call would spend it
        vm.prank(venue_);
        t.transfer(address(0xdead), drained);
        (, uint256 declared) = BlazePhoenixGateWrapper(w_).quote(true, 0);
        assertGt(declared, keep, "the venue declares more than it holds");
        (, uint256 v, ) = gate.vitalOf(w_);
        assertEq(v, keep, "vitalOf is the short side the venue holds");
    }

    // ─── A5: mid-operation the venue is not priced, and the adapter does not revert ───

    uint256[4] internal _mid;
    bool internal _midRan;

    function test_Conf_A5_MidOperation_QuoteIsZero_DoesNotRevert() public {
        _midOperation(abi.encodeCall(this.probeMidOperation, ()));
        assertTrue(_midRan, "the probe ran inside the operation");
        for (uint256 k; k < 4; ++k) assertEq(_mid[k], 0, "mid-operation: (0, 0)");
        (, uint256 d) = BlazePhoenixGateWrapper(w_).quote(true, 0);
        assertGt(d, 0, "after the operation: priced again");
    }

    /// Called by the venue (or under its lock): the adapter's own quote, as the wrapper asks it.
    function probeMidOperation() external {
        (address vp, bytes32 a0, bytes32 a1) = _leg();
        for (uint256 k; k < 2; ++k) {
            vm.prank(w_);
            (bool ok, bytes memory r) = adapter_.call(abi.encodeCall(IExtAdapter.quote, (vp, a0, a1, k == 0, 1e18)));
            assertTrue(ok, "quote reverts mid-operation");
            (_mid[2 * k], _mid[2 * k + 1]) = abi.decode(r, (uint256, uint256));
        }
        _midRan = true;
    }

    // ─── A6: quoteCall equals quote when quote answers, and leaves the venue as it found it ───

    function testFuzz_Conf_A6_QuoteCallMatchesQuote_VenueUnchanged(bool z, uint256 amt) public {
        amt = bound(amt, 1e3, HOLD / 10);
        (uint256 q, ) = BlazePhoenixGateWrapper(w_).quote(z, amt);
        uint256 b0 = t0.balanceOf(venue_);
        uint256 b1 = t1.balanceOf(venue_);
        vm.prank(address(this), address(0));
        uint256 qc = BlazePhoenixGateWrapper(w_).quoteCall(z, amt);
        if (q != 0) assertEq(qc, q, "quoteCall == quote");
        else assertGt(qc, 0, "quoteCall prices what the view cannot");
        assertEq(t0.balanceOf(venue_), b0, "venue t0");
        assertEq(t1.balanceOf(venue_), b1, "venue t1");
        _assertEmpty(adapter_, w_, venue_);
    }

    // ─── A10: the Quoter's arm prices the leg under its gas cap ───

    function test_Conf_A10_QuoteFitsTheQuotersGasCap() public {
        address[] memory cold = new address[](3);
        (cold[0], cold[1], cold[2]) = (adapter_, venue_, w_);
        _armUnderCap(w_, true, 1e18, cold);
        _armUnderCap(w_, false, 1e18, cold);
    }

    // ─── A12 (B4): one leg, one price, four producers ───
    // The wrapper's own view `quote` is the price; the Core's `gateQuote` (the Router's identity
    // first), the Solver's kind-9 arm (`universalQuoteRank`), the Quoter's committed pass and
    // the Router's fill must all read that price, and all read 0 for a wrapper that is not live.

    address internal constant USER = address(0xA11CE);

    /// The Hub, Router and Quoter around this Gate; `admit` registers the Gate as a kind-9
    /// factory for this wrapper's key, so the wrapper is live (`BPC.gateWrapperLive`).
    function _stack(bool admit) internal returns (BlazePhoenixHub hub, BlazePhoenixRouter router, BlazePhoenixQuoter quoter) {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0xBEEF));
        hub.setRoles(address(this), address(this), address(this));
        if (admit) {
            uint24[] memory fees = new uint24[](1);
            fees[0] = key_;
            hub.addFactory(address(gate), BPC.KIND_EXTERNAL, 5, gate.WRAPPER_INIT_HASH(), fees, new int24[](0));
        }
        router = new BlazePhoenixRouter(address(hub), address(0xD0D0), address(this), address(0xFEE1), address(0xFEE2));
        quoter = new BlazePhoenixQuoter(address(hub), address(0xD0D0));
    }

    function _route1(bool z, uint256 amt) internal view returns (Route memory r) {
        (address tIn, address tOut) = z ? (address(t0), address(t1)) : (address(t1), address(t0));
        Leg[] memory l = new Leg[](1);
        l[0] = Leg({pool: w_, hooks: address(0), kind: BPC.KIND_EXTERNAL, fee: key_, tickSpacing: 0,
            zeroForOne: z, stable: false, amountIn: amt, expectedOut: 0, auxId: bytes32(0)});
        Hop[] memory hs = new Hop[](1);
        hs[0] = Hop({tokenIn: tIn, tokenOut: tOut, amountIn: amt, expectedOut: 0, legs: l});
        r = Route({hops: hs, totalOut: 0, singleOut: 0, singleOutFloor: 0, expectedImpactBps: 0,
            confidenceWad: 0, estGas: 0, hasSurplus: false, isV4Bundle: false});
    }

    function _ctx(address hub, bool z) internal view returns (QuoteCtx memory c) {
        (address tIn, address tOut) = z ? (address(t0), address(t1)) : (address(t1), address(t0));
        c = QuoteCtx({kind: BPC.KIND_EXTERNAL, pool: w_, zeroForOne: z, fee: key_, tickSpacing: 0, stable: false,
            tokenIn: tIn, tokenOther: tOut, hooks: address(0), v4Manager: address(0), hub: hub, decIn1: 0, decOther1: 0});
    }

    /// The Quoter as an integrator runs it (eth_call: tx.origin 0, state thrown away).
    function _preview(BlazePhoenixQuoter quoter, bool z, uint256 amt) internal returns (Route memory q, uint256 exactOut) {
        uint256 s = vm.snapshotState();
        vm.prank(address(this), address(0));
        (q, exactOut) = quoter.previewRouteExact(_route1(z, amt), amt);
        vm.revertToState(s);
    }

    /// @notice A12: over a fixed grid (both directions; dust, 1 % and 10 % of the holdings) the
    ///         four producers read the wrapper's own price. A view price q != 0: `gateQuote` and
    ///         the Solver's arm return q, the Quoter commits q on the leg. A view price of 0 (a
    ///         venue that prices only by running the swap): the Solver does not rank the row and
    ///         the Quoter commits `quoteCall`. The Router then fills at least the Quoter's floor.
    ///         Every cell must be priced by the Quoter, so a grid that prices nothing is red.
    function test_Conf_A12_GateLegPriceCommutes_FourProducersReadOnePrice() public {
        (BlazePhoenixHub hub, BlazePhoenixRouter router, BlazePhoenixQuoter quoter) = _stack(true);
        uint256[3] memory amts = [uint256(1e6), HOLD / 100, HOLD / 10];
        uint256 cells;
        for (uint256 k; k < 6; ++k) {
            (bool z, uint256 amt) = (k % 2 == 0, amts[k / 2]);
            (uint256 q, ) = BlazePhoenixGateWrapper(w_).quote(z, amt);
            uint256 priced = _price(z, amt);
            assertGt(priced, 0, "A12 premise: the cell is priced");
            (address tIn, address tOut) = z ? (address(t0), address(t1)) : (address(t1), address(t0));
            (bool live, uint256 g, ) = BPC.gateQuote(address(hub), w_, tIn, tOut, key_, z, amt, false);
            assertTrue(live, "A12 premise: the admitted wrapper is live");
            assertEq(g, q, "A12 (i) gateQuote reads the wrapper's view price");
            (uint256 u, , uint256 rank, ) = BPC.universalQuoteRank(_ctx(address(hub), z), amt, 0, false);
            assertEq(u, q, "A12 (ii) the Solver's kind-9 arm reads the same price");
            if (q == 0) assertEq(rank, 0, "A12 (ii') a row the view does not price is not ranked");
            (Route memory r, uint256 exactOut) = _preview(quoter, z, amt);
            assertEq(r.hops[0].legs[0].expectedOut, priced, "A12 (iii) the Quoter commits the same price");
            assertGt(exactOut, 0, "A12 (iii) the Quoter's floor is priced");
            (MockERC20 mIn, MockERC20 mOut) = z ? (t0, t1) : (t1, t0);
            mIn.mint(USER, amt);
            vm.startPrank(USER);
            mIn.approve(address(router), amt);
            uint256 b = mOut.balanceOf(USER);
            uint256 got = router.swapExactIn(r, amt, 1, USER, block.timestamp + 1);
            vm.stopPrank();
            assertEq(mOut.balanceOf(USER) - b, got, "A12 (iv) the Router reports what it delivered");
            assertGe(got, exactOut, "A12 (iv) the Router fills the Quoter's floor");
            ++cells;
        }
        assertEq(cells, 6, "A12 the grid ran every cell");
    }

    /// @notice A12, `gateWrapperLive == false`: the Gate is not admitted by this Hub, so the
    ///         wrapper is not live although its adapter still prices it. All four producers read
    ///         0 and the Router refuses the leg by its own code (RouterE(19)).
    function test_Conf_A12_GateLegPriceCommutes_NotLiveIsZeroInAllFour() public {
        (BlazePhoenixHub hub, BlazePhoenixRouter router, BlazePhoenixQuoter quoter) = _stack(false);
        uint256 amt = HOLD / 100;
        assertGt(_price(true, amt), 0, "A12 premise: the adapter prices the leg");
        assertFalse(BPC.gateWrapperLive(address(hub), w_, address(t0), address(t1), key_), "A12 premise: not live");
        (bool live, uint256 g, uint256 d) = BPC.gateQuote(address(hub), w_, address(t0), address(t1), key_, true, amt, true);
        assertFalse(live, "A12 (i) not live");
        assertEq(g, 0, "A12 (i) gateQuote prices a wrapper that is not live 0");
        assertEq(d, 0, "A12 (i) and gives it no depth");
        (uint256 u, uint256 dw, uint256 rank, ) = BPC.universalQuoteRank(_ctx(address(hub), true), amt, 0, false);
        assertEq(u + dw + rank, 0, "A12 (ii) the Solver's arm reads 0 and does not rank the row");
        (Route memory r, uint256 exactOut) = _preview(quoter, true, amt);
        assertEq(r.hops[0].legs[0].expectedOut, 0, "A12 (iii) the Quoter commits 0");
        assertEq(exactOut, 0, "A12 (iii) and promises 0");
        t0.mint(USER, amt);
        vm.startPrank(USER);
        t0.approve(address(router), amt);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, uint16(19)));
        router.swapExactIn(_route1(true, amt), amt, 1, USER, block.timestamp + 1);
        vm.stopPrank();
    }

    // ─── A13: the kind-9 column of the route matrix (route length x Gate hop x fee calendar) ───
    //
    // test/DimensionMatrixRoutes.t.sol walks the route rules over native legs only; a fix that
    // holds on a V3 leg and fails on the Gate leg beside it is the cell this column adds. Each
    // cell asserts the Router's rules where they land: the fee is taken on the hop the calendar
    // names, in that hop's input token, once per paying hop (exhaustion: every hop; anchored: the
    // first hop whose input is a bridge; a direct route into a bridge: on the output only), the
    // Quoter's calendar door gives the same answer, the user receives what the Router reports and
    // the Router keeps nothing, and the registry feedback reaches the native leg of the route and
    // never the Gate leg (a kind-9 leg's one vitality producer is its wrapper, Router._recordHits).

    uint160 internal constant A13_Q96 = uint160(uint256(1) << 96);
    uint128 internal constant A13_LIQ = uint128(1e27);

    function _a13V3(MockERC20 x, MockERC20 y) internal returns (MockV3Pool p) {
        p = new MockV3Pool(address(x), address(y), 3000);
        p.setState(A13_Q96, A13_LIQ);
        x.mint(address(p), HOLD);
        y.mint(address(p), HOLD);
    }

    function _a13Native(MockV3Pool p, MockERC20 x, MockERC20 y, uint256 amt) internal pure returns (Hop memory h) {
        bool z = address(x) < address(y);
        uint256 o = BPC.outV3(amt, A13_Q96, A13_LIQ, 3000, z, 0);
        Leg[] memory l = new Leg[](1);
        l[0] = Leg({pool: address(p), hooks: address(0), kind: BPC.KIND_V3, fee: 3000, tickSpacing: 0,
            zeroForOne: z, stable: false, amountIn: amt, expectedOut: o, auxId: bytes32(0)});
        h = Hop({tokenIn: address(x), tokenOut: address(y), amountIn: amt, expectedOut: o, legs: l});
    }

    function _a13Gate(uint256 amt) internal returns (Hop memory h) {
        h = _route1(true, amt).hops[0];
        uint256 o = _price(true, amt);
        (h.legs[0].expectedOut, h.expectedOut) = (o, o);
    }

    /// The registry feedback calls the Router made to the Hub since the recording began, for the
    /// Gate leg's wrapper `g` and for the native pool `n`.
    function _a13Records(address hub, address g, address n) internal returns (uint256 rg, uint256 rn) {
        Vm.AccountAccess[] memory acc = vm.stopAndReturnStateDiff();
        for (uint256 i; i < acc.length; ++i) {
            bytes memory d = acc[i].data;
            if (acc[i].account != hub || acc[i].kind != VmSafe.AccountAccessKind.Call || d.length < 36) continue;
            if (bytes4(d) != BlazePhoenixHub.recordSwap.selector) continue;
            address p;
            assembly ("memory-safe") { p := mload(add(d, 36)) }
            if (p == g) ++rg;
            if (p == n && n != address(0)) ++rn;
        }
    }

    struct A13Ctx {
        BlazePhoenixHub hub;
        BlazePhoenixRouter router;
        BlazePhoenixQuoter quoter;
        MockERC20[3] tk;
        MockV3Pool after_;
        MockV3Pool before_;
        uint256 amt;
    }

    /// @notice A13: nine cells, generated: one hop x calendar {exhaustion, input is a bridge,
    ///         output is a bridge}, and two hops x Gate leg on hop {0, 1} x calendar {exhaustion,
    ///         hop 0's input is a bridge, hop 1's input is a bridge}. The count is asserted, so a
    ///         generator that drops a cell is red.
    function test_Conf_A13_KindNineColumn_FeeOnTheCalendarHop_FeedbackOnlyNative() public {
        A13Ctx memory x;
        (x.hub, x.router, x.quoter) = _stack(true);
        MockERC20 t2 = new MockERC20("C", "C");
        x.tk = [t0, t1, t2];
        x.after_ = _a13V3(t1, t2);  // t0 -(Gate)-> t1 -(V3)-> t2
        x.before_ = _a13V3(t2, t0); // t2 -(V3)-> t0 -(Gate)-> t1
        x.amt = HOLD / 100;
        uint256 cells;
        for (uint256 c; c < 9; ++c) {
            uint256 snap = vm.snapshotState();
            _a13Cell(x, c);
            vm.revertToState(snap);
            ++cells;
        }
        assertEq(cells, 9, "A13 the generator ran every cell");
    }

    function _a13Cell(A13Ctx memory x, uint256 c) internal {
        string memory cell = string.concat("A13 cell ", vm.toString(c));
        uint256 k = c < 3 ? c : (c - 3) % 3;
        (Hop[] memory hs, address nat) = _a13Hops(x, c);
        (bool onOut, uint256 payHop) = _a13Calendar(x, hs, k, cell);
        uint256[3] memory feeBefore = _a13FeeBal(x.tk);
        _a13Swap(x, hs, nat, cell);
        uint256 paying = _a13Fees(x, hs, feeBefore, onOut, payHop, cell);
        uint256 feeOut = _a13Paid(x.tk, feeBefore, hs[hs.length - 1].tokenOut);
        if (onOut) assertGt(feeOut, 0, string.concat(cell, ": a direct route into a bridge pays on its output"));
        else assertEq(feeOut, 0, string.concat(cell, ": no output fee off a direct bridge route"));
        assertEq(paying, onOut ? 0 : (k == 0 ? hs.length : 1), string.concat(cell, ": the number of paying hops"));
    }

    function _a13Hops(A13Ctx memory x, uint256 c) internal returns (Hop[] memory hs, address nat) {
        hs = new Hop[](c < 3 ? 1 : 2);
        if (c < 3) {
            hs[0] = _a13Gate(x.amt);
        } else if (c < 6) {
            hs[0] = _a13Gate(x.amt);
            hs[1] = _a13Native(x.after_, t1, x.tk[2], hs[0].expectedOut);
            nat = address(x.after_);
        } else {
            hs[0] = _a13Native(x.before_, x.tk[2], t0, x.amt);
            hs[1] = _a13Gate(hs[0].expectedOut);
            nat = address(x.before_);
        }
    }

    /// The calendar of the cell, written from its definition, never read from the Core; the
    /// Quoter's calendar door must give the same answer.
    function _a13Calendar(A13Ctx memory x, Hop[] memory hs, uint256 k, string memory cell)
        internal
        returns (bool onOut, uint256 payHop)
    {
        address tokenOut = hs[hs.length - 1].tokenOut;
        if (k == 1) x.hub.addBridge(hs[0].tokenIn);
        if (k == 2) x.hub.addBridge(hs.length == 1 ? tokenOut : hs[1].tokenIn);
        onOut = hs.length == 1 && k == 2;
        payHop = k == 0 ? type(uint256).max : (hs.length == 1 ? 0 : k - 1);
        (uint256 qHop, bool qOut) = x.quoter.feeCalendarOf(hs, tokenOut);
        assertEq(qHop, onOut ? type(uint256).max : payHop, string.concat(cell, ": the Quoter's fee hop"));
        assertEq(qOut, onOut, string.concat(cell, ": the Quoter's fee on output"));
    }

    function _a13Swap(A13Ctx memory x, Hop[] memory hs, address nat, string memory cell) internal {
        address tokenOut = hs[hs.length - 1].tokenOut;
        Route memory r = Route({hops: hs, totalOut: hs[hs.length - 1].expectedOut,
            singleOut: hs[hs.length - 1].expectedOut, singleOutFloor: 0, expectedImpactBps: 0,
            confidenceWad: 0, estGas: 0, hasSurplus: false, isV4Bundle: false});
        MockERC20(hs[0].tokenIn).mint(USER, x.amt);
        uint256 userBefore = MockERC20(tokenOut).balanceOf(USER);
        vm.startPrank(USER);
        MockERC20(hs[0].tokenIn).approve(address(x.router), x.amt);
        vm.startStateDiffRecording();
        uint256 got = x.router.swapExactIn(r, x.amt, 1, USER, block.timestamp + 1);
        vm.stopPrank();
        (uint256 rg, uint256 rn) = _a13Records(address(x.hub), w_, nat);
        assertEq(rg, 0, string.concat(cell, ": the Gate leg never reaches recordSwap"));
        assertEq(rn, hs.length - 1, string.concat(cell, ": the native leg beside it reaches recordSwap once"));
        assertEq(MockERC20(tokenOut).balanceOf(USER) - userBefore, got, string.concat(cell, ": delivered is reported"));
        assertGt(got, 0, string.concat(cell, ": settled with something"));
        for (uint256 i; i < 3; ++i) assertEq(x.tk[i].balanceOf(address(x.router)), 0, string.concat(cell, ": the Router keeps nothing"));
    }

    function _a13Fees(
        A13Ctx memory x,
        Hop[] memory hs,
        uint256[3] memory feeBefore,
        bool onOut,
        uint256 payHop,
        string memory cell
    ) internal view returns (uint256 paying) {
        for (uint256 h; h < hs.length; ++h) {
            uint256 fee = _a13Paid(x.tk, feeBefore, hs[h].tokenIn);
            bool pays = !onOut && (payHop == type(uint256).max || payHop == h);
            if (!pays) { assertEq(fee, 0, string.concat(cell, ": a hop off the calendar pays nothing")); continue; }
            ++paying;
            if (h == 0) assertEq(fee, BPC.mulDivUp(x.amt, BPC.PROTOCOL_FEE_BPS, 10_000), string.concat(cell, ": hop 0 pays the fee once"));
            else assertGt(fee, 0, string.concat(cell, ": the calendar's hop pays"));
        }
    }

    function _a13FeeBal(MockERC20[3] memory tk) internal view returns (uint256[3] memory b) {
        for (uint256 i; i < 3; ++i) b[i] = tk[i].balanceOf(address(0xFEE1)) + tk[i].balanceOf(address(0xFEE2));
    }

    /// The fee the treasury (0xFEE1 + 0xFEE2) took in token `t` since `before`.
    function _a13Paid(MockERC20[3] memory tk, uint256[3] memory before, address t) internal view returns (uint256) {
        uint256 i = _a13Ix(tk, t);
        return tk[i].balanceOf(address(0xFEE1)) + tk[i].balanceOf(address(0xFEE2)) - before[i];
    }

    function _a13Ix(MockERC20[3] memory tk, address t) internal pure returns (uint256 i) {
        while (address(tk[i]) != t) ++i;
    }
}

/// A8, for the venues whose pool carries a hook the adapter pins by codehash at create.
abstract contract AdapterConformanceHooked is AdapterConformance {
    /// Replaces the code at the pool's hook address after create.
    function _changeHook() internal virtual;

    // ─── A8: the hook pinned at create is re-proven at every exec ───

    function test_Conf_A8_HookChangedAfterCreate_ExecRefused() public {
        assertGt(_swap(w_, true, 1e18), 0, "the pinned hook trades");
        _changeHook();
        t0.mint(address(this), 1e18);
        vm.expectRevert(_aerr(7));
        BlazePhoenixGateWrapper(w_).swap(address(this), true, 1e18, 0, "");
    }
}
