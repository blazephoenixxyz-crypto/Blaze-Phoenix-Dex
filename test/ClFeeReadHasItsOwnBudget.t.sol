// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixCore as BPC} from "../src/BlazePhoenixCore.sol";
import {FeeReadWindow} from "./FeeReadWindow.sol";

// aero-nova (2026-10-26): the 2026 Aerodrome CL pools answer fee() through
// pool -> implementation -> library -> hook, and the hook recomputes the dynamic part from a TWAP
// whose binary search any caller can deepen. Measured on a Base fork: 78-178k cold per read. Under
// the shared GAS_CAP (100k) every one of those reads failed and the pool quoted 0xFFFFFF; and the
// hook wraps its observe in try/catch, so a read that starves INSIDE the hook does not fail: it
// answers the BASE fee. `getV3Fee` now runs on its own measured budget, with a guard (the whole
// budget reaches fee() or nothing is read) and a meta-guard (a read that spent what only a
// swallowed failure spends is not taken). These are the shapes, in mocks, that each of the two
// refuses, and the derivation of the four constants.

/// fee() that spends `burn` gas and answers `answer`; short of `burn`, it runs out (OOG).
contract CostlyFeePool {
    uint256 internal immutable burn;
    uint24 internal immutable answer;

    constructor(uint256 b, uint24 a) { burn = b; answer = a; }

    function fee() external view returns (uint24) {
        uint256 g = gasleft();
        uint256 stop = g > burn ? g - burn : 0;
        while (gasleft() > stop) {}
        return answer;
    }
}

/// The hook's shape in one frame: the dynamic fee comes from a call it wraps in try/catch, and a
/// starved call answers the BASE fee instead of failing.
contract SwallowingFeePool {
    uint24 internal constant BASE = 100;
    CostlyFeePool internal immutable observe;

    constructor(CostlyFeePool o) { observe = o; }

    function fee() external view returns (uint24) {
        try observe.fee() returns (uint24 f) { return f; } catch { return BASE; }
    }
}

