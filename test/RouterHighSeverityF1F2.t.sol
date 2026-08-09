// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// Regression tests for the two HIGH-severity findings sealed in vault note
// "093 - Selo da Mega-Caca" §3 (Agent 3, execution trapdoor):
//
//   F1 — the aggregate "protocol floor" was mathematically inert. It was a
//        fraction of the REALISED output (`mulDiv(totalReceived, floorBps, BPS)`
//        with floorBps < BPS), so `amountOut < protocolFloorOut` was impossible
//        and the floor never reverted anything. A route with singleOutFloor=0,
//        expectedOut=0 and userMinOut=0 therefore executed with NO floor at all.
//        Fix: derive the floor from the on-chain quote of the FINAL hop
//        (unforgeable by calldata, denominated in tokenOut), so a fill that
//        lands far below the quote actually reverts.
//
//   F2 — the universal V3-shaped callback cleared its transient (pool, token,
//        amt) context only AFTER pool.swap() returned, never inside the callback
//        itself. A malicious registered pool could re-enter the fallback
//        repeatedly during its own swap(), pulling up to maxAmt of tokenIn on
//        EACH re-entry — draining the input budgeted to sibling legs. Fix:
//        single-shot — clear the context inside _v3Callback BEFORE paying
//        (checks-effects-interactions), so the 2nd entry reads expected==0 and
//        reverts(6).
//
// forge test --match-contract RouterHighSeverityF1F2 -vvv

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

interface IERC20Min {
    function transfer(address to, uint256 amt) external returns (bool);
    function balanceOf(address who) external view returns (uint256);
}

interface IV3SwapCallback {
    function uniswapV3SwapCallback(int256 a0, int256 a1, bytes calldata data) external;
}

/// @notice V3-shaped pool that pulls the committed input TWICE from the Router
///         during a single swap(). A single-shot callback guard must reject the
///         second pull. Quotes via the same outV3 formula the Core uses, so the
///         Router's V3 quote/impact path reads live state as with an honest pool.
contract MaliciousMultiPullV3Pool {
    address public token0;
    address public token1;
    uint24  public fee;
    uint160 public sqrtPriceX96;
    uint128 public liquidity;

    constructor(address a, address b, uint24 f) {
        (token0, token1) = a < b ? (a, b) : (b, a);
        fee = f;
    }

    function setState(uint160 sp, uint128 lq) external { sqrtPriceX96 = sp; liquidity = lq; }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (sqrtPriceX96, 0, 0, 0, 0, 0, true);
    }

    function swap(
        address recipient, bool zeroForOne, int256 amountSpecified,
        uint160 /*limit*/, bytes calldata data
    ) external returns (int256 amount0, int256 amount1) {
        uint256 amtIn  = uint256(amountSpecified);
        uint256 amtOut = BPC.outV3(amtIn, sqrtPriceX96, liquidity, fee, zeroForOne);
        address tOut = zeroForOne ? token1 : token0;
        amount0 = zeroForOne ? int256(amtIn) : -int256(amtOut);
        amount1 = zeroForOne ? -int256(amtOut) : int256(amtIn);
        // ATTACK: two callbacks in one swap. Absent a single-shot guard, each
        // one passes msg.sender==expected and owed<=maxAmt, so the Router pays
        // `amtIn` of tokenIn TWICE.
        IV3SwapCallback(msg.sender).uniswapV3SwapCallback(amount0, amount1, data);
        IV3SwapCallback(msg.sender).uniswapV3SwapCallback(amount0, amount1, data);
        IERC20Min(tOut).transfer(recipient, amtOut);
    }
}

/// @notice V2-shaped pair that ADVERTISES fat reserves (so the Router's on-chain
///         quote is high) but DELIVERS only a fraction of what it is asked to
///         pay out — a fill far below the quote. Exercises the F1 floor.
contract ShortPayV2Pair {
    address public token0;
    address public token1;
    uint112 public reserve0;
    uint112 public reserve1;
    uint256 public payNum = 1;
    uint256 public payDen = 1;

    constructor(address a, address b) { (token0, token1) = a < b ? (a, b) : (b, a); }

    function setReserves(uint112 r0, uint112 r1) external { reserve0 = r0; reserve1 = r1; }
    function setPayRatio(uint256 n, uint256 d) external { payNum = n; payDen = d; }

    function getReserves() external view returns (uint112, uint112, uint32) {
        return (reserve0, reserve1, uint32(block.timestamp));
    }

    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata) external {
        if (amount0Out > 0) IERC20Min(token0).transfer(to, (amount0Out * payNum) / payDen);
        if (amount1Out > 0) IERC20Min(token1).transfer(to, (amount1Out * payNum) / payDen);
        reserve0 = uint112(IERC20Min(token0).balanceOf(address(this)));
        reserve1 = uint112(IERC20Min(token1).balanceOf(address(this)));
    }
}

