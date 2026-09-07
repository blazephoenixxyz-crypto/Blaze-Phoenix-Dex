// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  ROUTE SELF-CONSISTENCY, THE REMAINING FIELDS (follow-up to BPX-2026-009).
//
//  After the named-pool pin, two fields of a route were still taken at their
//  word by execution: a V4 leg's direction (its refusal lived in the manager's
//  settlement accounting, not in this code), and a pair leg's kind (a V2 pair
//  executed under the Solidly kind runs the other branch's arithmetic).
//
//    1. V4 direction: zeroForOne is derivable (true exactly when the input is
//       currency0), so a flipped direction is refused with RouterE(11) before
//       any token moves, and the Quoter refuses to price it. Red first: before
//       the pin the harness singleton refused the flipped leg with its own
//       settlement error, not with the Router's code.
//    2. Pair kind: measured, not pinned. A V2 pair run as Solidly settles and
//       delivers less than the honest route (the difference stays in the pair);
//       a V2 pair run as V3 reverts before any token moves. Both are the
//       caller's own signed fields (STEERING in the field register), bounded
//       by userMinOut; the measurements here keep the cost from drifting.
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixQuoter} from "../src/BlazePhoenixQuoter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {PricedV4Manager, FixedPlanSolver, HookDeployer} from "./RouteIntegrityV4.t.sol";

interface IERC20B { function balanceOf(address) external view returns (uint256); function transfer(address, uint256) external returns (bool); }

/// @dev A constant-product pair with the Uniswap V2 surface: reserves, a 30 bps
///      fee enforced through the K check, and the same swap signature Solidly pairs
///      expose - so a route may call it under either kind.
contract V2PairK {
    address public token0; address public token1;
    uint112 public reserve0; uint112 public reserve1;
    constructor(address a, address b) { (token0, token1) = a < b ? (a, b) : (b, a); }
    function factory() external view returns (address) { return address(this); }
    function sync() external { reserve0 = uint112(IERC20B(token0).balanceOf(address(this))); reserve1 = uint112(IERC20B(token1).balanceOf(address(this))); }
    function getReserves() external view returns (uint112, uint112, uint32) { return (reserve0, reserve1, 0); }
    function swap(uint256 a0, uint256 a1, address to, bytes calldata) external {
        require(a0 < reserve0 && a1 < reserve1, "K: liquidity");
        if (a0 > 0) IERC20B(token0).transfer(to, a0);
        if (a1 > 0) IERC20B(token1).transfer(to, a1);
        uint256 b0 = IERC20B(token0).balanceOf(address(this)); uint256 b1 = IERC20B(token1).balanceOf(address(this));
        uint256 in0 = b0 > reserve0 - a0 ? b0 - (reserve0 - a0) : 0;
        uint256 in1 = b1 > reserve1 - a1 ? b1 - (reserve1 - a1) : 0;
        require(in0 > 0 || in1 > 0, "K: no input");
        uint256 adj0 = b0 * 1000 - in0 * 3; uint256 adj1 = b1 * 1000 - in1 * 3;
        require(adj0 * adj1 >= uint256(reserve0) * uint256(reserve1) * 1_000_000, "K");
        reserve0 = uint112(b0); reserve1 = uint112(b1);
    }
}

