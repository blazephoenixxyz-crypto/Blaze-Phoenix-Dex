// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// =============================================================================
//  ROUTER ADVERSARIAL INVARIANTS — malicious BRIDGE pool (2-hop), offline.
//
//  Every other adversarial suite is single-hop. This one crafts a 2-hop route
//  A -> B(bridge) -> C where the SECOND-stage pool is hostile: it can decline
//  to collect the bridge token it is handed (a real pool reverts when unpaid;
//  a hostile one in a caller-supplied Route need not). The question the master
//  invariants answer: does the holds-nothing enforcement — which the earlier
//  fix applied to the INPUT token — also protect the intermediate BRIDGE token,
//  or can B be stranded in the Router (and later swept)?
//
//    INV-C  conservation of A, B and C (nothing created or destroyed)
//    INV-R  the Router holds 0 of A, 0 of B (the bridge) and 0 of C at rest
//
//    forge test --match-contract RouterAdversarialMultiHop -vv
// =============================================================================

import { Test } from "forge-std/Test.sol";
import { BlazePhoenixHub }    from "../src/BlazePhoenixHub.sol";
import { BlazePhoenixSolver } from "../src/BlazePhoenixSolver.sol";
import { BlazePhoenixRouter } from "../src/BlazePhoenixRouter.sol";
import { Route, Hop, Leg } from "../src/BlazePhoenixCore.sol";
import { MockERC20Exec, MockV2ExecPool } from "./RouterExecGuards.t.sol";
import { HostileV3Pool } from "./RouterAdversarialInvariant.t.sol";

contract MHAdversary {
    BlazePhoenixRouter immutable router;
    MockERC20Exec immutable A;
    MockERC20Exec immutable B;   // the bridge token
    MockERC20Exec immutable C;
    MockV2ExecPool immutable ab; // honest A -> B
    HostileV3Pool  immutable bc; // hostile B -> C

    uint256 public mintedA;
    uint256 public mintedB;
    uint256 public mintedC;
    uint256 public settled;

    constructor(
        BlazePhoenixRouter _r, MockERC20Exec _a, MockERC20Exec _b, MockERC20Exec _c,
        MockV2ExecPool _ab, HostileV3Pool _bc
    ) { router = _r; A = _a; B = _b; C = _c; ab = _ab; bc = _bc; }

    function _bound(uint256 x, uint256 lo, uint256 hi) internal pure returns (uint256) {
        return lo + (x % (hi - lo + 1));
    }

    /// 2-hop A->B->C where the stage-B pool is hostile (fuzzed collect / payout).
    function swapMH(uint256 amtSeed, uint256 nSeed, uint256 paySeed) external {
        uint256 amt = _bound(amtSeed, 1e15, 1e21);
        A.mint(address(this), amt);        mintedA += amt;
        B.mint(address(ab), 1e27);         mintedB += 1e27;   // ab pays B out
        uint256 pay = _bound(paySeed, 0, 5e21);
        C.mint(address(bc), pay);          mintedC += pay;     // bc can pay C out

        // Arm bc: collect the bridge 0..3 times (0 = never collect → strand risk).
        bc.arm(_bound(nSeed, 0, 3), 1e21, pay, false /* pay token1 = C */);

        // hop0: A->B honest V2; hop1: B->C hostile V3. expectedOut=0 on both so
        // the per-leg floor is skipped and any stranding manifests, not reverts.
        Leg memory l0 = Leg({
            pool: address(ab), hooks: address(0), kind: 0 /*V2*/, fee: 0, tickSpacing: 0,
            zeroForOne: true, stable: false, amountIn: amt, expectedOut: 0, auxId: bytes32(0)
        });
        Leg memory l1 = Leg({
            pool: address(bc), hooks: address(0), kind: 1 /*V3*/, fee: 3000, tickSpacing: 60,
            zeroForOne: true, stable: false, amountIn: amt, expectedOut: 0, auxId: bytes32(0)
        });
        Leg[] memory legs0 = new Leg[](1); legs0[0] = l0;
        Leg[] memory legs1 = new Leg[](1); legs1[0] = l1;
        Hop[] memory hops = new Hop[](2);
        hops[0] = Hop({ tokenIn: address(A), tokenOut: address(B), amountIn: amt, expectedOut: 0, legs: legs0 });
        hops[1] = Hop({ tokenIn: address(B), tokenOut: address(C), amountIn: amt, expectedOut: 0, legs: legs1 });
        Route memory r; r.hops = hops;

        try router.swapExactIn(r, amt, 0, address(this), block.timestamp + 1)
            returns (uint256) { unchecked { ++settled; } } catch {}
    }
}

contract RouterAdversarialMultiHop is Test {
    BlazePhoenixHub    hub;
    BlazePhoenixRouter router;
    MockERC20Exec A;
    MockERC20Exec B;
    MockERC20Exec C;
    MockV2ExecPool ab;
    HostileV3Pool  bc;
    MHAdversary    adv;

    address treasury1 = makeAddr("t1");
    address treasury2 = makeAddr("t2");

    function setUp() public {
        hub = new BlazePhoenixHub();
        hub.initialize(address(this), makeAddr("v4mgr"));
        BlazePhoenixSolver solver = new BlazePhoenixSolver(address(hub));
        router = new BlazePhoenixRouter(
            address(hub), address(solver), address(this), treasury1, treasury2);

        A = new MockERC20Exec();
        B = new MockERC20Exec();
        C = new MockERC20Exec();
        ab = new MockV2ExecPool(address(A), address(B), uint112(1e27), uint112(1e27));
        bc = new HostileV3Pool(address(B), address(C));
        adv = new MHAdversary(router, A, B, C, ab, bc);
        targetContract(address(adv));
    }

    function _sum(MockERC20Exec t) internal view returns (uint256) {
        return t.balanceOf(address(adv)) + t.balanceOf(address(ab))
             + t.balanceOf(address(bc)) + t.balanceOf(address(router))
             + t.balanceOf(treasury1) + t.balanceOf(treasury2);
    }

    function invariant_conservationA() public view { assertEq(_sum(A), adv.mintedA(), "MH: A not conserved"); }
    function invariant_conservationB() public view { assertEq(_sum(B), adv.mintedB(), "MH: B not conserved"); }
    function invariant_conservationC() public view { assertEq(_sum(C), adv.mintedC(), "MH: C not conserved"); }

    /// The bridge token B is the one at risk: does holds-nothing cover it?
    function invariant_routerHoldsNothing() public view {
        assertEq(A.balanceOf(address(router)), 0, "MH: A stuck in Router");
        assertEq(B.balanceOf(address(router)), 0, "MH: B (bridge) stuck in Router");
        assertEq(C.balanceOf(address(router)), 0, "MH: C stuck in Router");
    }
}
