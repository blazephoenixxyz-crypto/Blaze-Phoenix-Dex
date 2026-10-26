// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  A HOP BUILD READS EACH TOKEN'S DECIMALS ONCE.
//
//  `_buildHop` reads `decimals()` of its two tokens once and hands them, +1
//  encoded, to the quotes of the pair in `QuoteCtx.decIn1` / `decOther1` (its
//  DECIMALS HOISTING note: "once per pair"). Three of its quote sites did not:
//  the per-leg quotes of the split, the full-size singles of the min-split
//  gate, and the single leg a band of one collapses to went through `_quote`,
//  which passed 0 ("not filled"), so the Core read both tokens again on every
//  one of them (`Core._decIn` / `_decOther` read a token whose field is 0).
//
//  The decimals only feed the depth, and `_quote` discards the depth, so
//  handing them in changes no figure of the plan: the figures are pinned by
//  the rest of the suite, and a Base mainnet fork run on nineteen reference
//  pairs returned the same plan, bit for bit, before and after (2026-10-26).
//
//  The census is the Solver's own: STATICCALLs to `decimals()` made by the
//  Solver (the Core runs delegatecalled in its context). The Hub's registry
//  reads are not counted. One direct pair, no bridges: one hop build.
//
//  Red on 1d9c610 (before the fix): the split read each token's decimals 7
//  times, the band of one 2 times.
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixCore as BPC, RoutePlan} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";

contract DecimalsReadOncePerHopTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    MockERC20 A;
    MockERC20 B;

    uint256 constant ORDER = 1e20;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        solver = new BlazePhoenixSolver(address(hub), address(0));
        A = new MockERC20("A", "A");
        B = new MockERC20("B", "B");
    }

    function _pool(uint256 rA, uint256 rB) internal {
        MockV2Pair p = new MockV2Pair(address(A), address(B));
        A.mint(address(p), rA);
        B.mint(address(p), rB);
        (uint256 r0, uint256 r1) = address(A) < address(B) ? (rA, rB) : (rB, rA);
        p.setReserves(uint112(r0), uint112(r1));
        hub.seedPool(address(p), BPC.KIND_V2, 30, address(0), address(A), address(B));
    }

    /// The Solver's `decimals()` reads of `t` in the recorded accesses.
    function _reads(VmSafe.AccountAccess[] memory recs, address t) internal view returns (uint256 c) {
        for (uint256 i; i < recs.length; ++i) {
            VmSafe.AccountAccess memory r = recs[i];
            if (
                r.kind == VmSafe.AccountAccessKind.StaticCall && r.account == t
                    && r.accessor == address(solver) && r.data.length >= 4
                    && bytes4(r.data) == bytes4(0x313ce567)
            ) ++c;
        }
    }

    function _solve() internal returns (RoutePlan memory plan, uint256 a, uint256 b) {
        vm.startStateDiffRecording();
        plan = solver.findBestRoutePlan(address(A), address(B), ORDER);
        VmSafe.AccountAccess[] memory recs = vm.stopAndReturnStateDiff();
        a = _reads(recs, address(A));
        b = _reads(recs, address(B));
        emit log_named_uint("decimals(tIn) reads ", a);
        emit log_named_uint("decimals(tOut) reads", b);
    }

    /// Three pools inside the band (test/SplitGateSeesEverySurvivor.t.sol's book): the split
    /// quotes each of its legs, and the gate quotes every survivor at full size.
    function test_ASplitReadsEachTokensDecimalsOnce() public {
        _pool(1e24, 985e21);
        _pool(1e22, 101e20);
        _pool(1e21, 103e19);
        (RoutePlan memory plan, uint256 a, uint256 b) = _solve();
        assertGt(plan.best.totalOut, 0, "setup: the pair must route");
        assertEq(a, 1, "one hop build read decimals(tIn) more than once");
        assertEq(b, 1, "one hop build read decimals(tOut) more than once");
    }

    /// Two candidates, the shallow one 20% off the deep one's price: the band keeps one, and
    /// the hop is that single leg (`nKept == 1`), after the hoisted read.
    function test_ABandOfOneReadsEachTokensDecimalsOnce() public {
        _pool(1e24, 1e24);
        _pool(1e22, 8e21);
        (RoutePlan memory plan, uint256 a, uint256 b) = _solve();
        assertEq(plan.best.hops[0].legs.length, 1, "setup: the band must keep one pool");
        assertEq(a, 1, "one hop build read decimals(tIn) more than once");
        assertEq(b, 1, "one hop build read decimals(tOut) more than once");
    }
}
