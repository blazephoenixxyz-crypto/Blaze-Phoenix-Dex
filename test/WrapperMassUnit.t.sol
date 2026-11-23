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
//
// Red at 6387350 (caixa-1123 gate-mass): test_Mass_AWrapperBuyingTheCheapTokenIsNeverAboveTheTokenOutItsVenueHolds,
// test_Mass_TheCapReadsTheTokenOutAtItsOwnDecimals and
// testFuzz_Mass_AWrapperIsNeverAboveTheTokenOutHeld. The raise above assumes a venue
// holding both sides at its price; a venue whose short side is already the tokenOut was weighed
// at that side times the price, above what it can pay. Fixed: the raised mass is capped by the
// tokenOut held at the wrapper's `venuePool` address, measured in the same call. Oracle: the
// token's own balanceOf, read by the test. Cheatcodes: vm.mockCall on decimals() (both doors read
// it), vm.warp inside the base helpers.

import {GateBaseCoherenceTest} from "./GateBaseCoherence.t.sol";
import {BlazePhoenixGateWrapper} from "../src/BlazePhoenixGate.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixCore as BPC, RoutePlan, QuoteCtx} from "../src/BlazePhoenixCore.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";
import {MockGateVenue} from "./mocks/MockGateAdapters.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

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
        (m, , , , ) = BPC.universalProbe(c, 1e18, 0, true, 1e18);
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

    // --- the raise is capped by the tokenOut the venue holds (caixa-1123 gate-mass) ---

    /// Both tokens answer `d0`/`d1` to decimals(), for every reader (Gate and Core alike).
    function _decimals(uint8 d0, uint8 d1) internal {
        vm.mockCall(address(t0), abi.encodeWithSignature("decimals()"), abi.encode(uint256(d0)));
        vm.mockCall(address(t1), abi.encodeWithSignature("decimals()"), abi.encode(uint256(d1)));
    }

    function _massAt(address pool, bool zfo, uint256 amountIn, uint8 d0, uint8 d1) internal view returns (uint256 m) {
        QuoteCtx memory c;
        c.kind = BPC.KIND_EXTERNAL;
        c.pool = pool;
        c.zeroForOne = zfo;
        c.fee = KEY;
        c.tokenIn = zfo ? address(t0) : address(t1);
        c.tokenOther = zfo ? address(t1) : address(t0);
        c.hub = address(hub);
        c.decIn1 = (zfo ? d0 : d1) + 1;
        c.decOther1 = (zfo ? d1 : d0) + 1;
        (m, , , , ) = BPC.universalProbe(c, amountIn, 0, true, amountIn);
    }

    /// A wrapper over a venue holding (b0, b1) at decimals (d0, d1), its adapter declaring the
    /// venue's short side (an honest word) and paying `payBps` of the input, linear.
    function _oneSided(uint256 b0, uint256 b1, uint8 d0, uint8 d1, uint256 payBps)
        internal returns (BlazePhoenixGateWrapper w, MockGateVenue v)
    {
        _decimals(d0, d1);
        v = _asymVenue(b0, b1, payBps);
        _accept(FAM, address(adapter));
        w = BlazePhoenixGateWrapper(gate.create(address(t0), address(t1), KEY, abi.encode(address(v))));
        adapter.setDeclaredDepth(BPC.shortSide18(b0, d0, b1, d1));
        _admit();
    }

    /// Quantity: the mass of a wrapper whose venue holds 100 of the dear token (8 decimals) and
    /// 0.5 of the cheap one (6 decimals), buying the cheap one at 49 850 a unit. Expected: at
    /// most the 0.5 of tokenOut the venue holds (5e17 in 18 decimals). RED at 6387350: the short
    /// side (the tokenOut side here) times the price, about 2.49e22.
    function test_Mass_AWrapperBuyingTheCheapTokenIsNeverAboveTheTokenOutItsVenueHolds() public {
        (BlazePhoenixGateWrapper w, MockGateVenue v) = _oneSided(100e8, 5e5, 8, 6, 4_985_000);
        uint256 held18 = t1.balanceOf(address(v)) * 1e12;
        uint256 m = _massAt(address(w), true, 1e8, 8, 6);
        assertGt(m, 0, "the wrapper is not weighed at all");
        assertLe(m, held18, "a wrapper is weighed above the tokenOut its venue holds");
    }

    /// The mirror decimals: the venue holds 100 of the dear token at 6 decimals and 0.5 of the
    /// cheap one at 8, bought with the dear one. Expected: at most the 0.5 held (5e17). Pins that
    /// the cap scales the tokenOut balance by the tokenOut's decimals: read at the tokenIn's six
    /// it is 5e19, a hundred times what the venue holds.
    function test_Mass_TheCapReadsTheTokenOutAtItsOwnDecimals() public {
        (BlazePhoenixGateWrapper w, MockGateVenue v) = _oneSided(100e6, 5e7, 6, 8, 49_850_000_000);
        uint256 held18 = t1.balanceOf(address(v)) * 1e10;
        uint256 m = _massAt(address(w), true, 1e6, 6, 8);
        assertGt(m, 0, "the wrapper is not weighed at all");
        assertLe(m, held18, "a wrapper is weighed above the tokenOut its venue holds");
    }

    /// The same venue bought the other way (the dear token out): no raise, the mass is the short
    /// side, the tokenIn side here, and still below the tokenOut held. Pins that the cap reads
    /// the tokenOut and not the tokenIn.
    function test_Mass_AWrapperBuyingTheDearTokenFromAOneSidedVenueKeepsTheShortSide() public {
        (BlazePhoenixGateWrapper w, MockGateVenue v) = _oneSided(100e8, 5e5, 8, 6, 2);
        uint256 m = _massAt(address(w), false, 1e6, 8, 6);
        assertEq(m, 5e17, "buying the dear token the mass is the venue's short side");
        assertLe(m, t0.balanceOf(address(v)) * 1e10, "a wrapper is weighed above the tokenOut its venue holds");
    }

    /// Quantity: a wrapper's mass against the tokenOut its venue holds, over holdings from one
    /// unit to 2^112 a side, prices from far below to far above one, both directions, and the
    /// decimal pairs 6/8, 6/18, 18/18 (either order). Expected: never above the tokenOut held,
    /// in 18 decimals, as the test reads it from the token. RED at 6387350 (any one-sided venue
    /// bought on its short side).
    function testFuzz_Mass_AWrapperIsNeverAboveTheTokenOutHeld(
        uint256 h0, uint256 h1, uint256 payBps, bool zfo, uint8 decCase
    ) public {
        h0 = bound(h0, 1, 2 ** 112);
        h1 = bound(h1, 1, 2 ** 112);
        payBps = bound(payBps, 1, 1e12);
        uint8[6] memory a = [uint8(6), 8, 6, 18, 18, 18];
        uint8[6] memory b = [uint8(8), 6, 18, 6, 18, 8];
        decCase = uint8(bound(decCase, 0, 5));
        (uint8 d0, uint8 d1) = (a[decCase], b[decCase]);
        (BlazePhoenixGateWrapper w, MockGateVenue v) = _oneSided(h0, h1, d0, d1, payBps);
        uint256 amountIn = 10 ** uint256(zfo ? d0 : d1);
        uint256 m = _massAt(address(w), zfo, amountIn, d0, d1);
        uint256 held18 = zfo ? BPC.to18(t1.balanceOf(address(v)), d1) : BPC.to18(t0.balanceOf(address(v)), d0);
        assertLe(m, held18, "a wrapper is weighed above the tokenOut its venue holds");
    }
}
