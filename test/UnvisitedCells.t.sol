// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  UnvisitedCells - regions of the Router/Solver input space that a
//  combinatorial inventory found NO existing test ever reaches. Each cell has
//  a positive test asserting a CONCRETE number (or a specific revert code) and
//  a control that differs in exactly one respect. Cells are ordered by
//  consequence; see the per-cell headers for the exact invariant pinned.
//
//  forge test --match-contract UnvisitedCells -vv
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg, RoutePlan} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";
import {MockSolidlyPair} from "./mocks/MockSolidlyPair.sol";
// Reuse the faithful native-V4 fixtures instead of authoring a second copy.
import {MockV4ManagerNative, MockWETH9} from "./RouterV4NativeEth.t.sol";

interface IERC20Bal {
    function transfer(address to, uint256 amt) external returns (bool);
    function balanceOf(address who) external view returns (uint256);
}

// --- Shared leg/route builders for hand-assembled V2 routes -----------------
library RB {
    function v2Leg(address pool, address tokenIn, address tokenOut, uint256 amountIn, uint256 expectedOut)
        internal pure returns (Leg memory)
    {
        return Leg({
            pool: pool, hooks: address(0), kind: BPC.KIND_V2, fee: 30, tickSpacing: 0,
            zeroForOne: tokenIn < tokenOut, stable: false,
            amountIn: amountIn, expectedOut: expectedOut, auxId: bytes32(0)
        });
    }
}

// =============================================================================
//  CELL 1 - BRIDGE TABLE FULL (MAX_BRIDGES == 3). The shipping config
//  registers three bridges; every existing Solver test uses 0/1/2. Here the
//  ONLY route lives behind the THIRD unrolled arm (hub.bridge(2)/viaB3 in
//  BlazePhoenixSolver:296-298), with the first two bridges dead decoys and no
//  direct pool. Solve AND execute, so the third arm truly runs.
//
//  Constants/sites: MAX_BRIDGES=3 (BlazePhoenixHub.sol:105); third-arm read
//  BlazePhoenixSolver.sol:296-298; SolverE(5)=no-route BlazePhoenixSolver.sol:342.
// =============================================================================
contract UnvisitedCellsBridgeTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    BlazePhoenixRouter router;
    MockERC20 A; MockERC20 B;
    MockERC20 dec0; MockERC20 dec1; MockERC20 br3;
    address user = address(0xBEEF);
    address constant T1 = address(0xFEE1);
    address constant T2 = address(0xFEE2);
    uint256 constant R = 1_000_000e18;
    uint256 constant AMT = 1_000e18;

    function _seedV2(MockERC20 x, MockERC20 y, uint256 rx, uint256 ry) internal returns (MockV2Pair p) {
        p = new MockV2Pair(address(x), address(y));
        x.mint(address(p), rx); y.mint(address(p), ry);
        (address t0,) = address(x) < address(y) ? (address(x), address(y)) : (address(y), address(x));
        p.setReserves(uint112(address(x) == t0 ? rx : ry), uint112(address(x) == t0 ? ry : rx));
        hub.seedPool(address(p), BPC.KIND_V2, 30, address(0), address(x), address(y));
    }

    function _bootstrap() internal {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        solver = new BlazePhoenixSolver(address(hub));
        router = new BlazePhoenixRouter(address(hub), address(solver), address(this), T1, T2);
        A = new MockERC20("A", "A"); B = new MockERC20("B", "B");
        dec0 = new MockERC20("D0", "D0"); dec1 = new MockERC20("D1", "D1"); br3 = new MockERC20("BR3", "BR3");
        // The ONLY complete path: A -> br3 -> B. No direct A/B pool, and no
        // pool touches the two decoy bridges.
        _seedV2(A, br3, R, R);
        _seedV2(br3, B, R, R);
        A.mint(user, 10_000e18);
        vm.prank(user); A.approve(address(router), type(uint256).max);
    }

    /// @notice Positive: with three live bridges (decoys at slots 0/1, the real
    ///         one at slot 2), the route is found ONLY by the third arm and
    ///         executes end-to-end. Delivery and the bridge-coin fee are exact.
    function test_Cell1_ThirdBridgeArm_SolvesAndExecutes() public {
        _bootstrap();
        hub.addBridge(address(dec0));  // slot 0 - no pools, arm returns empty
        hub.addBridge(address(dec1));  // slot 1 - no pools, arm returns empty
        hub.addBridge(address(br3));   // slot 2 - the third arm, the only route

        // -- SOLVE ----------------------------------------------------------
        RoutePlan memory plan = solver.findBestRoutePlan(address(A), address(B), AMT);
        assertEq(plan.best.hops.length, 2, "third arm must produce a 2-hop route");
        assertEq(plan.best.hops[0].tokenOut, address(br3), "hop 0 exits through the 3rd bridge");
        assertEq(plan.best.hops[1].tokenOut, address(B),   "hop 1 reaches the destination");
        assertFalse(plan.hasFallback, "only one viable topology (viaB3)");

        // -- EXECUTE ---------------------------------------------------------
        // Fee anchors on the first bridge coin the Router holds = hop 1 input (br3).
        uint256 bridgeReceived = BPC.outV2(AMT, R, R, 30);
        uint256 fee1 = BPC.mulDivUp(bridgeReceived, BPC.PROTOCOL_FEE_BPS, BPC.BPS);
        uint256 expectedDelivered = BPC.outV2(bridgeReceived - fee1, R, R, 30);

        vm.prank(user);
        uint256 delivered = router.swapBestExactIn(address(A), address(B), AMT, 1, user, block.timestamp + 1);

        assertEq(delivered, expectedDelivered, "3rd-bridge route must deliver the exact 2-hop output");
        assertEq(
            IERC20Bal(address(br3)).balanceOf(T1) + IERC20Bal(address(br3)).balanceOf(T2),
            fee1,
            "protocol fee lands in the 3rd bridge coin - proof the third arm executed"
        );
    }

    /// @notice Control: identical pools, but the third bridge is NEVER
    ///         registered (only the two decoys). The third arm reads
    ///         hub.bridge(2)==address(0) and is skipped, so no topology reaches
    ///         B. One respect differs: the third addBridge call.
    function test_Cell1_Control_ThirdBridgeUnregistered_NoRoute() public {
        _bootstrap();
        hub.addBridge(address(dec0));
        hub.addBridge(address(dec1));
        // br3 deliberately NOT registered.
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixSolver.SolverE.selector, uint16(5)));
        solver.findBestRoutePlan(address(A), address(B), AMT);
    }
}

