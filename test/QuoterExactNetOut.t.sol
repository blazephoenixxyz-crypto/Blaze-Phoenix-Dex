// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  previewPlanExact must promise what the Router delivers — AFTER the fee.
//
//  THE DEFECT (register row PROTOCOL_FEE_BPS, escape FEE-02, reported with a
//  PoC in the eighth disclosure round, 2026-09-03). `previewPlan` packs the
//  Solver's estimate and deducts the protocol fee once (`_pack`), so its
//  `netOut` is what the Router pays. `previewPlanExact` dry-runs every leg on
//  the pool itself — a strictly better estimate — and then returned the
//  pool-math total with NO fee term at all, while its docstring called the
//  result "execution-grade" and the Router's own docstring told integrators to
//  derive `userMinOut` from it. Delivery is exactly PROTOCOL_FEE_BPS below that
//  number on every route, so a caller who followed both docstrings with a
//  slippage buffer under 28 bps had every swap refused by the floor guard.
//
//  THE PIN. Three arms, on the harness of test/PreviewExecutionParity.t.sol
//  (two 1:1 V2 pairs, tB registered as the bridge, so the Solver plans the
//  two-hop A -> B -> C route and the one-hop A -> B route):
//    1. the two previews agree on the same route in the same block — on V2
//       legs the dry-run and the estimate are the same closed form, so the
//       only thing that can separate them is the fee;
//    2. `exactOut` is a floor the Router honours: `userMinOut = exactOut`
//       executes and delivers at least that much;
//    3. the deduction is the one `_pack` and both Router sites make — once,
//       rounded UP — pinned by value on the one-hop route.
//
//  Under the mutant that drops the deduction, arm 1 reads a 28 bps gap, arm 2
//  reverts in the Router's floor guard, arm 3 reads the pool-math ceiling.
//
//  forge test --match-contract QuoterExactNetOut -vv
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixQuoter} from "../src/BlazePhoenixQuoter.sol";
import {BlazePhoenixCore as BPC, Route} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";

contract QuoterExactNetOutTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    BlazePhoenixQuoter quoter;
    BlazePhoenixRouter router;
    MockERC20 tA;
    MockERC20 tB;
    MockERC20 tC;
    MockV2Pair ab;
    MockV2Pair bc;

    address user = address(0x5E4);
    uint256 constant AMOUNT_IN = 1_000e18;
    uint112 constant RESERVE = 1_000_000e18;

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
        tC = new MockERC20("C", "C");
        ab = _pair(tA, tB);
        bc = _pair(tB, tC);

        hub.setRoles(address(this), address(solver), address(quoter));
        _seed(ab, tA, tB);
        _seed(bc, tB, tC);
        hub.setRoles(address(router), address(solver), address(quoter));
        hub.addBridge(address(tB));

        tA.mint(user, 10_000e18);
        vm.prank(user);
        tA.approve(address(router), type(uint256).max);
    }

    function _pair(MockERC20 x, MockERC20 y) private returns (MockV2Pair p) {
        p = new MockV2Pair(address(x), address(y));
        x.mint(address(p), RESERVE);
        y.mint(address(p), RESERVE);
        p.setReserves(RESERVE, RESERVE);
    }

    function _seed(MockV2Pair p, MockERC20 x, MockERC20 y) private {
        for (uint256 i; i < 5; i++) {
            hub.recordSwap(address(p), BPC.KIND_V2, 30, address(0),
                address(x), address(y), 1e18, 1e18, RESERVE);
        }
    }

    /// The protocol's own deduction, written once here from the constants so
    /// the expected value never comes from the code under test.
    function _afterFee(uint256 gross) private pure returns (uint256) {
        return gross - BPC.mulDivUp(gross, BPC.PROTOCOL_FEE_BPS, BPC.BPS);
    }

    /// ARM 1. Same route, same block: the estimate and the dry-run agree once
    /// both have taken the fee out. `netOut` is packed as after-fee MINUS the
    /// safety buffer (test/PreviewExecutionParity.t.sol measures delivery
    /// against `netOut + safetyBuffer` for the same reason), so the after-fee
    /// figure of the view preview is `netOut + safetyBuffer`. The tolerance is
    /// one wei of rounding — the fee is 28 bps, so a missing deduction is
    /// 2.8e17 wei away from it.
    function test_ExactOut_AgreesWithNetOut_OnTheSameRouteAndBlock() public {
        (BlazePhoenixQuoter.Preview memory pv, , ) =
            quoter.previewPlan(address(tA), address(tC), AMOUNT_IN);
        assertGt(pv.netOut, 0, "premise: the view preview quotes the two-hop route");
        assertEq(pv.hops, 2, "premise: the bridge route is the plan");

        (Route memory route, uint256 exactOut) =
            quoter.previewPlanExact(address(tA), address(tC), AMOUNT_IN);
        assertEq(route.hops.length, 2, "premise: the exact pass re-prices the same two-hop route");
        assertGt(exactOut, 0, "premise: the dry-run quotes");

        assertApproxEqAbs(exactOut, pv.netOut + pv.safetyBuffer, 1,
            "exactOut must be the NET output: the dry-run total minus the protocol fee, like netOut");
        assertGt(pv.netOut + pv.safetyBuffer, pv.netOut, "premise: the view preview carries a safety buffer");
        assertLt(exactOut, pv.grossOut,
            "exactOut must sit below the pool-math ceiling by the fee, never on it");
    }

    /// ARM 2. The user-facing promise: `userMinOut = exactOut` is accepted and
    /// honoured. Before the fix this call died in the Router's floor guard on
    /// every route, because delivery is exactly the fee below the old number.
    function test_ExactOut_IsAFloorTheRouterHonours() public {
        (, uint256 exactOut) = quoter.previewPlanExact(address(tA), address(tC), AMOUNT_IN);
        assertGt(exactOut, 0, "premise: the dry-run quotes");

        uint256 before = tC.balanceOf(user);
        vm.prank(user);
        router.swapBestExactIn(address(tA), address(tC), AMOUNT_IN, exactOut, user, block.timestamp + 1);
        uint256 delivered = tC.balanceOf(user) - before;

        assertGe(delivered, exactOut, "the Router must deliver at least the exact preview");
        assertApproxEqRel(delivered, exactOut, 0.001e18,
            "and not materially more: the preview is execution-grade, not merely a lower bound");
    }

    /// ARM 3. The deduction is the same one `_pack` and both Router sites make:
    /// once, rounded UP, on the dry-run total. Pinned by value on the one-hop
    /// route, where the pool-math ceiling is the V2 closed form itself.
    function test_ExactOut_OneHop_IsThePoolMathCeilingLessTheFeeRoundedUp() public {
        (, uint256 exactOut) = quoter.previewPlanExact(address(tA), address(tB), AMOUNT_IN);
        uint256 ceiling = BPC.outV2(AMOUNT_IN, RESERVE, RESERVE, 30);
        assertGt(ceiling, 0, "premise: the closed form prices the pair");
        assertEq(exactOut, _afterFee(ceiling),
            "exactOut == pool-math ceiling - fee (rounded up), exactly as netOut is packed");
    }
}
