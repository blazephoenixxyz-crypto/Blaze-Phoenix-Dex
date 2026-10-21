// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  FEE DoS (seal 2026-10-21). `_payFee` pushed each treasury share with a transfer
//  that had to succeed, so any refusal of the payee - an issuer blacklist, a token
//  that returns false or eats the gas, or a slot holder moving its slot (moveTreasury)
//  to an address the token refuses - reverted EVERY swap paying the fee in that token.
//
//  Fix, on the custody-delta line: the share is pushed with capped gas; a refused push
//  is booked to the slot (`owed`) and pulled later by the slot's current holder
//  (`claimFee`). The booked share stays in the Router, so it must never be seen by a
//  swap as its own balance: every swap-path self-balance read subtracts it (`_bal`).
//
//  Properties pinned here:
//    1. a refused payee never reverts the swap (revert, false, gas burnt);
//    2. the fee is charged in full either way: paid + owed == fee, and the treasuries
//       never receive more than the fees charged;
//    3. owed fees never enter a sweep, a residual, a hop's input or the output - in the
//       same swap, in a second swap of the same transaction, and on every fee site
//       (hop 0, a later bridge hop, the output);
//    4. the rescue returns the stray balance and leaves the owed fees;
//    5. only a slot's current holder claims, once, and never inside a swap.
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";

/// A token whose payee may refuse: 1 = revert (issuer blacklist), 2 = return false, 3 = burn
/// all the gas it is given, 5 = a return word Core does not read as success (64 bytes). And one
/// payee that does NOT refuse: 4 = pays and returns no data (the USDT shape). Shapes confirmed
/// at the source 2026-10-21: Circle FiatTokenV1 `transfer` is `whenNotPaused
/// notBlacklisted(msg.sender) notBlacklisted(to) returns (bool)`, the modifier reverting
/// "Blacklistable: account is blacklisted" (stablecoin-evm fc85788); Ethereum USDT's verified
/// ABI declares `transfer` with no outputs. Optionally, the first transfer OUT of `hookRouter` calls
/// `claimFee` on it (a treasury that is itself the token, reaching in mid-swap).
contract SealFeeToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => uint8) public refuse;
    uint8 public constant decimals = 18;
    address public hookRouter;
    bool public hookFired;
    bool public hookOk;
    bytes public hookErr;
    function setRefuse(address a, uint8 m) external { refuse[a] = m; }
    function setHook(address r) external { hookRouter = r; }
    function mint(address to, uint256 amt) external { balanceOf[to] += amt; }
    function approve(address s, uint256 a) external returns (bool) { allowance[msg.sender][s] = a; return true; }
    function transfer(address to, uint256 amt) external returns (bool) { return _t(msg.sender, to, amt); }
    function transferFrom(address f, address to, uint256 amt) external returns (bool) {
        if (f != msg.sender && allowance[f][msg.sender] != type(uint256).max) allowance[f][msg.sender] -= amt;
        return _t(f, to, amt);
    }
    function _t(address f, address to, uint256 amt) private returns (bool) {
        uint8 m = refuse[to];
        if (m == 1) revert("Blacklistable: account is blacklisted");
        if (m == 2) return false;
        if (m == 3) { uint256 x; while (gasleft() > 0) { unchecked { ++x; } } }
        balanceOf[f] -= amt; balanceOf[to] += amt;
        if (m == 4) assembly { return(0, 0) }
        if (m == 5) assembly { mstore(0, 1) mstore(32, 1) return(0, 64) }
        if (hookRouter != address(0) && f == hookRouter && !hookFired) {
            hookFired = true;
            (hookOk, hookErr) = hookRouter.call(abi.encodeWithSignature("claimFee(address)", address(this)));
        }
        return true;
    }
}

