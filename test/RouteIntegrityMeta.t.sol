// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  ROUTE SELF-CONSISTENCY — THE RELATIONS (follow-up to BPX-2026-009).
//
//  The pins in the Router say what a leg must look like. These tests state the
//  relations that hold AROUND the pins, so that a change on either side of a
//  seam is caught by the seam itself:
//
//    1. Solver -> Router: every leg the Solver builds from the registry passes
//       the Router's pins, field by field, and settles through swapBestExactIn.
//    2. Quoter twin of the accept-iff-consistent property: the exact preview
//       prices a leg exactly when its fields agree, and holds the plan's own
//       point otherwise.
//    3. Preview -> delivery: for every consistent leg, what previewPlanExact
//       returns is what the Router delivers, across the pool key's grid and
//       both directions.
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixQuoter} from "../src/BlazePhoenixQuoter.sol";
import {BlazePhoenixCore as BPC, Route, RoutePlan, Hop, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {PricedV4Manager, FixedPlanSolver, HookDeployer} from "./RouteIntegrityV4.t.sol";

contract RouteIntegrityMetaTest is Test {
    BlazePhoenixHub hub; BlazePhoenixRouter router; BlazePhoenixSolver solver; PricedV4Manager mgr;
    MockERC20 tokA; MockERC20 tokB; address c0; address c1;
    address user = address(0xBEEF);
    uint24 constant FEE = 3000; int24 constant TS = 60; uint128 constant LIQ = 1e30;
    bytes32 pidA; address hookB;

    function setUp() public {
        mgr = new PricedV4Manager();
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(mgr));
        solver = new BlazePhoenixSolver(address(hub));
        router = new BlazePhoenixRouter(address(hub), address(solver), address(this), address(0xFEE1), address(0xFEE2));
        hub.setRoles(address(router), address(solver), address(this));
        tokA = new MockERC20("A", "A"); tokB = new MockERC20("B", "B");
        (c0, c1) = address(tokA) < address(tokB) ? (address(tokA), address(tokB)) : (address(tokB), address(tokA));
        pidA = BPC.computeV4PoolId(c0, c1, FEE, TS, address(0));
        _seedUnit(pidA);
        hookB = new HookDeployer().deploy();
        hub.allowHook(hookB, true);
        MockERC20(c0).mint(user, 1_000e18); MockERC20(c1).mint(user, 1_000e18);
        MockERC20(c0).mint(address(mgr), 1_000_000e18); MockERC20(c1).mint(address(mgr), 1_000_000e18);
        vm.startPrank(user);
        MockERC20(c0).approve(address(router), type(uint256).max);
        MockERC20(c1).approve(address(router), type(uint256).max);
        vm.stopPrank();
    }

    function _seedUnit(bytes32 pid) internal {
        bytes32 base = keccak256(abi.encode(pid, uint256(6)));
        mgr.setSlot(base, bytes32(uint256(BPC.Q96)));
        mgr.setSlot(bytes32(uint256(base) + 3), bytes32(uint256(LIQ)));
        mgr.setRate(pid, 1000);
    }

    function _leg(bytes32 named, address hooks, uint24 fee, int24 ts, bool zfo, address tOther, uint256 amt, uint256 attested)
        internal pure returns (Leg memory)
    {
        return Leg({ pool: address(uint160(uint256(named))), hooks: hooks, kind: BPC.KIND_V4, fee: fee, tickSpacing: ts,
                     zeroForOne: zfo, stable: false, amountIn: amt, expectedOut: attested, auxId: bytes32(uint256(uint160(tOther))) });
    }

    function _oneHop(address tIn, address tOut, Leg memory leg, uint256 amt, uint256 attested) internal pure returns (Route memory route) {
        Leg[] memory legs = new Leg[](1); legs[0] = leg;
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({ tokenIn: tIn, tokenOut: tOut, amountIn: amt, expectedOut: attested, legs: legs });
        route = Route({ hops: hops, totalOut: attested, singleOut: attested, singleOutFloor: 0, expectedImpactBps: 0, confidenceWad: 0,
                        estGas: 0, hasSurplus: false, isV4Bundle: false });
    }

    /// @dev the Router's two pins, stated as a predicate over a leg
    function _pinsHold(Leg memory leg, address tokenIn) internal pure returns (bool) {
        address tOther = address(uint160(uint256(leg.auxId)));
        (address a, address b) = BPC.sortTokens(tokenIn, tOther);
        bool direction = leg.zeroForOne == (tokenIn == a);
        bool named = leg.pool == address(uint160(uint256(BPC.computeV4PoolId(a, b, leg.fee, leg.tickSpacing, leg.hooks))));
        return direction && named;
    }

    // ── 1. Solver -> Router ───────────────────────────────────────────────────

    /// The registry learns pool A from one honest swap; the Solver then builds its
    /// own leg for the pair from that row. That leg must satisfy both pins, and the
    /// route the Solver chooses must settle through the Router's own best-route door.
    function test_Seam_SolverLegsSatisfyTheRouterPins() public {
        uint256 amt = 1e18;
        vm.prank(user);
        router.swapExactIn(_oneHop(c0, c1, _leg(pidA, address(0), FEE, TS, true, c1, amt, amt), amt, 1), amt, 1, user, block.timestamp + 1);

        RoutePlan memory plan = solver.findBestRoutePlan(c0, c1, amt);
        assertGt(plan.best.hops.length, 0, "the Solver routes the pair it learned");
        uint256 v4Legs;
        for (uint256 h; h < plan.best.hops.length; ++h) {
            Hop memory hop = plan.best.hops[h];
            for (uint256 l; l < hop.legs.length; ++l) {
                Leg memory leg = hop.legs[l];
                if (!BPC.kindHas(leg.kind, BPC.A_CONC_SING)) continue;
                ++v4Legs;
                assertTrue(_pinsHold(leg, hop.tokenIn), "a Solver-built V4 leg satisfies the Router's pins");
            }
        }
        assertGt(v4Legs, 0, "the plan carries the V4 leg");

        vm.prank(user);
        uint256 got = router.swapBestExactIn(c0, c1, amt, 1, user, block.timestamp + 1);
        assertGt(got, amt * 9 / 10, "the Solver's route settles through the pins");
    }

    // ── 2. Quoter twin of accept-iff-consistent ───────────────────────────────

    function testFuzz_Quoter_PricesIffFieldsAgree(uint8 feeSel, uint8 tsSel, bool hooked, bool mirror, uint8 lieSel) public {
        uint24[3] memory fees = [uint24(500), uint24(3000), uint24(10000)];
        int24[3] memory tss = [int24(10), int24(60), int24(200)];
        uint24 fee = fees[feeSel % 3]; int24 ts = tss[tsSel % 3];
        address hooks = hooked ? hookB : address(0);
        bytes32 pid = BPC.computeV4PoolId(c0, c1, fee, ts, hooks);
        _seedUnit(pid);
        address tIn = mirror ? c1 : c0; address tOther = mirror ? c0 : c1; bool zfo = !mirror;
        uint256 amt = 1e18;
        Leg memory leg = _leg(pid, hooks, fee, ts, zfo, tOther, amt, 3 * amt);   // attested far above the 1:1 price
        uint8 lie = lieSel % 6;
        if (lie == 1) leg.pool = address(uint160(leg.pool) ^ 1);
        if (lie == 2) leg.fee = fee == 500 ? 3000 : 500;
        if (lie == 3) leg.tickSpacing = ts == 10 ? int24(60) : int24(10);
        if (lie == 4) leg.hooks = hooked ? address(0) : hookB;
        if (lie == 5) leg.zeroForOne = !zfo;
        FixedPlanSolver fixedSolver = new FixedPlanSolver();
        BlazePhoenixQuoter quoter = new BlazePhoenixQuoter(address(hub), address(fixedSolver));
        fixedSolver.setPlan(_oneHop(tIn, tOther, leg, amt, 3 * amt));
        (, uint256 exactOut) = quoter.previewPlanExact(tIn, tOther, amt);
        if (lie == 0) {
            assertLe(exactOut, amt, "a consistent leg is priced on the pool (1:1 less fee)");
            assertGt(exactOut, amt * 9 / 10, "and not clamped to the attested point");
        } else {
            assertGt(exactOut, 2 * amt, "an inconsistent leg is not priced: the preview holds the plan's point");
        }
    }

    // ── 3. Preview -> delivery ────────────────────────────────────────────────

    /// What the exact preview says is what the Router delivers, for every consistent
    /// leg across the key grid, both directions and a range of sizes.
    function testFuzz_ExactPreview_MatchesDelivery(uint8 feeSel, uint8 tsSel, bool hooked, bool mirror, uint96 amtSeed) public {
        uint24[3] memory fees = [uint24(500), uint24(3000), uint24(10000)];
        int24[3] memory tss = [int24(10), int24(60), int24(200)];
        uint24 fee = fees[feeSel % 3]; int24 ts = tss[tsSel % 3];
        address hooks = hooked ? hookB : address(0);
        bytes32 pid = BPC.computeV4PoolId(c0, c1, fee, ts, hooks);
        _seedUnit(pid);
        address tIn = mirror ? c1 : c0; address tOther = mirror ? c0 : c1; bool zfo = !mirror;
        uint256 amt = bound(uint256(amtSeed), 1e12, 100e18);
        Route memory r = _oneHop(tIn, tOther, _leg(pid, hooks, fee, ts, zfo, tOther, amt, amt), amt, amt);
        FixedPlanSolver fixedSolver = new FixedPlanSolver();
        BlazePhoenixQuoter quoter = new BlazePhoenixQuoter(address(hub), address(fixedSolver));
        fixedSolver.setPlan(r);
        (, uint256 exactOut) = quoter.previewPlanExact(tIn, tOther, amt);
        vm.prank(user);
        uint256 delivered = router.swapExactIn(r, amt, 1, user, block.timestamp + 1);
        assertEq(delivered, exactOut, "the exact preview is the delivery");
    }
}
