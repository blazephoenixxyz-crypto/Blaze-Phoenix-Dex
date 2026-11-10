// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  A fee share is booked by the delta, not by the answer (3688, 3995)
//
//  Red at af37bd6: `Router._push` returned as soon as the capped transfer ANSWERED true and
//  read the balance delta only on a refusal. A token that answers true and moves nothing (or
//  less than the share) left the share on the Router unbooked: `owed` stayed zero, `_bal` did
//  not subtract it, and the holds-nothing sweep paid it back to the swapper on an input-side
//  fee, or it stayed stranded and unclaimable on an output-side fee.
//
//  The property, for every answer a token can give: paid + owed == the share, per slot.
//  The oracle is arithmetic done here (ceil(amount * 28 / 10000), 30/70) and balances read
//  from the token, never the Router's own figures.
//
//  Vectors (what the token does on a push to a payee):
//    0 honest                      pays, answers true
//    1 answers true, moves nothing the report
//    2 answers true, moves half    the partial lie
//    3 answers false, moves all    the old branch: the delta already ruled there
//  Dimensions: fee on the input (no bridge), fee on the output (direct route into a bridge),
//  one swap and two swaps in one transaction, one slot and both slots. Range: fuzz.
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";

/// @dev An ERC-20 whose answer and whose movement are set apart, per destination.
contract AnswerVsDeltaToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => uint8) public shape;
    uint8 public constant decimals = 18;

    function setShape(address a, uint8 m) external { shape[a] = m; }
    function mint(address to, uint256 amt) external { balanceOf[to] += amt; }
    function approve(address s, uint256 a) external returns (bool) { allowance[msg.sender][s] = a; return true; }
    function transfer(address to, uint256 amt) external returns (bool) { return _t(msg.sender, to, amt); }
    function transferFrom(address f, address to, uint256 amt) external returns (bool) {
        if (f != msg.sender && allowance[f][msg.sender] != type(uint256).max) allowance[f][msg.sender] -= amt;
        return _t(f, to, amt);
    }
    function _t(address f, address to, uint256 amt) private returns (bool) {
        uint8 m = shape[to];
        if (m == 1) return true;
        if (m == 2) amt /= 2;
        balanceOf[f] -= amt; balanceOf[to] += amt;
        return m != 3;
    }
}

/// @dev One transaction for two swaps: the kept coordinate is transient.
contract DeltaBatch {
    function twoSwaps(BlazePhoenixRouter router, Route memory r, uint256 amt)
        external returns (uint256[2] memory spent)
    {
        AnswerVsDeltaToken t = AnswerVsDeltaToken(r.hops[0].tokenIn);
        t.approve(address(router), type(uint256).max);
        for (uint256 k; k < 2; ++k) {
            uint256 before = t.balanceOf(address(this));
            router.swapExactIn(r, amt, 1, address(this), block.timestamp + 1);
            spent[k] = before - t.balanceOf(address(this));
        }
    }
}

contract FeePushBookedByTheDeltaTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    BlazePhoenixRouter router;

    AnswerVsDeltaToken lying;   // tokenIn of the input-side swaps, tokenOut of the output-side ones
    MockERC20 honest;
    MockV2Pair pair;

    address user = address(0xBEEF);
    address treasury1 = address(0xFEE1);
    address treasury2 = address(0xFEE2);

    uint256 constant RESERVE = 1_000_000e18;
    uint256 constant IN = 100e18;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        solver = new BlazePhoenixSolver(address(hub), address(0));
        router = new BlazePhoenixRouter(address(hub), address(solver), address(this), treasury1, treasury2);
        hub.setRoles(address(router), address(solver), address(this));

        lying = new AnswerVsDeltaToken();
        honest = new MockERC20("Honest", "HON");
        pair = new MockV2Pair(address(lying), address(honest));
        lying.mint(address(pair), RESERVE);
        honest.mint(address(pair), RESERVE);
        pair.setReserves(uint112(RESERVE), uint112(RESERVE));

        lying.mint(user, 1e30);
        honest.mint(user, 1e30);
        vm.startPrank(user);
        lying.approve(address(router), type(uint256).max);
        honest.approve(address(router), type(uint256).max);
        vm.stopPrank();
    }

    // ---- the oracle: arithmetic done here ----------------------------------------------------

    function _fee(uint256 base) private pure returns (uint256) { return (base * 28 + 9_999) / 10_000; }
    function _share1(uint256 fee) private pure returns (uint256) { return fee * 3_000 / 10_000; }
    /// what a push of `amt` to a payee of shape `m` leaves undelivered
    function _undelivered(uint256 amt, uint8 m) private pure returns (uint256) {
        if (m == 1) return amt;
        if (m == 2) return amt - amt / 2;
        return 0;
    }

    function _route(address tIn, address tOut, uint256 amt) private view returns (Route memory r) {
        Leg[] memory legs = new Leg[](1);
        legs[0] = Leg({
            pool: address(pair), hooks: address(0), kind: BPC.KIND_V2, fee: 0,
            tickSpacing: 0, zeroForOne: pair.token0() == tIn, stable: false,
            amountIn: amt, expectedOut: 0, auxId: bytes32(0)
        });
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({tokenIn: tIn, tokenOut: tOut, amountIn: amt, expectedOut: 0, legs: legs});
        r = Route({
            hops: hops, totalOut: 0, singleOut: 0, singleOutFloor: 0,
            expectedImpactBps: 0, confidenceWad: 0, estGas: 0,
            hasSurplus: false, isV4Bundle: false
        });
    }

    /// One input-side swap of `amt` under the shapes (m1, m2); asserts paid + owed per slot,
    /// what the payer spent and what the Router is left holding.
    function _inputSide(uint256 amt, uint8 m1, uint8 m2) private {
        lying.setShape(treasury1, m1);
        lying.setShape(treasury2, m2);
        Route memory r = _route(address(lying), address(honest), amt);
        uint256 before = lying.balanceOf(user);
        vm.prank(user);
        router.swapExactIn(r, amt, 1, user, block.timestamp + 1);

        uint256 fee = _fee(amt);
        uint256 t1 = _share1(fee);
        uint256 t2 = fee - t1;
        uint256 u1 = _undelivered(t1, m1);
        uint256 u2 = _undelivered(t2, m2);
        assertEq(router.owed(address(lying), 0), u1, "slot 0: owed is what the push did not deliver");
        assertEq(router.owed(address(lying), 1), u2, "slot 1: owed is what the push did not deliver");
        assertEq(lying.balanceOf(treasury1) + router.owed(address(lying), 0), t1, "slot 0: paid + owed == share");
        assertEq(lying.balanceOf(treasury2) + router.owed(address(lying), 1), t2, "slot 1: paid + owed == share");
        assertEq(before - lying.balanceOf(user), amt, "the payer spent exactly amountIn");
        assertEq(lying.balanceOf(address(router)), u1 + u2, "the Router holds the owed shares and nothing else");
    }

    // ---- the report ---------------------------------------------------------------------------

    /// THE RED (3688, 3995): at af37bd6 owed was 0 and the payer spent 99.72e18.
    function test_AShareThatAnswersTrueWithoutMovingIsBooked() public {
        _inputSide(IN, 1, 1);
        assertEq(router.owed(address(lying), 0) + router.owed(address(lying), 1), 0.28e18, "the whole fee is owed");
    }

    function test_OnlyTheSlotThatDidNotMoveIsBooked_Slot0() public {
        _inputSide(IN, 1, 0);
        assertEq(lying.balanceOf(treasury2), 0.196e18, "slot 1 was paid");
    }

    function test_OnlyTheSlotThatDidNotMoveIsBooked_Slot1() public {
        _inputSide(IN, 0, 1);
        assertEq(lying.balanceOf(treasury1), 0.084e18, "slot 0 was paid");
    }

    function test_AShareThatAnswersTrueAndMovesHalfIsBookedForTheRest() public {
        _inputSide(IN, 2, 2);
        assertEq(router.owed(address(lying), 0), 0.042e18, "slot 0: the half that stayed");
        assertEq(router.owed(address(lying), 1), 0.098e18, "slot 1: the half that stayed");
    }

    /// Controls, green before the fix: the delta already ruled when the answer was false.
    function test_Control_HonestPushBooksNothing() public {
        _inputSide(IN, 0, 0);
        assertEq(lying.balanceOf(treasury1) + lying.balanceOf(treasury2), 0.28e18, "the fee left the Router");
    }

    function test_Control_AShareThatAnswersFalseAndMovesIsNotBooked() public {
        _inputSide(IN, 3, 3);
        assertEq(lying.balanceOf(treasury1) + lying.balanceOf(treasury2), 0.28e18, "the fee left the Router");
    }

    /// The booked share is the payee's: claimable once the token serves it, once.
    function test_TheBookedShareIsClaimedByItsSlot() public {
        _inputSide(IN, 1, 1);
        lying.setShape(treasury1, 0);
        lying.setShape(treasury2, 0);
        vm.prank(treasury1);
        router.claimFee(address(lying));
        assertEq(lying.balanceOf(treasury1), 0.084e18, "slot 0 claimed its share");
        vm.prank(treasury2);
        router.claimFee(address(lying));
        assertEq(lying.balanceOf(treasury2), 0.196e18, "slot 1 claimed its share");
        assertEq(lying.balanceOf(address(router)), 0, "nothing is left behind");
        vm.prank(treasury1);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, uint16(1)));
        router.claimFee(address(lying));
    }

    /// Two swaps, one transaction: the first swap's booked fee is never the second's refund.
    function test_TwoSwapsInOneTransaction_TheBookedShareIsNeverSwept() public {
        lying.setShape(treasury1, 1);
        lying.setShape(treasury2, 1);
        DeltaBatch b = new DeltaBatch();
        lying.mint(address(b), 1_000e18);
        uint256[2] memory spent = b.twoSwaps(router, _route(address(lying), address(honest), IN), IN);
        assertEq(spent[0], IN, "first swap: the payer spent exactly amountIn");
        assertEq(spent[1], IN, "second swap: the payer spent exactly amountIn");
        assertEq(router.owed(address(lying), 0) + router.owed(address(lying), 1), 0.56e18, "both fees are owed");
        assertEq(lying.balanceOf(address(router)), 0.56e18, "and held");
    }

    // ---- the output side ----------------------------------------------------------------------

    /// A direct route into a bridge pays the fee on the output. At af37bd6 the share that did
    /// not move stayed on the Router with owed == 0: no slot could claim it.
    function _outputSide(uint256 amt, uint8 m1, uint8 m2) private {
        hub.addBridge(address(lying));
        lying.setShape(treasury1, m1);
        lying.setShape(treasury2, m2);
        Route memory r = _route(address(honest), address(lying), amt);
        uint256 before = lying.balanceOf(user);
        vm.prank(user);
        router.swapExactIn(r, amt, 1, user, block.timestamp + 1);

        uint256 delivered = lying.balanceOf(user) - before;
        uint256 paid = lying.balanceOf(treasury1) + lying.balanceOf(treasury2);
        uint256 held = lying.balanceOf(address(router));
        uint256 fee = _fee(delivered + paid + held);   // the gross output, measured at the three holders
        uint256 t1 = _share1(fee);
        uint256 t2 = fee - t1;
        assertEq(paid + held, fee, "the output fee is the 28 bps of the gross, rounded up");
        assertEq(router.owed(address(lying), 0), _undelivered(t1, m1), "slot 0: owed is what did not move");
        assertEq(router.owed(address(lying), 1), _undelivered(t2, m2), "slot 1: owed is what did not move");
        assertEq(held, router.owed(address(lying), 0) + router.owed(address(lying), 1), "the Router holds only what it owes");
        assertEq(honest.balanceOf(address(router)), 0, "no input left behind");
    }

    function test_OutputSide_AShareThatAnswersTrueWithoutMovingIsBooked() public {
        _outputSide(IN, 1, 1);
        assertGt(router.owed(address(lying), 0), 0, "slot 0 is owed");
        assertGt(router.owed(address(lying), 1), 0, "slot 1 is owed");
    }

    function test_OutputSide_AShareThatMovesHalfIsBookedForTheRest() public {
        _outputSide(IN, 2, 2);
    }

    function test_OutputSide_Control_HonestPushBooksNothing() public {
        _outputSide(IN, 0, 0);
        assertEq(lying.balanceOf(address(router)), 0, "nothing held");
    }

    // ---- ranges x vectors ---------------------------------------------------------------------

    function testFuzz_InputSide_PaidPlusOwedIsTheShare(uint256 amt, uint8 m1, uint8 m2) public {
        _inputSide(bound(amt, 1e6, 1e22), uint8(bound(m1, 0, 3)), uint8(bound(m2, 0, 3)));
    }

    function testFuzz_OutputSide_PaidPlusOwedIsTheShare(uint256 amt, uint8 m1, uint8 m2) public {
        _outputSide(bound(amt, 1e6, 1e22), uint8(bound(m1, 0, 3)), uint8(bound(m2, 0, 3)));
    }
}
