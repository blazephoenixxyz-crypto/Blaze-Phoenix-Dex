// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  The encode doors ask the per-leg floor on the bound the Router measures (2026-11-14). The
//  Router lifts a leg's bound to MIN_QUOTE_COVERAGE_BPS of the quote it measures in-frame
//  (`Router._execScaled`, the coverage gate) before the per-leg floor and the hop budget. Red
//  while `_walk(ask)` asked the per-leg floor against the attestation alone (measured on the
//  G7 midtail-3:4 door before the lift; at 59b7819 the door asked less, so red there too): a
//  leg whose venue pays under 40 % of its in-frame quote, with an attestation that matches what
//  it pays, cleared the door and the Router refused the bytes. The in-frame quote reads the
//  pool's `liquidity()` (single-tick model); the mock fills from a shallower `swapLiquidity`,
//  the shape of a fill that crosses into thin ticks.
//  Oracle: the Router's execution of the returned bytes, never the Quoter.
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixQuoter} from "../src/BlazePhoenixQuoter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg, RoutePlan} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV3Pool} from "./mocks/MockV3Pool.sol";

contract EncodeDoorsAskTheCoverageLiftTest is Test {
    uint256 constant BIG = 99e18;
    uint256 constant SMALL = 1e18;

    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    BlazePhoenixRouter router;
    BlazePhoenixQuoter quoter;
    MockERC20 tA;
    MockERC20 tB;
    MockV3Pool deep;
    MockV3Pool gap;
    address recipient = makeAddr("recipient");

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        tA = new MockERC20("A", "A");
        tB = new MockERC20("B", "B");
        solver = new BlazePhoenixSolver(address(hub), address(0));
        router = new BlazePhoenixRouter(
            address(hub), address(solver), address(this), makeAddr("treasury1"), makeAddr("treasury2"));
        quoter = new BlazePhoenixQuoter(address(hub), address(solver));
        hub.setRoles(address(router), address(solver), address(this));
        deep = new MockV3Pool(address(tA), address(tB), 100);
        gap = new MockV3Pool(address(tA), address(tB), 500);
        deep.setState(uint160(BPC.Q96), 1e30);
        gap.setState(uint160(BPC.Q96), 1e30);
        tB.mint(address(deep), 1e30);
        tB.mint(address(gap), 1e30);
        hub.seedPool(address(deep), BPC.KIND_V3, 100, address(0), address(tA), address(tB));
        hub.seedPool(address(gap), BPC.KIND_V3, 500, address(0), address(tA), address(tB));
    }

    function _leg(MockV3Pool p, uint256 amountIn, uint256 expectedOut) internal view returns (Leg memory) {
        return Leg({
            pool: address(p), hooks: address(0), kind: BPC.KIND_V3, fee: p.fee(), tickSpacing: 1,
            zeroForOne: p.token0() == address(tA), stable: false,
            amountIn: amountIn, expectedOut: expectedOut, auxId: bytes32(0)
        });
    }

    /// What `p` pays for `amt`, from the liquidity it fills with.
    function _pays(MockV3Pool p, uint256 amt) internal view returns (uint256) {
        uint128 l = p.swapLiquidity() != 0 ? p.swapLiquidity() : p.liquidity();
        return BPC.outV3(amt, p.sqrtPriceX96(), l, p.fee(), p.token0() == address(tA), 0);
    }

    /// The door handed a two-leg route whose every attestation is what its venue pays, then the
    /// Router on the bytes. Fee on the input at hop 0; the order funds the legs at their commitment.
    function _doorThenRouter(uint128 gapL) internal returns (bool encoded, bool settled, bytes memory ret) {
        gap.setSwapLiquidity(gapL);
        Leg[] memory legs = new Leg[](2);
        legs[0] = _leg(deep, BIG, _pays(deep, BIG));
        legs[1] = _leg(gap, SMALL, _pays(gap, SMALL));
        uint256 sumOut = legs[0].expectedOut + legs[1].expectedOut;
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({tokenIn: address(tA), tokenOut: address(tB), amountIn: BIG + SMALL, expectedOut: sumOut, legs: legs});
        Route memory r = Route({hops: hops, totalOut: sumOut, singleOut: 0, singleOutFloor: 1,
            expectedImpactBps: 0, confidenceWad: 0, estGas: 0, hasSurplus: false, isV4Bundle: false});
        RoutePlan memory plan;
        plan.best = r;
        uint256 order = BIG + SMALL + BPC.mulDivUp(BIG + SMALL, BPC.PROTOCOL_FEE_BPS, BPC.BPS);
        vm.mockCall(address(solver), abi.encodeWithSelector(solver.findBestRoutePlan.selector), abi.encode(plan));
        (BlazePhoenixQuoter.Preview memory pv, bytes memory data) =
            quoter.previewAndEncodeWithMinOut(address(tA), address(tB), order, 1, recipient, block.timestamp + 1);
        vm.clearMockedCalls();
        encoded = data.length != 0;
        assertEq(pv.canExecute, encoded, "canExecute and bytes agree");
        // A refused door would have encoded `pv.effectiveMinOut`, max(the caller's floor,
        // `singleOutFloor`): both are 1 here, so the call below is that call.
        if (!encoded) data = abi.encodeCall(router.swapExactIn, (r, order, 1, recipient, block.timestamp + 1));
        tA.mint(address(this), order);
        tA.approve(address(router), order);
        (settled, ret) = address(router).call(data);
    }

    /// The gap leg pays ~29 % of its in-frame quote (under 80 % of the lifted 50 %): every
    /// attestation is met, the Router refuses on the lift.
    function test_UnderTheLiftedFloor_TheDoorsBytesSettleOrAreNotEncoded() public {
        (bool encoded, bool settled, bytes memory ret) = _doorThenRouter(4e17);
        assertFalse(settled, "premise of the oracle: the Router refuses on the lifted floor");
        assertEq(bytes4(ret), BlazePhoenixRouter.RouterE.selector, "refused as RouterE");
        bytes memory t = new bytes(ret.length - 4);
        for (uint256 i; i < t.length; ++i) t[i] = ret[i + 4];
        assertEq(abi.decode(t, (uint256)), 5, "with code 5");
        assertFalse(encoded, "the door encoded bytes the Router refuses");
    }

    /// Control: the gap leg pays ~50 % of its in-frame quote, over the lifted floor (40 %).
    function test_Control_OverTheLiftedFloor_TheBytesSettle() public {
        (bool encoded, bool settled, bytes memory ret) = _doorThenRouter(1e18);
        assertTrue(encoded, "encoded");
        assertTrue(settled, string.concat("settled: ", vm.toString(ret)));
    }
}
