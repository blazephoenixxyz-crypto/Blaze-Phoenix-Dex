// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  The one-range V3 quote against the pool's own step: old, new and pool.
//
//  OLD   test/legacy/OutV3Legacy.sol: outV3 as it stood at 2e4fdaa, its own
//        two-branch Q96 algebra and its own rounding.
//  NEW   BlazePhoenixCore.outV3.
//  POOL  test/vendor/SwapMathRef.sol: Uniswap v3-core SwapMath.computeSwapStep,
//        exact input, from the price toward the range's boundary (the limit, or
//        the price bound when there is none) - what a pool pays while its
//        liquidity does not change. No Core code runs inside the oracle.
//
//  What is DERIVED and asserted about the old figure (oneForZero, boundary not
//  reached): both share s' = P + floor(n * 2^96 / L); with x = L (s' - P) / s',
//  old = floor(floor(x) * 2^96 / P) and pool = floor(floor(x * 2^96) / P).
//  floor(x) * 2^96 is an integer under x * 2^96, so old <= pool; and
//  pool - old <= x 2^96 / P - ((x - 1) 2^96 / P - 1) = 2^96 / P + 1, so
//  pool - old <= floor(2^96 / P) + 1. The zeroForOne side has no such sign:
//  the old floor on n * P / 2^96 and the old floor on the new price pull
//  opposite ways (the pool rounds the price up), so its distance is MEASURED
//  and logged here, not asserted.
//
//  What is asserted about the NEW figure: it IS the pool's step, to the wei, on
//  every sample, both directions, with and without a limit, boundary reached
//  or not (red at 5570321, where outV3 was still the old form).
//
//  SAMPLES. A grid over the extremes (input from one wei to 2^128 - 1, liquidity
//  from one to 2^128 - 1, the price from the bound's neighbour to the other
//  bound's, fees from 0 to 999999 pips, both directions) and a pre-registered
//  log-uniform draw: SEED below was committed before any figure was measured,
//  and each draw is keccak(SEED, i). Log-uniform because a uniform draw almost
//  never lands under 2^96 in a 160-bit price.
// =============================================================================

import {Test, console2, stdError} from "forge-std/Test.sol";
import {BlazePhoenixCore as BPC} from "../src/BlazePhoenixCore.sol";
import {OutV3Legacy} from "./legacy/OutV3Legacy.sol";
import {SwapMathRef, SqrtPriceMathRef} from "./vendor/SwapMathRef.sol";