// =============================================================================
//  CELL 2 - MULTI-HOP CROSSED WITH A SPLIT. Every executed split has been
//  single-hop; every executed multi-hop has one leg per hop. Here hop 1
//  (index 0) splits across two pools, and hop 2 (index 1) must spend what hop 1
//  ACTUALLY delivered (the measured bridge balance), never its planned leg
//  amountIn. Input token is registered as the bridge so the fee anchors on
//  hop 0 and leaves hop 1's delivery to hop 2 untouched - the cleanest form of
//  "actual, not planned".
//
//  Mechanism: BlazePhoenixRouter._hopScaleImpactAndQuote scales hop h>0 by the
//  MEASURED balance (realIn), BlazePhoenixRouter.sol:723-726.
// =============================================================================
contract UnvisitedCellsSplitMultiHopTest is Test {
    using RB for *;
    BlazePhoenixHub hub;
    BlazePhoenixRouter router;
    MockERC20 A; MockERC20 BR; MockERC20 B;
    MockV2Pair p1; MockV2Pair p2; MockV2Pair pBC;
    address user = address(0xBEEF);
    address constant T1 = address(0xFEE1);
    address constant T2 = address(0xFEE2);
    uint256 constant R = 10_000_000e18;
    uint256 constant AMT = 1_000e18;

    function _seed(MockV2Pair p, MockERC20 x, MockERC20 y, uint256 rx, uint256 ry) internal {
        x.mint(address(p), rx); y.mint(address(p), ry);
        (address t0,) = address(x) < address(y) ? (address(x), address(y)) : (address(y), address(x));
        p.setReserves(uint112(address(x) == t0 ? rx : ry), uint112(address(x) == t0 ? ry : rx));
    }

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        router = new BlazePhoenixRouter(address(hub), address(0xCAFE), address(this), T1, T2);
        A = new MockERC20("A", "A"); BR = new MockERC20("BR", "BR"); B = new MockERC20("B", "B");
        p1  = new MockV2Pair(address(A), address(BR));
        p2  = new MockV2Pair(address(A), address(BR));
        pBC = new MockV2Pair(address(BR), address(B));
        _seed(p1,  A, BR, R, R);
        _seed(p2,  A, BR, R, R);
        _seed(pBC, BR, B, R, R);
        // Input token IS the bridge => fee anchors on hop 0, hop 1's delivery
        // flows into hop 2 in full.
        hub.addBridge(address(A));
        A.mint(user, 10_000e18);
        vm.prank(user); A.approve(address(router), type(uint256).max);
    }

    // hop 0 (split across p1,p2) + hop 1 (single pBC). expectedOut=0 everywhere
    // so the floors rest on the in-frame measured quote (fail-open by design),
    // isolating the "measured vs planned" behaviour under test.
    function _route(Leg[] memory hop0Legs, uint256 hop1PlannedIn) internal view returns (Route memory r) {
        Leg[] memory l1 = new Leg[](1);
        l1[0] = RB.v2Leg(address(pBC), address(BR), address(B), hop1PlannedIn, 0);
        Hop[] memory hops = new Hop[](2);
        hops[0] = Hop({tokenIn: address(A),  tokenOut: address(BR), amountIn: AMT,           expectedOut: 0, legs: hop0Legs});
        hops[1] = Hop({tokenIn: address(BR), tokenOut: address(B),  amountIn: hop1PlannedIn, expectedOut: 0, legs: l1});
        r = Route({hops: hops, totalOut: 0, singleOut: 0, singleOutFloor: 0,
                   expectedImpactBps: 0, confidenceWad: 0, estGas: 0, hasSurplus: false, isV4Bundle: false});
    }

    /// @notice Positive: hop 1 splits AMT across two equal pools. The bridge
    ///         hop 1 really delivers is computed from the fee-reduced, split
    ///         inputs; hop 2 spends exactly that, so delivery matches the
    ///         ACTUAL bridge - and NOT the deliberately-wrong planned amount.
    function test_Cell2_SplitFirstHop_SecondHopSpendsActualDelivery() public {
        uint256 feeH = BPC.mulDivUp(AMT, BPC.PROTOCOL_FEE_BPS, BPC.BPS);
        uint256 net  = AMT - feeH;                        // input after the hop-0 fee
        uint256 legAmt = BPC.mulDiv(AMT / 2, net, AMT);   // each split leg, fee-scaled
        uint256 realBridge = 2 * BPC.outV2(legAmt, R, R, 30);   // what hop 1 ACTUALLY delivers
        uint256 expectedDelivered = BPC.outV2(realBridge, R, R, 30);

        // Plant a WRONG planned input on hop 2 (half the truth). The rescale to
        // the measured balance must override it entirely.
        uint256 planned = realBridge / 2;
        uint256 plannedDelivered = BPC.outV2(planned, R, R, 30);

        Leg[] memory hop0 = new Leg[](2);
        hop0[0] = RB.v2Leg(address(p1), address(A), address(BR), AMT / 2, 0);
        hop0[1] = RB.v2Leg(address(p2), address(A), address(BR), AMT / 2, 0);

        vm.prank(user);
        uint256 delivered = router.swapExactIn(_route(hop0, planned), AMT, 1, user, block.timestamp + 1);

        assertEq(delivered, expectedDelivered, "hop 2 must spend the MEASURED bridge from the split hop 1");
        assertTrue(delivered != plannedDelivered, "hop 2 must NOT honour the planned (wrong) input");
    }

    /// @notice Control: hop 1 is a SINGLE leg carrying the full AMT (one respect
    ///         differs: leg count). One deep leg has more impact than the split,
    ///         so it delivers less bridge and the route ends lower - proving the
    ///         split genuinely split.
    function test_Cell2_Control_SingleLegFirstHop_DeliversLess() public {
        uint256 feeH = BPC.mulDivUp(AMT, BPC.PROTOCOL_FEE_BPS, BPC.BPS);
        uint256 net  = AMT - feeH;
        uint256 realBridgeSingle = BPC.outV2(net, R, R, 30);
        uint256 expectedSingle   = BPC.outV2(realBridgeSingle, R, R, 30);

        uint256 legAmt = BPC.mulDiv(AMT / 2, net, AMT);
        uint256 expectedSplit = BPC.outV2(2 * BPC.outV2(legAmt, R, R, 30), R, R, 30);

        Leg[] memory hop0 = new Leg[](1);
        hop0[0] = RB.v2Leg(address(p1), address(A), address(BR), AMT, 0);

        vm.prank(user);
        uint256 delivered = router.swapExactIn(_route(hop0, realBridgeSingle), AMT, 1, user, block.timestamp + 1);

        assertEq(delivered, expectedSingle, "single-leg hop 1 delivers the exact single-pool output");
        assertLt(delivered, expectedSplit, "one deep leg must deliver LESS than the two-way split");
    }
}

