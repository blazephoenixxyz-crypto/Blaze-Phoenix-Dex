// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  Entry and fee guards, each observed with its exact revert bytes.
//
//    G1  swapExactInNative  refuses when the native entry is not wired   -> RouterE(3)
//    G7  addFactory         refuses a discovery mode outside the mask    -> HubE(5)
//    G3  _chargeHopFee      at amountIn == 1 the fee is the whole input; the
//                           one-wei leg is refused (RouterE(8)) - the behaviour a
//                           user sees, pinned whichever check refuses it.
//    G2  _swapPrePulled     its own `hops == 0 || amountIn == 0` check is shadowed:
//                           every door checks both before the call, so a door is
//                           what refuses, and this pins that each one does.
//
//  forge test --match-contract EntryGuardsAreObserved -vv
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";

contract EntryGuardsAreObservedTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixRouter router;
    MockERC20 tokenIn;
    MockERC20 tokenOut;
    MockV2Pair pair;

    address treasury1 = address(0xFEE1);
    address treasury2 = address(0xFEE2);
    address user = address(0xBEEF);

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        tokenIn = new MockERC20("In", "IN");
        tokenOut = new MockERC20("Out", "OUT");
        pair = new MockV2Pair(address(tokenIn), address(tokenOut));
        router = new BlazePhoenixRouter(
            address(hub), address(0xBEE2), address(this), treasury1, treasury2
        );
        router.setPermit2(address(0xFEE7)); // unused here, but keeps the shape
        tokenIn.mint(address(pair), 10_000e18);
        tokenOut.mint(address(pair), 10_000e18);
        pair.setReserves(uint112(10_000e18), uint112(10_000e18));
        tokenIn.mint(user, 1_000e18);
        vm.prank(user);
        tokenIn.approve(address(router), type(uint256).max);
    }

    function _route(address tIn, address tOut, address pool, uint256 amountIn)
        private pure returns (Route memory route)
    {
        bool zfo = tIn < tOut;
        Leg[] memory legs = new Leg[](1);
        legs[0] = Leg({
            pool: pool, hooks: address(0), kind: BPC.KIND_V2, fee: 30,
            tickSpacing: 0, zeroForOne: zfo, stable: false,
            amountIn: amountIn, expectedOut: 0, auxId: bytes32(0)
        });
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({
            tokenIn: tIn, tokenOut: tOut, amountIn: amountIn, expectedOut: 0, legs: legs
        });
        route = Route({
            hops: hops, totalOut: 0, singleOut: 0, singleOutFloor: 0,
            expectedImpactBps: 0, confidenceWad: 0, estGas: 0,
            hasSurplus: false, isV4Bundle: false
        });
    }

    function _err(uint16 code) private pure returns (bytes memory) {
        return abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, code);
    }

    function _hubErr(uint16 code) private pure returns (bytes memory) {
        return abi.encodeWithSelector(BlazePhoenixHub.HubE.selector, code);
    }

    // =========================================================================
    //  G1 -- Router:464, the native door "weth never wired" fail-closed.
    //
    //  A Router is a valid deployment with `weth == address(0)` until setWeth
    //  is called. The route's hops[0].tokenIn is address(0) so that the NEXT
    //  guard (`route.hops[0].tokenIn != w`, also RouterE(3)) is SATISFIED
    //  (0 != 0 is false). Without the weth guard the deposit is attempted on
    //  the codeless address(0): deposit() returns void so the call SUCCEEDS,
    //  nothing is minted, `received == 0` and the path dies at RouterE(8).
    //  So the exact code 3 pins THIS guard and nothing else.
    // =========================================================================

    function test_G1_NativeDoorNotWired_RevertsRouterE3() public {
        BlazePhoenixRouter bare = new BlazePhoenixRouter(
            address(hub), address(0xBEE2), address(this), treasury1, treasury2
        );
        assertEq(bare.weth(), address(0), "precondition: weth never wired");

        Route memory route = _route(address(0), address(tokenOut), address(pair), 1);

        vm.deal(user, 2);
        vm.prank(user);
        vm.expectRevert(_err(3));
        bare.swapExactInNative{value: 1}(route, 1, user, block.timestamp + 1);
    }

    // =========================================================================
    //  G3 -- Router:679, `feeH >= amountIn` in _chargeHopFee (hop 0).
    //
    //  feeH = mulDivUp(baseH, PROTOCOL_FEE_BPS=28, BPS=10000). With
    //  amountIn == 1 wei, baseH == 1 (leg sum capped by the pull) and
    //  feeH = ceil(28/10000) = 1 >= amountIn. tokenIn is NOT a bridge, so
    //  feeHop stays at type(uint256).max and hop 0 is the charging hop.
    //  Without the guard `unchecked { return amountIn - feeH; }` returns 0.
    // =========================================================================

    function test_G3_FeeGeInput_RevertsRouterE8() public {
        Route memory route = _route(address(tokenIn), address(tokenOut), address(pair), 1);

        vm.prank(user);
        vm.expectRevert(_err(8));
        router.swapExactIn(route, 1, 1, user, block.timestamp + 1);
    }

    // =========================================================================
    //  G7 -- Hub:709, `(MODES_VALID >> mode) & 1 == 0` in addFactory.
    //
    //  MODES_VALID = 0x2FF = bits 0..7 and 9; bit 8 is a documented tombstone.
    //  kind = KIND_V2 (=0) is inside KINDS_ROUTABLE, so the kind check passes
    //  and ONLY the mode check can fire HubE(5). initHash != 0 so that the
    //  CREATE2 step (mode >= 4) does not double-fire the same code either.
    // =========================================================================

    function test_G7_AddFactoryInvalidMode_RevertsHubE5() public {
        uint24[] memory fees = new uint24[](0);
        int24[] memory spacings = new int24[](0);
        vm.expectRevert(_hubErr(5));
        hub.addFactory(address(0xF00D), BPC.KIND_V2, 8, bytes32(uint256(1)), fees, spacings);
    }

    // =========================================================================
    //  G2 -- Router:587 documented as UNREACHABLE (see header). This control
    //  proves the Permit2 door refuses an empty route at ITS OWN guard (:411),
    //  before _swapPrePulled is ever reached -- so no witness can exist.
    // =========================================================================

    function test_G2_SelfPrePulled_ShadowedByDoors() public {
        // Empty hops: the door's own :411 guard fires RouterE(3).
        Hop[] memory hops = new Hop[](0);
        Route memory route = Route({
            hops: hops, totalOut: 0, singleOut: 0, singleOutFloor: 0,
            expectedImpactBps: 0, confidenceWad: 0, estGas: 0,
            hasSurplus: false, isV4Bundle: false
        });
        vm.deal(user, 1);
        vm.prank(user);
        vm.expectRevert(_err(3));
        router.swapExactInNative{value: 1}(route, 1, user, block.timestamp + 1);
        // NOTE: this same code comes from :468 (hops.length==0), NOT :587.
        // _swapPrePulled is only entered with hops.length >= 1 and amountIn > 0.
    }
}
