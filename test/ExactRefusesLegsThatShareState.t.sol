// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// The exact doors price every leg of a route against the state before the swap
// (`Quoter._exact`): each V4 leg in its own reverting `unlock`, each V2 leg by a view formula.
// The Router runs the legs in turn, so a leg priced on state another leg of the same route
// moves was not measured. `_legsShareState` names that state: the same pool anywhere in the
// route (a cyclic route meets its own pool again on the next hop), or the same hook when it
// runs in the swap (bits 0xCC), in one hop or in two. Such a route has no exact figure.
// Declared limits, not refused here (SHARED_QUANTITIES, `_legsShareState` row): two
// different hooks, a hook of liquidity only, one external venue behind two wrappers.

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixQuoter, IV4Q} from "../src/BlazePhoenixQuoter.sol";
import {BlazePhoenixCore as BPC, Route, RoutePlan, Hop, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";
import {Origin} from "./mocks/MockOriginFactory.sol";
import {MockHubQ, MockSolverQ, IUnlockCbQ} from "./QuoterExactRefusalBranches.t.sol";

/// @dev A V4 manager that answers any key: out = 99% of the input. The refusal under test
///      reads only the legs' pool and hooks fields, so the price is a stand-in.
contract AnyKeyV4Manager {
    function unlock(bytes calldata data) external returns (bytes memory) {
        IUnlockCbQ(msg.sender).unlockCallback(data);
        revert("AnyKeyV4Manager: callback returned");
    }

    function swap(IV4Q.V4PoolKey memory, IV4Q.SwapParams memory p, bytes calldata)
        external pure returns (int256)
    {
        int256 outD = (-p.amountSpecified * 99) / 100;
        (int256 d0, int256 d1) = p.zeroForOne ? (p.amountSpecified, outD) : (outD, p.amountSpecified);
        return int256((uint256(uint128(int128(d0))) << 128) | uint256(uint128(int128(d1))));
    }
}

contract ExactRefusesLegsThatShareStateTest is Test {
    BlazePhoenixQuoter quoter;
    MockHubQ hub;
    MockERC20 tokA;
    MockERC20 tokB;
    MockERC20 tokC;

    uint256 constant AMT = 1_000e18;
    // Permission bits live in the low 14 address bits. 0xCC = the bits that run in the swap.
    address constant HOOK_AFTER = address(uint160(0xBEEF0000 + (1 << 6)));  // afterSwap, no delta
    address constant HOOK_AFTER_2 = address(uint160(0xCAFE0000 + (1 << 6)));
    address constant HOOK_LIQ = address(uint160(0xBEEF0000 + (1 << 11)));   // beforeAddLiquidity only

    function setUp() public {
        tokA = new MockERC20("A", "A");
        tokB = new MockERC20("B", "B");
        tokC = new MockERC20("C", "C");
        hub = new MockHubQ();
        hub.setV4PoolManager(address(new AnyKeyV4Manager()));
        quoter = new BlazePhoenixQuoter(address(hub), address(new MockSolverQ()));
    }

    /// @dev A well-formed V4 leg from `tIn` to `tOut`: `pool` is the poolId its key derives to.
    function _v4(address tIn, address tOut, uint24 fee, int24 ts, address hooks, uint256 amt)
        internal pure returns (Leg memory l)
    {
        (address c0, address c1) = BPC.sortTokens(tIn, tOut);
        l = Leg({
            pool: address(uint160(uint256(BPC.computeV4PoolId(c0, c1, fee, ts, hooks)))),
            hooks: hooks, kind: BPC.KIND_V4, fee: fee, tickSpacing: ts, zeroForOne: tIn == c0,
            stable: false, amountIn: amt, expectedOut: 1, auxId: bytes32(uint256(uint160(tOut)))
        });
    }

    function _route(Hop[] memory hs) internal pure returns (Route memory) {
        return Route({hops: hs, totalOut: 0, singleOut: 0, singleOutFloor: 0, expectedImpactBps: 0,
            confidenceWad: 0, estGas: 0, hasSurplus: false, isV4Bundle: false});
    }

    /// @dev One hop A->B, two V4 pools of the pair (fees 3000 and 500), hooks `h0` and `h1`.
    function _oneHopTwoPools(address h0, address h1, uint256 amt, bool swapOrder)
        internal view returns (Route memory)
    {
        Leg[] memory ls = new Leg[](2);
        Leg memory a = _v4(address(tokA), address(tokB), 3000, 60, h0, amt / 2);
        Leg memory b = _v4(address(tokA), address(tokB), 500, 10, h1, amt - amt / 2);
        (ls[0], ls[1]) = swapOrder ? (b, a) : (a, b);
        Hop[] memory hs = new Hop[](1);
        hs[0] = Hop({tokenIn: address(tokA), tokenOut: address(tokB), amountIn: amt, expectedOut: 0, legs: ls});
        return _route(hs);
    }

    /// @dev Two hops A->B->C, one V4 leg each, behind hooks `h0` and `h1`.
    function _twoHops(address h0, address h1) internal view returns (Route memory) {
        Leg[] memory l0 = new Leg[](1);
        l0[0] = _v4(address(tokA), address(tokB), 3000, 60, h0, AMT);
        Leg[] memory l1 = new Leg[](1);
        l1[0] = _v4(address(tokB), address(tokC), 3000, 60, h1, (AMT * 99) / 100);
        Hop[] memory hs = new Hop[](2);
        hs[0] = Hop({tokenIn: address(tokA), tokenOut: address(tokB), amountIn: AMT, expectedOut: 0, legs: l0});
        hs[1] = Hop({tokenIn: address(tokB), tokenOut: address(tokC), amountIn: (AMT * 99) / 100,
            expectedOut: 0, legs: l1});
        return _route(hs);
    }

    function _exactOut(Route memory r, uint256 amt) internal returns (uint256 exactOut) {
        (, exactOut) = quoter.previewRouteExact(r, amt);
    }

    /// @notice Two pools behind one hook that runs in the swap: the hook's state, moved by the
    ///         first leg, prices the second. No exact figure.
    function test_TwoPoolsBehindOneSwapHook_HaveNoExactFigure() public {
        assertTrue(BPC.hookRunsInSwap(HOOK_AFTER) && !BPC.hookAltersDeltas(HOOK_AFTER), "premise: a quoted swap hook");
        assertGt(_exactOut(_oneHopTwoPools(HOOK_AFTER, HOOK_LIQ, AMT, false), AMT), 0,
            "control: each pool alone is quoted");
        assertEq(_exactOut(_oneHopTwoPools(HOOK_AFTER, HOOK_AFTER, AMT, false), AMT), 0,
            "two legs behind one swap hook were priced side by side");
    }

    /// @notice The same hook on hop 0 and on hop 1.
    function test_TwoHopsBehindOneSwapHook_HaveNoExactFigure() public {
        assertGt(_exactOut(_twoHops(HOOK_AFTER, HOOK_AFTER_2), AMT), 0, "control: different hooks keep the figure");
        assertEq(_exactOut(_twoHops(HOOK_AFTER, HOOK_AFTER), AMT), 0,
            "one swap hook on both hops was priced side by side");
    }

    /// @notice Controls: the refusal does not fire on state the legs do not share.
    function test_TwoHooklessV4Pools_KeepTheExactFigure() public {
        assertGt(_exactOut(_oneHopTwoPools(address(0), address(0), AMT, false), AMT), 0,
            "two hookless pools share no state");
    }

    function test_TwoPoolsBehindAHookThatDoesNotRunInSwap_KeepTheExactFigure() public {
        assertFalse(BPC.hookRunsInSwap(HOOK_LIQ), "premise: no swap bit");
        assertGt(_exactOut(_oneHopTwoPools(HOOK_LIQ, HOOK_LIQ, AMT, false), AMT), 0,
            "a hook of liquidity only is not moved by the swap");
    }

    /// @dev Pins the declared limit: two different swap hooks are not refused.
    function test_TwoPoolsBehindDifferentSwapHooks_KeepTheExactFigure() public {
        assertGt(_exactOut(_oneHopTwoPools(HOOK_AFTER, HOOK_AFTER_2, AMT, false), AMT), 0,
            "different hooks: declared limit, not refused");
    }

    /// @notice The refusal has no threshold: it holds at every size and in either leg order.
    function testFuzz_SharedStateRefusal_HoldsAtEverySizeAndLegOrder(uint128 amt, bool swapOrder) public {
        amt = uint128(bound(amt, 1_000, type(uint128).max));
        assertEq(_exactOut(_oneHopTwoPools(HOOK_AFTER, HOOK_AFTER, amt, swapOrder), amt), 0, "shared swap hook");
        assertGt(_exactOut(_oneHopTwoPools(HOOK_AFTER, HOOK_AFTER_2, amt, swapOrder), amt), 0, "control");
    }

    /// @notice Property: a well-ordered route has a figure iff no two legs share a swap hook. The
    ///         oracle is written by cases over a small set, not by the contract's loop.
    function testFuzz_ExactFigureImpliesNoSharedState(uint8 i0, uint8 i1, bool twoHops) public {
        address[4] memory set = [address(0), HOOK_LIQ, HOOK_AFTER, HOOK_AFTER_2];
        address h0 = set[i0 % 4];
        address h1 = set[i1 % 4];
        bool shared = h0 == h1 && (h0 == HOOK_AFTER || h0 == HOOK_AFTER_2);
        // The Router's own order rule, mirrored by `_hookRefusedIn`: no hookless leg after a hooked one.
        bool misordered = h0 != address(0) && h1 == address(0);
        Route memory r = twoHops ? _twoHops(h0, h1) : _oneHopTwoPools(h0, h1, AMT, false);
        assertEq(_exactOut(r, AMT) == 0, shared || misordered, "exact figure iff no shared state");
    }
}

/// @dev A cyclic route on a real Hub/Solver/Router: the same V2 pair on hop 0 and on hop 1.
contract ExactRefusesACyclicRouteTest is Test {
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

    function _pair(MockERC20 x, MockERC20 y) internal returns (MockV2Pair p) {
        p = new MockV2Pair(address(x), address(y));
        Origin.wire(hub, address(p), address(x), address(y), BPC.KIND_V2, 30);
        x.mint(address(p), RESERVE);
        y.mint(address(p), RESERVE);
        p.setReserves(RESERVE, RESERVE);
        for (uint256 i; i < 5; i++) {
            hub.recordSwap(address(p), BPC.KIND_V2, 30, address(0), address(x), address(y), 1e18, 1e18, RESERVE);
        }
    }

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0xBEEF));
        solver = new BlazePhoenixSolver(address(hub), address(0));
        quoter = new BlazePhoenixQuoter(address(hub), address(solver));
        router = new BlazePhoenixRouter(address(hub), address(solver), address(this), address(0x7451), address(0x7452));
        tA = new MockERC20("A", "A");
        tB = new MockERC20("B", "B");
        tC = new MockERC20("C", "C");
        hub.setRoles(address(this), address(solver), address(quoter));
        ab = _pair(tA, tB);
        bc = _pair(tB, tC);
        hub.setRoles(address(router), address(solver), address(quoter));
        hub.addBridge(address(tB));
        tA.mint(user, 10_000e18);
        vm.prank(user);
        tA.approve(address(router), type(uint256).max);
    }

    /// @dev A->B on `ab`, then B->`out` on `second`. Leg floors are 1 wei: the Router's own
    ///      checks are not under test, only the Quoter's scalar against the fill.
    function _hop1Through(MockV2Pair second, address out) internal view returns (Route memory route) {
        RoutePlan memory plan = solver.findBestRoutePlan(address(tA), address(tB), AMOUNT_IN);
        route = plan.best;
        assertEq(route.hops.length, 1, "premise: a direct route");
        assertEq(route.hops[0].legs[0].pool, address(ab), "premise: the leg is the pair");
        uint256 mid = route.hops[0].expectedOut;
        Leg[] memory l1 = new Leg[](1);
        l1[0] = Leg(address(second), address(0), BPC.KIND_V2, 30, 0, address(tB) < out, false, mid, 1, bytes32(0));
        Hop[] memory hs = new Hop[](2);
        hs[0] = route.hops[0];
        hs[1] = Hop({tokenIn: address(tB), tokenOut: out, amountIn: mid, expectedOut: 1, legs: l1});
        route.hops = hs;
        route.totalOut = 1;
    }

    function _fill(Route memory route, MockERC20 out) internal returns (uint256 delivered) {
        uint256 before = out.balanceOf(user);
        uint256 deadline = block.timestamp;
        vm.prank(user);
        router.swapExactIn(route, AMOUNT_IN, 1, user, deadline);
        // A cyclic route pays its input out of the same balance it is paid into.
        delivered = out.balanceOf(user) + (out == tA ? AMOUNT_IN : 0) - before;
    }

    /// @notice A cyclic route meets its own pool again on hop 1: no exact figure.
    function test_ACyclicRouteThroughOnePool_HasNoExactFigure() public {
        Route memory route = _hop1Through(ab, address(tA));
        (, uint256 exactOut) = quoter.previewRouteExact(route, AMOUNT_IN);
        uint256 snap = vm.snapshotState();
        assertGt(_fill(route, tA), 0, "control: the Router fills the cyclic route");
        vm.revertToState(snap);
        assertEq(exactOut, 0, "a pool met on two hops was priced on the state before both");
    }

    /// @notice Control: the twin route with another pair on hop 1 keeps a figure the Router honours.
    function test_TheTwinRouteThroughTwoPools_KeepsAFigureAtOrBelowDelivery() public {
        Route memory route = _hop1Through(bc, address(tC));
        (, uint256 exactOut) = quoter.previewRouteExact(route, AMOUNT_IN);
        uint256 delivered = _fill(route, tC);
        assertGt(exactOut, 0, "two pools share no state");
        assertLe(exactOut, delivered, "exactOut is a floor the Router honours in this block");
    }
}
