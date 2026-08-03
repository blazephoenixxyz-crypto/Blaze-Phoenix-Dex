// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// =============================================================================
//  ROUTER INTRA-HOP SPLIT STATEFUL INVARIANTS — offline, mock executable venues.
//
//  Completes the route-shape coverage (single-leg → multi-hop → split). One hop,
//  TWO legs across two distinct A/B pools, splitting amountIn. This targets the
//  per-leg allocation accounting: if the leg amounts don't reconcile with the
//  pulled input, the surplus is stranded in the Router.
//
//    INV1  pass-through    Router holds 0 of A and B at rest, across all splits
//    INV2  conservation    per token, sum of all holders' balances == total minted
//
//    forge test --match-contract RouterSplitInvariant -vv
// =============================================================================

import { Test } from "forge-std/Test.sol";
import { BlazePhoenixHub }    from "../src/BlazePhoenixHub.sol";
import { BlazePhoenixSolver } from "../src/BlazePhoenixSolver.sol";
import { BlazePhoenixRouter } from "../src/BlazePhoenixRouter.sol";
import { Route, Hop, Leg } from "../src/BlazePhoenixCore.sol";
import { MockERC20Exec, MockV2ExecPool } from "./RouterExecGuards.t.sol";

contract SplitHandler {
    BlazePhoenixRouter immutable router;
    MockERC20Exec immutable A;
    MockERC20Exec immutable B;
    MockV2ExecPool immutable p1;   // token0=A, token1=B
    MockV2ExecPool immutable p2;   // token0=A, token1=B
    address immutable recipient;

    uint256 public swaps;
    uint256 public mintedA;
    uint256 public mintedB;

    uint256 constant LIQ = 1e30;

    constructor(
        BlazePhoenixRouter _router, MockERC20Exec _a, MockERC20Exec _b,
        MockV2ExecPool _p1, MockV2ExecPool _p2, address _recipient
    ) {
        router = _router; A = _a; B = _b; p1 = _p1; p2 = _p2; recipient = _recipient;
    }

    function _bound(uint256 x, uint256 lo, uint256 hi) internal pure returns (uint256) {
        return lo + (x % (hi - lo + 1));
    }

    function _leg(address pool, uint256 amt) internal pure returns (Leg memory) {
        return Leg({
            pool: pool, hooks: address(0), kind: 0 /*V2*/, fee: 0, tickSpacing: 0,
            zeroForOne: true, stable: false, amountIn: amt, expectedOut: 0, auxId: bytes32(0)
        });
    }

    /// @param amtSeed total input; @param splitSeed how it divides across the 2 legs.
    function split(uint256 amtSeed, uint256 splitSeed) external {
        uint256 amt   = _bound(amtSeed, 1e15, 1e21);
        uint256 part1 = 1 + (splitSeed % (amt - 1));   // 1..amt-1
        uint256 part2 = amt - part1;                   // legs sum EXACTLY to amt

        A.mint(address(this), amt);
        B.mint(address(p1), LIQ);
        B.mint(address(p2), LIQ);
        mintedA += amt; mintedB += 2 * LIQ;

        Leg[] memory legs = new Leg[](2);
        legs[0] = _leg(address(p1), part1);
        legs[1] = _leg(address(p2), part2);
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({
            tokenIn: address(A), tokenOut: address(B), amountIn: amt, expectedOut: 0, legs: legs
        });
        Route memory r; r.hops = hops;

        try router.swapExactIn(r, amt, 0, recipient, block.timestamp + 1) returns (uint256) {
            unchecked { ++swaps; }
        } catch {}
    }
}

contract RouterSplitInvariant is Test {
    BlazePhoenixRouter router;
    MockERC20Exec A;
    MockERC20Exec B;
    MockV2ExecPool p1;
    MockV2ExecPool p2;
    SplitHandler handler;

    address recipient = makeAddr("recipient");
    address treasury1 = makeAddr("treasury1");
    address treasury2 = makeAddr("treasury2");

    function setUp() public {
        BlazePhoenixHub hub = new BlazePhoenixHub();
        hub.initialize(address(this), makeAddr("v4mgr"));
        BlazePhoenixSolver solver = new BlazePhoenixSolver(address(hub));
        router = new BlazePhoenixRouter(
            address(hub), address(solver), address(this), treasury1, treasury2);

        A = new MockERC20Exec();
        B = new MockERC20Exec();
        p1 = new MockV2ExecPool(address(A), address(B), uint112(1e30), uint112(1e30));
        p2 = new MockV2ExecPool(address(A), address(B), uint112(1e30), uint112(1e30));

        handler = new SplitHandler(router, A, B, p1, p2, recipient);
        targetContract(address(handler));
    }

    /// INV1 — splitting across legs leaves no remainder stranded in the Router.
    function invariant_routerHoldsNothing() public view {
        assertEq(A.balanceOf(address(router)), 0, "INV1: A stuck in Router");
        assertEq(B.balanceOf(address(router)), 0, "INV1: B stuck in Router");
    }

    function _sum(MockERC20Exec t) internal view returns (uint256) {
        return t.balanceOf(address(handler)) + t.balanceOf(address(p1))
            + t.balanceOf(address(p2)) + t.balanceOf(address(router))
            + t.balanceOf(recipient) + t.balanceOf(treasury1) + t.balanceOf(treasury2);
    }

    function invariant_conservationA() public view {
        assertEq(_sum(A), handler.mintedA(), "INV2: A not conserved");
    }
    function invariant_conservationB() public view {
        assertEq(_sum(B), handler.mintedB(), "INV2: B not conserved");
    }
}
