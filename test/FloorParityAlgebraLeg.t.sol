// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  THE LIVE FEE OF AN ALGEBRA LEG HAS TWO READERS, AND THEY MUST AGREE.
//
//  The impact the Solver attests (`_legImpactBps`, which feeds `singleOutFloor`)
//  and the impact the Router enforces (`Core.legQuoteImpact`, which feeds the
//  ExecutionProof's `floorUsed`) are the two `ironFloorBpsShv` impact inputs of
//  SHARED_QUANTITIES. Each resolves a concentrated leg's fee through
//  the one producer `quoteV3Fee`, with a different key: the Solver hands it the
//  registry row's fee, the Router hands it 0 and never calldata's `leg.fee`.
//  For Algebra the row's fee is the 0 sentinel (rule R2, written by the Hub's
//  doors through `_concRowFee`), so both resolve the pool's live fee from
//  `globalState`. That agreement is a coincidence by construction: it is pinned
//  here, not fused.
//
//  INV-20 made the Solver resolve the live fee instead of pricing the leg with
//  the raw sentinel, which understated the impact and attested a floor TIGHTER
//  than the enforced one (the Solver's INV-20 note: an honest fill died in
//  RouterE(5)). No test held that fix by its value on an Algebra leg:
//  FloorParitySolverRouter seeds V2 pairs only, AlgebraExecution plans with
//  singleOutFloor 0, AlgebraFeeMeasured checks the quote, not the floor, and
//  ClFeeReadHasItsOwnBudget sees the fee read in the bytecode, not what it is
//  fed.
//
//  Same route, same block: the route's `expectedImpactBps` equals the impact
//  `Core.legQuoteImpact` returns for the leg the Router will spend, and the
//  Solver's `singleOutFloor` equals the Router's `floorUsed`. The impact check
//  is the one that still sees a split once both floors sit on the hard floor
//  (impact of 16% or more). On two hops each floor is held to the one law, on
//  the inputs its reader measures. Attested: `expectedImpactBps` is the mean of
//  the impacts `Core.legQuoteImpact` returns for the two legs at the inputs the
//  plan carries, and `singleOutFloor` is `ironFloorBpsShv` of that mean on the
//  plan's output. Enforced: `floorUsed` is `ironFloorBpsShv` of the mean of the
//  same impacts at the inputs the two pools received, on the frame's own quote.
//  Both are exact, to the wei, at every size and fee pair swept below. Prices
//  are off 1 (P = 4 and 1/4): at P = 1 the two directions of the curve mirror
//  each other.
//
//  Green at cb1d7d9. Red under (mutants.py): MT5-1 the Solver hands the curve
//  the raw row fee (INV-20 undone); MT5-2 the Solver drops the measured live
//  fee; MT5-3 the Router keys the fee on calldata's `leg.fee`; MT5-4 the Router
//  drops the measured live fee.
// =============================================================================

import {Test, Vm} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Leg, Route, RoutePlan} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockAlgebraPool} from "./mocks/MockAlgebraPool.sol";

contract FloorParityAlgebraLegTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    BlazePhoenixRouter router;
    MockERC20 tokenA;    // lowest address: sells into A/B zeroForOne
    MockERC20 tokenB;    // bridge, between the two
    MockERC20 tokenC;    // highest address, bridge: sells into B/C oneForZero
    MockAlgebraPool algAB;
    MockAlgebraPool algBC;
    address user = address(0xBEEF);

    uint160 constant Q96 = 79228162514264337593543950336;
    uint128 constant LIQ = 1_000_000e18;
    uint256 constant AMT = 50_000e18;
    bytes32 constant PROOF = keccak256("ExecutionProof(address,address,uint256,uint256,uint256,uint256)");

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        solver = new BlazePhoenixSolver(address(hub), address(0));
        router = new BlazePhoenixRouter(address(hub), address(solver), address(this), address(0xFEE1), address(0xFEE2));
        hub.setRoles(address(router), address(solver), address(this));

        // Ordered by address, so each pool's orientation is known.
        MockERC20 x = new MockERC20("X", "X");
        MockERC20 y = new MockERC20("Y", "Y");
        MockERC20 z = new MockERC20("Z", "Z");
        if (address(x) > address(y)) (x, y) = (y, x);
        if (address(y) > address(z)) (y, z) = (z, y);
        if (address(x) > address(y)) (x, y) = (y, x);
        (tokenA, tokenB, tokenC) = (x, y, z);
        hub.addBridge(address(tokenB));
        hub.addBridge(address(tokenC));

        algAB = new MockAlgebraPool(address(tokenA), address(tokenB), 3000);
        algAB.setState(2 * Q96, LIQ);                // P = 4: B per A
        algBC = new MockAlgebraPool(address(tokenB), address(tokenC), 3000);
        algBC.setState(Q96 / 2, LIQ);                // P = 1/4: C per B
        _fund(address(algAB));
        _fund(address(algBC));
        // As production holds it: the 0 fee sentinel in the row, the live fee on the pool.
        hub.seedPool(address(algAB), BPC.KIND_ALGEBRA, 0, address(0), address(tokenA), address(tokenB));
        hub.seedPool(address(algBC), BPC.KIND_ALGEBRA, 0, address(0), address(tokenB), address(tokenC));

        tokenA.mint(user, 1e27);
        tokenC.mint(user, 1e27);
        vm.startPrank(user);
        tokenA.approve(address(router), type(uint256).max);
        tokenC.approve(address(router), type(uint256).max);
        vm.stopPrank();
    }

    function _fund(address pool) private {
        tokenA.mint(pool, 1e27);
        tokenB.mint(pool, 1e27);
        tokenC.mint(pool, 1e27);
    }

    /// The Router's own call (Router `_hopScaleImpactAndQuote`), made from here: the impact
    /// the frame enforces for this leg at this amount, in this state.
    function frameImpact(Leg calldata leg, address tIn, address tOut, uint256 legAmt)
        external view returns (uint256 imp)
    {
        (, imp, ) = BPC.legQuoteImpact(leg, tIn, tOut, legAmt);
    }

    /// (quoted, floorUsed) of the Router's ExecutionProof: its OWN floor, not the max with
    /// the attested one. userMinOut is 1, so only the two floors are in play.
    function _enforced(Route memory r, uint256 amt) private returns (uint256 quoted, uint256 floorUsed) {
        vm.recordLogs();
        vm.prank(user);
        router.swapExactIn(r, amt, 1, user, block.timestamp + 1);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i = logs.length; i > 0 && !found; --i) {
            Vm.Log memory l = logs[i - 1];
            if (l.emitter == address(router) && l.topics.length > 0 && l.topics[0] == PROOF) {
                (quoted, , floorUsed, ) = abi.decode(l.data, (uint256, uint256, uint256, uint256));
                found = true;
            }
        }
        assertTrue(found, "premise: ExecutionProof emitted");
    }

    /// One hop, one Algebra leg, a bridge out: the two readers must agree EXACTLY.
    function _oneHopParity(MockERC20 tIn, MockERC20 tOut, MockAlgebraPool pool, uint16 liveFee, uint256 amt)
        private returns (RoutePlan memory plan)
    {
        pool.setDynamicFee(liveFee);
        plan = solver.findBestRoutePlan(address(tIn), address(tOut), amt);
        assertEq(plan.best.hops.length, 1, "premise: one hop");
        assertEq(plan.best.hops[0].legs.length, 1, "premise: one leg");
        Leg memory leg = plan.best.hops[0].legs[0];
        assertEq(leg.pool, address(pool), "premise: the Algebra leg");
        assertEq(leg.fee, 0, "premise: the row carries the 0 sentinel (R2)");
        assertEq(leg.zeroForOne, address(tIn) < address(tOut), "premise: the leg's direction");
        assertGt(plan.best.singleOutFloor, 0, "premise: the Solver attested a floor");

        assertEq(plan.best.expectedImpactBps, this.frameImpact(leg, address(tIn), address(tOut), leg.amountIn),
            "the impact the Solver attests != the impact the frame enforces, on an Algebra leg");
        (, uint256 floorUsed) = _enforced(plan.best, amt);
        assertEq(floorUsed, plan.best.singleOutFloor,
            "the floor the Solver attests != the floor the Router enforces, on an Algebra leg");
    }

    /// The INV-20 fixture: a 30 bps live fee the row does not carry.
    function test_AlgebraParity_ZeroForOne_LiveFee30Bps() public {
        _oneHopParity(tokenA, tokenB, algAB, 3000, AMT);
    }

    /// The other direction of the curve, at a 1% live fee.
    function test_AlgebraParity_OneForZero_LiveFee1Pct() public {
        _oneHopParity(tokenC, tokenB, algBC, 10_000, AMT);
    }

    /// A lying caller: `leg.fee` is calldata, no door of the Router checks it on an Algebra
    /// leg, and the frame must not read it. Lower, higher and absurd: the impact the frame
    /// computes and the floor the Router enforces stay the attested ones.
    function test_AlgebraParity_ACallerForgedFeeMovesNeitherImpactNorFloor() public {
        algAB.setDynamicFee(3000);
        RoutePlan memory plan = solver.findBestRoutePlan(address(tokenA), address(tokenB), AMT);
        assertEq(plan.best.hops.length, 1, "premise: one hop");
        assertEq(plan.best.hops[0].legs.length, 1, "premise: one leg");
        assertEq(plan.best.hops[0].legs[0].pool, address(algAB), "premise: the Algebra leg");
        assertEq(plan.best.hops[0].legs[0].fee, 0, "premise: the row carries the 0 sentinel (R2)");
        uint256 legAmt = plan.best.hops[0].legs[0].amountIn;
        uint256 honest = this.frameImpact(plan.best.hops[0].legs[0], address(tokenA), address(tokenB), legAmt);
        assertEq(plan.best.expectedImpactBps, honest, "premise: the honest leg is at parity");

        uint24[3] memory lies = [uint24(1), uint24(10_000), uint24(500_000)];
        for (uint256 i; i < lies.length; ++i) {
            uint256 snap = vm.snapshotState();
            plan.best.hops[0].legs[0].fee = lies[i];
            assertEq(this.frameImpact(plan.best.hops[0].legs[0], address(tokenA), address(tokenB), legAmt), honest,
                "calldata's leg.fee moved the impact the frame enforces");
            (, uint256 floorUsed) = _enforced(plan.best, AMT);
            assertEq(floorUsed, plan.best.singleOutFloor, "calldata's leg.fee moved the floor the Router enforces");
            vm.revertToState(snap);
        }
    }

    /// Two hops, one Algebra leg each, A -> B -> C: each floor is the one law of the frame's
    /// leg impacts, on the inputs its reader measures. The attested side is read off the plan;
    /// the enforced side off the ExecutionProof and the balances the two pools gained.
    function _twoHopLaw(uint16 feeAB, uint16 feeBC, uint256 amt) private {
        algAB.setDynamicFee(feeAB);
        algBC.setDynamicFee(feeBC);
        RoutePlan memory plan = solver.findBestRoutePlan(address(tokenA), address(tokenC), amt);
        assertEq(plan.best.hops.length, 2, "premise: the route crosses the bridge");
        assertEq(plan.best.hops[0].legs.length, 1, "premise: one leg on hop 0");
        assertEq(plan.best.hops[1].legs.length, 1, "premise: one leg on hop 1");
        Leg memory l0 = plan.best.hops[0].legs[0];
        Leg memory l1 = plan.best.hops[1].legs[0];
        assertEq(l0.pool, address(algAB), "premise: hop 0 is A/B");
        assertEq(l1.pool, address(algBC), "premise: hop 1 is B/C");
        assertEq(l0.amountIn, plan.best.hops[0].amountIn, "premise: the leg carries all of hop 0");
        assertEq(l1.amountIn, plan.best.hops[1].amountIn, "premise: the leg carries all of hop 1");
        assertGt(plan.best.singleOutFloor, 0, "premise: the Solver attested a floor");

        // Attested: the mean of the frame's impacts at the inputs the plan carries. One leg
        // per hop, so the leg shave is 0.
        uint256 mean = (this.frameImpact(l0, address(tokenA), address(tokenB), l0.amountIn)
            + this.frameImpact(l1, address(tokenB), address(tokenC), l1.amountIn)) / 2;
        assertEq(plan.best.expectedImpactBps, mean,
            "two Algebra hops: the impact the Solver attests != the mean of the frame's leg impacts");
        assertEq(plan.best.singleOutFloor, BPC.mulDivUp(plan.best.totalOut, BPC.ironFloorBpsShv(mean, 0, 0), BPC.BPS),
            "two Algebra hops: the floor the Solver attests != the floor of the frame's leg impacts");

        // Enforced: the same law at the inputs the two pools received, on the frame's quote.
        uint256 snap = vm.snapshotState();
        uint256 in0 = tokenA.balanceOf(address(algAB));
        uint256 in1 = tokenB.balanceOf(address(algBC));
        (uint256 quoted, uint256 floorUsed) = _enforced(plan.best, amt);
        in0 = tokenA.balanceOf(address(algAB)) - in0;
        in1 = tokenB.balanceOf(address(algBC)) - in1;
        vm.revertToState(snap);
        assertGt(in0, 0, "premise: hop 0 was spent");
        assertGt(in1, 0, "premise: hop 1 was spent");
        mean = (this.frameImpact(l0, address(tokenA), address(tokenB), in0)
            + this.frameImpact(l1, address(tokenB), address(tokenC), in1)) / 2;
        assertEq(floorUsed, BPC.mulDivUp(quoted, BPC.ironFloorBpsShv(mean, 0, 0), BPC.BPS),
            "two Algebra hops: the floor the Router enforces != the floor of the frame's leg impacts");
    }

    /// Two Algebra hops at different live fees: the attested floor and the enforced floor
    /// are each the law of the frame's leg impacts.
    function test_AlgebraParity_TwoHops_EachFloorIsTheLawOfTheFramesLegImpacts() public {
        _twoHopLaw(3000, 10_000, 100e18);
    }

    /// The same law across the sizes and the live fees: every decade from 1e3 wei to 1e23,
    /// each with two off-decade sizes, at four fee pairs (0% and Algebra's uint16 ceiling
    /// included).
    function test_AlgebraParity_TwoHops_TheLawHoldsAtEverySizeAndFeePair() public {
        uint16[4] memory fa = [uint16(3000), 0, type(uint16).max, 500];
        uint16[4] memory fb = [uint16(10_000), 0, type(uint16).max, 100];
        for (uint256 f; f < 4; ++f) {
            for (uint256 a = 1e3; a <= 1e23; a *= 10) {
                _twoHopLaw(fa[f], fb[f], a);
                if (a < 1e23) {
                    _twoHopLaw(fa[f], fb[f], 3 * a + 1);
                    _twoHopLaw(fa[f], fb[f], 7 * a + 13);
                }
            }
        }
    }

    /// 5% live fee, a fifth of the liquidity: the impact is past 16% with or without the
    /// fee, so both floors sit on the hard floor and cannot tell a fee-less impact from the
    /// live one. The impact check still can.
    function test_AlgebraParity_ImpactAgreesWhereBothFloorsSitOnTheHardFloor() public {
        uint256 amt = 200_000e18;
        assertGe(BPC.impactV3Bps(amt, 2 * Q96, LIQ, 0, true), BPC.FLOOR_BASE_BPS + BPC.FLOOR_HARD_MAX_LOSS_BPS - BPC.BPS,
            "premise: even the fee-less impact puts the floor on the hard floor");
        RoutePlan memory plan = _oneHopParity(tokenA, tokenB, algAB, 50_000, amt);
        assertEq(BPC.mulDiv(plan.best.singleOutFloor, BPC.BPS, plan.best.totalOut), BPC.BPS - BPC.FLOOR_HARD_MAX_LOSS_BPS,
            "premise: the attested floor sits on the hard floor");
    }

    /// The live fee, the size and the direction move; the two readers do not part. A measured
    /// 0% is a fee too (the read succeeded), up to Algebra's uint16 ceiling. Sizes from 1e3 wei
    /// (every decade from 1e3 to 1e23 routes here, both ways) to a fifth of the liquidity.
    /// forge-config: default.fuzz.runs = 64
    /// forge-config: release.fuzz.runs = 64
    function testFuzz_AlgebraParity_AnyLiveFeeAnySizeEitherWay(uint256 fee, uint256 amt, bool oneForZero) public {
        fee = bound(fee, 0, type(uint16).max);
        amt = bound(amt, 1e3, 200_000e18);
        if (oneForZero) _oneHopParity(tokenC, tokenB, algBC, uint16(fee), amt);
        else            _oneHopParity(tokenA, tokenB, algAB, uint16(fee), amt);
    }

}
