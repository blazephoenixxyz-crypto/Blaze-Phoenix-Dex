// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// =============================================================================
//  ROUTER CALLBACK AUTH — offline unit tests (no fork, no RPC).
//
//  The Router exposes two externally-reachable callback entrypoints:
//    * a universal fallback() that any V3-shaped pool calls back into during a
//      swap (uniswapV3SwapCallback / pancakeV3SwapCallback / algebra / …), and
//    * unlockCallback(bytes) that the Uniswap V4 PoolManager calls after unlock.
//
//  Both pay tokens OUT of the Router, so an UNSOLICITED call to either — outside
//  a swap, or from anyone other than the committed counterparty — is the classic
//  router-drain vector. These tests prove the auth gates hold with no swap in
//  flight (the transient context slots are zero), which is exactly when an
//  attacker would try to fire them.
// =============================================================================

import { Test } from "forge-std/Test.sol";
import { BlazePhoenixHub }    from "../src/BlazePhoenixHub.sol";
import { BlazePhoenixSolver } from "../src/BlazePhoenixSolver.sol";
import { BlazePhoenixRouter } from "../src/BlazePhoenixRouter.sol";

// V3-shaped callback shape: (int256, int256, bytes). Selector is irrelevant —
// the Router's fallback reads amounts straight from calldata offsets.
interface IV3Callback {
    function uniswapV3SwapCallback(int256 a0, int256 a1, bytes calldata data) external payable;
}

contract RouterCallbackAuthTest is Test {
    // Mirror of the Router's custom error so we can assert the exact code.
    error RouterE(uint16 code);

    BlazePhoenixHub    hub;
    BlazePhoenixRouter router;
    address v4mgr    = makeAddr("v4PoolManager");
    address attacker = makeAddr("attacker");

    function setUp() public {
        hub = new BlazePhoenixHub();
        hub.initialize(address(this), v4mgr);
        BlazePhoenixSolver solver = new BlazePhoenixSolver(address(hub));
        router = new BlazePhoenixRouter(
            address(hub), address(solver), address(this), address(this), address(this));
    }

    /// @dev Bubble a raw call's revert so vm.expectRevert can match it
    ///      (a plain low-level call would swallow the revert).
    function rawCall(bytes calldata cd) external {
        (bool ok, bytes memory ret) = address(router).call(cd);
        if (!ok) assembly { revert(add(ret, 0x20), mload(ret)) }
    }

    // ── P: an unsolicited V3 callback (no swap in flight) reverts RouterE(6). ──
    function test_v3Callback_unsolicited_reverts() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(RouterE.selector, uint16(6)));
        IV3Callback(address(router)).uniswapV3SwapCallback(1_000, 0, "");
    }

    // ── P: the same gate holds even if the caller spoofs realistic amounts. ──
    function test_v3Callback_unsolicited_reverts_negativeDelta() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(RouterE.selector, uint16(6)));
        IV3Callback(address(router)).uniswapV3SwapCallback(-5_000, 7_000, hex"deadbeef");
    }

    // ── P: ETH sent into the callback path reverts RouterE(3) before anything. ──
    function test_v3Callback_withValue_reverts() public {
        vm.deal(attacker, 1 ether);
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(RouterE.selector, uint16(3)));
        IV3Callback(address(router)).uniswapV3SwapCallback{value: 1}(1_000, 0, "");
    }

    // ── P: truncated callback calldata (< 4+64 bytes) reverts RouterE(3). ──
    function test_v3Callback_shortCalldata_reverts() public {
        // selector + a single 32-byte word = 36 bytes (< 68) → RouterE(3). The
        // length guard fires before any auth check, so the caller is irrelevant.
        bytes memory cd = abi.encodePacked(IV3Callback.uniswapV3SwapCallback.selector, uint256(1));
        vm.expectRevert(abi.encodeWithSelector(RouterE.selector, uint16(3)));
        this.rawCall(cd);
    }

    // ── P: V4 unlockCallback from anyone but the PoolManager reverts RouterE(6). ──
    function test_unlockCallback_nonManager_reverts() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(RouterE.selector, uint16(6)));
        router.unlockCallback("");
    }

    // ── P: even the real PoolManager cannot drive unlockCallback outside a swap
    //    (transient tIn/tOut are zero) — reverts RouterE(6). ──
    function test_unlockCallback_managerOutsideSwap_reverts() public {
        // Minimal validly-encoded payload so decoding succeeds and we reach the
        // tIn/tOut==0 guard: (V4PoolKey, bool, uint256, bytes). V4PoolKey is an
        // all-static 5-field struct, so a flat abi.encode of its fields + the
        // trailing args is byte-identical to encoding the struct (and gets the
        // dynamic `bytes` offset right).
        bytes memory data = abi.encode(
            address(0), address(0), uint24(0), int24(0), address(0), // V4PoolKey
            false, uint256(1), bytes("")
        );
        vm.prank(v4mgr);
        vm.expectRevert(abi.encodeWithSelector(RouterE.selector, uint16(6)));
        router.unlockCallback(data);
    }
}
