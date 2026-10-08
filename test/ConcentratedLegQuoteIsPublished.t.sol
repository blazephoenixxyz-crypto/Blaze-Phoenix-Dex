// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  The Router's concentrated-leg quote: what ExecutionProof publishes for a live
//  V3 leg with no caller attestation.
//
//      if (legAmt != 0 && sp != 0 && lq != 0) {   (Router, in-frame quote loop)
//
//  selects the LIVE concentrated quote over the conservative default-impact arm.
//  Execution does not depend on it - the pool delivers either way - but the
//  published quote and the protocol floor do. With the caller's attestation set,
//  the coverage gate makes ExecutionProof.quoted non-zero even when the quote arm
//  is skipped, so this pins the state where only the frame's own measurement can
//  supply it: a live V3 leg, unattested. Each arm of the condition, inverted, sends
//  the leg to the default arm and the published quote to 0.
//
//  The two other rewrites of the condition (`||` for `&&`) only diverge where
//  Core.outV3's own first guard returns 0 anyway - the same value the default arm
//  produces - so they are equivalent and not pinned.
//
//  forge test --match-path test/ConcentratedLegQuoteIsPublished.t.sol -vv
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV3Pool} from "./mocks/MockV3Pool.sol";

contract ConcentratedLegQuoteIsPublishedTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixRouter router;
    MockERC20 tokenIn;
    MockERC20 tokenOut;
    MockV3Pool v3pool;

    address treasury1 = address(0xFEE1);
    address treasury2 = address(0xFEE2);
    address user = address(0xBEEF);

    uint24 constant FEE = 3000;
    uint160 constant SQRT_P = uint160(BPC.Q96);
    uint128 constant LIQ = 1_000_000e18;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        tokenIn = new MockERC20("In", "IN");
        tokenOut = new MockERC20("Out", "OUT");

        router = new BlazePhoenixRouter(
            address(hub), address(0xBEEF), address(this), treasury1, treasury2
        );

        v3pool = new MockV3Pool(address(tokenIn), address(tokenOut), FEE);
        v3pool.setState(SQRT_P, LIQ);
        tokenOut.mint(address(v3pool), 1_000_000e18);

        tokenIn.mint(user, 3_000e18);
        vm.prank(user);
        tokenIn.approve(address(router), type(uint256).max);
    }

    function _execProof() private returns (uint256 quoted) {
        bytes32 sig = keccak256("ExecutionProof(address,address,uint256,uint256,uint256,uint256)");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] != sig) continue;
            found = true;
            (quoted, , , ) = abi.decode(logs[i].data, (uint256, uint256, uint256, uint256));
        }
        require(found, "ExecutionProof missing");
    }

    /// @dev Single KIND_V3 leg, LIVE pool, and — the point — NO caller
    ///      attestation (expectedOut == 0 on both the leg and the hop).
    function _swapLiveLeg(uint256 amountIn, uint256 userMinOut)
        private returns (uint256 quoted, uint256 delivered)
    {
        bool zfo = address(tokenIn) < address(tokenOut);

        Leg[] memory legs = new Leg[](1);
        legs[0] = Leg({
            pool: address(v3pool), hooks: address(0), kind: BPC.KIND_V3, fee: FEE,
            tickSpacing: 60, zeroForOne: zfo, stable: false,
            amountIn: amountIn, expectedOut: 0, auxId: bytes32(0)
        });
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({
            tokenIn: address(tokenIn), tokenOut: address(tokenOut),
            amountIn: amountIn, expectedOut: 0, legs: legs
        });
        Route memory route = Route({
            hops: hops, totalOut: 0, singleOut: 0, singleOutFloor: 0,
            expectedImpactBps: 0, confidenceWad: 0, estGas: 0,
            hasSurplus: false, isV4Bundle: false
        });

        vm.recordLogs();
        vm.prank(user);
        delivered = router.swapExactIn(route, amountIn, userMinOut, user, block.timestamp + 1);
        quoted = _execProof();
    }

    /// @dev The in-frame figure the Router must publish for this leg: outV3 on
    ///      the amount actually spent (the input side is charged hop 0's
    ///      protocol fee first, Router:673 / :1151).
    function _liveQuote(uint256 amountIn) private view returns (uint256) {
        bool zfo = address(tokenIn) < address(tokenOut);
        uint256 netIn = amountIn - BPC.mulDivUp(amountIn, BPC.PROTOCOL_FEE_BPS, BPC.BPS);
        return BPC.outV3(netIn, SQRT_P, LIQ, FEE, zfo, 0);
    }

    /// kills: 766/767/768 — the published quote is the frame's measurement of
    /// the LIVE concentrated leg, not a caller attestation and not the else-arm.
    function test_PublishedQuoteIsTheLiveConcentratedLegFigure() public {
        uint256 amountIn = 1_000e18;
        uint256 realQuote = _liveQuote(amountIn);
        assertGt(realQuote, 0, "sanity: a live concentrated leg must be quotable");

        (uint256 quoted, uint256 delivered) = _swapLiveLeg(amountIn, 1);

        assertEq(quoted, realQuote,
            "ExecutionProof.quoted must be the live V3 leg quote, not 0 (else-arm)");
        assertEq(delivered, realQuote,
            "a MockV3Pool quotes and settles with the same outV3 formula: quote == delivered");
    }

    /// @dev Second read of the same state through the aggregate floor: with no
    ///      attestation the protocol floor is built on the measured quote, so a
    ///      leg sent to the else-arm zeroes protocolFloorOut too. Kept separate
    ///      so a probe that only watches the quote still fails loud here.
    function test_FloorIsAnchoredOnTheMeasuredQuote() public {
        uint256 amountIn = 500e18;
        uint256 realQuote = _liveQuote(amountIn);
        assertGt(realQuote, 0);

        // Pull the floor out of the same ExecutionProof (5th word).
        bool zfo = address(tokenIn) < address(tokenOut);
        Leg[] memory legs = new Leg[](1);
        legs[0] = Leg({
            pool: address(v3pool), hooks: address(0), kind: BPC.KIND_V3, fee: FEE,
            tickSpacing: 60, zeroForOne: zfo, stable: false,
            amountIn: amountIn, expectedOut: 0, auxId: bytes32(0)
        });
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({
            tokenIn: address(tokenIn), tokenOut: address(tokenOut),
            amountIn: amountIn, expectedOut: 0, legs: legs
        });
        Route memory route = Route({
            hops: hops, totalOut: 0, singleOut: 0, singleOutFloor: 0,
            expectedImpactBps: 0, confidenceWad: 0, estGas: 0,
            hasSurplus: false, isV4Bundle: false
        });

        vm.recordLogs();
        vm.prank(user);
        router.swapExactIn(route, amountIn, 1, user, block.timestamp + 1);

        bytes32 sig = keccak256("ExecutionProof(address,address,uint256,uint256,uint256,uint256)");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 floorOut;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] != sig) continue;
            (, , floorOut, ) = abi.decode(logs[i].data, (uint256, uint256, uint256, uint256));
        }
        assertGt(floorOut, 0, "protocolFloorOut must anchor on the measured quote, not 0");
        assertLe(floorOut, realQuote, "the floor can never exceed the measured quote");
    }
}
