// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// A DEGENERATE INPUT QUOTES NOTHING. A probe of zero input (`BlazePhoenixCore._quoteArms`, the
// one body of `universalQuoteRank` and `universalProbe`) reads no venue: no mass, no rank, no fee,
// and its two bounds say nothing is known (rank 0 reads err = errOrder = WAD, the rule of
// test/ProbeTwoBounds.t.sol). Control: one wei on the same pair declares the pair's mass and fee.
// Oracle: zeros and WAD, written by hand; the pair's own reserves for the control.
// Mutant (.github/scripts/mutants.py, block `# 124-L1`):
//   «L1-124 Core:1909» `if (amountIn == 0)` -> `if (amountIn == 1)` (a zero probe reads the pair:
//     its out reserve as mass and its fee) -> red;
//   «L1-124 Core:2150» `if (liq == 0)` -> `if (liq == 1)` (a V4 book with no liquidity in range
//     is walked and quoted) -> red.

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixCore as BPC, QuoteCtx} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";
import {MockV4TickManager} from "./mocks/MockV4TickManager.sol";

contract DegenerateInputQuotesNothingTest is Test {
    uint256 constant WAD = 1e18;
    MockERC20 tA;
    MockERC20 tB;

    function setUp() public {
        tA = new MockERC20("A", "A");
        tB = new MockERC20("B", "B");
    }

    /// A pair holding x of the input token and y of the output, 30 bps, both 18 decimals.
    function _pair(uint256 x, uint256 y) internal returns (QuoteCtx memory c) {
        (address t0, address t1) = address(tA) < address(tB) ? (address(tA), address(tB)) : (address(tB), address(tA));
        MockV2Pair p = new MockV2Pair(t0, t1);
        (uint256 r0, uint256 r1) = address(tA) == t0 ? (x, y) : (y, x);
        p.setReserves(uint112(r0), uint112(r1));
        MockERC20(t0).mint(address(p), r0);
        MockERC20(t1).mint(address(p), r1);
        c.kind = BPC.KIND_V2;
        c.pool = address(p);
        c.zeroForOne = address(tA) == t0;
        c.fee = 30;
        c.tokenIn = address(tA);
        c.tokenOther = address(tB);
        c.decIn1 = 19;
        c.decOther1 = 19;
    }

    function _assertNothing(QuoteCtx memory c, bool wantFee, uint256 orderIn) internal view {
        (uint256 mass, uint256 rank, uint256 fee, uint256 err, uint256 errOrder) =
            BPC.universalProbe(c, 0, 0, wantFee, orderIn);
        assertEq(mass, 0, "zero input: no mass");
        assertEq(rank, 0, "zero input: no rank");
        assertEq(fee, 0, "zero input: no fee");
        assertEq(err, WAD, "zero input: err says nothing is known");
        assertEq(errOrder, WAD, "zero input: errOrder says nothing is known");
    }

    /// Dust, a pair at 4, and uint112's ceiling; order 0, one wei and 1e18; fee asked or not.
    function test_QuoteArmsZeroInput() public {
        uint256[3] memory x = [uint256(1), 1e18, type(uint112).max];
        uint256[3] memory y = [uint256(1), 4e18, type(uint112).max];
        uint256[3] memory o = [uint256(0), 1, 1e18];
        for (uint256 i; i < 3; ++i) {
            QuoteCtx memory c = _pair(x[i], y[i]);
            for (uint256 j; j < 3; ++j) {
                _assertNothing(c, true, o[j]);
                _assertNothing(c, false, o[j]);
            }
        }
        // control: one wei on the pair at 4 declares its out reserve and its 30 bps
        (uint256 mass,, uint256 fee,,) = BPC.universalProbe(_pair(1e18, 4e18), 1, 0, true, 0);
        assertEq(mass, 4e18, "one wei: the pair's out reserve");
        assertEq(fee, 3000, "one wei: the pair's fee in pips");
    }

    function testFuzz_QuoteArmsZeroInput(uint256 x, uint256 y, uint256 orderIn) public {
        x = bound(x, 1, type(uint112).max);
        y = bound(y, 1, type(uint112).max);
        orderIn = bound(orderIn, 0, uint256(1) << 128);
        _assertNothing(_pair(x, y), true, orderIn);
    }

    /// A V4 book initialized at tick 0 behind `fee`, holding `liq` from tick -20000 to 20000
    /// (none when 0).
    function _book(uint24 fee, uint128 liq, bool zeroForOne) internal returns (QuoteCtx memory c) {
        MockV4TickManager m = new MockV4TickManager();
        (address c0, address c1) = address(tA) < address(tB) ? (address(tA), address(tB)) : (address(tB), address(tA));
        c.kind = BPC.KIND_V4;
        c.zeroForOne = zeroForOne;
        c.fee = fee;
        c.tickSpacing = 1;
        (c.tokenIn, c.tokenOther) = zeroForOne ? (c0, c1) : (c1, c0);
        c.v4Manager = address(m);
        c.decIn1 = 19;
        c.decOther1 = 19;
        bytes32 pid = BPC.computeV4PoolId(c0, c1, fee, 1, address(0));
        m.initialize(pid, BPC.sqrtPriceAtTick(0), 0, fee);
        if (liq > 0) m.addPosition(pid, -20_000, 20_000, 1, liq);
    }

    /// A V4 book with no liquidity is quoted like a dead pool, whatever the input and the fee;
    /// both directions. Control: the same book with a position declares mass and its fee.
    function test_ConcLiqZeroQuotesNothing() public {
        uint24[3] memory fees = [uint24(100), 3000, 50_000];
        uint256[3] memory a = [uint256(1), 1e18, type(uint112).max];
        for (uint256 i; i < 3; ++i) {
            for (uint256 d; d < 2; ++d) {
                QuoteCtx memory c = _book(fees[i], 0, d == 0);
                for (uint256 j; j < 3; ++j) {
                    (uint256 mass, uint256 rank, uint256 fee, uint256 err, uint256 errOrder) =
                        BPC.universalProbe(c, a[j], 0, true, a[j]);
                    assertEq(mass, 0, "no liquidity: no mass");
                    assertEq(rank, 0, "no liquidity: no rank");
                    assertEq(fee, 0, "no liquidity: no fee");
                    assertEq(err, WAD, "no liquidity: err says nothing is known");
                    assertEq(errOrder, WAD, "no liquidity: errOrder says nothing is known");
                }
            }
        }
        (uint256 m1, uint256 r1, uint256 f1,,) = BPC.universalProbe(_book(3000, 1e24, true), 1e18, 0, true, 1e18);
        assertGt(m1, 0, "a position: mass");
        assertGt(r1, 0, "a position: rank");
        assertEq(f1, 3000, "a position: its fee in pips");
    }
}
