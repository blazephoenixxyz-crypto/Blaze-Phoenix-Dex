// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  A token whose `balanceOf` lies by a constant to the Router moves no value.
//
//  The Router derives every amount from `balanceOf` - the pull, the residual
//  sweep, the payout - and each one is a DELTA against a baseline read from the
//  same token in the same call. A constant lie therefore cancels:
//    · the pull:  `received` is after - before;
//    · the sweep: `baseIn = tinStart - amountIn` already contains the lie, so
//      `residIn > baseIn` reduces to "real residue > 0" and nothing phantom is
//      swept;
//    · the payout: measured at the recipient.
//  A lie that CHANGES between two reads is the rebase class, witnessed in
//  `test/PathologicalTokens.t.sol`. Here the lying run must deliver the honest
//  figure to the wei, pull exactly amountIn, and leave the Router's real ledger
//  empty.
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";

/// @dev ERC-20 whose `balanceOf` adds a display-only extra for ONE chosen
///      address, without touching real balances. Transfers are real and checked.
contract BalanceLiarToken {
    string public name = "Liar";
    string public symbol = "LIAR";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;

    mapping(address => uint256) internal real;
    mapping(address => mapping(address => uint256)) public allowance;

    address public liarTarget;
    uint256 public liarExtra;

    function setLie(address target, uint256 extra) external {
        liarTarget = target;
        liarExtra = extra;
    }

    function mint(address to, uint256 amt) external { totalSupply += amt; real[to] += amt; }

    function balanceOf(address who) public view returns (uint256) {
        return who == liarTarget && liarTarget != address(0) ? real[who] + liarExtra : real[who];
    }

    function realBalanceOf(address who) external view returns (uint256) { return real[who]; }

    function approve(address spender, uint256 amt) external returns (bool) {
        allowance[msg.sender][spender] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) { return _move(msg.sender, to, amt); }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        if (from != msg.sender) {
            uint256 a = allowance[from][msg.sender];
            if (a != type(uint256).max) allowance[from][msg.sender] = a - amt;
        }
        return _move(from, to, amt);
    }

    function _move(address from, address to, uint256 amt) private returns (bool) {
        real[from] -= amt; // checked: a phantom sweep underflows here
        real[to] += amt;
        return true;
    }
}

contract ConstantBalanceLieCancelsOutTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    BlazePhoenixRouter router;

    BalanceLiarToken tokenIn;
    MockERC20 tokenOut;
    MockV2Pair pair;

    address user = address(0xBEEF);
    uint256 constant RESERVE = 1_000_000e18;
    uint256 constant IN = 100e18;

    /// @dev The control's delivery, to the wei. The lying run asserts the SAME
    ///      number, so a lie that moved value would break an equality instead of
    ///      sliding under an inequality.
    uint256 constant HONEST_OUT = 99410956479201634330;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        solver = new BlazePhoenixSolver(address(hub));
        router = new BlazePhoenixRouter(
            address(hub), address(solver), address(this), address(0xFEE1), address(0xFEE2));
        hub.setRoles(address(router), address(solver), address(this));

        tokenIn = new BalanceLiarToken();
        tokenOut = new MockERC20("Out", "OUT");
        pair = new MockV2Pair(address(tokenIn), address(tokenOut));

        tokenIn.mint(address(pair), RESERVE);
        tokenOut.mint(address(pair), RESERVE);
        pair.setReserves(uint112(RESERVE), uint112(RESERVE));
        hub.seedPool(address(pair), BPC.KIND_V2, 0, address(0), address(tokenIn), address(tokenOut));

        tokenIn.mint(user, 1_000e18);
        vm.prank(user);
        tokenIn.approve(address(router), type(uint256).max);
    }

    function _route() private view returns (Route memory r) {
        Leg[] memory legs = new Leg[](1);
        legs[0] = Leg({
            pool: address(pair), hooks: address(0), kind: BPC.KIND_V2, fee: 0,
            tickSpacing: 0, zeroForOne: pair.token0() == address(tokenIn), stable: false,
            amountIn: IN, expectedOut: 0, auxId: bytes32(0)
        });
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({
            tokenIn: address(tokenIn), tokenOut: address(tokenOut),
            amountIn: IN, expectedOut: 0, legs: legs
        });
        r = Route({
            hops: hops, totalOut: 0, singleOut: 0, singleOutFloor: 0,
            expectedImpactBps: 0, confidenceWad: 0, estGas: 0,
            hasSurplus: false, isV4Bundle: false
        });
    }

    function _swap() private returns (bool ok, bytes memory data) {
        Route memory r = _route();
        uint256 deadline = block.timestamp + 1;
        vm.prank(user);
        return address(router).call(
            abi.encodeCall(BlazePhoenixRouter.swapExactIn, (r, IN, 1, user, deadline))
        );
    }

    /// @notice Control: the same route with no lie delivers and holds nothing.
    function test_Control_NoLie_DeliversAndHoldsNothing() public {
        uint256 realBefore = tokenIn.realBalanceOf(user);

        (bool ok, bytes memory data) = _swap();
        assertTrue(ok, "control: a token that does not lie settles");

        uint256 delivered = abi.decode(data, (uint256));
        assertEq(delivered, HONEST_OUT, "control: the honest delivery, to the wei");
        assertEq(tokenOut.balanceOf(user), delivered, "control: recipient got the output");
        assertEq(realBefore - tokenIn.realBalanceOf(user), IN, "control: the pull is exactly amountIn");
        assertEq(tokenIn.realBalanceOf(address(router)), 0, "control: router holds no tokenIn");
    }

    /// @notice A constant lie to the Router cancels out of every delta it
    ///         measures: the swap settles at the honest figure and nothing
    ///         phantom is ever transferred.
    function test_ConstantBalanceLie_CancelsOut_NeverMovesValue() public {
        tokenIn.setLie(address(router), IN);
        uint256 userRealBefore = tokenIn.realBalanceOf(user);

        (bool ok, bytes memory data) = _swap();

        assertTrue(ok, "a constant lie must not brick the swap: the deltas cancel it");
        uint256 delivered = abi.decode(data, (uint256));
        assertEq(delivered, HONEST_OUT, "a lying balanceOf must not move the delivery by one wei");
        assertEq(userRealBefore - tokenIn.realBalanceOf(user), IN, "the real pull is exactly amountIn");
        assertEq(tokenIn.realBalanceOf(address(router)), 0, "router holds nothing real");
        assertEq(tokenOut.balanceOf(user), delivered, "recipient got exactly the delivered amount");
    }
}
