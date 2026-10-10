// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  ROUTER BALANCE AFTER SETTLEMENT - the holds-nothing guarantee and its one
//  stated bound (Router header R1; register row "Router balance after
//  settlement").
//
//  For a token that moves the amount it is asked to move, the Router's balance
//  after a settlement is EXACTLY zero. For a token that keeps balances as shares
//  and rounds each transfer down to whole shares, the Router keeps fewer than
//  k + d/n shares after k outbound transfers of that token (d/n = shares per
//  unit of balance). Derivation: the Router holds S shares, its balance is
//  B = floor(S*n/d) > S*n/d - 1, so B*d/n > S - d/n. Paying out amounts x_i with
//  sum B moves sum floor(x_i*d/n) > B*d/n - k > S - d/n - k shares, which leaves
//  fewer than k + d/n. With a share worth at least one unit (n >= d), that is at
//  most k shares: one per outbound transfer.
//
//  The matrix is token accounting x commitment. Accounting: plain, or shares at
//  three units per share. Commitment: the route commits the whole pull, or half
//  of it, which sends the uncommitted remainder back through the input sweep.
//  The plain cells assert exact zero in both tokens; the share cells assert the
//  per-transfer bound with k counted for that cell. The input token's outbound
//  transfers are the leg push, the two treasury payments, and the sweep when
//  there is a remainder; the output token's is the delivery.
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";
import {PathologicalERC20} from "./mocks/PathologicalERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";

contract RouterBalanceAfterSettlementTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    BlazePhoenixRouter router;
    PathologicalERC20 P1; // tokenIn
    PathologicalERC20 P2; // tokenOut
    MockV2Pair pair;
    bool zfo;

    address user  = address(0xBEEF);
    address recip = address(0xCAFE);
    address constant T1 = address(0xFEE1);
    address constant T2 = address(0xFEE2);

    uint256 constant RESERVE = 1_000_000e18;
    // Not a multiple of three, so a share-accounted transfer has a remainder to round.
    uint256 constant IN = 100e18 + 7;

    function _deploy(uint256 unitsPerShare) internal {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        solver = new BlazePhoenixSolver(address(hub));
        router = new BlazePhoenixRouter(address(hub), address(solver), address(this), T1, T2);
        hub.setRoles(address(router), address(solver), address(this));

        P1 = new PathologicalERC20("P1", "P1", 18);
        P2 = new PathologicalERC20("P2", "P2", 18);
        // Set before any mint: balances are born at this factor, so the fixture holds
        // exactly what it minted and only transfers round.
        P1.setRebase(unitsPerShare, 1);
        P2.setRebase(unitsPerShare, 1);

        pair = new MockV2Pair(address(P1), address(P2));
        P1.mint(address(pair), RESERVE);
        P2.mint(address(pair), RESERVE);
        pair.setReserves(uint112(P1.balanceOf(address(pair))), uint112(P2.balanceOf(address(pair))));
        if (pair.token0() != address(P1)) {
            pair.setReserves(uint112(P2.balanceOf(address(pair))), uint112(P1.balanceOf(address(pair))));
        }
        zfo = pair.token0() == address(P1);
        hub.seedPool(address(pair), BPC.KIND_V2, 0, address(0), address(P1), address(P2));

        P1.mint(user, 2 * IN);
        vm.prank(user);
        P1.approve(address(router), type(uint256).max);
    }

    function _route(uint256 committed) internal view returns (Route memory r) {
        Leg[] memory legs = new Leg[](1);
        legs[0] = Leg({
            pool: address(pair), hooks: address(0), kind: BPC.KIND_V2, fee: 0,
            tickSpacing: 0, zeroForOne: zfo, stable: false,
            amountIn: committed, expectedOut: 0, auxId: bytes32(0)
        });
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({tokenIn: address(P1), tokenOut: address(P2), amountIn: committed, expectedOut: 0, legs: legs});
        r = Route({
            hops: hops, totalOut: 0, singleOut: 0, singleOutFloor: 0,
            expectedImpactBps: 0, confidenceWad: 0, estGas: 0,
            hasSurplus: false, isV4Bundle: false
        });
    }

    /// @return paid what the user's balance lost; below IN only if a remainder came back.
    function _settle(uint256 committed) internal returns (uint256 paid) {
        Route memory r = _route(committed);
        uint256 userBefore = P1.balanceOf(user);
        vm.prank(user);
        uint256 got = router.swapExactIn(r, IN, 1, recip, block.timestamp + 1);
        assertGt(got, 0, "premise: the swap delivered");
        paid = userBefore - P1.balanceOf(user);
    }

    // ---- plain accounting: exactly zero -----------------------------------------------------

    function test_RouterBalanceAfterSettlement_PlainToken_FullCommitment_IsZero() public {
        _deploy(1);
        _settle(IN);
        assertEq(P1.balanceOf(address(router)), 0, "input token: nothing held");
        assertEq(P2.balanceOf(address(router)), 0, "output token: nothing held");
    }

    function test_RouterBalanceAfterSettlement_PlainToken_PartialCommitment_IsZero() public {
        _deploy(1);
        uint256 paid = _settle(IN / 2);
        assertEq(P1.balanceOf(address(router)), 0, "input token: the remainder was swept, nothing held");
        assertEq(P2.balanceOf(address(router)), 0, "output token: nothing held");
        assertLt(paid, IN, "premise: the sweep path ran (a remainder came back to the user)");
    }

    // ---- share accounting: at most one share per outbound transfer ---------------------------

    function test_RouterBalanceAfterSettlement_ShareToken_FullCommitment_AtMostOneSharePerTransfer() public {
        _deploy(3);
        _settle(IN);
        // input: leg push + two treasury payments = 3; output: the delivery = 1.
        assertLe(P1.sharesOf(address(router)), 3, "input token: at most one share per outbound transfer");
        assertLe(P2.sharesOf(address(router)), 1, "output token: at most one share for the delivery");
    }

    function test_RouterBalanceAfterSettlement_ShareToken_PartialCommitment_AtMostOneSharePerTransfer() public {
        _deploy(3);
        uint256 paid = _settle(IN / 2);
        // input: leg push + two treasury payments + the sweep = 4; output: the delivery = 1.
        assertLe(P1.sharesOf(address(router)), 4, "input token: at most one share per outbound transfer");
        assertLe(P2.sharesOf(address(router)), 1, "output token: at most one share for the delivery");
        assertLt(paid, IN, "premise: the sweep path ran (a remainder came back to the user)");
    }
}
