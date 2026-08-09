// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// Ported from Blaze-Phoenix-Dex (V1) test/RouterMultiHopInvariant.t.sol — a genuine gap: this
// repo's own BlazePhoenixRouter.invariant.t.sol sets up a 4-token chain (T0-T1-T2-T3) but its
// handler always picks ONE pair and builds a single-hop route — it never actually constructs a
// 2-hop route, so the intermediate-token accounting a real bridge hop exercises (the token
// briefly held mid-route between the two legs) is never touched by any invariant suite here.
//
//   INV1  pass-through   Router holds 0 of A, B, AND the intermediate C at rest
//   INV2  conservation   per token, sum of all holders' balances == total minted
//
// forge test --match-contract RouterMultiHopInvariantFromV1 -vv

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";

contract MultiHopHandler {
    BlazePhoenixRouter immutable router;
    MockERC20 immutable A;
    MockERC20 immutable B;
    MockERC20 immutable C; // intermediate/bridge token
    MockV2Pair immutable pAC; // token0=A, token1=C (or sorted equivalent)
    MockV2Pair immutable pCB; // token0=C, token1=B (or sorted equivalent)
    address immutable recipient;

    uint256 public swaps;
    uint256 public mintedA;
    uint256 public mintedB;
    uint256 public mintedC;

    uint256 constant LIQ = 1e30; // deep pool top-up so two sequential hops settle

    constructor(
        BlazePhoenixRouter _router, MockERC20 _a, MockERC20 _b, MockERC20 _c,
        MockV2Pair _pAC, MockV2Pair _pCB, address _recipient
    ) {
        router = _router; A = _a; B = _b; C = _c; pAC = _pAC; pCB = _pCB; recipient = _recipient;
    }

    function _bound(uint256 x, uint256 lo, uint256 hi) internal pure returns (uint256) {
        return lo + (x % (hi - lo + 1));
    }

    function _hop(address tin, address tout, bool zfo, address pool, uint256 amt, uint256 quoted)
        internal pure returns (Hop memory h)
    {
        Leg[] memory legs = new Leg[](1);
        legs[0] = Leg({
            pool: pool, hooks: address(0), kind: BPC.KIND_V2, fee: 30, tickSpacing: 0,
            zeroForOne: zfo, stable: false, amountIn: amt, expectedOut: quoted, auxId: bytes32(0)
        });
        h = Hop({tokenIn: tin, tokenOut: tout, amountIn: amt, expectedOut: quoted, legs: legs});
    }

    /// @param dirSeed even = A->C->B, odd = B->C->A. @param amtSeed swap size.
    function twoHop(uint256 dirSeed, uint256 amtSeed) external {
        uint256 amt = _bound(amtSeed, 1e15, 1e21);
        Hop[] memory hops = new Hop[](2);

        if (dirSeed % 2 == 0) {
            A.mint(address(this), amt);
            A.approve(address(router), amt);
            C.mint(address(pAC), LIQ); // pAC pays out C
            B.mint(address(pCB), LIQ); // pCB pays out B
            mintedA += amt; mintedC += LIQ; mintedB += LIQ;
            bool zfo1 = address(A) == pAC.token0();
            bool zfo2 = address(C) == pCB.token0();
            hops[0] = _hop(address(A), address(C), zfo1, address(pAC), amt, amt); // quoted ~1:1 at deep liq
            hops[1] = _hop(address(C), address(B), zfo2, address(pCB), amt, amt);
        } else {
            B.mint(address(this), amt);
            B.approve(address(router), amt);
            C.mint(address(pCB), LIQ); // pCB pays out C
            A.mint(address(pAC), LIQ); // pAC pays out A
            mintedB += amt; mintedC += LIQ; mintedA += LIQ;
            bool zfo1 = address(B) == pCB.token0();
            bool zfo2 = address(C) == pAC.token0();
            hops[0] = _hop(address(B), address(C), zfo1, address(pCB), amt, amt);
            hops[1] = _hop(address(C), address(A), zfo2, address(pAC), amt, amt);
        }

        Route memory r = Route({
            hops: hops, totalOut: amt, singleOut: amt, singleOutFloor: 0,
            expectedImpactBps: 0, confidenceWad: 0, estGas: 0, hasSurplus: false, isV4Bundle: false
        });
        try router.swapExactIn(r, amt, 0, recipient, block.timestamp + 1) returns (uint256) {
            unchecked { ++swaps; }
        } catch {}
    }
}

contract RouterMultiHopInvariantFromV1Test is StdInvariant, Test {
    BlazePhoenixRouter router;
    MockERC20 A;
    MockERC20 B;
    MockERC20 C;
    MockV2Pair pAC;
    MockV2Pair pCB;
    MultiHopHandler handler;

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
        C = new MockERC20("C", "C");
        pAC = new MockV2Pair(address(A), address(C));
        pCB = new MockV2Pair(address(C), address(B));
        pAC.setReserves(1e30, 1e30); // quote-only bookkeeping; the handler funds real payouts per-call
        pCB.setReserves(1e30, 1e30);

        handler = new MultiHopHandler(router, A, B, C, pAC, pCB, recipient);
        targetContract(address(handler));
    }

    /// INV1 — including the intermediate C: no token is ever stranded mid-route in the Router.
    function invariant_routerHoldsNothing() public view {
        assertEq(A.balanceOf(address(router)), 0, "A stuck in Router");
        assertEq(B.balanceOf(address(router)), 0, "B stuck in Router");
        assertEq(C.balanceOf(address(router)), 0, "intermediate C stuck in Router");
    }

    function _sum(MockERC20 t) internal view returns (uint256) {
        return t.balanceOf(address(handler)) + t.balanceOf(address(pAC))
            + t.balanceOf(address(pCB)) + t.balanceOf(address(router))
            + t.balanceOf(recipient) + t.balanceOf(treasury1) + t.balanceOf(treasury2);
    }

    function invariant_conservationA() public view { assertEq(_sum(A), handler.mintedA(), "A not conserved"); }
    function invariant_conservationB() public view { assertEq(_sum(B), handler.mintedB(), "B not conserved"); }
    function invariant_conservationC() public view {
        assertEq(_sum(C), handler.mintedC(), "intermediate C not conserved");
    }

    /// @dev Guards against a vacuous pass: mints happen unconditionally, so conservation would
    ///      hold trivially even if every real 2-hop swap silently reverted. afterInvariant runs
    ///      once at the end of the whole campaign (unlike invariant_* functions, which are also
    ///      checked at step zero before any handler call, where this would trivially be 0).
    function afterInvariant() public view {
        assertGt(handler.swaps(), 0, "no 2-hop swap ever succeeded across the whole campaign - vacuous pass");
    }
}
