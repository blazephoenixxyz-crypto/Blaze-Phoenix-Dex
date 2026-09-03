// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// THE PREVIEW AND THE EXECUTION DISAGREE WHEN NO HOP INPUT IS A BRIDGE.
//
// WHY THIS FILE EXISTS. `test/PreviewExecutionParity.t.sol` already asserts that the Quoter
// predicts what the Router delivers. Its own header explains that the fee model changed twice
// on 2026-08-21 and the suite stayed GREEN both times, because nothing compared the two sides.
// That file then calls `hub.addBridge(address(tB))` in its fixture (PreviewExecutionParity:61),
// so every route it builds has a bridge input and takes the ANCHORED branch of Router:1111.
//
// There is a second regime. `Router:1032-1036` scans for the first hop whose `tokenIn` is a
// registered bridge; when it finds none, `feeHop` stays at `type(uint256).max`, and the
// predicate at `Router:1111` — `feeHop == type(uint256).max || h == feeHop` — is then TRUE FOR
// EVERY HOP. That is deliberate: `Router:1021-1027` calls it immunity by EXHAUSTION, the only
// rule with no index at which to insert a dust prefix. It is the fee POLICY that is at issue
// here, not the anchor.
//
// The Quoter does not model it. `Quoter:_pack` deducts the fee exactly ONCE, unconditionally,
// and its own comment says why that is dangerous:
//
//     "THIS IS THE SIBLING CHANNEL of `_chargeHopFee`. If one changes without the other, the
//      quote starts lying about what execution does again — the defect signature of this
//      codebase, recorded with N=3 in the corpus."
//
// The same comment records the number: "a 2-hop route lost ~56 bps". Reported independently by
// mohaseenbasha (FEE_01) as a measured 56 bps against a 28 bps preview.
//
// BOTH SIDES ARE REACHED THROUGH PUBLIC API. `Quoter.previewRoute` (Quoter:205) accepts a
// hand-built Route, and `Router.swapExactIn` (Router:372) executes one. A caller never needs to
// compute anything off-chain to be told 28 and charged 56.
//
// RED at 6334df6, both tests, for two independent reasons (INV-F1 and INV-F2).

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixQuoter} from "../src/BlazePhoenixQuoter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";

contract ExhaustionRegimePreviewParityTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    BlazePhoenixQuoter quoter;
    BlazePhoenixRouter router;
    MockERC20 tA;
    MockERC20 tB;
    MockERC20 tC;
    MockV2Pair ab;
    MockV2Pair bc;

    address user = address(0x5E4);
    address constant TREASURY_1 = address(0x7451);
    address constant TREASURY_2 = address(0x7452);
    uint256 constant AMOUNT_IN = 1_000e18;

    // The single legitimate fee, computed BY HAND from the published constant so the test is
    // not its own oracle: 1_000e18 x 28 / 10_000. Deliberately NOT `BPC.mulDivUp(...)`, which
    // would re-use the production rounding and move with the very mutation it must catch
    // (the `_netOfFee` defect, oracle-independence F3).
    uint256 constant ONE_FEE = 2.8e18;

    uint256 constant RESERVE = 1_000_000e18;

    // NOTE THE ABSENCE: no `hub.addBridge(...)` anywhere in this fixture. That absence is the
    // precondition under test and is asserted, never assumed, in every test below.
    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0xBEEF));
        solver = new BlazePhoenixSolver(address(hub));
        quoter = new BlazePhoenixQuoter(address(hub), address(solver));
        router = new BlazePhoenixRouter(
            address(hub), address(solver), address(this), TREASURY_1, TREASURY_2
        );

        tA = new MockERC20("A", "A");
        tB = new MockERC20("B", "B");
        tC = new MockERC20("C", "C");
        ab = _pair(tA, tB);
        bc = _pair(tB, tC);

        hub.setRoles(address(this), address(solver), address(quoter));
        _seed(ab, tA, tB);
        _seed(bc, tB, tC);
        hub.setRoles(address(router), address(solver), address(quoter));

        tA.mint(user, 10_000e18);
        vm.prank(user);
        tA.approve(address(router), type(uint256).max);
    }

    function _pair(MockERC20 x, MockERC20 y) private returns (MockV2Pair p) {
        p = new MockV2Pair(address(x), address(y));
        x.mint(address(p), RESERVE);
        y.mint(address(p), RESERVE);
        p.setReserves(uint112(RESERVE), uint112(RESERVE));
    }

    function _seed(MockV2Pair p, MockERC20 x, MockERC20 y) private {
        for (uint256 i; i < 5; i++) {
            hub.recordSwap(address(p), BPC.KIND_V2, 30, address(0),
                address(x), address(y), 1e18, 1e18, 1_000_000e18);
        }
    }

    /// @dev A two-hop route tA -> tB -> tC, built by hand because the Solver only composes
    ///      multi-hop routes through REGISTERED bridges and there are none here. The route is
    ///      built BEFORE any cheatcode is armed: the builders below read `token0()` off the
    ///      mocks, and a `prank` armed earlier would be spent on that staticcall.
    function _twoHopRoute() private view returns (Route memory route) {
        Leg[] memory l0 = new Leg[](1);
        l0[0] = Leg({
            pool: address(ab), hooks: address(0), kind: BPC.KIND_V2, fee: 30,
            tickSpacing: 0, zeroForOne: address(tA) < address(tB), stable: false,
            amountIn: AMOUNT_IN, expectedOut: 1, auxId: bytes32(0)
        });
        Leg[] memory l1 = new Leg[](1);
        l1[0] = Leg({
            pool: address(bc), hooks: address(0), kind: BPC.KIND_V2, fee: 30,
            tickSpacing: 0, zeroForOne: address(tB) < address(tC), stable: false,
            amountIn: AMOUNT_IN, expectedOut: 1, auxId: bytes32(0)
        });
        Hop[] memory hops = new Hop[](2);
        hops[0] = Hop({tokenIn: address(tA), tokenOut: address(tB),
                       amountIn: AMOUNT_IN, expectedOut: 1, legs: l0});
        hops[1] = Hop({tokenIn: address(tB), tokenOut: address(tC),
                       amountIn: AMOUNT_IN, expectedOut: 1, legs: l1});
        // THE HONEST GROSS QUOTE, composed the way the Solver would compose it: the pure
        // AMM output of both hops with NO protocol fee, because `_pack` applies the fee
        // itself. `previewRoute` is `pure` (Quoter:206) and returns `route.totalOut` as
        // `grossOut` untouched -- declaring 1 here would make the parity test compare the
        // caller's own number against delivery, which is vacuity, not a test.
        // Using `BPC.outV2` to BUILD the input is not the same as using it as the oracle:
        // the oracle below is the MEASURED `delivered`, and the claim under test is that
        // preview and execution agree, not that either matches this arithmetic.
        uint256 g0 = BPC.outV2(AMOUNT_IN, RESERVE, RESERVE, 30);
        uint256 g1 = BPC.outV2(g0, RESERVE, RESERVE, 30);
        route = Route({hops: hops, totalOut: g1, singleOut: g1, singleOutFloor: 0,
                       expectedImpactBps: 0, confidenceWad: 0, estGas: 0,
                       hasSurplus: false, isV4Bundle: false});
    }

    /// @dev The regime selector, asserted rather than assumed. If a future fixture change
    ///      registers any of these as a bridge, these tests stop testing what they claim and
    ///      MUST fail loudly here instead of passing for the wrong reason.
    function _assertExhaustionRegime() private view {
        assertFalse(hub.isBridgeToken(address(tA)), "precondition: tA must not be a bridge");
        assertFalse(hub.isBridgeToken(address(tB)), "precondition: tB must not be a bridge");
        assertFalse(hub.isBridgeToken(address(tC)), "precondition: tC must not be a bridge");
    }

    // =========================================================================
    //  INV-F1 — THE POLICY, PINNED, AND THE TWO CHANNELS TIED TOGETHER.
    // =========================================================================

    /// WHAT THIS PINS, AND WHY IT IS NOT AN ASSERTION THAT THE CODE IS RIGHT.
    ///
    /// Charging every hop when no hop input is a bridge is a POLICY, chosen deliberately
    /// (`Router:1021-1027`: immunity by exhaustion, the only rule with no index at which to
    /// insert a dust prefix). The owner's decision of 2026-08-22 rejected "every hop at full
    /// rate" for the ANCHORED case, and the choice between (a) accepting the measured residual,
    /// (b) every hop at full rate and (c) every hop at a reduced rate is still open. Until it is
    /// made, a test asserting "one fee per route" would be red for ever, and a permanently red
    /// test is a warning nobody reads.
    ///
    /// So this pins what the code DOES, in the manner `test/FeeAnchorValueInjectingPrefix.t.sol`
    /// already established for the anchored leak. The value of the pin is not the pin: it is
    /// that it fails the day the policy moves, and the assertion below then FORCES the Quoter
    /// to be changed in the same commit. That is the whole point — `Quoter:_pack` calls itself
    /// "THE SIBLING CHANNEL of `_chargeHopFee`" and warns that if one changes without the other
    /// the quote starts lying. Nothing enforced that warning. This does.
    ///
    /// NOT VACUOUS: the entry fee is asserted against a hand-computed literal (so a fee that
    /// stopped being charged fails here), the second denomination is asserted PRESENT (so a
    /// policy change to one-fee-per-route fails here), and the swap is asserted to have
    /// executed (so an empty run cannot read as a pass).
    function test_INV_F1_ExhaustionPolicyIsPinnedAndTiedToThePreview() public {
        _assertExhaustionRegime();
        Route memory route = _twoHopRoute();

        (BlazePhoenixQuoter.Preview memory pv) = quoter.previewRoute(route, 0);

        vm.prank(user);
        uint256 delivered = router.swapExactIn(
            route, AMOUNT_IN, 1, user, block.timestamp + 1
        );
        assertGt(delivered, 0, "precondition: the swap must actually execute");

        uint256 feeInA = tA.balanceOf(TREASURY_1) + tA.balanceOf(TREASURY_2);
        uint256 feeInB = tB.balanceOf(TREASURY_1) + tB.balanceOf(TREASURY_2);
        emit log_named_decimal_uint("fee taken in tA (entry)     ", feeInA, 18);
        emit log_named_decimal_uint("fee taken in tB (second hop)", feeInB, 18);

        assertEq(feeInA, ONE_FEE, "the entry hop pays exactly one 28 bps fee");
        assertGt(feeInB, 0,
            "PINNED: the exhaustion regime charges the second hop too. If this line fails the "
            "policy changed - and Quoter._pack MUST be changed in the same commit");

        // AND THE TIE. Whatever the policy is, the preview has to model it. This is the
        // assertion the corpus never had, and its absence is what let a 28 bps divergence
        // live in a regime that ten test files already executed.
        assertApproxEqRel(delivered, pv.netOut + pv.safetyBuffer, 0.001e18,
            "the preview's fee model must match the policy the Router actually applies");
    }

    // =========================================================================
    //  INV-F2 — HONESTY. The preview must predict the delivery.
    // =========================================================================

    /// CLAIM: `previewRoute(route).netOut + safetyBuffer` predicts what `swapExactIn(route)`
    /// delivers, for the same route, amount and block. This is the invariant
    /// `PreviewExecutionParity` already enforces for the anchored regime; it must hold here too
    /// or the published quote is regime-dependent without saying so.
    ///
    /// RED at 6334df6: the preview deducts 28 bps once, the Router takes ~28 bps per hop, so
    /// the delivery falls ~28 bps below the prediction — 2.8x the tolerance of the sibling file.
    ///
    /// THE TOLERANCE IS THE SIBLING FILE'S, DELIBERATELY. 0.1% is smaller than the 0.28% defect
    /// it must catch. Widening it to accommodate this failure would be the wrong repair, exactly
    /// as PreviewExecutionParity:97-101 already records for its own earlier version.
    function test_INV_F2_PreviewPredictsDeliveryWithNoBridge() public {
        _assertExhaustionRegime();
        Route memory route = _twoHopRoute();

        (BlazePhoenixQuoter.Preview memory pv) = quoter.previewRoute(route, 0);
        assertEq(pv.hops, 2, "precondition: the route must have two hops");
        assertGt(pv.netOut, 0, "precondition: the preview must quote something");

        vm.prank(user);
        uint256 delivered = router.swapExactIn(
            route, AMOUNT_IN, 1, user, block.timestamp + 1
        );

        emit log_named_decimal_uint("predicted (netOut+buffer)", pv.netOut + pv.safetyBuffer, 18);
        emit log_named_decimal_uint("delivered                ", delivered, 18);
        assertApproxEqRel(delivered, pv.netOut + pv.safetyBuffer, 0.001e18,
            "INV-F2: the preview's fee model does not match delivery in the exhaustion regime");
        assertLe(pv.netOut, delivered, "the preview must never promise more than execution delivers");
    }
}
