// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  Re-entry from the OUTPUT transfer is refused by the lock.
//
//  The existing re-entrancy tests attack from `transferFrom` - the pull of the
//  input. This one attacks from the other end: the leg's OUTPUT token re-enters
//  from its `transfer`, which the pool calls to pay the Router while the swap
//  is still inside the lock. The nested call must be refused by the lock
//  itself (RouterE(7)), not by some later guard, and the outer swap completes.
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";

/// @notice ERC-20 whose outgoing `transfer` makes one call to a chosen target
///         and records the result and the returndata, so the test can say WHICH
///         guard refused, not only that something reverted.
contract ReenteringOutputToken {
    string public name = "EVILOUT";
    string public symbol = "EOUT";
    uint8 public constant decimals = 18;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    address public attackTarget;
    bytes public attackCalldata;
    bool public attacking;
    bool public reentryAttempted;
    bool public reentryReverted;
    bytes public reentryReturndata;

    function mint(address to, uint256 amt) external { balanceOf[to] += amt; }

    function setAttack(address target, bytes calldata cd) external {
        attackTarget = target; attackCalldata = cd; attacking = true;
    }

    function approve(address spender, uint256 amt) external returns (bool) {
        allowance[msg.sender][spender] = amt; return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        if (attacking) {
            attacking = false; // one shot
            reentryAttempted = true;
            (bool ok, bytes memory ret) = attackTarget.call(attackCalldata);
            reentryReverted = !ok;
            reentryReturndata = ret;
        }
        require(balanceOf[msg.sender] >= amt, "EVILOUT: balance");
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amt;
        require(balanceOf[from] >= amt, "EVILOUT: balance");
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

contract ReentryFromTheOutputTransferTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixRouter router;
    MockERC20 honest;
    ReenteringOutputToken evil;
    MockV2Pair pair;

    address user = address(0xBEEF);

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        BlazePhoenixSolver solver = new BlazePhoenixSolver(address(hub));
        router = new BlazePhoenixRouter(
            address(hub), address(solver), address(this), address(0xFEE1), address(0xFEE2));
        hub.setRoles(address(router), address(solver), address(this));

        honest = new MockERC20("HON", "HON");
        evil = new ReenteringOutputToken();
        pair = new MockV2Pair(address(honest), address(evil));

        honest.mint(address(pair), 10_000e18);
        evil.mint(address(pair), 10_000e18);
        pair.setReserves(uint112(10_000e18), uint112(10_000e18));

        honest.mint(user, 3_000e18);
        vm.prank(user);
        honest.approve(address(router), type(uint256).max);
    }

    function _route(uint256 amt) private view returns (Route memory route) {
        Leg[] memory legs = new Leg[](1);
        legs[0] = Leg({
            pool: address(pair), hooks: address(0), kind: BPC.KIND_V2, fee: 30,
            tickSpacing: 0, zeroForOne: address(honest) < address(evil), stable: false,
            amountIn: amt, expectedOut: 1, auxId: bytes32(0)
        });
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({
            tokenIn: address(honest), tokenOut: address(evil),
            amountIn: amt, expectedOut: 1, legs: legs
        });
        route = Route({
            hops: hops, totalOut: 1, singleOut: 1, singleOutFloor: 0,
            expectedImpactBps: 0, confidenceWad: 0, estGas: 0,
            hasSurplus: false, isV4Bundle: false
        });
    }

    function test_Lock_RefusesANestedSwapFromTheOutputTransfer() public {
        uint256 amountIn = 100e18;
        Route memory route = _route(amountIn);

        bytes memory nested = abi.encodeWithSelector(
            router.swapExactIn.selector, route, amountIn, uint256(1), user, block.timestamp + 1
        );
        evil.setAttack(address(router), nested);

        vm.prank(user);
        uint256 delivered = router.swapExactIn(route, amountIn, 1, user, block.timestamp + 1);

        assertGt(delivered, 0, "the outer, legitimate swap completes");
        assertTrue(evil.reentryAttempted(), "the output transfer fired the nested call");
        assertTrue(evil.reentryReverted(), "the nested call was refused");
        assertEq(
            evil.reentryReturndata(),
            abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, uint16(7)),
            "and it was the lock that refused it (RouterE(7)), not another guard"
        );
    }
}
