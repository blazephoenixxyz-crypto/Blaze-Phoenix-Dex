// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Ported from Blaze-Phoenix-Dex (V1) test/RouterSplitInvariant.t.sol — completes this repo's
// route-shape invariant coverage (single-leg -> multi-hop [RouterMultiHopInvariantFromV1] ->
// intra-hop split, here). One hop, TWO legs across two distinct A/B pools, splitting amountIn.
// Targets the per-leg allocation accounting: if the leg amounts don't reconcile with the pulled
// input, the surplus/remainder is stranded in the Router. This repo's existing invariant handler
// never builds a split route (always exactly one leg per hop), so this shape had zero coverage.
//
// INV1  pass-through   Router holds 0 of A and B at rest, across all splits
// INV2  conservation   per token, sum of all holders' balances == total minted
//
// forge test --match-contract RouterSplitInvariantFromV1 -vv

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";

contract SplitHandler {
    BlazePhoenixRouter immutable router;
    MockERC20 immutable A;
    MockERC20 immutable B;
    MockV2Pair immutable p1;
    MockV2Pair immutable p2;
    address immutable recipient;

    uint256 public swaps;
    uint256 public mintedA;
    uint256 public mintedB;

    uint256 constant LIQ = 1e30;

    constructor(
        BlazePhoenixRouter _router, MockERC20 _a, MockERC20 _b,
        MockV2Pair _p1, MockV2Pair _p2, address _recipient
    ) {
        router = _router; A = _a; B = _b; p1 = _p1; p2 = _p2; recipient = _recipient;
    }

    function _bound(uint256 x, uint256 lo, uint256 hi) internal pure returns (uint256) {
        return lo + (x % (hi - lo + 1));
    }

    function _leg(address pool, bool zfo, uint256 amt) internal pure returns (Leg memory) {
        return Leg({
            pool: pool, hooks: address(0), kind: BPC.KIND_V2, fee: 30, tickSpacing: 0,
            zeroForOne: zfo, stable: false, amountIn: amt, expectedOut: amt, auxId: bytes32(0)
        });
    }

    /// @param amtSeed total input; @param splitSeed how it divides across the 2 legs.
    function split(uint256 amtSeed, uint256 splitSeed) external {
        uint256 amt = _bound(amtSeed, 1e15, 1e21);
        uint256 part1 = 1 + (splitSeed % (amt - 1)); // 1..amt-1
        uint256 part2 = amt - part1;                 // legs sum EXACTLY to amt

        A.mint(address(this), amt);
        A.approve(address(router), amt);
        B.mint(address(p1), LIQ);
        B.mint(address(p2), LIQ);
        mintedA += amt; mintedB += 2 * LIQ;

        bool zfo1 = address(A) == p1.token0();
        bool zfo2 = address(A) == p2.token0();
        Leg[] memory legs = new Leg[](2);
        legs[0] = _leg(address(p1), zfo1, part1);
        legs[1] = _leg(address(p2), zfo2, part2);
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({tokenIn: address(A), tokenOut: address(B), amountIn: amt, expectedOut: amt, legs: legs});
        Route memory r = Route({
            hops: hops, totalOut: amt, singleOut: amt, singleOutFloor: 0,
            expectedImpactBps: 0, confidenceWad: 0, estGas: 0, hasSurplus: false, isV4Bundle: false
        });

        try router.swapExactIn(r, amt, 0, recipient, block.timestamp + 1) returns (uint256) {
            unchecked { ++swaps; }
        } catch {}
    }
}

contract RouterSplitInvariantFromV1Test is StdInvariant, Test {
    BlazePhoenixRouter router;
    MockERC20 A;
    MockERC20 B;
    MockV2Pair p1;
    MockV2Pair p2;
    SplitHandler handler;

    address recipient = makeAddr("recipient");
    address treasury1 = makeAddr("treasury1");
    address treasury2 = makeAddr("treasury2");

    function setUp() public {
        BlazePhoenixHub hub = new BlazePhoenixHub();
        hub.initialize(address(this), makeAddr("v4mgr"));
        BlazePhoenixSolver solver = new BlazePhoenixSolver(address(hub));
        router = new BlazePhoenixRouter(address(hub), address(solver), address(this), treasury1, treasury2);

        A = new MockERC20("A", "A");
        B = new MockERC20("B", "B");
        p1 = new MockV2Pair(address(A), address(B));
        p2 = new MockV2Pair(address(A), address(B));
        p1.setReserves(1e30, 1e30); // quote-only bookkeeping; the handler funds real payouts per-call
        p2.setReserves(1e30, 1e30);

        handler = new SplitHandler(router, A, B, p1, p2, recipient);
        targetContract(address(handler));
    }

    /// INV1 — splitting across legs leaves no remainder stranded in the Router.
    function invariant_routerHoldsNothing() public view {
        assertEq(A.balanceOf(address(router)), 0, "A stuck in Router");
        assertEq(B.balanceOf(address(router)), 0, "B stuck in Router");
    }

    function _sum(MockERC20 t) internal view returns (uint256) {
        return t.balanceOf(address(handler)) + t.balanceOf(address(p1))
            + t.balanceOf(address(p2)) + t.balanceOf(address(router))
            + t.balanceOf(recipient) + t.balanceOf(treasury1) + t.balanceOf(treasury2);
    }

    function invariant_conservationA() public view { assertEq(_sum(A), handler.mintedA(), "A not conserved"); }
    function invariant_conservationB() public view { assertEq(_sum(B), handler.mintedB(), "B not conserved"); }

    /// @dev Guards against a vacuous pass (see RouterMultiHopInvariantFromV1.t.sol for why this
    ///      must be afterInvariant, not a plain invariant_ function).
    function afterInvariant() public view {
        assertGt(handler.swaps(), 0, "no split swap ever succeeded across the whole campaign - vacuous pass");
    }
}
