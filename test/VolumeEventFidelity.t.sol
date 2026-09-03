// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// THE VOLUME THE CHAIN RECORDS IS THE NUMBER THE CALLER WROTE, NOT THE NUMBER THAT MOVED.
//
// `Hub.recordSwap` emits `Volume(key, amtIn, amtOut)` (Hub:1563 and Hub:1739). The Router
// supplies those two numbers at `Router:2032-2034`:
//
//     try hub.recordSwap(leg.pool, leg.kind, leg.fee, leg.hooks,
//                        t0, t1, leg.amountIn, leg.expectedOut, depth) {} catch {}
//
// `leg.amountIn` and `leg.expectedOut` are CALLDATA fields of the Route. Nothing measures them.
// The docstring at `Router:1938-1946` shows the class was already met once: a one-wei phantom
// declaration used to bump the registry for a leg that never moved a token (reported by Thomas).
// That fix corrected WHICH legs are credited -- `executedMask` -- and left HOW MUCH untouched.
// This is the other half of the same channel, reported independently by mohaseenbasha (VOL_01).
//
// No adversary is required. On hop 0 the protocol fee is taken out of the input BEFORE the leg
// executes (`Router:1112` -> `_chargeHopFee` returns `amountIn - feeH`), so the pool receives
// strictly less than `leg.amountIn` on EVERY honest swap. The published volume overstates the
// real flow by the fee, permanently, for every pool in the registry.
//
// INV-F4: the emitted Volume equals the measured balance delta.
// RED at 6334df6.

import {Test, Vm} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixQuoter} from "../src/BlazePhoenixQuoter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";

contract VolumeEventFidelityTest is Test {
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

    // The event is identified by its SIGNATURE, re-derived here from the declaration in
    // `BlazePhoenixHub.sol`. It is not imported from the contract under test: an event whose
    // parameter list changed would then silently stop matching and the test would report
    // "no Volume emitted" instead of quietly comparing the wrong fields.
    bytes32 constant VOLUME_SIG = keccak256("Volume(bytes32,uint256,uint256)");

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0xBEEF));
        solver = new BlazePhoenixSolver(address(hub));
        quoter = new BlazePhoenixQuoter(address(hub), address(solver));
        router = new BlazePhoenixRouter(
            address(hub), address(solver), address(this), address(0x7451), address(0x7452)
        );

        tA = new MockERC20("A", "A");
        tB = new MockERC20("B", "B");
        ab = new MockV2Pair(address(tA), address(tB));
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

    /// @dev Built before any cheatcode is armed: the mocks are read for token ordering here,
    ///      and a `prank` armed earlier would be spent on that staticcall.
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

    // =========================================================================
    //  INV-F4 — the record equals the measurement.
    // =========================================================================

    /// CLAIM: the `Volume` the Hub publishes for a pool is how much actually moved through that
    /// pool. It is the protocol's own answer to "how much went through here", it is the only
    /// public record of flow, and `Hub:1563` publishes it with no measurement behind it.
    ///
    /// RED at 6334df6: the emitted `amtIn` is `leg.amountIn` -- the pre-fee figure the caller
    /// declared -- while the pool's tA balance grows by the post-fee amount. The gap is the
    /// protocol fee, on an entirely honest swap.
    ///
    /// NOT VACUOUS, and each premise is asserted rather than assumed:
    ///   * the log is asserted to have been FOUND, so a renamed or unemitted event fails loudly
    ///     instead of comparing two zeros;
    ///   * the measured delta is asserted non-zero, so a swap that did not execute cannot pass;
    ///   * the comparison is a MEASURED before/after delta on the pool, never a literal, so a
    ///     future change to the fee or to the scaling keeps the test honest without editing it.
    function test_INV_F4_VolumeInEqualsTheMeasuredPoolDelta() public {
        Route memory route = _oneHopRoute();
        uint256 poolBefore = tA.balanceOf(address(ab));

        vm.recordLogs();
        vm.prank(user);
        uint256 delivered = router.swapExactIn(route, AMOUNT_IN, 1, user, block.timestamp + 1);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertGt(delivered, 0, "precondition: the swap must actually execute");
        uint256 measuredIn = tA.balanceOf(address(ab)) - poolBefore;
        assertGt(measuredIn, 0, "precondition: the pool must have received the input");

        (bool found, uint256 amtIn, ) = _volumeFromLogs(logs);
        assertTrue(found, "precondition: a Volume event must have been emitted");

        emit log_named_decimal_uint("Volume.amtIn (published)", amtIn, 18);
        emit log_named_decimal_uint("pool delta   (measured) ", measuredIn, 18);
        assertEq(amtIn, measuredIn,
            "INV-F4: the published volume is the caller's declaration, not the measured flow");
    }

    /// @dev The same defect stated as a RATIO, so the failure message carries the size of the
    ///      lie and not only its existence. The overstatement is exactly the protocol fee, which
    ///      is why this is not a rounding argument: 28 bps of every swap, on every pool, for ever.
    function test_INV_F4_TheOverstatementIsExactlyTheProtocolFee() public {
        Route memory route = _oneHopRoute();
        uint256 poolBefore = tA.balanceOf(address(ab));

        vm.recordLogs();
        vm.prank(user);
        router.swapExactIn(route, AMOUNT_IN, 1, user, block.timestamp + 1);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 measuredIn = tA.balanceOf(address(ab)) - poolBefore;
        (bool found, uint256 amtIn, ) = _volumeFromLogs(logs);
        assertTrue(found, "precondition: a Volume event must have been emitted");
        assertGe(amtIn, measuredIn, "precondition: the direction of the gap is an overstatement");

        uint256 gapBps = ((amtIn - measuredIn) * 10_000) / measuredIn;
        emit log_named_uint("overstatement in bps", gapBps);
        assertEq(gapBps, 0, "INV-F4: the published volume overstates the real flow by the fee");
    }
}
