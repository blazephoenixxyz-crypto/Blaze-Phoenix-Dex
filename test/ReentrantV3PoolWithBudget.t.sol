// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  The single-shot clearing of `_v3Callback`, and the
//  two questions the existing suite cannot tell apart.
//
//  `_v3Callback` opens with the sender check and then clears the
//  transient context BEFORE paying:
//
//      // Single-shot (checks-effects-interactions): clear the transient auth
//      // context BEFORE paying, so a pool that re-enters this callback reads
//      // expected == 0 on the second entry and reverts(6) — no multi-pull.
//      assembly { tstore(sP, 0) tstore(sT, 0) tstore(sA, 0) }
//
//  WHY THE SUITE CANNOT SEE IT. `DoubleCallbackV3Pool` (test/regime/
//  HostileVenues.sol:178) already fires the callback twice, and its cells
//  (`HostileVenueMatrix.t.sol:222-223`) stay green with the clearing removed —
//  because `_cell` asserts only `Outcomes.classify(ret)` (`:204-205`), i.e.
//  "the revert carries a selector of ours". With no budget in the Router the
//  second entry dies at the transfer floor instead: `BPC.safeTransfer` reverts
//  `Error("BPC:transfer")`, and `Outcomes.classify` accepts ANY
//  `Error(string)` beginning `BPC:` as ours (`test/regime/Outcomes.sol:34-35`).
//  E(6) is swapped for BPC:transfer and nobody watching the code can tell.
//  That is the masking (eixo M) the 45/45 survival of the mutant is made of.
//
//  THE TWO QUESTIONS THIS FILE SEPARATES.
//    A. WHO refuses the second entry — the clearing, or another guard? The
//       only arm of the second entry that can produce E(6) is
//       `expected == 0`: `msg.sender` IS the expected pool (it made the first
//       call), `owed == maxAmt` on both entries. So E(6) is attributable to
//       the clearing alone.
//    B. DOES MONEY MOVE when the Router holds a budget? (h5 vs h6.) The pool
//       swallows the second call and records it, so the transaction settles
//       and the verdict is read from balances, not from a revert.
//
//  The budget (an extra AMT of tokenIn minted straight to the Router) is the
//  condition the candidate names: [inferido] synthesis of the residual regime
//  the surplus family describes (`hasSurplus`). Falsifier: rebuild the same
//  surplus through a real fee-on-transfer leg instead of a mint and the two
//  tests must behave identically.
//
//  forge test --match-contract ReentrantV3PoolWithBudget -vv
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {DoubleCallbackV3Pool} from "./regime/HostileVenues.sol";

interface IERC20Probe {
    function transfer(address to, uint256 amt) external returns (bool);
    function balanceOf(address who) external view returns (uint256);
    function mint(address to, uint256 amt) external;
}

/// @notice Honest V3-shaped pool that fires the payment callback TWICE, the
///         second time swallowing the outcome instead of letting it propagate,
///         and records what happened. Swallowing is what lets the transaction
///         settle under the CURRENT code, so the assertions below read
///         persistent state rather than a rolled-back frame.
contract BudgetProbeV3Pool {
    address public token0;
    address public token1;
    uint24  public fee;
    uint160 public sqrtPriceX96;
    uint128 public liquidity;

    bool    public secondAttempted;
    bool    public secondSucceeded;
    bytes   public secondReturndata;
    uint256 public firstPaid;
    uint256 public paidIn;

    constructor(address a, address b, uint24 f) {
        (token0, token1) = a < b ? (a, b) : (b, a);
        fee = f;
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
        require(amtOut > 0, "BudgetProbeV3Pool: zero out");

        address tokenIn  = zeroForOne ? token0 : token1;
        address tokenOut = zeroForOne ? token1 : token0;

        amount0 = zeroForOne ? int256(amtIn) : -int256(amtOut);
        amount1 = zeroForOne ? -int256(amtOut) : int256(amtIn);

        uint256 balBefore = IERC20Probe(tokenIn).balanceOf(address(this));
        // First entry: the ordinary one.
        (bool ok1, bytes memory ret1) = msg.sender.call(
            abi.encodeWithSignature(
                "uniswapV3SwapCallback(int256,int256,bytes)", amount0, amount1, data
            )
        );
        require(ok1, "BudgetProbeV3Pool: first callback failed");
        ret1;
        firstPaid = IERC20Probe(tokenIn).balanceOf(address(this)) - balBefore;

        // Second entry: the one the clearing exists for. Swallowed, recorded.
        secondAttempted = true;
        (bool ok2, bytes memory ret2) = msg.sender.call(
            abi.encodeWithSignature(
                "uniswapV3SwapCallback(int256,int256,bytes)", amount0, amount1, data
            )
        );
        secondSucceeded = ok2;
        secondReturndata = ret2;

        paidIn = IERC20Probe(tokenIn).balanceOf(address(this)) - balBefore;
        IERC20Probe(tokenOut).transfer(recipient, amtOut);
    }
}

