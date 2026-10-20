// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// FUSION 1 (2026-10-20) - ONE DERIVATION OF A V4 LEG'S NATIVE SIDE: BPC.v4LegCurrencies.
//
// "Which side of a native V4 leg is the chain's coin?" was written by hand five times, each copy
// a line of its own: the Quoter's #52 preview (`_hookRefusedIn`) and dry-run (`_simV4`) derived it
// from zeroForOne, the Solver's depth funnel (`_capByLiveDepth`), held share (`_heldShare`) and
// planner quote (`_quoteWithDepth`) from the registry row's orientation. They now call one Core
// primitive. This is a refactor, so there is no red commit: what this file proves is that the
// primitive IS each of the copies it replaced, on every input, and that it derives the same key as
// the Router's WETH-verified producer (`nativeMapVerified`) on every leg the Router admits.
//
// THE ORACLES ARE NOT THE CODE UNDER TEST. `_quoterBefore`, `_rowBefore` and `_plannerBefore` are
// the hand-written lines exactly as they stood at 13fff68 (Quoter:426-431 and 565-577, Solver:996
// and 1172, Solver:1450-1462). The Router side is `nativeMapVerified` + sortTokens + the
// BPX-2026-009 direction check, as `_execV4Amt` runs them.
//
// The guard that keeps the copies from coming back is .github/scripts/v4_identity_guard.py.
//
// forge test --match-path test/Fusion1020V4LegCurrencies.t.sol -vv

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixCore as BPC} from "../src/BlazePhoenixCore.sol";

contract Fusion1020V4LegCurrenciesTest is Test {
    // ── the five copies, frozen as they were ────────────────────────────────────────────

    /// Quoter `_hookRefusedIn` / `_simV4` at 13fff68 (the two were the same three lines).
    function _quoterBefore(uint8 kind, address tIn, address tOther, bool zfo)
        internal pure returns (address, address)
    {
        if (kind == BPC.KIND_V4_NATIVE) {
            if (zfo) tIn = address(0);
            else tOther = address(0);
        }
        return (tIn, tOther);
    }

    /// Solver `_capByLiveDepth` / `_heldShare` at 13fff68: the currencies fed to computeV4PoolId.
    function _rowBefore(uint8 kind, address t0, address t1) internal pure returns (address, address) {
        return (kind == BPC.KIND_V4_NATIVE ? address(0) : t0, t1);
    }

    /// Solver `_quoteWithDepth` at 13fff68: the (tokenIn, tokenOther) of the planner's QuoteCtx.
    function _plannerBefore(uint8 kind, address t0, address t1, address tIn)
        internal pure returns (address qIn, address other)
    {
        bool zfo = t0 == tIn;
        qIn = tIn;
        other = zfo ? t1 : t0;
        if (kind == BPC.KIND_V4_NATIVE) {
            if (zfo) qIn = address(0); else other = address(0);
        }
    }

    /// Kinds 0..9 cover every live kind plus both neighbours of KIND_V4_NATIVE (8).
    function _kind(uint256 k) internal pure returns (uint8) {
        return uint8(k % 10);
    }

    // ── the primitive is each copy ──────────────────────────────────────────────────────

    function testFuzz_V4LegCurrencies_IsTheQuotersCopy(uint256 k, address tIn, address tOther, bool zfo) public pure {
        uint8 kind = _kind(k);
        (address a, address b) = BPC.v4LegCurrencies(kind, tIn, tOther, zfo);
        (address ea, address eb) = _quoterBefore(kind, tIn, tOther, zfo);
        assertEq(a, ea, "input currency differs from the Quoter's copy");
        assertEq(b, eb, "counterpart currency differs from the Quoter's copy");
    }

    function testFuzz_V4LegCurrencies_IsTheRowCopy(uint256 k, address t0, address t1) public pure {
        uint8 kind = _kind(k);
        (address a, address b) = BPC.v4LegCurrencies(kind, t0, t1, true);
        (address ea, address eb) = _rowBefore(kind, t0, t1);
        assertEq(a, ea, "currency0 differs from the Solver row copy");
        assertEq(b, eb, "currency1 differs from the Solver row copy");
    }

    function testFuzz_V4LegCurrencies_IsThePlannersCopy(uint256 k, address t0, address t1, bool inIsToken0) public pure {
        uint8 kind = _kind(k);
        address tIn = inIsToken0 ? t0 : t1;
        bool zfo = t0 == tIn;
        (address a, address b) = BPC.v4LegCurrencies(kind, tIn, zfo ? t1 : t0, zfo);
        (address ea, address eb) = _plannerBefore(kind, t0, t1, tIn);
        assertEq(a, ea, "qIn differs from the planner's copy");
        assertEq(b, eb, "other differs from the planner's copy");
    }

    // ── the primitive and the Router's producer name one pool ───────────────────────────

    /// Every native leg the Router admits: the WETH on one side (else RouterE(8)) and the direction
    /// its tokens' own (else RouterE(11)). The orientation derivation must build the same key, pass
    /// its own direction check, and so name the same poolId.
    function testFuzz_V4LegCurrencies_NamesTheRoutersPool(address weth, address other, bool wethIsInput, uint24 fee, int24 ts)
        public pure
    {
        vm.assume(weth != address(0) && other != address(0) && other != weth);
        address tIn = wethIsInput ? weth : other;
        address tOther = wethIsInput ? other : weth;

        (address rIn, address rOther) = BPC.nativeMapVerified(tIn, tOther, weth);
        (address r0, address r1) = BPC.sortTokens(rIn, rOther);
        bool zfo = rIn == r0;                          // the only direction _execV4Amt admits

        (address qIn, address qOther) = BPC.v4LegCurrencies(BPC.KIND_V4_NATIVE, tIn, tOther, zfo);
        (address q0, address q1) = BPC.sortTokens(qIn, qOther);
        assertTrue(zfo == (qIn == q0), "the Quoter would refuse a direction the Router admits");
        assertEq(q0, r0, "currency0 differs from the Router's key");
        assertEq(q1, r1, "currency1 differs from the Router's key");
        assertEq(BPC.computeV4PoolId(q0, q1, fee, ts, address(0)), BPC.computeV4PoolId(r0, r1, fee, ts, address(0)),
            "the two producers name different pools");
    }

    // ── the orientation contract, value by value (the mutant's witness) ─────────────────

    /// A native leg puts the chain's coin on its input side exactly when zeroForOne holds.
    function test_V4LegCurrencies_NativeSideFollowsZeroForOne() public pure {
        address w = address(0xEEEE);
        address t = address(0xAAAA);
        (address a, address b) = BPC.v4LegCurrencies(BPC.KIND_V4_NATIVE, w, t, true);
        assertEq(a, address(0), "zeroForOne: the input is currency0, the native side");
        assertEq(b, t, "zeroForOne: the counterpart is untouched");
        (a, b) = BPC.v4LegCurrencies(BPC.KIND_V4_NATIVE, t, w, false);
        assertEq(a, t, "oneForZero: the input is untouched");
        assertEq(b, address(0), "oneForZero: the counterpart is currency0, the native side");
        (a, b) = BPC.v4LegCurrencies(BPC.KIND_V4, w, t, true);
        assertEq(a, w, "a wrapped V4 leg keeps its tokens");
        assertEq(b, t, "a wrapped V4 leg keeps its tokens");
    }
}
