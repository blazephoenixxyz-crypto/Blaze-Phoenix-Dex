// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  The lifecycle guards of every value door: each one honours the pause and the
//  reentrancy lock.
//
//  The Router has four value doors, all `whenLive nrEntrant`: swapExactIn and
//  swapExactInWithPermit2 are observed in their own files; this one observes
//  swapExactInNative (paused -> RouterE(2)) and swapBestExactIn (paused ->
//  RouterE(2), re-entered -> RouterE(7)).
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";
import {MaliciousReentrantERC20} from "./mocks/MaliciousReentrantERC20.sol";
import {StubSolverGNF} from "./GuardsNeverFired.t.sol";

contract MockWETHVD is MockERC20 {
    constructor() MockERC20("Wrapped Ether", "WETH") {}
    function deposit() external payable { this.mint(msg.sender, msg.value); }
}

contract ValueDoorsLifecycleGuardsTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixRouter router;
    MockWETHVD weth;
    MockERC20 tokenOut;
    MockERC20 tokenIn;
    MockV2Pair pair;

    address treasury1 = address(0xFEE1);
    address treasury2 = address(0xFEE2);
    address user = address(0xBEEF);

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        tokenIn = new MockERC20("In", "IN");
        tokenOut = new MockERC20("Out", "OUT");
        pair = new MockV2Pair(address(tokenIn), address(tokenOut));
        tokenIn.mint(address(pair), 10_000e18);
        tokenOut.mint(address(pair), 10_000e18);
        pair.setReserves(uint112(10_000e18), uint112(10_000e18));
        tokenIn.mint(user, 1_000e18);
    }

    function _route(address tIn, address pool, uint256 amountIn) private view returns (Route memory route) {
        bool zfo = tIn < address(tokenOut);
        Leg[] memory legs = new Leg[](1);
        legs[0] = Leg({
            pool: pool, hooks: address(0), kind: BPC.KIND_V2, fee: 30,
            tickSpacing: 0, zeroForOne: zfo, stable: false,
            amountIn: amountIn, expectedOut: 0, auxId: bytes32(0)
        });
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({ tokenIn: tIn, tokenOut: address(0), amountIn: amountIn, expectedOut: 0, legs: legs });
        route = Route({
            hops: hops, totalOut: 0, singleOut: 0, singleOutFloor: 0,
            expectedImpactBps: 0, confidenceWad: 0, estGas: 0,
            hasSurplus: false, isV4Bundle: false
        });
    }

    // =========================================================================
    //  D1 -- swapExactInNative: paused ⇒ RouterE(2), before the pull.
    // =========================================================================

    function test_D1_NativeDoor_PausedRevertsRouterE2() public {
        weth = new MockWETHVD();
        router = new BlazePhoenixRouter(
            address(hub), address(0xBEE2), address(this), treasury1, treasury2
        );
        router.setWeth(address(weth));

        Route memory route = _route(address(weth), address(pair), 1e18);
        route.hops[0].tokenOut = address(tokenOut);

        router.setPaused(true);
        vm.deal(user, 2e18);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, uint16(2)));
        router.swapExactInNative{value: 1e18}(route, 1, user, block.timestamp + 1);
    }

    // =========================================================================
    //  D2 -- swapBestExactIn: paused ⇒ RouterE(2).
    // =========================================================================

    function test_D2_BestDoor_PausedRevertsRouterE2() public {
        StubSolverGNF stub = new StubSolverGNF(0, address(pair), address(0));
        // The stub solver is the constructor arg; a dedicated router keeps the
        // native door of D1 out of this one.
        BlazePhoenixRouter best = new BlazePhoenixRouter(
            address(hub), address(stub), address(this), treasury1, treasury2
        );
        vm.prank(user);
        tokenIn.approve(address(best), type(uint256).max);

        best.setPaused(true);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, uint16(2)));
        best.swapBestExactIn(address(tokenIn), address(tokenOut), 1e18, 1, user, block.timestamp + 1);
    }

    // =========================================================================
    //  D3 -- swapBestExactIn: nrEntrant. A nested call mid-pull ⇒ RouterE(7).
    // =========================================================================

    function test_D3_BestDoor_ReentrancyBlockedRouterE7() public {
        MaliciousReentrantERC20 evil = new MaliciousReentrantERC20();
        MockV2Pair evilPair = new MockV2Pair(address(evil), address(tokenOut));
        evil.mint(address(evilPair), 10_000e18);
        tokenOut.mint(address(evilPair), 10_000e18);
        evilPair.setReserves(uint112(10_000e18), uint112(10_000e18));

        StubSolverGNF stub = new StubSolverGNF(0, address(evilPair), address(0));
        BlazePhoenixRouter best = new BlazePhoenixRouter(
            address(hub), address(stub), address(this), treasury1, treasury2
        );

        uint256 amountIn = 100e18;
        evil.mint(user, 1_000e18);
        vm.prank(user);
        evil.approve(address(best), type(uint256).max);

        Route memory route = _route(address(evil), address(evilPair), amountIn);
        route.hops[0].tokenOut = address(tokenOut);

        bytes memory nested = abi.encodeWithSelector(
            best.swapExactIn.selector, route, amountIn, uint256(1), user, block.timestamp + 1
        );
        evil.setAttack(address(best), nested);

        vm.prank(user);
        uint256 delivered = best.swapBestExactIn(
            address(evil), address(tokenOut), amountIn, 1, user, block.timestamp + 1
        );

        assertGt(delivered, 0, "the outer best-door swap must complete");
        assertTrue(evil.lastReentryAttempted(), "transferFrom must have attempted the nested call");
        assertTrue(evil.lastReentryReverted(), "nrEntrant must block the nested call mid-pull");

        bytes memory ret = evil.lastReentryReturndata();
        assertEq(ret.length, 36, "nested revert must carry RouterE(uint16)");
        assertEq(bytes4(ret), BlazePhoenixRouter.RouterE.selector, "must be a RouterE");
        uint256 code;
        assembly { code := mload(add(ret, 36)) }
        assertEq(code, 7, "the refusal must be the reentrancy lock, RouterE(7)");
    }
}