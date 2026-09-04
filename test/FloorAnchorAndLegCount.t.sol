// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";

/// @notice FLOOR-01 — one of two ways the caller could relax a floor the code promised
///         they could not, both found by a census of quantities with two producers rather than
///         by hand, and both measured before they were fixed.
///
///         `Router._execute` writes, eleven lines above the floor it computes: "The caller's
///         singleOutFloor and userMinOut may TIGHTEN the floor ... but can never RELAX the
///         protocol floor", and calls the anchor "unforgeable by calldata". Both sentences were
///         false, and the shape is this repository's standing law: a DECLARED count decided the
///         floor while the MEASURED count sat unread three hundred lines above.
///
///         Measured against the pre-fix code:
///           FLOOR-01  a trailing hop declaring amountIn = 0 -> quoted 0, floorUsed 0. The whole
///                     protocol floor gone, the swap settling normally, only userMinOut left.
///           FLOOR-02  four padded legs -> the floor fell 9501 -> 8702 bps of the quote, exactly
///                     4 x FLOOR_PER_LEG_BPS. At the structural maximum of MAX_HOPS x
///                     MAX_LEGS_PER_HOP = 15 legs it reaches the 8000 hard clamp: 96% -> 80%.
contract FloorAnchorAndLegCountTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixRouter router;
    MockERC20 tIn;
    MockERC20 tOut;
    MockV2Pair pair;
    address user = address(0xBEEF);

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        tIn = new MockERC20("In", "IN");
        tOut = new MockERC20("Out", "OUT");
        pair = new MockV2Pair(address(tIn), address(tOut));
        router = new BlazePhoenixRouter(
            address(hub), address(0xBEEF), address(this), address(0xFEE1), address(0xFEE2));
        tIn.mint(address(pair), 10_000e18);
        tOut.mint(address(pair), 10_000e18);
        pair.setReserves(10_000e18, 10_000e18);
        tIn.mint(user, 10_000e18);
        vm.prank(user);
        tIn.approve(address(router), type(uint256).max);
    }

    function _leg(uint256 amountIn) private view returns (Leg memory) {
        return Leg({pool: address(pair), hooks: address(0), kind: BPC.KIND_V2, fee: 30,
                    tickSpacing: 0, zeroForOne: address(tIn) < address(tOut), stable: false,
                    amountIn: amountIn, expectedOut: 0, auxId: bytes32(0)});
    }

    function _route(uint256 amountIn, uint256 pads) private view returns (Route memory r) {
        Leg[] memory legs = new Leg[](1 + pads);
        legs[0] = _leg(amountIn);
        // Same pair, same direction, ZERO input: satisfies the leg/hop token equality gate and
        // is returned from before any pool is touched, so it executes nothing at all.
        for (uint256 i; i < pads; ++i) legs[1 + i] = _leg(0);
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({tokenIn: address(tIn), tokenOut: address(tOut),
                       amountIn: amountIn, expectedOut: 0, legs: legs});
        r = Route({hops: hops, totalOut: 0, singleOut: 0, singleOutFloor: 0,
                   expectedImpactBps: 0, confidenceWad: 0, estGas: 0,
                   hasSurplus: false, isV4Bundle: false});
    }

    /// @dev The floor as a rate of the quote, read from the ExecutionProof the swap emits.
    ///      Rates, not absolutes: each swap moves the pool, so two runs never quote the same.
    function _floorBpsOfQuote(Route memory r, uint256 amountIn) private returns (uint256) {
        vm.recordLogs();
        vm.prank(user);
        router.swapExactIn(r, amountIn, 1, user, block.timestamp + 1);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("ExecutionProof(address,address,uint256,uint256,uint256,uint256)");
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == sig) {
                (uint256 q, , uint256 f, ) =
                    abi.decode(logs[i].data, (uint256, uint256, uint256, uint256));
                assertGt(q, 0, "premise: the swap must produce a real in-frame quote");
                return (f * 10_000) / q;
            }
        }
        revert("no ExecutionProof emitted");
    }

    /// @notice FLOOR-01. A trailing hop that moves nothing must not become the floor's anchor.
    ///         Both producers of `finalHopQuote` return zero for such a hop, and a floor of
    ///         `mulDivUp(0, ...)` is no floor at all.
    function test_TrailingHopThatMovesNothingCannotZeroTheProtocolFloor() public {
        uint256 amt = 100e18;
        uint256 clean = _floorBpsOfQuote(_route(amt, 0), amt);
        assertGt(clean, 9_000, "premise: the honest one-hop route carries a real floor");

        Leg[] memory l0 = new Leg[](1);
        l0[0] = _leg(amt);
        // A concentrated-single leg: `_legTokens` returns early for that family, so the token
        // gate is satisfied by auxId alone and no pool has to exist for the hop to be accepted.
        Leg[] memory l1 = new Leg[](1);
        l1[0] = Leg({pool: address(uint160(uint256(keccak256("nowhere")))), hooks: address(0),
                     kind: 4, fee: 500, tickSpacing: 10,
                     zeroForOne: address(tIn) < address(tOut), stable: false,
                     amountIn: 0, expectedOut: 0,
                     auxId: bytes32(uint256(uint160(address(tOut))))});
        Hop[] memory hops = new Hop[](2);
        hops[0] = Hop({tokenIn: address(tIn), tokenOut: address(tOut),
                       amountIn: amt, expectedOut: 0, legs: l0});
        hops[1] = Hop({tokenIn: address(tOut), tokenOut: address(tOut),
                       amountIn: 0, expectedOut: 0, legs: l1});
        Route memory r = Route({hops: hops, totalOut: 0, singleOut: 0, singleOutFloor: 0,
                                expectedImpactBps: 0, confidenceWad: 0, estGas: 0,
                                hasSurplus: false, isV4Bundle: false});

        uint256 withParasite = _floorBpsOfQuote(r, amt);
        emit log_named_uint("floor bps of quote, honest route ", clean);
        emit log_named_uint("floor bps of quote, + no-op hop  ", withParasite);
        assertGt(withParasite, 9_000,
            "TRAILING NO-OP HOP: the protocol floor must survive a hop that moved nothing");
    }
}