// =============================================================================
//  CELL 3 - A HOP WITH MAX_LEGS_PER_HOP LEGS, EXECUTED, plus cap+1 refusal.
//  The per-hop budget array is sized for the cap (BlazePhoenixRouter.sol:136,
//  MAX_LEGS_PER_HOP=5) and has only ever run below it. Drive it AT the cap and
//  ONE over (RouterE(3), BlazePhoenixRouter.sol:1006).
// =============================================================================
contract UnvisitedCellsMaxLegsTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixRouter router;
    MockERC20 A; MockERC20 B;
    MockV2Pair[6] pools;
    address user = address(0xBEEF);
    address constant T1 = address(0xFEE1);
    address constant T2 = address(0xFEE2);
    uint256 constant R = 10_000_000e18;
    uint256 constant AMT = 1_000e18;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        router = new BlazePhoenixRouter(address(hub), address(0xCAFE), address(this), T1, T2);
        A = new MockERC20("A", "A"); B = new MockERC20("B", "B");
        for (uint256 i; i < 6; ++i) {
            MockV2Pair p = new MockV2Pair(address(A), address(B));
            A.mint(address(p), R); B.mint(address(p), R);
            (address t0,) = address(A) < address(B) ? (address(A), address(B)) : (address(B), address(A));
            p.setReserves(uint112(address(A) == t0 ? R : R), uint112(R));
            pools[i] = p;
        }
        A.mint(user, 10_000e18);
        vm.prank(user); A.approve(address(router), type(uint256).max);
    }

    function _route(uint256 legCount) internal view returns (Route memory r) {
        Leg[] memory legs = new Leg[](legCount);
        uint256 share = AMT / 5;   // sums to AMT for the 5-leg case
        for (uint256 i; i < legCount; ++i) {
            legs[i] = RB.v2Leg(address(pools[i]), address(A), address(B), share, 0);
        }
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({tokenIn: address(A), tokenOut: address(B), amountIn: AMT, expectedOut: 0, legs: legs});
        r = Route({hops: hops, totalOut: 0, singleOut: 0, singleOutFloor: 0,
                   expectedImpactBps: 0, confidenceWad: 0, estGas: 0, hasSurplus: false, isV4Bundle: false});
    }

    /// @notice Positive: a single hop with exactly MAX_LEGS_PER_HOP (5) equal
    ///         legs executes and delivers 5x the per-leg output at the
    ///         fee-scaled input. Exact number.
    function test_Cell3_FiveLegHop_Executes() public {
        uint256 feeH = BPC.mulDivUp(AMT, BPC.PROTOCOL_FEE_BPS, BPC.BPS);
        uint256 net = AMT - feeH;
        uint256 legAmt = BPC.mulDiv(AMT / 5, net, AMT);
        uint256 expected = 5 * BPC.outV2(legAmt, R, R, 30);

        vm.prank(user);
        uint256 delivered = router.swapExactIn(_route(5), AMT, 1, user, block.timestamp + 1);
        assertEq(delivered, expected, "5-leg hop must deliver 5x the fee-scaled per-leg output");
    }

    /// @notice Control: one more leg (6 == cap+1). One respect differs: leg
    ///         count. The Router refuses with RouterE(3) before touching a pool.
    function test_Cell3_Control_SixLegs_Refused() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, uint16(3)));
        router.swapExactIn(_route(6), AMT, 1, user, block.timestamp + 1);
    }
}