contract OutV3StepParityTripleTest is Test {
    // TickMath.MIN_SQRT_RATIO / MAX_SQRT_RATIO, from the v3-core source, not from the Core
    uint160 internal constant MIN_SQRT = 4295128739;
    uint160 internal constant MAX_SQRT = 1461446703485210103287273052203988822378723970342;
    uint256 internal constant Q96 = 2 ** 96;
    uint256 internal constant SEED = 0x2e4fdaa13112026;
    uint256 internal constant DRAWS = 3000;

    struct Tally {
        uint256 n;
        uint256 newOff;
        uint256 oldReverts;
        uint256 oldAbove;
        uint256 oldBelow;
        uint256 maxAbove;
        uint256 maxBelow;
        uint256 maxAboveInRange;
        uint256 maxBelowInRange;
    }

    // ------------------------------------------------------------------ the three figures

    /// The pool's exact-input step over one range, toward `limit` or, with none, the price bound
    /// a swap may reach. A boundary at or past the price leaves no room to trade: the pool pays 0.
    function poolOut(uint256 a, uint160 p, uint128 l, uint24 f, bool zfo, uint160 limit)
        internal pure returns (uint256 out, bool reached)
    {
        uint160 target = limit != 0 ? limit : (zfo ? MIN_SQRT + 1 : MAX_SQRT - 1);
        if (zfo ? target >= p : target <= p) return (0, false);
        uint160 next;
        (next, , out, ) = SwapMathRef.computeSwapStep(p, target, l, int256(a), f);
        reached = next == target;
    }

    function oldOut(uint256 a, uint160 p, uint128 l, uint24 f, bool zfo, uint160 limit) external pure returns (uint256) {
        return OutV3Legacy.outV3At2e4fdaa(a, p, l, f, zfo, limit);
    }

    function _triple(uint256 a, uint160 p, uint128 l, uint24 f, bool zfo, uint160 limit, Tally memory t) internal view {
        (uint256 pool, bool reached) = poolOut(a, p, l, f, zfo, limit);
        uint256 nw = BPC.outV3(a, p, l, f, zfo, limit);
        if (nw != pool) t.newOff++;
        assertEq(nw, pool, "new: the one-range quote is not the pool's step");
        t.n++;
        try this.oldOut(a, p, l, f, zfo, limit) returns (uint256 old) {
            if (old > pool) {
                t.oldAbove++;
                if (old - pool > t.maxAbove) t.maxAbove = old - pool;
            } else if (pool > old) {
                t.oldBelow++;
                if (pool - old > t.maxBelow) t.maxBelow = pool - old;
            }
            if (!reached && old > pool && old - pool > t.maxAboveInRange) t.maxAboveInRange = old - pool;
            if (!reached && pool > old && pool - old > t.maxBelowInRange) t.maxBelowInRange = pool - old;
            if (!zfo && limit == 0 && !reached && pool != 0) {
                assertLe(old, pool, "oneForZero: the old figure sat above the pool's step");
                assertLe(pool - old, Q96 / p + 1, "oneForZero: the old figure sat more than floor(2^96/P)+1 under the pool");
            }
        } catch {
            t.oldReverts++;
        }
    }

    function _log(string memory what, Tally memory t) internal pure {
        console2.log(what);
        console2.log("  samples", t.n);
        console2.log("  new != pool", t.newOff);
        console2.log("  old reverted", t.oldReverts);
        console2.log("  old above pool / max wei", t.oldAbove, t.maxAbove);
        console2.log("  old below pool / max wei", t.oldBelow, t.maxBelow);
        console2.log("  boundary not reached: old max wei above / below pool", t.maxAboveInRange, t.maxBelowInRange);
    }

    // ------------------------------------------------------------------ the grid

    function _amounts() internal pure returns (uint256[] memory a) {
        a = new uint256[](34);
        a[0] = 1;
        a[1] = 2;
        uint256 v = 1;
        for (uint256 k; k <= 30; ++k) {
            a[2 + k] = v;
            v *= 10;
        }
        a[33] = type(uint128).max;
    }

    function _liquidities() internal pure returns (uint128[] memory l) {
        l = new uint128[](8);
        l[0] = 1;
        l[1] = 2 ** 64;
        l[2] = 2 ** 96 - 1;
        l[3] = 2 ** 96;
        l[4] = 2 ** 96 + 1;
        l[5] = 2 ** 100;
        l[6] = 2 ** 120;
        l[7] = type(uint128).max;
    }

    function _prices() internal pure returns (uint160[] memory p) {
        p = new uint160[](5);
        p[0] = MIN_SQRT + 2;
        p[1] = uint160(Q96 >> 20);
        p[2] = uint160(Q96);
        p[3] = uint160(Q96 << 20);
        p[4] = MAX_SQRT - 2;
    }

    function _fees() internal pure returns (uint24[] memory f) {
        f = new uint24[](6);
        f[0] = 0;
        f[1] = 100;
        f[2] = 500;
        f[3] = 3000;
        f[4] = 10000;
        f[5] = 999999;
    }

    function _grid(bool zfo) internal view returns (Tally memory t) {
        uint256[] memory a = _amounts();
        uint128[] memory l = _liquidities();
        uint160[] memory p = _prices();
        uint24[] memory f = _fees();
        for (uint256 i; i < a.length; ++i)
            for (uint256 j; j < l.length; ++j)
                for (uint256 k; k < p.length; ++k)
                    for (uint256 m; m < f.length; ++m)
                        _triple(a[i], p[k], l[j], f[m], zfo, 0, t);
    }

    function test_zfo_grid() public view {
        _log("zeroForOne grid", _grid(true));
    }

    function test_ofz_grid() public view {
        _log("oneForZero grid", _grid(false));
    }

    // ------------------------------------------------------------------ the pre-registered draw

    /// 2^e .. 2^(e+1) - 1 with e uniform in [lo, hi): log-uniform over the bit length.
    function _logU(uint256 r, uint256 lo, uint256 hi) internal pure returns (uint256) {
        uint256 e = lo + (r % (hi - lo));
        uint256 base = uint256(1) << e;
        return base + ((r >> 8) % base);
    }

    function _draw(uint256 i) internal pure returns (
        uint256 a, uint160 p, uint128 l, uint24 f, bool zfo, uint160 limit
    ) {
        uint256 r0 = uint256(keccak256(abi.encode(SEED, i, 0)));
        uint256 r1 = uint256(keccak256(abi.encode(SEED, i, 1)));
        uint256 r2 = uint256(keccak256(abi.encode(SEED, i, 2)));
        uint256 r3 = uint256(keccak256(abi.encode(SEED, i, 3)));
        a = _logU(r0, 0, 128);
        l = uint128(_logU(r1, 0, 128));
        uint256 pp = _logU(r2, 32, 160);
        if (pp < MIN_SQRT + 2) pp = MIN_SQRT + 2;
        if (pp > MAX_SQRT - 2) pp = MAX_SQRT - 2;
        p = uint160(pp);
        uint24[9] memory fs = [uint24(0), 1, 100, 500, 3000, 10000, 100000, 500000, 999999];
        f = r3 & 1 == 0 ? fs[(r3 >> 1) % 9] : uint24((r3 >> 8) % 1_000_000);
        zfo = (r3 >> 40) & 1 == 1;
        uint256 kind = (r3 >> 48) % 3;
        if (kind == 1) {
            // a boundary somewhere between the price and the bound on the trade's side
            uint256 span = zfo ? p - (MIN_SQRT + 1) : (MAX_SQRT - 1) - p;
            uint256 d = 1 + ((r3 >> 64) % span);
            limit = uint160(zfo ? p - d : p + d);
        } else if (kind == 2) {
            // a boundary one sqrt-price unit away: the tightest range there is
            limit = zfo ? p - 1 : p + 1;
        }
    }

    function test_preregistered_draw() public view {
        Tally memory t;
        for (uint256 i; i < DRAWS; ++i) {
            (uint256 a, uint160 p, uint128 l, uint24 f, bool zfo, uint160 limit) = _draw(i);
            _triple(a, p, l, f, zfo, limit, t);
        }
        _log("pre-registered draw", t);
    }

    // ------------------------------------------------------------------ behaviour changes, pinned
    // Each was red at 5570321 (the old form) except the binding-limit pin, which held there too.

    /// zeroForOne no longer quotes above the pool (L = 2^100 at price 1, 1e18 in, 0.3%).
    function test_zfo_noLongerQuotesAboveThePool() public view {
        uint160 p = uint160(Q96);
        uint128 l = uint128(2 ** 100);
        (uint256 pool, ) = poolOut(1e18, p, l, 3000, true, 0);
        assertGt(this.oldOut(1e18, p, l, 3000, true, 0), pool, "witness: the old form sat above the pool here");
        assertEq(BPC.outV3(1e18, p, l, 3000, true, 0), pool, "zeroForOne: the quote is the pool's step");
    }

    /// oneForZero quotes what the pool pays, no longer under it (L = 2^100 at sqrt price 2^-20).
    function test_ofz_quotesThePoolNotUnderIt() public view {
        uint160 p = uint160(Q96 >> 20);
        uint128 l = uint128(2 ** 100);
        (uint256 pool, ) = poolOut(1e18, p, l, 3000, false, 0);
        assertLt(this.oldOut(1e18, p, l, 3000, false, 0), pool, "witness: the old form sat under the pool here");
        assertEq(BPC.outV3(1e18, p, l, 3000, false, 0), pool, "oneForZero: the quote is the pool's step");
    }

    /// A price at the bound on the trade's side quotes nothing, never a revert: no limit a pool
    /// accepts lies past it. The old form quoted 2^32 wei for a pool at MIN_SQRT_RATIO.
    function test_aPriceAtTheBoundQuotesNothing() public view {
        uint128 l = type(uint128).max;
        uint256 a = 2 ** 100;
        assertGt(this.oldOut(a, MIN_SQRT, l, 3000, true, 0), 0, "witness: the old form quoted a pool that cannot pay");
        assertEq(BPC.outV3(a, MIN_SQRT, l, 3000, true, 0), 0, "falling from MIN_SQRT_RATIO: nothing");
        assertEq(BPC.outV3(a, MIN_SQRT + 1, l, 3000, true, 0), 0, "falling from MIN_SQRT_RATIO + 1: nothing");
        assertEq(BPC.outV3(a, MAX_SQRT - 1, l, 3000, false, 0), 0, "rising from MAX_SQRT_RATIO - 1: nothing");
        assertEq(BPC.outV3(a, MAX_SQRT, l, 3000, false, 0), 0, "rising from MAX_SQRT_RATIO: nothing");
        // control: the same pools trade the other way
        assertGt(BPC.outV3(a, MIN_SQRT, l, 3000, false, 0), 0, "control: MIN_SQRT_RATIO rises");
        assertGt(BPC.outV3(a, MAX_SQRT - 1, l, 3000, true, 0), 0, "control: MAX_SQRT_RATIO - 1 falls");
    }

    /// A limit at or past the price quotes 0; the old form reverted on one past it. No caller in
    /// src/ passes a limit (all pass 0): the pin is on the function's own domain.
    function test_aLimitAtOrPastThePriceQuotesNothing() public {
        uint160 p = uint160(Q96);
        assertEq(BPC.outV3(1e18, p, 1e18, 3000, true, p + 1), 0, "zeroForOne, limit above the price");
        assertEq(BPC.outV3(1e18, p, 1e18, 3000, true, p), 0, "zeroForOne, limit at the price");
        assertEq(BPC.outV3(1e18, p, 1e18, 3000, false, p - 1), 0, "oneForZero, limit below the price");
        assertEq(BPC.outV3(1e18, p, 1e18, 3000, false, p), 0, "oneForZero, limit at the price");
        vm.expectRevert(stdError.arithmeticError);
        this.oldOut(1e18, p, 1e18, 3000, true, p + 1);
    }

    /// An input past 2^256 / 1e6 quotes the whole range to the bound; the old form overflowed on
    /// ain * (1e6 - fee).
    function test_aHugeInputQuotesTheWholeRange() public {
        uint160 p = uint160(Q96);
        uint128 l = 1e18;
        uint256 a = type(uint256).max;
        assertEq(BPC.outV3(a, p, l, 3000, true, 0), SqrtPriceMathRef.getAmount1Delta(MIN_SQRT + 1, p, l, false),
            "zeroForOne: the whole range down to the bound");
        assertEq(BPC.outV3(a, p, l, 3000, false, 0), SqrtPriceMathRef.getAmount0Delta(p, MAX_SQRT - 1, l, false),
            "oneForZero: the whole range up to the bound");
        vm.expectRevert(stdError.arithmeticError);
        this.oldOut(a, p, l, 3000, true, 0);
    }

    /// A binding limit truncates at the boundary: the pool's step to it, under the unlimited quote.
    function test_aBindingLimitTruncatesAtTheBoundary() public view {
        uint160 p = uint160(Q96);
        uint128 l = 1e18;
        uint160 lo = uint160(Q96 * 9 / 10);
        uint160 hi = uint160(Q96 * 11 / 10);
        (uint256 pz, bool rz) = poolOut(1e18, p, l, 3000, true, lo);
        (uint256 po, bool ro) = poolOut(1e18, p, l, 3000, false, hi);
        assertTrue(rz && ro, "witness: both limits bind");
        assertEq(BPC.outV3(1e18, p, l, 3000, true, lo), pz, "zeroForOne: truncated at the limit");
        assertEq(BPC.outV3(1e18, p, l, 3000, false, hi), po, "oneForZero: truncated at the limit");
        assertLt(pz, BPC.outV3(1e18, p, l, 3000, true, 0), "zeroForOne: the limit binds");
        assertLt(po, BPC.outV3(1e18, p, l, 3000, false, 0), "oneForZero: the limit binds");
    }

    /// The walker's step is the pool's step: price reached, input spent (fee included), output.
    /// In the partial branch the pool's next price never lands on the target (zeroForOne: it is
    /// the ceiling of a price strictly above it; oneForZero: P + floor(n 2^96 / L) < target), so
    /// amountIn + feeAmount = rem there, and the step's `used` = rem is the pool's.
    function test_walkerStepIsThePoolStep() public view {
        for (uint256 i; i < DRAWS; ++i) {
            (uint256 a, uint160 p, uint128 l, uint24 f, bool zfo, uint160 limit) = _draw(i);
            uint160 target = limit != 0 ? limit : (zfo ? MIN_SQRT + 1 : MAX_SQRT - 1);
            (uint160 n1, uint256 used, uint256 o1) = BPC._v4Step(p, target, l, a, f, zfo);
            (uint160 n2, uint256 ain, uint256 o2, uint256 fee) = SwapMathRef.computeSwapStep(p, target, l, int256(a), f);
            assertEq(n1, n2, "step: the price reached is not the pool's");
            assertEq(o1, o2, "step: the output is not the pool's");
            assertEq(used, ain + fee, "step: the input spent is not the pool's");
        }
    }
}
