// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  PoC — F-2
//  Title    : Solver._singleLeg never bounds a reserve-shaped promise by the
//             pool's holdings (the split path was fixed; this path was not)
//  Contract : src/BlazePhoenixSolver.sol  (_singleLeg / _quote / universalQuote)
//  Severity : Medium (griefing / denial of service + a non-executable quote)
//
//  Run it:
//      FOUNDRY_PROFILE=poc forge test --match-contract F2_PhantomSingleLeg -vv
//
//  End to end:
//    1. a V2-shaped pair is deployed that DECLARES reserves far above what it
//       holds (getReserves is caller-controlled; the pair holds only enough
//       tokenOut to settle one dust swap);
//    2. a dust swap through it registers the pair (recordSwap on this revision
//       does not check that the pair holds its declared reserves);
//    3. the reserves are re-forged;
//    4. Solver.findBestRoutePlan returns a plan whose expectedOut is orders of
//       magnitude above the pool's real tokenOut balance, and
//       Quoter.previewPlan reports canExecute = true with the same netOut;
//    5. submitting that plan reverts: the pool cannot pay, so any user routed
//       this way burns gas and cannot settle. The published quote is not
//       executable.
//
//  The split path of _buildHop caps a reserve-shaped quote by the pool's
//  tokenOut holdings. _singleLeg does not.
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixQuoter} from "../src/BlazePhoenixQuoter.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg, RoutePlan} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "../test/mocks/MockERC20.sol";
import {MockV2Pair} from "../test/mocks/MockV2Pair.sol";
import {Origin} from "../test/mocks/MockOriginFactory.sol";

contract Bounty1013SingleLegBoundedByHoldingsTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    BlazePhoenixQuoter quoter;
    BlazePhoenixRouter router;

    MockERC20 inTok;
    MockERC20 outTok;
    MockV2Pair pair;

    address user = address(0xBEEF);

    // Declared reserves: in = 1e18, out = 1e30 (ratio 1e12). The pair holds only
    // 1e18 of tokenOut: enough to pay the dust swap that registers it and nothing
    // else.
    uint112 constant FAKE_R_IN  = 1e18;
    uint112 constant FAKE_R_OUT = 1e30;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        solver = new BlazePhoenixSolver(address(hub));
        quoter = new BlazePhoenixQuoter(address(hub), address(solver));
        router = new BlazePhoenixRouter(
            address(hub), address(solver), address(this), address(0xFEE1), address(0xFEE2)
        );
        hub.setRoles(address(router), address(solver), address(quoter));

        inTok  = new MockERC20("IN", "IN");
        outTok = new MockERC20("OUT", "OUT");
        pair = new MockV2Pair(address(inTok), address(outTok));
        // rizki-3107: the swap door now seats only a pool a wired factory derives, so a
        // contract that forges its reserves takes no seat unless a wired factory deployed it.
        // The pair is given that origin: what is measured here is the Solver's own bound,
        // kept as defence in depth behind the origin proof.
        Origin.wire(hub, address(pair), address(inTok), address(outTok), BPC.KIND_V2, 30);

        inTok.mint(address(pair),  1e18);
        outTok.mint(address(pair), 1e18);

        inTok.mint(user, 1e24);
        vm.prank(user);
        inTok.approve(address(router), type(uint256).max);
    }

    function _declaredReserves() internal view returns (uint256 rIn, uint256 rOut) {
        (uint256 r0, uint256 r1, ) = pair.getReserves();
        bool zfo = pair.token0() == address(inTok);
        (rIn, rOut) = zfo ? (r0, r1) : (r1, r0);
    }

    function _setReserves(uint112 rIn, uint112 rOut) internal {
        if (pair.token0() == address(inTok)) pair.setReserves(rIn, rOut);
        else pair.setReserves(rOut, rIn);
    }

    /// @dev hand-built single-hop route through the pair, for the dust swap that
    ///      gets the pair onto the registry.
    function _dustRoute(uint256 amt) internal view returns (Route memory r) {
        bool zfo = pair.token0() == address(inTok);
        (uint256 rIn, uint256 rOut) = _declaredReserves();
        uint256 q = BPC.outV2(amt, rIn, rOut, 30);

        Leg[] memory legs = new Leg[](1);
        legs[0] = Leg({
            pool: address(pair), hooks: address(0), kind: BPC.KIND_V2, fee: 30,
            tickSpacing: 0, zeroForOne: zfo, stable: false,
            amountIn: amt, expectedOut: q, auxId: bytes32(0)
        });
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({
            tokenIn: address(inTok), tokenOut: address(outTok),
            amountIn: amt, expectedOut: q, legs: legs
        });
        r = Route({
            hops: hops, totalOut: q, singleOut: q, singleOutFloor: 0,
            expectedImpactBps: 0, confidenceWad: 0, estGas: 0,
            hasSurplus: false, isV4Bundle: false
        });
    }

    function test_ForgedReservesSingleLegIsDropped() public {
        // (1) register the pair with a dust swap. Since bounty #85 (Remember Me)
        //     the Router refuses a leg whose pair declares more than it holds
        //     (RouterE(8)), so the seat is taken while the pair is honest and
        //     the forgery comes after.
        _setReserves(1e18, 1e18);
        Route memory dust = _dustRoute(1e6);
        vm.prank(user);
        router.swapExactIn(dust, 1e6, 1, user, block.timestamp + 1);

        assertEq(
            hub.getActivePools(address(inTok), address(outTok)).length, 1,
            "the forged pair did not take a registry seat"
        );

        // (2) re-forge (recordSwap re-synced reserves to the real balances)
        _setReserves(FAKE_R_IN, FAKE_R_OUT);

        // (3) ask the planner for a normal-size order
        uint256 order = 1e18;
        // #43: the forged pair is the only venue, so dropping its phantom single leg (the
        // split-path rule) leaves the planner with its "no path" answer, SolverE(5).
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixSolver.SolverE.selector, uint16(5)));
        solver.findBestRoutePlan(address(inTok), address(outTok), order);
        uint256 held = outTok.balanceOf(address(pair));
        try quoter.previewPlan(address(inTok), address(outTok), order) returns (
            BlazePhoenixQuoter.Preview memory pv, Route memory, bool
        ) {
            assertTrue(!pv.canExecute || pv.netOut <= held, "preview endorses a promise above holdings");
        } catch {}
    }
}
