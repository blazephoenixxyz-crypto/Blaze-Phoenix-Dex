// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  Hop 0 spends only what the swap owns - Router._hopScaleImpactAndQuote,
//  hop 0, `realIn = _owned(bal, baseIn, amountIn)`.
//
//  The question SHARED_QUANTITIES.md asks of every hop's input ("how much of
//  the Router's balance of hop h's input is this swap's?") is asked of hop 0
//  too, against the same baseline the input sweep keeps: baseIn, the balance
//  the Router held before the pull (F below). Between that baseline and hop
//  0's scale the Router pushes hop 0's fee in tokenIn. A tokenIn that restates
//  every balance by k inside that push leaves the Router holding
//  k * (F + A - t1) - t2, while the legs were scaled on the pull A less the
//  fee. Spending that figure took (1 - k) * (A - fee) out of F, the balance
//  the rescue exists to return. The measured delta past F is what the hop now
//  spends (I4: the measurement wins); the restatement's cut lands on the
//  swapper, inside the floor they signed, and past it the swap is refused
//  (RouterE(5)). A restatement fired by the legs' own transfers is outside
//  this window (KNOWN_ISSUES.md).
//
//  Oracle: F and k are written in each test; the Router's own arithmetic
//  (`_owned`) is never the oracle.
//
//  Red at 8a19c77 (before this fix). Red under mutants.py [tokenin-residual
//  a] (hop 0 spends the declared pull), [tokenin-residual b] (baseline 0) and
//  [tokenin-residual c] (no `decl` ceiling, the positive control).
//  Matrix: gamma F in {0, 1 wei, 500e18, fuzz up to 2^96}, k in {9/10, 1/2,
//  11/10, one wei short}; vectors restatement fired by the hop-0 fee push,
//  one-wei rounding token, positive restatement, honest input; unit and fuzz;
//  one leg, two-leg split, two hops, cyclic route (tokenIn == tokenOut); ERC20.
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {PathologicalERC20} from "./mocks/PathologicalERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";
import {MockPermit2} from "./mocks/MockPermit2.sol";

