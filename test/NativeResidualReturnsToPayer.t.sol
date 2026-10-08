// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  The native door's residual: every unit of `msg.value` the plan does not commit
//  comes back to the payer.
//
//  RouterRefundPayer proves it for `swapBestExactIn`; RouterNativeEntry runs the
//  native door with a fully consuming route only. Here the route declares half of
//  what the door pulls (leg.amountIn == hop.amountIn == half): the legs spend what
//  they declared and the rest is swept to `payer`. Native output is deliberately not
//  implemented, so the swap's ETH stays spent and the refund arrives as WETH.
//
//  forge test --match-contract NativeResidualReturnsToPayer -vv
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";

/// @dev WETH9-shaped mock (same shape as RouterNativeEntry.t.sol's local copy).
contract MockWETHResidual is MockERC20 {
    constructor() MockERC20("Wrapped Ether", "WETH") {}
    function deposit() external payable { this.mint(msg.sender, msg.value); }
}

contract NativeResidualReturnsToPayerTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixRouter router;
    MockWETHResidual wethT;
    MockERC20 tokenOut;
    MockV2Pair pair;

    address user = address(0xBEEF);
    uint256 constant FUNDED = 100e18;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        wethT = new MockWETHResidual();
        tokenOut = new MockERC20("Out", "OUT");
        pair = new MockV2Pair(address(wethT), address(tokenOut));

        router = new BlazePhoenixRouter(
            address(hub), address(0xBEEF), address(this), address(0xFEE1), address(0xFEE2)
        );
        router.setWeth(address(wethT));

        wethT.mint(address(pair), 10_000e18);
        tokenOut.mint(address(pair), 10_000e18);
        pair.setReserves(10_000e18, 10_000e18);

        vm.deal(user, FUNDED);
    }

    function _route(uint256 declared) private view returns (Route memory route) {
        bool zeroForOne = address(wethT) < address(tokenOut);
        Leg[] memory legs = new Leg[](1);
        legs[0] = Leg({
            pool: address(pair), hooks: address(0), kind: BPC.KIND_V2, fee: 30,
            tickSpacing: 0, zeroForOne: zeroForOne, stable: false,
            amountIn: declared, expectedOut: 0, auxId: bytes32(0)
        });
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({
            tokenIn: address(wethT), tokenOut: address(tokenOut),
            amountIn: declared, expectedOut: 0, legs: legs
        });
        route = Route({
            hops: hops, totalOut: 0, singleOut: 0,
            singleOutFloor: 0, expectedImpactBps: 0, confidenceWad: 0,
            estGas: 0, hasSurplus: false, isV4Bundle: false
        });
    }

    /// @notice The residual, native door: pull the whole msg.value, commit half.
    function test_Native_ResidualReturnsToPayer_AsWeth_RouterHoldsNothing() public {
        uint256 pulled = 10e18;
        uint256 declared = pulled / 2;
        Route memory route = _route(declared);

        vm.prank(user);
        uint256 delivered = router.swapExactInNative{value: pulled}(
            route, 1, user, block.timestamp + 1
        );

        assertGt(delivered, 0, "swap must complete");
        assertEq(tokenOut.balanceOf(user), delivered, "recipient got the delivered output");

        // The residual is produced by the setup, so the test cannot pass
        // vacuously when nothing was left to refund.
        uint256 refundedWeth = wethT.balanceOf(user);
        assertGt(refundedWeth, 0, "setup: the under-declared route must leave a residual");

        // The pin: the residual came back to the payer, not stranded on the Router.
        assertEq(wethT.balanceOf(address(router)), 0, "router must hold no WETH after the swap");
        assertEq(address(router).balance, 0, "router must hold no ETH after the swap");
        assertEq(tokenOut.balanceOf(address(router)), 0, "router must hold no tokenOut after the swap");

        // The ETH stayed spent (the refund is WETH, not ETH) and the unspent
        // input is exactly what came back as WETH: pulled - refunded == the
        // units the legs actually routed.
        assertEq(user.balance, FUNDED - pulled, "native refund is WETH, never ETH");
        assertLt(refundedWeth, pulled, "the legs routed something (refund < pulled)");
    }

    /// @notice Control: the fully-consuming route spends everything and leaves
    ///         no residual — same fixture, ONE difference (declared == pulled).
    function test_Native_FullRoute_LeavesNoResidual() public {
        uint256 pulled = 10e18;
        Route memory route = _route(pulled);

        vm.prank(user);
        uint256 delivered = router.swapExactInNative{value: pulled}(
            route, 1, user, block.timestamp + 1
        );

        assertGt(delivered, 0, "control must complete");
        assertEq(wethT.balanceOf(user), 0, "control: nothing left to refund");
        assertEq(wethT.balanceOf(address(router)), 0, "control: router holds no WETH");
    }
}