contract RouteIntegrityFieldsTest is Test {
    BlazePhoenixHub hub; BlazePhoenixRouter router; PricedV4Manager mgr;
    MockERC20 tokA; MockERC20 tokB; address c0; address c1;
    address user = address(0xBEEF);
    uint24 constant FEE = 3000; int24 constant TS = 60; uint128 constant LIQ = 1e30;
    bytes32 pidA;
    address hookB; MockERC20 tokC;

    function setUp() public {
        mgr = new PricedV4Manager();
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(mgr));
        router = new BlazePhoenixRouter(address(hub), address(0xBEEF), address(this), address(0xFEE1), address(0xFEE2));
        tokA = new MockERC20("A", "A"); tokB = new MockERC20("B", "B");
        (c0, c1) = address(tokA) < address(tokB) ? (address(tokA), address(tokB)) : (address(tokB), address(tokA));
        pidA = BPC.computeV4PoolId(c0, c1, FEE, TS, address(0));
        bytes32 base = keccak256(abi.encode(pidA, uint256(6)));
        mgr.setSlot(base, bytes32(uint256(2 * BPC.Q96)));
        mgr.setSlot(bytes32(uint256(base) + 3), bytes32(uint256(LIQ)));
        mgr.setRate(pidA, 4000);
        hookB = new HookDeployer().deploy();
        hub.allowHook(hookB, true);
        tokC = new MockERC20("C", "C");
        tokC.mint(address(mgr), 1_000e18);
        MockERC20(c0).mint(user, 100e18); MockERC20(c1).mint(user, 100e18);
        MockERC20(c1).mint(address(mgr), 1_000e18); MockERC20(c0).mint(address(mgr), 1_000e18);
        vm.startPrank(user);
        MockERC20(c0).approve(address(router), type(uint256).max);
        MockERC20(c1).approve(address(router), type(uint256).max);
        vm.stopPrank();
    }

    function _v4Route(bool zfo, uint256 amt, uint256 attested) internal view returns (Route memory route) {
        Leg[] memory legs = new Leg[](1);
        legs[0] = Leg({ pool: address(uint160(uint256(pidA))), hooks: address(0), kind: BPC.KIND_V4, fee: FEE, tickSpacing: TS,
                        zeroForOne: zfo, stable: false, amountIn: amt, expectedOut: attested, auxId: bytes32(uint256(uint160(c1))) });
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({ tokenIn: c0, tokenOut: c1, amountIn: amt, expectedOut: attested, legs: legs });
        route = Route({ hops: hops, totalOut: attested, singleOut: attested, singleOutFloor: 0, expectedImpactBps: 0, confidenceWad: 0,
                        estGas: 0, hasSurplus: false, isV4Bundle: false });
    }

    // ── 1. V4 direction ──────────────────────────────────────────────────────

    function test_V4_HonestDirection_Settles() public {
        uint256 amt = 1e18;
        vm.prank(user);
        uint256 got = router.swapExactIn(_v4Route(true, amt, amt), amt, 1, user, block.timestamp + 1);
        assertGt(got, 3 * amt, "c0 -> c1 at about 4:1");
    }

    /// The input is currency0, the leg says it is not. Before the pin the harness
    /// singleton refused with its own settlement error; now the Router refuses first.
    function test_V4_FlippedDirection_IsRefused() public {
        uint256 amt = 1e18;
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, uint16(11)));
        router.swapExactIn(_v4Route(false, amt, amt), amt, 1, user, block.timestamp + 1);
    }

    /// The Quoter's dry run prices a leg in the direction the leg claims; a flipped
    /// direction would price the inverse of the pool (about 1:4) under the plan's
    /// c0 -> c1 identity. It is refused and the preview holds the plan's own point.
    function test_Quoter_FlippedDirection_IsNotPriced() public {
        uint256 amt = 1e18;
        FixedPlanSolver solver = new FixedPlanSolver();
        BlazePhoenixQuoter quoter = new BlazePhoenixQuoter(address(hub), address(solver));
        solver.setPlan(_v4Route(true, amt, 4 * amt));
        (, uint256 exactHonest) = quoter.previewPlanExact(c0, c1, amt);
        assertGt(exactHonest, 3 * amt, "sanity: the dry run is live and prices c0 -> c1");
        solver.setPlan(_v4Route(false, amt, 4 * amt));
        (, uint256 exactFlipped) = quoter.previewPlanExact(c0, c1, amt);
        assertGt(exactFlipped, 3 * amt, "held at the plan's point, not priced as c1 -> c0");
    }

    /// @dev seeds a V4 pool at price 1 with deep liquidity and a 1:1 fill
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

    function _oneHop(address tIn, address tOut, Leg[] memory legs, uint256 amt, uint256 attested) internal pure returns (Route memory route) {
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({ tokenIn: tIn, tokenOut: tOut, amountIn: amt, expectedOut: attested, legs: legs });
        route = Route({ hops: hops, totalOut: attested, singleOut: attested, singleOutFloor: 0, expectedImpactBps: 0, confidenceWad: 0,
                        estGas: 0, hasSurplus: false, isV4Bundle: false });
    }

    function _refused11(Route memory r, uint256 amt) internal {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, uint16(11)));
        router.swapExactIn(r, amt, 1, user, block.timestamp + 1);
    }

    // ── 1b. The mirror: the same pool traded c1 -> c0 ─────────────────────────

    function test_V4_Mirror_HonestDirection_Settles() public {
        uint256 amt = 1e18; uint256 q = BPC.v4LegOut(address(mgr), pidA, amt, FEE, TS, false);
        Leg[] memory legs = new Leg[](1); legs[0] = _leg(pidA, address(0), FEE, TS, false, c0, amt, q);
        Route memory r = _oneHop(c1, c0, legs, amt, q);
        vm.prank(user);
        uint256 got = router.swapExactIn(r, amt, 1, user, block.timestamp + 1);
        assertGt(got, amt / 5, "c1 -> c0 at about 1:4");
        assertLt(got, amt * 3 / 10, "and not at the c0 -> c1 price");
    }

    function test_V4_Mirror_FlippedDirection_IsRefused() public {
        uint256 amt = 1e18;
        Leg[] memory legs = new Leg[](1); legs[0] = _leg(pidA, address(0), FEE, TS, true, c0, amt, amt / 4);
        _refused11(_oneHop(c1, c0, legs, amt, amt / 4), amt);
    }

    // ── 1c. Every other field of the key, one at a time ───────────────────────

    function test_V4_SwappedFee_RouteNamesPoolA_IsRefused() public {
        uint256 amt = 1e18;
        _seedUnit(BPC.computeV4PoolId(c0, c1, 500, TS, address(0)));   // the sibling exists
        Leg[] memory legs = new Leg[](1); legs[0] = _leg(pidA, address(0), 500, TS, true, c1, amt, amt);
        _refused11(_oneHop(c0, c1, legs, amt, amt), amt);
    }

    /// The counterpart token swapped for a third token, with the hop's output swapped
    /// to match: the pair passes the hop check, the key derives (c0, C), the leg names A.
    function test_V4_SwappedCounterpart_RouteNamesPoolA_IsRefused() public {
        uint256 amt = 1e18;
        (address d0, address d1) = BPC.sortTokens(c0, address(tokC));
        _seedUnit(BPC.computeV4PoolId(d0, d1, FEE, TS, address(0)));
        Leg[] memory legs = new Leg[](1);
        legs[0] = _leg(pidA, address(0), FEE, TS, c0 == d0, address(tokC), amt, amt);
        _refused11(_oneHop(c0, address(tokC), legs, amt, amt), amt);
    }

    // ── 1d. Macro: the lie sits in the second hop, or in one leg of a split ───

    function test_TwoHops_LieInSecondHop_NothingMoves() public {
        uint256 amt = 1e18;
        V2PairK pair = _newPair();                                   // hop 1: c0 -> c1, honest
        (address d0, address d1) = BPC.sortTokens(c1, address(tokC));
        bytes32 pid2 = BPC.computeV4PoolId(d0, d1, FEE, TS, address(0));
        _seedUnit(pid2);                                             // hop 2: c1 -> C, the pool named
        Leg[] memory l1 = new Leg[](1);
        l1[0] = Leg({ pool: address(pair), hooks: address(0), kind: BPC.KIND_V2, fee: 30, tickSpacing: 0,
                      zeroForOne: c0 == pair.token0(), stable: false, amountIn: amt, expectedOut: 0, auxId: bytes32(0) });
        Leg[] memory l2 = new Leg[](1);
        l2[0] = _leg(pid2, address(0), FEE, 10, c1 == d0, address(tokC), amt * 99 / 100, 0);   // tick spacing lied
        Hop[] memory hops = new Hop[](2);
        hops[0] = Hop({ tokenIn: c0, tokenOut: c1, amountIn: amt, expectedOut: 0, legs: l1 });
        hops[1] = Hop({ tokenIn: c1, tokenOut: address(tokC), amountIn: amt * 99 / 100, expectedOut: 0, legs: l2 });
        Route memory r = Route({ hops: hops, totalOut: 0, singleOut: 0, singleOutFloor: 0, expectedImpactBps: 0, confidenceWad: 0,
                                 estGas: 0, hasSurplus: false, isV4Bundle: false });
        uint256 u0 = IERC20B(c0).balanceOf(user); (uint112 r0, uint112 r1, ) = pair.getReserves();
        _refused11(r, amt);
        (uint112 r0b, uint112 r1b, ) = pair.getReserves();
        assertEq(IERC20B(c0).balanceOf(user), u0, "the caller's input did not move");
        assertTrue(r0 == r0b && r1 == r1b, "the first hop's pair was not traded");
        assertEq(IERC20B(c1).balanceOf(address(router)), 0, "nothing stranded in the Router");
    }

    function test_Split_OneLyingLeg_NothingMoves() public {
        uint256 amt = 1e18;
        bytes32 pidSib = BPC.computeV4PoolId(c0, c1, 500, 10, address(0));
        _seedUnit(pidSib);
        Leg[] memory legs = new Leg[](2);
        legs[0] = _leg(pidA, address(0), FEE, TS, true, c1, amt / 2, 0);        // honest
        legs[1] = _leg(pidA, address(0), 500, 10, true, c1, amt / 2, 0);        // executes the sibling, names A
        uint256 u0 = IERC20B(c0).balanceOf(user);
        _refused11(_oneHop(c0, c1, legs, amt, 0), amt);
        assertEq(IERC20B(c0).balanceOf(user), u0, "the caller's input did not move");
    }

    // ── 1e. Meta: accepted if and only if every field agrees ──────────────────

    /// One lie at a time, over the pool key's whole grid and both directions: a leg
    /// settles exactly when its named pool and its direction agree with its fields.
    function testFuzz_V4Leg_AcceptedIffFieldsAgree(uint8 feeSel, uint8 tsSel, bool hooked, bool mirror, uint8 lieSel) public {
        uint24[3] memory fees = [uint24(500), uint24(3000), uint24(10000)];
        int24[3] memory tss = [int24(10), int24(60), int24(200)];
        uint24 fee = fees[feeSel % 3]; int24 ts = tss[tsSel % 3];
        address hooks = hooked ? hookB : address(0);
        bytes32 pid = BPC.computeV4PoolId(c0, c1, fee, ts, hooks);
        _seedUnit(pid);
        address tIn = mirror ? c1 : c0; address tOther = mirror ? c0 : c1; bool zfo = !mirror;
        uint256 amt = 1e18;
        Leg memory leg = _leg(pid, hooks, fee, ts, zfo, tOther, amt, amt);
        uint8 lie = lieSel % 6;
        if (lie == 1) leg.pool = address(uint160(leg.pool) ^ 1);
        if (lie == 2) leg.fee = fee == 500 ? 3000 : 500;
        if (lie == 3) leg.tickSpacing = ts == 10 ? int24(60) : int24(10);
        if (lie == 4) leg.hooks = hooked ? address(0) : hookB;
        if (lie == 5) leg.zeroForOne = !zfo;
        Leg[] memory legs = new Leg[](1); legs[0] = leg;
        Route memory r = _oneHop(tIn, tOther, legs, amt, amt);
        if (lie == 0) {
            vm.prank(user);
            uint256 got = router.swapExactIn(r, amt, 1, user, block.timestamp + 1);
            assertGt(got, amt * 9 / 10, "a consistent leg settles at the pool's price");
        } else {
            _refused11(r, amt);
        }
    }

    // ── 2. Pair kind (measured) ─────────────────────────────────────────────

    function _pairRoute(V2PairK pair, uint8 kind, uint256 amt) internal view returns (Route memory route) {
        Leg[] memory legs = new Leg[](1);
        legs[0] = Leg({ pool: address(pair), hooks: address(0), kind: kind, fee: 30, tickSpacing: 0,
                        zeroForOne: c0 == pair.token0(), stable: false, amountIn: amt, expectedOut: 0, auxId: bytes32(0) });
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({ tokenIn: c0, tokenOut: c1, amountIn: amt, expectedOut: 0, legs: legs });
        route = Route({ hops: hops, totalOut: 0, singleOut: 0, singleOutFloor: 0, expectedImpactBps: 0, confidenceWad: 0,
                        estGas: 0, hasSurplus: false, isV4Bundle: false });
    }

    function _newPair() internal returns (V2PairK pair) {
        pair = new V2PairK(c0, c1);
        MockERC20(c0).mint(address(pair), 1_000e18); MockERC20(c1).mint(address(pair), 1_000e18);
        pair.sync();
    }

    /// A V2 pair executed under the Solidly kind: the pair's own getAmountOut does not
    /// exist, so the Router prices the leg with the Solidly curve at the fee ceiling and
    /// a 2 % haircut, and asks the pair for that smaller amount. It settles; the caller
    /// receives less than the honest route and the difference stays in the pair.
    function test_PairKindLie_V2AsSolidly_SettlesForLess() public {
        uint256 amt = 1e18;
        V2PairK honest = _newPair(); V2PairK lied = _newPair();
        Route memory rHonest = _pairRoute(honest, BPC.KIND_V2, amt);
        Route memory rLie = _pairRoute(lied, BPC.KIND_SOLIDLY, amt);
        vm.prank(user);
        uint256 gotHonest = router.swapExactIn(rHonest, amt, 1, user, block.timestamp + 1);
        vm.prank(user);
        uint256 gotLie = router.swapExactIn(rLie, amt, 1, user, block.timestamp + 1);
        assertLt(gotLie, gotHonest, "the kind lie delivers less than the honest route");
        assertGe(gotLie, gotHonest * 95 / 100, "and not more than five percent less (measured cost of the lie)");
    }

    /// A V2 pair executed under the V3 kind: the pair has no V3 swap selector, so the
    /// call reverts before any token moves.
    function test_PairKindLie_V2AsV3_Reverts() public {
        uint256 amt = 1e18;
        V2PairK pair = _newPair();
        uint256 before = IERC20B(c0).balanceOf(user);
        Route memory r = _pairRoute(pair, BPC.KIND_V3, amt);
        vm.prank(user);
        vm.expectRevert();
        router.swapExactIn(r, amt, 1, user, block.timestamp + 1);
        assertEq(IERC20B(c0).balanceOf(user), before, "nothing moved");
    }
}
