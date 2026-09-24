// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  A SOLIDLY LEG IS QUOTED AT WHAT THE EXECUTOR ASKS FOR.
//
//  The executor never asks a Solidly pair for its whole `getAmountOut`: it asks
//  one wei less, the rounding margin that keeps the pair's own K check satisfied.
//  The quote channel read `getAmountOut` itself, so every plan and every preview
//  promised one wei more than a Solidly leg can deliver. With one leg the preview
//  has no safety buffer to absorb it, and when the output is a bridge coin the
//  fee is charged on that output: the published netOut then exceeds the delivery
//  by exactly that wei, `canExecute` says yes, and an integrator who passes the
//  published netOut as userMinOut is refused by the Router.
//
//  One producer now answers both questions: `Core.solidlyAskOut`, which the executor
//  settles on and `universalQuote` promises.
//
//  Reported by mohaseenbasha (dex-13), ninth bounty wave.
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixQuoter} from "../src/BlazePhoenixQuoter.sol";
import {BlazePhoenixCore as BPC, QuoteCtx} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockSolidlyPair} from "./mocks/MockSolidlyPair.sol";

interface IERC20Ask {
    function transfer(address to, uint256 amt) external returns (bool);
    function balanceOf(address who) external view returns (uint256);
}

/// @dev A volatile Solidly pair whose swap enforces K on its balances, as the
///      real pair does, so an over-ask reverts instead of being paid.
contract SolidlyPairAsk {
    address public token0;
    address public token1;
    uint112 public reserve0;
    uint112 public reserve1;
    bool    public constant stable = false;
    uint256 public constant feeBps = 30;

    constructor(address a, address b) { (token0, token1) = a < b ? (a, b) : (b, a); }

    function setReserves(uint112 r0, uint112 r1) external { reserve0 = r0; reserve1 = r1; }
    function getReserves() external view returns (uint112, uint112, uint32) {
        return (reserve0, reserve1, uint32(block.timestamp));
    }
    function getAmountOut(uint256 amountIn, address tokenIn) external view returns (uint256) {
        (uint256 rIn, uint256 rOut) = tokenIn == token0
            ? (uint256(reserve0), uint256(reserve1))
            : (uint256(reserve1), uint256(reserve0));
        return BPC.outSolidly(amountIn, rIn, rOut, feeBps, false);
    }
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata) external {
        uint256 r0 = reserve0;
        uint256 r1 = reserve1;
        if (amount0Out > 0) IERC20Ask(token0).transfer(to, amount0Out);
        if (amount1Out > 0) IERC20Ask(token1).transfer(to, amount1Out);
        uint256 b0 = IERC20Ask(token0).balanceOf(address(this));
        uint256 b1 = IERC20Ask(token1).balanceOf(address(this));
        require(b0 * b1 >= r0 * r1, "SolidlyPairAsk: K");
        reserve0 = uint112(b0);
        reserve1 = uint112(b1);
    }
}

