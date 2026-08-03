// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// =============================================================================
//  ROUTER MULTI-HOP STATEFUL INVARIANTS — offline, mock executable venues.
//
//  Extends the single-leg stateful suite to a 2-hop bridge path A <-> C <-> B
//  across two pools (pAC, pCB), in both directions. Multi-hop is where the
//  bridge/intermediate-token accounting lives, so this targets the bug class a
//  single leg can never reach: the intermediate token (C) being left stranded
//  in the Router between hops.
//
//    INV1  pass-through    Router holds 0 of A, B AND the intermediate C at rest
//    INV2  conservation    per token, sum of all holders' balances == total minted
//
//    forge test --match-contract RouterMultiHopInvariant -vv
//    FOUNDRY_INVARIANT_RUNS=2000 FOUNDRY_INVARIANT_DEPTH=256 forge test \
//      --match-contract RouterMultiHopInvariant -vv
// =============================================================================

import { Test } from "forge-std/Test.sol";
import { BlazePhoenixHub }    from "../src/BlazePhoenixHub.sol";
import { BlazePhoenixSolver } from "../src/BlazePhoenixSolver.sol";
import { BlazePhoenixRouter } from "../src/BlazePhoenixRouter.sol";
import { Route, Hop, Leg } from "../src/BlazePhoenixCore.sol";
import { MockERC20Exec, MockV2ExecPool } from "./RouterExecGuards.t.sol";

contract MultiHopHandler {
    BlazePhoenixRouter immutable router;
    MockERC20Exec immutable A;
    MockERC20Exec immutable B;
    MockERC20Exec immutable C;
    MockV2ExecPool immutable pAC;  // token0=A, token1=C
    MockV2ExecPool immutable pCB;  // token0=C, token1=B
    address immutable recipient;

    uint256 public swaps;
    uint256 public mintedA;
    uint256 public mintedB;
    uint256 public mintedC;

    uint256 constant LIQ = 1e30;   // deep pool top-up so two sequential hops settle

    constructor(
        BlazePhoenixRouter _router, MockERC20Exec _a, MockERC20Exec _b, MockERC20Exec _c,
        MockV2ExecPool _pAC, MockV2ExecPool _pCB, address _recipient
    ) {
        router = _router; A = _a; B = _b; C = _c; pAC = _pAC; pCB = _pCB; recipient = _recipient;
    }

    function _bound(uint256 x, uint256 lo, uint256 hi) internal pure returns (uint256) {
        return lo + (x % (hi - lo + 1));
    }

    function _leg(address pool, bool zfo, uint256 amt) internal pure returns (Leg memory) {
        return Leg({
            pool: pool, hooks: address(0), kind: 0 /*V2*/, fee: 0, tickSpacing: 0,
            zeroForOne: zfo, stable: false, amountIn: amt, expectedOut: 0, auxId: bytes32(0)
        });
    }

    function _hop(address tin, address tout, bool zfo, address pool, uint256 amt)
        internal pure returns (Hop memory h)
    {
        Leg[] memory legs = new Leg[](1); legs[0] = _leg(pool, zfo, amt);
        h = Hop({ tokenIn: tin, tokenOut: tout, amountIn: amt, expectedOut: 0, legs: legs });
    }

    /// @param dirSeed even = A->C->B, odd = B->C->A. @param amtSeed swap size.
    function twoHop(uint256 dirSeed, uint256 amtSeed) external {
        uint256 amt = _bound(amtSeed, 1e15, 1e21);
        Hop[] memory hops = new Hop[](2);

        if (dirSeed % 2 == 0) {
            // A -> C (pAC, zfo=true) -> B (pCB, zfo=true)
            A.mint(address(this), amt);
            C.mint(address(pAC), LIQ);   // pAC pays out C
            B.mint(address(pCB), LIQ);   // pCB pays out B
            mintedA += amt; mintedC += LIQ; mintedB += LIQ;
            hops[0] = _hop(address(A), address(C), true,  address(pAC), amt);
            hops[1] = _hop(address(C), address(B), true,  address(pCB), amt);
        } else {
            // B -> C (pCB, zfo=false) -> A (pAC, zfo=false)
            B.mint(address(this), amt);
            C.mint(address(pCB), LIQ);   // pCB pays out C
            A.mint(address(pAC), LIQ);   // pAC pays out A
            mintedB += amt; mintedC += LIQ; mintedA += LIQ;
            hops[0] = _hop(address(B), address(C), false, address(pCB), amt);
            hops[1] = _hop(address(C), address(A), false, address(pAC), amt);
        }

        Route memory r; r.hops = hops;
        try router.swapExactIn(r, amt, 0, recipient, block.timestamp + 1) returns (uint256) {
            unchecked { ++swaps; }
        } catch {}
    }
}

contract RouterMultiHopInvariant is Test {
    BlazePhoenixRouter router;
    MockERC20Exec A;
    MockERC20Exec B;
    MockERC20Exec C;
    MockV2ExecPool pAC;
    MockV2ExecPool pCB;
    MultiHopHandler handler;

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
        C = new MockERC20Exec();
        pAC = new MockV2ExecPool(address(A), address(C), uint112(1e30), uint112(1e30));
        pCB = new MockV2ExecPool(address(C), address(B), uint112(1e30), uint112(1e30));

        handler = new MultiHopHandler(router, A, B, C, pAC, pCB, recipient);
        targetContract(address(handler));
    }

    /// INV1 — including the intermediate C: no token is ever stranded in the Router.
    function invariant_routerHoldsNothing() public view {
        assertEq(A.balanceOf(address(router)), 0, "INV1: A stuck in Router");
        assertEq(B.balanceOf(address(router)), 0, "INV1: B stuck in Router");
        assertEq(C.balanceOf(address(router)), 0, "INV1: intermediate C stuck in Router");
    }

    function _sum(MockERC20Exec t) internal view returns (uint256) {
        return t.balanceOf(address(handler)) + t.balanceOf(address(pAC))
            + t.balanceOf(address(pCB)) + t.balanceOf(address(router))
            + t.balanceOf(recipient) + t.balanceOf(treasury1) + t.balanceOf(treasury2);
    }

    function invariant_conservationA() public view {
        assertEq(_sum(A), handler.mintedA(), "INV2: A not conserved");
    }
    function invariant_conservationB() public view {
        assertEq(_sum(B), handler.mintedB(), "INV2: B not conserved");
    }
    function invariant_conservationC() public view {
        assertEq(_sum(C), handler.mintedC(), "INV2: intermediate C not conserved");
    }
}
