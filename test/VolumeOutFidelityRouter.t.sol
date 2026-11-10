// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// THE PUBLISHED VOLUME OUT IS WHAT LEFT THE POOL.
//
// `test/VolumeEventFidelity.t.sol` pins the FIRST field of `Volume(key, amtIn, amtOut)` to the
// pool's measured input delta. This pins the third. The Router produces it as
//
//     uint256 outM = legOut[legIdx - 1];
//
// the leg's measured delivery (the Router's balance delta that `_execScaled` reads), and hands
// it to `hub.recordSwap(..., inM, outM, depth)`.
//
// EXACT SINCE 2026-11-10 (3958, 4028). Until then the Router published
// `mulDiv(leg.expectedOut, sc, 1e18)`, the plan's quote scaled by the fee ratio, and this test
// held it to the pool's delta within 1e-4 relative, because a pre-execution quote scaled
// linearly agrees with the curve only to second order. A measurement needs no tolerance: on
// an untaxed output token the published figure is the pool's delta to the wei. The caller's
// over-attestation, which the tolerance could not see on an honest route, is pinned in
// `test/ClockAnchorMeasuredDelivery.t.sol`.
//
// NOT VACUOUS: the log is asserted FOUND, the measured delta is asserted non-zero, and the
// reference is a before/after balance delta on the pool rather than a literal.

import {Test, Vm} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixQuoter} from "../src/BlazePhoenixQuoter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";
import {Origin} from "./mocks/MockOriginFactory.sol";

contract VolumeOutFidelityRouterTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    BlazePhoenixQuoter quoter;
    BlazePhoenixRouter router;
    MockERC20 tA;
    MockERC20 tB;
    MockV2Pair ab;

    address user = address(0x5E4);
    uint256 constant AMOUNT_IN = 1_000e18;
    uint256 constant RESERVE   = 1_000_000e18;

    bytes32 constant VOLUME_SIG = keccak256("Volume(bytes32,uint256,uint256)");

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0xBEEF));
        solver = new BlazePhoenixSolver(address(hub), address(0));
        quoter = new BlazePhoenixQuoter(address(hub), address(solver));
        router = new BlazePhoenixRouter(
            address(hub), address(solver), address(this), address(0x7451), address(0x7452)
        );

        tA = new MockERC20("A", "A");
        tB = new MockERC20("B", "B");
        ab = new MockV2Pair(address(tA), address(tB));
        // rizki-3107: the swap door seats only a pool a wired factory derives.
        Origin.wire(hub, address(ab), address(tA), address(tB), BPC.KIND_V2, 30);
        tA.mint(address(ab), RESERVE);
        tB.mint(address(ab), RESERVE);
        ab.setReserves(uint112(RESERVE), uint112(RESERVE));

        hub.setRoles(address(this), address(solver), address(quoter));
        for (uint256 i; i < 5; i++) {
            hub.recordSwap(address(ab), BPC.KIND_V2, 30, address(0),
                address(tA), address(tB), 1e18, 1e18, RESERVE);
        }
        hub.setRoles(address(router), address(solver), address(quoter));

        tA.mint(user, 10_000e18);
        vm.prank(user);
        tA.approve(address(router), type(uint256).max);
    }

    function _oneHopRoute() private view returns (Route memory route) {
        uint256 gross = BPC.outV2(AMOUNT_IN, RESERVE, RESERVE, 30);
        Leg[] memory legs = new Leg[](1);
        legs[0] = Leg({
            pool: address(ab), hooks: address(0), kind: BPC.KIND_V2, fee: 30,
            tickSpacing: 0, zeroForOne: address(tA) < address(tB), stable: false,
            amountIn: AMOUNT_IN, expectedOut: gross, auxId: bytes32(0)
        });
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({tokenIn: address(tA), tokenOut: address(tB),
                       amountIn: AMOUNT_IN, expectedOut: gross, legs: legs});
        route = Route({hops: hops, totalOut: gross, singleOut: gross, singleOutFloor: 0,
                       expectedImpactBps: 0, confidenceWad: 0, estGas: 0,
                       hasSurplus: false, isV4Bundle: false});
    }

    function _volumeFromLogs(Vm.Log[] memory logs)
        private view returns (bool found, uint256 amtIn, uint256 amtOut)
    {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(hub)
                && logs[i].topics.length > 0
                && logs[i].topics[0] == VOLUME_SIG) {
                (amtIn, amtOut) = abi.decode(logs[i].data, (uint256, uint256));
                return (true, amtIn, amtOut);
            }
        }
    }

    /// The `amtOut` the Hub publishes tracks how much actually left the pool, as `amtIn`
    /// tracks what entered it.
    function test_VolumeOutTracksTheMeasuredPoolDelta() public {
        Route memory route = _oneHopRoute();
        uint256 poolOutBefore = tB.balanceOf(address(ab));

        vm.recordLogs();
        vm.prank(user);
        uint256 delivered = router.swapExactIn(route, AMOUNT_IN, 1, user, block.timestamp + 1);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertGt(delivered, 0, "precondition: the swap must actually execute");
        uint256 measuredOut = poolOutBefore - tB.balanceOf(address(ab));
        assertGt(measuredOut, 0, "precondition: the pool must have paid the output");

        (bool found, , uint256 amtOut) = _volumeFromLogs(logs);
        assertTrue(found, "precondition: a Volume event must have been emitted");

        emit log_named_decimal_uint("Volume.amtOut (published)", amtOut, 18);
        emit log_named_decimal_uint("pool delta    (measured) ", measuredOut, 18);

        assertEq(amtOut, measuredOut,
            "the published volume out is not the measured out delta");
    }
}