contract RouterHighSeverityF1F2Test is Test {
    BlazePhoenixHub hub;
    BlazePhoenixRouter router;
    MockERC20 tokenIn;
    MockERC20 tokenOut;
    address user = address(0xBEEF);

    function setUp() public {
        hub = new BlazePhoenixHub();
        tokenIn  = new MockERC20("In", "IN");
        tokenOut = new MockERC20("Out", "OUT");
        router = new BlazePhoenixRouter(
            address(hub), address(0xBEEF), address(this), address(this), address(this)
        );
        tokenIn.mint(user, 10_000e18);
        vm.prank(user);
        tokenIn.approve(address(router), type(uint256).max);
    }

    function _singleLegRoute(uint8 kind, address pool, uint256 amountIn)
        private view returns (Route memory route)
    {
        bool zfo = address(tokenIn) < address(tokenOut);
        Leg[] memory legs = new Leg[](1);
        legs[0] = Leg({
            pool: pool, hooks: address(0), kind: kind, fee: 3000,
            tickSpacing: 60, zeroForOne: zfo, stable: false,
            amountIn: amountIn, expectedOut: 0, auxId: bytes32(0)   // expectedOut=0 => per-leg guard OFF
        });
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({
            tokenIn: address(tokenIn), tokenOut: address(tokenOut),
            amountIn: amountIn, expectedOut: 0, legs: legs
        });
        route = Route({
            hops: hops, totalOut: 0, singleOut: 0, singleOutFloor: 0,
            expectedImpactBps: 0, confidenceWad: 0, estGas: 0,
            hasSurplus: false, isV4Bundle: false
        });
    }

    // ─── F1: the protocol floor must actually bite on a far-below-quote fill ───
    function test_F1_ProtocolFloor_RevertsOnFillFarBelowQuote() public {
        ShortPayV2Pair pair = new ShortPayV2Pair(address(tokenIn), address(tokenOut));
        // Fat advertised reserves => ~0 impact => floorBps == FLOOR_BASE (96%).
        pair.setReserves(uint112(1e30), uint112(1e30));
        // Deliver only 50% of what the Router asks the pair to pay out.
        pair.setPayRatio(1, 2);
        tokenOut.mint(address(pair), 1e24);   // enough to pay the (halved) output

        uint256 amountIn = 1_000e18;
        Route memory route = _singleLegRoute(BPC.KIND_V2, address(pair), amountIn);

        // userMinOut = 0: with F1 inert, this route had NO floor and would
        // accept a 50% loss. After the fix the protocol floor (96% of the
        // on-chain quote) rejects it.
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, uint16(5)));
        router.swapExactIn(route, amountIn, 0, user, block.timestamp + 1);
    }

    // ─── F2: a V3 callback that re-enters to multi-pull must be rejected ───
    function test_F2_V3Callback_RejectsSecondPull() public {
        bool zfo = address(tokenIn) < address(tokenOut);
        MaliciousMultiPullV3Pool pool =
            new MaliciousMultiPullV3Pool(address(tokenIn), address(tokenOut), 3000);
        pool.setState(uint160(BPC.Q96), 1_000_000e18);
        tokenOut.mint(address(pool), 1_000_000e18);

        uint256 amountIn = 1_000e18;
        // The Router holds extra tokenIn beyond this leg's budget (the input a
        // sibling leg would spend). Absent the fix, the pool's SECOND pull
        // drains exactly this — and the holds-nothing sweep cannot recover it,
        // because baseIn accounting assumes it is still there.
        tokenIn.mint(address(router), amountIn);

        Route memory route = _singleLegRoute(BPC.KIND_V3, address(pool), amountIn);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, uint16(6)));
        router.swapExactIn(route, amountIn, 0, user, block.timestamp + 1);
        // NOTE: zfo referenced so the compiler keeps the address-ordering intent
        // explicit for a reader auditing which token is the "owed" side.
        assertTrue(zfo == (address(tokenIn) < address(tokenOut)));
    }
}
