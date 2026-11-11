// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  A surplus measured on a pull is shared pro rata between the pull and the balance before it (3948)
//
//  Red at 8d2ce64 (fin1111-router): `Router._received` took the whole delta of a pull only when
//  the Router held exactly nothing before it, and clamped to the ask (#45) from one wei up. The
//  Router itself leaves wei on its own balance on a token that keeps balances as shares and
//  rounds each transfer down (a fee push, a leg transfer), so from the second swap of such a
//  token the clamp was back, and a token that restates balances upward inside `transferFrom`
//  kept the payer's own growth on the Router. One wei sent by anyone armed the same clamp.
//
//  The property: the surplus of a pull (delta minus the ask) is attributed to the pull in the
//  proportion of the ask to the balance the Router held plus the ask, rounded down. A token
//  that restates every balance by the same factor after crediting the Router grows the pull
//  and the prior balance by that factor, so the pull's part of the surplus is exactly the
//  payer's growth and what stays is exactly the prior balance's growth, dust or donation
//  alike. The prior balance is never spent (measured in the token's own shares), the payer
//  gets back what the swap did not spend, and no wei of the Router's own balance is a switch.
//
//  The oracle is the token's share ledger and arithmetic done here from the mock's documented
//  rounding (display = shares * num / den, rounded down; the restatement is applied after the
//  balances move). Dimensions: classic door and Permit2 door; the prior balance one wei, a few
//  wei, the Router's own share dust, a donation larger than the ask; whole and fractional
//  factors; amounts and balances by fuzz.
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter, IPermit2} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";
import {PathologicalERC20} from "./mocks/PathologicalERC20.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";
import {MockPermit2} from "./mocks/MockPermit2.sol";

contract PullSurplusIsSharedProRataTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    BlazePhoenixRouter router;
    MockPermit2 permit2;

    PathologicalERC20 inTok;
    MockERC20 outTok;
    MockV2Pair pair;

    address payer = address(0xA11CE);
    address other = address(0xBEEF);
    address recipient = address(0xCAFE);
    address treasury1 = address(0xFEE1);
    address treasury2 = address(0xFEE2);

    uint256 constant RESERVE = 1_000_000e18;
    uint256 constant AMOUNT = 100e18;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        solver = new BlazePhoenixSolver(address(hub), address(0));
        router = new BlazePhoenixRouter(address(hub), address(solver), address(this), treasury1, treasury2);
        hub.setRoles(address(router), address(solver), address(this));
        permit2 = new MockPermit2();
        router.setPermit2(address(permit2));

        inTok = new PathologicalERC20("IN", "IN", 18);
        outTok = new MockERC20("OUT", "OUT");
        pair = new MockV2Pair(address(inTok), address(outTok));
        inTok.mint(address(pair), RESERVE);
        outTok.mint(address(pair), RESERVE);
        pair.setReserves(uint112(RESERVE), uint112(RESERVE));

        vm.startPrank(payer);
        inTok.approve(address(router), type(uint256).max);
        inTok.approve(address(permit2), type(uint256).max);
        vm.stopPrank();
    }

    function _fee(uint256 base) private pure returns (uint256) { return (base * 28 + 9_999) / 10_000; }

    function _route(uint256 amt) private view returns (Route memory r) {
        Leg[] memory legs = new Leg[](1);
        legs[0] = Leg({
            pool: address(pair), hooks: address(0), kind: BPC.KIND_V2, fee: 30,
            tickSpacing: 0, zeroForOne: pair.token0() == address(inTok), stable: false,
            amountIn: amt, expectedOut: 0, auxId: bytes32(0)
        });
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({tokenIn: address(inTok), tokenOut: address(outTok), amountIn: amt, expectedOut: 0, legs: legs});
        r = Route({
            hops: hops, totalOut: 0, singleOut: 0, singleOutFloor: 0,
            expectedImpactBps: 0, confidenceWad: 0, estGas: 0,
            hasSurplus: false, isV4Bundle: false
        });
    }

    function _swap(uint256 amt, bool viaPermit2) private returns (uint256 got) {
        Route memory r = _route(amt);
        if (viaPermit2) {
            IPermit2.PermitTransferFrom memory p = IPermit2.PermitTransferFrom({
                permitted: IPermit2.TokenPermissions({token: address(inTok), amount: amt}),
                nonce: uint256(keccak256(abi.encode(amt, inTok.balanceOf(payer)))),
                deadline: block.timestamp + 60
            });
            vm.prank(payer);
            got = router.swapExactInWithPermit2(r, amt, 1, recipient, block.timestamp + 1, p, "");
        } else {
            vm.prank(payer);
            got = router.swapExactIn(r, amt, 1, recipient, block.timestamp + 1);
        }
    }

    /// The Router holds `prior` display units of the token (index 1) before the pull; the token
    /// sets its index to num/den after crediting the pull. The pull's part of the surplus is the
    /// payer's growth; what stays on the Router is the prior balance's growth, no more.
    function _sharedProRata(uint256 prior, uint256 amt, uint256 num, uint256 den, bool viaPermit2) private {
        if (prior > 0) {
            inTok.mint(other, prior);
            vm.prank(other);
            inTok.transfer(address(router), prior);
        }
        uint256 priorShares = inTok.sharesOf(address(router));
        assertEq(priorShares, prior, "fixture: index 1, one share per wei");
        inTok.mint(payer, amt);
        inTok.setRebaseOnTransferTo(address(router), num, den);

        uint256 got = _swap(amt, viaPermit2);
        assertGt(got, 0, "the swap settles");
        assertEq(outTok.balanceOf(recipient), got, "and delivers what it reports");

        // the oracle: the delta the Router measured, from the mock's own rounding, then the
        // pull's share of the surplus rounded down
        uint256 delta = (prior + amt) * num / den - prior; // the Router measured `prior` before the pull
        uint256 received = amt + BPC.mulDiv(delta - amt, amt, amt + prior);
        uint256 refund = received - amt - _fee(amt);

        // the prior balance is whole, in shares: a restatement cannot hide a spent wei
        assertGe(inTok.sharesOf(address(router)), priorShares, "the balance held before the pull was spent");
        // the payer got the refund: the token rounds each transfer down by under one wei, which
        // the sweep hands the payer for the three transfers before the refund (two fee pushes,
        // the leg) and keeps from the refund itself
        assertLe(inTok.balanceOf(payer), refund + 3, "the payer got more than the pull's share");
        assertGe(inTok.balanceOf(payer) + 1, refund, "the payer's share of the surplus stayed on the Router");
        // the Router keeps the prior balance's growth and at most one wei of rounding from each
        // of its three transfers (two fee pushes, the refund)
        assertLe(inTok.balanceOf(address(router)), (prior * num + den - 1) / den + 3,
                 "the Router kept part of the payer's growth");
    }

    // ---- the report: dust and donations before the pull ----------------------------------------

    /// THE RED (3948, dust): at 8d2ce64 one wei on the Router clamped the pull to the ask and
    /// the Router kept the payer's whole growth (100e18 at x2).
    function test_OneWeiBeforeThePull_ThePayersGrowthIsThePayers() public {
        _sharedProRata(1, AMOUNT, 2, 1, false);
    }

    function test_OneWeiBeforeThePull_FractionalFactor() public {
        _sharedProRata(1, AMOUNT, 11, 10, false);
    }

    function test_SevenWeiBeforeThePull_FractionalFactor() public {
        _sharedProRata(7, AMOUNT, 11, 10, false);
    }

    function test_Permit2Door_OneWeiBeforeThePull_ThePayersGrowthIsThePayers() public {
        _sharedProRata(1, AMOUNT, 2, 1, true);
    }

    /// A donation larger than the ask: the donor's growth stays, the payer's goes back.
    function test_ADonationLargerThanTheAsk_OnlyItsOwnGrowthStays() public {
        _sharedProRata(500e18, AMOUNT, 2, 1, false);
    }

    /// Nothing before the pull: the whole delta is the pull's (the 3948 fix of fin1111-router).
    function test_NothingBeforeThePull_TheWholeDeltaIsThePulls() public {
        _sharedProRata(0, AMOUNT, 2, 1, false);
    }

    function testFuzz_SharedProRata(uint256 prior, uint256 n, uint256 kSeed, bool viaPermit2) public {
        uint256[4] memory nums = [uint256(2), 11, 3, 101];
        uint256[4] memory dens = [uint256(1), 10, 2, 100];
        // the ask a multiple of 1e7 keeps the fee and its split exact; the prior balance is free
        _sharedProRata(bound(prior, 0, 1e24), bound(n, 1e3, 1e15) * 1e7, nums[kSeed % 4], dens[kSeed % 4], viaPermit2);
    }

    // ---- the report: the Router's own share dust ----------------------------------------------

    /// THE RED (3948, the verifier's case): a token with a fractional index rounds each transfer
    /// down, so the first swap leaves wei of the Router's own making on its balance. At 8d2ce64
    /// the second swap, restated inside its pull, was clamped by that dust and the payer got
    /// nothing back.
    function test_TheRoutersOwnShareDust_DoesNotClampTheNextPull() public {
        inTok.setRebase(11, 10);
        uint256 amt = 110e18 + 11; // exact in shares at index 11/10; the fee split and the leg transfer round
        inTok.mint(payer, amt);
        _swap(amt, false);
        uint256 dustShares = inTok.sharesOf(address(router));
        assertGt(dustShares, 0, "premise: the first swap left share dust on the Router");
        assertLe(inTok.balanceOf(address(router)), 3, "premise: wei, from three rounded transfers");
        assertEq(inTok.balanceOf(payer), 0, "premise: the first swap spent the ask");

        inTok.mint(payer, amt);
        inTok.setRebaseOnTransferTo(address(router), 22, 10); // doubles every balance inside the pull
        _swap(amt, false);

        // the pull doubled: the payer's growth is one ask, less the fee; the share of the dust's
        // growth that the proportion hands the payer, and the refund's rounding, are wei
        uint256 refund = amt - _fee(amt);
        assertLe(inTok.balanceOf(payer), refund, "the payer got more than its growth");
        assertGe(inTok.balanceOf(payer) + 3, refund, "the dust clamped the pull: the payer's growth stayed on the Router");
        assertGe(inTok.sharesOf(address(router)), dustShares, "the dust was spent");
        // at most 3 wei of dust grow to at most 7 at index 22/10; three transfers each leave under 2.2 wei
        assertLe(inTok.balanceOf(address(router)), 7 + 3 * 2, "the Router kept more than its dust, doubled, plus rounding");
    }

    // ---- controls -----------------------------------------------------------------------------

    /// No restatement: the pull is the ask, the prior balance is untouched.
    function test_Control_HonestPullOverADonation() public {
        inTok.mint(other, 500e18);
        vm.prank(other);
        inTok.transfer(address(router), 500e18);
        inTok.mint(payer, AMOUNT);
        inTok.setRebaseOnTransferTo(address(0xDEAD), 2, 1); // armed, never fires
        _swap(AMOUNT, false);
        assertEq(inTok.balanceOf(payer), 0, "the payer spent exactly amountIn");
        assertEq(inTok.balanceOf(address(router)), 500e18, "the Router holds exactly what it held");
        assertEq(inTok.balanceOf(treasury1) + inTok.balanceOf(treasury2), _fee(AMOUNT), "the fee was paid");
    }

    /// The restatement is the donation's alone when the ask is tiny next to it: the payer's part
    /// of the surplus rounds down to its own growth and not one wei of the donor's.
    function test_Control_ATinyAskOverALargeDonation_TakesOnlyItsOwnGrowth() public {
        _sharedProRata(1e24, 1e7, 2, 1, false);
    }
}
