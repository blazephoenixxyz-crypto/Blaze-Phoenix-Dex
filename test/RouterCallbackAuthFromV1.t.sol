// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// Ported from Blaze-Phoenix-Dex (V1) test/RouterCallbackAuth.t.sol — only what this repo's own
// BlazePhoenixRouter.t.sol doesn't already cover under "Universal V3-shaped callback" (which has
// test_Fallback_RevertsWhenNoExpectedPoolIsSet and test_UnlockCallback_RevertsWhenNotV4Manager):
//
//   - the payable-fallback guard (`msg.value > 0` -> RouterE(3)) has no direct test here yet;
//   - the short-calldata guard (`msg.data.length < 4+64` -> RouterE(3)) has no direct test here;
//   - unlockCallback from the REAL PoolManager but with no swap in flight (transient tIn/tOut
//     still zero) is a materially different auth path than "wrong caller entirely" — this repo
//     only tests the latter. Both are router-drain vectors: paying tokens out of the Router via
//     an unsolicited callback, so both the address check AND the transient-context check need
//     their own coverage.
//
// forge test --match-contract RouterCallbackAuthFromV1 -vv

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";

interface IV3Callback {
    function uniswapV3SwapCallback(int256 a0, int256 a1, bytes calldata data) external payable;
}

contract RouterCallbackAuthFromV1Test is Test {
    BlazePhoenixHub hub;
    BlazePhoenixRouter router;
    address v4mgr = makeAddr("v4PoolManager");
    address attacker = makeAddr("attacker");

    function setUp() public {
        hub = new BlazePhoenixHub();
        hub.initialize(address(this), v4mgr);
        BlazePhoenixSolver solver = new BlazePhoenixSolver(address(hub));
        router = new BlazePhoenixRouter(
            address(hub), address(solver), address(this), address(this), address(this));
    }

    /// @dev Bubble a raw call's revert so vm.expectRevert can match it (a plain low-level call
    ///      would otherwise swallow the revert reason).
    function rawCall(bytes calldata cd) external {
        (bool ok, bytes memory ret) = address(router).call(cd);
        if (!ok) assembly { revert(add(ret, 0x20), mload(ret)) }
    }

    function test_v3Callback_withValue_reverts() public {
        vm.deal(attacker, 1 ether);
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, uint16(3)));
        IV3Callback(address(router)).uniswapV3SwapCallback{value: 1}(1_000, 0, "");
    }

    function test_v3Callback_shortCalldata_reverts() public {
        // selector + a single 32-byte word = 36 bytes (< 68) -> RouterE(3). The length guard
        // fires before any auth check, so the caller is irrelevant.
        bytes memory cd = abi.encodePacked(IV3Callback.uniswapV3SwapCallback.selector, uint256(1));
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, uint16(3)));
        this.rawCall(cd);
    }

    /// @notice Even the REAL PoolManager cannot drive unlockCallback outside a swap — the
    ///         transient tIn/tOut context is zero whenever no swap is in flight, and that check
    ///         (not just "are you the manager") is what actually gates the fund-paying path.
    function test_unlockCallback_managerOutsideSwap_reverts() public {
        bytes memory data = abi.encode(
            address(0), address(0), uint24(0), int24(0), address(0), // V4PoolKey (all-static)
            false, uint256(1), bytes("")
        );
        vm.prank(v4mgr);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, uint16(6)));
        router.unlockCallback(data);
    }
}
