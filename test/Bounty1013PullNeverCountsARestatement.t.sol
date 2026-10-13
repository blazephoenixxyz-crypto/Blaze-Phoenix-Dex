// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  PoC — F-4
//  Title    : the input sweep returns part of a pre-existing ("foreign") balance
//             when the token changes the holder balance inside the pull
//  Contract : src/BlazePhoenixRouter.sol  (_swap / _execute baseline + sweep)
//  Severity : Low (value leakage; Medium where a material stranded balance exists)
//
//  Run it:
//      FOUNDRY_PROFILE=poc forge test --match-contract F4_ReflectionInputBaseline -vv
//
//  The Router measures the pull as a balance delta and then protects the
//  pre-existing balance with `baseIn = tinStart - received`. Both terms are read
//  in the token's CURRENT display unit, so if the token changes the display
//  factor inside `transferFrom` (a rebase, or a reflection that credits the
//  Router's existing holding), `baseIn` no longer represents the pre-existing
//  value. The residual sweep then pays the difference to the current payer.
//
//  Deterministic and offline: a share-accounted token whose display factor
//  doubles when a transfer lands on the Router, plus a 500-token balance left on
//  the Router before the swap. Control leaves the Router whole; the armed case
//  leaves the Router the same DISPLAY balance and half the SHARES, and refunds
//  the payer far more than their own input.
//
//  test/mocks/PathologicalERC20 already ships setRebaseOnTransferTo, used to date
//  only with the trigger riding the FEE payout and with no pre-existing balance
//  (test/PathologicalTokens.t.sol 1a, 1b, 2). This is the same token class aimed
//  at the pull, with a foreign baseline present.
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";
import {PathologicalERC20} from "../test/mocks/PathologicalERC20.sol";
import {MockERC20} from "../test/mocks/MockERC20.sol";
import {MockV2Pair} from "../test/mocks/MockV2Pair.sol";

contract Bounty1013PullNeverCountsARestatementTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    BlazePhoenixRouter router;

    PathologicalERC20 inTok;
    MockERC20 outTok;
    MockV2Pair pair;

    address victim    = address(0xBEEF);
    address attacker  = address(0xA77);
    address recipient = address(0xCAFE);

    // A balance already on the Router before the swap (mis-sent, stranded, or
    // airdropped): this is the value the sweep must never hand to a payer.
    uint256 constant FOREIGN = 500e18;
    uint256 constant AMOUNT  = 100e18;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        solver = new BlazePhoenixSolver(address(hub));
        router = new BlazePhoenixRouter(
            address(hub), address(solver), address(this), address(0xFEE1), address(0xFEE2)
        );
        hub.setRoles(address(router), address(solver), address(this));

        inTok  = new PathologicalERC20("IN", "IN", 18);
        outTok = new MockERC20("OUT", "OUT");
        pair = new MockV2Pair(address(inTok), address(outTok));

        inTok.mint(address(pair), 1_000_000e18);
        outTok.mint(address(pair), 1_000_000e18);
        if (pair.token0() == address(inTok)) {
            pair.setReserves(uint112(inTok.balanceOf(address(pair))), uint112(1_000_000e18));
        } else {
            pair.setReserves(uint112(1_000_000e18), uint112(inTok.balanceOf(address(pair))));
        }

        // the stranded balance, left by someone else before this swap
        inTok.mint(victim, FOREIGN);
        vm.prank(victim);
        inTok.transfer(address(router), FOREIGN);

        inTok.mint(attacker, AMOUNT);
        vm.prank(attacker);
        inTok.approve(address(router), type(uint256).max);
    }

    function _route() internal view returns (Route memory r) {
        Leg[] memory legs = new Leg[](1);
        legs[0] = Leg({
            pool: address(pair), hooks: address(0), kind: BPC.KIND_V2, fee: 30,
            tickSpacing: 0, zeroForOne: pair.token0() == address(inTok),
            stable: false, amountIn: AMOUNT, expectedOut: 0, auxId: bytes32(0)
        });
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({
            tokenIn: address(inTok), tokenOut: address(outTok),
            amountIn: AMOUNT, expectedOut: 0, legs: legs
        });
        r = Route({
            hops: hops, totalOut: 0, singleOut: 0, singleOutFloor: 0,
            expectedImpactBps: 0, confidenceWad: 0, estGas: 0,
            hasSurplus: false, isV4Bundle: false
        });
    }

    function test_control_no_rebase_leaves_foreign_balance_whole() public {
        inTok.setRebaseOnTransferTo(address(0xDEAD), 2, 1); // armed, never fires
        uint256 attackerBefore = inTok.balanceOf(attacker);
        Route memory r = _route();

        vm.prank(attacker);
        router.swapExactIn(r, AMOUNT, 1, recipient, block.timestamp + 1);

        assertEq(inTok.balanceOf(address(router)), FOREIGN, "foreign display balance intact");
        assertEq(inTok.sharesOf(address(router)), FOREIGN, "foreign shares intact");
        assertEq(inTok.balanceOf(attacker), 0, "no input refunded to the payer");
        assertEq(attackerBefore, AMOUNT);
    }

    /// #45: a balance restatement inside the pull is not the payer's: the refund never
    /// exceeds what was pulled, and the Router's pre-existing balance is not swept.
    function test_RebaseInsideThePullIsNotRefunded() public {
        inTok.setRebaseOnTransferTo(address(router), 2, 1);
        uint256 displayBefore = inTok.balanceOf(address(router));
        Route memory r = _route();

        vm.prank(attacker);
        router.swapExactIn(r, AMOUNT, 1, recipient, block.timestamp + 1);

        assertLe(inTok.balanceOf(attacker), AMOUNT, "payer refunded more than they pulled");
        assertGe(inTok.balanceOf(address(router)), displayBefore, "foreign balance swept");
    }
}
