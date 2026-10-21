// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  The two forms of `owed` in the Router's payment callback (M3, 2026-10-21).
//  Red at 85720ef (token-named form): `owed` was the first positive word, so a
//  pool that names its token in the first word demanded the token's address as
//  an amount, above the leg's ceiling, and the swap was refused (RouterE(8)).
//
//  The fallback reads the first two words of ANY callback as (a0, a1) and
//  `_v3Callback` decides what is owed:
//    - delta pair (Uniswap V3 / Algebra): owed = the positive delta;
//    - token named (Maverick V2 layout, maverickV2SwapCallback(tokenIn,
//      amountIn, amountOut, data)): a0 is the context's tokenIn, owed = a1.
//  Fail-closed: a pool that names the token with a NEGATIVE amount reads a
//  huge uint above the leg's ceiling and is refused (RouterE(8)); that test and
//  the delta-pair one were green at 85720ef too, and pin that M3 opens nothing.
//  The pool is V3-shaped on the call side; only its callback form varies.
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

interface IERC20OwedForms {
    function transfer(address to, uint256 amt) external returns (bool);
    function balanceOf(address who) external view returns (uint256);
}

interface IV3CallbackOwedForms {
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external;
}

interface IMaverickV2CallbackOwedForms {
    function maverickV2SwapCallback(address tokenIn, uint256 amountIn, uint256 amountOut, bytes calldata data) external;
}

/// @dev V3-shaped pool (slot0, liquidity, fee, swap) whose payment callback
///      takes one of three forms: 0 = delta pair, 1 = token named (Maverick V2
///      layout), 2 = token named with a negative amount. Single tick, priced
///      by the same BPC.outV3 the Router quotes with.
contract OwedFormV3Pool {
    address public token0;
    address public token1;
    uint24  public fee;
    uint160 public sqrtPriceX96;
    uint128 public liquidity;
    uint8   public form;

    constructor(address a, address b, uint24 f) {
        (token0, token1) = a < b ? (a, b) : (b, a);
        fee = f;
    }

    function setState(uint160 p, uint128 l) external { sqrtPriceX96 = p; liquidity = l; }
    function setForm(uint8 f) external { form = f; }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (sqrtPriceX96, 0, 0, 0, 0, 0, true);
    }

    function swap(
        address recipient, bool zeroForOne, int256 amountSpecified,
        uint160, bytes calldata data
    ) external returns (int256 amount0, int256 amount1) {
        require(amountSpecified > 0, "OwedFormV3Pool: exact-out unsupported");
        uint256 amtIn = uint256(amountSpecified);
        uint256 amtOut = BPC.outV3(amtIn, sqrtPriceX96, liquidity, fee, zeroForOne, 0);
        require(amtOut > 0, "OwedFormV3Pool: zero out");
        address tokenIn  = zeroForOne ? token0 : token1;
        address tokenOut = zeroForOne ? token1 : token0;
        amount0 = zeroForOne ? int256(amtIn) : -int256(amtOut);
        amount1 = zeroForOne ? -int256(amtOut) : int256(amtIn);

        uint256 balBefore = IERC20OwedForms(tokenIn).balanceOf(address(this));
        if (form == 0) {
            IV3CallbackOwedForms(msg.sender).uniswapV3SwapCallback(amount0, amount1, data);
        } else if (form == 1) {
            IMaverickV2CallbackOwedForms(msg.sender).maverickV2SwapCallback(tokenIn, amtIn, amtOut, data);
        } else {
            IV3CallbackOwedForms(msg.sender).uniswapV3SwapCallback(
                int256(uint256(uint160(tokenIn))), -int256(amtOut), data);
        }
        uint256 received = IERC20OwedForms(tokenIn).balanceOf(address(this)) - balBefore;
        // Form 2 does not demand its input: a payment of any size would let the
        // swap settle, so only the callback's own refusal can stop it.
        if (form != 2) require(received >= amtIn, "OwedFormV3Pool: insufficient input");
        IERC20OwedForms(tokenOut).transfer(recipient, amtOut);
    }
}

