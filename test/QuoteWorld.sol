// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;
// A small full stack (Hub, Solver, Quoter, Router) on three tokens and three constant-product
// pools, shared by the quote-delay and quoter-gas statistics; B is the bridge coin.
import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixQuoter} from "../src/BlazePhoenixQuoter.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";
import {MockV2Factory} from "./mocks/MockV2Factory.sol";

abstract contract QuoteWorld is Test {
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    BlazePhoenixQuoter quoter;
    BlazePhoenixRouter router;
    MockV2Factory factory;
    MockERC20 A; MockERC20 B; MockERC20 C;
    MockV2Pair AB1; MockV2Pair AB2; MockV2Pair AB3; MockV2Pair BC1;
    address user = address(0xBEEF);
    address whale = address(0xB16);

    function _world(bool seedRegistry) internal {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        solver = new BlazePhoenixSolver(address(hub));
        quoter = new BlazePhoenixQuoter(address(hub), address(solver));
        router = new BlazePhoenixRouter(address(hub), address(solver), address(this), address(0xFEE1), address(0xFEE2));
        hub.setRoles(address(router), address(solver), address(quoter));
        A = new MockERC20("A", "A"); B = new MockERC20("B", "B"); C = new MockERC20("C", "C");
        AB1 = _pool(A, B, 100_000e18, 160_000e18);
        AB2 = _pool(A, B, 200_000e18, 320_000e18);
        AB3 = _pool(A, B, 400_000e18, 640_000e18);
        BC1 = _pool(B, C, 150_000e18, 150_000e18);
        factory = new MockV2Factory();
        hub.addFactory(address(factory), BPC.KIND_V2, 0, bytes32(0), new uint24[](0), new int24[](0));
        factory.setPair(address(A), address(B), address(AB1));
        factory.setPair(address(B), address(C), address(BC1));
        hub.addBridge(address(B));
        if (seedRegistry) {
            hub.seedPool(address(AB1), BPC.KIND_V2, 30, address(0), address(A), address(B));
            hub.seedPool(address(AB2), BPC.KIND_V2, 30, address(0), address(A), address(B));
            hub.seedPool(address(AB3), BPC.KIND_V2, 30, address(0), address(A), address(B));
            hub.seedPool(address(BC1), BPC.KIND_V2, 30, address(0), address(B), address(C));
        }
    }

    function _pool(MockERC20 x, MockERC20 y, uint256 rx, uint256 ry) internal returns (MockV2Pair p) {
        p = new MockV2Pair(address(x), address(y));
        x.mint(address(p), rx); y.mint(address(p), ry);
        (address t0, ) = address(x) < address(y) ? (address(x), address(y)) : (address(y), address(x));
        p.setReserves(uint112(address(x) == t0 ? rx : ry), uint112(address(x) == t0 ? ry : rx));
    }

    /// A hand-built one-hop route through one pool — the "rest of the world" trading.
    function _handRoute(MockV2Pair p, address tIn, address tOut, uint256 amt) internal view returns (Route memory r) {
        (uint112 r0, uint112 r1, ) = p.getReserves();
        bool zfo = p.token0() == tIn;
        uint256 q = BPC.outV2(amt, zfo ? r0 : r1, zfo ? r1 : r0, 30);
        Leg[] memory legs = new Leg[](1);
        legs[0] = Leg({pool: address(p), hooks: address(0), kind: BPC.KIND_V2, fee: 30, tickSpacing: 0,
                       zeroForOne: zfo, stable: false, amountIn: amt, expectedOut: q, auxId: bytes32(0)});
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({tokenIn: tIn, tokenOut: tOut, amountIn: amt, expectedOut: q, legs: legs});
        r = Route({hops: hops, totalOut: q, singleOut: q, singleOutFloor: 0, expectedImpactBps: 0,
                   confidenceWad: 0, estGas: 0, hasSurplus: false, isV4Bundle: false});
    }

    /// Someone else trades `amt` of tIn through pool p (the drift between a quote and its execution).
    function _drift(MockV2Pair p, MockERC20 tIn, MockERC20 tOut, uint256 amt) internal {
        tIn.mint(whale, amt);
        vm.startPrank(whale);
        tIn.approve(address(router), amt);
        router.swapExactIn(_handRoute(p, address(tIn), address(tOut), amt), amt, 1, whale, block.timestamp + 1);
        vm.stopPrank();
    }

    function _routerCode(bytes memory ret) internal pure returns (uint16 code, bool isRouterE) {
        if (ret.length == 36 && bytes4(ret) == BlazePhoenixRouter.RouterE.selector) {
            assembly { code := mload(add(ret, 36)) }
            isRouterE = true;
        }
    }
}
