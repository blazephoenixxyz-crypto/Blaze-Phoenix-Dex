// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  A fee share is booked by two witnesses, never by the answer (4122; 3688, 3995)
//
//  Red at e01b503 (main). `Router._push` returned on a `true` and, on a refusal, booked
//  `amt - (b0 - b1)`: the share less what the Router's OWN balance said had left. A token that
//  pays the share, restates the Router's balance UP inside the same transfer (a rebase hook
//  fired by the transfer) and answers `false` hides the payment behind the restatement: the
//  delta is short, the paid part is booked to the slot and `claimFee` pays it a second time,
//  out of the payer's refund (whitelistsol, 4122). At k* = b0 / (b0 - amt) the delta is zero and
//  the whole paid share is booked again.
//
//  The Router's balance alone cannot decide. Two cells give the same (b0, b1) with opposite
//  truths: "answered true, moved half, no restatement" (half the share is still here) and
//  "answered true, moved all, restated up by less than k*" (nothing is still here). So no rule
//  over (answer, b0, b1) is right in both; the fix on fin2-router 3a871c5 (`if (ok && b1 > b0)
//  return;`) books (b0 - amt)(k - 1) in the second cell. The second witness is the payee: what
//  its balance rose by is what it was paid (I2, measure the delivered at the receiver).
//
//  The rule: gone = max(what the Router's balance lost, what the payee's balance gained); the
//  slot is owed `amt - gone`, nothing when gone >= amt. The answer is not read. The Router's
//  delta over-measures under a restatement down and under-measures under one up; the payee's
//  under-measures under fee-on-transfer and over-measures under a restatement up of a payee that
//  already held the token. The larger witness never exceeds what left for the payee in both
//  shapes at once, so a claim never pays a share twice; the fee stays collected in every cell
//  where the token did not take its own cut (3619, a restatement DOWN of the idle balance, is
//  the token's cut and keeps its own seal).
//
//  Oracles here are arithmetic (ceil(amountIn * 28 / 10000), 30/70) and the token's balances
//  and shares, never the Router's figures.
//  Vectors (what the token does on the push to slot 0's payee): answer in {true, false, an
//  oversized word, no data} x moved in {all, half, nothing} x restatement in {none, below k*, at
//  k*, 2x} x {uniform (every holder, stETH-like), the sender only}; fee-on-transfer; a
//  restatement DOWN as the control of the 3619 family. Dimensions: unit cells, the full matrix,
//  fuzz over the factor, the claim after a half payment. Ranges: the factor from 1 to 3x.
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";

/// A token that keeps balances as shares under one factor (`num/den`), so a restatement moves every
/// holder's display balance at once (the uniform shape), or, with `senderOnly`, only the sender's
/// shares. Per destination it chooses what it MOVES (0 all, 1 half, 2 nothing), what it ANSWERS
/// (0 true, 1 false, 2 a 64-byte word, 3 no data) and the restatement the transfer to that
/// destination fires, once, between the Router's balance reads. `fotBps` is the token's own cut.
contract WitnessToken {
    mapping(address => uint256) public sharesOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint8 public constant decimals = 18;
    uint256 public num = 1;
    uint256 public den = 1;
    uint16 public fotBps;
    address public fotTo;   // the cut applies to transfers INTO this address only (the push, not the pull)
    struct Shape { uint8 move; uint8 answer; uint256 rn; uint256 rd; bool senderOnly; }
    mapping(address => Shape) public shape;

    function setShape(address to, uint8 move, uint8 answer, uint256 rn, uint256 rd, bool senderOnly) external {
        shape[to] = Shape(move, answer, rn, rd, senderOnly);
    }
    function setFot(address to, uint16 b) external { fotTo = to; fotBps = b; }
    function mint(address to, uint256 amt) external { sharesOf[to] += amt * den / num; }
    function balanceOf(address a) public view returns (uint256) { return sharesOf[a] * num / den; }
    function approve(address s, uint256 a) external returns (bool) { allowance[msg.sender][s] = a; return true; }
    function transfer(address to, uint256 amt) external returns (bool) { return _t(msg.sender, to, amt); }
    function transferFrom(address f, address to, uint256 amt) external returns (bool) {
        if (f != msg.sender && allowance[f][msg.sender] != type(uint256).max) allowance[f][msg.sender] -= amt;
        return _t(f, to, amt);
    }
    function _t(address f, address to, uint256 amt) private returns (bool) {
        Shape memory s = shape[to];
        uint256 sh = amt * den / num;
        if (s.move == 1) sh /= 2;
        else if (s.move == 2) sh = 0;
        sharesOf[f] -= sh;
        sharesOf[to] += to == fotTo ? sh - sh * fotBps / 10_000 : sh;
        if (s.rn != 0) {
            if (s.senderOnly) sharesOf[f] = sharesOf[f] * s.rn / s.rd;
            else { num = s.rn; den = s.rd; }
            shape[to].rn = 0;
        }
        if (s.answer == 1) return false;
        if (s.answer == 2) assembly { mstore(0, 1) mstore(32, 1) return(0, 64) }
        if (s.answer == 3) assembly { return(0, 0) }
        return true;
    }
}

contract FeePushTwoWitnessesTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixRouter router;
    WitnessToken tok;
    MockERC20 other;
    MockV2Pair pair;
    address user = address(0xBEEF);
    address t1 = address(0x7001);
    address t2 = address(0x7002);
    uint256 constant R = 100_000e18;
    uint256 constant IN = 100e18;
    uint256 constant FEE = 0.28e18;        // ceil(IN * 28 / 10000), pinned in setUp
    uint256 constant SHARE0 = 0.084e18;    // FEE * 3000 / 10000, pinned in setUp
    // k* = IN / (IN - SHARE0): the restatement that puts the Router's balance back at b0 after
    // the share left, so the Router's delta reads zero while the whole share was paid.
    uint256 constant KS_N = 100_000;
    uint256 constant KS_D = 99_916;
    // the midpoint between 1 and k*: the Router's delta is short but not zero (the fin2 cell)
    uint256 constant KM_N = 199_916;
    uint256 constant KM_D = 199_832;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        BlazePhoenixSolver solver = new BlazePhoenixSolver(address(hub), address(0));
        router = new BlazePhoenixRouter(address(hub), address(solver), address(this), t1, t2);
        other = new MockERC20("O", "O");
        assertEq(BPC.mulDivUp(IN, BPC.PROTOCOL_FEE_BPS, BPC.BPS), FEE, "fee arithmetic");
        assertEq(FEE * 3_000 / BPC.BPS, SHARE0, "slot 0 share arithmetic");
        assertEq(IN * KS_D, (IN - SHARE0) * KS_N, "k* = IN / (IN - SHARE0)");
        _fresh();
    }

    /// A new token and pair for every cell: owed, the kept coordinate and the payees start at zero.
    function _fresh() internal {
        tok = new WitnessToken();
        (address lo, address hi) = address(tok) < address(other) ? (address(tok), address(other)) : (address(other), address(tok));
        pair = new MockV2Pair(lo, hi);
        tok.mint(address(pair), R); other.mint(address(pair), R);
        pair.setReserves(uint112(R), uint112(R));
        tok.mint(user, 10_000e18);
        vm.prank(user);
        tok.approve(address(router), type(uint256).max);
    }

    /// No external call in here: a route built after `vm.prank` would spend the prank on it.
    function _direct() internal view returns (Route memory) {
        uint256 out = BPC.outV2(IN * (BPC.BPS - 28) / BPC.BPS, R, R, 30);
        Leg[] memory legs = new Leg[](1);
        legs[0] = Leg({pool: address(pair), hooks: address(0), kind: BPC.KIND_V2, fee: 30, tickSpacing: 0,
            zeroForOne: address(tok) < address(other), stable: false, amountIn: IN, expectedOut: out, auxId: bytes32(0)});
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({tokenIn: address(tok), tokenOut: address(other), amountIn: IN, expectedOut: out, legs: legs});
        return Route({hops: hops, totalOut: out, singleOut: out, singleOutFloor: 0, expectedImpactBps: 0,
            confidenceWad: 0, estGas: 0, hasSurplus: true, isV4Bundle: false});
    }

    /// One swap by the payer; returns what it delivered and the shares the payer spent (zero when
    /// the payer ended with more: a sender-only restatement up mints shares to the Router and the
    /// holds-nothing sweep hands them to the payer).
    function _swap() internal returns (uint256 got, uint256 spent) {
        Route memory r = _direct();
        uint256 s0 = tok.sharesOf(user);
        vm.prank(user);
        got = router.swapExactIn(r, IN, 1, user, block.timestamp + 1);
        uint256 s1 = tok.sharesOf(user);
        spent = s0 > s1 ? s0 - s1 : 0;
    }

    /// One cell: a fresh token whose push to slot 0's payee behaves as told, one swap.
    function _cell(uint8 move, uint8 answer, uint256 rn, uint256 rd, bool senderOnly)
        internal returns (uint256 owed0, uint256 got, uint256 spent)
    {
        _fresh();
        tok.setShape(t1, move, answer, rn, rd, senderOnly);
        (got, spent) = _swap();
        owed0 = router.owed(address(tok), 0);
    }

    /// NEVER TWICE, in shares (the token's conserved unit): what the payee holds plus what a claim
    /// would pay it never exceeds the share it was pushed.
    function _neverTwice(uint256 owed0, string memory cell) internal view {
        assertLe(tok.sharesOf(t1) + owed0 * tok.den() / tok.num(), SHARE0, string.concat(cell, ": paid + owed, in shares, exceeds the share"));
    }

    /// COLLECTED, in display units at the token's current factor: what the payee holds plus what
    /// it is owed is at least the share less the token's own cut.
    function _collected(uint256 owed0, uint256 cut, string memory cell) internal view {
        assertGe(tok.balanceOf(t1) + owed0 + cut, SHARE0, string.concat(cell, ": paid + owed is short of the share"));
    }

    /// Owed is backed: the Router holds at least what the slots are owed.
    function _backed(string memory cell) internal view {
        assertGe(tok.balanceOf(address(router)), router.owed(address(tok), 0) + router.owed(address(tok), 1), string.concat(cell, ": owed is not backed"));
    }

    // ---------------------------------------------------------------- the red (4122)

    /// THE RED. The share is paid, the Router's balance is restated up to exactly b0 inside the
    /// transfer, the token answers false: at e01b503 the whole share is booked again (owed 0.084e18)
    /// and the payer spends it on top of the control's spend.
    function test_FalseAndRestatedUpAtKStar_WholeShareIsNotBookedAgain() public {
        (uint256 owedCtrl, uint256 gotCtrl, uint256 spentCtrl) = _cell(0, 0, KS_N, KS_D, false);
        assertEq(owedCtrl, 0, "control (true): nothing booked");
        (uint256 owed0, uint256 got, uint256 spent) = _cell(0, 1, KS_N, KS_D, false);
        assertEq(got, gotCtrl, "the output does not see the answer");
        assertEq(tok.sharesOf(t1), SHARE0, "the payee holds the whole share");
        assertEq(owed0, 0, "a paid share is not booked again");
        assertEq(spent, spentCtrl, "the payer spends what the control spends");
        _neverTwice(owed0, "false, all, k*");
        _collected(owed0, 0, "false, all, k*");
        _backed("false, all, k*");
    }

    /// The same at 2x, where the Router's delta is zero as well, and at the midpoint, where it
    /// is short but not zero: the paid part is never booked.
    function test_FalseAndRestatedUp_AtTwoXAndBelowKStar_NothingBooked() public {
        (uint256 owed0,,) = _cell(0, 1, 2, 1, false);
        assertEq(owed0, 0, "2x: a paid share is not booked");
        _neverTwice(owed0, "false, all, 2x");
        (owed0,,) = _cell(0, 1, KM_N, KM_D, false);
        assertEq(owed0, 0, "below k*: a paid share is not booked");
        _neverTwice(owed0, "false, all, mid");
    }

    /// The payment reaches a claim: half the share is paid, the Router restated up at k*, the token
    /// answers false. Half is owed, the claim pays it once, and the payee ends with at most the
    /// share, in shares.
    function test_ClaimAfterAHalfPaymentRestatedUp_PaysTheRestOnce() public {
        (uint256 owed0,,) = _cell(1, 1, KS_N, KS_D, false);
        uint256 paid = tok.balanceOf(t1);
        assertEq(owed0, SHARE0 - paid, "owed is the share less what the payee measurably got");
        _neverTwice(owed0, "false, half, k*");
        tok.setShape(t1, 0, 0, 0, 0, false); // the claim's transfer is an honest one
        vm.prank(t1);
        router.claimFee(address(tok));
        assertEq(router.owed(address(tok), 0), 0, "claimed");
        assertLe(tok.sharesOf(t1), SHARE0, "the payee never ends with more than its share");
        assertGe(tok.balanceOf(t1), SHARE0, "and holds the share in today's units");
    }

    // ---------------------------------------------------------------- the answer is not read

    /// Answered true, paid in full, the Router restated up by LESS than k*: the Router's delta is
    /// short, the payee's is whole. Nothing is booked. Green at e01b503 (a true returned); red on
    /// fin2-router 3a871c5, which books (b0 - amt)(k - 1) here.
    function test_TruePaidRestatedUpBelowKStar_IsNotBooked() public {
        (uint256 owed0,,) = _cell(0, 0, KM_N, KM_D, false);
        assertEq(owed0, 0, "a paid share answered true is not booked");
        _collected(owed0, 0, "true, all, mid");
    }

    /// Answered true, nothing moved (3688): the share stayed, so it is booked. Red at e01b503 for
    /// 3688's reason (the true returned and the share went back to the payer in the sweep).
    function test_TrueAndNothingMoved_IsBooked() public {
        (uint256 owed0,,) = _cell(2, 0, 0, 0, false);
        assertEq(owed0, SHARE0, "a share that stayed is booked whatever the answer");
        _collected(owed0, 0, "true, none, 1");
        _backed("true, none, 1");
    }

    /// Fee-on-transfer: the payee gets the share less the token's cut, the Router lost the whole
    /// share. The cut is the token's, not the slot's: nothing is booked.
    function test_FeeOnTransferShare_TheTokensCutIsNotBooked() public {
        _fresh();
        tok.setFot(t1, 500);
        tok.setShape(t1, 0, 0, 0, 0, false);
        _swap();
        uint256 owed0 = router.owed(address(tok), 0);
        assertEq(owed0, 0, "the token's own cut is not booked to the slot");
        assertEq(tok.balanceOf(t1), SHARE0 - SHARE0 * 500 / 10_000, "the payee got the share less the cut");
        _neverTwice(owed0, "fot");
    }

    /// The payee's prior holdings are not a payment: the payee witness is a DELTA. The payee holds
    /// more than the share before the push, nothing moves, the token answers true: the share is
    /// booked in full.
    function test_PayeesPriorBalance_IsNotAPayment() public {
        _fresh();
        tok.mint(t1, 10e18);
        tok.setShape(t1, 2, 0, 0, 0, false);
        _swap();
        uint256 owed0 = router.owed(address(tok), 0);
        assertEq(owed0, SHARE0, "a share that stayed is booked whatever the payee already held");
        assertEq(tok.sharesOf(t1), 10e18, "the payee got nothing");
        _backed("prior, none, 1");
    }

    /// Control of the 3619 family: the Router's balance restated DOWN at the push (sender-only: a
    /// uniform restatement down would also put the mock pair under its stored reserves). The
    /// Router's delta over-measures and nothing is booked, as at e01b503. The Router holds an idle
    /// balance first (baseIn, never swept) so the legs still find their input after the
    /// restatement shrank the pull.
    function test_RestatedDown_BooksNothingTwice() public {
        _fresh();
        tok.mint(address(router), 1e18);
        tok.setShape(t1, 0, 0, 999, 1000, true);
        _swap();
        uint256 owed0 = router.owed(address(tok), 0);
        assertEq(owed0, 0, "true, all, down: nothing booked");
        _neverTwice(owed0, "true, all, down");
        _fresh();
        tok.mint(address(router), 1e18);
        tok.setShape(t1, 0, 1, 999, 1000, true);
        _swap();
        owed0 = router.owed(address(tok), 0);
        assertEq(owed0, 0, "false, all, down: the whole share left, nothing booked");
        _neverTwice(owed0, "false, all, down");
    }

    // ---------------------------------------------------------------- the matrix

    /// Every answer x every movement x every factor x both restatement shapes: never twice (shares)
    /// and collected (display), the Router backing what it owes.
    function test_Matrix_EveryAnswerEveryMoveEveryFactor_NeverTwiceAndCollected() public {
        uint256[4] memory rn = [uint256(0), KM_N, KS_N, 2];
        uint256[4] memory rd = [uint256(0), KM_D, KS_D, 1];
        for (uint8 move; move < 3; ++move) {
            for (uint8 answer; answer < 4; ++answer) {
                for (uint256 f; f < 4; ++f) {
                    for (uint256 u; u < 2; ++u) {
                        string memory cell = string.concat("move ", vm.toString(move), " answer ", vm.toString(answer),
                            " factor ", vm.toString(f), u == 1 ? " sender-only" : " uniform");
                        (uint256 owed0, uint256 got,) = _cell(move, answer, rn[f], rd[f], u == 1);
                        assertGt(got, 0, string.concat(cell, ": the swap settled"));
                        _neverTwice(owed0, cell);
                        _collected(owed0, 0, cell);
                        _backed(cell);
                    }
                }
            }
        }
    }

    /// The factor swept from 1x to 3x, both shapes, every answer and movement.
    function testFuzz_RestatementUp_NeverTwiceAndCollected(uint32 kBps, uint8 move, uint8 answer, bool senderOnly) public {
        kBps = uint32(bound(kBps, 10_000, 30_000));
        move = uint8(bound(move, 0, 2));
        answer = uint8(bound(answer, 0, 3));
        (uint256 owed0, uint256 got,) = _cell(move, answer, kBps, 10_000, senderOnly);
        assertGt(got, 0, "settled");
        _neverTwice(owed0, "fuzz");
        _collected(owed0, 0, "fuzz");
        _backed("fuzz");
    }
}
