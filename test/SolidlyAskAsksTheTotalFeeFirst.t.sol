// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  The Solidly ask asks the total-fee selector first (M1, 2026-10-21).
//  Red at 85720ef: the pair below has no getAmountOut(uint256,address), so the
//  ask returned 0 and the leg was priced on the replicated curve at the leg's
//  configured fee less 200 bps.
//
//  `Core.solidlyGetAmountOut` asks 0x0ea099c1 getAmountOutWithTotalFee(uint256,
//  address) and, only when that ask fails (revert or less than a word), falls
//  back to 0xf140a35a getAmountOut(uint256,address). Aerodrome's new pools
//  charge base fee + MEV tax per caller in swap(); getAmountOutWithTotalFee is
//  the selector that answers for that same caller, getAmountOut the base fee
//  for address(0). The fallback arm is pinned by SolidlyQuoteFallbackTrigger
//  (a pair with only the old selector). This file pins the new arm:
//    - a pair that exposes ONLY the new selector: the ask, the executor's
//      producer, the in-frame quote and the delivery all come from its answer;
//    - a pair that exposes BOTH, answering different figures: the total-fee
//      answer is the one asked (the order of the two asks).
//  The pair's total fee (45 bps) differs from the leg's configured 30 bps, so
//  no fallback to the replicated curve can produce the pair's figure by luck.
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

interface IERC20TotalFeeAsk {
    function transfer(address to, uint256 amt) external returns (bool);
    function balanceOf(address who) external view returns (uint256);
}

/// @dev A Solidly-shaped pair with ONLY the total-fee quote selector: there is
///      no getAmountOut(uint256,address) in its bytecode.
contract TotalFeeOnlySolidlyPair {
    address public token0;
    address public token1;
    uint112 public reserve0;
    uint112 public reserve1;
    bool    public stable;
    uint256 public totalFeeBps;

    constructor(address a, address b, bool st, uint256 feeBps) {
        (token0, token1) = a < b ? (a, b) : (b, a);
        stable = st;
        totalFeeBps = feeBps;
    }

    function setReserves(uint112 r0, uint112 r1) external { reserve0 = r0; reserve1 = r1; }

    function getReserves() external view returns (uint112, uint112, uint32) {
        return (reserve0, reserve1, uint32(block.timestamp));
    }

    function getAmountOutWithTotalFee(uint256 amountIn, address tokenIn) public view returns (uint256) {
        (uint256 rIn, uint256 rOut) = tokenIn == token0
            ? (uint256(reserve0), uint256(reserve1))
            : (uint256(reserve1), uint256(reserve0));
        return BPC.outSolidly(amountIn, rIn, rOut, totalFeeBps, stable);
    }

    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata) external {
        if (amount0Out > 0) IERC20TotalFeeAsk(token0).transfer(to, amount0Out);
        if (amount1Out > 0) IERC20TotalFeeAsk(token1).transfer(to, amount1Out);
        reserve0 = uint112(IERC20TotalFeeAsk(token0).balanceOf(address(this)));
        reserve1 = uint112(IERC20TotalFeeAsk(token1).balanceOf(address(this)));
    }
}

/// @dev Both selectors, answering different figures: the total-fee ask at
///      `totalFeeBps`, the plain ask at `plainFeeBps`.
contract BothAsksSolidlyPair is TotalFeeOnlySolidlyPair {
    uint256 public plainFeeBps;

    constructor(address a, address b, uint256 totalBps, uint256 plainBps)
        TotalFeeOnlySolidlyPair(a, b, false, totalBps)
    {
        plainFeeBps = plainBps;
    }

    function getAmountOut(uint256 amountIn, address tokenIn) external view returns (uint256) {
        (uint256 rIn, uint256 rOut) = tokenIn == token0
            ? (uint256(reserve0), uint256(reserve1))
            : (uint256(reserve1), uint256(reserve0));
        return BPC.outSolidly(amountIn, rIn, rOut, plainFeeBps, stable);
    }
}

