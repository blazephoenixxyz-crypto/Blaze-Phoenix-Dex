// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixRouter, IV4PoolManager} from "../src/BlazePhoenixRouter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @dev A V4 manager that COUNTS the swaps it is asked to perform. The counter is the witness
///      this file exists for: the guard under test refuses **before** the manager is touched, and
///      no `expectRevert` on a shared error code can show that (three sites emit `RouterE(6)`).
contract CountingV4Manager {
    uint256 public swapCalls;

    function swap(
        IV4PoolManager.V4PoolKey calldata, IV4PoolManager.SwapParams calldata, bytes calldata
    ) external returns (int256) {
        swapCalls += 1;
        return 0;
    }
}

/// @notice THE WITNESS FOR THE UNLOCK CALLBACK'S CONTEXT GUARD.
///
///         `unlockCallback` has two sites that emit `RouterE(6)`:
///
///             :2064  if (msg.sender != mgr) revert RouterE(6);
///             :2072  if (tIn == address(0) || tOut == address(0)) revert RouterE(6);   <-- this one
///
///         (`_v3Callback`'s `:2038` is a third site of the same code, in another function.)
///         Removing **:2072** changed the result of no existing test: the guard had no witness.
///
///         How the site is reached with the premise asserted, so the refusal can only be its:
///           · the caller IS the manager (`vm.prank(address(mgr))`), and `hub.v4PoolManager()`
///             is asserted equal to it ⇒ the `:2064` site cannot be the one firing;
///           · the transient context (`TSLOT_V4IN`/`TSLOT_V4OUT`) is empty — the callback is
///             being called with no leg in flight, which is exactly what the guard exists for;
///           · therefore the manager must never be called: `mgr.swapCalls() == 0` is the
///             observable that **only** this guard produces.
///
///         Doctrine, from the mutation list's own header: a revert with the right code does not
///         prove the right check fired. A witness is an observable the named guard alone produces
///         (test/PausedSwapHookArmIsWitnessed.t.sol uses the same construction for the hook
///         sieve's second arm).
contract UnlockCallbackNoContextArmIsWitnessedTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixRouter router;
    CountingV4Manager mgr;

    address user = address(0xBEEF);

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        mgr = new CountingV4Manager();
        hub.setV4Manager(address(mgr));
        router = new BlazePhoenixRouter(
            address(hub), address(0xBEE2), address(this), address(0xFEE1), address(0xFEE2)
        );
    }

    /// @dev The payload the manager would hand the Router during an unlock. The key is a plainly
    ///      non-native pool, so nothing here depends on the native seam.
    function _data() private pure returns (bytes memory) {
        IV4PoolManager.V4PoolKey memory key = IV4PoolManager.V4PoolKey({
            currency0: address(0x1000),
            currency1: address(0x2000),
            fee: 3000,
            tickSpacing: 60,
            hooks: address(0)
        });
        return abi.encode(key, true, uint256(1e18), bytes(""));
    }

    /// @notice The guard refuses a manager-authenticated callback that carries no leg context,
    ///         and the manager is provably never reached.
    function test_ManagerCallWithNoContext_IsRefusedBeforeTheManagerIsTouched() public {
        assertEq(hub.v4PoolManager(), address(mgr), "premise: the manager is wired");
        assertTrue(address(mgr) != user, "premise: the manager and the user are distinct");

        vm.prank(address(mgr));
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, 6));
        router.unlockCallback(_data());

        assertEq(mgr.swapCalls(), 0, "witness: the manager was never touched");
    }

    /// @notice Control: the same payload from a caller that is NOT the manager is refused too —
    ///         by the OTHER site (`:2064`). The counter is zero here as well, so the counter alone
    ///         does not attribute: what attributes is the premise (who calls). This is the mirror of
    ///         the control in PausedSwapHookArmIsWitnessed: only the witness may fall when the guard is removed.
    function test_Control_NonManagerCaller_IsRefusedAndAlsoTouchesNothing() public {
        assertTrue(user != address(mgr), "control: the caller is not the manager");

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, 6));
        router.unlockCallback(_data());

        assertEq(mgr.swapCalls(), 0, "control: nothing was touched here either");
    }
}