/// ONE TRANSACTION, FOR REAL. This Foundry resets transient storage between the top-level calls
/// of a test (probed 2026-10-21: tstore in one call, tload in the next reads 0), so two swaps
/// called from the test body are two transactions and the kept coordinate is born at zero in
/// each. Everything that must share a transaction runs inside one call of this contract, which
/// is the payer (and, when moved there, a treasury slot holder). `spent[k]` is what swap k cost
/// it. `claimFee` by selector, like the test's helpers, so the file compiles before the fix.
contract SealBatch {
    function twoSwaps(BlazePhoenixRouter r, SealFeeToken t, Route calldata route, uint256 amt)
        external returns (uint256[2] memory spent)
    {
        t.approve(address(r), type(uint256).max);
        for (uint256 k; k < 2; ++k) {
            uint256 b0 = t.balanceOf(address(this));
            r.swapExactIn(route, amt, 1, address(this), block.timestamp + 1);
            spent[k] = b0 - t.balanceOf(address(this));
        }
    }

    /// Swap (this slot holder refuses its share, so it is booked), claim it, swap again. The
    /// first swap pulls exactly legs + fee (`amt0`): its holder refuses tok, so no residual may
    /// come back to it. The second (`amt1`) leaves a residual for the sweep under test.
    function swapClaimSwap(BlazePhoenixRouter r, SealFeeToken t, Route calldata route, uint256 amt0, uint256 amt1)
        external returns (uint256[2] memory spent, uint256 claimed)
    {
        t.approve(address(r), type(uint256).max);
        uint256 b0 = t.balanceOf(address(this));
        r.swapExactIn(route, amt0, 1, address(this), block.timestamp + 1);
        spent[0] = b0 - t.balanceOf(address(this));
        t.setRefuse(address(this), 0);
        b0 = t.balanceOf(address(this));
        (bool ok, ) = address(r).call(abi.encodeWithSignature("claimFee(address)", address(t)));
        require(ok, "claim");
        claimed = t.balanceOf(address(this)) - b0;
        b0 = t.balanceOf(address(this));
        r.swapExactIn(route, amt1, 1, address(this), block.timestamp + 1);
        spent[1] = b0 - t.balanceOf(address(this));
    }
}

