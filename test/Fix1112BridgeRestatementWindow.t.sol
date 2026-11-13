// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  4111 (whitelistsol, 2026-11-11): the bridge window under a restatement fired
//  by hop 0's delivery - Router._hopScaleImpactAndQuote, hop h >= 1,
//  `realIn = bal - foreignBase` (the R3 / BP-15 guard, invariant I1).
//
//  WHAT THE ROUTER SEES of the bridge B between hop 0 and hop 1:
//    F   = bridgeBase[0], the balance it held before hop 0 (the rescue's money);
//    bal = its balance after hop 0 delivered;
//    L   = the caller's declared hop-1 input (sum of leg.amountIn of hop 1).
//  Two worlds produce the SAME triple (F, bal, L):
//    R  a uniform restatement k fired by the delivery:  bal = k * (F + D);
//    T  hop 0 short by c with F intact (a stale quote,
//       a tax on the delivery, a pair that moved):     bal = F + D - c,
//  whenever c = (1 - k) * (F + D). In T the only lawful spend is bal - F: one
//  wei more is the balance held before the swap, the drain R3 / BP-15 closes
//  (test/HardeningR3_HopForeignBalance.t.sol). In R the "fair" spend k * D =
//  bal - k * F exceeds bal - F by (1 - k) * F. No rule of (F, bal, L) gives
//  the two worlds different answers, and the instruments that would tell them
//  apart (sharesOf, totalSupply) belong to the token that fired the
//  restatement. So the window keeps the measured delta (I4: the measurement
//  wins), and the restatement's cut on F lands where a short delivery lands:
//  on the swapper, inside the floor they signed (SOK-FOT); past it the hop is
//  refused (RouterE(5)). The Router keeps F in the only units it measures.
//
//  These tests pin that triangle and kill the two "fixes" that would open the
//  window: the raw balance (foreignBase forgotten) and the pro-rata share
//  `bal * L / (L + F)` of the declared input - a figure the caller writes, so
//  a route that declares L = 1e30 spends the whole stranded balance.
//
//  World R needs the hop-1 pair to hold B above its stale reserves, or the
//  restatement leaves the pair declaring more than it holds and the leg is
//  dead (RouterE(8), Core.heldBy): the finding's PoC over-funded it 5000x,
//  here it holds the minimum plus three wei. World T is the honest token on a
//  pair whose B reserve moved after the quote, so the two worlds differ in
//  nothing but the restatement.
//
//  Green at e01b503 (origin/main); the restated world's dust (one wei of the
//  fee push's rounding, booked as owed and held with F, see the test) is
//  pinned over e4185d8 (4122). Red under mutants.py [bridge-1112 a] and
//  [bridge-1112 b], and [fin1111-router-1] by the dust. Matrix: gamma F in
//  {1 wei, D/1000, 9 D}; vectors taxed
//  bridge, over-declared hop-1 input, restatement fired on delivery (k =
//  999/1000 inside the signed floor, k = 1/2 past it); unit, 2 hops, ERC20.
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

