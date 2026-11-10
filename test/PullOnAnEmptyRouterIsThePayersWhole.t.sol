// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  `received` on a Router that held nothing before the pull (3948)
//
//  Red at af37bd6: `Router._received` clamped every pull to `amountIn` (#45). The clamp exists
//  because a balance the Router held BEFORE the pull can be restated inside it, and that part
//  of the delta is not the payer's. With no balance before the pull there is nothing foreign to
//  restate: the whole delta came from this pull. Clamped all the same, a token that restates
//  balances up inside `transferFrom`, after crediting the Router, left the payer's own growth
//  on the Router: the swap spent `amountIn`, the baseline counted the rest as pre-existing, and
//  the holds-nothing sweep returned nothing.
//
//  The property: a pull onto an empty Router is measured whole, so what the swap does not
//  spend goes back to the payer and the Router ends holding nothing. With a balance before the
//  pull the #45 clamp stands (the control below; `Bounty1013PullNeverCountsARestatement`).
//
//  The oracle is the token's own share ledger and arithmetic done here. Factors and amounts are
//  chosen so every display/share conversion is exact (the token rounds shares down).
//  Dimensions: classic door and Permit2 door; factors 2, 4, 5, 10; amounts by fuzz.
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

contract PullOnAnEmptyRouterIsThePayersWholeTest is Test {
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
                nonce: 0,
                deadline: block.timestamp + 60
            });
            vm.prank(payer);
            got = router.swapExactInWithPermit2(r, amt, 1, recipient, block.timestamp + 1, p, "");
        } else {
            vm.prank(payer);
            got = router.swapExactIn(r, amt, 1, recipient, block.timestamp + 1);
        }
    }

    /// The token multiplies every balance by `k` inside the pull, after crediting the Router,
    /// which held nothing. Everything the swap does not spend is the payer's.
    function _restatedOnAnEmptyRouter(uint256 amt, uint256 k, bool viaPermit2) private {
        inTok.mint(payer, amt);
        uint256 payerShares = inTok.sharesOf(payer);
        uint256 pairShares = inTok.sharesOf(address(pair));
        assertEq(inTok.balanceOf(address(router)), 0, "fixture: the Router is empty before the pull");
        inTok.setRebaseOnTransferTo(address(router), k, 1);

        uint256 got = _swap(amt, viaPermit2);
        assertGt(got, 0, "the swap settles");
        assertEq(outTok.balanceOf(recipient), got, "and delivers what it reports");

        uint256 fee = _fee(amt);
        assertEq(inTok.sharesOf(address(router)), 0, "the Router keeps none of the payer's shares");
        assertEq(inTok.balanceOf(address(router)), 0, "the Router holds nothing");
        assertEq(inTok.balanceOf(treasury1) + inTok.balanceOf(treasury2), fee, "the fee is 28 bps of what the route spends");
        assertEq(inTok.balanceOf(payer), k * amt - amt - fee, "the payer keeps what the swap did not spend");
        // conservation in shares: the payer's shares went to the pool, the fee, or back to it
        assertEq(
            payerShares,
            inTok.sharesOf(payer) + (inTok.sharesOf(address(pair)) - pairShares)
                + inTok.sharesOf(treasury1) + inTok.sharesOf(treasury2),
            "no share of the payer is left anywhere else"
        );
    }

    // ---- the report ---------------------------------------------------------------------------

    /// THE RED (3948): at af37bd6 the Router kept 100e18 display (50e18 shares) at x2.
    function test_RestatedInsideThePull_OnAnEmptyRouter_ReceivedIsTheWholeDelta() public {
        _restatedOnAnEmptyRouter(AMOUNT, 2, false);
    }

    function test_RestatedInsideThePull_OnAnEmptyRouter_Factor4() public { _restatedOnAnEmptyRouter(AMOUNT, 4, false); }
    function test_RestatedInsideThePull_OnAnEmptyRouter_Factor5() public { _restatedOnAnEmptyRouter(AMOUNT, 5, false); }
    function test_RestatedInsideThePull_OnAnEmptyRouter_Factor10() public { _restatedOnAnEmptyRouter(AMOUNT, 10, false); }

    function test_Permit2Door_RestatedInsideThePull_OnAnEmptyRouter_ReceivedIsTheWholeDelta() public {
        _restatedOnAnEmptyRouter(AMOUNT, 2, true);
    }

    function testFuzz_RestatedInsideThePull_OnAnEmptyRouter(uint256 n, uint256 kSeed, bool viaPermit2) public {
        uint256[4] memory ks = [uint256(2), 4, 5, 10];
        // multiples of 1e7 keep the fee, its 30/70 split and every share conversion exact
        _restatedOnAnEmptyRouter(bound(n, 1e3, 1e15) * 1e7, ks[kSeed % 4], viaPermit2);
    }

    // ---- controls -----------------------------------------------------------------------------

    /// No restatement: the pull is the amount, the payer spends it all, nothing is held.
    function test_Control_HonestPullOnAnEmptyRouter() public {
        inTok.mint(payer, AMOUNT);
        inTok.setRebaseOnTransferTo(address(0xDEAD), 2, 1); // armed, never fires
        _swap(AMOUNT, false);
        assertEq(inTok.balanceOf(payer), 0, "the payer spent exactly amountIn");
        assertEq(inTok.balanceOf(address(router)), 0, "the Router holds nothing");
        assertEq(inTok.balanceOf(treasury1) + inTok.balanceOf(treasury2), _fee(AMOUNT), "the fee was paid");
    }

    /// #45 stands: with a balance on the Router before the pull, `received` is clamped to
    /// `amountIn`, so the restated part of that balance is never the payer's refund.
    function _clampStandsWithABalanceBefore(uint256 foreign, bool viaPermit2) private {
        inTok.mint(other, foreign);
        vm.prank(other);
        inTok.transfer(address(router), foreign);
        uint256 foreignShares = inTok.sharesOf(address(router));
        inTok.mint(payer, AMOUNT);
        inTok.setRebaseOnTransferTo(address(router), 2, 1);

        _swap(AMOUNT, viaPermit2);
        assertEq(inTok.balanceOf(payer), 0, "nothing is refunded: received was clamped to amountIn");
        assertGe(inTok.sharesOf(address(router)), foreignShares, "the balance held before the pull is whole");
    }

    function test_Control_WithABalanceBeforeThePull_ReceivedIsClampedToAmountIn() public {
        _clampStandsWithABalanceBefore(500e18, false);
    }

    function test_Control_WithOneWeiBeforeThePull_ReceivedIsClampedToAmountIn() public {
        _clampStandsWithABalanceBefore(1, false);
    }

    function test_Permit2Door_Control_WithABalanceBeforeThePull_ReceivedIsClampedToAmountIn() public {
        _clampStandsWithABalanceBefore(500e18, true);
    }
}
