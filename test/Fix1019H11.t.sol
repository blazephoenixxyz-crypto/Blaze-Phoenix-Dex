// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// H11 (19/10) - REGRESSION GUARDS FOR THE THREE V1 DRAIN SHAPES, ON 2.0.0.
//
// Two bounty reports against Router 1.0.0 were confirmed and paid. Both need an account whose
// balances the Router code can reach: an EOA that delegated to the Router (EIP-7702 designator
// 0xef0100 || router), where the Router code runs with address(this) == the EOA, or the Router
// itself holding stranded funds. Three distinct mechanisms, three protections in this tree:
//
//   I1 (momonom, input side). V1 hop 0 spent the DECLARED leg.amountIn whatever the pull
//      delivered, so a third party paying X while declaring X + balance spent the account's own
//      tokenIn. 2.0.0 scales hop 0 to the MEASURED pull: scaleNum = realIn over
//      scaleDen = sum(leg.amountIn) (_hopScaleImpactAndQuote, followed by the hop-0 clamp).
//   I2 (Tarun 3084, output side). V1 paid totalReceived = balanceOf(tokenOut, this): the
//      account's whole prior tokenOut balance went to the caller's recipient. 2.0.0 measures the
//      DELTA against toutStart, the baseline taken before the hops.
//   I3 (Tarun 3086 / Agis vector A, bridge side). V1 swept the raw balance of every declared
//      intermediate token to the payer. 2.0.0 sweeps only rb - bridgeBase[h].
//
// Each property has an honest case (a normal swap through the same account delivers) and an
// adversarial case that asserts the invariant on balances before and after. The adversarial
// cases SUCCEED on the guarded tree - they are not greens produced by a revert - and each one has
// a registered mutant in .github/scripts/mutants.py ("h11-1019") that turns it red on an assert.
//
// Delegated execution is real EIP-7702: the designator is etched and the EVM is switched to
// prague, and _delegate() proves the Router code answers at the EOA. In that context the
// treasuries read the EOA's empty storage (address(0)); MockERC20 accepts to == address(0), so a
// token that refuses it cannot turn the attack into a revert and fake a green.
//
// forge test --match-path test/Fix1019H11.t.sol -vv

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";

