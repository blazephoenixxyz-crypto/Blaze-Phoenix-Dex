// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  I-FEE family, second member — a threshold computed by floor division is a
//  guard that switches itself off on small numbers.
//
//  The per-leg iron floor (Router, end of _legFloor):
//
//      if (bound != 0 && got < BPC.mulDiv(bound, BPC.LEG_FLOOR_BPS, BPC.BPS))
//          revert RouterE(5);
//
//  LEG_FLOOR_BPS is 8_000, so the threshold is floor(bound * 0.8). For
//  bound == 1 that is floor(0.8) == 0, and `got < 0` is never true for an
//  unsigned. The guard is present, is reached, and cannot fire: a leg whose
//  bound is one wei may deliver ZERO and pass.
//
//  This is the same shape as the protocol-fee defect fixed in
//  FeeCannotRoundToZero.t.sol — floor division manufactures a zero, and a zero
//  threshold is a disabled check. The cure is the same lever: round the
//  threshold UP, so a non-zero bound always demands a non-zero delivery.
//
//  The window is narrow and the loss is small — bound == 1 exactly, so at most
//  a wei of expected output — and every aggregate floor plus userMinOut still
//  stands behind it. This is filed as a CONSISTENCY defect, not a value-loss
//  one, and the test is written to prove the guard fires, not to claim a theft.
//
//  ISOLATION: the aggregate floors would mask a single-leg dust route, so the
//  hop carries TWO legs — an honest pair that delivers the bulk (satisfying
//  Layer 1, the protocol floor and userMinOut) and a hostile pair that quotes
//  one wei and delivers nothing. Only the per-leg guard is left to catch it.
//
//  RESULT OF TRYING TO REACH IT: not reachable today, and this file is the
//  evidence. For the collapsed threshold to matter you need bound == 1 AND
//  got == 0 in the same leg — but the only delivery below 80% of 1 is 0, and
//  the V2/Solidly executor already refuses to ask a pool for zero output
//  (`if (outAmt == 0) revert RouterE(8);`) BEFORE the pool is even called. A
//  stricter guard upstream dominates the degenerate window.
//
//  The threshold was rounded up anyway (rule R-C: no protective threshold may
//  be computed by a division that rounds down). The first reason not to —
//  byte cost on a contract at the EIP-170 wall — stopped applying once the
//  optimiser runs could be lowered, and unreachability is a property of
//  today's call graph, not a guarantee. A guard whose threshold can be zero is
//  a guard that switches itself off; relying on a second guard to cover it
//  makes the first one decorative.
//
//  Two things are pinned below: the arithmetic that made the collapse
//  possible, and the executor refusal that is doing the real work. If someone
//  relaxes that refusal, the second test goes red.
//
//  forge test --match-contract LegFloorThresholdRoundsToZero -vv
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";

interface IERC20X {
    function transfer(address to, uint256 amt) external returns (bool);
    function balanceOf(address who) external view returns (uint256);
}

/// @dev V2-shaped pair that QUOTES a non-zero output (its reserves are real and
///      `outV2` prices them) but DELIVERS nothing. It is the minimum shape that
///      separates `bound` from `got`: the bound comes from the reserves, the
///      `got` comes from a measured balance delta that never moves.
contract QuotesOneDeliversNothing {
    address public token0;
    address public token1;
    uint112 public reserve0;
    uint112 public reserve1;

    constructor(address a, address b) {
        (token0, token1) = a < b ? (a, b) : (b, a);
    }

    function setReserves(uint112 r0, uint112 r1) external {
        reserve0 = r0;
        reserve1 = r1;
    }

    function getReserves() external view returns (uint112, uint112, uint32) {
        return (reserve0, reserve1, uint32(block.timestamp));
    }

    /// Accepts the input, transfers NOTHING out.
    function swap(uint256, uint256, address, bytes calldata) external {}
}

contract LegFloorThresholdRoundsToZeroTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    BlazePhoenixRouter router;

    MockERC20 tokA;
    MockERC20 tokB;
    MockV2Pair honest;
    QuotesOneDeliversNothing hostile;

    address user = address(0xBEEF);
    address constant T1 = address(0xFEE1);
    address constant T2 = address(0xFEE2);

    uint256 constant LEG_FLOOR_BPS = BPC.LEG_FLOOR_BPS; // 8_000
    uint256 constant BPS           = BPC.BPS;           // 10_000

    bool zfo;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        solver = new BlazePhoenixSolver(address(hub));
        router = new BlazePhoenixRouter(
            address(hub), address(solver), address(this), T1, T2);
        hub.setRoles(address(router), address(solver), address(this));

        tokA = new MockERC20("A", "A");
        tokB = new MockERC20("B", "B");

        honest = new MockV2Pair(address(tokA), address(tokB));
        tokA.mint(address(honest), 1_000_000e18);
        tokB.mint(address(honest), 1_000_000e18);
        honest.setReserves(1_000_000e18, 1_000_000e18);
        hub.seedPool(address(honest), BPC.KIND_V2, 30, address(0), address(tokA), address(tokB));

        // Reserves chosen so that a 2-wei input prices to exactly ONE wei out:
        // outV2(2, r, r, 30) == 1 for equal, deep-enough reserves.
        hostile = new QuotesOneDeliversNothing(address(tokA), address(tokB));
        tokB.mint(address(hostile), 1_000e18);
        hostile.setReserves(1_000e18, 1_000e18);
        hub.seedPool(address(hostile), BPC.KIND_V2, 30, address(0), address(tokA), address(tokB));

        zfo = honest.token0() == address(tokA);

        tokA.mint(user, 1_000_000e18);
        vm.prank(user);
        tokA.approve(address(router), type(uint256).max);
    }

    // ─── the arithmetic, stated plainly ──────────────────────────────────────

    function test_Arithmetic_LegFloorThresholdCollapsesAtOne() public pure {
        assertEq(BPC.mulDiv(1, LEG_FLOOR_BPS, BPS), 0,
            "a one-wei bound demands ZERO delivery: the guard cannot fire");
        assertEq(BPC.mulDivUp(1, LEG_FLOOR_BPS, BPS), 1,
            "rounding up demands one wei, so the guard fires");
        // The window is exactly bound == 1; from two upward the floor works.
        assertEq(BPC.mulDiv(2, LEG_FLOOR_BPS, BPS), 1);
    }

    /// R-C applies to the Hub's admission hysteresis too, and there the
    /// collapse was NOT merely theoretical: `worstPsi + worstPsi/4` is the
    /// documented "strict 25% margin", and integer division erases it entirely
    /// for worstPsi <= 3 — precisely the dust-vitality regime the hysteresis
    /// exists to damp. This pins the arithmetic so the margin cannot silently
    /// vanish again.
    function test_Arithmetic_AdmissionMarginSurvivesSmallPsi() public pure {
        for (uint256 psi = 1; psi <= 3; ++psi) {
            assertEq(psi / 4, 0, "the old expression gave no margin at all here");
            assertGe(BPC.mulDivUp(psi, 2_500, BPS), 1, "a non-zero psi must demand a non-zero margin");
        }
        // And it still means 25% where 25% is representable.
        assertEq(BPC.mulDivUp(100, 2_500, BPS), 25);
        assertEq(BPC.mulDivUp(4, 2_500, BPS), 1);
    }

    // ─── the guard that actually holds the line ─────────────────────────────

    function test_LegDeliveringNothing_IsRefusedBeforeTheFloorMatters() public {
        uint256 bulk = 10_000e18;
        uint256 dust = 2; // prices to exactly 1 wei out -> bound == 1

        Leg[] memory legs = new Leg[](2);
        legs[0] = Leg({
            pool: address(honest), hooks: address(0), kind: BPC.KIND_V2, fee: 30,
            tickSpacing: 0, zeroForOne: zfo, stable: false,
            amountIn: bulk, expectedOut: 0, auxId: bytes32(0)
        });
        legs[1] = Leg({
            pool: address(hostile), hooks: address(0), kind: BPC.KIND_V2, fee: 30,
            tickSpacing: 0, zeroForOne: zfo, stable: false,
            amountIn: dust, expectedOut: 0, auxId: bytes32(0)
        });

        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({
            tokenIn: address(tokA), tokenOut: address(tokB),
            amountIn: bulk + dust, expectedOut: 0, legs: legs
        });
        Route memory r = Route({
            hops: hops, totalOut: 0, singleOut: 0, singleOutFloor: 0,
            expectedImpactBps: 0, confidenceWad: 0, estGas: 0,
            hasSurplus: false, isV4Bundle: false
        });

        // RouterE(8), not RouterE(5): the executor refuses to ask for a zero
        // output before the pool is touched, so the per-leg floor's collapsed
        // threshold never gets the chance to wave anything through. This is
        // the assertion that must not regress.
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, 8));
        router.swapExactIn(r, bulk + dust, 1, user, block.timestamp + 1);
    }
}
