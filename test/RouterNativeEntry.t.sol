// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  swapExactInNative — native-ETH entry. The value is wrapped exactly once
//  into WETH at entry (measured, like every ERC20 pull) and routed as an
//  ERC20; msg.value is never read again and no multicall surface exists, so
//  the no-receive() double-spend defense stays intact. Fail-closed when the
//  weth address was never wired, on empty routes, and on routes that do not
//  start in WETH.
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";

/// @dev WETH9-shaped mock: deposit() mints the caller's balance 1:1.
contract MockWETH is MockERC20 {
    constructor() MockERC20("Wrapped Ether", "WETH") {}
    function deposit() external payable {
        this.mint(msg.sender, msg.value);
    }
}

contract RouterNativeEntryTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixRouter router;
    MockWETH wethT;
    MockERC20 tokenOut;
    MockV2Pair pair;

    address user = address(0xBEEF);

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        wethT = new MockWETH();
        tokenOut = new MockERC20("Out", "OUT");
        pair = new MockV2Pair(address(wethT), address(tokenOut));

        router = new BlazePhoenixRouter(
            address(hub), address(0xBEEF), address(this), address(0xFEE1), address(0xFEE2)
        );
        router.setWeth(address(wethT));

        // Seed the pair with WETH liquidity (mint directly, no deposit needed).
        wethT.mint(address(pair), 10_000e18);
        tokenOut.mint(address(pair), 10_000e18);
        pair.setReserves(10_000e18, 10_000e18);

        vm.deal(user, 100e18);
    }

    function _buildRoute(uint256 amountIn, uint256 claimedTotalOut) private view returns (Route memory route) {
        bool zeroForOne = address(wethT) < address(tokenOut);
        Leg[] memory legs = new Leg[](1);
        legs[0] = Leg({
            pool: address(pair), hooks: address(0), kind: BPC.KIND_V2, fee: 30,
            tickSpacing: 0, zeroForOne: zeroForOne, stable: false,
            amountIn: amountIn, expectedOut: claimedTotalOut, auxId: bytes32(0)
        });
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({
            tokenIn: address(wethT), tokenOut: address(tokenOut),
            amountIn: amountIn, expectedOut: claimedTotalOut, legs: legs
        });
        route = Route({
            hops: hops, totalOut: claimedTotalOut, singleOut: claimedTotalOut,
            singleOutFloor: 0, expectedImpactBps: 0, confidenceWad: 0,
            estGas: 0, hasSurplus: false, isV4Bundle: false
        });
    }

    /// @notice Happy path: raw ETH in, tokenOut delivered, router holds
    ///         neither ETH nor WETH nor tokenOut afterward.
    function test_Native_SwapWrapsOnceAndDelivers() public {
        uint256 amountIn = 10e18;
        uint256 realQuote = BPC.outV2(amountIn, 10_000e18, 10_000e18, 30);
        Route memory route = _buildRoute(amountIn, realQuote);

        vm.prank(user);
        uint256 delivered = router.swapExactInNative{value: amountIn}(
            route, 1, user, block.timestamp + 1
        );

        assertGt(delivered, 0, "must deliver");
        assertEq(tokenOut.balanceOf(user), delivered, "recipient got the output");
        assertEq(address(router).balance, 0, "router holds no ETH");
        assertEq(wethT.balanceOf(address(router)), 0, "router holds no WETH");
        assertEq(tokenOut.balanceOf(address(router)), 0, "router holds no tokenOut");
        assertEq(user.balance, 100e18 - amountIn, "user paid exactly msg.value");
    }

    function test_Native_RevertsWhenWethNotWired() public {
        BlazePhoenixRouter bare = new BlazePhoenixRouter(
            address(hub), address(0xBEEF), address(this), address(0xFEE1), address(0xFEE2)
        );
        Route memory route = _buildRoute(1e18, 1);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, uint16(3)));
        bare.swapExactInNative{value: 1e18}(route, 1, user, block.timestamp + 1);
    }

    function test_Native_RevertsWhenRouteDoesNotStartInWeth() public {
        // Route whose first hop starts in tokenOut, not WETH: the wrap target
        // and the route disagree -> fail-closed before any token movement.
        Route memory route = _buildRoute(1e18, 1);
        route.hops[0].tokenIn = address(tokenOut);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, uint16(3)));
        router.swapExactInNative{value: 1e18}(route, 1, user, block.timestamp + 1);
    }

    function test_Native_RevertsOnZeroValueOrZeroMinOut() public {
        Route memory route = _buildRoute(1e18, 1);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, uint16(3)));
        router.swapExactInNative{value: 0}(route, 1, user, block.timestamp + 1);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, uint16(10)));
        router.swapExactInNative{value: 1e18}(route, 0, user, block.timestamp + 1);
    }

    /// @notice Bare ETH transfers (empty calldata) must still be rejected —
    ///         the native entry did not create a stray ETH sink.
    function test_Native_BareEthTransferStillRejected() public {
        vm.prank(user);
        (bool ok, ) = address(router).call{value: 1e18}("");
        assertFalse(ok, "bare ETH must still revert (no receive())");
    }
}