// =============================================================================
//  CELL 4 - SOLIDLY stable == true, EXECUTED. The stable branch of the curve
//  (BlazePhoenixCore.outSolidly stable path) has only ever been QUOTED. Execute
//  through it and assert delivery == the pool's own quote (minus the 1-wei
//  rounding armour the executor applies, BlazePhoenixRouter.sol:1631-1633).
// =============================================================================
contract UnvisitedCellsSolidlyStableTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixRouter router;
    MockERC20 A; MockERC20 B;
    MockSolidlyPair stablePair; MockSolidlyPair volPair;
    address user = address(0xBEEF);
    address constant T1 = address(0xFEE1);
    address constant T2 = address(0xFEE2);
    uint256 constant R = 100_000e18;
    uint256 constant AMT = 1_000e18;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        router = new BlazePhoenixRouter(address(hub), address(0xCAFE), address(this), T1, T2);
        A = new MockERC20("A", "A"); B = new MockERC20("B", "B");
        stablePair = new MockSolidlyPair(address(A), address(B), true);
        volPair    = new MockSolidlyPair(address(A), address(B), false);
        for (uint256 i; i < 2; ++i) {
            MockSolidlyPair p = i == 0 ? stablePair : volPair;
            A.mint(address(p), R); B.mint(address(p), R);
            (address t0,) = address(A) < address(B) ? (address(A), address(B)) : (address(B), address(A));
            p.setReserves(uint112(R), uint112(R));
            t0;
        }
        A.mint(user, 10_000e18);
        vm.prank(user); A.approve(address(router), type(uint256).max);
    }

    function _route(address pool, bool stable) internal view returns (Route memory r) {
        Leg[] memory legs = new Leg[](1);
        legs[0] = Leg({
            pool: pool, hooks: address(0), kind: BPC.KIND_SOLIDLY, fee: 30, tickSpacing: 0,
            zeroForOne: address(A) < address(B), stable: stable,
            amountIn: AMT, expectedOut: 0, auxId: bytes32(0)
        });
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({tokenIn: address(A), tokenOut: address(B), amountIn: AMT, expectedOut: 0, legs: legs});
        r = Route({hops: hops, totalOut: 0, singleOut: 0, singleOutFloor: 0,
                   expectedImpactBps: 0, confidenceWad: 0, estGas: 0, hasSurplus: false, isV4Bundle: false});
    }

    /// @notice Positive: a swap through a stable=true Solidly pool delivers the
    ///         stable-curve quote of the fee-scaled input, minus 1 wei.
    function test_Cell4_StableTrue_DeliveryMatchesQuote() public {
        uint256 feeH = BPC.mulDivUp(AMT, BPC.PROTOCOL_FEE_BPS, BPC.BPS);
        uint256 net = AMT - feeH;
        uint256 expected = BPC.outSolidly(net, R, R, 30, true) - 1;

        vm.prank(user);
        uint256 delivered = router.swapExactIn(_route(address(stablePair), true), AMT, 1, user, block.timestamp + 1);
        assertEq(delivered, expected, "stable-curve delivery must equal the stable quote minus 1 wei");
    }

    /// @notice Control: the same reserves/amount through a volatile pool (one
    ///         respect differs: the stable flag). The stable curve is deeper at
    ///         the peg, so it must deliver strictly MORE than the volatile one.
    function test_Cell4_Control_VolatileDiffers() public {
        uint256 feeH = BPC.mulDivUp(AMT, BPC.PROTOCOL_FEE_BPS, BPC.BPS);
        uint256 net = AMT - feeH;
        uint256 expectedVol    = BPC.outSolidly(net, R, R, 30, false) - 1;
        uint256 expectedStable = BPC.outSolidly(net, R, R, 30, true) - 1;

        vm.prank(user);
        uint256 delivered = router.swapExactIn(_route(address(volPair), false), AMT, 1, user, block.timestamp + 1);
        assertEq(delivered, expectedVol, "volatile delivery must equal the volatile quote minus 1 wei");
        assertGt(expectedStable, delivered, "stable curve must out-deliver volatile at the peg");
    }
}

