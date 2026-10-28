// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// MED (2026-10-28): THE PROBE'S ERROR BOUND (`BlazePhoenixCore.universalProbe`). The band's
// width is the two fees and the two probes' error bounds e (BlazePhoenixMath, THE BAND), and
// its proof that an honest market at rest keeps its seat needs one thing of e: the price the
// band reads, p = floor(floor(out * 1e18 / probe) * 1e6 / (1e6 - fee)), lies within e of the
// pool's own spot price P, |p / P - 1| <= e (an overstated base is covered too: k carries
// (1 - e_b)). Read here on the pool shapes whose spot price is a closed form: a pair (P from its
// reserves) and a concentrated pool (P from sqrtPriceX96).
// Mutant [977] (the impact term dropped from e): a probe a tenth of the reserve falls 9% short
// of P with e of a few wei. Mutant [978] (the input side's 3 * WAD / n dropped from e): a 43-wei
// probe behind a 50% fee is handed 21 wei, not 21.5, and reads 2.3% short with e of 1.4e-5.

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixCore as BPC, QuoteCtx} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";
import {MockV3Pool} from "./mocks/MockV3Pool.sol";

contract MedianProbeErrorBoundTest is Test {
    uint256 constant PIPS = 1_000_000;
    uint256 constant WAD = 1e18;
    MockERC20 tA;
    MockERC20 tB;

    function setUp() public {
        tA = new MockERC20("A", "A");
        tB = new MockERC20("B", "B");
    }

    function _ctx(uint8 kind, address pool, address tIn, address tOut, uint24 fee)
        internal pure returns (QuoteCtx memory c)
    {
        c.kind = kind;
        c.pool = pool;
        c.zeroForOne = tIn < tOut;
        c.fee = fee;
        c.tokenIn = tIn;
        c.tokenOther = tOut;
        c.decIn1 = 19;      // 18 decimals, encoded + 1
        c.decOther1 = 19;
    }

    /// The price the band reads off a probe of `a` that paid `o` behind fee `f` (the Solver's
    /// `rates[i]`, then BlazePhoenixMath._prices).
    function _price(uint256 o, uint256 a, uint256 f) internal pure returns (uint256) {
        return BPC.mulDiv(o, 1e18, a) * PIPS / (PIPS - f);
    }

    /// A pair: x of the input token, y of the output, a fee of 1 to 100 bps, a probe up to a
    /// tenth of x. P = y / x. The pair's quote never overstates P; e covers the shortfall.
    function testFuzz_APairsProbeIsWithinItsBound(uint256 x, uint256 y, uint256 a, uint256 bps, bool aIn) public {
        x = bound(x, 1e15, 1e30);
        y = bound(y, 1e15, 1e30);
        a = bound(a, 1, x / 10);
        bps = bound(bps, 1, 100);
        (address tIn, address tOut) = aIn ? (address(tA), address(tB)) : (address(tB), address(tA));
        MockV2Pair p = new MockV2Pair(tIn, tOut);
        (uint256 r0, uint256 r1) = tIn < tOut ? (x, y) : (y, x);
        p.setReserves(uint112(r0), uint112(r1));
        MockERC20(p.token0()).mint(address(p), r0);
        MockERC20(p.token1()).mint(address(p), r1);
        (, uint256 o, uint256 f, uint256 e) = BPC.universalProbe(_ctx(BPC.KIND_V2, address(p), tIn, tOut, uint24(bps)), a);
        if (o == 0) return;   // a dead probe has no price to bound
        assertEq(f, bps * 100, "the fee the pair charged, in pips");
        uint256 q = _price(o, a, f);
        assertLe(q * x, y * 1e18, "the pair's probe read over its spot price");
        assertGe(q * x, BPC.mulDiv(y * 1e18, WAD - e, WAD), "the pair's probe fell short of its spot price by more than e");
    }

    /// A concentrated pool: liquidity up to 2^96 (see below), a price from 1e-6 to 1e6, any fee,
    /// a probe up to a tenth of the input side's virtual reserve. P = (sqrtP / 2^96)^2, or its
    /// inverse one way round. Here both sides of the bound are asked: `outV3` floors sqrtNew
    /// one way round, which can overstate the output by up to L / 2^96 + 1 units, so a probe
    /// can read above P; e covers it while L / 2^96 <= 1 (the 3 units of out in e). The fee's
    /// floor on the input is the other side, 1/n of the price (3 * WAD / n in e).
    function testFuzz_AConcentratedProbeIsWithinItsBound(uint256 sp, uint256 l, uint256 a, uint256 fee, bool zfo) public {
        sp = bound(sp, BPC.Q96 / 1000, BPC.Q96 * 1000);
        l = bound(l, 1e15, 1 << 96);
        fee = bound(fee, 1, 999_999);
        uint256 xIn = zfo ? BPC.mulDiv(l, BPC.Q96, sp) : BPC.mulDiv(l, sp, BPC.Q96);
        a = bound(a, 1, xIn / 10 + 1);
        MockV3Pool p = new MockV3Pool(address(tA), address(tB), uint24(fee));
        p.setState(uint160(sp), uint128(l));
        (address tIn, address tOut) = zfo ? (p.token0(), p.token1()) : (p.token1(), p.token0());
        (, uint256 o, uint256 f, uint256 e) = BPC.universalProbe(_ctx(BPC.KIND_V3, address(p), tIn, tOut, uint24(fee)), a);
        if (o == 0) return;
        assertEq(f, fee, "the fee the pool charged");
        uint256 q = _price(o, a, f);
        uint256 pf = zfo
            ? BPC.mulDiv(BPC.mulDiv(sp, sp, BPC.Q96), 1e18, BPC.Q96)
            : BPC.mulDiv(BPC.mulDiv(BPC.Q96, BPC.Q96, sp), 1e18, sp);
        assertLe(q, BPC.mulDiv(pf + 1, WAD + e, WAD) + 1, "the concentrated probe read over its spot price by more than e");
        assertGe(q, BPC.mulDiv(pf, WAD - e, WAD), "the concentrated probe fell short of its spot price by more than e");
    }

    /// The deterministic case [978] dies on: a concentrated pool at price 1e4, a probe of 43 wei
    /// behind a 50% fee. The pool is handed n = floor(21.5) = 21 wei: the probe reads 0.9767 of
    /// the spot price, 2.3% short, while its output (209,999 wei) and its impact (43 wei of a
    /// 1e16 reserve) alone would put e at 1.4e-5.
    function test_AProbeWhoseFeeFloorsAWeiOfInputIsInsideItsBound() public {
        MockV3Pool p = new MockV3Pool(address(tA), address(tB), 500_000);
        p.setState(uint160(100 * BPC.Q96), 1e18);
        (, uint256 o, uint256 f, uint256 e) =
            BPC.universalProbe(_ctx(BPC.KIND_V3, address(p), p.token0(), p.token1(), 500_000), 43);
        uint256 q = _price(o, 43, f);
        emit log_named_decimal_uint("price read", q, 18);
        emit log_named_decimal_uint("error bound", e, 18);
        assertEq(o, 209_999, "the pool's output for the 21 wei it was handed");
        assertLt(q, 977e19, "the probe reads 2.3% under the spot price 1e4");
        assertGe(q, BPC.mulDiv(1e22, WAD - e, WAD), "e covers the wei of input the fee's floor took");
    }

    /// The deterministic case [977] dies on: a probe a tenth of a pair's reserve, fee 30 bps.
    /// P = 1; the probe reads 1/1.0997 = 0.909 of it; e must be at least that far.
    function test_ATenthOfThePairIsInsideItsBound() public {
        MockV2Pair p = new MockV2Pair(address(tA), address(tB));
        p.setReserves(1e24, 1e24);
        tA.mint(address(p), 1e24);
        tB.mint(address(p), 1e24);
        (, uint256 o, uint256 f, uint256 e) = BPC.universalProbe(_ctx(BPC.KIND_V2, address(p), address(tA), address(tB), 30), 1e23);
        uint256 q = _price(o, 1e23, f);
        emit log_named_decimal_uint("price read", q, 18);
        emit log_named_decimal_uint("error bound", e, 18);
        assertLt(q, 91e16, "the probe of a tenth reads under 0.91");
        assertGe(q, WAD - e, "e covers the probe's own impact");
    }
}
