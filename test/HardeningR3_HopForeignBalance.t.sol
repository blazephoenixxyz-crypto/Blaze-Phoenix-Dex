// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  R3 / BP-15 regression — hop continuity + foreign-balance exclusion
//  (BlazePhoenixRouter._execute), invariant I1 "holds-nothing".
//
//  ATTACK (pre-fix): hop 1+ rescaled its legs against a fresh balanceOf() of
//  hop.tokenIn — the WHOLE Router balance. Nothing forced hop.tokenIn to be the
//  token the previous hop actually produced, so a crafted DISCONTINUOUS route
//  named any stranded/mis-sent token the Router happened to hold as
//  hops[1].tokenIn, sized leg.amountIn to that balance, and scaled funds the
//  48h timelocked rescue exists to return straight into the swap — delivered
//  to the attacker as output. Capping scaleNum to scaleDen does not close it
//  (the attacker sizes scaleDen to the stranded balance); and even on an
//  HONEST continuous route, a pre-swap ("foreign") balance of the bridge
//  token was folded into hop 1's realIn and spent.
//
//  THE FIX (two halves, both pinned here):
//    1. Continuity: for h != 0, hop.tokenIn == route.hops[h-1].tokenOut,
//       else revert RouterE(3) — so the pre-swap balance of the token being
//       scaled is always known (bridgeBase[h-1] baselines exactly that token).
//    2. Foreign-balance exclusion: hop 1+ scaleNum = balanceOf(tokenIn) MINUS
//       foreignBase (the Router's pre-swap balance of that bridge token), so
//       only what THIS swap's previous hop produced is ever scaled into the
//       legs. The foreign balance is left untouched on the Router for the
//       rescue path — never converted into output, never handed to a caller.
//
//  These tests fail on the pre-fix code (discontinuous route executes and
//  drains the stranded token / foreign balance inflates the fill) and pass on
//  the fix.
//
//  forge test --match-contract HardeningR3HopForeignBalance -vv
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";