contract ReentrantV3PoolWithBudgetTest is Test {
    BlazePhoenixHub    hub;
    BlazePhoenixRouter router;
    MockERC20 tokenIn;
    MockERC20 tokenOut;

    address user      = address(0xBEEF);
    address treasury1 = address(0xFEE1);
    address treasury2 = address(0xFEE2);

    uint256 constant AMT    = 1_000e18;
    uint256 constant DEPTH  = 1_000_000e18;
    uint24  constant PFEE   = 3000;

    function setUp() public {
        hub    = new BlazePhoenixHub(address(this));
        solver = new BlazePhoenixSolver(address(hub));
        router = new BlazePhoenixRouter(
            address(hub), address(solver), address(this), treasury1, treasury2
        );
        hub.setRoles(address(router), address(solver), address(this));

        tokenIn  = new MockERC20("In", "IN");
        tokenOut = new MockERC20("Out", "OUT");
    }

    BlazePhoenixSolver solver;

    function _budget() private {
        // The condition the candidate names: the Router holds at least 2x the
        // amount the pool will demand, so a second pull has something to take.
        IERC20Probe(address(tokenIn)).mint(address(router), AMT);
    }

    function _route(address pool, bool zfo, uint256 expectedOut) private view returns (Route memory) {
        Leg[] memory legs = new Leg[](1);
        legs[0] = Leg({
            pool: pool, hooks: address(0), kind: BPC.KIND_V3, fee: PFEE,
            tickSpacing: 60, zeroForOne: zfo, stable: false,
            amountIn: AMT, expectedOut: expectedOut, auxId: bytes32(0)
        });
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({
            tokenIn: address(tokenIn), tokenOut: address(tokenOut),
            amountIn: AMT, expectedOut: expectedOut, legs: legs
        });
        return Route({
            hops: hops, totalOut: expectedOut, singleOut: expectedOut,
            singleOutFloor: 0, expectedImpactBps: 0, confidenceWad: 0,
            estGas: 0, hasSurplus: false, isV4Bundle: false
        });
    }

    // -------------------------------------------------------------------------
    //  A. WHO refuses the second entry.
    // -------------------------------------------------------------------------
    function test_A_SecondEntryIsRefusedWithRouterE6_NotWithTheTransferFloor() public {
        bool zfo = address(tokenIn) < address(tokenOut);
        DoubleCallbackV3Pool pool = new DoubleCallbackV3Pool(address(tokenIn), address(tokenOut), PFEE);
        pool.setState(uint160(BPC.Q96), uint128(DEPTH));
        IERC20Probe(address(tokenOut)).mint(address(pool), DEPTH);

        _budget();

        uint256 expectedOut = BPC.outV3(AMT, uint160(BPC.Q96), uint128(DEPTH), PFEE, zfo, 0);
        assertGt(expectedOut, 0, "setup: the pool must quote something");

        tokenIn.mint(user, AMT);
        vm.prank(user);
        tokenIn.approve(address(router), AMT);

        Route memory route = _route(address(pool), zfo, expectedOut);

        // The clearing is the ONLY arm that can answer E(6) here: on the second
        // entry msg.sender still IS the expected pool and owed still equals
        // maxAmt. E(6) therefore names the clearing, not a neighbour.
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, uint16(6)));
        vm.prank(user);
        router.swapExactIn(route, AMT, 1, user, block.timestamp + 1);
    }

    // -------------------------------------------------------------------------
    //  B. Does money move when there is a budget? (h5 vs h6)
    // -------------------------------------------------------------------------
    function test_B_WithBudgetThePoolIsPaidExactlyOnce() public {
        bool zfo = address(tokenIn) < address(tokenOut);
        BudgetProbeV3Pool pool = new BudgetProbeV3Pool(address(tokenIn), address(tokenOut), PFEE);
        pool.setState(uint160(BPC.Q96), uint128(DEPTH));
        IERC20Probe(address(tokenOut)).mint(address(pool), DEPTH);

        _budget();

        uint256 expectedOut = BPC.outV3(AMT, uint160(BPC.Q96), uint128(DEPTH), PFEE, zfo, 0);
        assertGt(expectedOut, 0, "setup: the pool must quote something");

        tokenIn.mint(user, AMT);
        vm.prank(user);
        tokenIn.approve(address(router), AMT);

        Route memory route = _route(address(pool), zfo, expectedOut);

        vm.prank(user);
        uint256 delivered = router.swapExactIn(route, AMT, 1, user, block.timestamp + 1);
        assertGt(delivered, 0, "the outer, legitimate swap settles");

        // Non-vacuous: the second entry really happened.
        assertTrue(pool.secondAttempted(), "the pool really made a second callback");

        // WHO refused it: the clearing, by code and not by family.
        assertEq(
            pool.secondReturndata(),
            abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, uint16(6)),
            "the second entry was refused by the transient-context clearing (RouterE(6))"
        );
        assertFalse(pool.secondSucceeded(), "the second entry must not be paid");

        // AND THE MONEY. Two readings, ordered by how much they assume:
        //   1. differential — no assumption at all: the SECOND entry moved
        //      nothing. Under a Router without the clearing this is the
        //      assertion that dies with paidIn == 2 x firstPaid.
        //   2. absolute — from the library constant the house keeps readable
        //      precisely so the apparatus is bolted to the object it measures
        //      (src/BlazePhoenixCore.sol).
        assertGt(pool.firstPaid(), 0, "the first entry really paid - control, not a zero");
        assertEq(
            pool.paidIn(), pool.firstPaid(),
            "the second entry moved no tokens: paid exactly once, budget or no budget"
        );
        uint256 expectedAmt = AMT - BPC.mulDiv(AMT, BPC.PROTOCOL_FEE_BPS, BPC.BPS);
        assertEq(
            pool.firstPaid(), expectedAmt,
            "the first payment is the leg's input, net of the protocol fee"
        );
        assertEq(
            IERC20Probe(address(tokenIn)).balanceOf(address(pool)), pool.paidIn(),
            "the pool's balance says the same thing as its own measurement"
        );
    }

    // -------------------------------------------------------------------------
    //  CONTROL (property 6): the same construction with NO budget, so the
    //  refusal above is shown to be the clearing and not the balance floor.
    //  If this control ever fails, test_A's E(6) is the transfer floor talking.
    // -------------------------------------------------------------------------
    function test_C_Control_NoBudgetSecondEntryStillRefusedByRouterE6() public {
        bool zfo = address(tokenIn) < address(tokenOut);
        DoubleCallbackV3Pool pool = new DoubleCallbackV3Pool(address(tokenIn), address(tokenOut), PFEE);
        pool.setState(uint160(BPC.Q96), uint128(DEPTH));
        IERC20Probe(address(tokenOut)).mint(address(pool), DEPTH);

        // NO _budget(): the Router holds exactly one leg's input.

        uint256 expectedOut = BPC.outV3(AMT, uint160(BPC.Q96), uint128(DEPTH), PFEE, zfo, 0);
        tokenIn.mint(user, AMT);
        vm.prank(user);
        tokenIn.approve(address(router), AMT);

        Route memory route = _route(address(pool), zfo, expectedOut);

        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, uint16(6)));
        vm.prank(user);
        router.swapExactIn(route, AMT, 1, user, block.timestamp + 1);
    }
}
