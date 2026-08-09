// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// What does the SECURITY ARCHITECTURE cost, in gas, per swap?
//
// The Router's whole value proposition is that it does not trust the route it is handed: it
// re-derives the output floor and the protocol-fee base from what actually executed, bounds each
// pool's pull to the leg budget, guards reentrancy, and feeds the registry. All of that is work
// a naive "just call the pool" swap does not do.
//
// This measures the price tag directly: the SAME economic trade, executed two ways.
//   Arm A — through the Router (all guarantees on).
//   Arm B — raw: transfer into the pair and call swap() yourself (zero guarantees).
// The delta is what safety costs, and it is the honest number to quote to a user asking
// "why is this dearer than swapping on the pool directly?".
//
// forge test --match-contract SecurityArchitectureGas -vv

import {Test, console2} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";

contract SecurityArchitectureGasTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixRouter router;
    MockERC20 tokenIn;
    MockERC20 tokenOut;
    MockV2Pair pair;
    address user = address(0xBEEF);

    uint256 constant R = 1_000_000e18;
    uint256 constant AMT = 1_000e18;

    function setUp() public {
        hub = new BlazePhoenixHub();
        hub.initialize(address(this), address(0));
        BlazePhoenixSolver solver = new BlazePhoenixSolver(address(hub));
        router = new BlazePhoenixRouter(
            address(hub), address(solver), address(this), address(0xFEE1), address(0xFEE2));
        hub.setRoles(address(router), address(solver), address(this));

        tokenIn = new MockERC20("IN", "IN");
        tokenOut = new MockERC20("OUT", "OUT");
        pair = new MockV2Pair(address(tokenIn), address(tokenOut));
        tokenIn.mint(address(pair), R);
        tokenOut.mint(address(pair), R);
        pair.setReserves(uint112(R), uint112(R));

        tokenIn.mint(user, 1_000_000e18);
        vm.prank(user);
        tokenIn.approve(address(router), type(uint256).max);
    }

    function _route() internal view returns (Route memory r) {
        uint256 quoted = BPC.outV2(AMT, R, R, 30);
        Leg[] memory legs = new Leg[](1);
        legs[0] = Leg({
            pool: address(pair), hooks: address(0), kind: BPC.KIND_V2, fee: 30, tickSpacing: 0,
            zeroForOne: address(tokenIn) == pair.token0(), stable: false,
            amountIn: AMT, expectedOut: quoted, auxId: bytes32(0)
        });
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({
            tokenIn: address(tokenIn), tokenOut: address(tokenOut),
            amountIn: AMT, expectedOut: quoted, legs: legs
        });
        r = Route({
            hops: hops, totalOut: quoted, singleOut: quoted, singleOutFloor: 0,
            expectedImpactBps: 0, confidenceWad: 0, estGas: 0, hasSurplus: false, isV4Bundle: false
        });
    }

    function test_SecurityOverhead_RouterVsRawPoolSwap() public {
        Route memory r = _route();
        uint256 quoted = BPC.outV2(AMT, R, R, 30);
        bool zfo = address(tokenIn) == pair.token0();
        uint256 dl = block.timestamp + 1;

        // Warm up first: the very first swap on a pair also pays cold registry SSTOREs to
        // register the pool, which is a one-off amortised across every later trade. Comparing
        // that against a raw call would overstate the standing overhead.
        vm.prank(user);
        router.swapExactIn(r, AMT, 0, user, dl);

        // ── Arm A: through the Router, every guarantee active, steady state ──
        uint256 snap = vm.snapshotState();
        vm.prank(user);
        uint256 g0 = gasleft();
        router.swapExactIn(r, AMT, 0, user, dl);
        uint256 gRouter = g0 - gasleft();
        vm.revertToState(snap);

        // ── Arm B: raw. Push tokens into the pair and call swap() directly. No floor, no fee
        //    base re-derivation, no per-leg bound, no reentrancy guard, no registry feedback.
        vm.startPrank(user);
        uint256 g1 = gasleft();
        tokenIn.transfer(address(pair), AMT);
        pair.swap(zfo ? 0 : quoted, zfo ? quoted : 0, user, "");
        uint256 gRaw = g1 - gasleft();
        vm.stopPrank();

        console2.log("=== what the security architecture costs, one V2 leg ===");
        console2.log("Router (all guarantees), gas:", gRouter);
        console2.log("raw pool swap (none),    gas:", gRaw);
        assertGt(gRouter, gRaw, "the Router necessarily costs more than a raw pool call");
        uint256 overhead = gRouter - gRaw;
        console2.log("security + accounting overhead, gas:", overhead);
        console2.log("   as a multiple of the raw swap, x100:", (gRouter * 100) / gRaw);

        // Registry feedback is the one component already isolated (see LifecycleMetrics):
        // subtracting it leaves the pure verification cost.
        console2.log("");
        console2.log("of which, previously isolated:");
        console2.log("   registry feedback (recordSwap), ~gas/leg:", uint256(3889));
        if (overhead > 3889) {
            console2.log("   => remaining verification cost, ~gas:", overhead - 3889);
        }
    }
}