contract HardeningR3HopForeignBalanceTest is Test {
    BlazePhoenixHub    hub;
    BlazePhoenixSolver solver;
    BlazePhoenixRouter router;

    MockERC20 A; // route tokenIn
    MockERC20 B; // route tokenOut
    MockERC20 C; // honest intermediate/bridge token
    MockERC20 T; // STRANDED token: mis-sent to the Router, awaiting rescue

    // Two IDENTICAL pool sets so the foreign-balance run can be compared
    // against a baseline run with the exact same pre-swap pool state.
    MockV2Pair pAC1;
    MockV2Pair pCB1;
    MockV2Pair pAC2;
    MockV2Pair pCB2;
    MockV2Pair pTB; // venue the crafted discontinuous hop names for T -> B
    MockV2Pair pAB; // venue the crafted discontinuous hop names for A -> B

    address user      = makeAddr("user");
    address treasury1 = makeAddr("treasury1");
    address treasury2 = makeAddr("treasury2");

    uint112 constant RESERVE  = 1e30;      // deep quote-side reserves (~1:1)
    uint256 constant LIQ      = 1e30;      // real payout funding per pair
    uint256 constant AMT      = 1_000e18;  // honest 2-hop order size
    uint256 constant FOREIGN  = 5_000e18;  // pre-swap bridge balance on Router
    uint256 constant STRANDED = 7_500e18;  // mis-sent T balance on Router

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        solver = new BlazePhoenixSolver(address(hub));
        router = new BlazePhoenixRouter(
            address(hub), address(solver), address(this), treasury1, treasury2);

        A = new MockERC20("A", "A");
        B = new MockERC20("B", "B");
        C = new MockERC20("C", "C");
        T = new MockERC20("T", "T");

        pAC1 = new MockV2Pair(address(A), address(C));
        pCB1 = new MockV2Pair(address(C), address(B));
        pAC2 = new MockV2Pair(address(A), address(C));
        pCB2 = new MockV2Pair(address(C), address(B));
        pTB  = new MockV2Pair(address(T), address(B));
        pAB  = new MockV2Pair(address(A), address(B));
        pAC1.setReserves(RESERVE, RESERVE); // quote-only bookkeeping; payouts are
        pCB1.setReserves(RESERVE, RESERVE); // funded per-test via mint, exactly
        pAC2.setReserves(RESERVE, RESERVE); // as the multi-hop handler does
        pCB2.setReserves(RESERVE, RESERVE);
        pTB.setReserves(RESERVE, RESERVE);
        pAB.setReserves(RESERVE, RESERVE);

        A.mint(user, 10 * AMT);
        vm.prank(user);
        A.approve(address(router), type(uint256).max);
    }

    // ── route builders (mirrors MultiHopHandler._hop) ────────────────────────

    function _hop(address tin, address tout, address pool, uint256 amt, uint256 quoted)
        internal view returns (Hop memory h)
    {
        bool zfo = tin == MockV2Pair(pool).token0();
        Leg[] memory legs = new Leg[](1);
        legs[0] = Leg({
            pool: pool, hooks: address(0), kind: BPC.KIND_V2, fee: 30, tickSpacing: 0,
            zeroForOne: zfo, stable: false, amountIn: amt, expectedOut: quoted, auxId: bytes32(0)
        });
        h = Hop({tokenIn: tin, tokenOut: tout, amountIn: amt, expectedOut: quoted, legs: legs});
    }

    function _route(Hop[] memory hops, uint256 quoted) internal pure returns (Route memory r) {
        r = Route({
            hops: hops, totalOut: quoted, singleOut: quoted, singleOutFloor: 0,
            expectedImpactBps: 0, confidenceWad: 0, estGas: 0, hasSurplus: false, isV4Bundle: false
        });
    }

    /// @dev Honest continuous A -> C -> B route over the given pool set.
    function _honestRoute(MockV2Pair pAC, MockV2Pair pCB) internal view returns (Route memory) {
        Hop[] memory hops = new Hop[](2);
        hops[0] = _hop(address(A), address(C), address(pAC), AMT, AMT);
        hops[1] = _hop(address(C), address(B), address(pCB), AMT, AMT);
        return _route(hops, AMT);
    }

    function _fund(MockV2Pair pAC, MockV2Pair pCB) internal {
        C.mint(address(pAC), LIQ); // pAC pays out C
        B.mint(address(pCB), LIQ); // pCB pays out B
    }

    // ── (a) discontinuous routes revert RouterE(3) ───────────────────────────

    /// The original attack shape: the Router holds a mis-sent balance of T
    /// (rescue-path money). A crafted route runs an honest first hop A -> C,
    /// then names T — NOT C — as hops[1].tokenIn with leg.amountIn sized to the
    /// stranded balance. Pre-fix, hop 1's rescale read balanceOf(T) and spent
    /// the whole stranded balance into pTB, delivering it to the attacker as B.
    /// Post-fix the discontinuity itself reverts RouterE(3) before hop 1 runs.
    function test_Discontinuous_StrandedTokenHop_RevertsRouterE3() public {
        T.mint(address(router), STRANDED);   // mis-sent funds awaiting rescue
        _fund(pAC1, pCB1);                   // hop 0 must be executable: the
        B.mint(address(pTB), LIQ);           // check fires at h == 1, after it
        assertEq(T.balanceOf(address(router)), STRANDED, "setup: stranded T on Router");

        Hop[] memory hops = new Hop[](2);
        hops[0] = _hop(address(A), address(C), address(pAC1), AMT, AMT);
        hops[1] = _hop(address(T), address(B), address(pTB), STRANDED, STRANDED); // T != C
        Route memory r = _route(hops, STRANDED);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, uint16(3)));
        router.swapExactIn(r, AMT, 1, user, block.timestamp + 1);

        // The whole call reverted: the stranded balance never moved.
        assertEq(T.balanceOf(address(router)), STRANDED, "stranded T must be untouched");
        assertEq(B.balanceOf(user), 0, "attacker must receive nothing");
    }

    /// Discontinuity variant with a familiar token: hops[1].tokenIn is the
    /// route's own tokenIn A (still != hops[0].tokenOut C). Pre-fix this shape
    /// scaled the Router's residual/pre-existing A balance into a second spend;
    /// post-fix the chain break reverts RouterE(3) regardless of which token
    /// the crafted hop names.
    function test_Discontinuous_ReusedInputTokenHop_RevertsRouterE3() public {
        _fund(pAC1, pCB1);
        B.mint(address(pAB), LIQ);

        Hop[] memory hops = new Hop[](2);
        hops[0] = _hop(address(A), address(C), address(pAC1), AMT, AMT);
        hops[1] = _hop(address(A), address(B), address(pAB), AMT, AMT); // A != C
        Route memory r = _route(hops, AMT);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, uint16(3)));
        router.swapExactIn(r, AMT, 1, user, block.timestamp + 1);
    }

    // ── (b) foreign bridge balance is never scaled into an honest swap ───────

    /// Two byte-identical honest 2-hop swaps over two identical fresh pool
    /// sets. Between them, FOREIGN units of the bridge token C are mis-sent to
    /// the Router. Pre-fix, hop 1's realIn = balanceOf(C) folded FOREIGN into
    /// the rescale and the second fill came out larger — rescue-path money
    /// converted into the caller's output. Post-fix, foreignBase (== the
    /// bridgeBase[0] snapshot of C taken at entry) is subtracted, so:
    ///   * delivered output EQUALS the no-foreign-balance baseline, and
    ///   * the foreign C stays on the Router, byte-for-byte, for the 48h
    ///     rescue — mirroring the bridge residual sweep's baseline (I1).
    function test_ForeignBridgeBalance_NotScaledIntoOutput_EqualsBaseline() public {
        // Baseline: no foreign balance, pool set 1.
        _fund(pAC1, pCB1);
        // Build the route BEFORE vm.prank: _honestRoute makes token0() view
        // calls that would otherwise consume the prank, leaving swapExactIn
        // to run as the test contract (no balance/approval).
        Route memory r1 = _honestRoute(pAC1, pCB1);
        uint256 bBefore = B.balanceOf(user);
        vm.prank(user);
        uint256 out1 = router.swapExactIn(r1, AMT, 1, user, block.timestamp + 1);
        uint256 delivered1 = B.balanceOf(user) - bBefore;
        assertGt(out1, 0, "baseline swap must fill");
        assertEq(C.balanceOf(address(router)), 0, "I1 at rest: no bridge C after baseline");

        // Mis-send FOREIGN bridge tokens to the Router (rescue-path money).
        C.mint(address(router), FOREIGN);

        // Identical swap, identical fresh pool set 2, with the foreign balance
        // sitting on the Router.
        _fund(pAC2, pCB2);
        Route memory r2 = _honestRoute(pAC2, pCB2); // built before the prank (same footgun)
        bBefore = B.balanceOf(user);
        vm.prank(user);
        uint256 out2 = router.swapExactIn(r2, AMT, 1, user, block.timestamp + 1);
        uint256 delivered2 = B.balanceOf(user) - bBefore;

        // The pin: the foreign balance bought the caller NOTHING extra. Pre-fix
        // both of these fail — hop 1 spent outC + FOREIGN into pCB2, so the
        // fill (and the user's delivered B) came out strictly larger.
        assertEq(out2, out1, "foreign bridge balance must not change the fill");
        assertEq(delivered2, delivered1, "delivered output must equal the no-foreign baseline");

        // And it never left the Router: not swapped, not swept to the caller —
        // it is exactly the pre-swap balance the timelocked rescue returns.
        assertEq(C.balanceOf(address(router)), FOREIGN, "foreign C must remain for the rescue path");
        assertEq(A.balanceOf(address(router)), 0, "I1: no input token at rest");
        assertEq(B.balanceOf(address(router)), 0, "I1: no output token at rest");
    }
}
