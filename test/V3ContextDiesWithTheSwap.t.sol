// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  THE V3 PAYMENT CONTEXT DIES WITH THE SWAP THAT OPENED IT (revisao-total 2026-10-23)
//
//  `_execV3Amt` writes the transient context (pool, tokenIn, amount) the payment
//  callback authenticates against, calls `pool.swap`, and clears it when the swap
//  returns. `_v3Callback` clears it too, on consumption (M3, single use). The clear
//  after the swap is the only one that runs when the pool RETURNS WITHOUT CALLING
//  BACK: without it the context outlives the swap for the rest of the transaction,
//  and the router's fallback - which asks no lock, only the context - pays the pool
//  up to `amount` of tokenIn out of whatever the Router holds (fee shares a payee
//  refused, kept for their owner).
//
//  No test could see the clear: its mutant survived the Router's whole callback
//  and fee suites (mutant run, revisao-total). Transient storage is reset between
//  the test's top-level calls (Foundry), so the attack runs inside ONE call: a
//  contract swaps through a pool that pays the output out of its own pocket and
//  never calls back, then has the pool call the fallback.
//
//  forge test --match-path test/V3ContextDiesWithTheSwap.t.sol -vv
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @notice V3-shaped pool that pays the output without asking for the input, then,
///         when told, calls the Router's payment callback on its own.
contract SilentThenPullV3Pool {
    address public token0;
    address public token1;
    uint24  public fee;
    uint160 public sqrtPriceX96;
    uint128 public liquidity;

    bool  public pullOk;
    bytes public pullRet;

    constructor(address a, address b, uint24 f) {
        (token0, token1) = a < b ? (a, b) : (b, a);
        fee = f;
    }

    function setState(uint160 p, uint128 l) external { sqrtPriceX96 = p; liquidity = l; }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (sqrtPriceX96, 0, 0, 0, 0, 0, true);
    }

    function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160, bytes calldata)
        external returns (int256 amount0, int256 amount1)
    {
        uint256 amtIn  = uint256(amountSpecified);
        uint256 amtOut = BPC.outV3(amtIn, sqrtPriceX96, liquidity, fee, zeroForOne, 0);
        amount0 = zeroForOne ? int256(amtIn) : -int256(amtOut);
        amount1 = zeroForOne ? -int256(amtOut) : int256(amtIn);
        MockERC20(zeroForOne ? token1 : token0).transfer(recipient, amtOut); // no callback
    }

    /// The same callback a swap would have sent, sent later, by the same pool.
    function pull(address router, int256 a0, int256 a1) external {
        (pullOk, pullRet) = router.call(
            abi.encodeWithSignature("uniswapV3SwapCallback(int256,int256,bytes)", a0, a1, bytes("")));
    }
}

/// @notice Swaps and then has the pool pull, in one call: one transaction, one
///         transient store.
contract SwapThenPull {
    function run(BlazePhoenixRouter router, SilentThenPullV3Pool pool, Route calldata route,
                 MockERC20 tIn, uint256 amt, bool zfo, uint256 pullAmt) external {
        tIn.approve(address(router), amt);
        router.swapExactIn(route, amt, 1, address(this), block.timestamp + 1);
        int256 p = int256(pullAmt);
        pool.pull(address(router), zfo ? p : int256(0), zfo ? int256(0) : p);
    }
}

contract V3ContextDiesWithTheSwapTest is Test {
    BlazePhoenixHub    hub;
    BlazePhoenixSolver solver;
    BlazePhoenixRouter router;
    MockERC20 tokenIn;
    MockERC20 tokenOut;

    uint256 constant AMT   = 1_000e18;
    uint256 constant DEPTH = 1_000_000e18;
    uint24  constant PFEE  = 3000;

    function setUp() public {
        hub    = new BlazePhoenixHub(address(this));
        solver = new BlazePhoenixSolver(address(hub), address(0));
        router = new BlazePhoenixRouter(address(hub), address(solver), address(this), address(0xFEE1), address(0xFEE2));
        hub.setRoles(address(router), address(solver), address(this));
        tokenIn  = new MockERC20("In", "IN");
        tokenOut = new MockERC20("Out", "OUT");
    }

    function _route(address pool, bool zfo, uint256 expectedOut) private view returns (Route memory) {
        Leg[] memory legs = new Leg[](1);
        legs[0] = Leg({
            pool: pool, hooks: address(0), kind: BPC.KIND_V3, fee: PFEE,
            tickSpacing: 60, zeroForOne: zfo, stable: false,
            amountIn: AMT, expectedOut: expectedOut, auxId: bytes32(0)
        });
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({tokenIn: address(tokenIn), tokenOut: address(tokenOut),
                       amountIn: AMT, expectedOut: expectedOut, legs: legs});
        return Route({hops: hops, totalOut: expectedOut, singleOut: expectedOut,
                      singleOutFloor: 0, expectedImpactBps: 0, confidenceWad: 0,
                      estGas: 0, hasSurplus: false, isV4Bundle: false});
    }

    /// FAILS IF DELETED: yes - with the clear after `pool.swap` removed the late callback
    /// finds the swap's context, and the Router pays the pool the AMT it holds for others.
    function test_ALateCallbackFromTheSamePool_FindsNoContext() public {
        bool zfo = address(tokenIn) < address(tokenOut);
        SilentThenPullV3Pool pool = new SilentThenPullV3Pool(address(tokenIn), address(tokenOut), PFEE);
        pool.setState(uint160(BPC.Q96), uint128(DEPTH));
        tokenOut.mint(address(pool), DEPTH);
        uint256 expectedOut = BPC.outV3(AMT, uint160(BPC.Q96), uint128(DEPTH), PFEE, zfo, 0);

        // What the Router holds that is not this swap's: the budget a late pull would take.
        tokenIn.mint(address(router), AMT);

        SwapThenPull caller = new SwapThenPull();
        tokenIn.mint(address(caller), AMT);
        // The late pull asks for less than the leg's own budget (AMT less the protocol fee), so
        // only a dead context can refuse it - not the amount bound (RouterE(8)).
        caller.run(router, pool, _route(address(pool), zfo, expectedOut), tokenIn, AMT, zfo, AMT / 2);

        assertGt(tokenOut.balanceOf(address(caller)), 0, "setup: the swap settled");
        assertFalse(pool.pullOk(), "a callback after the swap returned was paid");
        assertEq(pool.pullRet(), abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, uint16(6)),
            "the late callback must find no context (RouterE(6))");
        assertGe(tokenIn.balanceOf(address(router)), AMT, "the Router's budget left with the late callback");
    }
}