contract SolidlyQuoteIsTheExecutorsAskTest is Test {
    uint112 constant RESERVE = 1_000_000e18;
    uint256 constant AMT     = 1_000e18;
    address constant USER    = address(0xBEEF);

    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    BlazePhoenixRouter router;
    BlazePhoenixQuoter quoter;
    MockERC20 tokenIn;
    MockERC20 bridgeOut;   // a bridge coin: a one-hop route pays its fee on this output
    SolidlyPairAsk pair;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        solver = new BlazePhoenixSolver(address(hub));
        router = new BlazePhoenixRouter(address(hub), address(solver), address(this), address(0xFEE1), address(0xFEE2));
        hub.setRoles(address(router), address(solver), address(this));
        quoter = new BlazePhoenixQuoter(address(hub), address(solver));

        tokenIn = new MockERC20("IN", "IN");
        bridgeOut = new MockERC20("BRIDGE", "BRIDGE");
        hub.addBridge(address(bridgeOut));

        pair = new SolidlyPairAsk(address(tokenIn), address(bridgeOut));
        tokenIn.mint(address(pair), RESERVE);
        bridgeOut.mint(address(pair), RESERVE);
        pair.setReserves(RESERVE, RESERVE);
        hub.seedPool(address(pair), BPC.KIND_SOLIDLY, 30, address(0), address(tokenIn), address(bridgeOut));

        tokenIn.mint(USER, 10 * AMT);
        vm.prank(USER);
        tokenIn.approve(address(router), type(uint256).max);
    }

    /// The claim, end to end: the netOut the preview publishes is a userMinOut the
    /// Router honours.
    function test_ThePublishedNetOutOfASolidlyRouteIsAMinOutTheRouterHonours() public {
        (BlazePhoenixQuoter.Preview memory pv, , ) = quoter.previewPlan(address(tokenIn), address(bridgeOut), AMT);
        assertEq(pv.hops, 1, "setup: one hop, so the fee is charged on the bridge-coin output");
        assertEq(pv.legs, 1, "setup: one leg, so no safety buffer absorbs anything");
        assertEq(pv.route.hops[0].legs[0].pool, address(pair), "setup: the leg is the Solidly pair");
        assertTrue(pv.canExecute, "setup: the preview calls the route executable");

        uint256 before = bridgeOut.balanceOf(USER);
        vm.prank(USER);
        try router.swapExactIn(pv.route, AMT, pv.netOut, USER, block.timestamp + 1) {
            assertGe(bridgeOut.balanceOf(USER) - before, pv.netOut, "delivered below the published netOut");
        } catch {
            assertTrue(false, "the Router refused the userMinOut its own preview published");
        }
    }

    /// The producer: the quote of a Solidly leg is the amount the executor asks the
    /// pair for, not the pair's own figure one wei above it.
    function test_TheSolidlyQuoteIsTheExecutorsAsk() public view {
        QuoteCtx memory c;
        c.kind       = BPC.KIND_SOLIDLY;
        c.pool       = address(pair);
        c.zeroForOne = address(tokenIn) < address(bridgeOut);
        c.fee        = 30;
        c.tokenIn    = address(tokenIn);
        c.tokenOther = address(bridgeOut);
        (uint256 q, ) = BPC.universalQuote(c, AMT);
        assertEq(q, pair.getAmountOut(AMT, address(tokenIn)) - 1, "the quote is not what the executor asks for");
    }

    /// The producer across its dimensions: the stable and the volatile curve, a pair that answers
    /// getAmountOut and one that does not (the replicated curve at the live fee, less the fork
    /// haircut), both directions over unequal reserves. In every cell the quote is the executor's
    /// ask; where the pair answers, the ask is its own figure less one wei; where it does not,
    /// the ask never exceeds what the pair pays.
    function test_EveryCellOfTheSolidlyQuoteIsTheExecutorsAsk() public {
        for (uint256 cell; cell < 8; ++cell) {
            bool st = cell & 1 == 1;
            bool hidden = cell & 2 == 2;
            bool fwd = cell & 4 == 4;
            MockSolidlyPair p = new MockSolidlyPair(address(tokenIn), address(bridgeOut), st);
            p.setReserves(RESERVE, RESERVE * 3 / 2);
            p.setHideGetAmountOut(hidden);
            (address tIn, address tOut) = fwd
                ? (address(tokenIn), address(bridgeOut)) : (address(bridgeOut), address(tokenIn));
            QuoteCtx memory c;
            c.kind       = BPC.KIND_SOLIDLY;
            c.pool       = address(p);
            c.zeroForOne = tIn < tOut;
            c.fee        = 30;
            c.stable     = st;
            c.tokenIn    = tIn;
            c.tokenOther = tOut;
            (uint256 q, ) = BPC.universalQuote(c, AMT);
            assertEq(q, BPC.solidlyAskOut(address(p), AMT, tIn, c.zeroForOne, st, 30),
                "the quote is not the executor's ask");
            (uint256 rIn, uint256 rOut) = tIn == p.token0()
                ? (uint256(p.reserve0()), uint256(p.reserve1()))
                : (uint256(p.reserve1()), uint256(p.reserve0()));
            uint256 pays = BPC.outSolidly(AMT, rIn, rOut, 30, st);
            assertGt(q, 0, "a cell went unquoted");
            if (hidden) assertLe(q, pays, "the replicated curve asks for more than the pair pays");
            else assertEq(q, pays - 1, "the ask is not the pair's own figure less one wei");
        }
    }
}
