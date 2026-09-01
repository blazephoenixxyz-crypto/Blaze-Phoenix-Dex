// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  The V3-shaped callback's sender check is the Router's most consequential
//  guard, and until this file nothing proved a test would catch its removal.
//
//  `_v3Callback` opens with:
//
//      if (msg.sender != expected || expected == address(0)) revert RouterE(6);
//
//  `expected` is the pool the Router is currently swapping against, written to
//  transient storage immediately before the call and cleared immediately after
//  it is validated. The guard says: only the pool I am talking to right now may
//  ask me to pay, and only once.
//
//  WHY THE EXISTING COVERAGE DOES NOT WATCH IT. The one direct-invocation test
//  (`test_Fallback_RevertsWhenNoExpectedPoolIsSet`) calls the callback from
//  OUTSIDE any swap and asserts only `bytes4(ret) == RouterE.selector` — the
//  selector, never the code. Outside a swap the transient context is empty, so
//  deleting the sender check does not make that call succeed: it falls through
//  to `owed > maxAmt` with maxAmt == 0 and reverts RouterE(8). Same selector,
//  test still green. The guard can be removed with the suite staying green.
//
//  WHAT THIS FILE ADDS. The case the guard actually exists for: a swap IS in
//  flight, so `expected` and `maxAmt` are both live and non-zero — and a
//  DIFFERENT contract asks to be paid. The pool the Router trusts hands the
//  callback to an impostor instead of making it itself.
//
//    with the guard   -> RouterE(6), impostor receives nothing
//    without it       -> the impostor's address is `msg.sender`, `owed` is
//                        under `maxAmt`, and the Router transfers the leg's
//                        input tokens TO THE IMPOSTOR. That is the drain.
//
//  The impostor swallows the revert so the swap continues either way; the
//  discriminating assertion is its balance, not the revert.
//
//  forge test --match-contract CallbackAuthImpostorDrain -vv
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixRouter, IPermit2} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

interface IERC20X {
    function transfer(address to, uint256 amt) external returns (bool);
    function balanceOf(address who) external view returns (uint256);
}

/// @notice Calls the Router's V3 callback on the pool's behalf. It is NOT the
///         address the Router is expecting, which is the entire point.
///         Failures are swallowed so the surrounding swap proceeds and the
///         test's verdict rests on where the money went, not on a revert.
contract Impostor {
    bool public tried;
    bool public callSucceeded;

    function fire(address router, int256 a0, int256 a1) external {
        tried = true;
        (bool ok, ) = router.call(
            abi.encodeWithSignature(
                "uniswapV3SwapCallback(int256,int256,bytes)", a0, a1, bytes("")
            )
        );
        callSucceeded = ok;
    }
}

/// @notice A V3-shaped pool that behaves normally except for one thing: it asks
///         an accomplice to make the callback instead of making it itself. Every
///         other read the Router performs (slot0, token0/1, fee) answers exactly
///         as the honest mock does, so the Router reaches the callback by the
///         ordinary path and the ONLY thing under test is who calls back.
contract ImpostorRoutingV3Pool {
    address public token0;
    address public token1;
    uint24  public fee;
    uint160 public sqrtPriceX96;
    uint128 public liquidity;
    Impostor public immutable impostor;

    constructor(address _t0, address _t1, uint24 _fee, Impostor _imp) {
        (token0, token1) = _t0 < _t1 ? (_t0, _t1) : (_t1, _t0);
        fee = _fee;
        impostor = _imp;
    }

    function setState(uint160 p, uint128 l) external { sqrtPriceX96 = p; liquidity = l; }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (sqrtPriceX96, 0, 0, 0, 0, 0, true);
    }

    function swap(
        address recipient, bool zeroForOne, int256 amountSpecified,
        uint160 /*sqrtPriceLimitX96*/, bytes calldata /*data*/
    ) external returns (int256 amount0, int256 amount1) {
        uint256 amtIn  = uint256(amountSpecified);
        uint256 amtOut = BPC.outV3(amtIn, sqrtPriceX96, liquidity, fee, zeroForOne, 0);
        require(amtOut > 0, "ImpostorPool: zero out");

        address tokenIn  = zeroForOne ? token0 : token1;
        address tokenOut = zeroForOne ? token1 : token0;

        amount0 = zeroForOne ? int256(amtIn) : -int256(amtOut);
        amount1 = zeroForOne ? -int256(amtOut) : int256(amtIn);

        // THE SUBSTITUTION. An honest pool calls
        // IV3SwapCallback(msg.sender).uniswapV3SwapCallback(...) itself.
        uint256 balBefore = IERC20X(tokenIn).balanceOf(address(this));
        impostor.fire(msg.sender, amount0, amount1);
        uint256 received = IERC20X(tokenIn).balanceOf(address(this)) - balBefore;

        // DELIBERATELY NO `require(received >= amtIn)`. A real pool would
        // refuse to deliver unpaid — but that revert would roll the whole
        // transaction back, and with it every state write the test needs to
        // read, including the impostor's own record that it ever ran. The
        // first version of this test asserted on exactly such an erased
        // variable and would have passed while proving nothing. The pool
        // therefore eats the loss and settles, so the verdict can be read
        // from persisted state: who holds the input tokens afterwards.
        received; // measured above; intentionally not enforced, see comment
        IERC20X(tokenOut).transfer(recipient, amtOut);
    }
}

