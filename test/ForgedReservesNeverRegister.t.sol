// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// A pair that proves its tokens but reports reserves it does not hold reached the registry
// through the swap door: one dust swap it settled honestly, and it held a seat on the pair at
// the reserves it declared (duxun D1). The swap door now reads the pair after the swap and
// registers a reserve-shaped pool only when neither reserve exceeds what it holds
// (Core.reservesHeld). The swap itself is never refused over a registry decision.

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg, PoolInfo} from "src/BlazePhoenixCore.sol";
import {BlazePhoenixHub} from "src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "src/BlazePhoenixRouter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";
import {MockV3Pool} from "./mocks/MockV3Pool.sol";

interface IERC20Bal {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}

/// Honest tokens, reserves = live holdings + a declared offset per side, pays from holdings.
/// Offset 0 on both sides is an honest pair read right after its sync.
contract ForgeablePair {
    address public immutable token0;
    address public immutable token1;
    int256 public off0;
    int256 public off1;

    constructor(address a, address b) {
        (token0, token1) = a < b ? (a, b) : (b, a);
    }

    function setOffsets(int256 o0, int256 o1) external { off0 = o0; off1 = o1; }

    function getReserves() external view returns (uint112, uint112, uint32) {
        int256 r0 = int256(IERC20Bal(token0).balanceOf(address(this))) + off0;
        int256 r1 = int256(IERC20Bal(token1).balanceOf(address(this))) + off1;
        return (uint112(uint256(r0 < 0 ? int256(0) : r0)), uint112(uint256(r1 < 0 ? int256(0) : r1)), 0);
    }

    function swap(uint256 a0, uint256 a1, address to, bytes calldata) external {
        if (a0 > 0) IERC20Bal(token0).transfer(to, a0);
        if (a1 > 0) IERC20Bal(token1).transfer(to, a1);
    }
}

/// A concentrated pool that also answers getReserves with a figure above what it holds.
/// Its mass is capped where its depth is read; the reserve rule is not its rule.
contract ConcWithReserves is MockV3Pool {
    constructor(address a, address b, uint24 f) MockV3Pool(a, b, f) {}
    function getReserves() external pure returns (uint112, uint112, uint32) {
        return (uint112(1e30), uint112(1e30), 0);
    }
}

contract ForgedReservesNeverRegisterTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixRouter router;
    MockERC20 ta;
    MockERC20 tb;
    address t0;
    address t1;
    address user = address(0xBEE);
    uint256 constant HOLD = 1e21;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        BlazePhoenixSolver solver = new BlazePhoenixSolver(address(hub));
        router = new BlazePhoenixRouter(address(hub), address(solver), address(this), address(0xFEE1), address(0xFEE2));
        hub.setRoles(address(router), address(solver), address(this));
        ta = new MockERC20("A", "A");
        tb = new MockERC20("B", "B");
        (t0, t1) = address(ta) < address(tb) ? (address(ta), address(tb)) : (address(tb), address(ta));
        MockERC20(t0).mint(user, 1e24);
        MockERC20(t1).mint(user, 1e24);
        vm.startPrank(user);
        MockERC20(t0).approve(address(router), type(uint256).max);
        MockERC20(t1).approve(address(router), type(uint256).max);
        vm.stopPrank();
    }

    function _pair(int256 o0, int256 o1) internal returns (ForgeablePair p) {
        p = new ForgeablePair(t0, t1);
        MockERC20(t0).mint(address(p), HOLD);
        MockERC20(t1).mint(address(p), HOLD);
        p.setOffsets(o0, o1);
    }

    function _hop(address pool, uint8 kind, uint24 fee, address tIn, address tOut, uint256 amt)
        internal pure returns (Hop memory)
    {
        Leg[] memory legs = new Leg[](1);
        legs[0] = Leg({pool: pool, hooks: address(0), kind: kind, fee: fee, tickSpacing: 0,
            zeroForOne: tIn < tOut, stable: false, amountIn: amt, expectedOut: 0, auxId: bytes32(0)});
        return Hop({tokenIn: tIn, tokenOut: tOut, amountIn: amt, expectedOut: 0, legs: legs});
    }

    function _route(Hop[] memory hops) internal pure returns (Route memory) {
        return Route({hops: hops, totalOut: 0, singleOut: 0, singleOutFloor: 0, expectedImpactBps: 0,
            confidenceWad: 0, estGas: 0, hasSurplus: false, isV4Bundle: false});
    }

    /// Swaps 1e6 of t0 through `pool` and returns what the user received in t1.
    function _swap(address pool, uint8 kind, uint24 fee) internal returns (uint256 got) {
        Hop[] memory hops = new Hop[](1);
        hops[0] = _hop(pool, kind, fee, t0, t1, 1e6);
        Route memory r = _route(hops);
        uint256 b = MockERC20(t1).balanceOf(user);
        vm.prank(user);
        router.swapExactIn(r, 1e6, 1, user, block.timestamp + 1);
        got = MockERC20(t1).balanceOf(user) - b;
    }

    function _registered(address pool) internal view returns (bool) {
        PoolInfo[] memory a = hub.getActivePools(t0, t1);
        for (uint256 i; i < a.length; i++) if (a[i].pool == pool) return true;
        return false;
    }

    function test_ForgedReserves_SwapSettles_PairNeverRegisters() public {
        ForgeablePair p = _pair(1e24, 1e24);
        assertGt(_swap(address(p), BPC.KIND_V2, 30), 0, "the swap itself settles");
        assertFalse(_registered(address(p)), "a pair reporting reserves it does not hold was registered");
    }

    function test_ForgedOnSideZeroOnly_NeverRegisters() public {
        ForgeablePair p = _pair(1, 0);
        assertGt(_swap(address(p), BPC.KIND_V2, 30), 0, "the swap itself settles");
        assertFalse(_registered(address(p)), "one wei of reserve0 above holdings was registered");
    }

    function test_ForgedOnSideOneOnly_NeverRegisters() public {
        ForgeablePair p = _pair(0, 1);
        assertGt(_swap(address(p), BPC.KIND_V2, 30), 0, "the swap itself settles");
        assertFalse(_registered(address(p)), "one wei of reserve1 above holdings was registered");
    }

    /// The legit neighbours: reserves exactly at holdings (a pair read right after its sync),
    /// and reserves below holdings (a donation not yet synced).
    function test_HonestPair_AtTheLimit_Registers() public {
        ForgeablePair p = _pair(0, 0);
        _swap(address(p), BPC.KIND_V2, 30);
        assertTrue(_registered(address(p)), "a pair holding exactly its reserves was refused");
    }

    function test_DonatedPair_Registers() public {
        ForgeablePair p = _pair(-1e18, -1e18);
        _swap(address(p), BPC.KIND_V2, 30);
        assertTrue(_registered(address(p)), "a pair holding more than its reserves was refused");
    }

    function test_SyncingMockPair_Registers() public {
        MockV2Pair p = new MockV2Pair(t0, t1);
        MockERC20(t0).mint(address(p), HOLD);
        MockERC20(t1).mint(address(p), HOLD);
        p.setReserves(uint112(HOLD), uint112(HOLD));
        _swap(address(p), BPC.KIND_V2, 30);
        assertTrue(_registered(address(p)), "an honest syncing pair was refused");
    }

    function test_SolidlyDeclared_ForgedReserves_NeverRegisters() public {
        ForgeablePair p = _pair(1e24, 1e24);
        _swap(address(p), BPC.KIND_SOLIDLY, 30); // the shape answers V2; the rule is the same
        assertFalse(_registered(address(p)), "a forged pair declared Solidly was registered");
    }

    /// The rule is for reserve-shaped pools: a concentrated pool that also answers getReserves
    /// above its holdings is judged where its depth is read, not here.
    function test_ConcentratedPool_AnsweringReserves_StillRegisters() public {
        ConcWithReserves c = new ConcWithReserves(t0, t1, 3000);
        c.setState(uint160(uint256(1) << 96), uint128(1e24));
        MockERC20(t0).mint(address(c), HOLD);
        MockERC20(t1).mint(address(c), HOLD);
        _swap(address(c), BPC.KIND_V3, 3000);
        assertTrue(_registered(address(c)), "a concentrated pool was judged by a reserve rule");
    }

    /// One more hop: an honest first hop registers in the same transaction in which a forged
    /// second hop does not, and the route settles.
    function test_TwoHops_HonestRegisters_ForgedDoesNot() public {
        ForgeablePair h = _pair(0, 0);
        ForgeablePair f = _pair(1e22, 0);
        Hop[] memory hops = new Hop[](2);
        hops[0] = _hop(address(h), BPC.KIND_V2, 30, t0, t1, 1e6);
        hops[1] = _hop(address(f), BPC.KIND_V2, 30, t1, t0, 1e6); // scaled to what hop 0 delivered
        Route memory r = _route(hops);
        uint256 b = MockERC20(t0).balanceOf(user);
        vm.prank(user);
        router.swapExactIn(r, 1e6, 1, user, block.timestamp + 1);
        assertGt(MockERC20(t0).balanceOf(user) + 1e6, b, "the route settles");
        assertTrue(_registered(address(h)), "the honest hop was refused");
        assertFalse(_registered(address(f)), "the forged hop was registered");
    }

    /// For any offsets: registered exactly when neither reserve exceeds holdings.
    function testFuzz_RegisteredIffReservesHeld(int256 o0, int256 o1) public {
        o0 = bound(o0, -1e20, 1e20);
        o1 = bound(o1, -1e20, 1e20);
        ForgeablePair p = _pair(o0, o1);
        _swap(address(p), BPC.KIND_V2, 30);
        assertEq(_registered(address(p)), o0 <= 0 && o1 <= 0, "registration must follow the holdings");
    }
}
