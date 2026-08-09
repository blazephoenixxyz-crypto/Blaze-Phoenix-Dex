// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// Ported from Blaze-Phoenix-Dex (V1) test/RouterExecGuards.t.sol — only the V4 hookAltersDeltas
// guard. The reentrancy guard (RouterE(7)) is already fully covered here by
// BlazePhoenixRouter.t.sol's test_ReentrancyGuard_BlocksNestedSwapExactInDuringTokenPull, using a
// dedicated MaliciousReentrantERC20 mock — no gap there.
//
// hookAltersDeltas() itself IS unit-tested here (BlazePhoenixCore.t.sol, pure bit-flag logic),
// but nothing proves the ROUTER actually refuses to execute a V4 leg carrying such a hook before
// ever unlocking the PoolManager — the end-to-end integration point RouterE(9) exists to guard.
//
// forge test --match-contract RouterExecGuardsFromV1 -vv

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract RouterExecGuardsFromV1Test is Test {
    uint8 constant KIND_V4 = 4;

    BlazePhoenixHub hub;
    BlazePhoenixRouter router;
    address v4mgr = makeAddr("v4PoolManager");
    address recipient = makeAddr("recipient");

    function setUp() public {
        hub = new BlazePhoenixHub();
        hub.initialize(address(this), v4mgr); // nonzero V4 manager, required to reach the hook check
        BlazePhoenixSolver solver = new BlazePhoenixSolver(address(hub));
        router = new BlazePhoenixRouter(
            address(hub), address(solver), address(this), address(this), address(this));
    }

    function test_v4_hookAltersDeltas_RejectedBeforeUnlock() public {
        MockERC20 tin = new MockERC20("IN", "IN");
        uint256 amt = 1e18;
        tin.mint(address(this), amt);
        tin.approve(address(router), amt);

        // Hook address with a delta-returning permission bit set (bit 2 = AFTER_SWAP_RETURNS_DELTA)
        // -> hookAltersDeltas() must flag it, and the Router must refuse the leg before unlocking.
        address badHook = address(uint160(1 << 2));

        Leg memory leg = Leg({
            pool: address(0xDEAD), hooks: badHook, kind: KIND_V4, fee: 0, tickSpacing: 0,
            zeroForOne: true, stable: false, amountIn: amt, expectedOut: 0, auxId: bytes32(0)
        });
        Leg[] memory legs = new Leg[](1); legs[0] = leg;
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({
            tokenIn: address(tin), tokenOut: makeAddr("tout"),
            amountIn: amt, expectedOut: 0, legs: legs
        });
        Route memory r; r.hops = hops;

        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, uint16(9)));
        router.swapExactIn(r, amt, 0, recipient, block.timestamp + 1);
    }
}
