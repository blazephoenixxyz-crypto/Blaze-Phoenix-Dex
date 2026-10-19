// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  N2 (fix-1019, matrix round E; email 3037): on the explicit door
//  (swapExactIn) a V2 leg's pool comes from the caller's calldata and is never
//  checked against the registry or a factory (Router._execPairAmt: getReserves,
//  safeTransfer, swap on `leg.pool`). By design (Router:1154-1157, :1720-1726):
//  the signer's route is the signer's choice, and userMinOut is the bound.
//
//  Pinned, both eras:
//    - an off-market pool the registry never saw, with forged-low declared
//      figures, receives the input and settles at its own price when the
//      caller signs userMinOut = 1 (the protocol floors are relative to the
//      in-frame quote of that same pool, so they do not bind);
//    - the same route with an honest userMinOut (0.5 % under the market fill)
//      reverts RouterE(5): the only bound that holds is the caller's.
//
//  forge test --match-path test/Fix1019CallerPoolsN2.t.sol -vv
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

interface IF19N2Erc20 {
    function transfer(address to, uint256 amt) external returns (bool);
    function balanceOf(address who) external view returns (uint256);
}

/// Minimal V2 pair, never registered in the Hub, no factory: reserves follow balances.
contract F19N2Pair {
    address public token0;
    address public token1;
    uint112 public reserve0;
    uint112 public reserve1;

    constructor(address a, address b) { (token0, token1) = a < b ? (a, b) : (b, a); }

    function sync() external {
        reserve0 = uint112(IF19N2Erc20(token0).balanceOf(address(this)));
        reserve1 = uint112(IF19N2Erc20(token1).balanceOf(address(this)));
    }
    function getReserves() external view returns (uint112, uint112, uint32) {
        return (reserve0, reserve1, uint32(block.timestamp));
    }
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata) external {
        if (amount0Out > 0) IF19N2Erc20(token0).transfer(to, amount0Out);
        if (amount1Out > 0) IF19N2Erc20(token1).transfer(to, amount1Out);
        reserve0 = uint112(IF19N2Erc20(token0).balanceOf(address(this)));
        reserve1 = uint112(IF19N2Erc20(token1).balanceOf(address(this)));
    }
}

contract Fix1019CallerPoolsN2Test is Test {
    BlazePhoenixHub hub;
    BlazePhoenixRouter router;
    MockERC20 A;
    MockERC20 B;
    F19N2Pair rogue;              // off-market: B at half the market price of A
    address user = address(0xBEEF);
    uint256 constant R   = 100_000e18;
    uint256 constant AMT = 1_000e18;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        router = new BlazePhoenixRouter(address(hub), address(0xD0D0), address(this), address(0xFEE1), address(0xFEE2));
        A = new MockERC20("A", "A");
        B = new MockERC20("B", "B");
        rogue = new F19N2Pair(address(A), address(B));
        A.mint(address(rogue), R);
        B.mint(address(rogue), R / 2);
        rogue.sync();
        A.mint(user, AMT);
        vm.prank(user);
        A.approve(address(router), type(uint256).max);
    }

    /// Oracle, written here: x*y=k with 30 bps on a 1:1 market of depth R a side.
    function _marketOut(uint256 amtIn) private pure returns (uint256) {
        uint256 f = amtIn * 9970;
        return (f * R) / (R * 10_000 + f);
    }

    /// The forged result: the rogue pool, declared figures of 1 wei, no singleOutFloor.
    function _forged() private view returns (Route memory) {
        Leg[] memory ls = new Leg[](1);
        ls[0] = Leg({pool: address(rogue), hooks: address(0), kind: BPC.KIND_V2, fee: 30, tickSpacing: 0,
            zeroForOne: rogue.token0() == address(A), stable: false, amountIn: AMT, expectedOut: 1,
            auxId: bytes32(0)});
        Hop[] memory hs = new Hop[](1);
        hs[0] = Hop({tokenIn: address(A), tokenOut: address(B), amountIn: AMT, expectedOut: 1, legs: ls});
        return Route({hops: hs, totalOut: 1, singleOut: 1, singleOutFloor: 0,
            expectedImpactBps: 0, confidenceWad: 0, estGas: 0, hasSurplus: false, isV4Bundle: false});
    }

    /// By design: the caller's pool takes the input and settles at its own price.
    /// Red iff the Router stops moving the input it pulled into the caller's pool
    /// (or keeps a residual: the holds-nothing check).
    function test_N2_UnregisteredOffMarketPool_UserMinOutOne_SettlesAtItsOwnPrice() public {
        assertEq(hub.getActivePools(address(A), address(B)).length, 0, "setup: the registry never saw the pool");
        Route memory r = _forged();
        uint256 poolA0 = A.balanceOf(address(rogue));
        vm.prank(user);
        uint256 got = router.swapExactIn(r, AMT, 1, user, block.timestamp + 1);
        uint256 poolIn = A.balanceOf(address(rogue)) - poolA0;
        assertEq(A.balanceOf(user), 0, "the user spent the whole input");
        assertLe(poolIn, AMT, "the pool never receives more than the input");
        assertGe(poolIn * 10_000, AMT * (10_000 - 28) - 10_000, "the pool receives the input less at most the protocol fee");
        assertEq(A.balanceOf(address(router)), 0, "the Router keeps no input");
        assertEq(B.balanceOf(address(router)), 0, "the Router keeps no output");
        assertEq(B.balanceOf(user), got, "delivered to the recipient");
        assertLt(got * 10, _marketOut(AMT) * 6, "settled at the rogue pool's price, ~half the market");
    }

    /// The bound that holds: an honest userMinOut, from the market, reverts the forged route.
    function test_N2_UnregisteredOffMarketPool_HonestUserMinOut_RevertsRouterE5() public {
        Route memory r = _forged();
        uint256 honest = _marketOut(AMT) * 9_950 / 10_000;
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, uint16(5)));
        router.swapExactIn(r, AMT, honest, user, block.timestamp + 1);
    }
}