contract Seal1021FeeNeverBlocksTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixRouter router;
    SealFeeToken tok;       // the fee token
    MockERC20 other;        // the far side
    MockERC20 head;         // a non-bridge token in front of `tok` for the bridge-hop routes
    MockV2Pair pair;        // tok / other
    MockV2Pair pairH;       // head / tok
    address user = address(0xBEEF);
    address t1 = address(0x7001);
    address t2 = address(0x7002);
    address bad = address(0xBAD);
    uint256 constant R = 100_000e18;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        BlazePhoenixSolver solver = new BlazePhoenixSolver(address(hub));
        router = new BlazePhoenixRouter(address(hub), address(solver), address(this), t1, t2);
        tok = new SealFeeToken();
        other = new MockERC20("O", "O");
        head = new MockERC20("H", "H");
        pair = _pair(address(tok), address(other));
        pairH = _pair(address(head), address(tok));
        tok.mint(user, 10_000e18); head.mint(user, 10_000e18);
        vm.startPrank(user);
        tok.approve(address(router), type(uint256).max);
        head.approve(address(router), type(uint256).max);
        vm.stopPrank();
    }

    function _pair(address a, address b) internal returns (MockV2Pair p) {
        (address lo, address hi) = a < b ? (a, b) : (b, a);
        p = new MockV2Pair(lo, hi);
        SealFeeToken(a).mint(address(p), R); SealFeeToken(b).mint(address(p), R);
        p.setReserves(uint112(R), uint112(R));
    }

    /// No external call in here: a route built after `vm.prank` would spend the prank on it
    /// (the payer silently becomes this contract). The orientation is derived from the ends.
    function _leg(MockV2Pair p, address tIn, address tOut, uint256 amt) internal pure returns (Leg memory) {
        uint256 out = BPC.outV2(amt * (BPC.BPS - 28) / BPC.BPS, R, R, 30);
        return Leg({pool: address(p), hooks: address(0), kind: BPC.KIND_V2, fee: 30, tickSpacing: 0,
            zeroForOne: tIn < tOut, stable: false, amountIn: amt, expectedOut: out, auxId: bytes32(0)});
    }

    function _hop(MockV2Pair p, address tIn, address tOut, uint256 amt) internal pure returns (Hop memory h) {
        Leg[] memory legs = new Leg[](1);
        legs[0] = _leg(p, tIn, tOut, amt);
        h = Hop({tokenIn: tIn, tokenOut: tOut, amountIn: amt, expectedOut: legs[0].expectedOut, legs: legs});
    }

    function _wrap(Hop[] memory hops) internal pure returns (Route memory) {
        uint256 out = hops[hops.length - 1].expectedOut;
        return Route({hops: hops, totalOut: out, singleOut: out, singleOutFloor: 0, expectedImpactBps: 0,
            confidenceWad: 0, estGas: 0, hasSurplus: true, isV4Bundle: false});
    }

    /// tok -> other, fee on hop 0's input; `legAmt` < amountIn leaves a residual to sweep.
    function _direct(uint256 legAmt) internal view returns (Route memory) {
        Hop[] memory hops = new Hop[](1);
        hops[0] = _hop(pair, address(tok), address(other), legAmt);
        return _wrap(hops);
    }

    /// `owed` and `claimFee` are reached by selector so this file compiles on the tree before
    /// the fix too, where every test is run for its red (the swap reverts before any of them).
    function _owed(uint256 i) internal view returns (uint256 v) {
        (bool ok, bytes memory r) = address(router).staticcall(abi.encodeWithSignature("owed(address,uint256)", address(tok), i));
        if (ok && r.length == 32) v = abi.decode(r, (uint256));
    }

    function _claim(address who) internal returns (bool ok, bytes memory err) {
        vm.prank(who);
        (ok, err) = address(router).call(abi.encodeWithSignature("claimFee(address)", address(tok)));
    }

    function _e(uint16 c) internal pure returns (bytes memory) { return abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, c); }

    function _fee(uint256 base) internal pure returns (uint256) { return BPC.mulDivUp(base, 28, BPC.BPS); }
    function _owedAll() internal view returns (uint256) { return _owed(0) + _owed(1); }

    /// THE RED. treasury1's holder moves its slot to an address the token refuses: on the tree
    /// before the fix every tok-fee swap reverts ("Blacklistable: account is blacklisted").
    function test_SlotMovedToARefusedPayee_SwapStillSettles() public {
        tok.setRefuse(bad, 1);
        vm.prank(t1);
        router.moveTreasury(bad);
        uint256 amt = 1_000e18;
        vm.prank(user);
        uint256 got = router.swapExactIn(_direct(amt), amt, 1, user, block.timestamp + 1);
        assertGt(got, 0, "the swap settled");
        uint256 fee = _fee(amt);
        uint256 s1 = fee * 3_000 / BPC.BPS;
        assertEq(_owed(0), s1, "treasury1's share is booked to its slot");
        assertEq(tok.balanceOf(t2), fee - s1, "treasury2 is still paid in the swap");
        assertEq(tok.balanceOf(address(router)), s1, "the Router holds exactly what it owes");
    }

    /// Every refusal shape, the gas burner under a realistic gas limit: the push costs the
    /// swap at most FEE_GAS, never the swap.
    function test_EveryRefusalShape_DoesNotBlock() public {
        uint8[4] memory shapes = [uint8(1), 2, 3, 5];
        uint256 share = _fee(100e18) * 3_000 / BPC.BPS;
        for (uint256 j; j < 4; ++j) {
            tok.setRefuse(t1, shapes[j]);
            uint256 o0 = _owed(0); uint256 p0 = tok.balanceOf(t1);
            vm.prank(user);
            uint256 got = router.swapExactIn{gas: 3_000_000}(_direct(100e18), 100e18, 1, user, block.timestamp + 1);
            assertGt(got, 0, "a refused push never reverts the swap");
            uint256 booked = _owed(0) - o0; uint256 paid = tok.balanceOf(t1) - p0;
            assertEq(booked + paid, share, "paid + owed is the share, exactly");
            // Shape 5 moves the share and then answers in a shape Core reads as a refusal:
            // the share is paid, so nothing may be booked (a claim would pay it twice).
            if (shapes[j] == 5) assertEq(paid, share, "the moved share is not booked again");
            else assertEq(booked, share, "the refused share is booked");
        }
        assertEq(tok.balanceOf(address(router)), _owedAll(), "owed is backed, unit for unit");
    }

    /// The no-return shape (USDT) is a payment, not a refusal: the share reaches treasury1 in the
    /// swap and nothing is booked.
    function test_NoReturnPayee_IsPaidNotBooked() public {
        tok.setRefuse(t1, 4);
        vm.prank(user);
        router.swapExactIn(_direct(1_000e18), 1_000e18, 1, user, block.timestamp + 1);
        assertEq(tok.balanceOf(t1), _fee(1_000e18) * 3_000 / BPC.BPS, "paid in the swap");
        assertEq(_owedAll(), 0, "nothing booked");
        assertEq(tok.balanceOf(address(router)), 0, "nothing held");
    }

    /// Property 3 at hop 0, twice in ONE transaction, each swap leaving a residual for the
    /// input sweep: the payer gets back exactly its unspent input, never the booked fee.
    function test_OwedNeverReachesTheInputSweep_TwoSwapsOneTransaction() public {
        tok.setRefuse(t1, 1);
        tok.setRefuse(t2, 1);
        uint256 amt = 1_000e18; uint256 legAmt = 600e18;
        SealBatch b = new SealBatch();
        tok.mint(address(b), 10_000e18);
        uint256[2] memory spent = b.twoSwaps(router, tok, _direct(legAmt), amt);
        for (uint256 k; k < 2; ++k) {
            assertEq(spent[k], legAmt + _fee(legAmt), "the payer spent the legs and the fee, no more, no less");
        }
        assertEq(_owedAll(), 2 * _fee(legAmt), "both fees booked in full");
        assertEq(tok.balanceOf(address(router)), _owedAll(), "nothing owed was swept");
    }

    /// Property 3 on a later hop: head -> tok (bridge) -> other, fee on hop 1's input. The
    /// booked fee must not be spent by hop 1's legs nor returned by the bridge sweep.
    function test_OwedOnABridgeHop_IsNeitherSpentNorSwept() public {
        hub.addBridge(address(tok));
        tok.setRefuse(t1, 1);
        tok.setRefuse(t2, 2);
        uint256 amt = 1_000e18;
        Hop[] memory hops = new Hop[](2);
        hops[0] = _hop(pairH, address(head), address(tok), amt);
        hops[1] = _hop(pair, address(tok), address(other), hops[0].expectedOut);
        uint256 o0 = other.balanceOf(user);
        vm.prank(user);
        uint256 got = router.swapExactIn(_wrap(hops), amt, 1, user, block.timestamp + 1);
        assertGt(got, 0, "settled");
        assertEq(other.balanceOf(user) - o0, got, "delivered what it reports");
        assertGt(_owedAll(), 0, "the bridge fee is booked");
        assertEq(tok.balanceOf(address(router)), _owedAll(), "hop 1 spent and swept only this swap's bridge coin");
    }

    /// Property 3 on the output: other -> tok (bridge), fee out of tokenOut after the floor.
    function test_OwedOnTheOutput_IsNotDelivered() public {
        hub.addBridge(address(tok));
        tok.setRefuse(t1, 1);
        tok.setRefuse(t2, 1);
        other.mint(user, 1_000e18);
        vm.prank(user); other.approve(address(router), type(uint256).max);
        Hop[] memory hops = new Hop[](1);
        hops[0] = _hop(pair, address(other), address(tok), 1_000e18);
        uint256 b0 = tok.balanceOf(user);
        vm.prank(user);
        uint256 got = router.swapExactIn(_wrap(hops), 1_000e18, 1, user, block.timestamp + 1);
        assertEq(tok.balanceOf(user) - b0, got, "delivered the net");
        assertGt(_owedAll(), 0, "the output fee is booked");
        assertEq(tok.balanceOf(address(router)), _owedAll(), "the booked fee stayed, nothing else did");
    }

    /// Properties 2 and 5: the slot's CURRENT holder claims what the slot is owed, once; the
    /// treasuries end with exactly the fees charged.
    function test_ClaimFee_CurrentHolderOnce_TreasuriesGetExactlyTheFees() public {
        tok.setRefuse(bad, 1);
        vm.prank(t1); router.moveTreasury(bad);
        uint256 amt = 1_000e18;
        vm.prank(user);
        router.swapExactIn(_direct(amt), amt, 1, user, block.timestamp + 1);
        address good = address(0x7003);
        vm.prank(bad); router.moveTreasury(good);
        (bool ok, bytes memory err) = _claim(user);
        assertTrue(!ok && keccak256(err) == keccak256(_e(1)), "a stranger claimed");
        (ok, ) = _claim(bad);
        assertFalse(ok, "the slot's former holder claimed");
        (ok, ) = _claim(good);
        assertTrue(ok, "the slot's current holder could not claim");
        assertEq(_owed(0), 0, "claimed");
        (ok, err) = _claim(good);
        assertTrue(!ok && keccak256(err) == keccak256(_e(1)), "claimed twice");
        assertEq(tok.balanceOf(good) + tok.balanceOf(t2), _fee(amt), "the treasuries got the fee, exactly");
        assertEq(tok.balanceOf(address(router)), 0, "and the Router holds nothing");
    }

    /// Property 3 across a claim: swap (a share booked), claim, swap again - all in ONE
    /// transaction. What the claim paid out is no longer kept, so the second swap's input
    /// sweep returns the payer's whole residual and the Router ends holding nothing.
    function test_ClaimBetweenTwoSwapsOfOneTransaction_KeepsTheCoordinate() public {
        uint256 amt = 1_000e18; uint256 legAmt = 600e18;
        uint256 share0 = _fee(legAmt) * 3_000 / BPC.BPS;
        SealBatch b = new SealBatch();
        tok.mint(address(b), 10_000e18);
        vm.prank(t1); router.moveTreasury(address(b));
        tok.setRefuse(address(b), 1);
        (uint256[2] memory spent, uint256 claimed) = b.swapClaimSwap(router, tok, _direct(legAmt), legAmt + _fee(legAmt), amt);
        assertEq(claimed, share0, "setup: the first swap booked slot 0's share and its holder claimed it");
        assertEq(spent[0], legAmt + _fee(legAmt), "the first swap cost the legs and the fee");
        // The holder is now paid its slot-0 share in the swap, so the swap nets the fee less it.
        assertEq(spent[1], legAmt + _fee(legAmt) - share0,
            "the second swap of the same transaction returned its whole residual");
        assertEq(tok.balanceOf(address(router)), 0, "nothing stranded");
    }

    /// Property 4: the rescue returns a stray balance and leaves the owed fees claimable.
    function test_Rescue_LeavesTheOwedFees() public {
        tok.setRefuse(t1, 1);
        vm.prank(user);
        router.swapExactIn(_direct(1_000e18), 1_000e18, 1, user, block.timestamp + 1);
        uint256 o = _owedAll();
        assertGt(o, 0, "setup: a fee is owed");
        tok.mint(address(router), 5e18);
        router.queueRescue(address(tok), address(0x5AFE));
        vm.warp(block.timestamp + 48 hours + 1);
        router.executeRescue(address(tok), address(0x5AFE));
        assertEq(tok.balanceOf(address(0x5AFE)), 5e18, "the stray balance, no more");
        assertEq(tok.balanceOf(address(router)), o, "the owed fees stay");
        tok.setRefuse(t1, 0);
        (bool ok, ) = _claim(t1);
        assertTrue(ok, "claim");
        assertEq(tok.balanceOf(address(router)), 0, "and are claimed");
    }

    /// Property 5: a claim cannot run inside a swap. The token is treasury2 itself and reaches
    /// in from the swap's first transfer out of the Router; the lock refuses it (RouterE(7)).
    function test_ClaimInsideASwap_IsRefused() public {
        vm.prank(t2); router.moveTreasury(address(tok));
        tok.setRefuse(address(tok), 1);
        vm.prank(user);
        router.swapExactIn(_direct(1_000e18), 1_000e18, 1, user, block.timestamp + 1);
        assertGt(_owed(1), 0, "setup: treasury2 (the token) is owed");
        tok.setRefuse(address(tok), 0);
        tok.setHook(address(router));
        vm.prank(user);
        router.swapExactIn(_direct(1_000e18), 1_000e18, 1, user, block.timestamp + 1);
        assertTrue(tok.hookFired(), "setup: the token reached in mid-swap");
        assertFalse(tok.hookOk(), "a claim ran inside a swap");
        assertEq(keccak256(tok.hookErr()), keccak256(_e(7)), "refused by the swap lock");
    }
}
