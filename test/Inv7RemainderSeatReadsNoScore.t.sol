// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  INV-7 @ d96c32b53f626694beda7da9393a8b86cebdb647
//
//  Claim (whitepaper-v2.2 App. B, §9.6): "Ψ ranks and truncates candidates; no
//  quote, floor or allocation reads it." / "The registry decides what is seen;
//  it has no vote on what is paid."
//
//  Channel: `_topKPools` (Solver:1395-1425) emits the KEPT set in Ψ order.
//  `_buildHop` gives the LAST position the remainder (Solver:795-800), and the
//  input-side phantom cut (Solver:858-861) returns freed input to that
//  remainder. So Ψ picks which venue absorbs the freed input.
//
//  Two histories run the SAME dust trades on the SAME four pools. Only the time
//  of the trades differs. Reserves, balances, depth buckets and the candidate
//  set end identical; only Ψ differs. The next 100 X order is then paid a
//  different amount.
//
//  Run:
//  Reported by Seavia Resources through the bug bounty programme; this file is
//  their proof of concept. Since 2026-10-07 the remainder seat goes to the
//  deepest survivor by measured weight (ties to the lowest address), so the two
//  histories pay alike and INV-7 holds: no quote, floor or allocation reads psi.
//
//    forge test --match-path 'test/Inv7RemainderSeatReadsNoScore.t.sol' -vv
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg, RoutePlan} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";
import {MockV3Pool} from "./mocks/MockV3Pool.sol";