/// One forwarding frame (pool -> implementation -> library ...): passes the call on with all it
/// may (all but 1/64, EIP-150) and hands back what comes back.
contract FeeRelay {
    address internal immutable next;

    constructor(address n) { next = n; }

    fallback() external {
        address n = next;
        assembly {
            calldatacopy(0, 0, calldatasize())
            let ok := staticcall(gas(), n, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            if iszero(ok) { revert(0, returndatasize()) }
            return(0, returndatasize())
        }
    }
}

contract FeeReadHarness {
    function read(address pool) external view returns (uint24) { return BPC.getV3Fee(pool); }

    function quote(address pool) external view returns (uint24) { return BPC.quoteV3Fee(pool, 0, 0, false); }

    /// The read's own measure, taken as getV3Fee takes it: the same opcodes around the same call.
    function spentOf(address pool, uint256 budget) external view returns (bool ok, uint256 spent) {
        assembly {
            mstore(0x00, 0xddca3f4300000000000000000000000000000000000000000000000000000000)
            let g0 := gas()
            ok := staticcall(budget, pool, 0x00, 0x04, 0x00, 0x20)
            spent := sub(g0, gas())
        }
    }
}

contract ClFeeReadHasItsOwnBudgetTest is Test {
    // The constants, re-derived from the one measured number and the window bound.
    // C: the most one read costs at the structural maximum, the cold account access and all the
    // callee consumes (Base fork, test/fork/AeroNovaFork.t.sol G3all: ring of 65 535, every
    // reachable leaf, both registry flags, the MEV-tax branch; the reader's spent, 177 670, net of
    // the reader's own 8-gas window).
    uint256 internal constant C = 177_662;
    // W: a bound on the compiled window of the Core's read (the static gas between its two GAS
    // reads; 11 in the Hub and the Solver as compiled, checked below on every build). Measured
    // with the reader's window alone (8), the derivation refused the maximum: the Core's read
    // measures 3 more (fork G5, red, log s3h-fork-g5-red.log).
    uint256 internal constant W = 64;
    // U: the most an honest read measures in the Core.
    uint256 internal constant U = C + W;
    uint256 internal constant P63 = 63 ** 5;
    uint256 internal constant P64 = 64 ** 5;
    // G = ceil((U + 1) * 64^5 / 63^5): a failure swallowed <= 5 forwards deep spent >= G * (63/64)^5.
    uint256 internal constant G = ((U + 1) * P64 + P63 - 1) / P63;
    // T = floor(G * 63^5 / 64^5): spent this much or more, the answer is not taken.
    uint256 internal constant T = G * P63 / P64;
    // FLOOR = G * 64 / 63 + 3_000: what a frame holds for the whole budget to reach fee().
    uint256 internal constant FLOOR = G * 64 / 63 + 3_000;

    uint24 internal constant DYNAMIC = 3000;
    uint24 internal constant BASE = 100;

    FeeReadHarness internal h;

    function setUp() public {
        h = new FeeReadHarness();
    }

    function _swallower(uint256 innerBurn) internal returns (SwallowingFeePool) {
        return new SwallowingFeePool(new CostlyFeePool(innerBurn, DYNAMIC));
    }

    /// The pool the old cap could not read: 150k is inside the measured 78-178k.
    function test_AFeeReadInsideTheMeasuredCostIsAnswered() public {
        CostlyFeePool p = new CostlyFeePool(150_000, DYNAMIC);
        assertEq(h.read(address(p)), DYNAMIC, "a 150k fee() must be read");
        assertEq(h.quote(address(p)), DYNAMIC, "and quoted at its fee, not skipped");
    }

    /// Past the budget: the pool is skipped (0 -> 0xFFFFFF), the call does not revert.
    function test_AFeeReadPastTheBudgetIsSkippedNotReverted() public {
        CostlyFeePool p = new CostlyFeePool(250_000, DYNAMIC);
        assertEq(h.read(address(p)), 0, "a fee() past the budget answers nothing");
        assertEq(h.quote(address(p)), 0xFFFFFF, "and the pool is skipped");
    }

    /// META-GUARD. The hook's observe starves inside the budget and the hook answers BASE: the
    /// read succeeded, answered 32 bytes, and is wrong. What gives it away is what it spent.
    function test_ASwallowedFailureIsNotTaken() public {
        SwallowingFeePool p = _swallower(250_000);
        (bool ok, uint256 spent) = h.spentOf(address(p), G);
        assertTrue(ok, "the swallowing pool answers");
        assertGe(spent, T, "a swallowed failure spends at least T");
        assertEq(h.read(address(p)), 0, "its BASE answer is not taken");
        assertEq(h.quote(address(p)), 0xFFFFFF, "the pool is skipped");
    }

    /// The same, five forwards deep (the Aerodrome chain: the hook's observe is the 4th forward,
    /// the pool's implementation the 5th). Each frame keeps at most 1/64, so the swallowed OOG
    /// still spent G * (63/64)^5 >= T. Depth 6 is outside this proof (reported residual).
    function test_ASwallowedFailureFiveForwardsDeepIsNotTaken() public {
        address p = address(_swallower(250_000));
        for (uint256 i; i < 4; ++i) p = address(new FeeRelay(p));
        (bool ok, uint256 spent) = h.spentOf(p, G);
        assertTrue(ok, "the relayed pool answers");
        assertGe(spent, T, "five forwards deep, a swallowed failure still spends at least T");
        assertEq(h.read(p), 0, "its BASE answer is not taken");
    }

    /// The threshold, from both sides, on an honest (non-swallowing) pool: just under T is
    /// answered (the measured maximum must stay readable), just over is not.
    function test_TheTrustThresholdSitsWhereTheDerivationPutsIt() public {
        CostlyFeePool probe = new CostlyFeePool(100_000, DYNAMIC);
        vm.cool(address(probe));
        (, uint256 s0) = h.spentOf(address(probe), G);
        uint256 over = s0 - 100_000; // the frame's cost beyond its burn, cold

        CostlyFeePool under = new CostlyFeePool(T - 600 - over, DYNAMIC);
        vm.cool(address(under));
        (bool okU, uint256 sU) = h.spentOf(address(under), G);
        assertTrue(okU && sU < T && sU + 1_500 >= T, "calibration: just under T");
        vm.cool(address(under));
        assertEq(h.read(address(under)), DYNAMIC, "an honest read just under T is taken");

        CostlyFeePool past = new CostlyFeePool(T + 600 - over, DYNAMIC);
        vm.cool(address(past));
        (bool okP, uint256 sP) = h.spentOf(address(past), G);
        assertTrue(okP && sP >= T && sP <= T + 1_500, "calibration: just over T");
        vm.cool(address(past));
        assertEq(h.read(address(past)), 0, "a read that spent T or more is not taken");
    }

    /// GUARD. The caller's gas never chooses the answer: a starved budget would starve the hook's
    /// observe and answer BASE. Over every caller gas, the read reverts or answers the dynamic fee.
    function test_TheCallerGasNeverChangesTheAnswer() public {
        address p = address(_swallower(120_000));
        bool sawRevert;
        bool sawFee;
        for (uint256 g = 120_000; g <= 300_000; g += 500) {
            (bool ok, bytes memory r) = address(h).call{gas: g}(abi.encodeCall(FeeReadHarness.read, (p)));
            if (!ok) { sawRevert = true; continue; }
            uint24 f = abi.decode(r, (uint24));
            assertEq(f, DYNAMIC, "a starved budget answered the BASE fee");
            sawFee = true;
        }
        assertTrue(sawRevert && sawFee, "both outcomes must be reached");
    }

    /// GUARD, exact: fee() receives the whole budget or is not called. The echo answers the gas
    /// it was handed (GAS costs 2), read cold, the tight case (2_600 for the account access).
    function test_TheWholeBudgetReachesFeeOrNothingIsRead() public {
        address echo = address(0xEC40);
        vm.etch(echo, hex"5A60005260206000F3"); // GAS PUSH1 0 MSTORE PUSH1 32 PUSH1 0 RETURN
        bool sawRevert;
        bool sawFee;
        for (uint256 g = FLOOR - 3_000; g <= FLOOR + 3_000; g += 10) {
            vm.cool(echo);
            (bool ok, bytes memory r) = address(h).call{gas: g}(abi.encodeCall(FeeReadHarness.read, (echo)));
            if (!ok) { sawRevert = true; continue; }
            assertEq(abi.decode(r, (uint24)), G - 2, "fee() was handed less than the budget");
            sawFee = true;
        }
        assertTrue(sawRevert && sawFee, "both outcomes must be reached");
    }

    /// The derivation, and that it is the least budget that keeps the measured maximum readable
    /// in any compiled read whose window fits the bound.
    function test_TheBudgetIsDerivedAndMinimal() public pure {
        assertGt(T, U, "the measured maximum must stay below the trust threshold");
        assertLe((G - 1) * P63 / P64, U, "one gas less and the maximum would be refused");
        // At the floor, after a cold account access (2_600) and 100 gas of opcodes, the call can
        // still forward the whole budget (all but 1/64 of what is left). Measured exactly by
        // test_TheWholeBudgetReachesFeeOrNothingIsRead.
        uint256 left = FLOOR - 2_600 - 100;
        assertGe(left - left / 64, G, "the floor covers the budget");
    }

    // RED-STRIP-BEGIN: the constants do not exist before the fix.
    /// META-GUARD of the measurement. The derivation holds for a read whose window is at most
    /// CL_FEE_WINDOW; the window is the compiler's choice, so every compiled instance of the read
    /// is found in the runtime code and priced, on every build.
    function test_EveryCompiledReadFitsTheWindowBound() public view {
        // The Core library's own instance (DELEGATECALL) is the one universalQuote,
        // legQuoteImpact and v4WalkOut read through.
        string[3] memory names = [
            "BlazePhoenixHub.sol:BlazePhoenixHub",
            "BlazePhoenixSolver.sol:BlazePhoenixSolver",
            "BlazePhoenixCore.sol:BlazePhoenixCore"
        ];
        for (uint256 i; i < 3; ++i) {
            (uint256 sites, uint256 widest) = FeeReadWindow.scan(vm.getDeployedCode(names[i]), BPC.CL_FEE_GAS);
            assertGe(sites, 1, string.concat(names[i], ": the measured fee read is in the code"));
            assertLe(widest, BPC.CL_FEE_WINDOW, string.concat(names[i], ": a read window past the bound"));
        }
        // The harness's own instance, the one the tests above exercise.
        (uint256 hs, uint256 hw) = FeeReadWindow.scan(address(h).code, BPC.CL_FEE_GAS);
        assertTrue(hs >= 1 && hw <= BPC.CL_FEE_WINDOW, "harness: a read window past the bound");
    }

    function test_TheCoreCarriesTheDerivedConstants() public pure {
        assertEq(BPC.CL_FEE_COST, C, "CL_FEE_COST");
        assertEq(BPC.CL_FEE_WINDOW, W, "CL_FEE_WINDOW");
        assertEq(BPC.CL_FEE_SPENT, U, "CL_FEE_SPENT");
        assertEq(BPC.CL_FEE_GAS, G, "CL_FEE_GAS");
        assertEq(BPC.CL_FEE_TRUST, T, "CL_FEE_TRUST");
        assertEq(BPC.CL_FEE_FLOOR, FLOOR, "CL_FEE_FLOOR");
    }
    // RED-STRIP-END
}