contract Hop0SpendsOnlyWhatTheSwapOwnsTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    BlazePhoenixRouter router;

    address constant T1 = address(0xFEE1);
    address constant T2 = address(0xFEE2);
    address user = address(0xBEEF);
    address recip = address(0xCAFE);

    uint256 constant RES = 2000e18; // every pair: both reserves
    uint256 constant IN = 100e18;
    uint256 constant STRANDED = 500e18;

    uint8 constant ONE_LEG = 0;
    uint8 constant TWO_LEGS = 1;
    uint8 constant TWO_HOPS = 2;
    uint8 constant CYCLIC = 3;

    struct World {
        bool ok;
        uint16 code;
        uint256 routerIn; // the Router's tokenIn balance after the swap
        uint256 spent; // tokenIn the hop-0 pairs received
        uint256 delivered; // tokenOut received by `recip`
    }

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        solver = new BlazePhoenixSolver(address(hub), address(0));
        router = new BlazePhoenixRouter(address(hub), address(solver), address(this), T1, T2);
        hub.setRoles(address(router), address(solver), address(this));
        router.setPermit2(address(new MockPermit2()));
    }

    // --- helpers -----------------------------------------------------------

    function _code(bytes memory err) internal pure returns (uint16 code) {
        if (err.length == 0) return 0;
        bytes4 sel;
        assembly { sel := mload(add(err, 32)) }
        if (sel == BlazePhoenixRouter.RouterE.selector && err.length == 36) {
            uint256 c;
            assembly { c := mload(add(err, 36)) }
            return uint16(c);
        }
        return 0xFFFE;
    }

    function _fee(uint256 a) internal pure returns (uint256) {
        return BPC.mulDivUp(a, BPC.PROTOCOL_FEE_BPS, BPC.BPS);
    }

    /// A pair holding both reserves plus `extraX`/`extraY` above them, so a
    /// negative restatement leaves it holding at least what it declares.
    function _pair(address x, address y, uint256 extraX, uint256 extraY) internal returns (MockV2Pair p) {
        p = new MockV2Pair(x, y);
        MockERC20(x).mint(address(p), RES + extraX); // both mocks expose mint(address,uint256)
        MockERC20(y).mint(address(p), RES + extraY);
        p.setReserves(uint112(RES), uint112(RES));
        hub.seedPool(address(p), BPC.KIND_V2, 30, address(0), x, y);
    }

    function _leg(MockV2Pair p, address tIn, uint256 amt, uint256 exp) internal view returns (Leg memory) {
        return Leg({
            pool: address(p), hooks: address(0), kind: BPC.KIND_V2, fee: 30, tickSpacing: 0,
            zeroForOne: p.token0() == tIn, stable: false, amountIn: amt, expectedOut: exp, auxId: bytes32(0)
        });
    }

    function _hop(address tIn, address tOut, Leg[] memory legs, uint256 amt, uint256 exp)
        internal pure returns (Hop memory)
    {
        return Hop({tokenIn: tIn, tokenOut: tOut, amountIn: amt, expectedOut: exp, legs: legs});
    }

    /// One swap of `amt` tokenIn on fresh pairs, `f` tokenIn stranded in the
    /// Router before it. `num/den` (0 = honest) is the factor the tokenIn
    /// applies to every balance when hop 0's fee push delivers to treasury 1.
    /// The route is built from the quotes at the pairs' reserves, as a quoter
    /// that does not model the token's pathology builds it; `exact` signs the
    /// floor at the attested output, otherwise at one wei.
    // The swap under test, kept in storage so `_run` stays inside the stack.
    PathologicalERC20 tA;
    MockV2Pair p0;
    MockV2Pair p0b;
    address tOut;
    uint256 expOut;

    /// Fresh tokens and pairs for `shape`, and the route a quoter that does
    /// not model the token's pathology builds from the pairs' reserves.
    function _build(uint8 shape, uint256 amt, uint256 over) internal returns (Route memory route) {
        tA = new PathologicalERC20("A", "A", 18);
        address tB = address(new MockERC20("B", "B"));
        uint256 d = BPC.outV2(amt - _fee(amt), RES, RES, 30);
        Hop[] memory hops = new Hop[](shape >= TWO_HOPS ? 2 : 1);
        p0 = _pair(address(tA), tB, over, 0);
        p0b = MockV2Pair(address(0));
        if (shape == TWO_LEGS) {
            p0b = _pair(address(tA), tB, over, 0);
            uint256 half = amt / 2;
            uint256 dh = BPC.outV2(half - _fee(half), RES, RES, 30);
            uint256 dr = BPC.outV2(amt - half - _fee(amt - half), RES, RES, 30);
            Leg[] memory l2 = new Leg[](2);
            l2[0] = _leg(p0, address(tA), half, dh);
            l2[1] = _leg(p0b, address(tA), amt - half, dr);
            d = dh + dr;
            hops[0] = _hop(address(tA), tB, l2, amt, d);
        } else {
            Leg[] memory l1 = new Leg[](1);
            l1[0] = _leg(p0, address(tA), amt, d);
            hops[0] = _hop(address(tA), tB, l1, amt, d);
        }
        expOut = d;
        tOut = tB;
        if (shape >= TWO_HOPS) {
            tOut = shape == CYCLIC ? address(tA) : address(new MockERC20("C", "C"));
            MockV2Pair p1 = shape == CYCLIC ? _pair(tB, address(tA), 0, over) : _pair(tB, tOut, 0, 0);
            expOut = BPC.outV2(d - _fee(d), RES, RES, 30);
            Leg[] memory l1b = new Leg[](1);
            l1b[0] = _leg(p1, tB, d, expOut);
            hops[1] = _hop(tB, tOut, l1b, d, expOut);
        }
        route = Route({
            hops: hops, totalOut: expOut, singleOut: expOut, singleOutFloor: 0,
            expectedImpactBps: 0, confidenceWad: 0, estGas: 0, hasSurplus: false, isV4Bundle: false
        });
    }

    /// What `p` gained in tokenIn over its opening balance, restated by the
    /// factor the swap fired (the pair's balance is read after it).
    function _gain(MockV2Pair p, uint256 before, uint256 num, uint256 den, bool ok) internal view returns (uint256) {
        if (address(p) == address(0)) return 0;
        uint256 k0 = num == 0 || !ok ? before : before * num / den;
        return tA.balanceOf(address(p)) - k0;
    }

    /// One swap of `amt` tokenIn on fresh pairs, `f` tokenIn stranded in the
    /// Router before it. `num/den` (0 = honest) is the factor the tokenIn
    /// applies to every balance when hop 0's fee push delivers to treasury 1.
    /// `exact` signs the floor at the attested output, otherwise at one wei.
    function _run(uint8 shape, uint256 amt, uint256 f, uint256 num, uint256 den, bool exact)
        internal returns (World memory w)
    {
        uint256 over = num != 0 && num < den ? BPC.mulDivUp(RES, den, num) - RES + 3 : 0;
        Route memory route = _build(shape, amt, over);
        if (f > 0) tA.mint(address(router), f);
        tA.mint(user, amt);
        vm.prank(user);
        tA.approve(address(router), type(uint256).max);
        if (num != 0) tA.setRebaseOnTransferTo(T1, num, den);

        uint256 b0 = tA.balanceOf(address(p0));
        uint256 b1 = address(p0b) == address(0) ? 0 : tA.balanceOf(address(p0b));
        uint256 outBefore = MockERC20(tOut).balanceOf(recip);
        uint256 minOut = exact ? expOut : 1;
        vm.prank(user);
        (bool ok, bytes memory err) = address(router).call(
            abi.encodeCall(router.swapExactIn, (route, amt, minOut, recip, block.timestamp + 100))
        );
        w.ok = ok;
        w.code = ok ? 0 : _code(err);
        w.routerIn = tA.balanceOf(address(router));
        w.spent = _gain(p0, b0, num, den, ok) + _gain(p0b, b1, num, den, ok);
        w.delivered = MockERC20(tOut).balanceOf(recip) - outBefore;
    }

    function _assertKeepsStranded(World memory w, uint256 f, string memory tag) internal pure {
        assertTrue(w.ok, string.concat(tag, ": settles inside the one-wei floor"));
        assertGe(w.routerIn, f, string.concat(tag, ": the stranded balance is not spent"));
        assertLe(w.routerIn, f + 1, string.concat(tag, ": and nothing of the swap stays behind"));
        assertGt(w.spent, 0, string.concat(tag, ": the hop spent the measured delta"));
        assertLt(w.spent, IN - _fee(IN), string.concat(tag, ": the cut landed on the swapper"));
        assertGt(w.delivered, 0, string.concat(tag, ": delivered"));
    }

    // --- the restatement fired by the hop-0 fee push -------------------------

    function test_ANegativeInputRestatementFiredByTheHop0FeePush_LeavesTheStrandedBalance_PairLeg() public {
        _assertKeepsStranded(_run(ONE_LEG, IN, STRANDED, 9, 10, false), STRANDED, "one leg");
    }

    function test_ANegativeInputRestatementFiredByTheHop0FeePush_LeavesTheStrandedBalance_TwoLegSplit() public {
        _assertKeepsStranded(_run(TWO_LEGS, IN, STRANDED, 9, 10, false), STRANDED, "two legs");
    }

    function test_ANegativeInputRestatementFiredByTheHop0FeePush_LeavesTheStrandedBalance_TwoHops() public {
        _assertKeepsStranded(_run(TWO_HOPS, IN, STRANDED, 9, 10, false), STRANDED, "two hops");
    }

    /// tokenIn == tokenOut: the output baseline is baseIn, so the Router ends
    /// holding F exactly and the output is measured past it.
    function test_ANegativeInputRestatementFiredByTheHop0FeePush_LeavesTheStrandedBalance_CyclicRoute() public {
        _assertKeepsStranded(_run(CYCLIC, IN, STRANDED, 9, 10, false), STRANDED, "cyclic");
    }

    /// k = 1/2 with F = 5 A: the restated balance is below F, the swap owns
    /// nothing and the hop is refused instead of spending F.
    function test_AHalvingRestatementWithTheSwapOwningNothing_IsRefusedAndKeepsTheStrandedBalance() public {
        World memory w = _run(ONE_LEG, IN, STRANDED, 1, 2, false);
        assertFalse(w.ok, "nothing past F to spend");
        assertEq(w.code, 8, "RouterE(8): the hop has no input");
        assertEq(w.routerIn, STRANDED, "reverted: F intact");
    }

    function test_TheCutPastTheSignedFloorIsRefused() public {
        World memory w = _run(ONE_LEG, IN, STRANDED, 9, 10, true);
        assertFalse(w.ok, "the cut is past the attested floor");
        assertEq(w.code, 5, "RouterE(5): the floors, not a later guard");
        assertEq(w.routerIn, STRANDED, "reverted: F intact");
    }

    /// The push loses one wei more than the fee: k = (X - 1) / X on the
    /// Router's X shares after treasury 1's part. F = 1 wei stays.
    function test_AOneWeiRoundingTokenWithOneWeiStranded_Settles() public {
        uint256 fee = _fee(IN);
        uint256 x = 1 + IN - BPC.mulDiv(fee, 3_000, BPC.BPS);
        World memory w = _run(ONE_LEG, IN, 1, x - 1, x, false);
        assertTrue(w.ok, "settles");
        assertEq(w.routerIn, 1, "the one stranded wei stays");
        assertGt(w.spent, 0, "spent");
    }

    // --- controls --------------------------------------------------------------

    /// A positive restatement grows the balance past F + A - fee: the growth
    /// is not the swap's input (the `decl` ceiling), it is swept to the payer.
    function test_Control_APositiveRestatementIsNotSpent() public {
        World memory w = _run(ONE_LEG, IN, STRANDED, 11, 10, false);
        assertTrue(w.ok, "settles");
        // The pair's restated balance rounds the delivery down by at most one wei.
        assertLe(w.spent, IN - _fee(IN), "the hop spends the pull less its fee, not the growth");
        assertGe(w.spent + 1, IN - _fee(IN), "and all of it");
        assertGe(w.routerIn, STRANDED, "F stays");
    }

    /// No stranded balance (F = 0): the restated pull is spent whole and the
    /// short delivery is measured, inside the one-wei floor.
    function test_Control_NoStrandedBalance_ShortDeliveryInsideTheFloor() public {
        World memory w = _run(ONE_LEG, IN, 0, 9, 10, false);
        assertTrue(w.ok, "settles");
        assertEq(w.routerIn, 0, "the Router holds nothing");
        assertLt(w.spent, IN - _fee(IN), "short");
        assertGt(w.delivered, 0, "delivered");
    }

    /// Honest tokenIn: the measured delta past F is the pull less its fee,
    /// wei for wei, for every F.
    function testFuzz_HonestInput_Hop0SpendsTheMeasuredPullLessItsFee(uint256 amt, uint256 f, uint8 shape) public {
        amt = bound(amt, 1e6, 1e21);
        f = bound(f, 0, 2 ** 96);
        shape = uint8(bound(shape, ONE_LEG, CYCLIC));
        World memory w = _run(shape, amt, f, 0, 0, false);
        assertTrue(w.ok, "settles");
        uint256 net = amt - _fee(amt);
        // Two legs: each leg is scaled by net / amt and floored on its own.
        uint256 want = shape == TWO_LEGS
            ? BPC.mulDiv(amt / 2, net, amt) + BPC.mulDiv(amt - amt / 2, net, amt)
            : net;
        assertEq(w.spent, want, "hop 0 spends the pull less its fee");
        assertEq(w.routerIn, f, "the Router keeps F");
    }
}
