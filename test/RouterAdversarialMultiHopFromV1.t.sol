// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Ported from Blaze-Phoenix-Dex (V1) test/RouterAdversarialMultiHop.t.sol — the last of the 15 V1
// test files assessed for this reconstruction. Every other adversarial suite here is single-hop.
// This one crafts a 2-hop route A -> B(bridge) -> C where the SECOND-stage pool is hostile: a
// real pool reverts when unpaid, but a hostile one in a caller-supplied Route need not decline
// gracefully. The question: does holds-nothing enforcement also protect the INTERMEDIATE bridge
// token B (only ever held mid-route, never by the caller directly), or can it be stranded?
//
// INV-C  conservation of A, B and C (nothing created or destroyed)
// INV-R  the Router holds 0 of A, 0 of the bridge B, and 0 of C at rest
//
// forge test --match-contract RouterAdversarialMultiHopFromV1 -vv

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";
import {HostileV3Pool} from "./RouterAdversarialInvariantFromV1.t.sol";

contract MHAdversary {
    BlazePhoenixRouter immutable router;
    MockERC20 immutable A;
    MockERC20 immutable B; // the bridge token
    MockERC20 immutable C;
    MockV2Pair immutable ab; // honest A -> B
    HostileV3Pool immutable bc; // hostile B -> C

    uint256 public mintedA;
    uint256 public mintedB;
    uint256 public mintedC;
    uint256 public settled;

    constructor(
        BlazePhoenixRouter _r, MockERC20 _a, MockERC20 _b, MockERC20 _c,
        MockV2Pair _ab, HostileV3Pool _bc
    ) { router = _r; A = _a; B = _b; C = _c; ab = _ab; bc = _bc; }

    function _bound(uint256 x, uint256 lo, uint256 hi) internal pure returns (uint256) {
        return lo + (x % (hi - lo + 1));
    }

    /// 2-hop A->B->C where the stage-B pool is hostile (fuzzed collect / payout).
    function swapMH(uint256 amtSeed, uint256 nSeed, uint256 paySeed) external {
        uint256 amt = _bound(amtSeed, 1e15, 1e21);
        A.mint(address(this), amt); mintedA += amt;
        A.approve(address(router), amt);
        B.mint(address(ab), 1e27); mintedB += 1e27; // ab pays B out
        uint256 pay = _bound(paySeed, 0, 5e21);
        C.mint(address(bc), pay); mintedC += pay; // bc can pay C out

        // Arm bc: collect the bridge 0..3 times (0 = never collect -> strand risk).
        bc.arm(_bound(nSeed, 0, 3), 1e21, pay, false /* pay token1 = C */);

        bool zfo0 = address(A) == ab.token0();
        bool zfo1 = address(B) == bc.token0();
        Leg memory l0 = Leg({
            pool: address(ab), hooks: address(0), kind: BPC.KIND_V2, fee: 30, tickSpacing: 0,
            zeroForOne: zfo0, stable: false, amountIn: amt, expectedOut: 0, auxId: bytes32(0)
        });
        Leg memory l1 = Leg({
            pool: address(bc), hooks: address(0), kind: BPC.KIND_V3, fee: 3000, tickSpacing: 60,
            zeroForOne: zfo1, stable: false, amountIn: amt, expectedOut: 0, auxId: bytes32(0)
        });
        Leg[] memory legs0 = new Leg[](1); legs0[0] = l0;
        Leg[] memory legs1 = new Leg[](1); legs1[0] = l1;
        Hop[] memory hops = new Hop[](2);
        hops[0] = Hop({tokenIn: address(A), tokenOut: address(B), amountIn: amt, expectedOut: 0, legs: legs0});
        hops[1] = Hop({tokenIn: address(B), tokenOut: address(C), amountIn: amt, expectedOut: 0, legs: legs1});
        Route memory r; r.hops = hops;
        // expectedOut/totalOut left at 0 on both hops so the per-leg/aggregate floor is skipped
        // and any stranding manifests as a failed invariant, not a clean revert.

        try router.swapExactIn(r, amt, 0, address(this), block.timestamp + 1)
            returns (uint256) { unchecked { ++settled; } } catch {}
    }
}

contract RouterAdversarialMultiHopFromV1Test is StdInvariant, Test {
    BlazePhoenixHub hub;
    BlazePhoenixRouter router;
    MockERC20 A;
    MockERC20 B;
    MockERC20 C;
    MockV2Pair ab;
    HostileV3Pool bc;
    MHAdversary adv;

    address treasury1 = makeAddr("t1");
    address treasury2 = makeAddr("t2");

    function setUp() public {
        hub = new BlazePhoenixHub();
        hub.initialize(address(this), makeAddr("v4mgr"));
        BlazePhoenixSolver solver = new BlazePhoenixSolver(address(hub));
        router = new BlazePhoenixRouter(address(hub), address(solver), address(this), treasury1, treasury2);

        A = new MockERC20("A", "A");
        B = new MockERC20("B", "B");
        C = new MockERC20("C", "C");
        ab = new MockV2Pair(address(A), address(B));
        ab.setReserves(1e27, 1e27);
        bc = new HostileV3Pool(address(B), address(C));
        adv = new MHAdversary(router, A, B, C, ab, bc);
        targetContract(address(adv));
    }

    function _sum(MockERC20 t) internal view returns (uint256) {
        return t.balanceOf(address(adv)) + t.balanceOf(address(ab))
             + t.balanceOf(address(bc)) + t.balanceOf(address(router))
             + t.balanceOf(treasury1) + t.balanceOf(treasury2);
    }

    function invariant_conservationA() public view { assertEq(_sum(A), adv.mintedA(), "A not conserved"); }
    function invariant_conservationB() public view { assertEq(_sum(B), adv.mintedB(), "B not conserved"); }
    function invariant_conservationC() public view { assertEq(_sum(C), adv.mintedC(), "C not conserved"); }

    /// The bridge token B is the one at risk: does holds-nothing cover it?
    function invariant_routerHoldsNothing() public view {
        assertEq(A.balanceOf(address(router)), 0, "A stuck in Router");
        assertEq(B.balanceOf(address(router)), 0, "B (bridge) stuck in Router");
        assertEq(C.balanceOf(address(router)), 0, "C stuck in Router");
    }

    /// @dev Guards against a vacuous pass (see RouterMultiHopInvariantFromV1.t.sol).
    function afterInvariant() public view {
        assertGt(adv.settled(), 0, "no adversarial 2-hop route ever settled across the whole campaign");
    }
}
