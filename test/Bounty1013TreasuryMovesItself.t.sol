// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// Bounty #55 (mastermindran, 2026-10-11): a treasury blacklisted by a token issuer
// after renounceControl() made every swap that pays the fee in that token revert, and
// nobody could move the treasury any more. Each treasury now moves its own slot
// (moveTreasury), renounced or not. Red on 982c1de: the function does not exist.

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "../test/mocks/MockERC20.sol";
import {MockV2Pair} from "../test/mocks/MockV2Pair.sol";

/// USDC-style issuer blacklist: a transfer to or from a listed address reverts.
contract B1013BlacklistERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => bool) public blacklisted;
    uint8 public constant decimals = 18;
    function setBlacklisted(address a, bool b) external { blacklisted[a] = b; }
    function mint(address to, uint256 amt) external { balanceOf[to] += amt; }
    function approve(address s, uint256 a) external returns (bool) { allowance[msg.sender][s] = a; return true; }
    function transfer(address to, uint256 amt) external returns (bool) { _t(msg.sender, to, amt); return true; }
    function transferFrom(address f, address to, uint256 amt) external returns (bool) {
        if (f != msg.sender && allowance[f][msg.sender] != type(uint256).max) allowance[f][msg.sender] -= amt;
        _t(f, to, amt); return true;
    }
    function _t(address f, address to, uint256 amt) private {
        require(!blacklisted[f] && !blacklisted[to], "Blacklistable: account is blacklisted");
        balanceOf[f] -= amt; balanceOf[to] += amt;
    }
}

contract Bounty1013TreasuryMovesItselfTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixRouter router;
    B1013BlacklistERC20 usdc;
    MockERC20 tokenB;
    MockV2Pair pair;
    address user = address(0xBEEF);
    address t1 = address(0x7001);
    address t2 = address(0x7002);

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        BlazePhoenixSolver solver = new BlazePhoenixSolver(address(hub));
        router = new BlazePhoenixRouter(address(hub), address(solver), address(this), t1, t2);
        usdc = new B1013BlacklistERC20();
        tokenB = new MockERC20("B", "B");
        pair = new MockV2Pair(address(usdc), address(tokenB));
        usdc.mint(address(pair), 100_000e18);
        tokenB.mint(address(pair), 100_000e18);
        pair.setReserves(100_000e18, 100_000e18);
        usdc.mint(user, 10_000e18);
        vm.prank(user);
        usdc.approve(address(router), type(uint256).max);
    }

    function _route(uint256 amountIn) internal view returns (Route memory route) {
        bool zfo = address(usdc) < address(tokenB);
        uint256 out = BPC.outV2(amountIn * (BPC.BPS - 28) / BPC.BPS, 100_000e18, 100_000e18, 30);
        Leg[] memory legs = new Leg[](1);
        legs[0] = Leg({pool: address(pair), hooks: address(0), kind: BPC.KIND_V2, fee: 30, tickSpacing: 0,
            zeroForOne: zfo, stable: false, amountIn: amountIn, expectedOut: out, auxId: bytes32(0)});
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({tokenIn: address(usdc), tokenOut: address(tokenB), amountIn: amountIn, expectedOut: out, legs: legs});
        route = Route({hops: hops, totalOut: out, singleOut: out, singleOutFloor: 0, expectedImpactBps: 0,
            confidenceWad: 0, estGas: 0, hasSurplus: true, isV4Bundle: false});
    }

    function test_Control_SwapPaysTreasuries() public {
        vm.prank(user);
        uint256 got = router.swapExactIn(_route(1_000e18), 1_000e18, 1, user, block.timestamp + 1);
        assertGt(got, 0);
        assertGt(usdc.balanceOf(t1), 0, "treasury1 paid in the input token");
        emit log_named_uint("treasury1 fee", usdc.balanceOf(t1));
        emit log_named_uint("treasury2 fee", usdc.balanceOf(t2));
    }

    function test_BlacklistedTreasuryAfterRenounce_MovesItselfAndSwapsResume() public {
        router.renounceControl();
        usdc.setBlacklisted(t1, true);
        vm.prank(user);
        vm.expectRevert();
        router.swapExactIn(_route(1_000e18), 1_000e18, 1, user, block.timestamp + 1);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, uint16(1)));
        router.setTreasuries(address(0x7003), t2);
        vm.prank(t1);
        router.moveTreasury(address(0x7003));
        assertEq(router.treasury1(), address(0x7003), "treasury1 moved by its holder");
        assertEq(router.treasury2(), t2, "treasury2 untouched");
        vm.prank(user);
        assertGt(router.swapExactIn(_route(1_000e18), 1_000e18, 1, user, block.timestamp + 1), 0, "swaps resume");
        assertGt(usdc.balanceOf(address(0x7003)), 0, "the fee reaches the new slot");
    }

    function test_OnlyAHolderMovesASlot() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, uint16(1)));
        router.moveTreasury(user);
        vm.prank(t2);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, uint16(3)));
        router.moveTreasury(address(0));
        vm.prank(t2);
        router.moveTreasury(address(0x7004));
        assertEq(router.treasury1(), t1, "t2 cannot move t1");
        assertEq(router.treasury2(), address(0x7004));
    }
}