// =============================================================================
//  CELL 5 - NATIVE DOOR crossed with a V4-NATIVE leg: the only shape with TWO
//  ETH<->WETH transitions. (1) swapExactInNative wraps msg.value once at entry;
//  (2) the KIND_V4_NATIVE leg unwraps inside unlockCallback's JIT seam to
//  settle in raw ETH. Existing native-V4 tests all enter through the WETH door
//  (swapExactIn), so the wrap-once accounting meeting the unwrap window is
//  unvisited.
// =============================================================================
contract UnvisitedCellsNativeV4Test is Test {
    BlazePhoenixHub hub;
    BlazePhoenixRouter router;
    MockWETH9 wethT;
    MockERC20 tok;
    MockV4ManagerNative mgr;
    address user = address(0xBEEF);
    uint24  constant FEE = 500;
    int24   constant TS  = 10;
    uint128 constant LIQ = 1e24;
    bytes32 pid;

    function _netIn(uint256 a) internal pure returns (uint256) { return a - (a * 28) / 10_000; }

    function setUp() public {
        mgr = new MockV4ManagerNative();
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(mgr));
        wethT = new MockWETH9();
        tok = new MockERC20("Token", "TOK");
        router = new BlazePhoenixRouter(address(hub), address(0xBEEF), address(this), address(0xFEE1), address(0xFEE2));
        router.setWeth(address(wethT));

        pid = BPC.computeV4PoolId(address(0), address(tok), FEE, TS, address(0));
        bytes32 base = keccak256(abi.encode(pid, uint256(6)));
        mgr.setSlot(base, bytes32(uint256(BPC.Q96)));
        mgr.setSlot(bytes32(uint256(base) + 3), bytes32(uint256(LIQ)));

        vm.deal(address(wethT), 1_000e18);
        vm.deal(address(mgr), 1_000e18);
        tok.mint(address(mgr), 1_000e18);
        wethT.mint(user, 100e18);
        vm.prank(user); wethT.approve(address(router), type(uint256).max);
    }

    function _nativeRoute(uint256 amountIn) internal view returns (Route memory route) {
        Leg[] memory legs = new Leg[](1);
        legs[0] = Leg({
            pool: address(uint160(uint256(pid))), hooks: address(0),
            kind: BPC.KIND_V4_NATIVE, fee: FEE, tickSpacing: TS,
            zeroForOne: true, stable: false,
            amountIn: amountIn, expectedOut: 0,
            auxId: bytes32(uint256(uint160(address(tok))))
        });
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({tokenIn: address(wethT), tokenOut: address(tok), amountIn: amountIn, expectedOut: 0, legs: legs});
        route = Route({hops: hops, totalOut: 0, singleOut: 0, singleOutFloor: 0,
                       expectedImpactBps: 0, confidenceWad: 0, estGas: 0, hasSurplus: false, isV4Bundle: false});
    }

    /// @notice Positive: enter through the native door with raw ETH. The Router
    ///         wraps once (transition 1), then the native-V4 leg unwraps to
    ///         settle in ETH (transition 2). Delivery equals the WETH-priced
    ///         quote of the fee-net input; the manager is settled in exactly
    ///         that many raw ETH; the Router keeps nothing.
    function test_Cell5_NativeDoor_V4NativeLeg_TwoTransitions() public {
        uint256 amt = 10e18;
        // MockV4ManagerNative fills 1:1 (honest), so the delivered token equals
        // the fee-net WETH that reached the manager. The outV3 curve figure is
        // only the QUOTE the floor/ExecutionProof use, not this mock's fill.
        uint256 expected = _netIn(amt);
        uint256 mgrEthBefore = address(mgr).balance;

        vm.deal(user, amt);
        vm.prank(user);
        uint256 delivered = router.swapExactInNative{value: amt}(_nativeRoute(amt), 1, user, block.timestamp + 1);

        assertEq(delivered, expected, "native door must deliver the fee-net WETH-priced quote");
        assertEq(tok.balanceOf(user), delivered, "user received tokenOut (started with 0 TOK)");
        // The JIT unwrap: manager settled in RAW ETH equal to the fee-net input.
        assertEq(address(mgr).balance, mgrEthBefore + _netIn(amt), "manager settled in raw ETH (the 2nd transition)");
        // Wrap-once accounting: nothing lodged in the Router.
        assertEq(address(router).balance, 0, "router holds no ETH");
        assertEq(wethT.balanceOf(address(router)), 0, "router holds no WETH");
        assertEq(tok.balanceOf(address(router)), 0, "router holds no TOK");
    }

    /// @notice Control: the identical route and amount through the WETH door
    ///         (pre-wrapped, one transition). One respect differs: how the WETH
    ///         arrives. Delivery must be byte-identical - the entry wrap adds
    ///         and loses nothing.
    function test_Cell5_Control_WethDoor_IdenticalDelivery() public {
        uint256 amt = 10e18;
        uint256 expected = _netIn(amt);   // 1:1 fill, same as the native door

        vm.prank(user);
        uint256 delivered = router.swapExactIn(_nativeRoute(amt), amt, 1, user, block.timestamp + 1);
        assertEq(delivered, expected, "WETH door delivers the same amount as the native door");
    }
}

