// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";

/// @notice `MAX_HOPS = 3` had no test at any value. The only occurrence of the name in 194 test
///         files was a stale comment reading "grep -rn MAX_HOPS src/ -> nothing", written before
///         the constant existed, and the test beside it built a 61-hop route and swallowed the
///         result with a BARE `vm.expectRevert()`. Sixty-one is greater than three and also
///         greater than sixty, so raising the ceiling twentyfold left that green.
///
///         A ceiling needs both sides. Asserting the refusal alone does not pin the value -
///         `RouterE(3)` is raised at 24 distinct sites in the Router, so the code says only "one
///         of twenty-four things went wrong". The discriminating fact is that the route ONE HOP
///         SHORTER settles: three hops through, four refused, and the pair moves together only
///         if the constant does.
contract RouteHopCeilingIsThreeTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixRouter router;
    MockERC20[5] t;                 // t0 -> t1 -> t2 -> t3 -> t4
    MockV2Pair[4] p;
    address user = address(0xBEEF);

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        router = new BlazePhoenixRouter(
            address(hub), address(0xBEEF), address(this), address(0xFEE1), address(0xFEE2));
        for (uint256 i; i < 5; ++i) t[i] = new MockERC20("T", "T");
        for (uint256 i; i < 4; ++i) {
            p[i] = new MockV2Pair(address(t[i]), address(t[i + 1]));
            t[i].mint(address(p[i]), 10_000e18);
            t[i + 1].mint(address(p[i]), 10_000e18);
            p[i].setReserves(10_000e18, 10_000e18);
        }
        t[0].mint(user, 10_000e18);
        vm.prank(user);
        t[0].approve(address(router), type(uint256).max);
    }

    function _route(uint256 hopCount, uint256 amountIn) private view returns (Route memory r) {
        Hop[] memory hops = new Hop[](hopCount);
        for (uint256 h; h < hopCount; ++h) {
            Leg[] memory legs = new Leg[](1);
            legs[0] = Leg({pool: address(p[h]), hooks: address(0), kind: BPC.KIND_V2, fee: 30,
                           tickSpacing: 0, zeroForOne: address(t[h]) < address(t[h + 1]),
                           stable: false, amountIn: h == 0 ? amountIn : 0, expectedOut: 0,
                           auxId: bytes32(0)});
            hops[h] = Hop({tokenIn: address(t[h]), tokenOut: address(t[h + 1]),
                           amountIn: h == 0 ? amountIn : 0, expectedOut: 0, legs: legs});
        }
        r = Route({hops: hops, totalOut: 0, singleOut: 0, singleOutFloor: 0,
                   expectedImpactBps: 0, confidenceWad: 0, estGas: 0,
                   hasSurplus: false, isV4Bundle: false});
    }

    /// @notice Three hops is inside the ceiling and settles. Without this arm the refusal below
    ///         proves nothing: a Router that refused every route would satisfy it.
    function test_ThreeHopsIsInsideTheCeilingAndSettles() public {
        uint256 amt = 100e18;
        vm.prank(user);
        uint256 got = router.swapExactIn(_route(3, amt), amt, 1, user, block.timestamp + 1);
        assertGt(got, 0, "a three-hop route must settle: it is at the ceiling, not past it");
        assertEq(t[3].balanceOf(user), got, "and it must deliver the third hop's output token");
    }

    /// @notice Four is past it, and refused.
    function test_FourHopsIsPastTheCeilingAndRefused() public {
        uint256 amt = 100e18;
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, uint16(3)));
        router.swapExactIn(_route(4, amt), amt, 1, user, block.timestamp + 1);
    }
}
