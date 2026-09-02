// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  CONDITION ADEQUACY — BlazePhoenixQuoter, the two MC/DC-inert sub-conditions.
//
//  MC/DC triage (2026-08-31) found two sub-conditions in this contract that no
//  test in the tree depends on: neutralising them (replacing the condition with
//  the identity of its connective) leaves the whole suite green. Each test here
//  exists to make exactly one of those neutralisations FAIL.
//
//  1. Quoter:311  `pv.canExecute = pv.netOut > 0 && pv.netOut >= pv.effectiveMinOut`
//     Sub-condition `pv.netOut > 0`, forced true, diverges only in the state
//     (netOut == 0, effectiveMinOut == 0), where canExecute flips false -> true:
//     a route that nets NOTHING previews as executable because the user asked
//     for nothing — absence read as permission. The suite already reaches that
//     state (empty-route classify test) but never reads the flag there.
//
//  2. Quoter:486  `if (h == 0 && carry > plannedIn) carry = plannedIn;`
//     Sub-condition `carry > plannedIn`, forced true, makes the hop-0 cap an
//     unconditional assignment. That diverges only when the plan's hop-0
//     commitment EXCEEDS the caller's amountIn: the exact pass would then
//     re-inflate the caller's order up to the plan's, dry-running liquidity the
//     caller never offered. The real Solver's clamp only ever shrinks, so no
//     existing test produces that state; the crafted-plan mock solver does.
//
//  Fixture reuse: MockSolverQ / MockHubQ come from QuoterExactRefusalBranches
//  (house idiom, cf. UnvisitedCells importing from RouterV4NativeEth). The
//  route builders are the same shapes as there, at the sizes these two states
//  need.
//
//  forge test --match-contract ConditionAdequacyQuoter -vv
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixQuoter} from "../src/BlazePhoenixQuoter.sol";
import {
    BlazePhoenixCore as BPC,
    Route, Hop, Leg
} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV3Pool} from "./mocks/MockV3Pool.sol";
import {MockSolverQ, MockHubQ} from "./QuoterExactRefusalBranches.t.sol";

