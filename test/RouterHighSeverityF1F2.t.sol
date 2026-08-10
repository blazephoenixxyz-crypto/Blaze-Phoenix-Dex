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
        hub = new BlazePhoenixHub(address(this));
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

        // BP-04 forces userMinOut > 0 (RouterE(10)), so use a DELIBERATELY
        // weak user bound: 1e18 sits far below both the on-chain quote
        // (~700e18 — the helper's fee field is 3000 and outV2 is BPS-
        // denominated, i.e. a 30% fee pool; the floor property is ratio-
        // based and does not care) and the short-pay fill (~350e18 = 50% of
        // the ~700e18 the Router asks the pair for). Attribution is
        // therefore contrafactual: if the protocol floor were inert (the
        // original F1 bug), this swap would SUCCEED (delivered ~349e18 >>
        // 1e18) — the RouterE(5) below can only come from the protocol
        // floor (96% of the final-hop on-chain quote ≈ 672e18) rejecting
        // the 50% fill. The test still targets the FLOOR, not the user's
        // own slippage bound.
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, uint16(5)));
        router.swapExactIn(route, amountIn, 1e18, user, block.timestamp + 1);
    }

    // ─── F1b (BP-02 × hop-0 cap seam): a plan that commits LESS than the
    //      pulled amountIn (phantom-tier clamp) must still EXECUTE — the
    //      floor prices the capped amounts, never a scaled-up quote that
    //      execution does not spend. Red before the pre-quote-cap fix
    //      (false RouterE(5)), green after. ───
    function test_F1b_Floor_AllowsLegitFillWhenHop0CapBinds() public {
        ShortPayV2Pair pair = new ShortPayV2Pair(address(tokenIn), address(tokenOut));
        pair.setReserves(uint112(1e30), uint112(1e30));
        // Honest pair: default payNum/payDen = 1/1 — pays exactly what it is
        // asked. This test is about the floor's quote base, not underpay.
        tokenOut.mint(address(pair), 1e24);

        uint256 amountIn = 1_000e18;
        // The leg commits only 600e18 of the 1_000e18 pulled: scaleNum
        // (1000e18) > scaleDen (Σ leg.amountIn = 600e18). Pre-fix the quote
        // was scaled UP by 1000/600 while execution capped to 600e18 —
        // realised ≈ 60% of the quote < 96% floor → false RouterE(5).
        // Post-fix quote == executed amounts → the swap succeeds and the
        // uncommitted 400e18 is swept back to the caller.
        Route memory route = _singleLegRoute(BPC.KIND_V2, address(pair), 600e18);
        // Realistic 0.30% V2 fee IN BPS (the helper's default of 3000 means
        // 30% to outV2 — fine for F1's ratio property, wrong for the
        // absolute bounds asserted here): quote = outV2(600e18) ≈ 598.2e18,
        // floor ≈ 574.3e18, delivered after the 28 bps protocol fee
        // ≈ 596.5e18.
        route.hops[0].legs[0].fee = 30;
        // Keep the hop's own header honest about the full pull (the Router
        // derives its spend cap from Σ leg.amountIn, never from this field).
        route.hops[0].amountIn = amountIn;

        uint256 outBefore = tokenOut.balanceOf(user);
        uint256 inBefore  = tokenIn.balanceOf(user);
        vm.prank(user);
        router.swapExactIn(route, amountIn, 1, user, block.timestamp + 1);
        // Bound tolerates the 28 bps protocol fee with wide margin (fails
        // only if the protocol fee ever exceeds ~6%).
        assertGt(tokenOut.balanceOf(user) - outBefore, 560e18);
        // Only the committed 600e18 left the user's balance for good — the
        // hop-0 cap held (issue #1 still enforced: max spend Σ leg.amountIn)
        // and the residual sweep returned the uncommitted 400e18.
        assertEq(inBefore - tokenIn.balanceOf(user), 600e18);
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
        // userMinOut = 1 satisfies the BP-04 entry guard (RouterE(10)); it is
        // never evaluated — the single-shot callback guard reverts mid-
        // execution, on the second pull.
        router.swapExactIn(route, amountIn, 1, user, block.timestamp + 1);
        // NOTE: zfo referenced so the compiler keeps the address-ordering intent
        // explicit for a reader auditing which token is the "owed" side.
        assertTrue(zfo == (address(tokenIn) < address(tokenOut)));
    }

    // ─── BP-04 positive coverage: the entry guard itself stays covered ───
    // After this change-set every swap call site in the suite passes
    // userMinOut > 0, so without THIS test the suite would stay green even
    // if a refactor deleted the guard — silently reopening the unbounded-
    // sandwich gap BP-04 closes. The guard precedes all route validation,
    // so an empty route suffices. (swapExactInWithPermit2 carries the byte-
    // identical guard line; its coverage belongs with the permit2 fixtures —
    // see the Seam Register / residual.)
    function test_BP04_ZeroMinOutReverts_AndZeroAmountDoesNot() public {
        Route memory route;   // empty: the guard fires before route checks
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, uint16(10)));
        router.swapExactIn(route, 1e18, 0, user, block.timestamp + 1);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, uint16(10)));
        router.swapExactInWith7702(route, 1e18, 0, user, block.timestamp + 1);
        // I8 idempotence: a zero-amount call must never revert ON THE GUARD —
        // this one reverts later, for its own reason (RouterE(3): empty
        // route), proving the guard is conditioned on amountIn > 0.
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, uint16(3)));
        router.swapExactIn(route, 0, 0, user, block.timestamp + 1);
    }
}