contract SolidlyAskAsksTheTotalFeeFirstTest is Test {
    bytes32 constant TOPIC = keccak256(
        "ExecutionProof(address,address,uint256,uint256,uint256,uint256)"
    );

    uint112 constant RESERVE   = 1_000_000e18;
    uint256 constant AMT       = 1_000e18;
    uint256 constant LEG_FEE   = 30; // the leg's configured fee (bps)
    uint256 constant TOTAL_FEE = 45; // the pair's own total fee (bps)
    address constant USER      = address(0xA11CE);

    BlazePhoenixHub internal hub;
    BlazePhoenixRouter internal router;
    MockERC20 internal tIn;
    MockERC20 internal tOut;
    TotalFeeOnlySolidlyPair internal pair;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        BlazePhoenixSolver solver = new BlazePhoenixSolver(address(hub), address(0));
        router = new BlazePhoenixRouter(
            address(hub), address(solver), address(this), address(0xFEE1), address(0xFEE2)
        );
        hub.setRoles(address(router), address(solver), address(this));

        tIn  = new MockERC20("IN", "IN");
        tOut = new MockERC20("OUT", "OUT"); // not a bridge: no output-side fee
        pair = new TotalFeeOnlySolidlyPair(address(tIn), address(tOut), false, TOTAL_FEE);
        tIn.mint(address(pair), RESERVE);
        tOut.mint(address(pair), RESERVE);
        pair.setReserves(RESERVE, RESERVE);
        hub.seedPool(address(pair), BPC.KIND_SOLIDLY, uint24(LEG_FEE), address(0), address(tIn), address(tOut));

        tIn.mint(USER, 100 * AMT);
        vm.prank(USER);
        tIn.approve(address(router), type(uint256).max);
    }

    function _route() private view returns (Route memory r) {
        Leg[] memory legs = new Leg[](1);
        legs[0] = Leg({
            pool: address(pair), hooks: address(0), kind: BPC.KIND_SOLIDLY, fee: uint24(LEG_FEE),
            tickSpacing: 0, zeroForOne: address(tIn) < address(tOut), stable: false,
            amountIn: AMT, expectedOut: 0, auxId: bytes32(0)
        });
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({
            tokenIn: address(tIn), tokenOut: address(tOut),
            amountIn: AMT, expectedOut: 0, legs: legs
        });
        r = Route({
            hops: hops, totalOut: 0, singleOut: 0, singleOutFloor: 0,
            expectedImpactBps: 0, confidenceWad: 0, estGas: 0,
            hasSurplus: false, isV4Bundle: false
        });
    }

    function _run() private returns (uint256 quoted, uint256 realized) {
        Route memory r = _route();
        uint256 before = tOut.balanceOf(USER);
        vm.recordLogs();
        vm.prank(USER);
        router.swapExactIn(r, AMT, 1, USER, block.timestamp + 1);
        realized = tOut.balanceOf(USER) - before;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool seen;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == TOPIC) {
                (quoted, , , ) = abi.decode(logs[i].data, (uint256, uint256, uint256, uint256));
                seen = true;
            }
        }
        assertTrue(seen, "setup: the Router emits ExecutionProof");
    }

    /// @notice Only the new selector: the ask and the executor's producer are
    ///         the pair's own total-fee answer.
    function test_APairWithOnlyTheTotalFeeSelectorIsAskedItsOwnAnswer() public view {
        (bool hasOld, ) = address(pair).staticcall(abi.encodeWithSelector(0xf140a35a, AMT, address(tIn)));
        assertFalse(hasOld, "setup: the pair has no getAmountOut(uint256,address)");
        uint256 ans = pair.getAmountOutWithTotalFee(AMT, address(tIn));
        assertGt(ans, 1, "setup: the pair answers a real figure");
        assertTrue(ans != BPC.outSolidly(AMT, RESERVE, RESERVE, LEG_FEE, false),
            "setup: the answer is not the leg-fee curve");
        assertEq(BPC.solidlyGetAmountOut(address(pair), AMT, address(tIn)), ans,
            "the ask is the pair's own total-fee answer");
        assertEq(
            BPC.solidlyAskOut(address(pair), AMT, address(tIn), address(tIn) < address(tOut), false, LEG_FEE),
            ans - 1,
            "the executor's producer is that answer less the one-wei ask margin"
        );
    }

    /// @notice Only the new selector, end to end: the in-frame quote is the
    ///         pair's answer and the delivery is that answer less one wei.
    function test_APairWithOnlyTheTotalFeeSelectorQuotesAndDeliversItsOwnAnswer() public {
        uint256 net = AMT - (AMT * BPC.PROTOCOL_FEE_BPS) / 10_000;
        uint256 ans = pair.getAmountOutWithTotalFee(net, address(tIn));
        (uint256 q, uint256 r) = _run();
        assertEq(q, ans, "the in-frame quote is the pair's total-fee answer");
        assertEq(r, ans - 1, "the delivery is that answer less the one-wei ask margin");
    }

    /// @notice Both selectors answering different figures: the total-fee
    ///         answer is the one asked.
    function test_APairWithBothSelectorsIsAskedTheTotalFeeOne() public {
        BothAsksSolidlyPair both = new BothAsksSolidlyPair(address(tIn), address(tOut), TOTAL_FEE, LEG_FEE);
        both.setReserves(RESERVE, RESERVE);
        uint256 total = both.getAmountOutWithTotalFee(AMT, address(tIn));
        uint256 plain = both.getAmountOut(AMT, address(tIn));
        assertTrue(total != plain, "setup: the two asks answer differently");
        assertEq(BPC.solidlyGetAmountOut(address(both), AMT, address(tIn)), total,
            "with both selectors, the total-fee answer is the one asked");
    }
}
