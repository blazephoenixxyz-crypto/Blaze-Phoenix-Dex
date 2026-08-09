// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// Closes coverage gaps found by auditing the PUBLIC surface against the test suite. Three
// externally-callable functions had zero references anywhere in tests:
//
//   * Router.swapExactInWith7702  — one of the five auth entry points the README advertises
//   * Hub.setOperator             — a privileged role mutator (dimension 4: privilege)
//   * Hub.setV4Manager            — repoints the V4 singleton every V4 leg trusts
//
// The 7702 test also pins down something the audit surfaced: that entry point is a byte-for-byte
// ALIAS of swapExactIn. Asserting the equivalence keeps the claim honest — if anyone later adds
// real 7702-specific logic, this test fails and forces the docs to be updated with it.
//
// forge test --match-contract UntestedSurface -vv

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";

contract UntestedSurfaceTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixRouter router;
    MockERC20 tokenIn;
    MockERC20 tokenOut;
    MockV2Pair pair;
    address user = address(0xBEEF);

    function setUp() public {
        hub = new BlazePhoenixHub();
        hub.initialize(address(this), address(0));
        BlazePhoenixSolver solver = new BlazePhoenixSolver(address(hub));
        router = new BlazePhoenixRouter(
            address(hub), address(solver), address(this), address(0xFEE1), address(0xFEE2));
        hub.setRoles(address(router), address(solver), address(this));

        tokenIn = new MockERC20("IN", "IN");
        tokenOut = new MockERC20("OUT", "OUT");
        pair = new MockV2Pair(address(tokenIn), address(tokenOut));
        tokenIn.mint(address(pair), 1_000_000e18);
        tokenOut.mint(address(pair), 1_000_000e18);
        pair.setReserves(uint112(1_000_000e18), uint112(1_000_000e18));

        tokenIn.mint(user, 1_000_000e18);
        vm.prank(user);
        tokenIn.approve(address(router), type(uint256).max);
    }

    function _route(uint256 amt) internal view returns (Route memory r) {
        uint256 quoted = BPC.outV2(amt, 1_000_000e18, 1_000_000e18, 30);
        Leg[] memory legs = new Leg[](1);
        legs[0] = Leg({
            pool: address(pair), hooks: address(0), kind: BPC.KIND_V2, fee: 30, tickSpacing: 0,
            zeroForOne: address(tokenIn) == pair.token0(), stable: false,
            amountIn: amt, expectedOut: quoted, auxId: bytes32(0)
        });
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({
            tokenIn: address(tokenIn), tokenOut: address(tokenOut),
            amountIn: amt, expectedOut: quoted, legs: legs
        });
        r = Route({
            hops: hops, totalOut: quoted, singleOut: quoted, singleOutFloor: 0,
            expectedImpactBps: 0, confidenceWad: 0, estGas: 0, hasSurplus: false, isV4Bundle: false
        });
    }

    /// @notice The 7702 entry point delivers exactly what swapExactIn delivers, for the same
    ///         inputs and the same starting state. Documents the alias as an executable fact.
    function test_7702_IsAnExactAliasOfSwapExactIn() public {
        uint256 amt = 1_000e18;
        // Build the route BEFORE pranking: _route() makes an external pair.token0() call, which
        // would otherwise consume vm.prank's single-next-call scope and run the swap as the test
        // contract (which holds no tokens) instead of `user`.
        Route memory r = _route(amt);
        uint256 dl = block.timestamp + 1;

        uint256 snap = vm.snapshotState();
        vm.prank(user);
        uint256 viaClassic = router.swapExactIn(r, amt, 0, user, dl);
        vm.revertToState(snap);

        vm.prank(user);
        uint256 via7702 = router.swapExactInWith7702(r, amt, 0, user, dl);

        assertEq(via7702, viaClassic,
            "the 7702 entry point must deliver exactly what swapExactIn delivers - it is an alias");
        assertGt(via7702, 0, "the swap must actually settle for this comparison to mean anything");
    }

    /// @notice 7702 is still subject to every guard the classic path enforces — an alias must
    ///         not be a bypass.
    function test_7702_RespectsPauseAndDeadline() public {
        uint256 amt = 1_000e18;
        // Same reason as above: hoist the external calls out from under prank/expectRevert.
        Route memory r = _route(amt);
        uint256 past = block.timestamp - 1;
        uint256 future = block.timestamp + 1;

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, 4));
        router.swapExactInWith7702(r, amt, 0, user, past);

        router.setPaused(true);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, 2));
        router.swapExactInWith7702(r, amt, 0, user, future);
    }

    // ─── Hub privileged mutators (dimension 4) ────────────────────────────────

    function test_SetOperator_OnlyControl_AndGrantsSeedPool() public {
        address op = makeAddr("operator");

        vm.prank(address(0xBAD));
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixHub.HubE.selector, uint16(1)));
        hub.setOperator(op, true);

        // Before the grant, the operator-only path is closed.
        vm.prank(op);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixHub.HubE.selector, uint16(1)));
        hub.seedPool(address(pair), BPC.KIND_V2, 30, address(0), address(tokenIn), address(tokenOut));

        hub.setOperator(op, true);
        vm.prank(op);
        hub.seedPool(address(pair), BPC.KIND_V2, 30, address(0), address(tokenIn), address(tokenOut));
        assertEq(hub.getActivePools(address(tokenIn), address(tokenOut)).length, 1,
            "a granted operator must be able to seed");

        // Revocation must actually close the door again.
        hub.setOperator(op, false);
        vm.prank(op);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixHub.HubE.selector, uint16(1)));
        hub.seedPool(address(0x1234), BPC.KIND_V2, 30, address(0), address(tokenIn), address(tokenOut));
    }

    function test_SetV4Manager_OnlyControl_AndTakesEffect() public {
        address mgr = makeAddr("v4manager");

        vm.prank(address(0xBAD));
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixHub.HubE.selector, uint16(1)));
        hub.setV4Manager(mgr);

        hub.setV4Manager(mgr);
        assertEq(hub.v4PoolManager(), mgr, "the V4 singleton every V4 leg trusts must be repointed");
    }

    /// @notice renounceControl must freeze BOTH mutators — otherwise "ossified" is a lie.
    function test_RenounceControl_FreezesOperatorAndV4Manager() public {
        hub.renounceControl();
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixHub.HubE.selector, uint16(1)));
        hub.setOperator(address(0x1), true);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixHub.HubE.selector, uint16(1)));
        hub.setV4Manager(address(0x2));
    }
}
