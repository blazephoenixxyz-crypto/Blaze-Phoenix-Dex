// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  The Solidly fallback trigger, aligned on both channels.
//
//  An answer of `<= 1` from a pair's `getAmountOut` means "no answer" for BOTH
//  the executor (`Core.solidlyAskOut`: `if (out > 1)` is an answer) and the
//  in-frame quote (`Router._solidlyLegQuote`: `if (quote <= 1)` falls back to
//  the replicated curve). A pool may answer anything, so the trigger is driven
//  here by a pair that answers a configured figure:
//    · honest pair: the known relation, realized == quoted - 1 (the ask margin);
//    · answer 1: both channels fall back to the curve. The quote carries no
//      haircut and the executor asks 200 bps below the curve, so the quote
//      sits above the delivery - and is never the answer itself;
//    · answer 2: the quote takes it as an answer and the executor asks 1; the
//      per-leg floor refuses the swap (RouterE(5)), with or without the
//      caller's minimal attestation.
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockSolidlyPair} from "./mocks/MockSolidlyPair.sol";

/// @dev A Solidly pair whose `getAmountOut` returns a configured figure instead
///      of the curve. It has no `factory()`, so the leg's configured fee (30 bps)
///      prices the replicated curve and the fallback is deterministic.
contract AnsweringSolidlyPair is MockSolidlyPair {
    uint256 public answer;
    bool public answering;

    constructor(address t0, address t1, bool st) MockSolidlyPair(t0, t1, st) {}

    function setAnswer(uint256 v) external { answer = v; answering = true; }

    function getAmountOut(uint256 amountIn, address tokenIn)
        public view override returns (uint256)
    {
        if (answering) return answer;
        return super.getAmountOut(amountIn, tokenIn);
    }
}

contract SolidlyQuoteFallbackTriggerTest is Test {
    bytes32 constant TOPIC = keccak256(
        "ExecutionProof(address,address,uint256,uint256,uint256,uint256)"
    );

    uint112 constant RESERVE = 1_000_000e18;
    uint256 constant AMT     = 1_000e18;
    address constant USER    = address(0xA11CE);

    BlazePhoenixHub internal hub;
    BlazePhoenixRouter internal router;
    MockERC20 internal tIn;
    MockERC20 internal tOut;
    AnsweringSolidlyPair internal pair;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        BlazePhoenixSolver solver = new BlazePhoenixSolver(address(hub));
        router = new BlazePhoenixRouter(
            address(hub), address(solver), address(this), address(0xFEE1), address(0xFEE2)
        );
        hub.setRoles(address(router), address(solver), address(this));

        tIn  = new MockERC20("IN", "IN");
        tOut = new MockERC20("OUT", "OUT");   // not a bridge: no output-side fee
        pair = new AnsweringSolidlyPair(address(tIn), address(tOut), false);
        tIn.mint(address(pair), RESERVE);
        tOut.mint(address(pair), RESERVE);
        pair.setReserves(RESERVE, RESERVE);
        hub.seedPool(address(pair), BPC.KIND_SOLIDLY, 30, address(0), address(tIn), address(tOut));

        tIn.mint(USER, 100 * AMT);
        vm.prank(USER);
        tIn.approve(address(router), type(uint256).max);
    }

    /// @dev Hand-built route, one Solidly leg, no caller attestation
    ///      (`expectedOut == 0`): the quote channel is the in-frame figure.
    function _route(uint256 attest) private view returns (Route memory r) {
        Leg[] memory legs = new Leg[](1);
        legs[0] = Leg({
            pool: address(pair), hooks: address(0), kind: BPC.KIND_SOLIDLY, fee: 30,
            tickSpacing: 0, zeroForOne: address(tIn) < address(tOut), stable: false,
            amountIn: AMT, expectedOut: attest, auxId: bytes32(0)
        });
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({
            tokenIn: address(tIn), tokenOut: address(tOut),
            amountIn: AMT, expectedOut: attest, legs: legs
        });
        r = Route({
            hops: hops, totalOut: 0, singleOut: 0, singleOutFloor: 0,
            expectedImpactBps: 0, confidenceWad: 0, estGas: 0,
            hasSurplus: false, isV4Bundle: false
        });
    }

    function _run() private returns (uint256 quoted, uint256 realized) {
        Route memory r = _route(0);
        uint256 before = tOut.balanceOf(USER);
        vm.recordLogs();
        vm.prank(USER);
        router.swapExactIn(r, AMT, 1, USER, block.timestamp + 1);
        realized = tOut.balanceOf(USER) - before;

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool seen;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == TOPIC) {
                (quoted, , , ) = abi.decode(logs[i].data, (uint256, uint256, uint256, uint256));
                seen = true;
            }
        }
        assertTrue(seen, "setup: the Router emits ExecutionProof");
    }

    /// @notice Honest pair: the quote is a real figure and the delivery is
    ///         that figure less the one-wei ask margin.
    function test_HonestPairKeepsTheAskMarginRelation() public {
        (uint256 q, uint256 r) = _run();
        assertGt(q, 1, "setup: the honest quote is a real figure");
        assertEq(r + 1, q, "the delivery is the quoted figure less the one-wei ask margin");
    }

    /// @notice An answer of 1 is "no answer" on both channels: both fall back
    ///         to the replicated curve.
    function test_PairAnsweringOneFallsBackOnBothChannels() public {
        pair.setAnswer(1);
        (uint256 q, uint256 r) = _run();
        assertGt(r, 1, "the executor falls back to the curve");
        assertTrue(q != 1, "the quote channel must not take 1 as an answer");
        assertGt(q, r, "with no answer, the quote (no haircut) sits above the delivery (200 bps below the curve)");
    }

    /// @notice An answer of 2 with no attestation: refused by the per-leg floor.
    function test_PairAnsweringTwoWithoutAttestationIsRefusedByTheFloor() public {
        pair.setAnswer(2);
        Route memory r = _route(0);
        vm.prank(USER);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, uint16(5)));
        router.swapExactIn(r, AMT, 1, USER, block.timestamp + 1);
    }

    /// @notice An answer of 2 under the caller's minimal attestation: refused
    ///         the same way.
    function test_PairAnsweringTwoWithAttestationIsRefusedByTheFloor() public {
        pair.setAnswer(2);
        Route memory r = _route(1);
        vm.prank(USER);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, uint16(5)));
        router.swapExactIn(r, AMT, 1, USER, block.timestamp + 1);
    }
}
