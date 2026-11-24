// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// A V4 leg may carry a price limit in the high bits of its auxId (bit 184 on, the limit tick
// in bits 160..183, `BPC.v4Limit`). Such a leg rides only as a hop's first leg, V4 and
// hookless, ahead of at least one exact leg. It spends out of the hop's whole input, window by
// window, never past its limit: up to the input its quote verified it always goes on; past it
// a window must pay the hop's bar above what its input is worth at the limit price. The exact
// legs share what it leaves, in their declared proportions.
//
// The book is a MockV4WindowManager: it honours sqrtPriceLimitX96 the way v4-core's Pool.swap
// does, nets what each unlock owes, and counts swaps and input per pool.

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";
import {HostileERC20} from "./mocks/HostileERC20.sol";
import {MockV4WindowManager} from "./mocks/MockV4WindowManager.sol";

contract V4PriceLimitedLegTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixRouter router;
    MockV4WindowManager mgr;

    address lo;
    address hi;
    address user = address(0xA11CE);

    uint24 constant FEE_LIM = 500;
    int24  constant TS_LIM  = 1;
    uint24 constant FEE_A   = 3000;
    int24  constant TS_A    = 60;
    uint24 constant FEE_B   = 10000;
    int24  constant TS_B    = 200;

    uint128 constant L_THICK = 3e20;   // [-512, 256): about 3.87e18 of input per 256-tick window
    uint128 constant L_THIN  = 1e16;   // [-4096, -512)
    uint128 constant L_WIDE  = 1e24;

    uint256 constant AMT   = 10e18;
    uint256 constant LIM_IN = 4e18;    // the limited leg's declared input: its floor
    uint256 constant A_IN  = 6e18;
    uint256 constant B_IN  = 4e18;     // A_IN + B_IN == AMT: the hop's commitment

    bytes32 pidLim;
    bytes32 pidA;
    bytes32 pidB;

    function setUp() public {
        mgr = new MockV4WindowManager();
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(mgr));
        router = new BlazePhoenixRouter(
            address(hub), address(0xBEEF), address(this), address(0xFEE1), address(0xFEE2)
        );
        MockERC20 tA = new MockERC20("Limited A", "LMA");
        MockERC20 tB = new MockERC20("Limited B", "LMB");
        _tokens(address(tA), address(tB));
        tA.mint(address(mgr), 1_000e18);
        tB.mint(address(mgr), 1_000e18);
        tA.mint(user, 100e18);
        tB.mint(user, 100e18);
        vm.startPrank(user);
        tA.approve(address(router), type(uint256).max);
        tB.approve(address(router), type(uint256).max);
        vm.stopPrank();
    }

    function _tokens(address a, address b) internal {
        (lo, hi) = a < b ? (a, b) : (b, a);
        pidLim = BPC.computeV4PoolId(lo, hi, FEE_LIM, TS_LIM, address(0));
        pidA   = BPC.computeV4PoolId(lo, hi, FEE_A, TS_A, address(0));
        pidB   = BPC.computeV4PoolId(lo, hi, FEE_B, TS_B, address(0));
        mgr.initialize(pidLim, uint160(BPC.Q96), 0, FEE_LIM);
        mgr.initialize(pidA, uint160(BPC.Q96), 0, FEE_A);
        mgr.initialize(pidB, uint160(BPC.Q96), 0, FEE_B);
        mgr.addPosition(pidLim, -512, 256, TS_LIM, L_THICK);
        mgr.addPosition(pidLim, -4096, -512, TS_LIM, L_THIN);
        mgr.addPosition(pidA, -887220, 887220, TS_A, L_WIDE);
        mgr.addPosition(pidB, -887200, 887200, TS_B, L_WIDE);
    }

    // ── route builders ───────────────────────────────────────────────────────

    function _quote(bytes32 pid, uint256 amt, uint24 fee, int24 ts) internal view returns (uint256 out) {
        (, out, , , ) = mgr.specSwap(pid, amt, fee, ts, true, BPC.MIN_SQRT_PRICE_PLUS_ONE);
        out = out * 999 / 1000;
    }

    function _aux(bool limited, int24 tick) internal view returns (bytes32) {
        uint256 a = uint256(uint160(hi));
        if (limited) a |= (uint256(1) << 184) | (uint256(uint24(tick)) << 160);
        return bytes32(a);
    }

    function _v4Leg(bytes32 pid, uint24 fee, int24 ts, uint256 amountIn, bytes32 aux)
        internal view returns (Leg memory)
    {
        return Leg({
            pool: address(uint160(uint256(pid))), hooks: address(0),
            kind: BPC.KIND_V4, fee: fee, tickSpacing: ts,
            zeroForOne: true, stable: false,
            amountIn: amountIn, expectedOut: _quote(pid, amountIn, fee, ts),
            auxId: aux
        });
    }

    function _limLeg(int24 tick) internal view returns (Leg memory) {
        return _v4Leg(pidLim, FEE_LIM, TS_LIM, LIM_IN, _aux(true, tick));
    }

    function _exA(uint256 amountIn) internal view returns (Leg memory) {
        return _v4Leg(pidA, FEE_A, TS_A, amountIn, _aux(false, 0));
    }

    function _exB(uint256 amountIn) internal view returns (Leg memory) {
        return _v4Leg(pidB, FEE_B, TS_B, amountIn, _aux(false, 0));
    }

    function _route(Leg[] memory legs) internal view returns (Route memory route) {
        uint256 inSum;
        uint256 outSum;
        for (uint256 i; i < legs.length; ++i) {
            outSum += legs[i].expectedOut;
            if ((uint256(legs[i].auxId) >> 184) & 1 == 0) inSum += legs[i].amountIn;
        }
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({tokenIn: lo, tokenOut: hi, amountIn: inSum, expectedOut: outSum, legs: legs});
        route = Route({
            hops: hops, totalOut: outSum, singleOut: outSum,
            singleOutFloor: 0, expectedImpactBps: 0, confidenceWad: 0,
            estGas: 0, hasSurplus: false, isV4Bundle: false
        });
    }

    function _three(int24 tick) internal view returns (Route memory) {
        Leg[] memory legs = new Leg[](3);
        legs[0] = _limLeg(tick);
        legs[1] = _exA(A_IN);
        legs[2] = _exB(B_IN);
        return _route(legs);
    }

    function _swap(Route memory route) internal returns (uint256) {
        vm.prank(user);
        return router.swapExactIn(route, AMT, 1, user, block.timestamp + 1);
    }

    function _realIn() internal pure returns (uint256) {
        return AMT - BPC.mulDivUp(AMT, BPC.PROTOCOL_FEE_BPS, BPC.BPS);
    }

    function _expectShape(Route memory route) internal {
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, uint16(3)));
        vm.prank(user);
        router.swapExactIn(route, AMT, 1, user, block.timestamp + 1);
    }

    // ── the exact legs share what the limited leg leaves ─────────────────────

    /// The limited leg stops at its limit past its floor; the exact legs split the rest of the
    /// hop's input 6:4, exactly their declared shares of what is left.
    function test_ExactLegsShareWhatTheLimitedLegLeaves() public {
        Route memory route = _three(-400);
        vm.expectCall(address(hub), abi.encodeWithSelector(BlazePhoenixHub.recordSwap.selector, address(uint160(uint256(pidLim)))), 1);
        uint256 got = _swap(route);
        uint256 took = mgr.spentIn(pidLim);
        uint256 left = _realIn() - took;
        uint256 floor = BPC.mulDiv(LIM_IN, _realIn(), AMT);
        assertGt(took, floor, "the limited leg must run past its floor");
        (uint160 sp, int24 tick) = mgr.slot0(pidLim);
        assertEq(tick, -400, "the limited leg must stop at its limit tick");
        assertEq(sp, BPC.sqrtPriceAtTick(-400), "the limited leg must stop at its limit price");
        assertEq(mgr.spentIn(pidA), BPC.mulDiv(A_IN, left, AMT), "leg A: its share of what is left");
        assertEq(mgr.spentIn(pidB), BPC.mulDiv(B_IN, left, AMT), "leg B: its share of what is left");
        assertEq(mgr.swapCount(), 4, "two windows for the limited leg, one swap per exact leg");
        assertEq(MockERC20(hi).balanceOf(user), 100e18 + got, "user did not receive tokenOut");
        assertEq(MockERC20(lo).balanceOf(address(router)), 0, "router holds tokenIn");
        assertEq(MockERC20(hi).balanceOf(address(router)), 0, "router holds tokenOut");
    }

    /// A limit the book reaches before the floor: the limited leg stops there, short of its
    /// floor, and its floor and its quote read what it filled, not the input it was offered.
    /// The exact legs share the rest.
    function test_LimitedLegStoppedShortOfItsFloorSettles() public {
        Route memory route = _three(-100);
        uint256 got = _swap(route);
        uint256 took = mgr.spentIn(pidLim);
        uint256 left = _realIn() - took;
        assertGt(took, 0, "the limited leg must fill up to its limit");
        assertLt(took, BPC.mulDiv(LIM_IN, _realIn(), AMT), "the limited leg must stop short of its floor");
        (uint160 sp, int24 tick) = mgr.slot0(pidLim);
        assertEq(tick, -100, "the limited leg must stop at its limit tick");
        assertEq(sp, BPC.sqrtPriceAtTick(-100), "the limited leg must stop at its limit price");
        assertEq(mgr.spentIn(pidA), BPC.mulDiv(A_IN, left, AMT), "leg A: its share of what is left");
        assertEq(mgr.spentIn(pidB), BPC.mulDiv(B_IN, left, AMT), "leg B: its share of what is left");
        assertEq(MockERC20(hi).balanceOf(user), 100e18 + got, "user did not receive tokenOut");
        assertEq(MockERC20(lo).balanceOf(address(router)), 0, "router holds tokenIn");
    }

    // ── the shape a limited leg may ride in ──────────────────────────────────

    /// The limit bits on a pair-shaped leg: refused before anything moves.
    function test_LimitOnAPairLegIsRefused() public {
        MockV2Pair pair = new MockV2Pair(lo, hi);
        MockERC20(lo).mint(address(pair), 1_000e18);
        MockERC20(hi).mint(address(pair), 1_000e18);
        pair.setReserves(1_000e18, 1_000e18);
        uint256 v2Out = LIM_IN * 997 * 1_000e18 / (1_000e18 * 1000 + LIM_IN * 997) * 999 / 1000;
        Leg[] memory legs = new Leg[](2);
        legs[0] = Leg({
            pool: address(pair), hooks: address(0), kind: BPC.KIND_V2, fee: 30,
            tickSpacing: 0, zeroForOne: true, stable: false,
            amountIn: LIM_IN, expectedOut: v2Out, auxId: _aux(true, -400)
        });
        legs[1] = _exA(A_IN);
        _expectShape(_route(legs));
    }

    /// A limited leg behind an exact leg: refused.
    function test_LimitedLegOffTheFirstSeatIsRefused() public {
        Leg[] memory legs = new Leg[](2);
        legs[0] = _exA(A_IN);
        legs[1] = _limLeg(-400);
        _expectShape(_route(legs));
    }

    /// A limited leg with no exact leg beside it: refused.
    function test_LimitedLegAloneIsRefused() public {
        Leg[] memory legs = new Leg[](1);
        legs[0] = _limLeg(-400);
        _expectShape(_route(legs));
    }

    /// A limited leg on a hooked pool: refused. The hook has no swap bit, so no other hook rule
    /// applies, and the exact leg behind it is hooked too, so the hooked-legs-last order holds:
    /// the hook on the limited leg is the only thing wrong with this route.
    function test_LimitedLegOnAHookedPoolIsRefused() public {
        address hooks = address(uint160(1) << 20);
        bytes32 pidH  = BPC.computeV4PoolId(lo, hi, FEE_LIM, TS_LIM, hooks);
        bytes32 pidAH = BPC.computeV4PoolId(lo, hi, FEE_A, TS_A, hooks);
        mgr.initialize(pidH, uint160(BPC.Q96), 0, FEE_LIM);
        mgr.initialize(pidAH, uint160(BPC.Q96), 0, FEE_A);
        mgr.addPosition(pidH, -512, 256, TS_LIM, L_THICK);
        mgr.addPosition(pidAH, -887220, 887220, TS_A, L_WIDE);
        Leg[] memory legs = new Leg[](2);
        legs[0] = _v4Leg(pidH, FEE_LIM, TS_LIM, LIM_IN, _aux(true, -400));
        legs[0].hooks = hooks;
        legs[1] = _v4Leg(pidAH, FEE_A, TS_A, A_IN, _aux(false, 0));
        legs[1].hooks = hooks;
        _expectShape(_route(legs));
    }
}