// =============================================================================
//  CELL 6 - recipient == address(router): self-delivery meets the holds-nothing
//  DELTA accounting. `delivered` is measured as the recipient's balance CHANGE
//  (BlazePhoenixRouter.sol:1353-1355); a transfer to self changes nothing, so
//  the delta reads ZERO and the swap trips userMinOut (RouterE(5)). The
//  ambiguity between "delivered" and "swept" resolves to a hard refusal - the
//  finding.
// =============================================================================
contract UnvisitedCellsSelfRecipientTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixRouter router;
    MockERC20 A; MockERC20 B;
    MockV2Pair pool;
    address user = address(0xBEEF);
    address constant T1 = address(0xFEE1);
    address constant T2 = address(0xFEE2);
    uint256 constant R = 10_000_000e18;
    uint256 constant AMT = 1_000e18;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        router = new BlazePhoenixRouter(address(hub), address(0xCAFE), address(this), T1, T2);
        A = new MockERC20("A", "A"); B = new MockERC20("B", "B");
        pool = new MockV2Pair(address(A), address(B));
        A.mint(address(pool), R); B.mint(address(pool), R);
        pool.setReserves(uint112(R), uint112(R));
        A.mint(user, 10_000e18);
        vm.prank(user); A.approve(address(router), type(uint256).max);
    }

    function _route() internal view returns (Route memory r) {
        Leg[] memory legs = new Leg[](1);
        legs[0] = RB.v2Leg(address(pool), address(A), address(B), AMT, 0);
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({tokenIn: address(A), tokenOut: address(B), amountIn: AMT, expectedOut: 0, legs: legs});
        r = Route({hops: hops, totalOut: 0, singleOut: 0, singleOutFloor: 0,
                   expectedImpactBps: 0, confidenceWad: 0, estGas: 0, hasSurplus: false, isV4Bundle: false});
    }

    /// @notice FINDING: recipient == the Router itself. The output is already
    ///         in the Router, so the self-transfer produces a zero balance
    ///         delta and the swap reverts RouterE(5) on userMinOut - self
    ///         delivery is impossible, not silently swept.
    function test_Cell6_RecipientIsRouter_RevertsFromZeroDelta() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, uint16(5)));
        router.swapExactIn(_route(), AMT, 1, address(router), block.timestamp + 1);
    }

    /// @notice Control: a normal EOA recipient (one respect differs). The exact
    ///         same swap succeeds and delivers the fee-scaled single-pool output.
    function test_Cell6_Control_NormalRecipient_Delivers() public {
        uint256 feeH = BPC.mulDivUp(AMT, BPC.PROTOCOL_FEE_BPS, BPC.BPS);
        uint256 expected = BPC.outV2(AMT - feeH, R, R, 30);
        vm.prank(user);
        uint256 delivered = router.swapExactIn(_route(), AMT, 1, user, block.timestamp + 1);
        assertEq(delivered, expected, "a normal recipient receives the exact output");
    }
}