contract Inv7RemainderSeatReadsNoScoreTest is Test {
    BlazePhoenixHub    hub;
    BlazePhoenixSolver solver;
    BlazePhoenixRouter router;
    MockERC20 X;               // 1 X = 2000 Y
    MockERC20 Y;
    MockV2Pair D1;             // 600 X / 1.2M Y
    MockV2Pair D2;             // 400 X / 0.8M Y
    MockV2Pair T;              //  20 X /  40k Y
    MockV3Pool V;              // concentrated, holds 10k Y + 5 X
    address constant USER   = address(0xBEEF);
    address constant TRADER = address(0xD057);

    uint256 constant ORDER = 100e18;
    uint256 constant DUST  = 1e15;
    uint256 constant M     = 6;          // dust trades per pool, both histories
    uint256 constant GAP   = 4 days;     // 14 decay steps of 24,576 s
    bool noV;                            // V drained: no dust trade can route through it

    struct End {
        uint256 delivered;
        uint256 spent;
        uint256 totalOut;
        uint256 floorOut;
        bytes32 reserves;
        bytes32 buckets;
        uint256 psiD1; uint256 psiD2; uint256 psiT; uint256 psiV;
        address lastLeg;
        uint256 lastLegIn;
        uint256 legs;
    }

    function _sqrt(uint256 y) internal pure returns (uint256 z) {
        if (y > 3) { z = y; uint256 x = y / 2 + 1; while (x < z) { z = x; x = (y / x + x) / 2; } }
        else if (y != 0) z = 1;
    }

    function _pair(uint256 x, uint256 y) private returns (MockV2Pair p) {
        p = new MockV2Pair(address(X), address(Y));
        X.mint(address(p), x); Y.mint(address(p), y);
        (uint112 r0, uint112 r1) = address(X) < address(Y) ? (uint112(x), uint112(y)) : (uint112(y), uint112(x));
        p.setReserves(r0, r1);
        hub.seedPool(address(p), BPC.KIND_V2, 30, address(0), address(X), address(Y));
    }

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        solver = new BlazePhoenixSolver(address(hub));
        router = new BlazePhoenixRouter(address(hub), address(solver), address(this), address(0xFEE1), address(0xFEE2));
        hub.setRoles(address(router), address(solver), address(this));
        X = new MockERC20("X", "X");
        Y = new MockERC20("Y", "Y");
        D1 = _pair(600e18, 1_200_000e18);
        D2 = _pair(400e18,   800_000e18);
        T  = _pair( 20e18,    40_000e18);
        V = new MockV3Pool(address(X), address(Y), 500);
        uint256 sp = address(X) < address(Y)
            ? _sqrt(2000 << 192)
            : _sqrt((uint256(1) << 192) / 2000);
        V.setState(uint160(sp), 1e25);
        X.mint(address(V), 5e18);
        Y.mint(address(V), 10_000e18);
        hub.seedPool(address(V), BPC.KIND_V3, 500, address(0), address(X), address(Y));

        X.mint(USER, 1_000e18);
        vm.prank(USER); X.approve(address(router), type(uint256).max);
        X.mint(TRADER, 1_000e18);
        vm.prank(TRADER); X.approve(address(router), type(uint256).max);
    }

    // ─── a permissionless dust trade through one named pool ───
    function _dust(address pool, uint8 kind, uint24 fee) private {
        Leg[] memory legs = new Leg[](1);
        legs[0] = Leg({pool: pool, hooks: address(0), kind: kind, fee: fee, tickSpacing: 0,
            zeroForOne: address(X) < address(Y), stable: false,
            amountIn: DUST, expectedOut: 0, auxId: bytes32(0)});
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({tokenIn: address(X), tokenOut: address(Y), amountIn: DUST, expectedOut: 0, legs: legs});
        Route memory r = Route({hops: hops, totalOut: 0, singleOut: 0, singleOutFloor: 0,
            expectedImpactBps: 0, confidenceWad: 0, estGas: 0, hasSurplus: false, isV4Bundle: false});
        vm.prank(TRADER);
        router.swapExactIn(r, DUST, 1, TRADER, type(uint256).max);
    }

    function _trades(address pool) private {
        (uint8 k, uint24 f) = pool == address(V) ? (BPC.KIND_V3, uint24(500)) : (BPC.KIND_V2, uint24(30));
        for (uint256 i; i < M; i++) _dust(pool, k, f);
    }

    /// @dev `early` gets its M trades at t0; every other pool gets its M trades at t0 + GAP.
    function _history(address early) private {
        uint256 t0 = vm.getBlockTimestamp();
        _trades(early);
        vm.warp(t0 + GAP);
        address[4] memory ps = [address(D1), address(D2), address(T), address(V)];
        for (uint256 i; i < 4; i++) if (ps[i] != early && !(noV && ps[i] == address(V))) _trades(ps[i]);
    }

    function _psi(address p) private view returns (uint256) { return hub.getPsi(p, address(X), address(Y)); }
    function _bucket(address p) private view returns (uint256) {
        return BPC.decodeBucket(hub.getSlot(hub.keyOf(p, address(X), address(Y))));
    }

    function _end() private returns (End memory e) {
        e.reserves = keccak256(abi.encode(
            X.balanceOf(address(D1)), Y.balanceOf(address(D1)), X.balanceOf(address(D2)), Y.balanceOf(address(D2)),
            X.balanceOf(address(T)),  Y.balanceOf(address(T)),  X.balanceOf(address(V)),  Y.balanceOf(address(V))));
        e.buckets = keccak256(abi.encode(_bucket(address(D1)), _bucket(address(D2)), _bucket(address(T)), _bucket(address(V))));
        e.psiD1 = _psi(address(D1)); e.psiD2 = _psi(address(D2)); e.psiT = _psi(address(T)); e.psiV = _psi(address(V));
        RoutePlan memory p = solver.findBestRoutePlan(address(X), address(Y), ORDER);
        e.totalOut = p.best.totalOut;
        e.floorOut = p.best.singleOutFloor;
        Leg[] memory legs = p.best.hops[0].legs;
        e.legs = legs.length;
        e.lastLeg = legs[legs.length - 1].pool;
        e.lastLegIn = legs[legs.length - 1].amountIn;
        uint256 x0 = X.balanceOf(USER);
        vm.prank(USER);
        e.delivered = router.swapBestExactIn(address(X), address(Y), ORDER, 1, USER, type(uint256).max);
        e.spent = x0 - X.balanceOf(USER);
    }

    function _name(address p) private view returns (string memory) {
        return p == address(D1) ? "D1" : p == address(D2) ? "D2" : p == address(T) ? "T" : p == address(V) ? "V" : "?";
    }

    function _log(string memory tag, End memory e) private {
        emit log_string(tag);
        emit log_named_uint("  psi D1", e.psiD1);
        emit log_named_uint("  psi D2", e.psiD2);
        emit log_named_uint("  psi T ", e.psiT);
        emit log_named_uint("  psi V ", e.psiV);
        emit log_named_uint("  legs in plan", e.legs);
        emit log_named_string("  last leg", _name(e.lastLeg));
        emit log_named_uint("  last leg amountIn", e.lastLegIn);
        emit log_named_uint("  plan totalOut", e.totalOut);
        emit log_named_uint("  plan floor   ", e.floorOut);
        emit log_named_uint("  DELIVERED Y  ", e.delivered);
        emit log_named_uint("  X spent      ", e.spent);
    }

    function _both(address earlyA, address earlyB) private returns (End memory a, End memory b) {
        uint256 s = vm.snapshotState();
        _history(earlyA);
        a = _end();
        vm.revertToState(s);
        _history(earlyB);
        b = _end();
    }

    // =========================================================================
    //  PoC — RED at the pin, GREEN under the fix.
    // =========================================================================

    /// Same trades, same pools, same end state. Only WHEN the trades happened
    /// differs: in A, D1 traded early (its Ψ has decayed), in B, T traded early.
    function test_INV7_SameTradesDifferentTiming_PayDifferently() public {
        (End memory a, End memory b) = _both(address(D1), address(T));
        _log("A: D1 traded early", a);
        _log("B: T traded early ", b);

        // Isolation: nothing the allocator is allowed to read differs.
        assertEq(a.reserves, b.reserves, "isolation: every pool holds the same tokens");
        assertEq(a.buckets,  b.buckets,  "isolation: every depth bucket is the same");
        assertTrue(a.psiD1 != b.psiD1 && a.psiT != b.psiT, "only the score differs");

        emit log_named_int("delivered A - B (Y wei)", int256(a.delivered) - int256(b.delivered));
        // INV-7: Ψ has no vote on what is paid.
        assertEq(a.delivered, b.delivered, "INV-7: the same order is paid differently by score alone");
        assertEq(a.totalOut,  b.totalOut,  "INV-7: the quote read the score");
        assertEq(a.floorOut,  b.floorOut,  "INV-7: the floor read the score");
    }

    /// Control: with no phantom cut the score still moves the remainder seat (D1 vs T
    /// below), but the remainder is rounding dust and the payout is identical.
    function test_control_NoPhantomCut_ScoreMovesOnlyDust() public {
        // Drop V from the candidate set (Hub eviction is not operator-reachable; drain its
        // tokenOut so the band/cap drops it: a zero cap drops the leg at Solver:866).
        uint256 heldV = Y.balanceOf(address(V));
        vm.prank(address(V)); Y.transfer(address(0xdead), heldV);
        noV = true;
        (End memory a, End memory b) = _both(address(D1), address(T));
        _log("A (V2 only)", a);
        _log("B (V2 only)", b);
        assertEq(a.reserves, b.reserves, "isolation: same holdings");
        assertEq(a.buckets,  b.buckets,  "isolation: same buckets");
        assertEq(a.delivered, b.delivered, "no freed input: the seat carries only dust");
    }

    // =========================================================================
    //  Controls — GREEN at the pin.
    // =========================================================================

    /// Two histories whose scores and whose candidate ORDER differ, but whose
    /// lowest-score seat (the remainder seat) is the same venue, are paid to the
    /// wei: the whole effect is the remainder seat, which is what the fix pins.
    function test_control_SameRemainderSeat_SamePayout() public {
        uint256 s = vm.snapshotState();
        _history(address(D1));
        End memory a = _end();
        vm.revertToState(s);
        // Same trades again; T now trades one decay step before the end, so its
        // score halves and it drops below V. D1 still scores lowest.
        uint256 t0 = vm.getBlockTimestamp();
        _trades(address(D1));
        vm.warp(t0 + GAP - 24_576 - 1);
        _trades(address(T));
        vm.warp(t0 + GAP);
        _trades(address(D2));
        _trades(address(V));
        End memory c = _end();
        _log("A: D1 early", a);
        _log("C: D1 early, T one step early", c);
        assertEq(a.reserves, c.reserves, "isolation: same holdings");
        assertTrue(a.psiT > a.psiV && c.psiT < c.psiV, "the candidate order really changed");
        assertTrue(a.psiD1 < a.psiT && c.psiD1 < c.psiT && c.psiD1 < c.psiV && c.psiD1 < c.psiD2,
            "D1 holds the remainder seat in both");
        assertEq(a.delivered, c.delivered, "same remainder seat, same payout");
    }

    /// The payout is live: moving REAL mass (not the score) moves it.
    function test_control_RealMassMovesThePayout() public {
        uint256 s = vm.snapshotState();
        End memory a = _end();
        vm.revertToState(s);
        X.mint(address(D1), 600e18); Y.mint(address(D1), 1_200_000e18);
        (uint112 r0, uint112 r1) = address(X) < address(Y)
            ? (uint112(1_200e18), uint112(2_400_000e18)) : (uint112(2_400_000e18), uint112(1_200e18));
        D1.setReserves(r0, r1);
        End memory b = _end();
        assertGt(b.delivered, a.delivered, "real mass moves the payout");
    }

    /// The honest path settles in both histories and both clear the protocol's own floor.
    function test_control_BothHistoriesSettleAboveTheirFloor() public {
        (End memory a, End memory b) = _both(address(D1), address(T));
        assertApproxEqAbs(a.spent, ORDER, 10, "A spends the whole order");
        assertApproxEqAbs(b.spent, ORDER, 10, "B spends the whole order");
        assertGe(a.delivered, a.floorOut, "A clears its floor");
        assertGe(b.delivered, b.floorOut, "B clears its floor");
    }
}
