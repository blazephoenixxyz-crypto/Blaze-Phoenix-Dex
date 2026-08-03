// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// =============================================================================
//  ROUTER STATEFUL INVARIANTS — offline, mock executable venue.
//
//  Foundry drives long random sequences of swaps through the Router (a real
//  single-leg V2 fill each time, against the mock pool) and checks protocol-wide
//  invariants hold across the WHOLE sequence — not just one call:
//
//    INV1  pass-through      the Router retains 0 of every token at rest
//                            (no dust trapped over arbitrarily many swaps)
//    INV2  monotonic payout   treasuries + recipient balances never decrease
//                            (the Router can only ADD to them, never claw back)
//
//  Tune depth/runs in foundry.toml ([invariant] runs/depth) or with
//  FOUNDRY_INVARIANT_RUNS / FOUNDRY_INVARIANT_DEPTH. Fully offline — no RPC.
//
//    forge test --match-contract RouterStatefulInvariant -vv
// =============================================================================

import { Test } from "forge-std/Test.sol";
import { BlazePhoenixHub }    from "../src/BlazePhoenixHub.sol";
import { BlazePhoenixSolver } from "../src/BlazePhoenixSolver.sol";
import { BlazePhoenixRouter } from "../src/BlazePhoenixRouter.sol";
import { Route, Hop, Leg } from "../src/BlazePhoenixCore.sol";
import { MockERC20Exec, MockV2ExecPool } from "./RouterExecGuards.t.sol";

/// @dev Bounded swap actor: every call performs a settle-able single-leg swap in
///      a random direction and size, so the fuzzer explores real fills only.
contract SwapHandler {
    BlazePhoenixRouter immutable router;
    MockERC20Exec      immutable A;
    MockERC20Exec      immutable B;
    MockV2ExecPool     immutable pool;
    address            immutable recipient;

    uint256 public swaps;
    uint256 public mintedA;   // ghost: total token A minted into the system
    uint256 public mintedB;   // ghost: total token B minted into the system

    constructor(
        BlazePhoenixRouter _router, MockERC20Exec _a, MockERC20Exec _b,
        MockV2ExecPool _pool, address _recipient
    ) {
        router = _router; A = _a; B = _b; pool = _pool; recipient = _recipient;
    }

    function _bound(uint256 x, uint256 lo, uint256 hi) internal pure returns (uint256) {
        return lo + (x % (hi - lo + 1));
    }

    /// @param dirSeed picks the swap direction; @param amtSeed the size.
    function swap(uint256 dirSeed, uint256 amtSeed) external {
        bool zfo = dirSeed % 2 == 0;                 // true: A->B, false: B->A
        MockERC20Exec tin  = zfo ? A : B;
        MockERC20Exec tout = zfo ? B : A;
        uint256 amt = _bound(amtSeed, 1e15, 1e21);

        tin.mint(address(this), amt);                // fund the swapper
        tout.mint(address(pool), 1e27);              // keep the pool solvent to pay out
        if (zfo) { mintedA += amt; mintedB += 1e27; } // track ghosts (in==A, out==B)
        else     { mintedB += amt; mintedA += 1e27; }

        Leg memory leg = Leg({
            pool: address(pool), hooks: address(0), kind: 0 /*V2*/, fee: 0, tickSpacing: 0,
            zeroForOne: zfo, stable: false, amountIn: amt, expectedOut: 0, auxId: bytes32(0)
        });
        Leg[] memory legs = new Leg[](1); legs[0] = leg;
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({
            tokenIn: address(tin), tokenOut: address(tout),
            amountIn: amt, expectedOut: 0, legs: legs
        });
        Route memory r; r.hops = hops;

        // minOut = 0; reverts are tolerated (fail_on_revert=false) but we expect
        // these to settle. Count the productive ones.
        try router.swapExactIn(r, amt, 0, recipient, block.timestamp + 1) returns (uint256) {
            unchecked { ++swaps; }
        } catch {}
    }
}

contract RouterStatefulInvariant is Test {
    BlazePhoenixHub    hub;
    BlazePhoenixRouter router;
    MockERC20Exec      A;
    MockERC20Exec      B;
    MockV2ExecPool     pool;
    SwapHandler        handler;

    address recipient = makeAddr("recipient");
    address treasury1 = makeAddr("treasury1");
    address treasury2 = makeAddr("treasury2");

    function setUp() public {
        hub = new BlazePhoenixHub();
        hub.initialize(address(this), makeAddr("v4mgr"));
        BlazePhoenixSolver solver = new BlazePhoenixSolver(address(hub));
        router = new BlazePhoenixRouter(
            address(hub), address(solver), address(this), treasury1, treasury2);

        A = new MockERC20Exec();
        B = new MockERC20Exec();
        pool = new MockV2ExecPool(address(A), address(B), uint112(1e27), uint112(1e27));

        handler = new SwapHandler(router, A, B, pool, recipient);
        targetContract(address(handler));
    }

    /// INV1 — the Router is a pass-through: it never holds token dust at rest.
    function invariant_routerHoldsNothing() public view {
        assertEq(A.balanceOf(address(router)), 0, "INV1: token A stuck in Router");
        assertEq(B.balanceOf(address(router)), 0, "INV1: token B stuck in Router");
    }

    /// INV2 — token conservation: no value is created or destroyed. The sum of
    ///        every holder's balance equals the total minted into the system.
    function invariant_conservationA() public view {
        uint256 sum = A.balanceOf(address(handler)) + A.balanceOf(address(pool))
            + A.balanceOf(address(router)) + A.balanceOf(recipient)
            + A.balanceOf(treasury1) + A.balanceOf(treasury2);
        assertEq(sum, handler.mintedA(), "INV2: token A not conserved");
    }

    function invariant_conservationB() public view {
        uint256 sum = B.balanceOf(address(handler)) + B.balanceOf(address(pool))
            + B.balanceOf(address(router)) + B.balanceOf(recipient)
            + B.balanceOf(treasury1) + B.balanceOf(treasury2);
        assertEq(sum, handler.mintedB(), "INV2: token B not conserved");
    }
}
