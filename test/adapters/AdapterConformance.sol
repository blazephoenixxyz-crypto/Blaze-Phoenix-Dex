// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {AdapterHarness} from "./AdapterHarness.sol";
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