// =============================================================================
//  CELL 7 - DECLARED kinds 3, 9 and 255 at a door. Kinds 2 and 7 are pinned
//  dead (test/hunt/ResidualApproval.t.sol). These are not: 3 is a tombstone, 9
//  and 255 are undefined (above KIND_V4_NATIVE=8). All resolve theta==0
//  (BlazePhoenixCore.thetaOf, fail-closed) and fall into the dispatch `else`
//  (BlazePhoenixRouter.sol:1455, RouterE(8)). We use a REAL A/B pool so the
//  leg-homogeneity guard PASSES and the DISPATCH - not the admission guard -
//  is what refuses; and we prove the input is not stranded (full rollback).
// =============================================================================
contract UnvisitedCellsBadKindTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixRouter router;
    MockERC20 A; MockERC20 B;
    MockV2Pair pool;
    address user = address(0xBEEF);
    address constant T1 = address(0xFEE1);
    address constant T2 = address(0xFEE2);
    uint256 constant R = 10_000_000e18;
    uint256 constant AMT = 1_000e18;
    uint256 userStart;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        router = new BlazePhoenixRouter(address(hub), address(0xCAFE), address(this), T1, T2);
        A = new MockERC20("A", "A"); B = new MockERC20("B", "B");
        pool = new MockV2Pair(address(A), address(B));
        A.mint(address(pool), R); B.mint(address(pool), R);
        pool.setReserves(uint112(R), uint112(R));
        userStart = 10_000e18;
        A.mint(user, userStart);
        vm.prank(user); A.approve(address(router), type(uint256).max);
    }

    function _route(uint8 kind) internal view returns (Route memory r) {
        Leg[] memory legs = new Leg[](1);
        legs[0] = Leg({
            pool: address(pool), hooks: address(0), kind: kind, fee: 30, tickSpacing: 0,
            zeroForOne: address(A) < address(B), stable: false,
            amountIn: AMT, expectedOut: 0, auxId: bytes32(0)
        });
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({tokenIn: address(A), tokenOut: address(B), amountIn: AMT, expectedOut: 0, legs: legs});
        r = Route({hops: hops, totalOut: 0, singleOut: 0, singleOutFloor: 0,
                   expectedImpactBps: 0, confidenceWad: 0, estGas: 0, hasSurplus: false, isV4Bundle: false});
    }

    function _expectRefusalAndNoStranding(uint8 kind) internal {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, uint16(8)));
        router.swapExactIn(_route(kind), AMT, 1, user, block.timestamp + 1);
        // Full rollback: the input never left the user, nothing stranded.
        assertEq(A.balanceOf(user), userStart, "input must not be stranded in the Router");
        assertEq(A.balanceOf(address(router)), 0, "Router holds no input after refusal");
    }

    function test_Cell7_Kind3_DispatchRefuses()   public { _expectRefusalAndNoStranding(3); }
    function test_Cell7_Kind9_DispatchRefuses()   public { _expectRefusalAndNoStranding(9); }
    function test_Cell7_Kind255_DispatchRefuses() public { _expectRefusalAndNoStranding(255); }

    /// @notice Control: the SAME real pool declared as KIND_V2 (0). One respect
    ///         differs: the kind field. It executes and delivers the exact
    ///         fee-scaled output - proving the kind alone drives the refusal.
    function test_Cell7_Control_Kind0_Executes() public {
        uint256 feeH = BPC.mulDivUp(AMT, BPC.PROTOCOL_FEE_BPS, BPC.BPS);
        uint256 expected = BPC.outV2(AMT - feeH, R, R, 30);
        vm.prank(user);
        uint256 delivered = router.swapExactIn(_route(BPC.KIND_V2), AMT, 1, user, block.timestamp + 1);
        assertEq(delivered, expected, "KIND_V2 on the same pool executes normally");
    }
}
