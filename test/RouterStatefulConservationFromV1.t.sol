// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// Ported from Blaze-Phoenix-Dex (V1) test/RouterStatefulInvariant.t.sol — only the property this
// repo's own BlazePhoenixRouter.invariant.t.sol doesn't check. That suite already covers
// holds-nothing (across 4 tokens/3 pairs, multi-hop capable) and a fee-bound invariant V1 never
// had. What's missing is full LEDGER conservation: the sum of every holder's balance (swapper,
// pool, Router, recipient, both treasuries) must equal the total ever minted into the system —
// a strictly stronger, complementary check than "the Router itself holds nothing", since it also
// catches value silently created or destroyed anywhere else in the fee-split/delivery path.
//
// forge test --match-contract RouterStatefulConservationFromV1 -vv

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";

contract ConservationSwapHandler {
    BlazePhoenixRouter immutable router;
    MockERC20 immutable A;
    MockERC20 immutable B;
    MockV2Pair immutable pool;
    address immutable recipient;

    uint256 public swaps;
    uint256 public mintedA;
    uint256 public mintedB;

    constructor(BlazePhoenixRouter _router, MockERC20 _a, MockERC20 _b, MockV2Pair _pool, address _recipient) {
        router = _router; A = _a; B = _b; pool = _pool; recipient = _recipient;
    }

    function _bound(uint256 x, uint256 lo, uint256 hi) internal pure returns (uint256) {
        return lo + (x % (hi - lo + 1));
    }

    function swap(uint256 dirSeed, uint256 amtSeed) external {
        bool zfo = dirSeed % 2 == 0;
        MockERC20 tin = zfo ? A : B;
        MockERC20 tout = zfo ? B : A;
        uint256 amt = _bound(amtSeed, 1e15, 1e21);

        tin.mint(address(this), amt);
        tout.mint(address(pool), 1e27); // keep the pool solvent to pay out
        if (zfo) { mintedA += amt; mintedB += 1e27; } else { mintedB += amt; mintedA += 1e27; }
        tin.approve(address(router), amt);

        (uint112 r0, uint112 r1,) = pool.getReserves();
        address t0 = pool.token0();
        uint256 rIn = address(tin) == t0 ? r0 : r1;
        uint256 rOut = address(tin) == t0 ? r1 : r0;
        uint256 quoted = BPC.outV2(amt, rIn, rOut, 30);
        if (quoted == 0) return;

        Leg memory leg = Leg({
            pool: address(pool), hooks: address(0), kind: BPC.KIND_V2, fee: 30, tickSpacing: 0,
            zeroForOne: address(tin) == t0, stable: false, amountIn: amt, expectedOut: quoted, auxId: bytes32(0)
        });
        Leg[] memory legs = new Leg[](1); legs[0] = leg;
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({tokenIn: address(tin), tokenOut: address(tout), amountIn: amt, expectedOut: quoted, legs: legs});
        Route memory r = Route({
            hops: hops, totalOut: quoted, singleOut: quoted, singleOutFloor: 0,
            expectedImpactBps: 0, confidenceWad: 0, estGas: 0, hasSurplus: false, isV4Bundle: false
        });

        try router.swapExactIn(r, amt, 1, recipient, block.timestamp + 1) returns (uint256) {
            unchecked { ++swaps; }
        } catch {}
    }
}

contract RouterStatefulConservationFromV1Test is StdInvariant, Test {
    BlazePhoenixHub hub;
    BlazePhoenixRouter router;
    MockERC20 A;
    MockERC20 B;
    MockV2Pair pool;
    ConservationSwapHandler handler;

    address recipient = makeAddr("recipient");
    address treasury1 = makeAddr("treasury1");
    address treasury2 = makeAddr("treasury2");

    function setUp() public {
        hub = new BlazePhoenixHub();
        hub.initialize(address(this), makeAddr("v4mgr"));
        BlazePhoenixSolver solver = new BlazePhoenixSolver(address(hub));
        router = new BlazePhoenixRouter(address(hub), address(solver), address(this), treasury1, treasury2);

        A = new MockERC20("A", "A");
        B = new MockERC20("B", "B");
        pool = new MockV2Pair(address(A), address(B));
        // Reserves are quote-only bookkeeping here (decoupled from real balance, like V1's
        // MockV2ExecPool) — the handler mints the pool's real payout balance on every call, so
        // pre-funding it here would be an untracked mint the conservation ghosts never see.
        pool.setReserves(1e27, 1e27);

        handler = new ConservationSwapHandler(router, A, B, pool, recipient);
        targetContract(address(handler));
    }

    function invariant_conservationA() public view {
        uint256 sum = A.balanceOf(address(handler)) + A.balanceOf(address(pool))
            + A.balanceOf(address(router)) + A.balanceOf(recipient)
            + A.balanceOf(treasury1) + A.balanceOf(treasury2);
        assertEq(sum, handler.mintedA(), "token A not conserved across the sequence");
    }

    function invariant_conservationB() public view {
        uint256 sum = B.balanceOf(address(handler)) + B.balanceOf(address(pool))
            + B.balanceOf(address(router)) + B.balanceOf(recipient)
            + B.balanceOf(treasury1) + B.balanceOf(treasury2);
        assertEq(sum, handler.mintedB(), "token B not conserved across the sequence");
    }

    /// @dev Non-vacuousness guard: mints (and the `quoted == 0` early return) happen before the
    ///      swap, so conservation would hold trivially over a campaign of zero executed swaps.
    function afterInvariant() public view {
        assertGt(handler.swaps(), 0, "no swap ever settled across the whole campaign - vacuous pass");
    }
}
