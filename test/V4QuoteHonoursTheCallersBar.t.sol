// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// Core:2024. The V4 arm of the one quote door (`universalQuoteRank`) hands the CALLER's
// `bar` to the walk: `return _v4Quote(c, amountIn, bar)`. The bar is what separates the two
// readers of that door (Core:2568-2581): the Quoter asks at type(uint256).max and reads the
// promise alone (a quote cut at sixteen stretches answers `rank == out` and the "not asked"
// ceiling `hi = max(rank, 2^128 - 1)`); the Solver's probe asks at 0 and has every truncated
// quote resolved (`rank > out`, `hi == rank` once the deep walk finishes).
//
// The book: an honest V4 book (1e24 liquidity over [-20000, 20000), tick spacing 1) with one
// wei of liquidity seated on each of the twenty ticks the order crosses first, so the
// sixteen-stretch walk spends its stretches on dust and leaves most of the input unspent.
//
// Oracle: `v4WalkRank` at the same bar - the door is the walk, at the bar the caller chose.
// Mutant (mutants.py "Core:2024"): the arm passes 0 instead of `bar`, so the Quoter's
// promise-only call resolves the deep walk and its ceiling falls under 2^128 - 1.
//
//   forge test --match-path test/V4QuoteHonoursTheCallersBar.t.sol -vv

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixCore as BPC, QuoteCtx} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV4TickManager} from "./mocks/MockV4TickManager.sol";

contract V4QuoteHonoursTheCallersBarTest is Test {
    MockV4TickManager mgr;
    address t0;
    address t1;
    bytes32 pid;

    uint24  constant FEE   = 100;   // static key fee, no protocol fee: the walk's fee is FEE
    int24   constant TS    = 1;
    uint128 constant L     = 1e24;
    uint256 constant ORDER = 1e22;
    uint256 constant NOT_ASKED = type(uint128).max;   // 2^128 - 1

    function setUp() public {
        mgr = new MockV4TickManager();
        address a = address(new MockERC20("A", "A"));
        address b = address(new MockERC20("B", "B"));
        (t0, t1) = a < b ? (a, b) : (b, a);
        pid = BPC.computeV4PoolId(t0, t1, FEE, TS, address(0));
        mgr.initialize(pid, BPC.sqrtPriceAtTick(0), 0, FEE);
        mgr.addPosition(pid, -20_000, 20_000, TS, L);
        for (int24 t = -20; t < 0; ++t) mgr.addPosition(pid, t, t + 1, TS, 1);
    }

    function _ctx() internal view returns (QuoteCtx memory c) {
        c.kind        = BPC.KIND_V4;
        c.zeroForOne  = true;          // t0 -> t1: the price walks down through the dust
        c.fee         = FEE;
        c.tickSpacing = TS;
        c.tokenIn     = t0;
        c.tokenOther  = t1;
        c.v4Manager   = address(mgr);
    }

    function _walk(uint256 amt, uint256 bar) internal view returns (uint256 lo, uint256 rank, uint256 hi) {
        return BPC.v4WalkRank(address(mgr), pid, amt, FEE, TS, true, bar);
    }

    /// The Quoter's call (bar = max) reads the promise alone on a cut book, and the Solver's
    /// call (bar = 0) reads the deep walk. RED under the Core:2024 mutant (bar dropped to 0).
    function test_TheV4QuoteAtTheMaximumBarReadsThePromiseAlone() public view {
        QuoteCtx memory c = _ctx();
        (uint256 lo, , ) = _walk(ORDER, 0);
        assertGt(lo, 0, "precondition: the sixteen stretches pay something");
        assertLt(lo * 10, ORDER, "precondition: the promise is cut more than tenfold");

        (uint256 out, , uint256 rank, uint256 hi) = BPC.universalQuoteRank(c, ORDER, type(uint256).max, false);
        assertEq(out, lo, "the promise is the sixteen-stretch walk");
        assertEq(rank, out, "bar = max: the rank is the promise, the deep walk is not asked");
        assertEq(hi, rank > NOT_ASKED ? rank : NOT_ASKED, "bar = max: the ceiling of a cut quote is 2^128 - 1");

        (uint256 out0, , uint256 rank0, uint256 hi0) = BPC.universalQuoteRank(c, ORDER, 0, false);
        assertEq(out0, out, "the bar never moves the promise");
        assertGt(rank0, ORDER * 98 / 100, "bar = 0: the deep walk reads the honest book");
        assertEq(hi0, rank0, "bar = 0: a walk that finished is its own ceiling");
    }

    /// For any bar and any order, the V4 arm answers exactly the walk at the caller's bar,
    /// and `lo <= rank <= hi` (the Solver subtracts `lo` from `hi` unchecked, B1).
    function testFuzz_TheV4QuoteIsTheWalkAtTheCallersBar(uint256 amt, uint256 bar) public view {
        amt = bound(amt, 1, 1e24);
        QuoteCtx memory c = _ctx();
        (uint256 out, , uint256 rank, uint256 hi) = BPC.universalQuoteRank(c, amt, bar, false);
        (uint256 lo, uint256 wRank, uint256 wHi) = _walk(amt, bar);
        assertEq(out, lo, "out is the walk's promise");
        assertEq(rank, wRank, "rank is the walk's rank at the caller's bar");
        assertEq(hi, wHi, "hi is the walk's ceiling at the caller's bar");
        assertLe(out, rank, "lo <= rank");
        assertLe(rank, hi, "rank <= hi");
    }
}
