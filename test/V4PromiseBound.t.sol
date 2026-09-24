// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  The in-frame PROMISE for a V4 leg never pays more than the pool's book holds.
//  Since the ninth wave the promise is the pool's own swap walked over its
//  initialized ticks (`Core.v4WalkOut`). This file pins it against a book with
//  one position around the price - so "the range" is the position the book
//  really holds, not an interval inferred from the tick spacing - and bounds it
//  by the range's content in closed form, computed here and never by the Core.
//  History: the promise was once unwired (main 8949a9d); then the single-tick
//  form truncated at an edge inferred from the spacing, whose up arm promised
//  1.030x the range with the price inside its tick, and whose model could see
//  neither the liquidity beyond a narrow range nor its absence (dex-19).
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixCore as BPC} from "../src/BlazePhoenixCore.sol";
import {MockV4TickManager} from "./mocks/MockV4TickManager.sol";

contract V4PromiseBoundTest is Test {
    int24 constant TS = int24(60);
    uint24 constant FEE = 3000;
    MockV4TickManager mgr;
    address tokenA = address(0xA11);
    address tokenB = address(0xB22);
    bytes32 pid;

    function setUp() public {
        mgr = new MockV4TickManager();
        (address s0, address s1) = BPC.sortTokens(tokenA, tokenB);
        pid = BPC.computeV4PoolId(s0, s1, FEE, TS, address(0));
    }

    /// One position [lo, hi) of `liq`, and the price at `P` (its tick `tick`) inside it.
    function _range(uint160 P, int24 tick, int24 lo, int24 hi, uint128 liq) internal {
        mgr.initialize(pid, P, tick, FEE);
        mgr.addPosition(pid, lo, hi, TS, liq);
    }

    /// Everything a range of liquidity `L` holds between the price `P` and the edge `e`,
    /// before fees: token0 on the way up, `L*Q96*(e-P)/(P*e)`; token1 on the way down,
    /// `L*(P-e)/Q96`. Rounded UP, because it is a ceiling.
    function _rangeCap(uint160 P, uint160 e, uint128 L, bool up) internal pure returns (uint256) {
        return up
            ? BPC.mulDivUp(BPC.mulDivUp(uint256(L), uint256(e) - uint256(P), uint256(e)), BPC.Q96, uint256(P))
            : BPC.mulDivUp(uint256(L), uint256(P) - uint256(e), BPC.Q96);
    }

    function test_RangeExit_PromiseIsTruncatedAtTheBoundary() public {
        // [0, 60) with the price at tick 59; a swap far larger than the range goes down
        // through it to its lower edge, and nothing lies below.
        uint160 P = mgr.sqrtAt(59);
        _range(P, 59, 0, 60, 1e18);
        uint256 amt = 1e21;
        uint256 bounded = BPC.v4LegOut(address(mgr), pid, amt, FEE, TS, true);
        uint256 cap = _rangeCap(P, mgr.sqrtAt(0), 1e18, false);
        assertLe(bounded, cap, "the promise priced liquidity below the range's lower edge");
        assertGt(bounded, cap * 999 / 1000, "and it promised less than the range holds");
        assertLt(bounded, BPC.outV3(amt, P, 1e18, FEE, true, 0), "the promise is not the edge-blind single-tick form");
    }

    function test_InsideRange_PromiseEqualsSingleTickForm() public {
        // a small swap deep inside the range: no edge is reached, and the pool's own swap
        // is the single-tick closed form
        uint160 P = mgr.sqrtAt(30);
        _range(P, 30, 0, 60, 1e24);
        uint256 amt = 1e18;
        assertApproxEqAbs(BPC.v4LegOut(address(mgr), pid, amt, FEE, TS, true),
            BPC.outV3(amt, P, uint128(1e24), FEE, true, 0), 4);
    }

    function test_StaticKey_ProtocolFee_ReachesThePromise() public {
        // the same pool with a 5-pip zeroForOne protocol fee promises less than without it
        uint160 P = mgr.sqrtAt(30);
        _range(P, 30, 0, 60, 1e24);
        uint256 without = BPC.v4LegOut(address(mgr), pid, 1e18, FEE, TS, true);
        mgr.initializeWithProtocolFee(pid, P, 30, 5, FEE);
        uint256 withFee = BPC.v4LegOut(address(mgr), pid, 1e18, FEE, TS, true);
        assertLt(withFee, without, "a protocol fee on a static key lowers the promise");
        assertApproxEqAbs(withFee, BPC.outV3(1e18, P, uint128(1e24), 3005, true, 0), 4, "by exactly the composed fee");
    }

    /// The price exactly at a position's lower edge, going down: the position lies above the
    /// price, so it pays nothing; a second position below pays what it holds, and no more.
    function test_AtTheLowerEdge_OnlyWhatLiesBelowIsPromised() public {
        uint160 P = mgr.sqrtAt(0);
        _range(P, 0, 0, 60, 1e18);
        uint256 amt = 1e21;
        assertEq(BPC.v4LegOut(address(mgr), pid, amt, FEE, TS, true), 0, "nothing lies below the price");
        mgr.addPosition(pid, -60, 0, TS, 2e18);
        uint256 below = BPC.v4LegOut(address(mgr), pid, amt, FEE, TS, true);
        uint256 cap = _rangeCap(P, mgr.sqrtAt(-60), 2e18, false);
        assertLe(below, cap, "the promise priced liquidity beyond the position below");
        assertGt(below, cap * 999 / 1000, "and it promised less than that position holds");
    }

    /// Going up from the same edge, the whole position lies ahead.
    function test_BoundaryTick_Up_PromisesTheWholeRange() public {
        uint160 P = mgr.sqrtAt(0);
        _range(P, 0, 0, 60, 1e18);
        uint256 up = BPC.v4LegOut(address(mgr), pid, 1e21, FEE, TS, false);
        uint256 cap = _rangeCap(P, mgr.sqrtAt(60), 1e18, true);
        assertLe(up, cap, "the promise priced liquidity above the range");
        assertGt(up, cap * 999 / 1000, "and it promised less than the range holds");
    }

    /// The up arm with the price INSIDE its tick, where the spacing-inferred edge once sat
    /// one tick too far (1.030x at 0.9 of tick 30).
    function test_Up_PriceInsideItsTick_PromiseNeverExceedsTheRangeOutput() public {
        uint160 P = uint160(79350658504438321566761821096);     // sqrt(1.0001^30.9) * 2^96
        _range(P, 30, 0, 60, 1e18);
        uint256 promised = BPC.v4LegOut(address(mgr), pid, 1e21, FEE, TS, false);
        uint256 rangeOut = _rangeCap(P, mgr.sqrtAt(60), uint128(1e18), true);
        emit log_named_uint("promised  ", promised);
        emit log_named_uint("range out ", rangeOut);
        assertLe(promised, rangeOut, "the up promise priced liquidity beyond the edge of the range");
        assertGt(promised, rangeOut * 95 / 100, "and it stays within the range's content");
    }

    /// Any spacing, any tick, the price anywhere inside its tick, either direction: the promise
    /// of a one-position book never exceeds what the position holds on that side of the price.
    function testFuzz_ThePromiseNeverPricesBeyondItsRange(
        int24 tickSeed, uint16 fracSeed, uint8 spacingSel, bool up
    ) public {
        int24 S = spacingSel % 4 == 0 ? int24(1) : spacingSel % 4 == 1 ? int24(10)
                 : spacingSel % 4 == 2 ? int24(60) : int24(200);
        int24 t = int24(int256(tickSeed) % 200_000);
        uint256 frac = 1 + uint256(fracSeed) % 998;               // per mille, never on a tick
        uint160 pT = mgr.sqrtAt(t);
        uint160 P = uint160(pT + (uint256(mgr.sqrtAt(t + 1)) - pT) * frac / 1000);
        int24 lo = t / S;
        if (t < 0 && t % S != 0) lo--;
        lo *= S;
        int24 hi = lo + S;
        mgr.initialize(pid, P, t, FEE);
        mgr.addPosition(pid, lo, hi, S, 1e18);

        uint256 promised = BPC.v4LegOut(address(mgr), pid, 1e30, FEE, S, !up);
        uint256 bound = _rangeCap(P, mgr.sqrtAt(up ? hi : lo), uint128(1e18), up);
        assertLe(promised, bound + 1, "the promise priced liquidity beyond the edge of its range");
        assertGt(promised, 0, "a range holding liquidity promised nothing");
    }

    /// A dynamic-fee key (fee sentinel 0x800000) under a non-zero protocol fee cannot be
    /// priced in the frame: the promise is zero, so the floor is the caller's attestation and
    /// userMinOut (SOK-DYNFEE-PROTOFEE). Pinned so the residual is visible, not assumed.
    function test_DynamicFeeKey_UnderProtocolFee_PromisesZero() public {
        uint160 P = mgr.sqrtAt(30);
        (address s0, address s1) = BPC.sortTokens(tokenA, tokenB);
        bytes32 dyn = BPC.computeV4PoolId(s0, s1, 0x800000, TS, address(0));
        mgr.initializeWithProtocolFee(dyn, P, 30, 5, 3000);
        mgr.addPosition(dyn, 0, 60, TS, 1e24);
        assertEq(BPC.v4LegOut(address(mgr), dyn, 1e18, 0x800000, TS, true), 0, "dynamic fee under a protocol fee promises zero");
    }

    function test_EmptyPool_PromisesZero() public view {
        assertEq(BPC.v4LegOut(address(mgr), pid, 1e18, FEE, TS, true), 0, "an uninitialised pool promises nothing");
    }
}