contract Fix1019H11Test is Test {
    BlazePhoenixHub hub;
    BlazePhoenixRouter router;
    MockERC20 tA;
    MockERC20 tB;
    MockERC20 tX;
    MockERC20 tC;
    MockV2Pair pairAB;
    MockV2Pair pairAX;
    MockV2Pair pairXC;

    address victim;
    uint256 victimPk;
    address attacker = makeAddr("attacker");
    address user = makeAddr("user");

    uint256 constant R = 1_000_000e18;      // every pair: R / R
    uint256 constant X = 1_000e18;          // what the third party actually pays
    uint256 constant PRIOR_A = 50_000e18;   // the delegated account's own tokenIn
    uint256 constant PRIOR_B = 40_000e18;   // the delegated account's own tokenOut
    uint256 constant STRANDED = 5_000e18;   // pre-existing bridge-token balance (I3)

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        router = new BlazePhoenixRouter(
            address(hub), address(0xBEEF), address(this), makeAddr("t1"), makeAddr("t2"));
        tA = new MockERC20("A", "A");
        tB = new MockERC20("B", "B");
        tX = new MockERC20("X", "X");
        tC = new MockERC20("C", "C");
        pairAB = _pair(tA, tB);
        pairAX = _pair(tA, tX);
        pairXC = _pair(tX, tC);
        (victim, victimPk) = makeAddrAndKey("victim");
        tA.mint(attacker, 10 * X);
        tA.mint(user, 10 * X);
    }

    function _pair(MockERC20 a, MockERC20 b) private returns (MockV2Pair p) {
        p = new MockV2Pair(address(a), address(b));
        a.mint(address(p), R);
        b.mint(address(p), R);
        p.setReserves(uint112(R), uint112(R));
    }

    /// The victim EOA delegates to the Router (EIP-7702). Proven, not assumed: an immutable read
    /// through the EOA must answer with the Router's hub, i.e. Router code runs at the EOA.
    function _delegate() private {
        vm.setEvmVersion("prague");
        vm.etch(victim, abi.encodePacked(hex"ef0100", address(router)));
        assertEq(address(BlazePhoenixRouter(payable(victim)).hub()), address(hub),
            "the delegated EOA does not run the Router code");
    }

    function _leg(MockV2Pair p, address tin, address tout, uint256 amt)
        private pure returns (Leg memory)
    {
        return Leg({
            pool: address(p), hooks: address(0), kind: BPC.KIND_V2, fee: 30, tickSpacing: 0,
            zeroForOne: tin < tout, stable: false, amountIn: amt, expectedOut: 0,
            auxId: bytes32(0)
        });
    }

    function _wrap(Hop[] memory hops) private pure returns (Route memory r) {
        r = Route({
            hops: hops, totalOut: 0, singleOut: 0, singleOutFloor: 0,
            expectedImpactBps: 0, confidenceWad: 0, estGas: 0,
            hasSurplus: false, isV4Bundle: false
        });
    }

    /// One hop A -> B whose single leg DECLARES `declared` (the momonom lever).
    function _routeAB(uint256 declared) private view returns (Route memory) {
        Leg[] memory l = new Leg[](1);
        l[0] = _leg(pairAB, address(tA), address(tB), declared);
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({tokenIn: address(tA), tokenOut: address(tB), amountIn: declared,
            expectedOut: 0, legs: l});
        return _wrap(hops);
    }

    /// Two hops A -> X -> C: hops[0].tokenOut DECLARES tX, the token the target already holds.
    function _routeAXC() private view returns (Route memory) {
        uint256 q = (X * 9970 * R) / (R * 10_000 + X * 9970);
        Leg[] memory l0 = new Leg[](1);
        l0[0] = _leg(pairAX, address(tA), address(tX), X);
        Leg[] memory l1 = new Leg[](1);
        l1[0] = _leg(pairXC, address(tX), address(tC), q);
        Hop[] memory hops = new Hop[](2);
        hops[0] = Hop({tokenIn: address(tA), tokenOut: address(tX), amountIn: X, expectedOut: 0, legs: l0});
        hops[1] = Hop({tokenIn: address(tX), tokenOut: address(tC), amountIn: q, expectedOut: 0, legs: l1});
        return _wrap(hops);
    }

    function _pay(address from, address target) private {
        vm.prank(from);
        tA.approve(target, X);
    }

    // ─── I1 (P1): a third party cannot spend the delegated account's tokenIn ───────────────────

    function test_H11_1019_I1_HonestThirdPartySwapThroughDelegatedAccountDelivers() public {
        _delegate();
        tA.mint(victim, PRIOR_A);
        _pay(attacker, victim);
        Route memory r = _routeAB(X);
        uint256 pairOut0 = tB.balanceOf(address(pairAB));

        vm.prank(attacker);
        uint256 out = BlazePhoenixRouter(payable(victim)).swapExactIn(r, X, 1, attacker, block.timestamp + 1);

        assertGt(out, 0, "the honest swap delivers");
        assertEq(tB.balanceOf(attacker), pairOut0 - tB.balanceOf(address(pairAB)),
            "the recipient gets what the pool produced");
        assertEq(tA.balanceOf(victim), PRIOR_A, "the account's tokenIn is untouched");
    }

    function test_H11_1019_I1_DelegatedAccountTokenInNeverPaysForAThirdParty() public {
        _delegate();
        tA.mint(victim, PRIOR_A);
        _pay(attacker, victim);
        // The V1 lever: pay X, declare X/2 + the account's whole balance on hop 0.
        Route memory r = _routeAB(PRIOR_A + X / 2);
        uint256 attackerA0 = tA.balanceOf(attacker);
        uint256 pairIn0 = tA.balanceOf(address(pairAB));
        uint256 victimA0 = tA.balanceOf(victim);

        vm.prank(attacker);
        BlazePhoenixRouter(payable(victim)).swapExactIn(r, X, 1, attacker, block.timestamp + 1);

        uint256 paid = attackerA0 - tA.balanceOf(attacker);
        assertLe(paid, X, "the third party pays at most amountIn");
        assertLe(tA.balanceOf(address(pairAB)) - pairIn0, paid,
            "the pool received more tokenIn than the third party paid");
        assertGe(tA.balanceOf(victim), victimA0,
            "the delegated account's own tokenIn paid for a third party's swap");
    }

    // ─── I2 (P2): the recipient gets only this swap's output; the account's tokenOut stays ─────

    function test_H11_1019_I2_HonestSwapPaysExactlyItsOwnOutput() public {
        _delegate();
        _pay(attacker, victim);
        Route memory r = _routeAB(X);
        uint256 pairOut0 = tB.balanceOf(address(pairAB));

        vm.prank(attacker);
        uint256 out = BlazePhoenixRouter(payable(victim)).swapExactIn(r, X, 1, attacker, block.timestamp + 1);

        uint256 produced = pairOut0 - tB.balanceOf(address(pairAB));
        assertGt(out, 0, "the honest swap delivers");
        assertEq(tB.balanceOf(attacker), produced, "the recipient gets the swap's output");
        assertEq(tB.balanceOf(victim), 0, "nothing stays behind");
    }

    function test_H11_1019_I2_DelegatedAccountTokenOutIsNeverPaidOut() public {
        _delegate();
        tB.mint(victim, PRIOR_B);
        _pay(attacker, victim);
        Route memory r = _routeAB(X); // an HONEST route: the lever is the account's tokenOut
        uint256 pairOut0 = tB.balanceOf(address(pairAB));
        uint256 victimB0 = tB.balanceOf(victim);

        vm.prank(attacker);
        BlazePhoenixRouter(payable(victim)).swapExactIn(r, X, 1, attacker, block.timestamp + 1);

        uint256 produced = pairOut0 - tB.balanceOf(address(pairAB));
        assertLe(tB.balanceOf(attacker), produced,
            "the recipient received more than the swap produced");
        assertGe(tB.balanceOf(victim), victimB0,
            "the delegated account's prior tokenOut was paid to a third party");
    }

    // ─── I3 (P3): a declared intermediate token never moves the pre-existing balance ──────────

    function _i3(address target, address payer) private {
        tX.mint(target, STRANDED);
        _pay(payer, target);
        Route memory r = _routeAXC();
        uint256 payerC0 = tC.balanceOf(payer);
        uint256 pairC0 = tC.balanceOf(address(pairXC));

        vm.prank(payer);
        uint256 out = BlazePhoenixRouter(payable(target)).swapExactIn(r, X, 1, payer, block.timestamp + 1);

        assertGt(out, 0, "the two-hop swap delivers");
        assertEq(tC.balanceOf(payer) - payerC0, pairC0 - tC.balanceOf(address(pairXC)),
            "the payer gets the final hop's output");
        assertGe(tX.balanceOf(target), STRANDED,
            "the bridge sweep moved the target's pre-existing balance of the declared token");
        assertLe(tX.balanceOf(payer), 1e18, "the payer got more than a rounding residual of tX");
    }

    function test_H11_1019_I3_RouterStrandedBridgeBalanceIsNotSwept() public {
        _i3(address(router), user);
    }

    function test_H11_1019_I3_DelegatedAccountBridgeBalanceIsNotSwept() public {
        _delegate();
        _i3(victim, attacker);
    }

    /// The declaration alone cannot aim the sweep: hops[0] names tX as the bridge but its leg
    /// trades A -> B. The first check to see it is the pool-holds-the-declared-pair test in the
    /// hop quote (BPC.heldBy -> RouterE(8)), before any transfer and before the leg-token gate
    /// (RouterE(3)) would run.
    function test_H11_1019_I3_MisdeclaredBridgeTokenIsRefused() public {
        tX.mint(address(router), STRANDED);
        _pay(user, address(router));
        Route memory r = _routeAXC();
        r.hops[0].legs[0] = _leg(pairAB, address(tA), address(tB), X);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, uint16(8)));
        router.swapExactIn(r, X, 1, user, block.timestamp + 1);

        assertEq(tX.balanceOf(address(router)), STRANDED, "the stranded balance is intact");
    }
}