contract CallbackAuthImpostorDrainTest is Test {
    BlazePhoenixHub    hub;
    BlazePhoenixRouter router;
    MockERC20 tokenIn;
    MockERC20 tokenOut;

    address user      = address(0xBEEF);
    address treasury1 = address(0xFEE1);
    address treasury2 = address(0xFEE2);

    function setUp() public {
        hub    = new BlazePhoenixHub(address(this));
        router = new BlazePhoenixRouter(
            address(hub), address(0xBEE2), address(this), treasury1, treasury2
        );
        tokenIn  = new MockERC20("IN",  "IN");
        tokenOut = new MockERC20("OUT", "OUT");
    }

    /// THE CLAIM: while a swap is in flight, a contract that is not the pool
    /// the Router is talking to must never be paid by the callback.
    ///
    /// RED WITHOUT THE GUARD: the impostor's balance is the leg's full input.
    function test_ImpostorCallingTheCallbackMidSwapIsNeverPaid() public {
        Impostor imp = new Impostor();
        bool zfo = address(tokenIn) < address(tokenOut);

        ImpostorRoutingV3Pool pool =
            new ImpostorRoutingV3Pool(address(tokenIn), address(tokenOut), 3000, imp);
        uint160 sqrtP = uint160(BPC.Q96);
        uint128 liq   = 1_000_000e18;
        pool.setState(sqrtP, liq);
        tokenOut.mint(address(pool), 1_000_000e18);

        uint256 amountIn   = 1_000e18;
        uint256 expectedOut = BPC.outV3(amountIn, sqrtP, liq, 3000, zfo, 0);
        assertGt(expectedOut, 0, "setup: the pool must quote something");

        tokenIn.mint(user, amountIn);
        vm.prank(user);
        tokenIn.approve(address(router), amountIn);

        Leg[] memory legs = new Leg[](1);
        legs[0] = Leg({
            pool: address(pool), hooks: address(0), kind: BPC.KIND_V3, fee: 3000,
            tickSpacing: 60, zeroForOne: zfo, stable: false,
            amountIn: amountIn, expectedOut: expectedOut, auxId: bytes32(0)
        });
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({
            tokenIn: address(tokenIn), tokenOut: address(tokenOut),
            amountIn: amountIn, expectedOut: expectedOut, legs: legs
        });
        Route memory route = Route({
            hops: hops, totalOut: expectedOut, singleOut: expectedOut,
            singleOutFloor: 0, expectedImpactBps: 0, confidenceWad: 0,
            estGas: 0, hasSurplus: false, isV4Bundle: false
        });

        // The swap MUST settle for this test to mean anything — a reverted
        // transaction erases the very state the assertions read. The pool is
        // built to settle whether or not it was paid, precisely so that the
        // verdict below is about where the tokens ended up rather than about
        // which revert happened to fire first.
        vm.prank(user);
        try router.swapExactIn(route, amountIn, 1, user, block.timestamp + 1) {
        } catch {}

        assertTrue(imp.tried(), "vacuous: the impostor never reached the callback");
        assertFalse(imp.callSucceeded(),
            "the callback accepted a caller that was not the expected pool");
        assertEq(tokenIn.balanceOf(address(imp)), 0,
            "DRAIN: the Router paid the leg's input to a contract it was not swapping with");
    }

    /// Control: the same construction with the HONEST call path settles, so the
    /// test above fails for the substitution and not for the scaffolding.
    function test_Control_TheSameRouteSettlesWhenThePoolCallsBackItself() public {
        bool zfo = address(tokenIn) < address(tokenOut);
        // MockV3Pool is the honest twin of the pool above: identical reads,
        // identical maths, and it makes the callback itself.
        MockV3PoolLocal pool =
            new MockV3PoolLocal(address(tokenIn), address(tokenOut), 3000);
        uint160 sqrtP = uint160(BPC.Q96);
        uint128 liq   = 1_000_000e18;
        pool.setState(sqrtP, liq);
        tokenOut.mint(address(pool), 1_000_000e18);

        uint256 amountIn    = 1_000e18;
        uint256 expectedOut = BPC.outV3(amountIn, sqrtP, liq, 3000, zfo, 0);

        tokenIn.mint(user, amountIn);
        vm.prank(user);
        tokenIn.approve(address(router), amountIn);

        Leg[] memory legs = new Leg[](1);
        legs[0] = Leg({
            pool: address(pool), hooks: address(0), kind: BPC.KIND_V3, fee: 3000,
            tickSpacing: 60, zeroForOne: zfo, stable: false,
            amountIn: amountIn, expectedOut: expectedOut, auxId: bytes32(0)
        });
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({
            tokenIn: address(tokenIn), tokenOut: address(tokenOut),
            amountIn: amountIn, expectedOut: expectedOut, legs: legs
        });
        Route memory route = Route({
            hops: hops, totalOut: expectedOut, singleOut: expectedOut,
            singleOutFloor: 0, expectedImpactBps: 0, confidenceWad: 0,
            estGas: 0, hasSurplus: false, isV4Bundle: false
        });

        vm.prank(user);
        uint256 delivered = router.swapExactIn(route, amountIn, 1, user, block.timestamp + 1);
        assertGt(delivered, 0, "the honest path must still settle");
    }
}

