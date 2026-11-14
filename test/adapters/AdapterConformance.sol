// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {AdapterHarness} from "./AdapterHarness.sol";
import {BlazePhoenixGateWrapper, IExtAdapter} from "../../src/BlazePhoenixGate.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

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