contract V3CallbackOwedFormsTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixRouter router;
    MockERC20 tokenA;
    MockERC20 tokenB;
    OwedFormV3Pool pool;

    address constant USER = address(0xBEEF);
    uint160 constant SQRT_P_1  = 79228162514264337593543950336; // price 1.0
    uint128 constant LIQ       = 1_000_000e18;
    uint256 constant AMOUNT_IN = 10_000e18;
    uint24  constant FEE       = 3000;
    uint256 constant FEE_IN    = (AMOUNT_IN * BPC.PROTOCOL_FEE_BPS) / 10_000;
    uint256 constant IN_NET    = AMOUNT_IN - FEE_IN;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        BlazePhoenixSolver solver = new BlazePhoenixSolver(address(hub));
        router = new BlazePhoenixRouter(
            address(hub), address(solver), address(this), address(0xFEE1), address(0xFEE2));
        hub.setRoles(address(router), address(solver), address(this));

        tokenA = new MockERC20("A", "A");
        tokenB = new MockERC20("B", "B");
        pool = new OwedFormV3Pool(address(tokenA), address(tokenB), FEE);
        pool.setState(SQRT_P_1, LIQ);
        tokenA.mint(address(pool), 1_000_000e18);
        tokenB.mint(address(pool), 1_000_000e18);
        hub.seedPool(address(pool), BPC.KIND_V3, FEE, address(0), address(tokenA), address(tokenB));

        tokenA.mint(USER, 10_000_000e18);
        tokenB.mint(USER, 10_000_000e18);
        vm.startPrank(USER);
        tokenA.approve(address(router), type(uint256).max);
        tokenB.approve(address(router), type(uint256).max);
        vm.stopPrank();
    }

    function _route(address tIn, address tOut) internal view returns (Route memory r) {
        Leg[] memory legs = new Leg[](1);
        legs[0] = Leg({
            pool: address(pool), hooks: address(0), kind: BPC.KIND_V3, fee: FEE,
            tickSpacing: 0, zeroForOne: tIn == pool.token0(), stable: false,
            amountIn: AMOUNT_IN, expectedOut: 0, auxId: bytes32(0)
        });
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({tokenIn: tIn, tokenOut: tOut, amountIn: AMOUNT_IN, expectedOut: 0, legs: legs});
        r = Route({
            hops: hops, totalOut: 0, singleOut: 0, singleOutFloor: 0,
            expectedImpactBps: 0, confidenceWad: 0, estGas: 0,
            hasSurplus: false, isV4Bundle: false
        });
    }

    /// @dev One swap tIn -> tOut; the pool must be paid exactly IN_NET and the
    ///      user must receive the pool's own figure for it.
    function _swapPaysExactly(MockERC20 tIn, MockERC20 tOut, string memory what) internal {
        bool zfo = address(tIn) == pool.token0();
        uint256 expectOut = BPC.outV3(IN_NET, SQRT_P_1, LIQ, FEE, zfo, 0);
        uint256 poolInBefore = tIn.balanceOf(address(pool));
        uint256 userOutBefore = tOut.balanceOf(USER);
        // The route is built BEFORE the prank: _route reads pool.token0(), and a
        // prank is spent on the next external call.
        Route memory r = _route(address(tIn), address(tOut));
        vm.prank(USER);
        uint256 delivered = router.swapExactIn(r, AMOUNT_IN, 1, USER, block.timestamp + 1);
        assertEq(tIn.balanceOf(address(pool)) - poolInBefore, IN_NET, what);
        assertEq(delivered, expectOut, "delivered == the pool's figure");
        assertEq(tOut.balanceOf(USER) - userOutBefore, delivered, "reported == received");
    }

    /// @notice Delta pair, both directions: the positive delta is paid, once,
    ///         exactly. One direction has the owed amount in a0, the other in a1.
    function test_ADeltaPairCallbackIsPaidItsPositiveDeltaInBothDirections() public {
        pool.setForm(0);
        _swapPaysExactly(tokenA, tokenB, "delta pair, A->B: the pool is paid exactly its positive delta");
        _swapPaysExactly(tokenB, tokenA, "delta pair, B->A: the pool is paid exactly its positive delta");
    }

    /// @notice Token named (Maverick V2 layout): a0 is the context's tokenIn,
    ///         the amount in a1 is paid, both directions.
    function test_ATokenNamedCallbackIsPaidTheNamedAmountInBothDirections() public {
        pool.setForm(1);
        _swapPaysExactly(tokenA, tokenB, "token named, A->B: the pool is paid exactly the named amount");
        _swapPaysExactly(tokenB, tokenA, "token named, B->A: the pool is paid exactly the named amount");
    }

    /// @notice Token named with a NEGATIVE amount: the owed word is a huge uint
    ///         above the leg's ceiling, and the swap is refused. The pool does
    ///         not demand its input, so only the callback's refusal stops it.
    function test_ATokenNamedCallbackWithANegativeAmountIsRefused() public {
        pool.setForm(2);
        Route memory r = _route(address(tokenA), address(tokenB));
        vm.prank(USER);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, uint16(8)));
        router.swapExactIn(r, AMOUNT_IN, 1, USER, block.timestamp + 1);
    }
}