/// @dev Local honest twin, byte-for-byte the same reads as the impostor pool
///      except that it makes the callback itself. Kept in-file so the control
///      and the subject differ in exactly one respect.
contract MockV3PoolLocal {
    address public token0;
    address public token1;
    uint24  public fee;
    uint160 public sqrtPriceX96;
    uint128 public liquidity;

    constructor(address _t0, address _t1, uint24 _fee) {
        (token0, token1) = _t0 < _t1 ? (_t0, _t1) : (_t1, _t0);
        fee = _fee;
    }

    function setState(uint160 p, uint128 l) external { sqrtPriceX96 = p; liquidity = l; }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (sqrtPriceX96, 0, 0, 0, 0, 0, true);
    }

    function swap(
        address recipient, bool zeroForOne, int256 amountSpecified,
        uint160 /*sqrtPriceLimitX96*/, bytes calldata data
    ) external returns (int256 amount0, int256 amount1) {
        uint256 amtIn  = uint256(amountSpecified);
        uint256 amtOut = BPC.outV3(amtIn, sqrtPriceX96, liquidity, fee, zeroForOne, 0);
        require(amtOut > 0, "MockV3PoolLocal: zero out");

        address tokenIn  = zeroForOne ? token0 : token1;
        address tokenOut = zeroForOne ? token1 : token0;

        amount0 = zeroForOne ? int256(amtIn) : -int256(amtOut);
        amount1 = zeroForOne ? -int256(amtOut) : int256(amtIn);

        uint256 balBefore = IERC20X(tokenIn).balanceOf(address(this));
        (bool ok, ) = msg.sender.call(
            abi.encodeWithSignature(
                "uniswapV3SwapCallback(int256,int256,bytes)", amount0, amount1, data
            )
        );
        require(ok, "MockV3PoolLocal: callback failed");
        uint256 received = IERC20X(tokenIn).balanceOf(address(this)) - balBefore;
        require(received >= amtIn, "MockV3PoolLocal: insufficient input");
        IERC20X(tokenOut).transfer(recipient, amtOut);
    }
}
