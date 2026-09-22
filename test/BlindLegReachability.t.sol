// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  PROBE — is a leg that EXECUTES but cannot be QUOTED reachable, and what do the
//  floors see when it is?
//
//  The measurement and the per-leg floor share one condition (Router:1590):
//
//      bool guard = legOut != address(0) && amt != 0
//          && ((leg.expectedOut != 0 && leg.amountIn != 0)
//              || (legQuote != 0 && legAmt != 0));
//
//  so a leg with neither a caller attestation nor an in-frame quote returns zero
//  for BOTH `got` and `attested`. The hop loop adds both, which means the leg
//  leaves no trace on either side of the aggregate comparison at Router:1299:
//
//      slack = mulDiv(hopAttested / hopQuoted, BPS - LEG_FLOOR_BPS, BPS);
//      if (hopGot + slack < hopAttested) revert RouterE(5);
//
//  Whether that matters depends on a question this file asks rather than assumes:
//  can a leg execute at all while being unquotable? Two of the three families say
//  no by construction — a pair leg with no input-side reserve computes a zero
//  output and reverts at Router:1807. The concentrated branch is the open one: the
//  quote runs only under `sp != 0 && lq != 0` (Router:828), and nothing ties the
//  liquidity a pool REPORTS to the liquidity it SWAPS with.
//
//  Reported by Seavia Resources, ninth bounty wave. The report cites a proof of
//  concept that did not reach us, so this is built from the source rather than
//  from theirs, and it records what happens instead of asserting what should.
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV3Pool} from "./mocks/MockV3Pool.sol";