contract Fix1112BridgeRestatementWindowTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    BlazePhoenixRouter router;
    MockPermit2 permit2;

    address constant T1 = address(0xFEE1);
    address constant T2 = address(0xFEE2);
    address user = address(0xBEEF);
    address recip = address(0xCAFE);

    uint256 constant RES = 200e18; // every pair: both reserves
    uint256 constant IN = 100e18;

    uint8 constant HONEST = 0;
    uint8 constant TAX = 1; // p = bps taken from every delivery, F intact
    uint8 constant RESTATE = 2; // p/q = the factor fired by the delivery to the Router

    struct Case {
        uint8 mode;
        uint256 p;
        uint256 q;
        uint256 foreignMilli; // F in thousandths of D ...
        uint256 foreignWei; // ... plus this many wei
        uint256 l; // hop 1's declared input (0 = D)
        uint256 minBps; // the signed floor on the attested output (0 = one wei)
        uint256 overHold; // B the hop-1 pair holds above its reserve (its x side)
        uint256 staleRB; // pairAB's B reserve once the route is built (0 = untouched)
    }

    struct World {
        bool ok;
        uint16 code;
        uint256 delivered; // tokenOut C received by `recip`
        uint256 routerB; // the Router's bridge balance after the swap, display units
        uint256 routerShares; // the same balance in the token's own shares
        uint256 poolShares; // shares of B the hop-1 pair received
        uint256 aIn; // A that reached pairAB (hop 0's real input)
        uint256 d; // hop 0's attested output
        uint256 exp1; // the attested hop-1 output
        uint256 foreign; // F as minted
        uint256 owed; // fee shares of B booked to the two slots by the swap (4122)
    }

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        solver = new BlazePhoenixSolver(address(hub), address(0));
        router = new BlazePhoenixRouter(address(hub), address(solver), address(this), T1, T2);
        hub.setRoles(address(router), address(solver), address(this));
        permit2 = new MockPermit2();
        router.setPermit2(address(permit2));
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

    function _c(uint8 mode, uint256 p, uint256 q, uint256 milli, uint256 wei_, uint256 l, uint256 minBps)
        internal pure returns (Case memory c)
    {
        c = Case(mode, p, q, milli, wei_, l, minBps, 0, 0);
    }

    /// The least B a stale pair must hold above its reserve so that a p/q
    /// restatement leaves it holding what it declares (plus three wei).
    function _overHoldFor(uint256 p, uint256 q) internal pure returns (uint256) {
        return BPC.mulDivUp(RES, q, p) - RES + 3;
    }

    /// The B reserve at which pairAB pays exactly `target` for `aIn` of A.
    function _reserveFor(uint256 aIn, uint256 target) internal pure returns (uint256 rB) {
        uint256 amtFee = aIn * (BPC.BPS - 30);
        rB = target * (RES * BPC.BPS + amtFee) / amtFee;
        while (BPC.outV2(aIn, RES, rB, 30) < target) ++rB;
        while (BPC.outV2(aIn, RES, rB, 30) > target) --rB;
        assertEq(BPC.outV2(aIn, RES, rB, 30), target, "reserveFor: exact hit");
        assertLe(rB, RES, "reserveFor: the pair holds what it declares");
    }

    function _pair(address x, address y, uint256 extraX) internal returns (MockV2Pair p) {
        p = new MockV2Pair(x, y);
        MockERC20(x).mint(address(p), RES + extraX); // both mocks expose mint(address,uint256)
        MockERC20(y).mint(address(p), RES);
        p.setReserves(uint112(RES), uint112(RES)); // symmetric: the token order does not matter
        hub.seedPool(address(p), BPC.KIND_V2, 30, address(0), x, y);
    }

    function _route2(
        address pool0, bool zfo0, address tA, address tB, uint256 exp0,
        address pool1, bool zfo1, address tC, uint256 l, uint256 exp1
    ) internal pure returns (Route memory r) {
        Leg[] memory legs0 = new Leg[](1);
        legs0[0] = Leg({
            pool: pool0, hooks: address(0), kind: BPC.KIND_V2, fee: 30, tickSpacing: 0,
            zeroForOne: zfo0, stable: false, amountIn: IN, expectedOut: exp0, auxId: bytes32(0)
        });
        Leg[] memory legs1 = new Leg[](1);
        legs1[0] = Leg({
            pool: pool1, hooks: address(0), kind: BPC.KIND_V2, fee: 30, tickSpacing: 0,
            zeroForOne: zfo1, stable: false, amountIn: l, expectedOut: exp1, auxId: bytes32(0)
        });
        Hop[] memory hops = new Hop[](2);
        hops[0] = Hop({tokenIn: tA, tokenOut: tB, amountIn: IN, expectedOut: exp0, legs: legs0});
        hops[1] = Hop({tokenIn: tB, tokenOut: tC, amountIn: l, expectedOut: exp1, legs: legs1});
        r = Route({
            hops: hops, totalOut: exp1, singleOut: exp1, singleOutFloor: 0,
            expectedImpactBps: 0, confidenceWad: 0, estGas: 0, hasSurplus: false, isV4Bundle: false
        });
    }

    /// One swap A -> B -> C on fresh pools, F minted to the Router before it.
    /// The route is built from the UNTAXED quotes at the pairs' reserves (hop 0
    /// attested at D, hop 1 declared at `l`, or D), as a quoter that does not
    /// model the token's pathology builds it.
    function _run(Case memory c) internal returns (World memory w) {
        MockERC20 tA = new MockERC20("A", "A");
        PathologicalERC20 tB = new PathologicalERC20("B", "B", 18);
        MockERC20 tC = new MockERC20("C", "C");
        MockV2Pair pairAB = _pair(address(tA), address(tB), 0);
        MockV2Pair pairBC = _pair(address(tB), address(tC), c.overHold);

        tA.mint(user, IN);
        vm.prank(user);
        tA.approve(address(router), type(uint256).max);

        uint256 fee0 = BPC.mulDivUp(IN, BPC.PROTOCOL_FEE_BPS, BPC.BPS);
        w.d = BPC.outV2(IN - fee0, RES, RES, 30);
        w.foreign = w.d * c.foreignMilli / 1000 + c.foreignWei;
        if (w.foreign > 0) tB.mint(address(router), w.foreign);
        if (c.mode == TAX) tB.setFeeOnTransferBps(uint16(c.p));
        if (c.mode == RESTATE) tB.setRebaseOnTransferTo(address(router), c.p, c.q);

        uint256 feeD = BPC.mulDivUp(w.d, BPC.PROTOCOL_FEE_BPS, BPC.BPS);
        w.exp1 = BPC.outV2(w.d - feeD, RES, RES, 30);
        uint256 l = c.l == 0 ? w.d : c.l;
        bool aIs0 = pairAB.token0() == address(tA);
        Route memory route = _route2(
            address(pairAB), aIs0, address(tA), address(tB), w.d,
            address(pairBC), pairBC.token0() == address(tB), address(tC), l, w.exp1
        );
        if (c.staleRB != 0) {
            if (aIs0) pairAB.setReserves(uint112(RES), uint112(c.staleRB));
            else pairAB.setReserves(uint112(c.staleRB), uint112(RES));
        }
        uint256 minOut = c.minBps == 0 ? 1 : w.exp1 * c.minBps / BPC.BPS;

        uint256 poolSharesBefore = tB.sharesOf(address(pairBC));
        vm.prank(user);
        (bool ok, bytes memory err) = address(router).call(
            abi.encodeCall(router.swapExactIn, (route, IN, minOut, recip, block.timestamp + 100))
        );
        w.ok = ok;
        w.code = ok ? 0 : _code(err);
        w.delivered = tC.balanceOf(recip);
        w.routerB = tB.balanceOf(address(router));
        w.routerShares = tB.sharesOf(address(router));
        w.owed = router.owed(address(tB), 0) + router.owed(address(tB), 1);
        w.poolShares = tB.sharesOf(address(pairBC)) - poolSharesBefore;
        w.aIn = tA.balanceOf(address(pairAB)) - RES;
    }

    // --- a taxed bridge over a stranded balance ------------------------------

    /// Hop 0 delivers D - c (a 1 % tax), the route was built from D. Hop 1 spends
    /// `realIn = bal - bridgeBase` = D - c and not one wei of F, for F of one
    /// wei, a thousandth of D and nine times D: the swapper gets exactly what
    /// the no-foreign control gets, and the Router keeps exactly F.
    /// Red under [bridge-1112 a] (the raw balance spends F) and, at the two
    /// larger F, under [bridge-1112 b] (the pro-rata share of the declared D
    /// spends F * c / (F + D) of the stranded balance).
    function test_ATaxedBridgeOverAStrandedBalanceSpendsOnlyWhatHopZeroDelivered() public {
        World memory c = _run(_c(TAX, 100, 0, 0, 0, 0, 0));
        assertTrue(c.ok, "control: the taxed route settles inside the floors");
        assertEq(c.routerB, 0, "control: a Router that held nothing holds nothing");

        uint256[3] memory milli = [uint256(0), 1, 9000];
        uint256[3] memory wei_ = [uint256(1), 0, 0];
        for (uint256 i; i < 3; ++i) {
            World memory w = _run(_c(TAX, 100, 0, milli[i], wei_[i], 0, 0));
            assertTrue(w.ok, "the stranded balance changes nothing about settling");
            assertEq(w.delivered, c.delivered, "realIn is D - c: the stranded balance bought the swapper nothing");
            assertEq(w.routerB, w.foreign, "the Router keeps exactly the balance it held before the swap");
        }
    }

    // --- an over-declared hop-1 input ----------------------------------------

    /// The caller writes L = 1e30 into hop 1 while hop 0 delivered D onto a Router
    /// holding 9 D. The scale is realIn / L, so the leg spends D: the Router keeps
    /// 9 D and the swapper gets the honest control's output. A share of the
    /// balance taken in proportion to L ([bridge-1112 b]) would spend it all.
    function test_AnOverDeclaredBridgeInputNeverReachesTheStrandedBalance() public {
        World memory c = _run(_c(HONEST, 0, 0, 0, 0, 0, 0));
        assertTrue(c.ok, "control: the honest route settles");
        World memory w = _run(_c(HONEST, 0, 0, 9000, 0, 1e30, 0));
        assertTrue(w.ok, "the declared input is a divisor, not a budget");
        assertEq(w.delivered, c.delivered, "the leg spends what hop 0 delivered, whatever hop 1 declares");
        assertEq(w.routerB, w.foreign, "the stranded 9 D never reaches the pool");
    }

    // --- the restatement fired by the delivery -------------------------------

    /// k = 999/1000 fired by hop 0's delivery over F = 9 D is, to the Router, the
    /// honest token whose pair paid k * (F + D) - F for hop 0: the same bal - F,
    /// the same hop-1 spend (the pair's shares say so), the same output to
    /// within the stale pair's three wei, the same F left in the Router plus the
    /// token's rounding on the fee pushes (below). The cut (1 - k) * F lands on
    /// the swapper inside the 98 % they signed, as the finding measures (the
    /// Router's shares of B exceed what it held). Past the floor (k = 1/2,
    /// F = 0.15 D, hop 0 attested at D) the hop is refused with RouterE(5) by the
    /// per-leg coverage floor and the hop budget, each watched by its own mutant
    /// ([coverage-gate], [per-hop budget]).
    ///
    /// THE DUST (4122, `Router._push`). Under k < 1 the token takes
    /// floor(t * q / p) shares for t of display, so a fee push of t can move
    /// t - 1 at both ends: the Router loses t - 1 and the payee gains t - 1.
    /// The push books the wei the share is short as `owed` to its slot and keeps
    /// it out of every swap-path balance read (`_bal`), so hop 1 spends
    /// bal - owed - F = what hop 0 delivered less the fee (4111-2, `_owned`) and
    /// the Router's display balance ends at F + owed: dust = 1 here, the 30 %
    /// share. It is a fee the treasury claims, not the swapper's and not the
    /// rescue's (I7: rounding lands with the protocol). Before 4122 the wei was
    /// nobody's: hop 1 spent it as input (4111-1, the Router kept F exactly) or
    /// the baseline kept it (4111-2, F + 1 with nothing owed).
    /// Red under [fin1111-router-1] / [1026] (the push believes the answer, the
    /// short wei is not booked: F + 1 held, nothing owed) and [bridge-1112 a]
    /// (the raw balance is spent, F included).
    /// Bounty uids 4077, 4079, 4080 (one root: a negative rebase over a stranded balance).
    function test_ANegativeBridgeRestatementIsOneObservationWithAShortDelivery() public {
        Case memory cr = _c(RESTATE, 999, 1000, 9000, 0, 0, 9800);
        cr.overHold = _overHoldFor(999, 1000);
        World memory r = _run(cr);
        assertEq(uint256(r.code), 0, "restated world settles inside the signed minimum");
        assertGt(r.routerShares, r.foreign, "the restatement's cut on F stays as shares of B (the finding, inside the floor)");

        // bal - F, from what the pair paid at factor 1 and the factor the delivery fired.
        uint256 dReal = BPC.outV2(r.aIn, RES, RES, 30);
        uint256 spendR = (r.foreign + dReal) * 999 / 1000 - r.foreign;
        // The dust: the fee on bal - F goes out in two pushes of display, each taking
        // floor(t * 1000 / 999) shares, so the Router's loss falls short of the share by the
        // token's rounding; the push books that wei as owed (4122) and hop 1 spends
        // bal - owed - F - feeH (`_owned`), so the Router holds F plus what it owes.
        {
            uint256 feeH = BPC.mulDivUp(spendR, BPC.PROTOCOL_FEE_BPS, BPC.BPS);
            uint256 t1 = BPC.mulDiv(feeH, 3_000, BPC.BPS); // TREASURY1_SHARE
            uint256 shares2 = r.foreign + dReal - t1 * 1000 / 999 - (feeH - t1) * 1000 / 999;
            uint256 dust = shares2 * 999 / 1000 - (r.foreign + spendR - feeH);
            assertEq(dust, 1, "the two fee pushes' rounding at k = 999/1000: one wei of display");
            assertEq(r.owed, dust, "the wei the fee push fell short is booked to its slot (4122)");
            assertEq(r.routerB, r.foreign + r.owed, "the Router keeps F in display plus what it owes: hop 1 spends bal - owed - F - feeH and no more");
        }

        Case memory ct = _c(HONEST, 0, 0, 9000, 0, 0, 9800);
        ct.overHold = cr.overHold;
        ct.staleRB = _reserveFor(r.aIn, spendR);
        World memory t = _run(ct);
        assertEq(uint256(t.code), 0, "short-delivery world settles inside the signed minimum");
        assertEq(t.routerB, t.foreign, "the same F in the honest world");
        assertApproxEqAbs(r.poolShares * 999 / 1000, t.poolShares, 2, "one triple (F, bal, L), one hop-1 spend");
        assertApproxEqAbs(r.delivered, t.delivered, 4, "one spend, one output");

        Case memory c0 = _c(RESTATE, 999, 1000, 0, 0, 0, 9800);
        c0.overHold = cr.overHold;
        World memory r0 = _run(c0);
        assertEq(uint256(r0.code), 0, "no-foreign restated control settles");
        assertLt(r.delivered, r0.delivered, "the cut on F is the swapper's, bounded by minOut");
        assertGe(r.delivered, r.exp1 * 9800 / BPC.BPS, "never below the signed minimum");

        Case memory cf = _c(RESTATE, 1, 2, 150, 0, 0, 0);
        cf.overHold = _overHoldFor(1, 2);
        World memory far = _run(cf);
        assertFalse(far.ok, "a restatement past the floor is refused");
        assertEq(far.code, 5, "RouterE(5): the floors, not a later guard");
        assertEq(far.routerB, far.foreign, "a refused swap leaves F untouched");
    }
}
