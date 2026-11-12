// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// Red at f9cca7a (fin1111-massa): a Gate wrapper's mass was the Gate's word, the SHORT side of
// what the venue holds, where every native kind's is the tokenOut side (`Core._quoteArms`). When
// the order buys the cheap token the wrapper was weighed at the dear token's count, below a
// native pair with the same holdings by the price, and a mixed hop left it the whole order or
// none. Fixed: the wrapper's mass is its short side times the price its own quote paid when
// that price is above one, the tokenOut side a venue holding both sides at its price holds.
// The unit pinned is the hop's mass (`hopMass18`, SHARED_QUANTITIES): the tokenOut a row can
// pay, as `Core._quoteArms` produces it for a wrapper, in the same unit as a native pair's.

import {GateBaseCoherenceTest} from "./GateBaseCoherence.t.sol";
import {BlazePhoenixGateWrapper} from "../src/BlazePhoenixGate.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixCore as BPC, RoutePlan, QuoteCtx} from "../src/BlazePhoenixCore.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";
import {MockGateVenue} from "./mocks/MockGateAdapters.sol";

contract WrapperMassUnitTest is GateBaseCoherenceTest {
    uint256 constant B0 = 1_000_000e18;
    uint256 constant B1 = 10_000e18;

    function _mass(address pool, uint8 kind, uint24 fee, bool zfo) internal view returns (uint256 m) {
        QuoteCtx memory c;
        c.kind = kind;
        c.pool = pool;
        c.zeroForOne = zfo;
        c.fee = fee;
        c.tokenIn = zfo ? address(t0) : address(t1);
        c.tokenOther = zfo ? address(t1) : address(t0);
        c.hub = address(hub);
        c.decIn1 = 19;
        c.decOther1 = 19;
        (m, , , ) = BPC.universalProbe(c, 1e18, 0, true);
    }

    /// One set of holdings (1M of t0, 10k of t1) behind two doors: a Gate wrapper over a venue
    /// paying `payBps` of mid, and a native V2 pair.
    function _books(uint256 payBps) internal returns (BlazePhoenixGateWrapper w, MockV2Pair pair) {
        MockGateVenue v = _asymVenue(B0, B1, payBps);
        _accept(FAM, address(adapter));
        w = BlazePhoenixGateWrapper(gate.create(address(t0), address(t1), KEY, abi.encode(address(v))));
        adapter.setDeclaredDepth(BPC.shortSide18(B0, 18, B1, 18));
        _admit();
        pair = _pairAt(B0, B1);
    }

    /// Buying the cheap token (t0, the 1M side): the pair's mass is its t0 reserve; the
    /// wrapper's, measured at the price its quote paid (0.98 of mid), is within that fee of it
    /// and never above it.
    function test_Mass_AWrapperWeighsTheTokenOutSideLikeANativePair() public {
        (BlazePhoenixGateWrapper w, MockV2Pair pair) = _books(980_000);
        uint256 native = _mass(address(pair), BPC.KIND_V2, 30, false);
        uint256 wrapped = _mass(address(w), BPC.KIND_EXTERNAL, KEY, false);
        assertEq(native, B0, "the pair's mass buying t0 is its t0 reserve");
        assertLe(wrapped, native, "a wrapper is weighed above the tokenOut side a pair with its holdings has");
        assertGe(wrapped, native * 98 / 100, "a wrapper buying the cheap token is weighed at the dear token's count");
    }

    /// Buying the dear token (t1, the 10k side): the short side is the tokenOut side already
    /// and the price paid is below one; both doors weigh the same, as before the fix.
    function test_Mass_BuyingTheDearTokenBothDoorsWeighTheShortSide() public {
        (BlazePhoenixGateWrapper w, MockV2Pair pair) = _books(98);
        assertEq(_mass(address(pair), BPC.KIND_V2, 30, true), B1, "the pair's mass buying t1 is its t1 reserve");
        assertEq(_mass(address(w), BPC.KIND_EXTERNAL, KEY, true), B1, "buying the dear token the short side is the tokenOut side");
    }

    /// The order buys the cheap token: 200 of t1 against two doors on the same holdings. The
    /// plan pays more than either door alone (the standing guarantee of docs/DEX_ROUTING.md),
    /// where at f9cca7a it was the wrapper alone, 0.98 of mid flat.
    function test_Plan_BuyingTheCheapTokenSplitsOverBothDoors() public {
        _books(980_000);
        (BlazePhoenixSolver solver, ) = _autoDoor();
        uint256 amt = 200e18;
        RoutePlan memory p = solver.findBestRoutePlan(address(t1), address(t0), amt);
        uint256 wrapperAlone = amt * 980_000 / 10_000;
        uint256 pairAlone = _v2out(amt, B1, B0);
        assertGt(p.best.totalOut, wrapperAlone, "the plan pays no more than the wrapper alone");
        assertGt(p.best.totalOut, pairAlone, "the plan pays no more than the pair alone");
    }

    /// The mirror, buying the dear token: 20 000 of t0. Both doors weigh the same side here and
    /// the plan already beat either alone; pinned so the fix moves nothing on this side.
    function test_Plan_BuyingTheDearTokenSplitsOverBothDoors() public {
        _books(98);
        (BlazePhoenixSolver solver, ) = _autoDoor();
        uint256 amt = 20_000e18;
        RoutePlan memory p = solver.findBestRoutePlan(address(t0), address(t1), amt);
        assertGt(p.best.totalOut, amt * 98 / 10_000, "the plan pays no more than the wrapper alone");
        assertGt(p.best.totalOut, _v2out(amt, B0, B1), "the plan pays no more than the pair alone");
    }
}