contract BlindLegReachability is Test {
    BlazePhoenixHub    internal hub;
    BlazePhoenixSolver internal solver;
    BlazePhoenixRouter internal router;

    MockERC20  internal tokenA;
    MockERC20  internal tokenB;
    MockV3Pool internal honest;
    MockV3Pool internal blind;

    address internal s0;
    address internal s1;

    address internal user = address(0xBEEF);
    address constant T1 = address(0xFEE1);
    address constant T2 = address(0xFEE2);

    uint160 constant Q96  = uint160(uint256(1) << 96);   // price 1:1
    uint128 constant LIQ  = uint128(1e27);
    uint256 constant PHYS = 500_000e18;
    uint256 constant AMT  = 1_000e18;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        solver = new BlazePhoenixSolver(address(hub));
        router = new BlazePhoenixRouter(
            address(hub), address(solver), address(this), T1, T2);
        hub.setRoles(address(router), address(solver), address(this));

        tokenA = new MockERC20("A", "A");
        tokenB = new MockERC20("B", "B");

        honest = new MockV3Pool(address(tokenA), address(tokenB), 3000);
        honest.setState(Q96, LIQ);

        // The divergence under test: the pool REPORTS no liquidity, so the quote
        // loop skips it, and SWAPS with real liquidity, so execution succeeds.
        blind = new MockV3Pool(address(tokenA), address(tokenB), 3000);
        blind.setState(Q96, 0);
        blind.setSwapLiquidity(LIQ);

        s0 = honest.token0();
        s1 = honest.token1();

        tokenA.mint(address(honest), PHYS);
        tokenB.mint(address(honest), PHYS);
        tokenA.mint(address(blind), PHYS);
        tokenB.mint(address(blind), PHYS);

        tokenA.mint(user, 1_000_000e18);
        tokenB.mint(user, 1_000_000e18);
        vm.startPrank(user);
        tokenA.approve(address(router), type(uint256).max);
        tokenB.approve(address(router), type(uint256).max);
        vm.stopPrank();
    }

    function _leg(address pool, uint256 amt, uint256 expectedOut)
        internal pure returns (Leg memory)
    {
        return Leg({
            pool: pool, hooks: address(0), kind: BPC.KIND_V3,
            fee: 3000, tickSpacing: 0, zeroForOne: true, stable: false,
            amountIn: amt, expectedOut: expectedOut, auxId: bytes32(0)
        });
    }

    /// @dev PROBE 1 — does the quote loop really skip a pool that reports zero
    ///      liquidity while the same pool executes? Measured one leg at a time so
    ///      the two answers cannot be confused with each other.
    function test_Probe_TheBlindPoolExecutesWhileReportingNothing() public {
        Leg[] memory legs = new Leg[](1);
        legs[0] = _leg(address(blind), AMT, 0);
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({tokenIn: s0, tokenOut: s1, amountIn: AMT, expectedOut: 0, legs: legs});
        Route memory r = Route({
            hops: hops, totalOut: 0, singleOut: 0, singleOutFloor: 0,
            expectedImpactBps: 0, confidenceWad: 0, estGas: 0,
            hasSurplus: false, isV4Bundle: false
        });

        uint256 before = MockERC20(s1).balanceOf(user);
        vm.prank(user);
        try router.swapExactIn(r, AMT, 1, user, block.timestamp + 1) returns (uint256 out) {
            emit log("OPEN: a pool reporting zero liquidity executed a swap");
            emit log_named_uint("delivered", out);
            emit log_named_uint("balance delta", MockERC20(s1).balanceOf(user) - before);
        } catch (bytes memory e) {
            emit log_named_bytes("REFUSED", e);
        }
    }

    /// @dev PROBE 2 — the shape the report describes: one hop, one attested and
    ///      quotable leg beside one blind leg. If the blind leg delivers far less
    ///      than its share, does anything stop the swap?
    function test_Probe_ABlindLegBesideAnHonestOne() public {
        uint256 half = AMT / 2;
        Leg[] memory legs = new Leg[](2);
        legs[0] = _leg(address(honest), half, half);   // attested, quotable
        legs[1] = _leg(address(blind),  half, 0);      // neither
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({tokenIn: s0, tokenOut: s1, amountIn: AMT, expectedOut: AMT, legs: legs});
        Route memory r = Route({
            hops: hops, totalOut: AMT, singleOut: AMT, singleOutFloor: 0,
            expectedImpactBps: 0, confidenceWad: 0, estGas: 0,
            hasSurplus: false, isV4Bundle: false
        });

        vm.prank(user);
        try router.swapExactIn(r, AMT, 1, user, block.timestamp + 1) returns (uint256 out) {
            emit log("OPEN: the hop settled with one leg outside every measurement");
            emit log_named_uint("delivered", out);
            emit log_named_uint("the hop asked for", AMT);
        } catch (bytes memory e) {
            emit log_named_bytes("REFUSED", e);
        }
    }

    /// @dev PROBE 3 — the one that decides. The blind leg now swaps against a
    ///      thousandth of the liquidity it would need, so it eats its half of the
    ///      input and returns almost nothing. The honest half is attested and
    ///      delivers. Nothing in the hop can see the loss, because the leg that
    ///      took it is absent from both sides of the aggregate comparison.
    ///
    ///      If this settles, the report holds: a hop can lose most of its value
    ///      through a leg no floor is watching. If it reverts, something catches
    ///      it and the finding is inert — and the error tells us which guard.
    function test_Probe_ABlindLegThatEatsItsHalf() public {
        // Swept rather than guessed: the divisor decides how little the blind leg
        // answers with, and the point is where the protocol stops it - if it does.
        uint256[5] memory div = [uint256(1e3), 1e5, 1e7, 1e9, 1e12];
        for (uint256 i; i < div.length; ++i) {
            _sweep(div[i]);
        }
    }

    function _sweep(uint256 divisor) private {
        uint128 l = uint128(LIQ / divisor);
        if (l == 0) l = 1;
        blind.setSwapLiquidity(l);

        uint256 half = AMT / 2;
        Leg[] memory legs = new Leg[](2);
        legs[0] = _leg(address(honest), half, half);
        legs[1] = _leg(address(blind),  half, 0);
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({tokenIn: s0, tokenOut: s1, amountIn: AMT, expectedOut: AMT, legs: legs});
        Route memory r = Route({
            hops: hops, totalOut: AMT, singleOut: AMT, singleOutFloor: 0,
            expectedImpactBps: 0, confidenceWad: 0, estGas: 0,
            hasSurplus: false, isV4Bundle: false
        });

        uint256 before = MockERC20(s1).balanceOf(user);
        vm.prank(user);
        try router.swapExactIn(r, AMT, 1, user, block.timestamp + 1) returns (uint256) {
            uint256 got = MockERC20(s1).balanceOf(user) - before;
            uint256 lostBps = ((AMT - got) * 10_000) / AMT;
            emit log_named_uint("SETTLED with divisor", divisor);
            emit log_named_uint("   lost (bps)       ", lostBps);
            // THE ASSERTION. The hop attested AMT, and the protocol floors are all
            // that stands behind a caller who passed no bound of their own - the
            // case the entry docstring says they cover: "passing 0 delegates
            // protection to the protocol floors alone, which BOUNDS sandwich loss".
            // A hop that delivers half of what it attested is bounded by nothing.
            assertLt(lostBps, 2_500,
                "a hop settled past the 25% the floors are documented to hold");
        } catch (bytes memory e) {
            emit log_named_uint("REFUSED with divisor", divisor);
            emit log_named_bytes("   by              ", e);
        }
    }

    /// @dev CONTROL — the same route with BOTH legs quotable. If this one is also
    ///      refused, probe 2 proves nothing about blindness and everything about
    ///      the fixture.
    function test_Control_TwoHonestLegsSettle() public {
        uint256 half = AMT / 2;
        Leg[] memory legs = new Leg[](2);
        legs[0] = _leg(address(honest), half, half);
        legs[1] = _leg(address(honest), half, half);
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({tokenIn: s0, tokenOut: s1, amountIn: AMT, expectedOut: AMT, legs: legs});
        Route memory r = Route({
            hops: hops, totalOut: AMT, singleOut: AMT, singleOutFloor: 0,
            expectedImpactBps: 0, confidenceWad: 0, estGas: 0,
            hasSurplus: false, isV4Bundle: false
        });

        vm.prank(user);
        try router.swapExactIn(r, AMT, 1, user, block.timestamp + 1) returns (uint256 out) {
            emit log_named_uint("control settled, delivered", out);
        } catch (bytes memory e) {
            emit log_named_bytes("control REFUSED (the fixture, not the finding)", e);
        }
    }

    /// @dev THE CONTROL THE MUTANT ASKED FOR, built so the difference can decide.
    ///      A leg scaled to zero input moved nothing, so it is not blindness. The
    ///      first version of this test could not tell the two apart: with the
    ///      attestation and the in-frame quote a few basis points apart, the floor
    ///      cleared either way and the mutation changed nothing observable. The
    ///      second could not either, and the mutation guard said so: its delivering
    ///      leg sat on the pool that reports no liquidity, so that leg was blind by
    ///      itself and the zero-input leg never decided anything.
    ///
    ///      Here the delivering leg is on the pool the frame CAN price and carries
    ///      no attestation, so it is measured and the hop's figure rests on the
    ///      in-frame quote alone, while the caller writes a hop total of double.
    ///      Only treating the zero-input leg as blind can hand the floor that
    ///      inflated figure - which is what must not happen, and what this sees.
    function test_Control_AZeroInputLegIsNotBlindness() public {
        Leg[] memory legs = new Leg[](2);
        legs[0] = _leg(address(honest), AMT, 0);   // delivers, measured in frame, unattested
        legs[1] = _leg(address(honest), 0,   0);   // scaled to nothing
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({tokenIn: s0, tokenOut: s1, amountIn: AMT, expectedOut: AMT * 2, legs: legs});
        Route memory r = Route({
            hops: hops, totalOut: AMT, singleOut: AMT, singleOutFloor: 0,
            expectedImpactBps: 0, confidenceWad: 0, estGas: 0,
            hasSurplus: false, isV4Bundle: false
        });

        uint256 before = MockERC20(s1).balanceOf(user);
        vm.prank(user);
        router.swapExactIn(r, AMT, 1, user, block.timestamp + 1);
        assertGt(MockERC20(s1).balanceOf(user) - before, 0,
            "a hop carrying a zero-input leg must still settle");
    }

    /// @dev AN OVER-STATED HOP TOTAL MUST NOT INFLATE THE PROTOCOL FLOOR. The
    ///      fallback reaches for `hop.expectedOut` only when a leg went unmeasured;
    ///      here every leg is attested and priced, so the hop's own figure - which
    ///      the caller writes and can write high - must not become the floor's
    ///      basis. Written because the mutant that flags EVERY leg as blind
    ///      survived three earlier controls: with an honest hop total the max
    ///      changes nothing, so no honest route could tell the two apart.
    function test_Control_AnOverStatedHopTotalDoesNotRaiseTheFloor() public {
        Leg[] memory legs = new Leg[](1);
        legs[0] = _leg(address(honest), AMT, AMT);       // attested and quotable
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({
            tokenIn: s0, tokenOut: s1, amountIn: AMT,
            expectedOut: AMT * 2,                        // the caller claims double
            legs: legs
        });
        Route memory r = Route({
            hops: hops, totalOut: AMT, singleOut: AMT, singleOutFloor: 0,
            expectedImpactBps: 0, confidenceWad: 0, estGas: 0,
            hasSurplus: false, isV4Bundle: false
        });

        uint256 before = MockERC20(s1).balanceOf(user);
        vm.prank(user);
        router.swapExactIn(r, AMT, 1, user, block.timestamp + 1);
        assertGt(MockERC20(s1).balanceOf(user) - before, 0,
            "an inflated hop total must not become the protocol floor's basis");
    }
}