contract ConditionAdequacyQuoterTest is Test {
    BlazePhoenixQuoter quoter;
    MockSolverQ solverMock;
    MockHubQ    hubMock;

    MockERC20 tokA;
    MockERC20 tokB;

    // Same pins as QuoterExactRefusalBranches: price 1.0 (== BPC.Q96), deep
    // single-tick liquidity, standard fee tier.
    uint160 constant SQRT_P_1 = 79228162514264337593543950336;
    uint128 constant LIQ      = 1e24;
    uint24  constant POOL_FEE = 3000;
    int24   constant TICK_SP  = 60;

    // The caller's order and the plan's (over-committed) hop-0 amount. PLANNED
    // is an exact multiple of CALL_AMT so the scale-down mulDiv is lossless and
    // the equality assertions carry no rounding slack.
    uint256 constant CALL_AMT = 1e18;
    uint256 constant PLANNED  = 4e18;

    // Planted plan-time approximation: if the dry run refused and the fallback
    // answered instead, exactOut would be a rescale of THIS (DECOY_OUT/4 under
    // the real cap, DECOY_OUT whole under the mutant) — either way ~1000x the
    // honest reading, so the oracle equality fails loudly instead of
    // comparing two zeros.
    uint256 constant DECOY_OUT = 4_242e18;

    function setUp() public {
        tokA = new MockERC20("A", "A");
        tokB = new MockERC20("B", "B");
        solverMock = new MockSolverQ();
        hubMock    = new MockHubQ();
        quoter = new BlazePhoenixQuoter(address(hubMock), address(solverMock));
    }

    function _leg(uint8 kind_, address pool_, uint256 amt, uint256 expectedOut_)
        internal pure returns (Leg memory l)
    {
        l = Leg({
            pool: pool_,
            hooks: address(0),
            kind: kind_,
            fee: POOL_FEE,
            tickSpacing: TICK_SP,
            zeroForOne: true,
            stable: false,
            amountIn: amt,
            expectedOut: expectedOut_,
            auxId: bytes32(0)
        });
    }

    /// One hop A -> B carrying one leg; totalOut/floor as given.
    function _route1(Leg memory l, uint256 hopIn, uint256 totalOut_)
        internal view returns (Route memory r)
    {
        Leg[] memory ls = new Leg[](1);
        ls[0] = l;
        Hop[] memory hs = new Hop[](1);
        hs[0] = Hop({
            tokenIn: address(tokA), tokenOut: address(tokB),
            amountIn: hopIn, expectedOut: 0, legs: ls
        });
        r = Route({
            hops: hs, totalOut: totalOut_, singleOut: 0, singleOutFloor: 0,
            expectedImpactBps: 0, confidenceWad: 0, estGas: 0,
            hasSurplus: false, isV4Bundle: false
        });
    }

    // =========================================================================
    //  Quoter:311 — `pv.netOut > 0` in the canExecute conjunction
    // =========================================================================

    /// The ONLY state where this sub-condition decides anything is
    /// (netOut == 0, effectiveMinOut == 0): there the other conjunct is 0 >= 0
    /// == true, and only `netOut > 0` keeps canExecute false. Both zero-yield
    /// shapes are pinned — the empty route AND a real route priced to zero —
    /// with the state coordinates asserted first, so a refactor that moves the
    /// state cannot let the flag read pass for the wrong reason. The healthy
    /// control at the end proves the flag is live (not hardwired false), so
    /// the assertFalse readings are readings, not defaults.
    function test_CanExecute_ZeroNetOutIsNotExecutable() public {
        // (a) Empty route, userMinOut 0 — the state the classify test reaches
        //     but never reads canExecute in.
        Route memory empty;
        empty.hops = new Hop[](0);
        BlazePhoenixQuoter.Preview memory pv = quoter.previewRoute(empty, 0);
        assertEq(pv.netOut, 0,          "state pin: empty route nets zero");
        assertEq(pv.effectiveMinOut, 0, "state pin: no floor of any kind");
        assertFalse(pv.canExecute, "a route netting ZERO must not preview as executable");

        // (b) Same state through a route with real topology: one hop, one leg,
        //     priced to zero. Rules out "empty is special-cased upstream".
        Route memory zeroYield = _route1(
            _leg(BPC.KIND_V3, address(uint160(0xF001)), CALL_AMT, 0), CALL_AMT, 0
        );
        pv = quoter.previewRoute(zeroYield, 0);
        assertEq(pv.netOut, 0,          "state pin: zero totalOut nets zero");
        assertEq(pv.effectiveMinOut, 0, "state pin: no floor of any kind");
        assertFalse(pv.canExecute, "a zero-yield route must not preview as executable");

        // (c) Control: positive yield, zero floor -> executable. Guards the
        //     two assertFalse above against a flag that is false everywhere.
        Route memory healthy = _route1(
            _leg(BPC.KIND_V3, address(uint160(0xF001)), CALL_AMT, 0), CALL_AMT, CALL_AMT
        );
        pv = quoter.previewRoute(healthy, 0);
        assertGt(pv.netOut, 0, "control state pin: fee+buffer leave a positive net");
        assertTrue(pv.canExecute, "control: positive net over a zero floor executes");
    }

    // =========================================================================
    //  Quoter:486 — `carry > plannedIn` in the hop-0 cap
    // =========================================================================

    /// A crafted plan whose hop 0 commits MORE than the caller's order
    /// (PLANNED = 4 * CALL_AMT). The cap must NOT fire — carry stays at the
    /// caller's amount and every leg is rescaled DOWN by carry/plannedIn.
    /// Neutralised (`if (h == 0) carry = plannedIn`), carry is inflated to
    /// PLANNED before the legs loop, and all three readings move:
    ///   hops[0].amountIn   1e18 -> 4e18   (written from carry after the loop)
    ///   legs[0].amountIn   1e18 -> 4e18   (mulDiv(PLANNED, carry, PLANNED))
    ///   exactOut           outV3(1e18) -> outV3(4e18), strictly larger.
    /// The exactOut oracle is computed at CALL_AMT — a literal of this test,
    /// not derived from the code path under mutation — so it cannot follow the
    /// inflation. The dry run is the genuine revert-extraction round trip
    /// against MockV3Pool's own arithmetic; a refusal would surface as a
    /// rescaled DECOY_OUT, ~1000x off, and fail the equality loudly, never
    /// silently.
    function test_ExactPass_UnderOrderIsNeverInflatedToPlan() public {
        MockV3Pool pool = new MockV3Pool(address(tokA), address(tokB), POOL_FEE);
        pool.setState(SQRT_P_1, LIQ);
        bool zfo = pool.token0() == address(tokA);

        Leg memory l = _leg(BPC.KIND_V3, address(pool), PLANNED, DECOY_OUT);
        l.zeroForOne = zfo;
        solverMock.setBest(_route1(l, PLANNED, 0));

        (Route memory back, uint256 exactOut) =
            quoter.previewPlanExact(address(tokA), address(tokB), CALL_AMT);

        uint256 atCallAmt = BPC.outV3(CALL_AMT, SQRT_P_1, LIQ, POOL_FEE, zfo, 0);
        assertGt(atCallAmt, 0, "sanity: the pool prices the caller's order");
        assertLt(atCallAmt, BPC.outV3(PLANNED, SQRT_P_1, LIQ, POOL_FEE, zfo, 0),
            "sanity: the two candidate readings are distinguishable");

        assertEq(back.hops[0].amountIn, CALL_AMT,
            "hop 0 must record the caller's spend, never the plan's over-commitment");
        assertEq(back.hops[0].legs[0].amountIn, CALL_AMT,
            "the leg must be rescaled down to the caller's order");
        assertEq(exactOut, atCallAmt,
            "the dry run must price the caller's amount, not the plan's");
    }
}
